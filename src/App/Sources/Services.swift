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
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "services")

    @Published private(set) var stats: Stats?
    @Published private(set) var lastError: String?
    @Published private(set) var destination: Destination?
    @Published private(set) var connectionHandoff: ConnectionHandoff?

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
        destination = Self.loadDestination()
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
            log.info("created bucket \(created.bucket, privacy: .public)")
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
        UserDefaults.standard.removeObject(forKey: Self.destinationKey)
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
        uploader = built
        return built
    }

    // MARK: - Actions

    func setError(_ message: String?) {
        lastError = message
    }

    func refreshStats() {
        do {
            stats = try store.stats()
        } catch {
            lastError = String(describing: error)
        }
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
        guard let uploader = uploaderIfPaired() else {
            lastError = "No archive has been created yet."
            return
        }
        do {
            let outcome = try await uploader.send()
            log.info("send outcome: \(String(describing: outcome), privacy: .public)")
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        refreshStats()
    }

    /// The first export: find how far Health goes back and mark every day since.
    ///
    /// Quick, because marking a day is a row and nothing more. The sending that
    /// follows takes as long as it takes and needs nobody watching — a day is
    /// either in the archive or still marked.
    func exportEverything() async {
        do {
            _ = try await health.markHistory()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        refreshStats()
        await sendNow()
    }

    // MARK: - Storage

    private static let destinationKey = "destination"

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
