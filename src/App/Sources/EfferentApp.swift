import BackgroundTasks
import SwiftUI

@main
struct EfferentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // The store screenshots are made by this same binary, offscreen, and
        // it quits before any of the real machinery below wakes up.
        if Snapshot.runIfAsked() {
            exit(0)
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(Services.shared)
        }
        // A launch with a screen is the only kind that can show the system
        // sheet, and the applier waits until one has. Asked here rather than
        // on the way into sending, because sending mostly happens in launches
        // nobody is looking at. This is the scene's own signal: an app built
        // on scenes never has `applicationDidBecomeActive` called on its
        // delegate, so a request made there would never be made.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { @MainActor in
                await Services.shared.askForWriteAccessIfNeeded()
                // Second, and only ever after the first: two system sheets at
                // once is one question nobody reads.
                await Services.shared.askForNoticesIfNeeded()
                // Coming to the front is a trigger of its own, said out loud.
                // It looked like one before this line existed, because a resume
                // is when Health hands over what it held back — which made the
                // inbound direction work by coincidence and fail on a phone
                // lying still with the app open.
                await Services.shared.deliverEdits()
            }
        }
    }
}

/// Answers the system once, however the woken work ends.
///
/// A wake has three endings — the work finished, it ran past its budget, or
/// the system said the app was about to be suspended anyway — and each of them
/// has to do two things: report a result, and give back the promise not to be
/// suspended. Doing either twice is a crash, doing either never is an app the
/// system terminates, so both are counted here and nowhere else.
@MainActor
private final class WakeAnswer {
    private let report: (UIBackgroundFetchResult) -> Void
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var answered = false

    init(report: @escaping (UIBackgroundFetchResult) -> Void) {
        self.report = report
    }

    func hold(_ assertion: UIBackgroundTaskIdentifier) {
        guard !answered else {
            // The work beat the assertion, which is possible because asking is
            // itself asynchronous. Give it straight back.
            UIApplication.shared.endBackgroundTask(assertion)
            return
        }
        self.assertion = assertion
    }

    /// - Returns: whether this was the ending that counted.
    @discardableResult
    func finish(_ result: UIBackgroundFetchResult) -> Bool {
        guard !answered else { return false }
        answered = true
        report(result)
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
        return true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let refreshTaskIdentifier = "dev.korchasa.efferent.refresh"

    /// How long the woken work may take before the system is answered without
    /// it.
    ///
    /// Apple allows thirty seconds of wall-clock time to handle a wake and
    /// terminates an app that has not answered by then. Twenty is room for a
    /// slow network with the rest left for answering and winding down. Nothing
    /// is lost by cutting a run short: the edit stays in the queue and the
    /// floor finds it.
    private static let wakeBudget = Duration.seconds(20)

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

        // Every launch, because the token belongs to Apple: a restore, a
        // reinstall or a new phone each produce a different one, and asking is
        // the only way to find out. Nothing is shown and nobody is asked.
        Services.shared.registerForWake()

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
            // Awake, with a network, for a reason of the system's own choosing.
            // A launch that does not ask makes the person wait for the next one.
            await Services.shared.deliverEdits()
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

    /// The screen was unlocked, so Health will take a write again.
    ///
    /// This is the one moment edits that arrived on a locked phone can finally
    /// land, and without it they would wait for whatever woke the app next —
    /// which on a quiet phone is the catch-up task, hours away.
    func applicationProtectedDataDidBecomeAvailable(_: UIApplication) {
        log.debug("the phone was unlocked, so Health will take a write again")
        Task { @MainActor in
            await Services.shared.deliverEdits()
            await Services.shared.sendNow()
        }
    }

    func application(
        _: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken token: Data
    ) {
        Task { @MainActor in
            await Services.shared.recordDeviceToken(token)
        }
    }

    func application(
        _: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Worth a line: from here on the phone finds edits only when something
        // else wakes it, which looks from the outside like a slow service.
        log.error("apple would not say how to reach this phone: \(String(describing: error))")
    }

    /// The service says something is waiting.
    ///
    /// The push carries nothing — no count, no name, no day — so there is
    /// nothing here to read. It is a moment of being awake with a network, and
    /// what the app does with it is the same fetch it makes when it is opened.
    ///
    /// The result matters: the system counts what a wake produced, and an app
    /// that always answers `.noData` is woken less often. So this says what
    /// actually happened.
    ///
    /// The handler rather than the `async` form of this method: the payload is
    /// a dictionary of `Any`, which cannot cross into a main-actor method, and
    /// this app has nothing to read out of it anyway.
    ///
    /// Two promises are made to the system here and both have to be kept. The
    /// first is "do not suspend me while this runs": without it the app can be
    /// put to sleep a moment after the wake arrives, and on 2026-09-19 that
    /// left a fetch frozen for 224 901 ms, far past the thirty seconds a wake
    /// is allowed — after which the system stopped delivering wakes at all,
    /// silently. The second is "here is what came of it", which has to be said
    /// inside those thirty seconds whatever the work is doing.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification _: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let answer = WakeAnswer(report: completionHandler)
        // Asked before the work starts, because asking is itself asynchronous
        // and a request made at the last moment can lose the race with the
        // suspension it was meant to prevent.
        answer.hold(application.beginBackgroundTask(withName: "woken by the archive") { [weak self] in
            self?.log.error("the system took back the time the wake was given")
            answer.finish(.failed)
        })

        let work = Task { @MainActor in
            let before = Services.shared.edits.unseen.total
            await Services.shared.wokenByService()
            answer.finish(Services.shared.edits.unseen.total == before ? .noData : .newData)
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.wakeBudget)
            guard answer.finish(.failed) else { return }
            self.log.error("the woken work outlasted its budget; the system was answered without it")
            work.cancel()
        }
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
            // Before the lock is looked at, because the queue can be listed
            // through a lock even though Health cannot be written to. On a
            // quiet locked phone this task is the only thing running, and
            // without this line the screen would have nothing to say about
            // edits that arrived overnight.
            await Services.shared.deliverEdits()
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
