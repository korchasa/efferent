import SwiftUI

/// The one question this app asks on an agent's behalf.
///
/// An agent may add to Health by itself. Changing or removing what is already
/// there is somebody else's record of their own life, so it waits here. The
/// decision is one decision for the whole run: these items arrive together and
/// are usually about the same few records, and a screen that asked about each of
/// them separately would turn one answer into a chore nobody finishes — which
/// ends with an agent waiting forever on a question that was read and left.
struct EditReviewView: View {
    @EnvironmentObject private var services: Services
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [EditEntry]
    /// On while Health is being written, so neither action can be pressed twice.
    @State private var deciding = false
    /// Off for the store screenshot: an image renderer draws a scroll view and a
    /// navigation stack as nothing at all.
    private let scrolls: Bool

    /// The rows are read when the screen appears, which an offscreen renderer
    /// never does — the screenshot run hands them in instead.
    init(showing entries: [EditEntry] = [], scrolls: Bool = true) {
        _entries = State(initialValue: entries)
        self.scrolls = scrolls
    }

    var body: some View {
        if scrolls {
            presented
        } else {
            content.pageBackground()
        }
    }

    private var presented: some View {
        NavigationStack {
            content
                .pageBackground()
                .navigationTitle("Waiting for you")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Not "Done": nothing has been decided, and the question
                        // is still there when the screen goes.
                        Button("Later") { dismiss() }
                            .foregroundStyle(Palette.accent)
                    }
                }
        }
        .task { entries = services.waitingEdits() }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView { asked }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                asked
                Spacer(minLength: 0)
            }
            answers
        }
    }

    private var asked: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(EditWords.asking(entries.count))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(EditWords.askingExplained)
                .font(.system(size: 14))
                .foregroundStyle(Palette.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 6)
            ForEach(entries) { entry in
                EditRow(entry: entry, calendar: services.calendar)
                RowDivider()
            }
        }
        .padding(.horizontal, 20)
    }

    /// The two actions, and nothing in the rows above that could be mistaken for
    /// a third: a record's own row says it is waiting and offers no button.
    private var answers: some View {
        VStack(spacing: 0) {
            RowDivider()
            Button(entries.count == 1 ? "Allow it" : "Allow all") { decide(yes: true) }
                .buttonStyle(ProminentButton())
                .disabled(deciding)
                .padding(.top, 12)
            Button(entries.count == 1 ? "Turn it down" : "Turn them all down") {
                decide(yes: false)
            }
            .buttonStyle(QuietButton())
            .disabled(deciding)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func decide(yes: Bool) {
        deciding = true
        Task {
            if yes {
                await services.approveWaiting()
            } else {
                await services.declineWaiting()
            }
            entries = services.waitingEdits()
            deciding = false
            // Nothing left to ask about, so the screen has no reason to stand.
            // A row still waiting means the phone never got that far — Health is
            // sealed while the phone is locked — so the ask stays, with the
            // sentence under the dial saying why.
            if entries.isEmpty {
                dismiss()
            }
        }
    }
}
