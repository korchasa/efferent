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
            guard let uploader = Services.shared.uploaderIfConfigured() else {
                completionHandler()
                return
            }
            uploader.backgroundEventsFinished = completionHandler
            uploader.adoptBackgroundSession()
        }
    }
}
