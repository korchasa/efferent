import CryptoKit
import Foundation
import os

/// Puts days into the bucket, one request per day.
///
/// **A background session, not an ordinary one.** The upload is usually started
/// from a HealthKit delivery that woke the app for a couple of seconds. An
/// ordinary `URLSession` task dies with the process; a background one is handed
/// to a system daemon that finishes it and relaunches the app to report back.
///
/// **The body goes through a file.** Background sessions reject the in-memory
/// `uploadTask(with:from:)` — the daemon has to read the body after this process
/// is gone, so it must exist on disk.
///
/// **The day is sealed before it is staged.** What lands in the temporary file
/// is already ciphertext, so even that momentary copy tells nobody anything.
///
/// **An unchanged day never goes.** A day is built, then its plaintext is
/// fingerprinted and compared with what the service last accepted. Re-reading
/// the last week on every refresh therefore costs a few Health queries and no
/// network at all. The fingerprint is of the plaintext, not of what goes on the
/// wire: sealing uses a fresh throwaway key every time, so two identical days
/// never produce the same bytes.
///
/// **Days are independent, so several go at once.** There is no order to keep
/// and no counter to protect — a day either arrived or it did not, and the one
/// that did not is still marked. That is what makes the first export minutes
/// rather than an hour.
public final class Uploader: NSObject {
    public struct Configuration {
        /// Days built in one pass. They are read from Health as a single span,
        /// so this is mostly about how much work is redone if the app is
        /// suspended halfway.
        public let daysPerPass: Int
        /// Requests in the air at once.
        public let concurrentUploads: Int
        public let sessionIdentifier: String

        public init(
            daysPerPass: Int = 31,
            concurrentUploads: Int = 4,
            sessionIdentifier: String = "dev.korchasa.efferent.upload"
        ) {
            self.daysPerPass = daysPerPass
            self.concurrentUploads = concurrentUploads
            self.sessionIdentifier = sessionIdentifier
        }
    }

    public enum Outcome: Equatable {
        case nothingToSend
        /// `days` went up; `unchanged` were rebuilt, found identical to what the
        /// archive already holds, and cost nothing.
        case scheduled(days: Int, unchanged: Int)
        case alreadyInFlight
    }

    public enum UploadError: Error, Equatable {
        case staging(String)
    }

