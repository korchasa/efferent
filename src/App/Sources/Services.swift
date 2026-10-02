import Foundation
import os
import UIKit

/// Composition root: builds the store, the collector and the uploader once, and
/// hands them out.
///
/// This is the only place that knows about the file system and user defaults;
/// everything below it is plain values that a test can construct.
@MainActor
final class Services: ObservableObject {
    static let shared = Services()

    let store: Store
    let health: HealthCoordinator
    /// Where this archive's days are cut. Pinned to the phone's zone the first
    /// time it is asked and then left alone, so a fortnight abroad does not
    /// silently re-cut a decade of history into different days.
    let calendar: Calendar
    let identity = DeviceIdentity()
    let readingIdentity = ReadingIdentity()
    /// The key an agent signs edits with. Made here, handed over beside the
    /// reading key, and named to the service so it takes edits from nobody else.
    let editor = EditorIdentity()
    let deployment: Deployment?
    let deploymentError: String?
    private let log = Log(category: "services")
    /// Asks that arrived while sending was held back, reported once when it is
    /// let go again rather than one line each.
    private var asksWhileHeldBack = 0

    @Published private(set) var stats: Stats?
    @Published private(set) var lastError: String?
    /// The service's last word on an upload it turned away, until one lands.
    /// Answers arrive long after the pass that sent them has finished, so the
    /// pass cannot report them itself — and a pass that ends without a
    /// thrown error must not wipe the one sentence saying why nothing lands.
    private var uploadRefusal: String?
    @Published private(set) var destination: Destination?
    @Published private(set) var connectionHandoff: ConnectionHandoff?
    /// Whether setup has been walked through. A phone that already holds an
    /// archive has walked it by definition, so the flag is only ever written
    /// for phones that have not.
    @Published private(set) var setupComplete: Bool
    /// Whether the setup text has ever left the phone. It only ever dims the
    /// invitation to hand it over: an archive nobody can read is the state this
    /// app is least useful in, so the way out of it stays lit until it is done.
    @Published private(set) var agentConnected: Bool

    /// How far the first export has got, for the walkthrough screen that
    /// watches it begin.
    enum Preparation: Equatable {
        /// Making the reading key and claiming the archive with the service.
        case creatingArchive
        /// Marking the chosen days and reading Health through once. Nothing
        /// is sent yet, and on a long history this is the slow part: before
        /// it had a name the screen already said "Sending has started" and
        /// then stood still for ten seconds on the owner's phone (2026-09-29).
        case readingHistory
        /// The days are going.
        case sending
    }

    @Published private(set) var preparation = Preparation.creatingArchive

    /// The phone is re-reading Health because the person asked it to, so the
    /// figure on the face is about to change and is not shown yet.
    ///
    /// Pressing start marks the last week and only then works out which of
    /// those days differ from the archive — usually none of them. For the
    /// second or two in between, the queue holds days that are about to be
    /// written off, and the face was reporting them as work: "5 days waiting"
    /// on a phone that was up to date, gone again before it could be read
    /// (owner, 2026-09-20). A figure that is about to change is not a status,
    /// so the face says nothing rather than saying five.
    @Published private(set) var rereading = false

    /// What stopped the last look at the queue, or nil when nothing did.
    ///
    /// The screen reads it. NOTICE-7: a delivery that stopped used to leave its
    /// only trace in the log, which is a place nobody looks — so an edit
    /// waiting behind a lock, or a run that failed, looked exactly like an
    /// agent that had sent nothing.
    @Published private(set) var deliveryStop: EditWords.DeliveryStop?
    /// How far an edit can get without somebody opening the app.
    ///
    /// STATE-2: a wake the phone refused and a system that runs nothing in the
    /// background both make delivery late, and from the everyday screen they
    /// look exactly like an agent that sent nothing. Kept as a property the
    /// screen can read rather than asked of UIKit inside a view, so the words
    /// stay in `EditWords` and can be tested without a phone.
    @Published private(set) var reach = EditWords.Reach.whole
    /// Whether the last attempt to make this phone reachable failed.
    ///
    /// Only a failure, never a silence: registration is asked for on every
    /// launch and Apple answers on its own time, so a phone that has simply not
    /// been answered yet must not be called refused.
    private var wakeRefused = false
    /// The walkthrough has just ended and the archive has never been handed to
    /// an agent. Lives only in memory: it is about this launch, not about the
    /// phone, and a person who closed the sheet has answered the question.
    @Published private(set) var offerHandoff = false
    /// Sending held back on purpose. Days stay marked while it is on, so a
    /// pause costs time and never data.
    @Published private(set) var paused: Bool
    /// How many days the run in front of the ring began with. Kept across
    /// launches so a phone restarted in the middle of a first export still
    /// knows what it is counting towards; zero means nothing is outstanding.
    @Published private(set) var batchTotal: Int
    /// What an agent has changed: since the person last looked, since the start
    /// of today, and ever. The everyday screen reads all three.
    @Published private(set) var edits = EditSummary()

    private var uploader: Uploader?
    private var applier: Applier?
    /// The one way into Health's write side. A person's own correction uses it
    /// as the applier does,
    /// because taking a record back out is the same operation the agent's own
    /// `delete` performs.
    private lazy var healthWriter = HealthKitWriter(calendar: calendar)
    /// Built for a screenshot: figures are fixed, and nothing here may move them.
    private let demonstration: Bool

