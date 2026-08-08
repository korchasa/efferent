import Foundation
import os

/// Composition root: builds the store and the uploader once and hands them out.
///
/// Everything below this line is plain values and can be constructed in a test;
/// this is the only place that knows about the file system and user defaults.
@MainActor
final class Services: ObservableObject {
    static let shared = Services()

    let store: Store
    let health: HealthCoordinator
    let tokens = TokenStore()
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "services")

    @Published private(set) var stats: Stats?
    @Published private(set) var lastError: String?
    @Published private(set) var backfill: String?

    private var uploader: Uploader?

    private init() {
        do {
            store = try Store(url: Self.storeURL())
        } catch {
            // The app has nothing to do without its outbox, and carrying on
            // would silently drop every reading. Better to stop where the cause
            // is still visible.
            fatalError("could not open the outbox: \(error)")
        }
        health = HealthCoordinator(store: store)
        health.onNewData = { [weak self] in
            Task { @MainActor in await self?.sendNow() }
        }
    }

    /// Where the endpoint lives. Not a secret, unlike the token beside it.
    var endpoint: URL? {
        get { UserDefaults.standard.url(forKey: "endpoint") }
        set {
            UserDefaults.standard.set(newValue, forKey: "endpoint")
            uploader = nil
            objectWillChange.send()
        }
    }

    func uploaderIfConfigured() -> Uploader? {
        if let uploader { return uploader }
        guard let endpoint else { return nil }
        let built = Uploader(configuration: .init(endpoint: endpoint), store: store)
        uploader = built
        return built
    }

    func setError(_ message: String?) {
        lastError = message
    }

    func storeToken(_ token: String) {
        do {
            try tokens.save(token)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func refreshStats() {
        do {
            stats = try store.stats()
        } catch {
            lastError = String(describing: error)
        }
    }

    func sendNow() async {
        guard let uploader = uploaderIfConfigured() else {
            lastError = "No endpoint configured yet."
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

    func requestHealthAccess() async {
        do {
            try await health.requestAuthorization()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func collectNow() async {
        do {
            _ = try await health.collectEverythingRecent()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        refreshStats()
    }

    /// The first export. Runs on screen because Health can hold years and a
    /// background wake-up gets about thirty seconds.
    func runFirstExport() async {
        backfill = "starting…"
        do {
            try await health.backfill { step in
                Task { @MainActor [weak self] in
                    self?.backfill = "\(step.metric) — back to \(step.reached.formatted(date: .abbreviated, time: .omitted))"
                }
            }
            backfill = "done"
            lastError = nil
        } catch {
            backfill = nil
            lastError = String(describing: error)
        }
        refreshStats()
    }

    private static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("efferent", isDirectory: true)
            .appendingPathComponent("outbox.sqlite")
    }
}