    private let configuration: Configuration
    private let destination: Destination
    private let store: Store
    private let identity: DeviceIdentity
    private let build: (([String]) async throws -> [String: DayContents])
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "upload")

    /// Touched only on `delegateQueue`, which is serial.
    private var inFlightDays: [Int: (day: String, digest: Data, identifiers: [UUID])] = [:]
    private var responseBodies: [Int: Data] = [:]
    private var stagedFiles: [Int: URL] = [:]

    /// Handed over by the app when iOS relaunches it to deliver finished
    /// transfers; called once the session says it has reported everything.
    public var backgroundEventsFinished: (() -> Void)?

    /// Called after every day the service accepts, so a screen showing the
    /// counters can follow along. Days land on the session's delegate queue, far
    /// away from any view, and without this the numbers on screen only change
    /// when the screen happens to reappear.
    public var didStoreDay: (() -> Void)?

    /// Guards against two passes overlapping. A flag rather than a look at
    /// `session.allTasks`, because the next pass is started from the completion
    /// of the previous one, and at that moment the finished task may still be
    /// listed — which would refuse the send and leave days standing.
    private let passLock = NSLock()
    private var passRunning = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: configuration.sessionIdentifier)
        // The data is small and the point of the app is freshness, so let it go
        // as soon as there is a network rather than waiting for a charger.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = configuration.concurrentUploads
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    public init(
        configuration: Configuration = Configuration(),
        destination: Destination,
        store: Store,
        identity: DeviceIdentity = DeviceIdentity(),
        build: @escaping ([String]) async throws -> [String: DayContents]
    ) {
        self.configuration = configuration
        self.destination = destination
        self.store = store
        self.identity = identity
        self.build = build
        super.init()
    }

    /// Build the next days and hand the changed ones to the system.
    public func send() async throws -> Outcome {
        guard claimPass() else { return .alreadyInFlight }
        defer { releasePass() }

        let days = try store.pendingDays(limit: configuration.daysPerPass)
        guard !days.isEmpty else { return .nothingToSend }

        let contents = try await build(days)
        var sent = 0
        var unchanged = 0

        for day in days {
            guard let content = contents[day] else { continue }
            let plaintext = try NDJSON.body(content.events)
            let digest = Data(SHA256.hash(data: plaintext))

            if try store.digest(for: day) == digest {
                try store.markClean(day: day)
                unchanged += 1
                continue
            }

            try schedule(day: day, plaintext: plaintext, digest: digest, content: content)
            sent += 1
        }

        log.info("pass over \(days.count) days: \(sent) sending, \(unchanged) unchanged")
        return sent == 0 && unchanged == 0 ? .nothingToSend : .scheduled(days: sent, unchanged: unchanged)
    }

    private func schedule(
        day: String, plaintext: Data, digest: Data, content: DayContents
    ) throws {
        let body = try SealedBox.seal(
            readingPublicKey: destination.readingPublicKey,
            plaintext: Deflate.compress(plaintext),
            associatedData: CanonicalRequest.associatedData(bucket: destination.bucket, day: day)
        )
        let file = try stage(body)
        let task = session.uploadTask(with: try signedRequest(day: day, body: body), fromFile: file)
        inFlightDays[task.taskIdentifier] = (day, digest, content.sampleIdentifiers)
        stagedFiles[task.taskIdentifier] = file
        task.resume()
    }

    private func claimPass() -> Bool {
        passLock.lock()
        defer { passLock.unlock() }
        guard !passRunning else { return false }
        passRunning = true
        return true
    }

    private func releasePass() {
        passLock.lock()
        passRunning = false
        passLock.unlock()
    }

    /// Restart a transfer the system reported as finished while the app was not
    /// running. Call from `application(_:handleEventsForBackgroundURLSession:)`.
    public func adoptBackgroundSession() {
        _ = session
    }

    // MARK: - Building a request

    private func signedRequest(day: String, body: Data) throws -> URLRequest {
        let key = try identity.signingKey()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = try key.signature(
            for: CanonicalRequest.bytes(
                bucket: destination.bucket, day: day, timestamp: timestamp, body: body
            )
        )

        var request = URLRequest(url: destination.dayURL(day))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(timestamp), forHTTPHeaderField: "x-efferent-timestamp")
        request.setValue(
            Base64URL.encode(key.publicKey.rawRepresentation), forHTTPHeaderField: "x-efferent-writer"
        )
        request.setValue(Base64URL.encode(Data(signature)), forHTTPHeaderField: "x-efferent-signature")
        return request
    }

    private func stage(_ body: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbound", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
            try body.write(to: file, options: .atomic)
            return file
        } catch {
            throw UploadError.staging(String(describing: error))
        }
    }
}

// MARK: - Delegate

extension Uploader: URLSessionDataDelegate {
    public func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let carried = inFlightDays.removeValue(forKey: task.taskIdentifier)
        if let staged = stagedFiles.removeValue(forKey: task.taskIdentifier) {
            try? FileManager.default.removeItem(at: staged)
        }

        if let error {
            // Nothing to undo: the day is still marked, so it goes again next
            // pass. Retrying here would only fight the system's own backoff.
            log.error("upload failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let response = task.response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(response.statusCode) else {
            let detail = String(data: body, encoding: .utf8) ?? ""
            log.error("service answered \(response.statusCode): \(detail, privacy: .public)")
            return
        }
        guard let carried else { return }

        do {
            try store.recordSent(
                day: carried.day, digest: carried.digest, sampleIdentifiers: carried.identifiers
            )
            didStoreDay?()

            // Only when nothing else is in the air. Starting the next pass while
            // days from this one are still flying would build them again and
            // send duplicates of work already under way.
            if inFlightDays.isEmpty {
                Task { [weak self] in _ = try? await self?.send() }
            }
        } catch {
            log.error("could not record \(carried.day, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let finished = backgroundEventsFinished
        DispatchQueue.main.async { finished?() }
    }
}
