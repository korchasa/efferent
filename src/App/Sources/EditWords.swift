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

    // MARK: - What has not landed yet

    /// Edits the service is holding that this phone has seen and cannot write
    /// yet, because Health is sealed while the screen is locked.
    ///
    /// It says what happens next rather than what went wrong: nothing did, and
    /// the thing that fixes it is the unlock the person is about to do anyway.
    static func onTheWay(_ count: Int) -> String {
        "Your agent sent \(records(count)). They land in Health the next time you unlock this phone."
    }

    /// Why the last look at the queue ended without writing anything.
    ///
    /// Only the endings a person can act on, or is owed an explanation for. A
    /// run turned away because another one was already going is neither: it is
    /// this very job being done, one caller along.
    enum DeliveryStop: Equatable, Sendable {
        /// The screen was locked, so Health would take nothing. The count is
        /// what goes in at the next unlock.
        case sealedByLock(waiting: Int)
        /// Something went wrong. Which, is in the log — this line exists to
        /// send the person there rather than to be the report itself.
        case failed
    }

    /// How far an edit can get without the person opening the app.
    ///
    /// Two layers carry it there — the archive ringing this phone, and the
    /// catch-up task the system runs on its own — and both can be switched off
    /// outside this app. Neither stops an edit arriving; they decide how late
    /// it arrives, which is why neither is drawn as a fault.
    enum Reach: Equatable, Sendable {
        /// The archive can ring this phone, and the system runs the catch-up
        /// task.
        case whole
        /// Nothing can ring this phone: Apple would not say how to reach it, or
        /// the archive was never told. The catch-up task still runs, so an edit
        /// arrives within hours instead of within seconds.
        case noWake
        /// The system runs nothing for this app while it is out of sight, so
        /// both layers are gone at once and an edit waits for the next time
        /// somebody opens it.
        case nothingInTheBackground
    }

    /// The one line under the dial about the queue.
    struct DeliveryLine: Equatable {
        let text: String
        /// Whether it names something wrong, which is drawn in the alarm colour
        /// instead of the faint one. A locked phone is not wrong and a pause is
        /// the person's own doing, so neither is raised.
        let isFault: Bool
    }

    /// What the everyday screen says about the queue: what stopped the last
    /// look, or when that look happened.
    ///
    /// NOTICE-7 and STATE-1 in one sentence, because they are one question to
    /// the person looking — is anything coming, and if not, why. Silence has
    /// two causes, nobody sent anything and nobody looked, and only one of them
    /// is a fault. The log is not a place a person looks.
    static func delivery(
        paused: Bool,
        healthUndecided: Bool,
        stopped: DeliveryStop?,
        reach: Reach,
        checked: Date?,
        now: Date = Date()
    ) -> DeliveryLine {
        // Before everything, because it is why there was no look at all, and it
        // is a decision rather than a fault.
        if paused {
            return DeliveryLine(text: "agent edits held back with sending", isFault: false)
        }
        // Before the time, because an unanswered Health question stops the
        // queue being read at all: a bare "not checked yet" would send the
        // person looking for a fault in their agent.
        if healthUndecided {
            return DeliveryLine(text: "health access not answered yet", isFault: true)
        }
        switch stopped {
        case let .sealedByLock(waiting):
            // A count only when the queue was read far enough to have one. A
            // run that failed on the way to it knows the condition and not the
            // figure, and "0 edits wait" would be a lie about both.
            let text = switch waiting {
            case 0: "health is sealed until this phone is unlocked"
            case 1: "1 edit waits until this phone is unlocked"
            default: "\(waiting) edits wait until this phone is unlocked"
            }
            return DeliveryLine(text: text, isFault: false)
        case .failed:
            return DeliveryLine(text: "the last look at the archive did not finish", isFault: true)
        case nil:
            break
        }
        // After what stopped the last look, because that is about this moment
        // and these two are about every moment. Before the time, because a
        // phone nothing can reach is exactly the phone whose last-checked time
        // is about to stop moving, and the time alone would leave the person
        // hunting for the cause. Faint rather than raised: both are settings
        // outside this app, and an edit still arrives — later.
        switch reach {
        case .nothingInTheBackground:
            return DeliveryLine(
                text: "background app refresh is off, so edits are late", isFault: false
            )
        case .noWake:
            return DeliveryLine(text: "nothing can wake this phone, so edits are late", isFault: false)
        case .whole:
            break
        }
        guard let checked else {
            return DeliveryLine(text: "agent edits not checked yet", isFault: false)
        }
        return DeliveryLine(text: "agent edits checked " + ago(checked, now: now), isFault: false)
    }

    /// How long ago something happened, in the coarsest words that are still
    /// true.
    ///
    /// Coarse on purpose. This line exists so that a phone iOS has stopped
    /// waking is recognisable by its time standing still, and for that a person
    /// needs to tell minutes from days — not to read a clock.
    static func ago(_ moment: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(moment))
        if seconds < 90 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = hours / 24
        return days == 1 ? "yesterday" : "\(days) days ago"
    }
}
