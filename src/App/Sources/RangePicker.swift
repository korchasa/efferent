import SwiftUI

/// How far back the person wants to go.
///
/// The presets are the answers almost everybody gives; the fourth is for the
/// person who has a date in mind. Everything is resolved to one day id before
/// it leaves this file, so nothing downstream has to know a preset existed.
enum RangeSelection: Equatable {
    case lastMonth
    case lastYear
    case everything
    case day(Date)
}

/// The screen that asks how far back to go, and the same screen again later
/// when somebody who chose a short range changes their mind.
///
/// Health's own first record is the floor. It is fetched rather than assumed
/// because the offer names a real date and a real number of days, and a made-up
/// one would be a promise the archive cannot keep.
struct RangePicker: View {
    let earliest: String?
    /// Whether Health has been asked yet. Without it, "no first day" and "not
    /// asked yet" are the same `nil` and the row would say "working it out"
    /// forever at somebody whose Health is simply empty.
    let probed: Bool
    @Binding var selection: RangeSelection

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The archive's own zone, not the phone's current one: the days this
    /// picker names have to be the days that get sent.
    private var calendar: Calendar {
        Services.shared.calendar
    }

    var body: some View {
        VStack(spacing: 8) {
            option(.lastMonth, title: "Last 30 days", detail: detail(for: .lastMonth))
            option(.lastYear, title: "Last 12 months", detail: detail(for: .lastYear))
            option(.everything, title: "Everything Health has", detail: detail(for: .everything))
            chosenDayRow

            if case let .day(date) = selection {
                DatePicker(
                    "Start from",
                    selection: Binding(
                        get: { date },
                        set: { selection = .day($0) }
                    ),
                    in: floor ... Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(Palette.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .padding(.top, 6)
                .transition(.arriving(reduced: reduceMotion))
            }
        }
        // A calendar opening under the fourth row pushes nothing off the
        // screen at once: the rows below it make room at the same pace.
        .animation(Motion.standard(reduced: reduceMotion), value: isChosenDay)
        // A light tick when the choice moves to another row, and none while a
        // day is being picked on the calendar — that has feedback of its own.
        .sensoryFeedback(.selection, trigger: choice)
    }

    /// Which row is chosen, apart from the day inside the fourth one.
    private var choice: Int {
        switch selection {
        case .lastMonth: 0
        case .lastYear: 1
        case .everything: 2
        case .day: 3
        }
    }

    // MARK: - Rows

    private func option(_ value: RangeSelection, title: String, detail: String) -> some View {
        Button {
            selection = value
        } label: {
            row(title: title, detail: detail, ticked: selection == value) {
                EmptyView()
            }
        }
        .buttonStyle(LatchedKey(latched: selection == value))
    }

    private var chosenDayRow: some View {
        Button {
            if case .day = selection {
                return
            }
            selection = .day(defaultChoice)
        } label: {
            row(title: "A day I choose", detail: chosenDetail, ticked: isChosenDay) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.tick)
                    // Turned down while the calendar is open under it, the
                    // way a disclosure says which way it went.
                    .rotationEffect(.degrees(isChosenDay ? 90 : 0))
            }
        }
        .buttonStyle(LatchedKey(latched: isChosenDay))
    }

    /// One key on the panel: a lamp that is lit or not, the choice in the
    /// ordinary face, and what it costs printed underneath as a legend. The
    /// chosen key latches down into the shell and its lamp lights, so which
    /// one is chosen shows in its shape as well as its lamp.
    private func row(
        title: String,
        detail: String,
        ticked: Bool,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(ticked ? Palette.accent : Color.clear)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle().strokeBorder(ticked ? Palette.ink : Palette.tick, lineWidth: 1)
                        .frame(width: 18, height: 18)
                )
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Legend(detail, size: 9)
                    .fixedSize(horizontal: false, vertical: true)
                    // Health's answer arrives after the screen does, and the
                    // line under each row fades over to it rather than
                    // jumping. A fade, not rolling digits: the line changes
                    // from a sentence to a figure, and rolling every letter of
                    // it left the row unreadable for the length of the change.
                    .contentTransition(.opacity)
                    .animation(Motion.standard, value: detail)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .keyCap(in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .contentShape(Rectangle())
        // The lamp lights as the key goes down.
        .animation(Motion.snappy, value: ticked)
    }

    // MARK: - What each choice costs

    private var isChosenDay: Bool {
        if case .day = selection {
            return true
        }
        return false
    }

    private var chosenDetail: String {
        guard case let .day(date) = selection else { return "Pick the day to start from" }
        return spoken(day: Day.of(date, in: calendar))
    }

    private func detail(for value: RangeSelection) -> String {
        guard let day = RangePicker.startDay(for: value, earliest: earliest, calendar: calendar) else {
            return probed ? "Health has nothing to read yet" : "Working out how far back Health goes…"
        }
        guard let count = days(from: day) else { return spoken(day: day) }
        return "\(grouped(count)) days · back to \(spoken(day: day))"
    }

    /// The floor for the calendar. Health's first record when it is known, and
    /// otherwise a date far enough back that the picker is never empty.
    private var floor: Date {
        guard let earliest, let bounds = try? Day.bounds(earliest, in: calendar) else {
            return calendar.date(byAdding: .year, value: -20, to: Date()) ?? Date()
        }
        return bounds.start
    }

    private var defaultChoice: Date {
        calendar.date(byAdding: .month, value: -6, to: Date()) ?? Date()
    }

    private func days(from day: String) -> Int? {
        guard let bounds = try? Day.bounds(day, in: calendar) else { return nil }
        let today = calendar.startOfDay(for: Date())
        guard let span = calendar.dateComponents([.day], from: bounds.start, to: today).day else {
            return nil
        }
        return max(1, span + 1)
    }

    // MARK: - Resolving a choice

    /// The day a selection means, or nil when it depends on a first record that
    /// has not been read yet.
    static func startDay(
        for selection: RangeSelection,
        earliest: String?,
        calendar: Calendar
    ) -> String? {
        let chosen: String?
        switch selection {
        case .everything:
            return earliest
        case .lastMonth:
            chosen = shifted(days: -29, calendar: calendar)
        case .lastYear:
            chosen = shifted(days: -365, calendar: calendar)
        case let .day(date):
            chosen = Day.of(date, in: calendar)
        }
        // A day before Health's own first record would promise history the
        // archive cannot hold (SETUP-3); the marking step clamps it too, and
        // doing it here as well keeps the sentence under the button honest. The
        // presets need it as much as a chosen day: on a phone with 97 days of
        // Health, "Last 12 months" said 366 days back to a date nothing exists
        // for (walk of build 25, 2026-09-27).
        guard let earliest, let chosen else { return chosen }
        return max(earliest, chosen)
    }

    private static func shifted(days: Int, calendar: Calendar) -> String? {
        guard let date = calendar.date(byAdding: .day, value: days, to: Date()) else { return nil }
        return Day.of(date, in: calendar)
    }
}
