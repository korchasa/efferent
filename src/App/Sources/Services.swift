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

    private var uploader: Uploader?
    private var applier: Applier?
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
            deployment = try Deployment.load()
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
        // editor key the service has never heard of.
        if destination != nil {
            Task { [weak self] in await self?.ensureEditorRegistered() }
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
            try await ArchiveCreator.create(destination: created, identity: identity)
            _ = try store.activateArchive(created.bucket)
            _ = try store.activateSealingVersion(Int64(SealedBox.version))
            _ = try store.activateDayFormat(Int64(dayFormatVersion))
            try UserDefaults.standard.set(JSONEncoder().encode(created), forKey: Self.destinationKey)
            destination = created
            uploader = nil
            applier = nil
            lastError = nil
            refreshConnectionHandoff()
            refreshStats()
            log.info("created bucket \(created.bucket)")
            await ensureEditorRegistered()
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
                editorPublicKey: key.publicKey.rawRepresentation
            )
            try store.recordEditorRegistered(for: destination.bucket)
            log.info("the editor key is registered with the archive")
            refreshConnectionHandoff()
        } catch {
            log.error("could not register the editor key: \(String(describing: error))")
        }
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
    func disconnect() {
        log.info("disconnected: this phone forgets the archive and its keys")
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
        uploader = nil
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
                try await health.reconcile(with: Archive(destination: destination))
            }
        )
        // Days land on the upload session's own queue, with no view in sight.
        // Without this the counters only change when the screen reappears,
        // which reads as a stall while data is going up fine.
        built.didStoreDay = { [weak self] in
            Task { @MainActor in self?.refreshStats() }
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
            writer: HealthKitWriter(calendar: calendar),
            fetch: Applier.session()
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
        // Edits first, days second: what an edit changes is a day that then
        // goes up in the same pass. The pause above holds edits back exactly as
        // it holds days back.
        await applyEdits()
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
            lastError = nil
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

    /// Write what the agent asked for into Health and owe the days it changed.
    ///
    /// A failure is written down and does not stop the send behind it: the
    /// edits stay in the queue, and the days already changed are marked
    /// whatever stopped the run.
    private func applyEdits() async {
        await ensureEditorRegistered()
        guard let applier = applierIfPaired() else { return }
        do {
            let outcome = try await applier.run()
            guard case let .applied(applied) = outcome else { return }
            if !applied.days.isEmpty {
                let marked = try store.markDirty(applied.days)
                log.info("\(applied.days.count) days changed by edits, \(marked) newly waiting")
            }
        } catch where HealthReader.isLocked(error) {
            log.debug("the phone is locked, so no edit could be applied; they wait")
        } catch {
            log.error("applying edits failed: \(String(describing: error))")
        }
    }

    /// The first day Health has anything about, for the screen that offers a
    /// starting point. Nil when Health has nothing, or when it will not say.
    func firstDayInHealth() async -> String? {
        do {
            let day = try await health.firstDay()
            lastError = nil
            return day
        } catch {
            lastError = "Could not work out how far back Health goes. (\(error))"
            return nil
        }
    }

    /// Mark everything from the chosen day onwards, or from Health's own first
    /// record when no day was chosen.
    ///
    /// Quick, because marking a day is a row and nothing more. The sending that
    /// follows takes as long as it takes and needs nobody watching — a day is
    /// either in the archive or still marked.
    func exportHistory(from day: String? = nil) async {
        log.info("queueing history from \(day ?? "the first day Health has")")
        do {
            _ = try await health.markHistory(from: day)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        refreshStats()
        await sendNow()
    }

    // MARK: - Setup

    /// Make the archive if there is not one yet, then queue the chosen history.
    ///
    /// Creating the archive is not a decision anyone can make wrongly, so it is
    /// not a question either — it happens once the person has said how far back
    /// to go, and the screen that shows it is telling, not asking.
    func prepareArchive(startingFrom day: String?) async {
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
        await exportHistory(from: day)
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
        Task { [weak self] in
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
