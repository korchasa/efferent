import Foundation

/// A calendar day, which is the address of everything this app sends.
///
/// Days are the person's own days, not UTC ones: "steps on the 7th" has to mean
/// what the Health app means by it, and a boundary at midnight UTC would put an
/// evening walk on the wrong date for most of the world.
///
/// The numbering, though, is always Gregorian. `Calendar.current` follows the
/// phone's region and can be Japanese or Buddhist, where the year is not 2026 —
/// which would name days nobody else could ask for. So the time zone comes from
/// the device and the calendar does not.
public enum Day {
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `2026-08-07` — the day `date` falls on.
    public static func of(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// When the day starts and when the next one does.
    ///
    /// The end is the next day's start rather than a moment just before it, so
    /// the two together are a half-open interval and no reading can fall
    /// between two days or land in both.
    public static func bounds(_ day: String, in calendar: Calendar) throws -> (start: Date, end: Date) {
        guard let start = date(day, in: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else {
            throw DayError.notADay(day)
        }
        return (start, end)
    }

    public static func next(_ day: String, in calendar: Calendar) throws -> String {
        try shift(day, by: 1, in: calendar)
    }

    public static func previous(_ day: String, in calendar: Calendar) throws -> String {
        try shift(day, by: -1, in: calendar)
    }

    /// Whether `earlier` is the day immediately before `later`.
    ///
    /// Answered without a time zone on purpose, and that is not a hole in the
    /// pinned boundary: which zone a day starts in decides *when* it begins, and
    /// this asks only which date comes before which. A day string is a Gregorian
    /// date and reads the same everywhere.
    public static func adjacent(_ earlier: String, before later: String) -> Bool {
        (try? previous(later, in: plainCalendar)) == earlier
    }

    /// Every day from `from` to `to`, both ends included.
    public static func range(from: String, to: String, in calendar: Calendar) throws -> [String] {
        guard from <= to else { return [] }
        var days: [String] = []
        var current = from
        while current <= to {
            days.append(current)
            current = try next(current, in: calendar)
            // A calendar without the day it was asked for — the hour a country
            // skipped when it moved its clock across midnight — would otherwise
            // spin here forever.
            guard days.count < 100_000 else { throw DayError.notADay(to) }
        }
        return days
    }

    public static func isValid(_ day: String, in calendar: Calendar) -> Bool {
        guard let parsed = date(day, in: calendar) else { return false }
        return of(parsed, in: calendar) == day
    }

    /// For arithmetic on day strings alone, where no boundary is being decided.
    private static let plainCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    private static func shift(_ day: String, by amount: Int, in calendar: Calendar) throws -> String {
        guard let start = date(day, in: calendar),
              let moved = calendar.date(byAdding: .day, value: amount, to: start)
        else {
            throw DayError.notADay(day)
        }
        return of(moved, in: calendar)
    }

    /// The start of `day`, or nil if that is not a date.
    ///
    /// `startOfDay` at the end rather than trusting the components: on the night
    /// a country moves its clocks forward, midnight itself does not exist, and
    /// `date(from:)` then answers with an hour that belongs to the day before.
    private static func date(_ day: String, in calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
              let moment = calendar.date(
                  from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12)
              )
        else {
            return nil
        }
        return calendar.startOfDay(for: moment)
    }
}

public enum DayError: Error, Equatable {
    case notADay(String)
}
