import SwiftUI
import UIKit

/// First launch, from an empty app to one that is sending.
///
/// Four screens and a pause: what this is, what it reads, what it may tell you
/// about, and how far back to go. The archive is made in the pause — that is
/// not a decision anybody can make wrongly, so it is told rather than asked.
/// Handing the archive to an
/// agent is not part of the walkthrough: it needs a decision about somebody
/// else's software, it can be done at any time, and a setup that ends on it
/// leaves the phone waiting on a step nobody has to take today. The everyday
/// screen asks for it instead, and keeps asking until it is done.
struct SetupView: View {
    @EnvironmentObject private var services: Services

    private enum Step: Int { case welcome, access, notices, range, preparing }

    @State private var step: Step = .welcome
    /// Which way the last move went, so a step leaves by the edge the next one
    /// did not come in from.
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Health's own first record, looked at again by every screen that shows it.
    @StateObject private var earliest = EarliestDay()
    @State private var selection: RangeSelection = .everything

    var body: some View {
        VStack(spacing: 0) {
            // The brand row and the step counter stay put while the steps
            // change under them: they are the instrument's own printing, and
            // only the counter moves, a segment at a time.
            stepHeader
                .padding(.horizontal, 20)

            ZStack {
                Group {
                    switch step {
                    case .welcome: welcome
                    case .access: access
                    case .notices: notices
                    case .range: range
                    case .preparing: preparing
                    }
                }
                .id(step)
                .transition(.step(forward: forward, reduced: reduceMotion))
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .pageBackground()
        .task {
            // Asked early, so the last screen can already name a real date
            // instead of a spinner by the time anybody reaches it. This answer
            // is taken before the Health sheet has been shown, so it is a head
            // start and never the answer that screen shows.
            await lookAtHealth()
        }
    }

    /// Move to another step along the path the steps are laid out on.
    ///
    /// A step that is leaving is drawn with the direction it had when it
    /// arrived, so when the direction turns round it has to be told first and
    /// the move made on the next turn of the run loop — otherwise going back
    /// would slide the old step out towards the side the new one comes from.
    private func go(to next: Step) {
        let ahead = next.rawValue > step.rawValue
        let move = { withAnimation(Motion.standard(reduced: reduceMotion)) { step = next } }
        guard ahead != forward else { return move() }
        forward = ahead
        Task { @MainActor in move() }
    }

    /// Ask Health how far back it goes, through the screen's own services so a
    /// demonstration run answers with its own figures.
    private func lookAtHealth() async {
        await earliest.look { await services.firstDayInHealth() }
    }

    // MARK: - What this is

    /// No picture: the sentence is the screen. It is set as large as the frame
    /// allows, because what this app is takes one sentence to say and nothing
    /// else on the screen has to compete with it.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
                .padding(.top, 20)

            Text("Efferent encrypts every day of Apple Health on this phone and sends it to "
                + "storage you own. The key never leaves the device.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Spacer(minLength: 24)

            VStack(spacing: 0) {
                spec("encryption", "X25519 · HKDF")
                spec("storage", "yours")
                spec("key", "this phone only")
            }
            .padding(.bottom, 22)

            VStack(spacing: 10) {
                Button("Begin setup") { go(to: .access) }
                    .buttonStyle(ProminentButton())
                Legend("4 steps · about a minute", size: 9)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var headline: some View {
        (
            Text("Your Health history, kept where ")
                + Text("only you").foregroundStyle(Palette.accent)
                + Text(" can read it.")
        )
        .font(.system(size: 46, weight: .semibold))
        .kerning(-1.4)
        .foregroundStyle(Palette.ink)
        .minimumScaleFactor(0.7)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A line of the printed legend along the bottom of the shell: what the
    /// thing is made of, said in the fewest words that stay true.
    private func spec(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Legend(label, size: 9)
                Spacer(minLength: 8)
                Legend(value, size: 9, colour: Palette.ink)
            }
            .padding(.vertical, 9)
            RowDivider()
        }
    }

    // MARK: - What it reads

    private var access: some View {
        stepLayout(
            title: "Health access",
            blurb: "Apple never tells an app what you allowed. Nothing here can confirm it — "
                + "the switches in Health are the only record."
        ) {
            VStack(spacing: 0) {
                numbered(
                    "01", "Efferent reads whatever you tick",
                    "Steps, sleep, workouts, heart, weight — day by day. "
                        + "An agent you connect may also write meals, sleep and weight."
                )
                numbered(
                    "02", "Nothing goes twice",
                    "Efferent skips a day that is already in the archive."
                )
                numbered(
                    "03", "Untick anything, any time",
                    "In Health → Apps and Services → Efferent."
                )
            }
        } actions: {
            VStack(spacing: 6) {
                Button("Ask Health now") {
                    Task {
                        await services.requestHealthAccess()
                        go(to: .notices)
                    }
                }
                .buttonStyle(ProminentButton())
                Button("Not now") { go(to: .notices) }
                    .buttonStyle(QuietButton())
            }
        }
    }

    private func numbered(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Legend(number, size: 11, colour: Palette.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            RowDivider()
        }
    }

    // MARK: - What it may tell you about

    /// The one thing this app ever puts on a lock screen, offered rather than
    /// sprung.
    ///
    /// Asking here is asking about something that has not happened yet, which
    /// is why "Not now" walks on without showing the system sheet at all: the
    /// permission stays undetermined, and the everyday screen puts the same
    /// question again the first time an agent actually writes. Only the filled
    /// button shows the sheet, because that sheet can be answered once.
    private var notices: some View {
        stepLayout(
            title: "Notices",
            blurb: "An agent you connect may write into Health — a meal, a nap, a weight. "
                + "Efferent can tell you when that happens. It is the only thing this app "
                + "ever puts on your lock screen."
        ) {
            VStack(spacing: 0) {
                numbered(
                    "01", "Only what an agent writes",
                    "Sending your own history says nothing. An export runs in silence, "
                        + "however many days it carries."
                )
                numbered(
                    "02", "A count, never a reading",
                    "The notice says how many records were written and how many removed, and "
                        + "stops there — no metric, no value, no day. A lock screen is read by "
                        + "whoever holds the phone."
                )
                numbered(
                    "03", "Nothing until an agent is connected",
                    "No agent, no notices. You can allow this now and decide about an agent "
                        + "any day."
                )
            }
        } actions: {
            VStack(spacing: 12) {
                note("Not now is not an answer. Skip this and Efferent asks again the first "
                    + "time an agent writes something into Health.")
                VStack(spacing: 6) {
                    Button("Allow notices") {
                        Task {
                            await services.askForNotices()
                            go(to: .range)
                        }
                    }
                    .buttonStyle(ProminentButton())
                    Button("Not now") { go(to: .range) }
                        .buttonStyle(QuietButton())
                }
            }
        }
    }

    // MARK: - How far back

    private var range: some View {
        stepLayout(
            title: "How far back?",
            blurb: "Efferent takes every day from the one you choose up to today. You can reach "
                + "further back later."
        ) {
            RangePicker(earliest: earliest.day, probed: earliest.looked, selection: $selection)
        } actions: {
            VStack(spacing: 12) {
                note(summary)
                if let problem = services.lastError {
                    Text(problem)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.alarm)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.arriving(reduced: reduceMotion))
                }
                Button("Start syncing") {
                    go(to: .preparing)
                    Task { await services.prepareArchive(startingFrom: startDay) }
                }
                .buttonStyle(ProminentButton())
            }
            // The remark follows the choice above it, and Health's answer
            // arriving: a sentence that swaps in place reads as the same
            // sentence being corrected, not as a new one to find.
            .animation(Motion.standard(reduced: reduceMotion), value: summary)
            .animation(Motion.standard(reduced: reduceMotion), value: services.lastError)
        }
        // Asked again here, and not once for the whole walkthrough. The Health
        // sheet is two steps back, and an answer taken before it was shown says
        // Health has nothing however much of it there is.
        .task { await lookAtHealth() }
    }

    /// The small printed remark beside a control, with the indicator dot that
    /// marks it as coming from the device rather than from the person.
    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Palette.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.body)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    private var startDay: String? {
        RangePicker.startDay(for: selection, earliest: earliest.day, calendar: services.calendar)
    }

