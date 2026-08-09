import BackgroundTasks
import SwiftUI

@main
struct EfferentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(Services.shared)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskIdentifier = "dev.korchasa.efferent.refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Synchronously, right here. The system launches this app in the
        // background with no interface; an observer registered from a `Task` or
        // when a view appears would not exist during that launch, and the
        // delivery that caused it would be lost.
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
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // iOS relaunched the app only to hand over transfers that finished while
        // it was gone. Re-create the session so its delegate can be called, and
        // hold on to the handler until it says it has reported everything —
        // returning early makes the system count the app as unresponsive.
        Task { @MainActor in
            guard let uploader = Services.shared.uploaderIfPaired() else {
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
        scheduleRefresh()   // always re-arm first; an early return would end the chain

        let work = Task { @MainActor in
            await Services.shared.collectNow()
            await Services.shared.sendNow()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
}
