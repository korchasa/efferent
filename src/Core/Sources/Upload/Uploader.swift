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
        /// How long one call may go on clearing days that turn out to be
        /// already stored, before it leaves the rest for the next pass.
        ///
        /// It bounds the one case where a pass has to keep going by itself: a
        /// backlog of days that are all in the archive already sends nothing,
        /// so nothing would start the next round. Twenty seconds is well inside
        /// what the system gives a launch it woke for a Health delivery, and it
        /// gets through about a thousand such days.
        public let passBudget: TimeInterval
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
            passBudget: TimeInterval = 20,
            reconcileEvery: TimeInterval = 24 * 60 * 60,
            sessionIdentifier: String = "dev.korchasa.efferent.upload"
        ) {
            self.daysPerPass = daysPerPass
            self.daysPerRequest = min(daysPerRequest, Batch.maxDaysPerRequest)
            self.bytesPerRequest = bytesPerRequest
            self.concurrentUploads = concurrentUploads
            self.passBudget = passBudget
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

    /// What is in the air. Written by a pass when it hands a request over and by
    /// the session's delegate when the answer comes back, so it is not the
    /// property of either queue and is kept under a lock.
    private let flightLock = NSLock()
    private var inFlightBatches: [Int: [Sending]] = [:]
    private var stagedFiles: [Int: URL] = [:]
    /// The days those requests carry. A pass leaves them out when it picks the
    /// next days to build: without it, a second request would be built from the
    /// same days as the first — they are still marked, and marked is all the
    /// ledger knows — and the archive would be written twice with one answer
    /// left over.
    private var inFlightDays: Set<String> = []
    /// Requests that came back as a failure since the last one that did not.
    /// It sets how long to wait before trying again, and nothing else.
    private var consecutiveFailures = 0

    /// Answers as they arrive, byte by byte. Delegate queue only.
    private var responseBodies: [Int: Data] = [:]

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
    /// Asks turned away since the last pass reported them. A burst of Health
    /// deliveries is one event and arrives as fifteen, so counting is what
    /// keeps the fact without writing it down fifteen times.
    private var refusedWhileRunning = 0
    private var refusedWhileStopped = 0
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
    ///
    /// **A pass keeps going until the pipe is full or the queue is empty.**
    /// Rounds are what a request is built from, and a pass that stopped after
    /// one of them left a single request in the air and the network idle
    /// between round trips — a decade then takes a day of wake-ups. So rounds
    /// carry on: the days already in the air are left out of the next one, so
    /// nothing is built twice, and the pass stops when there are as many
    /// requests in the air as the session will run at once. The rest follows
    /// from the answers, each of which starts the next pass.
    ///
    /// **A round that only cleans days keeps going too.** A backlog already in
    /// the archive sends nothing, so nothing would come back to start the next
    /// round; without this the queue moved one round per wake-up while the
    /// screen said thousands of days were waiting.
    public func send() async throws -> Outcome {
        guard !isStopped else {
            countRefusal(stopped: true)
            return .stopped
        }
        guard claimPass() else {
            countRefusal(stopped: false)
            return .alreadyInFlight
        }
        defer { releasePass() }

        await checkTheArchive()

        let deadline = Date().addingTimeInterval(configuration.passBudget)
        var scheduled = 0
        var cleaned = 0
        var rounds = 0

        while true {
            let round = try await runRound()
            scheduled += round.scheduled
            cleaned += round.cleaned
            rounds += 1

            // Nothing came back from the ledger, so there is nothing left to
            // take — not "nothing happened", which is why both counts matter.
            guard round.scheduled > 0 || round.cleaned > 0, !isStopped else { break }
            guard batchesInFlight < configuration.concurrentUploads else {
                log.debug(
                    "\(batchesInFlight) requests are in the air, which is as many as this "
                        + "session runs at once; the answers carry on from here"
                )
                break
            }
            guard Date() < deadline else {
                log.info(
                    "this launch has run long enough: \(scheduled) days sending, \(cleaned) "
                        + "already in the archive. The rest go on the next pass."
                )
                break
            }
        }

        if rounds > 1 {
            log.info("pass ran \(rounds) rounds: \(scheduled) days sending, \(cleaned) unchanged")
        }
        reportRefusals()
        return scheduled == 0 && cleaned == 0
            ? .nothingToSend
            : .scheduled(days: scheduled, unchanged: cleaned)
    }

    /// One walk through the days at the front of the queue.
    private func runRound() async throws -> (scheduled: Int, cleaned: Int) {
        let days = try store.pendingDays(
            limit: configuration.daysPerPass, excluding: daysInFlight
        )
        log.debug(
            "pass took \(days.count) of the days waiting"
                + (days.isEmpty ? "" : ": \(days.last ?? "") … \(days.first ?? "")")
        )
        guard !days.isEmpty else { return (0, 0) }

        let startedBuilding = Date()
        let contents = try await build(days)
        log.debug(
            "read \(contents.count) days out of Health in \(Self.milliseconds(since: startedBuilding)) ms"
        )
        var pending: [Sending] = []
        var unchanged = 0

        for day in days {
            guard let content = contents[day] else {
                log.debug("\(day): Health returned nothing at all, not even an empty day")
                continue
            }
            let plaintext = try Columnar.body(content.events)
            let digest = Data(SHA256.hash(data: plaintext))

            if try store.digest(for: day) == digest {
                try store.markClean(day: day)
                unchanged += 1
                continue
            }

            let sealed = try SealedBox.seal(
                readingPublicKey: destination.readingPublicKey,
                plaintext: Deflate.compress(plaintext),
                associatedData: CanonicalRequest.associatedData(
                    bucket: destination.bucket, day: day
                )
            )
            log.debug(
                "\(day): \(content.events.count) events, \(plaintext.count) bytes, "
                    + "\(sealed.count) sealed, queued to go"
            )
            pending.append(Sending(
                day: day, digest: digest, identifiers: content.sampleIdentifiers, blob: sealed
            ))
        }

        let batches = Self.batches(pending, configuration: configuration)
        for batch in batches {
            try schedule(batch)
        }

        log.info(
            "pass over \(days.count) days: \(pending.count) sending in \(batches.count) requests, \(unchanged) unchanged"
        )
        return (pending.count, unchanged)
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
                log.debug(
                    "the archive was checked \(Int(Date().timeIntervalSince(last) / 60)) minutes "
                        + "ago; not checking again yet"
                )
                return
            }
            let started = Date()
            let owed = try await reconcile()
            try store.recordReconciled()
            log.debug(
                "checked the archive against Health in \(Self.milliseconds(since: started)) ms; "
                    + "\(owed) days owed again"
            )
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
        log.debug("staged \(body.count) bytes at \(file.lastPathComponent)")
        let request = try signedRequest(days: batch.map(\.day), body: body)
        log.debug(
            "\(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?") "
                + "signed over \(batch.count) days"
        )
        let task = session.uploadTask(with: request, fromFile: file)
        hold(batch, task: task.taskIdentifier, file: file)
        task.resume()
        log.info(
            "request \(task.taskIdentifier) handed to the system: \(batch.count) days "
                + "(\(batch.first?.day ?? "") … \(batch.last?.day ?? "")), \(body.count) bytes"
        )
    }

    // MARK: - Being told the time

    /// What the service's clock said, out of an answer that refused ours.
    ///
    /// The body first, because the service puts its own seconds there when it
    /// refuses a signature for being out of time, and that is exact. The `Date`
    /// header second: every HTTP answer carries one, so a service that refused
    /// for some other reason can still be believed about the time.
    static func serverTime(body: Data, dateHeader: String?) -> Date? {
        if let refusal = try? JSONDecoder().decode(Refusal.self, from: body), let now = refusal.now {
            return Date(timeIntervalSince1970: TimeInterval(now))
        }
        guard let dateHeader else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: dateHeader)
    }

    /// Seconds this phone is behind the service, or nil when it is close enough
    /// that nothing needs saying.
    ///
    /// A minute is the threshold because the tolerance either side is five, and
    /// a round trip is not a clock error. Below it, adjusting would be writing
    /// down the network's latency and calling it the time.
    static func driftWorthLearning(theirs: Date, ours: Date, known: TimeInterval) -> TimeInterval? {
        let offset = theirs.timeIntervalSince(ours)
        return abs(offset - known) > 60 ? offset : nil
    }

    private struct Refusal: Decodable {
        let error: String?
        /// The service's own clock, in seconds. Present only when it refused a
        /// signature for being out of time.
        let now: Int64?
    }

    /// Learn the service's clock from an answer that refused this phone's.
    ///
    /// Nothing else is done about it: the days in the refused request are still
    /// marked, so the next pass rebuilds them and signs them with the corrected
    /// clock. A pass is what retries; this only makes the retry able to succeed.
    private func learnTheClock(from response: HTTPURLResponse, body: Data) -> Bool {
        let header = response.value(forHTTPHeaderField: "Date")
        guard let theirs = Self.serverTime(body: body, dateHeader: header) else { return false }
        let known = (try? store.clockOffset()) ?? 0
        guard let offset = Self.driftWorthLearning(theirs: theirs, ours: Date(), known: known) else {
            return false
        }
        do {
            try store.recordClockOffset(offset)
            log.error(
                "this phone's clock is \(Int(offset)) seconds away from the service's, which is "
                    + "why the request was refused; requests are signed against the service's "
                    + "clock from now on"
            )
            return true
        } catch {
            log.error("could not write down the clock difference: \(String(describing: error))")
            return false
        }
    }

    /// How long something took, in whole milliseconds. Durations are the half
    /// of a sending problem that no count can show: a pass that took a minute
    /// to read Health and a pass that never got there look the same afterwards.
    static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    // MARK: - What is in the air

    private func hold(_ batch: [Sending], task: Int, file: URL) {
        flightLock.lock()
        defer { flightLock.unlock() }
        inFlightBatches[task] = batch
        stagedFiles[task] = file
        inFlightDays.formUnion(batch.map(\.day))
    }

    /// Take a finished request out of the air.
    private func release(task: Int) -> (batch: [Sending]?, file: URL?) {
        flightLock.lock()
        defer { flightLock.unlock() }
        let batch = inFlightBatches.removeValue(forKey: task)
        let file = stagedFiles.removeValue(forKey: task)
        for day in batch ?? [] {
            inFlightDays.remove(day.day)
        }
        return (batch, file)
    }

    private var batchesInFlight: Int {
        flightLock.lock()
        defer { flightLock.unlock() }
        return inFlightBatches.count
    }

    private var daysInFlight: Set<String> {
        flightLock.lock()
        defer { flightLock.unlock() }
        return inFlightDays
    }

    /// How many requests in a row have come back a failure, after counting this
    /// one. Zero resets the run.
    @discardableResult
    private func countFailure(_ failed: Bool) -> Int {
        flightLock.lock()
        defer { flightLock.unlock() }
        consecutiveFailures = failed ? consecutiveFailures + 1 : 0
        return consecutiveFailures
    }

    private func countRefusal(stopped: Bool) {
        passLock.lock()
        defer { passLock.unlock() }
        if stopped {
            refusedWhileStopped += 1
        } else {
            refusedWhileRunning += 1
        }
    }

    /// Say once what was turned away, at the end of the pass that turned it
    /// away. An ask refused while sending is held back has no running pass to
    /// report it, so it waits for the next one — which is the first moment
    /// anybody could act on it anyway.
    private func reportRefusals() {
        passLock.lock()
        let running = refusedWhileRunning
        let stopped = refusedWhileStopped
        refusedWhileRunning = 0
        refusedWhileStopped = 0
        passLock.unlock()

        var reasons: [String] = []
        if running > 0 {
            reasons.append("\(running) while this pass was running")
        }
        if stopped > 0 {
            reasons.append("\(stopped) while sending was held back")
        }
        guard !reasons.isEmpty else { return }
        log.debug("asks turned away: " + reasons.joined(separator: ", "))
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
        // The service's clock, not this phone's. They are the same number until
        // the phone's is wrong, and a phone cannot tell that its own clock is
        // wrong — it can only be told, which is what the offset is.
        let offset = (try? store.clockOffset()) ?? 0
        let timestamp = Int64(Date().timeIntervalSince1970 + offset)
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
        log.debug("request \(dataTask.taskIdentifier) answered with \(data.count) bytes")
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        log.debug(
            "request \(task.taskIdentifier) finished: sent \(task.countOfBytesSent) bytes, "
                + "received \(task.countOfBytesReceived)"
        )
        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let flight = release(task: task.taskIdentifier)
        if let staged = flight.file {
            try? FileManager.default.removeItem(at: staged)
        }
        let carried = flight.batch

        if let error {
            // Nothing to undo: the days are still marked, so they go again next
            // pass. Retrying here would only fight the system's own backoff.
            log.error("request \(task.taskIdentifier) failed: \(error.localizedDescription)")
            return carryOn(after: .transport)
        }
        guard let response = task.response as? HTTPURLResponse else {
            return carryOn(after: .transport)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            let detail = String(data: body, encoding: .utf8) ?? ""
            log.error("request \(task.taskIdentifier) answered \(response.statusCode): \(detail)")

            // A refusal the phone can act on: its clock is wrong. Learning the
            // difference is the whole repair — the days are still marked, and
            // the next pass signs them against the service's clock instead.
            if learnTheClock(from: response, body: body) {
                return carryOn(after: .recoverable)
            }
            // A refusal about the request itself, rather than about the network
            // or the service's own trouble. Counted against the days it carried:
            // a day the service will not take is not made acceptable by being
            // sent again forever at the head of the queue.
            if (400 ..< 500).contains(response.statusCode), let carried {
                refuse(carried.map(\.day), status: response.statusCode)
            }

            let refused = (400 ..< 500).contains(response.statusCode)
            return carryOn(after: refused ? .refused : .transport)
        }
        guard let carried else { return carryOn(after: .delivered) }

        // Written down only for the days the answer names. A batch is not a
        // promise that every day in it landed, and marking one clean that the
        // service never stored would lose it in a way nothing later could
        // notice — the day would simply never be sent again.
        guard let accepted = try? JSONDecoder().decode(Accepted.self, from: body) else {
            log.error(
                "could not read what the service stored: \(String(data: body, encoding: .utf8) ?? "")"
            )
            return carryOn(after: .refused)
        }
        let stored = Set(accepted.stored)
        let left = carried.filter { !stored.contains($0.day) }
        if !left.isEmpty {
            for entry in left {
                log.error("the service did not store \(entry.day); it stays marked")
            }
            refuse(left.map(\.day), status: response.statusCode)
        }

        log.info(
            "request \(task.taskIdentifier) answered \(response.statusCode): the archive "
                + "took \(stored.count) of \(carried.count) days"
        )

        for entry in carried where stored.contains(entry.day) {
            do {
                try store.recordSent(
                    day: entry.day,
                    digest: entry.digest,
                    bytes: entry.blob.count,
                    sampleIdentifiers: entry.identifiers
                )
            } catch {
                log.error("could not record \(entry.day): \(String(describing: error))")
            }
        }
        didStoreDay?()
        carryOn(after: .delivered)
    }

    /// Count a refusal against the days it was about, and say so once when a day
    /// has been refused often enough to be set aside.
    private func refuse(_ days: [String], status: Int) {
        do {
            let parked = try store.recordRefused(days)
            guard !parked.isEmpty else { return }
            log.error(
                "the service has refused \(parked.first ?? "") "
                    + (parked.count > 1 ? "and \(parked.count - 1) more " : "")
                    + "\(Store.attemptsBeforeParking) times (last with \(status)); they are set "
                    + "aside and tried again by the daily check against the archive"
            )
        } catch {
            log.error("could not count the refusal: \(String(describing: error))")
        }
    }

    /// What the last request came back as, as far as what to do next is
    /// concerned.
    private enum Answer {
        case delivered
        /// The phone has just repaired something and should try again at once.
        case recoverable
        /// The network or the service. Waiting is the only useful reply.
        case transport
        /// The service understood and said no. Waiting helps as little as
        /// hurrying, but the days it was about have been counted against.
        case refused
    }

    /// Start the next pass, or leave it to a wake-up.
    ///
    /// The chain that walks a backlog is made of exactly this: every answer
    /// starts the pass that builds the next days. Every answer, not only the
    /// last one in the air — the days still flying are left out of what a pass
    /// builds, so this tops the pipe back up rather than waiting for the
    /// slowest of four requests before any of them is replaced. A pass that
    /// finds one already running costs a claim and returns.
    ///
    /// It is also where a failure stops being invisible: before, a failed
    /// request simply ended the chain, and the queue then stood still until
    /// something outside woke the app.
    private func carryOn(after answer: Answer) {
        let failures = countFailure(answer == .transport || answer == .refused)
        guard !isStopped else { return }

        let delay: TimeInterval
        switch answer {
        case .delivered, .recoverable:
            delay = 0
        case .transport, .refused:
            // Doubling, and capped. A phone with no network that retried every
            // few seconds would spend a day of battery discovering the same
            // thing; one that waited an hour after a blip would look broken.
            delay = min(300, 5 * pow(2, Double(min(failures, 8) - 1)))
            log.info("waiting \(Int(delay)) seconds after \(failures) failed requests in a row")
        }

        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            _ = try? await self?.send()
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        log.debug("the system has reported every transfer it finished while the app was gone")
        let finished = backgroundEventsFinished
        DispatchQueue.main.async { finished?() }
    }
}
