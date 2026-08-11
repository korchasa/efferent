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
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "services")

    @Published private(set) var stats: Stats?
    @Published private(set) var lastError: String?
    @Published private(set) var destination: Destination?

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
        health.onNewData = { [weak self] in
            Task { @MainActor in await self?.sendNow() }
        }
    }

    // MARK: - Pairing

    /// Take the scanned code and remember where this phone writes.
    ///
    /// Nothing here is secret, so it lives in user defaults rather than the
    /// Keychain: an address and a public key. The one secret the device owns —
    /// its signing key — is made separately and never leaves the Keychain.
    func pair(withScannedCode code: String) {
        do {
            let paired = try Pairing.parse(code)
            try UserDefaults.standard.set(JSONEncoder().encode(paired), forKey: Self.destinationKey)
            destination = paired
            uploader = nil
            lastError = nil
            log.info("paired with bucket \(paired.bucket, privacy: .public)")
        } catch {
            lastError = "That code is not an Efferent pairing code. (\(error))"
        }
    }

    /// Forget where to send. The signing key goes too, so the bucket it claimed
    /// can never be written to again — which is why this asks first.
    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Self.destinationKey)
        destination = nil
        uploader = nil
        do {
            try identity.forget()
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
            build: { [health] days in try await health.build(days: days) }
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
            lastError = "Not paired with a reader yet."
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
