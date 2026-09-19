import Foundation
import UIKit

/// Runs a piece of work with the system asked not to suspend the app meanwhile.
///
/// iOS freezes a backgrounded app between one line and the next. A frozen app
/// is not waiting for its network request — it is doing nothing at all, while
/// the clock that request is measured against keeps running. On 2026-09-19 that
/// left one fetch frozen for 224 901 ms and another for 97 794 ms, and both
/// times the run that was frozen had been started by something other than the
/// wake. The wake handler was asking for time around its own call, which
/// returns in a moment when another run already holds the applier's pass, so
/// the promise was handed back while the real work was still in flight.
///
/// The promise therefore belongs here, around the work itself, whoever started
/// it — a wake, an unlock, a delivery from Health, the catch-up task or the
/// person tapping the button.
///
/// The work runs in a task of its own, which is what makes the two independent:
/// a caller that gives up waiting — the wake handler must answer the system
/// inside thirty seconds whatever the work is doing — cancels its own wait and
/// leaves this run to finish under its own protection.
@MainActor
func withTimeToFinish(
    _ name: String,
    log: Log,
    _ work: @escaping @MainActor () async -> Void
) async {
    // Asked before the work starts: the request is itself asynchronous, and one
    // made late loses the race it was meant to win.
    let borrowed = BorrowedTime(name, log: log)
    let job = Task { @MainActor in await work() }
    borrowed.stop(job)
    await job.value
    borrowed.giveBack()
}

/// A promise from the system not to suspend the app, and the one place it is
/// given back.
///
/// Giving it back twice is a crash and never giving it back gets the app
/// killed, so the counting lives here and nowhere else.
@MainActor
private final class BorrowedTime {
    private var assertion = UIBackgroundTaskIdentifier.invalid
    private var returned = false
    private var job: Task<Void, Never>?

    init(_ name: String, log: Log) {
        assertion = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Worth a line: from here the run is cut short, and what it was
            // doing is finished by whatever triggers next. Without this line
            // that reads as a run that simply stopped.
            log.error("the system took back the time given to \(name)")
            self?.job?.cancel()
            self?.giveBack()
        }
    }

    /// The run to stop if the system takes its time back. Handed over after the
    /// run starts, since the promise is asked for first.
    func stop(_ job: Task<Void, Never>) {
        guard !returned else {
            job.cancel()
            return
        }
        self.job = job
    }

    func giveBack() {
        guard !returned else { return }
        returned = true
        if assertion != .invalid {
            UIApplication.shared.endBackgroundTask(assertion)
            assertion = .invalid
        }
    }
}