    private init() {
        demonstration = false
        do {
            store = try Store(url: Self.storeURL())
        } catch {
            // The app has nothing to do without it, and carrying on would
            // silently forget every day that still has to go. Better to stop
            // where the cause is still visible.
            fatalError("could not open the day store: \(error)")
        }
        calendar = Day.calendar(timeZone: Self.dayTimeZone(in: store))
        health = HealthCoordinator(store: store, calendar: calendar)
        // Held locally as well as stored: the flag below is decided before the
        // rest of the properties exist, and until they do nothing may be read
        // back off `self`.
        let loaded = Self.loadDestination()
        let defaults = UserDefaults.standard
        agentConnected = defaults.bool(forKey: Self.connectedKey)
        paused = defaults.bool(forKey: Self.pausedKey)
        batchTotal = defaults.integer(forKey: Self.batchKey)
        // A phone that already has somewhere to send has been through setup,
        // whatever the flag says. Without this, the update that introduced the
        // walkthrough would have shown it to everybody who was already running.
        setupComplete = defaults.object(forKey: Self.setupKey) as? Bool ?? (loaded != nil)
        var archiveNeedsRewrite = false
        do {
            // A debug run may have been pointed at a service on this machine;
            // every other build sends where its own build says.
            deployment = try Rehearsal.deployment() ?? Deployment.load()
            deploymentError = nil
        } catch {
            deployment = nil
            deploymentError = String(describing: error)
        }
        destination = Self.movedToThisBuild(loaded, deployment)
        connectionHandoff = nil
        do {
            if let destination {
                if try readingIdentity.existingPrivateKey() == nil {
                    try store.rememberArchive(destination.bucket)
                } else {
                    archiveNeedsRewrite = try store.activateArchive(destination.bucket)
                }
                archiveNeedsRewrite = try store.activateSealingVersion(Int64(SealedBox.version))
                    || archiveNeedsRewrite
                archiveNeedsRewrite = try store.activateDayFormat(Int64(dayFormatVersion))
                    || archiveNeedsRewrite
            }
        } catch {
            lastError = "Could not bind the day ledger to its archive. (\(error))"
        }
        refreshConnectionHandoff()
        health.onNewData = { [weak self] in
            Task { @MainActor in await self?.sendNow() }
        }
        if archiveNeedsRewrite {
            refreshStats()
            Task { [weak self] in await self?.sendNow() }
        }
        // Once per bucket, and retried at the head of every pass until it
        // lands: a phone that made its archive before edits existed has an
        // editor key the service has never heard of, and one that made it
        // before reads were signed has no read key there either.
        if destination != nil {
            Task { [weak self] in
                await self?.ensureEditorRegistered()
                await self?.ensureReaderRegistered()
            }
        }
    }

    /// A copy for the store screenshots: an in-memory store, no Health, no
    /// Keychain, no network, and figures chosen so that each screen shows the
    /// state it exists for. Only the snapshot run (`--snapshot <dir>`) builds
    /// one; the app itself always goes through `shared`.
    init(
        demoStats: Stats?,
        batchTotal: Int,
        setupComplete: Bool,
        deployment: Deployment?,
        destination: Destination?,
        handoff: ConnectionHandoff?
    ) {
        demonstration = true
        do {
            store = try Store.inMemory()
        } catch {
            fatalError("could not open an in-memory day store: \(error)")
        }
        calendar = Day.calendar()
        health = HealthCoordinator(store: store, calendar: calendar)
        self.deployment = deployment
        deploymentError = nil
        stats = demoStats
        lastError = nil
        self.destination = destination
        connectionHandoff = handoff
        self.setupComplete = setupComplete
        agentConnected = false
        paused = false
        self.batchTotal = batchTotal
    }

    /// One line of a demonstration's agent run.
    struct DemoEdit {
        let item: EditItem
        /// What the record is at the end of the demonstration.
        let state: EditEntry.State
        /// Whose doing that is. A person's row is written twice: the agent's
        /// own outcome first, then the person's action over it.
        var askedBy: EditEntry.Asker = .agent
        var day: String?
        var code: OutcomeCode?
        /// What it pushed out of Health, as the real thing carries it — which
        /// is what decides whether its page offers to put a record back.
        var displaced: [DisplacedRecord] = []
        let at: Date
    }

