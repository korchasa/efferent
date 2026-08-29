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

    /// A safety net under background delivery, not a schedule.
    ///
    /// The system decides when this runs — sometimes hourly, sometimes not for
    /// half a day — so nothing may depend on it firing. It exists to catch up
    /// after a stretch where Health had nothing to report but an upload was
    /// still owed.
    private func scheduleRefresh() {
        let request = BGProcessingTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleRefresh(_ task: BGTask) {
        scheduleRefresh() // always re-arm first; an early return would end the chain
        log.info("the system ran the catch-up task")

        let work = Task { @MainActor in
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
