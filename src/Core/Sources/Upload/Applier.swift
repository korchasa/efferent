import CryptoKit
import Foundation
import os

/// Takes an agent's edits out of the queue and writes them into Health.
///
/// **The queue is the service's `e/` prefix, and nothing else.** There is no
/// cursor to keep in step: an edit is listed until the phone has answered it,
/// and the answer is what takes it out. A run that dies halfway leaves the
/// edit where it was, and the next run applies it again — which HealthKit
/// makes safe, because a sample carries the agent's id as its sync identifier
/// and a version that only climbs, so the second write replaces the first
/// rather than standing beside it.
///
/// **The phone checks the editor's signature itself.** The service checked it
/// on the way in, to keep strangers out of the queue; the phone checks it
/// again because a service that decided on its own what goes into Health
/// would be able to write into Health. Only then is the edit opened with the
/// reading key, which never leaves the phone and the agent.
///
/// **An edit never becomes a day on the wire.** What it changed is marked, and
/// the uploader reads those days out of Health whole and sends them like any
/// other. The archive keeps holding what Health says, not what was asked for.
///
/// **A bad edit is answered, not left.** One the phone cannot verify, open or
/// read is answered with a single refusal and leaves the queue like any other:
/// a queue blocked forever by one bad edit is worse than a bad edit answered.
/// A failure to *deliver* the answer is different, and stops the run — the
/// edit stays, and is applied again next time.
public final class Applier {
    /// Edits taken in one run. A run happens at the head of every pass, so a
    /// long queue is walked a launch at a time rather than in one that the
    /// system cuts short.
    public static let maxEditsPerRun = 50
    /// Edits asked for per listing page. The service caps the page anyway.
    public static let pageSize = 200
    /// Enough pages for the queue's own ceiling several times over; a service
    /// answering nonsense ends the walk loudly rather than spinning.
    public static let maxPages = 20

    public struct Applied: Equatable, Sendable {
        public var edits = 0
        public var items = 0
        public var refused = 0
        /// The days Health changed on, to be marked and rebuilt.
        public var days: Set<String> = []
        /// Why the run stopped before the queue was empty, when it did. The
        /// days above are still real and still owed: a run that lost the
        /// network after writing a meal has still written the meal.
        public var stoppedBy: String?

        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        case nothingWaiting
        case applied(Applied)
        /// Another run holds the pass; this one did nothing.
        case busy
        /// Some writable type has never been asked about. The system sheet has
        /// to be shown first, and only a launch with a screen can do that; the
        /// edits wait, unread.
        case notAsked
    }

    public enum ApplyError: Error, Equatable {
        case refused(status: Int, message: String)
        case malformed(String)
        case tooManyPages
    }

    /// What the service answered a request with.
    public struct Answer: Sendable {
        public let status: Int
        public let body: Data
        /// Header names in lower case.
        public let headers: [String: String]