    /// Put a run of an agent's work into a demonstration's journal.
    ///
    /// `refreshStats` leaves a screenshot's figures alone on purpose, and the
    /// edit screens are the ones that read the journal rather than the stats,
    /// so their contents have to be put in by hand. Does nothing in the app.
    func demonstrate(_ run: [DemoEdit]) {
        guard demonstration else { return }
        do {
            for (index, edit) in run.enumerated() {
                // A row the person ended up changing is written the way the app
                // writes it — as the agent's — and then changed, because that
                // is the only way the journal ever gets one.
                let agentLeft: EditEntry.State = edit.askedBy == .agent
                    ? edit.state
                    : (edit.state == .removed ? .written : .removed)
                try store.recordEdit(
                    edit.item, at: index, in: "1757336400000-abcdefgh",
                    state: agentLeft,
                    day: edit.day, code: edit.code, displaced: edit.displaced, at: edit.at
                )
            }
            let written = try store.recentEdits()
            for edit in run where edit.askedBy == .person {
                guard let row = written.first(where: { $0.recordID == edit.item.id }) else { continue }
                try store.recordPersonAction(
                    row.id, left: edit.state, at: edit.at.addingTimeInterval(240)
                )
            }
            edits = try store.editSummary(seenAt: nil, todayFrom: calendar.startOfDay(for: Date()))
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Archive creation and connection

    /// Make the phone-owned reading key, claim its archive, then remember it.
    /// The destination is persisted only after the server accepts the claim.
    func createArchive() async {
        do {
            guard destination == nil else { return }
            guard let deployment else {
                throw ConnectionError.missingDeploymentValue(deploymentError ?? "deployment")
            }
            let readingKey = try readingIdentity.privateKey()
            let created = try Destination(
                endpoint: deployment.serviceURL,
                readingPublicKey: readingKey.publicKey.rawRepresentation
            )
            if Rehearsal.isPretending() {
                log.info("claiming without App Attest: this run stands in for Apple")
            }
            try await ArchiveCreator.create(
                destination: created, identity: identity, attester: Rehearsal.attester()
            )
            _ = try store.activateArchive(created.bucket)
            _ = try store.activateSealingVersion(Int64(SealedBox.version))
            _ = try store.activateDayFormat(Int64(dayFormatVersion))
            try UserDefaults.standard.set(JSONEncoder().encode(created), forKey: Self.destinationKey)
            destination = created
            uploader?.retire()
            uploader = nil
            applier = nil
            lastError = nil
            refreshConnectionHandoff()
            refreshStats()
            log.info("created bucket \(created.bucket)")
            await ensureEditorRegistered()
            await ensureReaderRegistered()
            // The archive was made by a person on a screen, which is the one
            // moment the writing sheet can be shown without waiting for the
            // next launch.
            await askForWriteAccessIfNeeded()
            // No pass yet: the caller marks the history next, and a pass run
            // before that marking sends what the archive check found missing,
            // only for the marking to queue those same days a second time.
        } catch AttestationFailure.notAvailableOnThisDevice {
            // Says what is wrong with the machine rather than with the archive.
            // Without this the simulator answers a person's first tap with a
            // sentence about a failure that has nothing to do with them.
            lastError = "This device cannot claim an archive. App Attest needs a real iPhone."
        } catch {
            lastError = "Could not create the archive. (\(error))"
        }
    }

    /// Tell the service which key edits come from, once per archive.
    ///
    /// A failure is written down and not shown: the archive works without it,
    /// and the next pass tries again. Until it lands the handoff still carries
    /// the editor key, and an edit made with it is refused by the service with
    /// a sentence saying no editor is registered — which is true, and mends
    /// itself the next time the phone is online.
    func ensureEditorRegistered() async {
        guard !demonstration, let destination else { return }
        do {
            guard try !store.editorRegistered(for: destination.bucket) else { return }
            let key = try editor.signingKey()
            try await ArchiveCreator.registerEditor(
                destination: destination,
                identity: identity,
                editorPublicKey: key.publicKey.rawRepresentation,
                now: serviceNow()
            )
            try store.recordEditorRegistered(for: destination.bucket)
            log.info("the editor key is registered with the archive")
            refreshConnectionHandoff()
        } catch {
            log.error("could not register the editor key: \(String(describing: error))")
        }
    }

    /// Tell the service which key reads must be signed with, once per archive.
    ///
    /// From the moment it lands the bucket id stops opening anything: every
    /// read has to carry a signature only a holder of the reading key can make.
    /// Only a phone that holds its reading key has anything to make the read
    /// key from; a legacy archive joined from a reader registers none and stays
    /// readable on its id, as before. A failure is a line in the log, like the
    /// editor's, and the next pass tries again — until then the archive simply
    /// reads the way it did before there were read keys.
    func ensureReaderRegistered() async {
        guard !demonstration, let destination else { return }
        do {
            guard try !store.readerRegistered(for: destination.bucket),
                  let reading = try readingIdentity.existingPrivateKey()
            else { return }
            try await ArchiveCreator.registerReader(
                destination: destination,
                identity: identity,
                readerPublicKey: ReadKey.derive(from: reading).publicKey.rawRepresentation,
                now: serviceNow()
            )
            try store.recordReaderRegistered(for: destination.bucket)
            log.info("the read key is registered with the archive; reads must be signed from now on")
        } catch {
            log.error("could not register the read key: \(String(describing: error))")
        }
    }

    /// The service's clock as this phone last learned it. A registration
    /// signed on a clock the service refuses would be refused every launch,
    /// for the same reason, for good.
    private func serviceNow() -> Date {
        Date().addingTimeInterval((try? store.clockOffset()) ?? 0)
    }

    /// What signs this phone's reads of its archive, or nil for a phone that
    /// holds no reading key and so has no read key to sign with.
    private func readSigner(for destination: Destination) -> ReadSigner? {
        guard let reading = try? readingIdentity.existingPrivateKey(),
              let readKey = try? ReadKey.derive(from: reading)
        else { return nil }
        return ReadSigner(destination: destination, readKey: readKey, store: store)
    }

    // MARK: - Being woken

    /// Ask Apple for a way to reach this phone.
    ///
    /// Not a permission and not a question: a background wake needs no notice
    /// permission and shows nothing, so nobody is asked anything here. What it
    /// costs is written down instead — the service learns it can ring this
    /// phone, and learns when it did.
    ///
    /// Called on every launch with an archive, because the token is Apple's to
    /// change: a restore, a reinstall or a new phone all produce a new one, and
    /// the only way to find out is to ask. Apple answers on the delegate.
    func registerForWake() {
        guard !demonstration, destination != nil else { return }
        // Read once at launch as well as from the screen's ticker: a launch in
        // the background never opens a screen, and the first thing a person
        // does after turning background refresh back on is open the app.
        refreshReach()
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Apple answered with the way to reach this phone; tell the service.
    ///
    /// Sent when it is news — a token this bucket has already been told about
    /// is not sent again — and a failure is a line in the log. Being woken is
    /// the fast path and never the only one, so a phone that could not register
    /// is slower and not broken.
    func recordDeviceToken(_ token: Data) async {
        guard !demonstration, let destination else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard let topic = Bundle.main.bundleIdentifier else {
            log.error("this build has no bundle id, so it cannot say what to push under")
            return
        }
        do {
            guard try !store.wakeRegistered(for: destination.bucket, token: hex) else { return }
            try await ArchiveCreator.registerDevice(
                destination: destination, identity: identity, token: token, topic: topic
            )
            try store.recordWakeRegistered(for: destination.bucket, token: hex)
            log.info("the service can wake this phone now")
            wakeRefused = false
            refreshReach()
        } catch {
            log.error("could not register for waking: \(String(describing: error))")
            // A token Apple gave that the archive never learned reaches nobody,
            // so this counts as a refusal on the screen exactly like Apple's.
            recordWakeRefused()
        }
    }

    /// Nothing can ring this phone: Apple would not say how to reach it, or the
    /// archive was never told. Written down because the everyday screen is the
    /// only place a person would ever find out — being woken is the fast path
    /// and never the only one, so the app goes on working and just goes slower.
    func recordWakeRefused() {
        wakeRefused = true
        refreshReach()
    }

    /// Re-read the two settings delivery depends on and nothing in this app
    /// controls. Cheap, and called from the screen's own ticker: background
    /// refresh is switched in the system settings, which this app is not
    /// running during.
    func refreshReach() {
        guard !demonstration else { return }
        switch UIApplication.shared.backgroundRefreshStatus {
        case .denied, .restricted:
            // Both layers at once: without background refresh the system runs
            // no catch-up task, and a silent wake is not delivered either.
            reach = .nothingInTheBackground
        case .available:
            reach = wakeRefused ? .noWake : .whole
        @unknown default:
            // Nothing is known to be wrong, so nothing is said. A guess here
            // would accuse the person's settings of a fault they do not have.
            reach = wakeRefused ? .noWake : .whole
        }
    }

    /// For the walk over the screens, which has no real settings to read.
    func demonstrate(reach: EditWords.Reach) {
        guard demonstration else { return }
        self.reach = reach
    }

    /// The service says an edit is waiting. Everything else is this phone's.
    ///
    /// The wake carries nothing, so there is nothing to read out of it — it is
    /// the same fetch the open app and the catch-up task make, at a moment
    /// somebody asked for rather than one the system chose.
    func wokenByService() async {
        log.info("woken: something is waiting at the archive")
        await deliverEdits()
    }

    private func refreshConnectionHandoff() {
        do {
            guard let deployment, let destination,
                  let privateKey = try readingIdentity.existingPrivateKey()
            else {
                connectionHandoff = nil
                return
            }
            let editorKey = try editor.signingKey()
            connectionHandoff = ConnectionHandoff(
                deployment: deployment,
                destination: destination,
                privateKey: privateKey.rawRepresentation,
                editorPrivateKey: editorKey.rawRepresentation,
                editorPublicKey: editorKey.publicKey.rawRepresentation
            )
        } catch {
            connectionHandoff = nil
            lastError = "Could not read the connection key. (\(error))"
        }
    }

    /// Forget where to send and both phone-owned keys. A phone-owned archive
    /// becomes unreadable if its reading key was not already moved elsewhere.
    func disconnect() async {
        log.info("disconnected: this phone forgets the archive and its keys")
        // First, while there is still a key that can sign for it: an archive
        // this phone has let go of must not leave a way to ring it. A service
        // that cannot be reached keeps the token, and refuses to wake a phone
        // that no longer answers — which is a wake nobody sees rather than a
        // way in.
        if let destination, !demonstration {
            do {
                try await ArchiveCreator.forgetDevice(destination: destination, identity: identity)
            } catch {
                log.error("the service was not told to stop waking this phone: \(String(describing: error))")
            }
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        try? store.forgetWakeRegistration()
        UserDefaults.standard.removeObject(forKey: Self.destinationKey)
        // Back to the beginning, not to an everyday screen with nowhere to
        // send: without an archive there is nothing for that screen to show.
        UserDefaults.standard.removeObject(forKey: Self.setupKey)
        UserDefaults.standard.removeObject(forKey: Self.batchKey)
        UserDefaults.standard.removeObject(forKey: Self.connectedKey)
        agentConnected = false
        setupComplete = false
        batchTotal = 0
        destination = nil
        connectionHandoff = nil
        // Retired, not just dropped: its background session keeps it alive
        // and would go on sending to this archive under the next one's key.
        uploader?.retire()
        uploader = nil
        uploadRefusal = nil
        applier = nil
        do {
            try identity.forget()
            try readingIdentity.forget()
            try editor.forget()
        } catch {
            lastError = String(describing: error)
        }
    }

    func uploaderIfPaired() -> Uploader? {
        if let uploader {
            return uploader
        }
        guard let destination else { return nil }
        let signer = readSigner(for: destination)
        let built = Uploader(
            destination: destination,
            store: store,
            identity: identity,
            // The uploader decides *when* a day goes; Health decides what is in
            // it. Handing the reading in rather than the coordinator keeps the
            // uploader testable without a phone.
            build: { [health] days in try await health.build(days: days) },
            // The same split for the check: the uploader decides how often to
            // ask, Health works out which days should exist and compares.
            reconcile: { [health] in
                try await health.reconcile(with: Archive(destination: destination, signer: signer))
            }
        )
        // Days land on the upload session's own queue, with no view in sight.
        // Without this the counters only change when the screen reappears,
        // which reads as a stall while data is going up fine.
        built.didStoreDay = { [weak self] in
            Task { @MainActor in
                self?.uploadRefusal = nil
                self?.refreshStats()
            }
        }
        built.didRefuse = { [weak self] error in
            let said: String
            if case let ConnectionError.server(status, message) = error {
                said = "The archive turned the upload away (\(status)): \(message)"
            } else {
                said = "The archive turned the upload away. (\(error))"
            }
            Task { @MainActor in
                self?.uploadRefusal = said
                self?.lastError = said
            }
        }
        // A pause set before anything was ever sent has to survive the first
        // uploader being built, or the first send would start under it.
        built.setStopped(paused)
        uploader = built
        return built
    }

    /// The applier, for a phone that holds its archive's reading key. A phone
    /// on a legacy reader-first archive cannot open an edit and gets none.
    func applierIfPaired() -> Applier? {
        if let applier {
            return applier
        }
        guard let destination, (try? readingIdentity.existingPrivateKey()) != nil else { return nil }
        let built = Applier(
            destination: destination,
            identity: identity,
            readingKey: { [readingIdentity] in try readingIdentity.privateKey() },
            editorPublicKey: { [editor] in try editor.signingKey().publicKey.rawRepresentation },
            store: store,
            writer: healthWriter,
            fetch: Applier.session(),
            calendar: calendar
        )
        applier = built
        return built
    }

    // MARK: - Actions

    func setError(_ message: String?) {
        lastError = message
    }

    func refreshStats() {
        // A screenshot's figures are the point of it; the empty store behind
        // them must not be allowed to say otherwise.
        guard !demonstration else { return }
        do {
            let fresh = try store.stats()
            stats = fresh
            trackBatch(pending: fresh.pendingDays)
            edits = try store.editSummary(
                seenAt: store.editsSeenAt(), todayFrom: calendar.startOfDay(for: Date())
            )
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Keep the number the ring counts towards.
    ///
    /// It is set when work appears and cleared when there is none, rather than
    /// held at the size of the archive: a ring measured against a decade would
    /// sit at ninety-nine per cent for every ordinary day and say nothing about
    /// whether anything is moving. Three new days should fill it.
    private func trackBatch(pending: Int) {
        if pending == 0 {
            guard batchTotal != 0 else { return }
            batchTotal = 0
            runStartedAt = nil
        } else if pending > batchTotal {
            batchTotal = pending
            runStartedAt = Date()
            runStartPending = pending
        } else {
            return
        }
        UserDefaults.standard.set(batchTotal, forKey: Self.batchKey)
    }

    /// When the measurement behind the time left began, and what was waiting
    /// then. Not persisted: a phone that was away has no idea how much of the
    /// gap was spent sending, and a rate worked out across it would be fiction.
    private var runStartedAt: Date?
    private var runStartPending = 0

    private func markRunStart() {
        runStartedAt = Date()
        runStartPending = stats?.pendingDays ?? 0
    }

    /// How long the days still waiting will take, once the phone has watched
    /// enough of them go to have an answer.
    ///
    /// Nil until then, and nil is shown as nothing rather than as a guess: a
    /// rate computed from three days changes every second, and a number that
    /// keeps changing teaches nobody anything. It is measured rather than
    /// assumed because the real rate depends on the day — a decade of workouts
    /// and an empty week are not the same work.
    var timeLeft: TimeInterval? {
        guard let started = runStartedAt, let stats, stats.pendingDays > 0 else { return nil }
        let done = runStartPending - stats.pendingDays
        let elapsed = Date().timeIntervalSince(started)
        guard done >= 10, elapsed >= 5 else { return nil }
        return Double(stats.pendingDays) * elapsed / Double(done)
    }

    /// How much of the run in front of the ring is done, from nothing to all.
    /// With no run outstanding it is full: there is nothing left to wait for.
    var syncProgress: Double {
        guard batchTotal > 0, let stats else { return 1 }
        return Double(batchTotal - stats.pendingDays) / Double(batchTotal)
    }

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Show the system sheet for writing, once, when a launch with a screen
    /// finds a type nobody has decided about.
    ///
    /// The sheet lists only the undecided types, so a phone that granted
    /// reading before writing existed is asked once more, about writing alone.
    /// Background launches never get here, and the applier waits with
    /// `.notAsked` until one with a screen has.
    func askForWriteAccessIfNeeded() async {
        guard !demonstration, destination != nil, HealthReader.isAvailable else { return }
        guard HealthKitWriter().writeAccessUndecided() else { return }
        log.info("asking about writing: some writable type has never been decided")
        await requestHealthAccess()
    }

    /// Whether some writable Health type has never been decided about, which
    /// stops the queue being read at all. Asked of HealthKit each time rather
    /// than remembered: the person can answer it in the Health app, and a
    /// remembered "no" would go on blaming a question that was answered.
    var healthWriteUndecided: Bool {
        guard !demonstration else { return false }
        return healthWriter.writeAccessUndecided()
    }

    func refreshNow() async {
        do {
            _ = try await health.refresh()
            lastError = nil
        } catch where HealthReader.isLocked(error) {
            log.debug("the phone is locked, so Health kept its data; the next launch reads it")
        } catch {
            lastError = String(describing: error)
        }
        refreshStats()
    }

    func sendNow() async {
        await withTimeToFinish("sending the days that are owed", log: log) { [self] in
            await send()
        }
    }

    private func send() async {
        // The one place a pause is honoured. Every route into sending — the
        // button, the Health observer, the background refresh — arrives here,
        // so a single guard covers all of them and none of them can forget.
        guard !paused else {
            // Counted, not written down. Health delivers each metric separately
            // and every delivery asks; while sending is held back that is a
            // dozen identical lines an hour saying what the button already says.
            asksWhileHeldBack += 1
            return
        }
        // Edits first, days second: what an edit changes is a day that then
        // goes up in the same pass. Above the lock guard below, because a
        // locked phone can still list the queue and say what is coming — only
        // the writing waits for the unlock.
        await applyEdits()
        // Every day in a pass is built out of Health, and Health is sealed
        // while the screen is locked. Going in anyway marks a week, reads the
        // ledger and then waits on Health until it refuses — 70 seconds of a
        // background launch that lasts seconds, for nothing. Health delivers to
        // a locked phone, so this is an ordinary state, not a rare one.
        guard UIApplication.shared.isProtectedDataAvailable else {
            log.debug("the phone is locked, so Health has nothing to give; the days wait")
            return
        }
        guard let uploader = uploaderIfPaired() else {
            log.error("asked to send with no archive to send to")
            lastError = "No archive has been created yet."
            return
        }
        do {
            let started = Date()
            let outcome = try await uploader.send()
            // Only when the pass did something. The uploader writes down what
            // it took, what it sent and what it turned away, so repeating every
            // outcome here doubled a burst of asks into two lines apiece.
            if case let .scheduled(days, unchanged) = outcome {
                log.info(
                    "send outcome: \(days) days sending, \(unchanged) unchanged, "
                        + "in \(Uploader.milliseconds(since: started)) ms"
                )
            }
            lastError = uploadRefusal
        } catch where HealthReader.isLocked(error) {
            // Not a failure and not on the screen: a day is built out of Health,
            // and a locked phone hands nothing over. The days stay marked.
            log.debug("the phone is locked, so nothing could be built; the days wait")
        } catch {
            log.error("send failed: \(String(describing: error))")
            lastError = String(describing: error)
        }
        refreshStats()
    }

    /// Go and see what the agent asked for, on its own.
    ///
    /// The one entry point for the inbound direction. It reads no Health and
    /// sends no days, so anything may call it as often as a person's patience
    /// asks for — the screen's own ticker does, every few seconds, and a pass
    /// calls it first. Serialising overlapping callers is the applier's job and
    /// costs nothing here.
    ///
    /// A pause holds edits exactly as it holds days: held back is a decision,
    /// and a decision that only half took effect would be worse than none.
    func deliverEdits() async {
        await withTimeToFinish("delivering what an agent asked for", log: log) { [self] in
            await deliver()
        }
    }

    private func deliver() async {
        guard !paused else { return }
        await applyEdits()
        refreshStats()
    }

    /// Write what the agent asked for into Health and owe the days it changed.
    ///
    /// A failure is written down and does not stop the send behind it: the
    /// edits stay in the queue, and the days already changed are marked
    /// whatever stopped the run.
    private func applyEdits() async {
        // A walk over the screens has an archive address and keys, both made
        // up, so without this line it would ask a real service about a bucket
        // that does not exist — every fifteen seconds, from the ticker.
        guard !demonstration else { return }
        await ensureEditorRegistered()
        await ensureReaderRegistered()
        guard let applier = applierIfPaired() else { return }
        do {
            // Read here, where the answer lives, and handed in: a locked phone
            // still lists the queue, and only the writing waits for the unlock.
            let outcome = try await applier.run(
                canWrite: UIApplication.shared.isProtectedDataAvailable
            )
            // Only when the queue was actually reached. `busy` did not get to
            // ask, and `notAsked` returns before the listing — writing a time
            // for either would put a sentence on the screen saying this phone
            // looked, which is the one thing that line exists to be honest
            // about.
            switch outcome {
            case .busy, .notAsked: return
            case .nothingWaiting, .applied, .locked:
                try store.recordEditCheck(heldByLock: Self.heldByLock(in: outcome))
                deliveryStop = Self.stopped(by: outcome)
            }
            guard case let .applied(applied) = outcome else { return }
            var owed = 0
            if !applied.days.isEmpty {
                owed = try store.markDirty(applied.days)
                log.info("\(applied.days.count) days changed by edits, \(owed) newly waiting")
            }
            // Said once per run, from the launch that did it — which is usually
            // one nobody is looking at. The screen learns the same fact from
            // the journal the next time it refreshes.
            await Notices.tell(
                written: applied.written,
                removed: applied.removed,
                failed: applied.failed
            )
            // Marking a day is not sending it, and of the five paths that
            // deliver edits only two send afterwards: an edit applied on a
            // push wake, on a relaunch for finished transfers, on coming to
            // the front, or on this screen's own ticker left its day marked
            // and nothing carried it. The dial then read "1 day waiting ·
            // sending" and stood still until Health happened to wake the app
            // about something else — which on the owner's phone was minutes
            // (2026-09-20). Only when something was newly marked: a pass over
            // a day already in the queue is the caller's business, not this
            // one's, and the pass lock turns away whatever overlaps.
            if owed > 0 {
                await sendNow()
            }
        } catch where HealthReader.isLocked(error) {
            log.debug("the phone is locked, so no edit could be applied; they wait")
            // The count is unknown here — the run failed on the way to it — so
            // the sentence says the condition and not a figure.
            deliveryStop = .sealedByLock(waiting: 0)
        } catch {
            log.error("applying edits failed: \(String(describing: error))")
            deliveryStop = .failed
        }
    }

    /// What the screen is owed about a run that ended, or nil when the run did
    /// its job. A locked phone is the one ending that is neither done nor
    /// wrong: the queue was read, and what is in it goes in at the unlock.
    private static func stopped(by outcome: Applier.Outcome) -> EditWords.DeliveryStop? {
        guard case let .locked(waiting) = outcome, waiting > 0 else { return nil }
        return .sealedByLock(waiting: waiting)
    }

    /// What a run leaves behind for the next unlock. Only a locked run leaves
    /// anything: every other outcome either emptied the queue or never reached
    /// it, and a stale count is worse than none.
    private static func heldByLock(in outcome: Applier.Outcome) -> Int {
        if case let .locked(waiting) = outcome {
            return waiting
        }
        return 0
    }

    // MARK: - What an agent changed

    /// The end of the journal, newest first, for the list.
    func recentEdits() -> [EditEntry] {
        do {
            return try store.recentEdits()
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    /// The same end of the journal gathered by record, which is what the list
    /// shows and what the person acts on.
    func recentRecords() -> [RecordHistory] {
        do {
            return try store.recordHistories()
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    /// The person has looked. What lands after this moment is what the dark
    /// strip on the everyday screen counts.
    func markEditsSeen() {
        do {
            try store.recordEditsSeen()
            refreshStats()
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Put Health back the way it was before this item.
    ///
    /// Possible at all because an app may change and remove what it wrote
    /// itself, which is also the limit on what an agent could do in the first
    /// place. A record already gone is not a failure — the journal simply
    /// catches up with Health, which is the one that decides.
    func act(on entry: EditEntry) async {
        await carryOut(entry)
        refreshStats()
        // The day is owed now, and the person is watching: a day that went up
        // on the next delivery would leave the archive disagreeing with Health
        // for an hour, with nothing on screen saying why.
        await sendNow()
    }

    /// Take back everything that has landed since the person last looked.
    ///
    /// The whole run at once, because that is what the strip on the everyday
    /// screen is about: a batch that has just arrived and is not wanted. An
    /// item that never happened has nothing to take back, and neither has a removal an older
    /// build wrote down without keeping what it took out; both are passed over
    /// rather than reported as failures.
    func actOnRecentRun() async {
        let seen = (try? store.editsSeenAt()) ?? .distantPast
        // By record, not by item: a record an agent wrote and then corrected
        // has two rows in the journal and one sample in Health, and acting on
        // both of them would remove it once and then fail looking for it.
        for record in recentRecords()
            where record.personCanAct && record.current.at > seen
        {
            await carryOut(record.current)
        }
        markEditsSeen()
        await sendNow()
    }

    /// Do to Health whatever this row leaves for the person, and write down
    /// which of the app's two operations that turned out to be. A row that
    /// displaced something is put right by writing that record back; a plain
    /// addition is put right by removing it.
    private func carryOut(_ entry: EditEntry) async {
        guard entry.personCanAct else { return }
        let left: EditEntry.State = entry.personRestores ? .written : .removed
        do {
            let days = try await put(entry)
            try store.recordPersonAction(entry.id, left: left)
            let marked = try store.markDirty(days)
            log.info(
                "the person \(left == .removed ? "removed" : "wrote back") a record: "
                    + "\(days.count) days changed, \(marked) newly waiting"
            )
            lastError = nil
        } catch WriteFailed.code(.notFound) {
            // Health has not got it, so there is nothing to take out and
            // nothing to mark: the day it was on changed when it went.
            do { try store.recordPersonAction(entry.id, left: left) } catch {
                lastError = String(describing: error)
            }
            log.info(
                "the person \(left == .removed ? "removed" : "wrote back") "
                    + "a record Health no longer had"
            )
        } catch where HealthReader.isLocked(error) {
            lastError = "Unlock the phone and try again — Health is sealed while it is locked."
        } catch {
            log.error(
                "the person's \(left == .removed ? "removal" : "write back") failed: "
                    + String(describing: error)
            )
            lastError = left == .removed
                ? "That record could not be taken out of Health. (\(error))"
                : "That record could not be written back into Health. (\(error))"
        }
    }

    /// Put Health back the way it was before this item, and answer the days
    /// that changed.
    ///
    /// Two shapes, and which one it is depends on whether the item pushed
    /// anything out. An addition is taken out again — there was nothing under
    /// that id before it, so removing it is the whole of putting it back. A
    /// replacement or a removal has a record waiting in the journal, and
    /// writing that record under the same id is what restores it: a `put`
    /// replaces what this app holds under an id, so the agent's version is
    /// displaced by the one it displaced, in a single step.
    ///
    /// The version is drawn fresh and the `written` ledger is left alone on the
    /// restoring path. HealthKit keeps the newest version it has seen for a
    /// sync identifier, so a restore written under a version it has already
    /// passed would be quietly ignored — which would read as a write back that
    /// did nothing at all.
    private func put(_ entry: EditEntry) async throws -> Set<String> {
        guard entry.personRestores else {
            let written = try await healthWriter.remove(id: entry.recordID)
            try store.forgetWritten(entry.recordID)
            return written.days
        }
        var days: Set<String> = []
        for record in entry.displaced {
            let version = try store.nextVersion(for: entry.recordID)
            let written = try await healthWriter.apply(
                record.asPut(id: entry.recordID), version: version
            )
            days.formUnion(written.days)
        }
        return days
    }

    /// Put the system's own permission sheet up, once.
    ///
    /// Guarded on `notDetermined` because iOS answers a second request with
    /// whatever was said the first time and draws nothing — so a caller that
    /// did not check would believe it had asked.
    func askForNotices() async {
        guard !demonstration else { return }
        guard await Notices.status() == .notDetermined else { return }
        await Notices.ask()
    }

    /// Ask about notices once an agent is connected — before it can write, not
    /// after it has.
    ///
    /// The walkthrough offers the question too, and this is what makes walking
    /// past it cost nothing: its "Not now" never shows the system sheet, so the
    /// permission is still undetermined and the question can be put again here.
    ///
    /// It used to wait until an agent had actually written something, which
    /// read as the more considerate order and guaranteed the opposite: the
    /// first edit — the one a person most wants to hear about — always landed
    /// in silence, because the permission was still being asked for. A
    /// connected agent is a thing that has just happened, and that is enough.
    ///
    /// The flag alone was not enough, though: it records that the setup text
    /// left this phone through this app's own share sheet, and an agent can be
    /// connected without that ever happening — the text was carried across from
    /// an older install, or typed over from another screen. Such a phone was
    /// never asked about notices at all, and every edit its agent made landed in
    /// a silence nothing explained. A journal with agent edits in it is the
    /// proof the flag was standing in for, so it asks too.
    func askForNoticesIfNeeded() async {
        guard agentConnected || edits.ever.total > 0 else { return }
        await askForNotices()
    }

    /// The first day Health has anything about, for the screen that offers a
    /// starting point. Nil when Health has nothing, or when it will not say.
    ///
    /// Being refused because nobody has answered Health yet is not a failure
    /// and is not reported as one: walking past the Health step is a choice the
    /// walkthrough offers, and this screen already says in plain words that
    /// Health has nothing to read yet.
    func firstDayInHealth() async -> String? {
        do {
            let day = try await health.firstDay()
            // Every look leaves a line, because the defect this replaced was
            // invisible from the outside: a screen showing an answer taken
            // three screens ago looks exactly like a screen that just asked.
            log.info("Health goes back to \(day ?? "no day at all")")
            lastError = nil
            return day
        } catch {
            log.info("Health would not say how far back it goes: \(error)")
            lastError = HealthReader.hasNotBeenAsked(error)
                ? nil
                : "Could not work out how far back Health goes. (\(error))"
            return nil
        }
    }

    /// Mark everything from the chosen day onwards, or from Health's own first
    /// record when no day was chosen, then send.
    ///
    /// The sending that follows takes as long as it takes and needs nobody
    /// watching — a day is either in the archive or still marked.
    func exportHistory(from day: String? = nil) async {
        await queueHistory(from: day)
        await sendNow()
    }

    /// The marking half of `exportHistory`, on its own so the walkthrough can
    /// say when it ends.
    ///
    /// Not quick on a first export. Marking a day is a row, but the first
    /// marking also reads every metric Health keeps once, so that later reads
    /// start from now (`HealthCoordinator.markHistory`) — about a minute for a
    /// decade, and nothing is sent until it is done.
    private func queueHistory(from day: String?) async {
        log.info("queueing history from \(day ?? "the first day Health has")")
        do {
            _ = try await health.markHistory(from: day)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        refreshStats()
    }

    // MARK: - Setup

    /// Make the archive if there is not one yet, then queue the chosen history.
    ///
    /// Creating the archive is not a decision anyone can make wrongly, so it is
    /// not a question either — it happens once the person has said how far back
    /// to go, and the screen that shows it is telling, not asking.
    func prepareArchive(startingFrom day: String?) async {
        preparation = .creatingArchive
        if destination == nil {
            await createArchive()
        }
        guard destination != nil else { return }
        // The button says "start syncing", so it starts: a pause left over from
        // an earlier life of this install would otherwise swallow the whole
        // first export in silence, and the uploader's own stop flag with it.
        // Nobody should have to find the button on the dial to begin.
        if paused {
            setPaused(false)
        }
        preparation = .readingHistory
        await queueHistory(from: day)
        preparation = .sending
        await sendNow()
    }

    /// The walkthrough is done. Written last, so a setup abandoned halfway
    /// starts again from the beginning rather than dropping the person into a
    /// screen about an archive that was never made.
    func finishSetup() {
        // Nothing to finish without an archive: the everyday screen is about
        // one, and would have nothing to say and nowhere to send.
        guard destination != nil else { return }
        UserDefaults.standard.set(true, forKey: Self.setupKey)
        offerHandoff = !agentConnected
        setupComplete = true
    }

    /// The everyday screen has opened the handoff sheet; it must not open it
    /// again by itself.
    func handoffOffered() {
        offerHandoff = false
    }

    /// The setup text has gone somewhere. Written down only when the share
    /// actually completed or the text was copied, never when a sheet was opened
    /// and dismissed.
    func markAgentConnected() {
        guard !agentConnected else { return }
        UserDefaults.standard.set(true, forKey: Self.connectedKey)
        agentConnected = true
    }

    // MARK: - Stopping and starting

    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if value {
            log.info("sending held back by hand")
        } else {
            log.info("sending let go again"
                + (asksWhileHeldBack > 0 ? ", after turning away \(asksWhileHeldBack) asks" : ""))
            asksWhileHeldBack = 0
        }
        UserDefaults.standard.set(value, forKey: Self.pausedKey)
        // The uploader stops itself, cancelling what is in the air. Without
        // this the button changed only what the next tap on it would do: every
        // finished batch starts the next pass from the upload session, which
        // never passes through here.
        uploaderIfPaired()?.setStopped(value)
        guard !value else { return }
        // Nothing was moving while it was held back, so the measurement behind
        // the time left has to begin again — carrying the pause into it would
        // read as an upload that had slowed to a crawl.
        markRunStart()
        // Starting again begins by re-reading Health, not by sending what is
        // already marked. That is what makes a separate "read and send now"
        // unnecessary: one button does both.
        rereading = true
        Task { [weak self] in
            defer { self?.rereading = false }
            await self?.refreshNow()
            await self?.sendNow()
        }
    }

    // MARK: - Storage

    private static let destinationKey = "destination"
    private static let setupKey = "setupComplete"
    private static let connectedKey = "agentConnected"
    private static let pausedKey = "sendingPaused"
    private static let batchKey = "batchTotal"

    /// The zone the ledger's days are cut on, falling back to the phone's own
    /// if the ledger cannot be asked. Falling back is not a silent repair: it is
    /// what the pin would have been anyway on the first run, and a phone whose
    /// ledger will not answer has larger trouble than a day boundary.
    private static func dayTimeZone(in store: Store) -> TimeZone {
        (try? store.dayTimeZone()) ?? .current
    }

    private static func loadDestination() -> Destination? {
        guard let data = UserDefaults.standard.data(forKey: destinationKey) else { return nil }
        return try? JSONDecoder().decode(Destination.self, from: data)
    }

    /// The stored archive, at the address this build carries, written down.
    ///
    /// The address was recorded once, when the archive was made, and nothing
    /// read it from the build again — so the phone kept sending to the host it
    /// was set up with after the service moved, and Cloudflare answered every
    /// upload with a page. The bucket comes from the reading key, so following
    /// the build moves nothing but where the same archive is reached.
    private static func movedToThisBuild(
        _ stored: Destination?, _ deployment: Deployment?
    ) -> Destination? {
        guard let stored, let deployment else { return stored }
        // Its own logger: this runs while the properties are still being made,
        // and nothing may be read off `self` until they all are.
        let log = Log(category: "services")
        do {
            let moved = try stored.following(deployment)
            guard moved != stored else { return stored }
            try UserDefaults.standard.set(JSONEncoder().encode(moved), forKey: destinationKey)
            log.info("the service has moved to \(moved.endpoint.absoluteString); sending there now")
            return moved
        } catch {
            // Keep sending where it was sending. A build with an address this
            // phone cannot use is a reason to say so, not to stop.
            log.error("could not follow the address in this build: \(String(describing: error))")
            return stored
        }
    }

    /// Named for what it holds. It is not an outbox — there is no queue of
    /// readings any more, only a row per day saying whether that day still has
    /// to go. A build that finds the older file simply starts fresh beside it
    /// rather than failing to open a shape it no longer understands.
    private static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("efferent", isDirectory: true)
            .appendingPathComponent("days.sqlite")
    }
}
