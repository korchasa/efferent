import SwiftUI

/// How an edit is said on screen.
///
/// Kept apart from the views because it is nearly all of what these screens
/// are: the journal holds wire names, whole seconds and one-word codes, and
/// none of those are things to put in front of a person.
enum EditWords {
    struct Field {
        let name: String
        let value: String
        /// Printed as it came rather than in small capitals. The agent's id is
        /// the one value on these screens that is data instead of a word: it is
        /// case-sensitive, and a person hands it back to their agent to talk
        /// about this record.
        var verbatim = false
    }

    /// The dial's own vocabulary: accent for what is standing, alarm for what
    /// was turned away, legend for what is no longer there.
    static func colour(_ state: EditEntry.State) -> Color {
        switch state {
        case .applied: Palette.accent
        case .refused: Palette.alarm
        // Waiting is among them now: an older version of the app held items
        // back for an answer, and those rows are history like the rest.
        case .deleted, .undone, .declined, .waiting: Palette.legend
        }
    }

    // MARK: - A run, counted

    /// What a run did, for the strip across the top of the everyday screen.
    static func summary(_ tally: EditTally) -> String {
        var parts: [String] = []
        if tally.applied > 0 {
            parts.append("changed \(records(tally.applied))")
        }
        if tally.deleted > 0 {
            parts.append("removed \(records(tally.deleted))")
        }
        if tally.refused > 0 {
            parts.append("had \(records(tally.refused)) refused")
        }
        guard !parts.isEmpty else { return "Your agent changed nothing." }
        return "Your agent " + list(parts) + " in Health."
    }

    /// The same counts as a legend, for the row above the keys: "3 applied,
    /// 1 refused".
    static func counted(_ tally: EditTally) -> String {
        var parts: [String] = []
        if tally.waiting > 0 {
            parts.append("\(tally.waiting) never answered")
        }
        if tally.applied > 0 {
            parts.append("\(tally.applied) applied")
        }
        if tally.deleted > 0 {
            parts.append("\(tally.deleted) removed")
        }
        if tally.refused > 0 {
            parts.append("\(tally.refused) refused")
        }
        if tally.declined > 0 {
            parts.append("\(tally.declined) turned down")
        }
        if tally.undone > 0 {
            parts.append("\(tally.undone) undone")
        }
        return parts.isEmpty ? "no edits" : parts.joined(separator: ", ")
    }

    // MARK: - The question

    static func records(_ count: Int) -> String {
        count == 1 ? "1 record" : "\(count) records"
    }

