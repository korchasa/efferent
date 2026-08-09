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
    }

    private let configuration: Configuration
    private let destination: Destination
    private let store: Store
    private let identity: DeviceIdentity
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "upload")

    /// Touched only on `delegateQueue`, which is serial.
    private var responseBodies: [Int: Data] = [:]
    private var stagedFiles: [Int: URL] = [:]

    /// Handed over by the app when iOS relaunches it to deliver finished
    /// transfers; called once the session says it has reported everything.
    public var backgroundEventsFinished: (() -> Void)?

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
        identity: DeviceIdentity = DeviceIdentity()
    ) {
        self.configuration = configuration
        self.destination = destination
        self.store = store
        self.identity = identity
        super.init()
    }

    /// Hand the next batch to the system. Returns as soon as it is queued.
    public func send() async throws -> Outcome {
        guard await session.allTasks.isEmpty else { return .alreadyInFlight }

        let batch = try store.pending(limit: configuration.batchSize)
        guard let first = batch.first, let last = batch.last else { return .nothingToSend }

        let body = try seal(batch, seqFrom: first.seq, seqTo: last.seq)
        let file = try stage(body)
        let request = try signedRequest(body: body, seqFrom: first.seq, seqTo: last.seq)

        let task = session.uploadTask(with: request, fromFile: file)
        stagedFiles[task.taskIdentifier] = file
        task.resume()

        log.info("queued \(batch.count) lines through seq \(last.seq)")
        return .scheduled(lines: batch.count, throughSeq: last.seq)
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

        return try SealedBox.seal(
            readingPublicKey: destination.readingPublicKey,
            plaintext: try Deflate.compress(lines),
            associatedData: CanonicalRequest.associatedData(
                bucket: destination.bucket, seqFrom: seqFrom, seqTo: seqTo
            )
        )
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
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        if let staged = stagedFiles.removeValue(forKey: task.taskIdentifier) {
            try? FileManager.default.removeItem(at: staged)
        }

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
            let ack = try JSONDecoder().decode(Acknowledgement.self, from: body)
            try store.acknowledge(through: ack.ack)
            let removed = try store.prune(confirmedBefore: Date().addingTimeInterval(-configuration.retention))
            log.info("confirmed through seq \(ack.ack), pruned \(removed) rows")
        } catch {
            log.error("could not apply acknowledgement: \(String(describing: error), privacy: .public)")
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let finished = backgroundEventsFinished
        DispatchQueue.main.async { finished?() }
    }
}

/// What the service answers: the highest sequence number it has durably stored.
struct Acknowledgement: Decodable {
    let ack: Int64
}