    private var summary: String {
        Self.summary(startDay: startDay, firstDay: earliest.day, looked: earliest.looked)
    }

    /// The remark under the range, which has to agree with the rows above it.
    ///
    /// It follows Health's first day, not the chosen one. A preset or a chosen
    /// day always resolves to a date, so with an empty Health — or one that is
    /// not sharing, which looks the same — the remark used to promise
    /// "everything since" that date while the row above it said Health had
    /// nothing to read (walk of build 25, 2026-09-27). That is the screen an App
    /// Review device with no Health history shows first.
    static func summary(startDay: String?, firstDay: String?, looked: Bool) -> String {
        guard firstDay != nil, let day = startDay else {
            // Nothing to promise: Health either has no history or is not
            // sharing it. Saying "everything goes up now" here would be a
            // sentence about an archive that stays empty.
            return looked
                ? "Health has nothing to send yet. New readings go up as they arrive."
                : "Working out how far back Health goes…"
        }
        return "Everything since \(spoken(day: day)) goes up now. The first export goes as soon "
            + "as this phone has a network. After that Efferent sends only new days."
    }

    // MARK: - Making the archive, and watching it start

    /// Sending begins here, and the walkthrough waits.
    ///
    /// The pass runs whether or not anybody is looking, so this screen could
    /// simply move on — but the one thing a person wants after pressing "start"
    /// is to see that it started. It shows the archive being made, then the
    /// count going up, and moves on only when they say so. An archive that
    /// could not be made stops here too: the everyday screen with nowhere to
    /// send is a screen nobody can act on.
    private var preparing: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                // While the archive is being made there is nothing to
                // measure, so the lit arc walks round instead of standing at
                // a figure it does not have.
                Dial(
                    progress: archiveReady ? services.syncProgress : 0.08,
                    mood: .alight,
                    side: 132,
                    waiting: !archiveReady && services.lastError == nil
                )
                VStack(spacing: 10) {
                    Text(archiveReady ? "Sending has started" : "Creating your archive")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.opacity)
                    Text(preparingBlurb)
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                if archiveReady {
                    Legend(queueLine, size: 11, colour: Palette.ink)
                        .contentTransition(.numericText())
                        .transition(.arriving(reduced: reduceMotion))
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if let problem = services.lastError {
                    Text(problem)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.alarm)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.arriving(reduced: reduceMotion))
                }
                if archiveReady {
                    Button("Continue") { services.finishSetup() }
                        .buttonStyle(ProminentButton())
                        .transition(.opacity)
                } else if services.lastError != nil {
                    Button("Try again") { go(to: .range) }
                        .buttonStyle(ProminentButton())
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        // The archive being made, the first figure, a failure: each arrives
        // while the person is watching this screen for exactly that.
        .animation(Motion.standard(reduced: reduceMotion), value: archiveReady)
        .animation(Motion.standard(reduced: reduceMotion), value: services.lastError)
        .animation(Motion.standard, value: queueLine)
        .task {
            // The count moves on the upload session's own queue, and watching
            // it move is the whole point of this screen.
            while !Task.isCancelled {
                services.refreshStats()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var archiveReady: Bool {
        services.destination != nil
    }

    private var preparingBlurb: String {
        archiveReady
            ? "Efferent is sending in the background. You can leave this screen — it carries on "
            + "without you, whenever this phone has a network."
            : "Making the key that opens it, and claiming a place to keep the sealed days."
    }

    private var queueLine: String {
        guard let pending = services.stats?.pendingDays, pending > 0 else { return "nothing waiting" }
        return "\(grouped(pending)) days waiting"
    }

    // MARK: - The shape every step shares

    /// Where the back key goes from each step, or nil where there is no way
    /// back: the first step, and the pause in which the archive is made.
    private var previous: Step? {
        switch step {
        case .welcome, .preparing: nil
        case .access: .welcome
        case .notices: .access
        case .range: .notices
        }
    }

    /// Which of the four segments are lit. Making the archive is the end of
    /// the fourth step rather than a fifth.
    private var stepNumber: Int {
        min(step.rawValue + 1, 4)
    }

    private var stepHeader: some View {
        HStack(spacing: 10) {
            if let previous {
                Button { go(to: previous) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(minWidth: 24, minHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableKey())
                .transition(.opacity)
            }
            Text("efferent")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            StepBar(step: stepNumber, total: 4)
        }
        .frame(height: 34)
    }

    /// A brand row with the step counter, a title, a paragraph, scrolling
    /// content, and one action at the bottom that never moves. The action stays
    /// put because the content above it grows — the day picker opens a calendar
    /// — and a button that drifts off the screen is how a setup gets abandoned.
    private func stepLayout(
        title: String,
        blurb: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(title)
                            .font(.system(size: 30, weight: .semibold))
                            .kerning(-0.6)
                            .foregroundStyle(Palette.ink)
                        Text(blurb)
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 18)

                    content()
                        .padding(.top, 20)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)

            actions()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
    }
}
