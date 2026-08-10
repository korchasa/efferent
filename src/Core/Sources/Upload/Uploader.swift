import CryptoKit
import Foundation
import os

/// Ships the outbox to the bucket and moves the confirmation mark on success.
///
/// Four decisions shape everything here.
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
/// **The batch is sealed before it is staged.** What lands in the temporary file
/// is already ciphertext, so even that momentary copy tells nobody anything.
///
/// **The service decides what counted.** The confirmation mark moves to the
/// `ack` in the response, not to the highest sequence number we happened to
/// send. A service that accepted half a batch reports half, and the rest goes
/// again.
///
/// **One acknowledged batch pulls the next.** A send ships `batchSize` lines and
/// no more, so without this the outbox would only drain as fast as something
/// else asked it to — which during the first export looks exactly like a stall
/// at a round number. The chain stops the moment a batch fails or the service
/// stops moving its mark, so a service stuck on one number cannot be hammered.
public final class Uploader: NSObject {
    public struct Configuration {
        /// Lines per request. Enough to be worth a round trip, small enough to
        /// finish inside a background window on a bad connection.
        public let batchSize: Int
        public let sessionIdentifier: String
        /// How long confirmed rows stay for change detection. Must comfortably
        /// exceed the daily re-scan window, which is a week.
        public let retention: TimeInterval

        public init(
            batchSize: Int = 500,
            sessionIdentifier: String = "dev.korchasa.efferent.upload",
            retention: TimeInterval = 30 * 24 * 60 * 60
        ) {
            self.batchSize = batchSize
            self.sessionIdentifier = sessionIdentifier
            self.retention = retention
        }
    }

    public enum Outcome: Equatable {
        case nothingToSend
        case scheduled(lines: Int, throughSeq: Int64)
        case alreadyInFlight
    }

    public enum UploadError: Error, Equatable {
        case staging(String)
        case emptyBatch
        /// The archive could not say how far it goes, so where to start counting
        /// is unknown. Sending anyway is what silently loses a batch.
        case archiveUnreachable(Int)
    }

