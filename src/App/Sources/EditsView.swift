import SwiftUI

/// What an agent changed, and the way to take one back.
///
/// The service is told counts and codes and nothing else, on purpose, so this
/// screen is the only place the contents of an edit can be read at all. It is
/// reached from the everyday screen rather than hidden behind a gesture: an app
/// that changes Health quietly is an app nobody should trust with Health.
struct EditsView: View {
    @EnvironmentObject private var services: Services
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [EditEntry]
    /// On for the store screenshot: an image renderer draws a list, a scroll
    /// view and a navigation stack as nothing at all, so the same rows are
    /// printed straight onto the shell instead. The app itself is never flat —
    /// the swipe that undoes a row is the list's own.
    private let flat: Bool

    /// The rows are read when the screen appears, which an offscreen renderer
    /// never does — the screenshot run hands them in instead. The app itself
    /// starts empty and reads them, as it did before.
    init(showing entries: [EditEntry] = [], flat: Bool = false) {
        _entries = State(initialValue: entries)
        self.flat = flat
    }

    var body: some View {
        if flat {
            printed.pageBackground()
        } else {
            presented
        }
    }

    private var presented: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    nothing
                } else {
                    journal
                }
            }
            .pageBackground()
            .navigationTitle("Agent edits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.accent)
                }
            }
            .navigationDestination(for: EditEntry.self) { entry in
                EditDetailView(entry: entry, calendar: services.calendar) { undo(entry) }
            }
        }
        .task {
            reload()
            // Opening the list is what makes a run old news: the dark strip on
            // the everyday screen counts what has landed since this moment.
            services.markEditsSeen()
        }
    }

    /// The same rows without the list around them.
    private var printed: some View {
        VStack(alignment: .leading, spacing: 0) {
            explanation
                .padding(.top, 8)
                .padding(.bottom, 6)
            ForEach(lines) { line in
                switch line {
                case let .day(title):
                    Legend(title, size: 9)
                        .padding(.top, 18)
                        .padding(.bottom, 2)
                case let .entry(entry):
                    EditRow(entry: entry, calendar: services.calendar)
                    RowDivider()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - The journal

    private var explanation: some View {
        Text("Everything your agent asked this phone to change in Health, and what became of "
            + "each one. The service only ever sees counts; the details live here.")
            .font(.system(size: 14))
            .foregroundStyle(Palette.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var journal: some View {
        List {
            explanation
                .padding(.top, 8)
                .listRowBackground(Palette.shell)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 6, trailing: 20))

            ForEach(lines) { line in
                switch line {
                case let .day(title):
                    Legend(title, size: 9)
                        .listRowBackground(Palette.shell)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 2, trailing: 20))
                case let .entry(entry):
                    NavigationLink(value: entry) { EditRow(entry: entry, calendar: services.calendar) }
                        .listRowBackground(Palette.shell)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowSeparatorTint(Palette.hairline)
                        // Full swipe is off on purpose. The gesture takes a
                        // record out of Health, and a flick that goes further
                        // than it was meant to is exactly how that happens by
                        // accident; the button has to be pressed.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if entry.canBeUndone {
                                Button("Undo") { undo(entry) }
                                    .tint(Palette.alarm)
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }


    private var nothing: some View {
        VStack(spacing: 8) {
            Legend("no edits yet")
            Text("When your agent writes something into Health, it shows up here.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One flat run of headers and rows. A `Section` would sit sticky over the
    /// shell in its own colour, and the day a row belongs to is a legend on the
    /// page rather than a bar over it.
    private enum Line: Identifiable, Hashable {
        case day(String)
        case entry(EditEntry)

        var id: String {
            switch self {
            case let .day(title): "day:" + title
            case let .entry(entry): "entry:\(entry.id)"
            }
        }
    }

    private var lines: [Line] {
        var lines: [Line] = []
        var last: String?
        for entry in entries {
            let day = Day.of(entry.at, in: services.calendar)
            if day != last {
                lines.append(.day(EditWords.when(day, in: services.calendar)))
                last = day
            }
            lines.append(.entry(entry))
        }
        return lines
    }

    private func reload() {
        entries = services.recentEdits()
    }

    private func undo(_ entry: EditEntry) {
        Task {
            await services.undo(entry)
            reload()
        }
    }
}

// MARK: - One row

/// The walkthrough's numbered row, with the state where the number was.
struct EditRow: View {
    let entry: EditEntry
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Legend(entry.state.rawValue, size: 11, colour: EditWords.colour(entry.state))
                .frame(width: 74, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(EditWords.title(entry))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(entry.state == .undone ? Palette.legend : Palette.ink)
                    .strikethrough(entry.state == .undone, color: Palette.legend)
                    .fixedSize(horizontal: false, vertical: true)
                Text(EditWords.detail(entry, in: calendar))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }
}

// MARK: - One edit, in full

/// Every field of one item, printed as the welcome screen prints what the app
/// is made of: the name on the left, the value on the right, a line between.
struct EditDetailView: View {
    let entry: EditEntry
    let calendar: Calendar
    let remove: () -> Void
    /// Off for the store screenshot: an image renderer draws a scroll view as
    /// nothing at all, and one edit's fields fit the screen without one.
    var scrolls = true

    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView { fields }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                fields
                Spacer(minLength: 0)
            }

            way
        }
        .pageBackground()
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remove this record?", isPresented: $confirming) {
            Button("Remove", role: .destructive) {
                remove()
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(EditWords.consequence(entry))
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(EditWords.fields(entry, in: calendar), id: \.name) { field in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Legend(field.name, size: 9)
                    Spacer(minLength: 8)
                    if field.verbatim {
                        Text(field.value)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Legend(field.value, size: 9, colour: Palette.ink)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(.vertical, 9)
                RowDivider()
            }
            note
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var note: some View {
        Text(EditWords.note(entry, in: calendar))
            .font(.system(size: 13))
            .foregroundStyle(entry.state == .deleted ? Palette.alarm : Palette.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The one row that destroys something, or the sentence that says why there
    /// is none. A deletion never gets a button: the value it removed was never
    /// kept, so a button here could only fail.
    @ViewBuilder private var way: some View {
        if entry.canBeUndone {
            VStack(spacing: 0) {
                RowDivider()
                Button("Remove from Health") { confirming = true }
                    .buttonStyle(DangerButton())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        } else if entry.state == .deleted {
            VStack(spacing: 0) {
                RowDivider()
                Legend("cannot be undone", size: 11, colour: Palette.tick)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }
}