        public init(status: Int, body: Data, headers: [String: String]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    public typealias Fetch = (URLRequest) async throws -> Answer

    private let destination: Destination
    private let identity: DeviceIdentity
    private let readingKey: () throws -> Curve25519.KeyAgreement.PrivateKey
    private let editorPublicKey: () throws -> Data
    private let store: Store
    private let writer: any HealthWriter
    private let fetch: Fetch
    private let now: () -> Date
    private let maxEdits: Int
    private let log = Log(category: "apply")

    /// One run at a time, released on every path out of `run()`. A flag a
    /// `return` can slip past stops applying until the app is relaunched.
    private let passLock = NSLock()
    private var running = false

    public init(
        destination: Destination,
        identity: DeviceIdentity,
        readingKey: @escaping () throws -> Curve25519.KeyAgreement.PrivateKey,
        editorPublicKey: @escaping () throws -> Data,
        store: Store,
        writer: any HealthWriter,
        fetch: @escaping Fetch,
        now: @escaping () -> Date = Date.init,
        maxEdits: Int = Applier.maxEditsPerRun
    ) {
        self.destination = destination
        self.identity = identity
        self.readingKey = readingKey
        self.editorPublicKey = editorPublicKey
        self.store = store
        self.writer = writer
        self.fetch = fetch
        self.now = now
        self.maxEdits = maxEdits
    }

    /// The default transport: an ordinary session with a timeout, like the
    /// archive check. This runs at the head of a pass and its answers are
    /// needed before anything can be decided, so a background session would be
    /// no use, and a timeout keeps a dead network from holding up the send.
    public static func session(timeout: TimeInterval = 20) -> Fetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApplyError.malformed("no HTTP response")
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String {
                    headers[name.lowercased()] = value
                }
            }
            return Answer(status: http.statusCode, body: data, headers: headers)
        }
    }

    // MARK: - A run

    public func run() async throws -> Outcome {
        guard claimPass() else { return .busy }
        defer { releasePass() }

        // Asked before the queue is read: an edit fetched now would be refused
        // item by item as unauthorized, and it is not — nobody has been asked.
        guard !writer.writeAccessUndecided() else { return .notAsked }

        let waiting = try await pending()
        guard !waiting.isEmpty else { return .nothingWaiting }

        var applied = Applied()
        let started = now()
        for name in waiting {
            do {
                try await apply(name, into: &applied)
            } catch {
                // The days touched so far are real: the caller marks them
                // whatever stopped the run. What stopped it is said once here.
                applied.stoppedBy = String(describing: error)
                log.error("applying stopped at \(name): \(applied.stoppedBy ?? "")")
                break
            }
        }
        log.info(
            "applied \(applied.edits) edits, \(applied.items) items, \(applied.refused) refused, "
                + "\(applied.days.count) days to rebuild, in \(Uploader.milliseconds(since: started)) ms"
        )
        return .applied(applied)
    }

    /// The names waiting, in the order the service took them, up to this run's
    /// share of them.
    private func pending() async throws -> [String] {
        var names: [String] = []
        var after: String?
        for _ in 0 ..< Self.maxPages {
            let url = destination.editsURL(after: after, limit: Self.pageSize)
            let answer = try await fetch(URLRequest(url: url))
            guard (200 ..< 300).contains(answer.status) else {
                throw ApplyError.refused(status: answer.status, message: Uploader.said(answer.body))
            }
            let page: Listing
            do {
                page = try JSONDecoder().decode(Listing.self, from: answer.body)
            } catch {
                throw ApplyError.malformed("the listing did not parse: \(error)")
            }
            for entry in page.edits {
                // Checked before it goes into a path: a listing that came back
                // wrong must not send this phone somewhere else.
                guard EditName.isValid(entry.name) else {
                    throw ApplyError.malformed("the listing named \(entry.name.prefix(40))")
                }
                names.append(entry.name)
                if names.count >= maxEdits {
                    return names
                }
            }
            guard let next = page.next else { return names }
            after = next
        }
        throw ApplyError.tooManyPages
    }

    private struct Listing: Decodable {
        struct Entry: Decodable {
            let name: String
        }

        let edits: [Entry]
        let next: String?
    }

    private struct Result {
        let applied: Int
        let refused: [Efferent.Outcome.Refusal]
        let days: Set<String>
    }

    /// One edit: fetched, checked, opened, applied, answered. Nothing is
    /// counted when the service no longer has it — answered from another
    /// launch, or gone. The days are added before the answer is sent, so a
    /// run that stops on the answer still hands them back to be rebuilt.
    private func apply(_ name: String, into applied: inout Applied) async throws {
        let request = try signed(destination.editURL(name), method: "GET", body: nil) { timestamp in
            CanonicalRequest.fetch(bucket: destination.bucket, name: name, timestamp: timestamp)
        }
        let answer = try await fetch(request)
        if answer.status == 410 || answer.status == 404 {
            log.debug("\(name): no longer in the queue (\(answer.status))")
            return
        }
        guard (200 ..< 300).contains(answer.status) else {
            throw ApplyError.refused(status: answer.status, message: Uploader.said(answer.body))
        }

        let result: Result
        switch try open(answer) {
        case let .items(items):
            result = try await write(items)
        case let .refused(code):
            log.debug("\(name): refused whole, \(code.rawValue)")
            result = Result(applied: 0, refused: [.init(item: 0, code: code)], days: [])
        }

        applied.days.formUnion(result.days)
        try await report(name, Efferent.Outcome(applied: result.applied, refused: result.refused))
        applied.edits += 1
        applied.items += result.applied + result.refused.count
        applied.refused += result.refused.count
        log.debug(
            "\(name): \(answer.body.count) bytes, \(result.applied) applied"
                + (result.refused.isEmpty
                    ? "" : ", refused " + result.refused.map { "\($0.item):\($0.code.rawValue)" }.joined(separator: " "))
        )
    }

    private enum Opened {
        case items([EditItem])
        case refused(OutcomeCode)
    }

    /// The editor's signature, then the seal, then the shape. Each failure is
    /// a word the outcome can carry.
    private func open(_ answer: Answer) throws -> Opened {
        guard let editor = answer.headers["x-efferent-editor"],
              let signature = answer.headers["x-efferent-signature"],
              let stamp = answer.headers["x-efferent-timestamp"], let timestamp = Int64(stamp),
              try Base64URL.decode(editor) == editorPublicKey(),
              EditorSignature.verify(
                  publicKey: Base64URL.decode(editor),
                  signature: Base64URL.decode(signature),
                  message: CanonicalRequest.edit(
                      bucket: destination.bucket, timestamp: timestamp, sealed: answer.body
                  )
              )
        else {
            return .refused(.badSignature)
        }
        let plaintext: Data
        do {
            plaintext = try SealedBox.open(
                readingPrivateKey: readingKey(),
                blob: answer.body,
                associatedData: CanonicalRequest.associatedData(editBucket: destination.bucket)
            )
        } catch {
            return .refused(.cannotOpen)
        }
        do {
            return try .items(EditBatch.unpack(plaintext))
        } catch {
            return .refused(.malformed)
        }
    }

    /// The items, in order. A refusal is written down and the next item goes;
    /// anything else — a locked phone, a ledger that will not write — stops
    /// the run, and the edit is applied again next time.
    private func write(_ items: [EditItem]) async throws -> Result {
        var applied = 0
        var refused: [Efferent.Outcome.Refusal] = []
        var days: Set<String> = []
        for (index, item) in items.enumerated() {
            do {
                switch item {
                case let .put(put):
                    let version = try store.nextVersion(for: put.id)
                    try days.formUnion(await writer.apply(put, version: version))
                case let .delete(id):
                    try days.formUnion(await writer.remove(id: id))
                    try store.forgetWritten(id)
                }
                applied += 1
            } catch let WriteRefused.code(code) {
                refused.append(.init(item: index, code: code))
            }
        }
        return Result(applied: applied, refused: refused, days: days)
    }

    /// Tell the service what became of the edit. The service replaces the edit
    /// with this, so an answer that did not land leaves the edit in the queue,
    /// and that is the right place for it.
    private func report(_ name: String, _ outcome: Efferent.Outcome) async throws {
        let body = try outcome.encoded()
        let request = try signed(destination.outcomeURL(name), method: "PUT", body: body) { timestamp in
            CanonicalRequest.outcome(
                bucket: destination.bucket, name: name, timestamp: timestamp, body: body
            )
        }
        let answer = try await fetch(request)
        guard (200 ..< 300).contains(answer.status) else {
            throw ApplyError.refused(status: answer.status, message: Uploader.said(answer.body))
        }
    }

    // MARK: - Signing as the phone

    private func signed(
        _ url: URL, method: String, body: Data?, message: (Int64) -> Data
    ) throws -> URLRequest {
        let key = try identity.signingKey()
        // The service's clock, not this phone's: the same number until the
        // phone's is wrong, which it cannot tell on its own.
        let offset = (try? store.clockOffset()) ?? 0
        let timestamp = Int64(now().timeIntervalSince1970 + offset)
        let signature = try key.signature(for: message(timestamp))

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(String(timestamp), forHTTPHeaderField: "x-efferent-timestamp")
        request.setValue(
            Base64URL.encode(key.publicKey.rawRepresentation), forHTTPHeaderField: "x-efferent-writer"
        )
        request.setValue(Base64URL.encode(Data(signature)), forHTTPHeaderField: "x-efferent-signature")
        return request
    }

    private func claimPass() -> Bool {
        passLock.lock()
        defer { passLock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    private func releasePass() {
        passLock.lock()
        running = false
        passLock.unlock()
    }
}
