import Foundation
import UserNotifications

/// The one thing this app ever puts on the lock screen.
///
/// Sending happens in launches nobody sees, so an edit lands while the phone is
/// in a pocket. Everything else this app does is the person's own doing and
/// needs no announcement; an agent writing into Health is not, and it is the
/// one thing they might want to know about before they next open the app.
enum Notices {
    /// One identifier for every notice, so a second run replaces the first
    /// rather than stacking beside it. What matters is the latest state, and a
    /// column of near-identical lines is how a person learns to swipe them away
    /// without reading.
    private static let identifier = "agent-edits"
    private static let log = Log(category: "notices")

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Ask for permission. The caller decides when: asking before an agent has
    /// ever written anything is asking about something the person has no reason
    /// to have an opinion about yet.
    static func ask() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            log.info("notices \(granted ? "allowed" : "refused")")
        } catch {
            log.error("could not ask about notices: \(String(describing: error))")
        }
    }

    /// Say what a run did, if there is anybody to say it to.
    static func tell(written: Int, removed: Int, failed: Int) async {
        guard written + removed + failed > 0 else { return }
        let standing = await status()
        // The one silence that used to leave no trace. A phone nobody ever
        // asked and a phone that said no both dropped every notice without a
        // word, so the log — the only account of a launch nobody watched —
        // could not tell the two apart, or tell either from an agent that had
        // written nothing at all.
        guard standing == .authorized else {
            log.info(
                "said nothing about \(written + removed + failed) records: "
                    + "notices are \(String(describing: standing))"
            )
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Efferent"
        content.body = sentence(written: written, removed: removed, failed: failed)
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
            // A step that did something, so it is written down. Without it the
            // log could say why a notice was dropped but never that one was
            // put up, and "it was posted and nobody saw it" could not be told
            // apart from "it was never posted" — which is a whole evening of
            // guessing about a launch nobody watched.
            log.info("said: \(content.body)")
        } catch {
            log.error("could not put up a notice: \(String(describing: error))")
        }
    }

    /// Never a metric and never a value: a notice is read on a lock screen, and
    /// what an agent wrote is nobody's business but the owner's. A count is the
    /// most it ever says.
    ///
    /// It tells rather than asks. Nothing an agent sends waits for an answer
    /// any more, so the one thing this notice is for is letting somebody who is
    /// not looking at the phone know that their Health changed — and, if they
    /// did not want it, open the app and take it back.
    ///
    /// The two operations are named by the same two verbs the journal and the
    /// list use, and a run that did both says both: one word for what happened
    /// to a record, wherever a person meets it.
    static func sentence(written: Int, removed: Int, failed: Int) -> String {
        if written + removed == 0 {
            return "Your agent sent \(records(failed)) this phone could not write."
        }
        if failed == 0 {
            return "Your agent changed Health: \(operations(written: written, removed: removed))."
        }
        return "Your agent changed Health: "
            + "\(operations(written: written, removed: removed)), and \(failed) did not happen."
    }

    /// "2 records written", "1 record removed", "2 written, 1 removed" — the
    /// unit is said once, and a mixed run lists both rather than folding them
    /// into a word that names neither.
    private static func operations(written: Int, removed: Int) -> String {
        if removed == 0 {
            return "\(records(written)) written"
        }
        if written == 0 {
            return "\(records(removed)) removed"
        }
        return "\(written) written, \(removed) removed"
    }

    private static func records(_ count: Int) -> String {
        count == 1 ? "1 record" : "\(count) records"
    }
}