    private let configuration: Configuration
    private let destination: Destination
    private let store: Store
    private let identity: DeviceIdentity
    private let archiveHighestSeq: (Destination) async throws -> Int64
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "upload")

    /// Touched only on `delegateQueue`, which is serial.
    private var responseBodies: [Int: Data] = [:]
    private var stagedFiles: [Int: URL] = [:]

    /// Handed over by the app when iOS relaunches it to deliver finished
    /// transfers; called once the session says it has reported everything.
    public var backgroundEventsFinished: (() -> Void)?

    /// Called after every acknowledgement, so a screen showing the counters can
    /// follow along. The confirmation mark moves on the session's delegate
    /// queue, far away from any view, and without this the numbers on screen
    /// only change when the screen happens to reappear.
    public var didAcknowledge: (() -> Void)?

    /// Guards against two batches in the air at once. A flag rather than a look
    /// at `session.allTasks`, because the next batch is started from the
    /// completion of the previous one, and at that moment the finished task may
    /// still be listed — which would refuse the send and leave the outbox
    /// standing.
    private let inFlightLock = NSLock()
    private var inFlight = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: configuration.sessionIdentifier)
        // The data is small and the point of the app is freshness, so let it go
        // as soon as there is a network rather than waiting for a charger.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    public init(
        configuration: Configuration = Configuration(),
        destination: Destination,
        store: Store,
        identity: DeviceIdentity = DeviceIdentity(),
        // Injectable so a test can exercise the send path without a service to
        // ask. Nothing else overrides it.
        archiveHighestSeq: @escaping (Destination) async throws -> Int64 = Uploader.highestSeq
    ) {
        self.configuration = configuration
        self.destination = destination
        self.store = store
        self.identity = identity
        self.archiveHighestSeq = archiveHighestSeq
        super.init()
    }

    /// Hand the next batch to the system. Returns as soon as it is queued.
    public func send() async throws -> Outcome {
        // Where to start counting, before anything is counted. A reinstalled app
        // begins at 1 again and would claim ranges the archive already has —
        // which the service answers with an `ack` and then quietly ignores,
        // because its stored batches cannot be rewritten. This throws when the
        // archive cannot be reached: sending on a guess is what loses data.
        if try store.stats().acknowledgedSeq == 0 {
            try await store.adoptNumbering(after: archiveHighestSeq(destination))
        }

        // A transfer the daemon carried on with while the app was dead is still
        // running, and only shows up here.
        let carriedOver = await session.allTasks.contains {
            $0.state == .running || $0.state == .suspended
        }
        guard claimInFlight(unless: carriedOver) else { return .alreadyInFlight }

        do {
            let batch = try store.pending(limit: configuration.batchSize)
            guard let first = batch.first, let last = batch.last else {
                releaseInFlight()
                return .nothingToSend
            }

            let body = try seal(batch, seqFrom: first.seq, seqTo: last.seq)
            let file = try stage(body)
            let request = try signedRequest(body: body, seqFrom: first.seq, seqTo: last.seq)

            let task = session.uploadTask(with: request, fromFile: file)
            stagedFiles[task.taskIdentifier] = file
            task.resume()

            log.info("queued \(batch.count) lines through seq \(last.seq)")
            return .scheduled(lines: batch.count, throughSeq: last.seq)
        } catch {
            releaseInFlight()
            throw error
        }
    }

    private func claimInFlight(unless carriedOver: Bool) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        guard !inFlight, !carriedOver else { return false }
        inFlight = true
        return true
    }

    private func releaseInFlight() {
        inFlightLock.lock()
        inFlight = false
        inFlightLock.unlock()
    }

    /// The highest sequence number the archive holds, or 0 if it holds nothing.
    ///
    /// An ordinary session on purpose: this is a small GET whose answer decides
    /// the very next step, while a background session hands its response to a
    /// delegate at some unrelated later moment.
    public static func highestSeq(of destination: Destination) async throws -> Int64 {
        let (data, response) = try await URLSession.shared.data(from: destination.statsURL)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw UploadError.archiveUnreachable((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ArchiveStats.self, from: data).highestSeq
    }

    /// Restart a transfer the system reported as finished while the app was not
    /// running. Call from `application(_:handleEventsForBackgroundURLSession:)`.
    public func adoptBackgroundSession() {
        _ = session
    }

    // MARK: - Building a request

    private func seal(_ batch: [PendingEvent], seqFrom: Int64, seqTo: Int64) throws -> Data {
        let lines = try NDJSON.body(batch)
        guard !lines.isEmpty else { throw UploadError.emptyBatch }

        let sealed = try SealedBox.seal(
            readingPublicKey: destination.readingPublicKey,
            plaintext: Deflate.compress(lines),
            associatedData: CanonicalRequest.associatedData(
                bucket: destination.bucket, seqFrom: seqFrom, seqTo: seqTo
            )
        )
        // The manifest goes inside the body, so the signature over the body
        // covers it. Sent beside it, it would be something a network could
        // rewrite without breaking anything visible.
        return try Manifest.body(entries: Manifest.entries(for: batch), sealed: sealed)
    }

    private func signedRequest(body: Data, seqFrom: Int64, seqTo: Int64) throws -> URLRequest {
        let key = try identity.signingKey()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = try key.signature(
            for: CanonicalRequest.bytes(
                bucket: destination.bucket,
                seqFrom: seqFrom,
                seqTo: seqTo,
                timestamp: timestamp,
                body: body
            )
        )

        var request = URLRequest(url: destination.uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(seqFrom), forHTTPHeaderField: "x-efferent-seq-from")
        request.setValue(String(seqTo), forHTTPHeaderField: "x-efferent-seq-to")
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
        if let staged = stagedFiles.removeValue(forKey: task.taskIdentifier) {
            try? FileManager.default.removeItem(at: staged)
        }
        // Before anything that can return early, or the next batch can never
        // start and the outbox stands still until something else prods it.
        releaseInFlight()

        if let error {
            // Nothing to undo: the mark has not moved, so the same lines go out
            // next time. Retrying here would only fight the system's own backoff.
            log.error("upload failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let response = task.response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(response.statusCode) else {
            let detail = String(data: body, encoding: .utf8) ?? ""
            log.error("service answered \(response.statusCode): \(detail, privacy: .public)")
            return
        }

        do {
            let markBefore = try store.stats().acknowledgedSeq
            let ack = try JSONDecoder().decode(Acknowledgement.self, from: body)
            try store.acknowledge(through: ack.ack)
            let removed = try store.prune(confirmedBefore: Date().addingTimeInterval(-configuration.retention))
            let after = try store.stats()
            log.info("confirmed through seq \(ack.ack), pruned \(removed) rows, \(after.pending) waiting")
            didAcknowledge?()

            // Only chain on real progress. A service that keeps answering with
            // the same number would otherwise be sent the same batch forever,
            // as fast as the network allows.
            if ack.ack > markBefore, after.pending > 0 {
                Task { [weak self] in _ = try? await self?.send() }
            }
        } catch {
            log.error("could not apply acknowledgement: \(String(describing: error), privacy: .public)")
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let finished = backgroundEventsFinished
        DispatchQueue.main.async { finished?() }
    }
}

/// What the service answers: the highest sequence number it has durably stored.
struct Acknowledgement: Decodable {
    let ack: Int64
}

/// The part of `/stats` this side cares about. The rest — object count, bytes —
/// is for a person looking at the archive, not for the phone.
struct ArchiveStats: Decodable {
    let highestSeq: Int64
}
