import Foundation

/// The first day Health has anything about, as a screen knows it.
///
/// SETUP-1 and SETUP-2 are what this type is for.
///
/// Health never says whether it will answer. A phone nobody has been asked
/// about yet and a phone whose Health is empty both come back with nothing, so
/// this is not a fact that can be fetched once and kept — it is only ever what
/// the last look found. A screen that offers a range therefore looks again
/// every time it appears, instead of showing an answer taken earlier in the
/// same launch.
///
/// The walkthrough is where that mattered. It asked on its first screen, three
/// steps before the Health sheet had been shown, and the fourth step then
/// offered "Everything Health has" while printing "Health has nothing to read
/// yet" underneath it — a phone with 90 days of readings, told it had none
/// (owner, 2026-09-20). The days themselves were never at risk: a range with no
/// first day falls back to Health's own first record when the history is
/// marked. What was wrong was the sentence, and a setup screen that lies about
/// what is about to be sent is the one place this app cannot afford one.
@MainActor
final class EarliestDay: ObservableObject {
    /// What the last look found, or nil when it found nothing.
    @Published private(set) var day: String?

    /// Whether Health has been looked at at all. Without it, "Health has
    /// nothing" and "nobody has looked yet" are the same nil, and a row would
    /// say it was working it out forever at somebody whose Health is empty.
    @Published private(set) var looked = false

    /// Look again, and keep what this look found.
    ///
    /// The answer replaces the previous one rather than filling a blank: the
    /// date on the screen has to be the date this phone would send from now,
    /// not the date it would have sent from when the question was first asked.
    func look(_ read: () async -> String?) async {
        day = await read()
        looked = true
    }
}
