import BackgroundTasks
import SwiftUI

@main
struct EfferentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(Services.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskIdentifier = "dev.korchasa.efferent.refresh"

    private let log = Log(category: "app")

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Synchronously, right here. The system launches this app in the
        // background with no interface; an observer registered from a `Task` or
        // when a view appears would not exist during that launch, and the
        // delivery that caused it would be lost.
        log.info("launched \(UIApplication.shared.applicationState == .background ? "in the background" : "by hand")")
        log.debug(Self.situation())
        Services.shared.health.startObserving()

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil
        ) { task in
            self.handleRefresh(task)
        }
        scheduleRefresh()
        return true
    }

    func application(
        _: UIApplication,
        handleEventsForBackgroundURLSession _: String,
        completionHandler: @escaping () -> Void
    ) {
        // iOS relaunched the app only to hand over transfers that finished while
        // it was gone. Re-create the session so its delegate can be called, and
        // hold on to the handler until it says it has reported everything —
        // returning early makes the system count the app as unresponsive.
        log.info("relaunched to finish transfers started earlier")
        Task { @MainActor in
            guard let uploader = Services.shared.uploaderIfPaired() else {
                self.log.error("relaunched for transfers, but this phone has no archive to send to")
                completionHandler()
                return
            }
            uploader.backgroundEventsFinished = completionHandler
            uploader.adoptBackgroundSession()
        }
    }

    /// The conditions sending depends on and nothing in the app controls. Every
    /// one of them silently stops a phone from sending, and each looks from the
    /// inside exactly like an app that simply had nothing to do.
    private static func situation() -> String {
        let refresh: String
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: refresh = "background refresh on"
        case .denied: refresh = "background refresh OFF"
        case .restricted: refresh = "background refresh restricted"
        @unknown default: refresh = "background refresh unknown"
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let power = ProcessInfo.processInfo.isLowPowerModeEnabled ? "low power mode ON" : "low power mode off"
        return "\(version) (\(build)) · iOS \(UIDevice.current.systemVersion) · \(refresh) · \(power)"
    }

    func applicationDidEnterBackground(_: UIApplication) {
        log.debug("the app went into the background")
    }

    func applicationWillEnterForeground(_: UIApplication) {
        log.debug("the app came back to the front")
    }

    /// A safety net under background delivery, not a schedule.
    ///
    /// The system decides when this runs — sometimes hourly, sometimes not for
    /// half a day — so nothing may depend on it firing. It exists to catch up
    /// after a stretch where Health had nothing to report but an upload was
    /// still owed.
    /// - Parameter announce: written down only where it is news. Re-arming from
    ///   the handler happens on every catch-up launch, one line after the line
    ///   saying the task ran, and two identical sentences a second apart read as
    ///   a duplicate rather than as a chain. A refusal is written down either way.
    private func scheduleRefresh(announce: Bool = true) {
        let request = BGProcessingTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            if announce {
                log.debug("asked the system for a catch-up task")
            }
        } catch {
            // Worth knowing about: with no catch-up task the phone sends only
            // when Health wakes it, and this is the one place that would say so.
            log.error("the system refused the catch-up task: \(String(describing: error))")
        }
    }

    private func handleRefresh(_ task: BGTask) {
        scheduleRefresh(announce: false) // always re-arm first; an early return would end the chain
        log.info("the system ran the catch-up task")

        let work = Task { @MainActor in
            // Everything below reads Health, and Health is sealed while the
            // screen is locked — which is most of when this task runs. Going in
            // anyway costs a ledger read and the start of a build, and comes
            // back with an error that describes the lock rather than a fault.
            guard UIApplication.shared.isProtectedDataAvailable else {
                self.log.info("the phone is locked, so Health is out of reach; this catch-up waits")
                task.setTaskCompleted(success: true)
                return
            }
            await Services.shared.refreshNow()
            await Services.shared.sendNow()
            self.log.info("catch-up task finished")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            self.log.error("the system took the catch-up task back before it finished")
            work.cancel()
        }
    }
}
