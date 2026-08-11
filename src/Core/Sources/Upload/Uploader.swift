import CryptoKit
import Foundation
import os

/// Puts days into the bucket, a batch of them per request.
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
/// **Days are sealed before they are staged.** What lands in the temporary file
/// is already ciphertext, so even that momentary copy tells nobody anything.
/// Each day is sealed on its own with its own date bound into the tag; the
/// batch around them is only a way of travelling.
///
/// **Days share a request because the request is what costs.** A day is a few
/// kilobytes and a decade is thousands of them, so one request each would be a
/// phone spending its whole waking life on round trips. A month goes at a time,
/// and the answer names the days that landed — the ones it does not name stay
/// marked and go again.
///
/// **An unchanged day never goes.** A day is built, then its plaintext is
/// fingerprinted and compared with what the service last accepted. Re-reading
/// the last week on every refresh therefore costs a few Health queries and no
/// network at all. The fingerprint is of the plaintext, not of what goes on the
/// wire: sealing uses a fresh throwaway key every time, so two identical days
/// never produce the same bytes.
///
/// **Days are independent, so nothing has to be kept in order.** A day either
/// arrived or it did not, and the one that did not is still marked. That is what
/// makes the first export minutes rather than an hour.
public final class Uploader: NSObject {
    public struct Configuration {
        /// Days built in one pass. They are read from Health as a single span,
        /// so this is mostly about how much work is redone if the app is
        /// suspended halfway.
        public let daysPerPass: Int
        /// Days packed into one request. Never above `Batch.maxDaysPerRequest`,
        /// which is what the far side will take.
        public let daysPerRequest: Int
        /// Where a batch is cut short regardless of how few days are in it. A
        /// single day over this goes on its own rather than being dropped —
        /// there is no size at which a day stops being owed.
        public let bytesPerRequest: Int
        /// Requests in the air at once.
        public let concurrentUploads: Int
        public let sessionIdentifier: String

        public init(
            daysPerPass: Int = 31,
            daysPerRequest: Int = Batch.maxDaysPerRequest,
            bytesPerRequest: Int = 4 * 1024 * 1024,
            concurrentUploads: Int = 4,
            sessionIdentifier: String = "dev.korchasa.efferent.upload"
        ) {
            self.daysPerPass = daysPerPass
            self.daysPerRequest = min(daysPerRequest, Batch.maxDaysPerRequest)
            self.bytesPerRequest = bytesPerRequest
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

    /// A day that is on its way: what to write down once the service says it
    /// took it, and the ciphertext it is going as.
    struct Sending {
        let day: String
        let digest: Data
        let identifiers: [UUID]
        let blob: Data
    }

    /// What the service answers a batch with. The days it names are the ones
    /// that are now in the archive; a day missing from the list stays marked.
    private struct Accepted: Decodable {
        let stored: [String]
    }

    private let configuration: Configuration
    private let destination: Destination
    private let store: Store
    private let identity: DeviceIdentity
    private let build: ([String]) async throws -> [String: DayContents]
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "upload")

    /// Touched only on `delegateQueue`, which is serial.
    private var inFlightBatches: [Int: [Sending]] = [:]
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
        var pending: [Sending] = []
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

            try pending.append(Sending(
                day: day,
                digest: digest,
                identifiers: content.sampleIdentifiers,
                blob: SealedBox.seal(
                    readingPublicKey: destination.readingPublicKey,
                    plaintext: Deflate.compress(plaintext),
                    associatedData: CanonicalRequest.associatedData(
                        bucket: destination.bucket, day: day
                    )
                )
            ))
        }

        let batches = Self.batches(pending, configuration: configuration)
        for batch in batches {
            try schedule(batch)
        }

        log.info(
            "pass over \(days.count) days: \(pending.count) sending in \(batches.count) requests, \(unchanged) unchanged"
        )
        return pending.isEmpty && unchanged == 0
            ? .nothingToSend
            : .scheduled(days: pending.count, unchanged: unchanged)
    }

    /// Cut the days into requests.
    ///
    /// Ascending, because that is the order a frame is packed in — days chosen
    /// newest first, then sent oldest first within the batch. A day too big for
    /// the byte limit travels alone rather than being held back: there is no
    /// size at which a day stops being owed, and a batch that silently skipped
    /// one would leave it marked forever.
    static func batches(_ pending: [Sending], configuration: Configuration) -> [[Sending]] {
        var batches: [[Sending]] = []
        var current: [Sending] = []
        var bytes = 0

        for entry in pending.sorted(by: { $0.day < $1.day }) {
            let full = current.count >= configuration.daysPerRequest
                || bytes + entry.blob.count > configuration.bytesPerRequest
            if full, !current.isEmpty {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(entry)
            bytes += entry.blob.count
        }
        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    private func schedule(_ batch: [Sending]) throws {
        let body = try Batch.pack(
            batch.map { Batch.SealedDay(day: $0.day, blob: $0.blob) }
        )
        let file = try stage(body)
        let request = try signedRequest(days: batch.map(\.day), body: body)
        let task = session.uploadTask(with: request, fromFile: file)
        inFlightBatches[task.taskIdentifier] = batch
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

    private func signedRequest(days: [String], body: Data) throws -> URLRequest {
        let key = try identity.signingKey()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = try key.signature(
            for: CanonicalRequest.bytes(
                bucket: destination.bucket, days: days, timestamp: timestamp, body: body
            )
        )

        var request = URLRequest(url: destination.daysURL)
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
        let carried = inFlightBatches.removeValue(forKey: task.taskIdentifier)
        if let staged = stagedFiles.removeValue(forKey: task.taskIdentifier) {
            try? FileManager.default.removeItem(at: staged)
        }

        if let error {
            // Nothing to undo: the days are still marked, so they go again next
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

        // Written down only for the days the answer names. A batch is not a
        // promise that every day in it landed, and marking one clean that the
        // service never stored would lose it in a way nothing later could
        // notice — the day would simply never be sent again.
        guard let accepted = try? JSONDecoder().decode(Accepted.self, from: body) else {
            log.error(
                "could not read what the service stored: \(String(data: body, encoding: .utf8) ?? "", privacy: .public)"
            )
            return
        }
        let stored = Set(accepted.stored)
        for entry in carried where !stored.contains(entry.day) {
            log.error("the service did not store \(entry.day, privacy: .public); it stays marked")
        }

        for entry in carried where stored.contains(entry.day) {
            do {
                try store.recordSent(
                    day: entry.day, digest: entry.digest, sampleIdentifiers: entry.identifiers
                )
            } catch {
                log.error("could not record \(entry.day, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        didStoreDay?()

        // Only when nothing else is in the air. Starting the next pass while
        // days from this one are still flying would build them again and send
        // duplicates of work already under way.
        if inFlightBatches.isEmpty {
            Task { [weak self] in _ = try? await self?.send() }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let finished = backgroundEventsFinished
        DispatchQueue.main.async { finished?() }
    }
}
