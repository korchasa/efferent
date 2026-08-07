import Foundation
import os

/// Ships the outbox to the endpoint and moves the confirmation mark on success.
///
/// Three decisions shape everything here.
///
/// **A background session, not an ordinary one.** The upload is usually started
/// from a HealthKit delivery that woke the app for a couple of seconds. An
/// ordinary `URLSession` task dies with the process; a background one is handed
/// to a system daemon that finishes it and relaunches the app to report back.
///
/// **The body goes through a file.** Background sessions reject the in-memory
/// `uploadTask(with:from:)` — the daemon has to be able to read the body after
/// this process is gone, so it must exist on disk.
///
/// **The server decides what counted.** The confirmation mark moves to the `ack`
/// in the response, not to the highest sequence number we happened to send. A
/// server that accepted half a batch reports half, and the rest is sent again.
public final class Uploader: NSObject {
    public struct Configuration {
        public let endpoint: URL
        /// Lines per request. Enough to be worth a round trip, small enough to
        /// finish inside a background window on a bad connection.
        public let batchSize: Int
        public let sessionIdentifier: String
        /// How long confirmed rows stay for change detection. Must comfortably
        /// exceed the daily re-scan window, which is a week.
        public let retention: TimeInterval

        public init(
            endpoint: URL,
            batchSize: Int = 500,
            sessionIdentifier: String = "dev.korchasa.efferent.upload",
            retention: TimeInterval = 30 * 24 * 60 * 60
        ) {
            self.endpoint = endpoint
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
        case missingToken
        case staging(String)
    }

    private let configuration: Configuration
    private let store: Store
    private let tokens: TokenStore
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "upload")

    /// Response bodies accumulate here between `didReceive data` and completion,
    /// keyed by task. Only ever touched on `delegateQueue`, which is serial.
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

    public init(configuration: Configuration, store: Store, tokens: TokenStore = TokenStore()) {
        self.configuration = configuration
        self.store = store
        self.tokens = tokens
        super.init()
    }

    /// Hand the next batch to the system. Returns as soon as it is queued.
    public func send() async throws -> Outcome {
        guard await inFlightCount() == 0 else { return .alreadyInFlight }

        let batch = try store.pending(limit: configuration.batchSize)
        guard !batch.isEmpty else { return .nothingToSend }

        guard let token = try tokens.read() else { throw UploadError.missingToken }

        let body = try NDJSON.body(batch)
        let file = try stage(body)

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let task = session.uploadTask(with: request, fromFile: file)
        stagedFiles[task.taskIdentifier] = file
        task.resume()

        let through = batch[batch.count - 1].seq
        log.info("queued \(batch.count) lines through seq \(through)")
        return .scheduled(lines: batch.count, throughSeq: through)
    }

    /// Restart a transfer that the system reported as finished while the app was
    /// not running. Call from `application(_:handleEventsForBackgroundURLSession:)`.
    public func adoptBackgroundSession() {
        _ = session
    }

    private func inFlightCount() async -> Int {
        await session.allTasks.count
    }

    private func stage(_ body: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outbound", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("ndjson")
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
        guard (200..<300).contains(response.statusCode) else {
            log.error("endpoint answered \(response.statusCode)")
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

/// What the endpoint answers: the highest sequence number it has durably stored.
struct Acknowledgement: Decodable {
    let ack: Int64
}