    /// "a", "a and b", "a, b and c" — the way a sentence lists things, which no
    /// join with commas alone ever reads as.
    private static func list(_ parts: [String]) -> String {
        guard let last = parts.last else { return "" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - A row

    /// The metric and its value: "Water · 100 mL", "Sleep · asleep 7 h 10 min".
    static func title(_ entry: EditEntry) -> String {
        guard let metric = entry.metric else {
            if entry.recordID.isEmpty {
                return "An edit this phone could not read"
            }
            switch entry.state {
            case .waiting: return "A record your agent wanted to remove"
            case .declined: return "A removal you turned down"
            default: return "A record your agent removed"
            }
        }
        let name = WritableMetric.named(metric)?.spoken ?? metric
        if let stage = entry.stage {
            let word = WritableMetric.sleepStageWords[stage] ?? stage
            guard let length = length(entry) else { return "\(name) · \(word)" }
            return "\(name) · \(word) \(length)"
        }
        guard let value = entry.value else { return name }
        return "\(name) · \(figure(value))" + (entry.unit.map { " " + $0 } ?? "")
    }

    /// When the edit arrived, and what it did — or why it did not.
    static func detail(_ entry: EditEntry, in calendar: Calendar) -> String {
        let arrived = clock(entry.at, in: calendar)
        switch entry.state {
        case .undone:
            guard let undoneAt = entry.undoneAt else { return "\(arrived) · undone" }
            return "\(arrived) · undone at \(clock(undoneAt, in: calendar))"
        case .refused:
            return "\(arrived) · " + (entry.code.map(reason) ?? "refused")
        case .deleted:
            guard let day = entry.day else { return "\(arrived) · removed a record" }
            return "\(arrived) · removed a record from \(spoken(day: day))"
        case .declined:
            return "\(arrived) · you turned this down"
        case .waiting:
            if let span = span(entry, in: calendar) {
                return "\(arrived) · \(span)"
            }
            // A removal names no instant, so its day is all there is to say
            // about what it would take away.
            guard let day = entry.day else { return "\(arrived) · never written" }
            return "\(arrived) · a record from \(spoken(day: day))"
        case .applied:
            guard let span = span(entry, in: calendar) else { return arrived }
            return "\(arrived) · \(span)"
        }
    }

    /// "today", "yesterday", or the date itself.
    static func when(_ day: String, in calendar: Calendar) -> String {
        let today = Day.of(Date(), in: calendar)
        if day == today {
            return "today"
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())
            .map { Day.of($0, in: calendar) }
        if day == yesterday {
            return "yesterday"
        }
        return spoken(day: day)
    }

    // MARK: - One edit, in full

    static func fields(_ entry: EditEntry, in calendar: Calendar) -> [Field] {
        var fields: [Field] = []
        if let metric = entry.metric {
            let name = WritableMetric.named(metric)?.spoken ?? metric
            let stage = entry.stage.flatMap { WritableMetric.sleepStageWords[$0] ?? $0 }
            fields.append(Field(name: "metric", value: stage.map { "\(name), \($0)" } ?? name))
        }
        if let length = length(entry) {
            fields.append(Field(name: "length", value: length))
        } else if let value = entry.value {
            fields.append(
                Field(name: "value", value: figure(value) + (entry.unit.map { " " + $0 } ?? ""))
            )
        }
        if let start = entry.start {
            fields.append(Field(name: "from", value: stamp(start, in: calendar)))
        }
        if let end = entry.end, end != entry.start {
            fields.append(Field(name: "to", value: stamp(end, in: calendar)))
        }
        if let code = entry.code {
            switch entry.state {
            // The same column, and not the word "refused": nothing has been
            // turned away here, and nothing has been written either.
            case .waiting: fields.append(Field(name: "your answer", value: "never given"))
            case .declined: fields.append(Field(name: "your answer", value: "no"))
            default: fields.append(Field(name: "refused", value: reason(code)))
            }
        }
        fields.append(Field(name: "written", value: stamp(entry.at, in: calendar)))
        if let undoneAt = entry.undoneAt {
            fields.append(Field(name: "undone", value: stamp(undoneAt, in: calendar)))
        }
        // Only when it says something the instants above do not: an item that
        // landed on the day it began on has already said which day that is.
        if let day = entry.day, day != entry.start.map({ Day.of($0, in: calendar) }) {
            fields.append(Field(name: "day", value: spoken(day: day)))
        }
        if !entry.recordID.isEmpty {
            fields.append(Field(name: "agent's id", value: entry.recordID, verbatim: true))
        }
        return fields
    }

    /// The sentence under the fields: what taking it back would do, or why
    /// there is nothing to take back.
    static func note(_ entry: EditEntry, in calendar: Calendar) -> String {
        let day = entry.day.map(spoken(day:)) ?? "the day it is on"
        switch entry.state {
        case .applied where restores(entry):
            return "Putting it back writes the record that was there before into Health again, "
                + "and sends \(day) to the archive, so the archive stops showing this one."
        case .applied where entry.canBeUndone:
            return "Removing it takes the record out of Health and sends \(day) to the archive "
                + "again, so the archive stops showing it too."
        case .applied:
            return "This record is in Health."
        case .refused:
            return "Nothing was written, so there is nothing to take back. Your agent can send it "
                + "again once the reason is gone."
        case .deleted where restores(entry):
            return "Putting it back writes the record into Health again and sends \(day) to the "
                + "archive, so the archive shows it once more."
        case .deleted:
            return "This was removed by a version of the app that kept nothing of what it took "
                + "out, so there is nothing to write back. Ask your agent to write the record "
                + "again if it should be there."
        case .undone:
            let moment = entry.undoneAt.map { stamp($0, in: calendar) } ?? "earlier"
            return "You put Health back the way it was on \(moment). Your agent can write it "
                + "again."
        case .waiting:
            return "An older version of this app held changes back for your answer, and this one "
                + "was never answered. Health was never touched. Your agent can send it again, "
                + "and it will go straight in."
        case .declined:
            return "You turned this down, so Health was never touched. Your agent has been told, "
                + "and it can ask again."
        }
    }

    // MARK: - Taking one back

    /// Whether taking this one back puts a record there rather than removing
    /// one. An addition displaced nothing, so undoing it is a removal; a change
    /// and a removal both have a record waiting in the journal.
    static func restores(_ entry: EditEntry) -> Bool {
        !entry.displaced.isEmpty
    }

    /// The row in the list, where there is room for two words.
    static func undoWord(_ entry: EditEntry) -> String {
        restores(entry) ? "Put back" : "Undo"
    }

    /// The key at the foot of a record's own page.
    static func undoAction(_ entry: EditEntry) -> String {
        restores(entry) ? "Put back what was there" : "Remove from Health"
    }

    /// What the alert asks, and the word on the key that answers it.
    static func undoQuestion(_ entry: EditEntry) -> String {
        restores(entry) ? "Put the record back?" : "Remove this record?"
    }

    static func undoConfirmation(_ entry: EditEntry) -> String {
        restores(entry) ? "Put back" : "Remove"
    }

    /// What the alert says will happen, in the same words as the note.
    static func consequence(_ entry: EditEntry) -> String {
        let what = entry.metric.flatMap { WritableMetric.named($0)?.spoken.lowercased() } ?? "record"
        let day = entry.day.map(spoken(day:)) ?? "the day it is on"
        guard restores(entry) else {
            return "The \(what) record leaves Health, and \(day) goes to the archive again."
        }
        let before = entry.displaced.first.flatMap { WritableMetric.named($0.metric)?.spoken.lowercased() }
        return "Health goes back to the \(before ?? what) record that was there before, and "
            + "\(day) goes to the archive again."
    }

    // MARK: - Words for the codes

    /// Every way an item can be turned away, said as a fact about this phone's
    /// Health rather than as the word the wire carries.
    static func reason(_ code: OutcomeCode) -> String {
        switch code {
        case .unknownMetric: "not a metric agents may write"
        case .badUnit: "the unit does not fit the metric"
        case .badRange: "the start and end do not make sense"
        case .unauthorized: "writing this is switched off in Health"
        case .notFound: "no record of your agent's to remove"
        case .healthRefused: "Health would not take it"
        case .badSignature: "not signed by your agent's key"
        case .cannotOpen: "this phone could not open it"
        case .malformed: "the edit did not make sense"
        // The two that are not a refusal. They are in the same set because the
        // wire has one field for "what became of this item", and an agent reads
        // them the same way — except that these two can change.
        case .awaitingApproval: "waiting for you to allow it"
        case .declined: "you did not allow it"
        }
    }

    // MARK: - Figures and instants

    /// A value as a person writes it: whole when it is whole, one place when it
    /// is not. Health carries a weight as 78.4 and a glass of water as 100.
    static func figure(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded(), abs(value) < 1e9 {
            return grouped(Int(value))
        }
        return String(format: "%.1f", value)
    }

    /// An exact stretch: "7 h 10 min", "45 min". Not `spoken(duration:)`, which
    /// rounds and says "about" — this is a record, not an estimate.
    static func length(_ entry: EditEntry) -> String? {
        guard entry.stage != nil, let start = entry.start, let end = entry.end else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        guard minutes > 0 else { return nil }
        if minutes < 60 {
            return "\(minutes) min"
        }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "for 8 Sep 2026, 13:00 – 13:01", or both dates when it crosses midnight,
    /// where one date and two clock times would say the wrong thing.
    static func span(_ entry: EditEntry, in calendar: Calendar) -> String? {
        guard let start = entry.start else { return nil }
        let startDay = Day.of(start, in: calendar)
        guard let end = entry.end, end != start else {
            return "for \(spoken(day: startDay)), \(clock(start, in: calendar))"
        }
        guard Day.of(end, in: calendar) == startDay else {
            return "from \(stamp(start, in: calendar)) to \(stamp(end, in: calendar))"
        }
        return "for \(spoken(day: startDay)), \(clock(start, in: calendar)) – "
            + clock(end, in: calendar)
    }

    /// A day and a clock time in the archive's own zone: "8 Sep 2026 23:10".
    static func stamp(_ date: Date, in calendar: Calendar) -> String {
        spoken(day: Day.of(date, in: calendar)) + " " + clock(date, in: calendar)
    }

    static func clock(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
