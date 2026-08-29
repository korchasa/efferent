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

    private var calendar: Calendar {
        Day.calendar()
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
            }
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
        .buttonStyle(.plain)
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
            }
        }
        .buttonStyle(.plain)
    }

    /// One key on the panel: a lamp that is lit or not, the choice in the
    /// ordinary face, and what it costs printed underneath as a legend. The
    /// chosen one is outlined in ink, so which key is down can be seen from
    /// across the room rather than read.
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
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(ticked ? Palette.ink : Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
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
        switch selection {
        case .everything:
            return earliest
        case .lastMonth:
            return shifted(days: -29, calendar: calendar)
        case .lastYear:
            return shifted(days: -365, calendar: calendar)
        case let .day(date):
            let chosen = Day.of(date, in: calendar)
            // A day before Health's own first record would promise history the
            // archive cannot hold; the marking step clamps it too, and doing it
            // here as well keeps the sentence under the button honest.
            guard let earliest else { return chosen }
            return max(earliest, chosen)
        }
    }

    private static func shifted(days: Int, calendar: Calendar) -> String? {
        guard let date = calendar.date(byAdding: .day, value: days, to: Date()) else { return nil }
        return Day.of(date, in: calendar)
    }
}
