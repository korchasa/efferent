import Foundation
import os

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
    let identity = DeviceIdentity()
    let readingIdentity = ReadingIdentity()
    let deployment: Deployment?
    let deploymentError: String?
    private let log = Log(category: "services")

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

    private init() {
        do {
            store = try Store(url: Self.storeURL())
        } catch {
            // The app has nothing to do without it, and carrying on would
            // silently forget every day that still has to go. Better to stop
            // where the cause is still visible.
            fatalError("could not open the day store: \(error)")
        }
        health = HealthCoordinator(store: store)
        // Held locally as well as stored: the flag below is decided before the
        // rest of the properties exist, and until they do nothing may be read
        // back off `self`.
        let loaded = Self.loadDestination()
        destination = loaded
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
            try UserDefaults.standard.set(JSONEncoder().encode(created), forKey: Self.destinationKey)
            destination = created
            uploader = nil
            lastError = nil
            refreshConnectionHandoff()
            refreshStats()
            log.info("created bucket \(created.bucket)")
            await sendNow()
        } catch {
            lastError = "Could not create the archive. (\(error))"
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
            connectionHandoff = ConnectionHandoff(
                deployment: deployment,
                destination: destination,
                privateKey: privateKey.rawRepresentation
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
        do {
            try identity.forget()
            try readingIdentity.forget()
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

    // MARK: - Actions

    func setError(_ message: String?) {
        lastError = message
    }

    func refreshStats() {
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

    func refreshNow() async {
        do {
            _ = try await health.refresh()
            lastError = nil
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
            log.info("asked to send while held back; nothing was sent")
            return
        }
        guard let uploader = uploaderIfPaired() else {
            log.error("asked to send with no archive to send to")
            lastError = "No archive has been created yet."
            return
        }
        do {
            let outcome = try await uploader.send()
            log.info("send outcome: \(String(describing: outcome))")
            lastError = nil
        } catch {
            log.error("send failed: \(String(describing: error))")
            lastError = String(describing: error)
        }
        refreshStats()
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
        log.info(value ? "sending held back by hand" : "sending let go again")
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

    private static func loadDestination() -> Destination? {
        guard let data = UserDefaults.standard.data(forKey: destinationKey) else { return nil }
        return try? JSONDecoder().decode(Destination.self, from: data)
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
