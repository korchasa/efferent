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
        /// How often the archive is asked what it actually holds.
        ///
        /// Once a day, because the check is worth what it costs at that rate
        /// and not at a higher one: a decade of days is six requests and about
        /// two hundred kilobytes, which is nothing daily and real hourly. It
        /// never runs mid-backfill either — the first pass does it and the next
        /// twenty-four hours of passes go straight to sending.
        public let reconcileEvery: TimeInterval
        public let sessionIdentifier: String

        public init(
            daysPerPass: Int = 31,
            daysPerRequest: Int = Batch.maxDaysPerRequest,
            bytesPerRequest: Int = 4 * 1024 * 1024,
            concurrentUploads: Int = 4,
            reconcileEvery: TimeInterval = 24 * 60 * 60,
            sessionIdentifier: String = "dev.korchasa.efferent.upload"
        ) {
            self.daysPerPass = daysPerPass
            self.daysPerRequest = min(daysPerRequest, Batch.maxDaysPerRequest)
            self.bytesPerRequest = bytesPerRequest
            self.concurrentUploads = concurrentUploads
            self.reconcileEvery = reconcileEvery
            self.sessionIdentifier = sessionIdentifier
        }
    }

    public enum Outcome: Equatable {
        case nothingToSend
        /// `days` went up; `unchanged` were rebuilt, found identical to what the
        /// archive already holds, and cost nothing.
        case scheduled(days: Int, unchanged: Int)
        case alreadyInFlight
        /// Held back on purpose. The days stay marked, so nothing is lost by
        /// stopping and nothing has to be rebuilt to start again.
        case stopped
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
    /// Compares the archive with what should be in it and owes back whatever is
    /// missing, answering how many days that was. Injected rather than done here
    /// because working out which days *should* exist is a question for Health,
    /// and this type knows only about sending.
    private let reconcile: () async throws -> Int
    private let log = Log(category: "upload")

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

    /// Sending held back on purpose.
    ///
    /// It lives here rather than only in the app because the chain restarts
    /// itself: every finished batch starts the next pass from the session's own
    /// delegate, far away from whatever the person last pressed. A flag checked
    /// only on the way in would stop the button and let the chain run on.
    private let stopLock = NSLock()
    private var stopped = false

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
        build: @escaping ([String]) async throws -> [String: DayContents],
        reconcile: @escaping () async throws -> Int = { 0 }
    ) {
        self.configuration = configuration
        self.destination = destination
        self.store = store
        self.identity = identity
        self.build = build
        self.reconcile = reconcile
        super.init()
    }

    /// Hold sending back, or let it go again.
    ///
    /// Stopping also cancels what is already in the air, because a request the
    /// system has taken finishes on its own otherwise — a stop that let a month
    /// keep landing is not a stop. A cancelled batch fails like any other: its
    /// days are still marked and go again on the next pass.
    public func setStopped(_ value: Bool) {
        stopLock.lock()
        let changed = stopped != value
        stopped = value
        stopLock.unlock()
        guard changed, value else { return }
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    /// Build the next days and hand the changed ones to the system.
    public func send() async throws -> Outcome {
        guard !isStopped else { return .stopped }
        guard claimPass() else { return .alreadyInFlight }
        defer { releasePass() }

        await checkTheArchive()

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

    /// Ask the archive what it holds before deciding there is nothing to send.
    ///
    /// Before, not after, because "nothing waiting" is the answer this is meant
    /// to distrust: a day whose fingerprint matches an archive that has since
    /// lost it looks exactly like a day that is safely stored.
    ///
    /// Failing is not a reason to stop. The listing may be unreachable in
    /// exactly the conditions where sending still works, and the day is only
    /// stamped when the check actually completed — so a run that failed is
    /// simply due again next pass rather than skipped for a day.
    private func checkTheArchive() async {
        do {
            if let last = try store.lastReconciledAt(),
               Date().timeIntervalSince(last) < configuration.reconcileEvery
            {
                return
            }
            let owed = try await reconcile()
            try store.recordReconciled()
            if owed > 0 {
                log.error("the archive was missing \(owed) days; they go again now")
            }
        } catch {
            log.error("could not check the archive: \(String(describing: error))")
        }
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
        log.info(
            "request \(task.taskIdentifier) handed to the system: \(batch.count) days "
                + "(\(batch.first?.day ?? "") … \(batch.last?.day ?? "")), \(body.count) bytes"
        )
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
            log.error("request \(task.taskIdentifier) failed: \(error.localizedDescription)")
            return
        }
        guard let response = task.response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(response.statusCode) else {
            let detail = String(data: body, encoding: .utf8) ?? ""
            log.error("request \(task.taskIdentifier) answered \(response.statusCode): \(detail)")
            return
        }
        guard let carried else { return }

        // Written down only for the days the answer names. A batch is not a
        // promise that every day in it landed, and marking one clean that the
        // service never stored would lose it in a way nothing later could
        // notice — the day would simply never be sent again.
        guard let accepted = try? JSONDecoder().decode(Accepted.self, from: body) else {
            log.error(
                "could not read what the service stored: \(String(data: body, encoding: .utf8) ?? "")"
            )
            return
        }
        let stored = Set(accepted.stored)
        for entry in carried where !stored.contains(entry.day) {
            log.error("the service did not store \(entry.day); it stays marked")
        }

        log.info(
            "request \(task.taskIdentifier) answered \(response.statusCode): the archive "
                + "took \(stored.count) of \(carried.count) days"
        )

        for entry in carried where stored.contains(entry.day) {
            do {
                try store.recordSent(
                    day: entry.day, digest: entry.digest, sampleIdentifiers: entry.identifiers
                )
            } catch {
                log.error("could not record \(entry.day): \(String(describing: error))")
            }
        }
        didStoreDay?()

        // Only when nothing else is in the air. Starting the next pass while
        // days from this one are still flying would build them again and send
        // duplicates of work already under way.
        // …and not at all while sending is held back: this is the path a pause
        // has to close, because it starts the next pass from the session rather
        // than from anything the person pressed.
        if inFlightBatches.isEmpty, !isStopped {
            Task { [weak self] in _ = try? await self?.send() }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let finished = backgroundEventsFinished
        DispatchQueue.main.async { finished?() }
    }
}
