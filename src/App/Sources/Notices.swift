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
    static func tell(applied: Int, refused: Int, waiting: Int = 0) async {
        guard applied + refused + waiting > 0 else { return }
        guard await status() == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Efferent"
        content.body = sentence(applied: applied, refused: refused, waiting: waiting)
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        } catch {
            log.error("could not put up a notice: \(String(describing: error))")
        }
    }

    /// Never a metric and never a value: a notice is read on a lock screen, and
    /// what an agent wrote is nobody's business but the owner's. A count is the
    /// most it ever says.
    ///
    /// Anything waiting is said first and on its own, because it is the only
    /// notice this app puts up that asks for something. What else the same run
    /// did is on the screen, and a notice that tried to say both would bury the
    /// part a person has to act on.
    static func sentence(applied: Int, refused: Int, waiting: Int = 0) -> String {
        if waiting > 0 {
            return "Your agent wants to change \(records(waiting)) already in Health. "
                + "Open Efferent to allow it or turn it down."
        }
        if refused == 0 {
            return "Your agent changed \(records(applied)) in Health."
        }
        if applied == 0 {
            return "Your agent sent \(records(refused)) this phone could not write."
        }
        return "Your agent changed \(records(applied)) in Health, and \(refused) were refused."
    }

    private static func records(_ count: Int) -> String {
        count == 1 ? "1 record" : "\(count) records"
    }
}
