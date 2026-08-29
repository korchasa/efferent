import SwiftUI
import UIKit

/// First launch, from an empty app to one that is sending.
///
/// Four screens and a pause: what this is, what it reads, how far back to go,
/// and which agent may read it afterwards. The archive is made in the pause —
/// that is not a decision anybody can make wrongly, so it is told rather than
/// asked.
struct SetupView: View {
    @EnvironmentObject private var services: Services

    private enum Step { case welcome, access, range, preparing, connect }

    @State private var step: Step = .welcome
    @State private var earliest: String?
    @State private var probed = false
    @State private var sharing = false
    @State private var selection: RangeSelection = .everything

    var body: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .access: access
            case .range: range
            case .preparing: preparing
            case .connect: connect
            }
        }
        .pageBackground()
        .task {
            // Asked once, early, so the third screen can already name a real
            // date instead of a spinner by the time anybody reaches it.
            if !probed {
                earliest = await services.firstDayInHealth()
                probed = true
            }
        }
    }

    // MARK: - What this is

    /// No picture: the sentence is the screen. It is set as large as the frame
    /// allows, because what this app is takes one sentence to say and nothing
    /// else on the screen has to compete with it.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepHeader(step: 1, back: nil)

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
                Button("Begin setup") { step = .access }
                    .buttonStyle(ProminentButton())
                Legend("4 steps · about 2 minutes", size: 9)
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
            step: 2,
            back: { step = .welcome },
            title: "Health access",
            blurb: "Apple never tells an app what you allowed. Nothing here can confirm it — "
                + "the switches in Health are the only record."
        ) {
            VStack(spacing: 0) {
                numbered(
                    "01", "Efferent reads whatever you tick",
                    "Steps, sleep, workouts, heart, weight — day by day."
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
                        step = .range
                    }
                }
                .buttonStyle(ProminentButton())
                Button("Not now") { step = .range }
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

    // MARK: - How far back

    private var range: some View {
        stepLayout(
            step: 3,
            back: { step = .access },
            title: "How far back?",
            blurb: "Efferent takes every day from the one you choose up to today. You can reach "
                + "further back later."
        ) {
            RangePicker(earliest: earliest, probed: probed, selection: $selection)
        } actions: {
            VStack(spacing: 12) {
                note(summary)
                if let problem = services.lastError {
                    Text(problem)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.alarm)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Start syncing") {
                    step = .preparing
                    Task {
                        await services.prepareArchive(startingFrom: startDay)
                        // Only an archive that exists earns the next screen.
                        // Walking on regardless is how somebody ends up being
                        // offered a setup text for an archive that was never
                        // made — a screen with a dash where the address goes
                        // and no way to tell that anything went wrong.
                        step = services.destination == nil ? .range : .connect
                    }
                }
                .buttonStyle(ProminentButton())
            }
        }
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
        RangePicker.startDay(for: selection, earliest: earliest, calendar: Day.calendar())
    }

    private var summary: String {
        guard let day = startDay else {
            // Nothing to promise: Health either has no history or is not
            // sharing it. Saying "everything goes up now" here would be a
            // sentence about an archive that stays empty.
            return probed
                ? "Health has nothing to send yet. New readings go up as they arrive."
                : "Working out how far back Health goes…"
        }
        return "Everything since \(spoken(day: day)) goes up now. The first export runs on "
            + "Wi-Fi and power. After that Efferent sends only new days."
    }

    // MARK: - Making the archive

    private var preparing: some View {
        VStack(spacing: 28) {
            Dial(progress: 0.18, mood: .alight, side: 92)
            VStack(spacing: 8) {
                Text("Creating your archive")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Making the key that opens it, and claiming a place to keep the sealed days.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.body)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Which agent may read it

    /// What the phone hands over is one text, exactly as the app composes it.
    /// Split into fields on screen, it invites pasting a part of it — and a part
    /// of it opens nothing.
    private var connect: some View {
        stepLayout(
            step: 4,
            back: nil,
            title: "Connect your agent",
            blurb: "Paste this whole text to your agent — ChatGPT, Claude, Gemini, whatever you "
                + "use. The text says what to do, where the archive is and what opens it."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                handoffPanel
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.legend)
                    Legend("give it only to an agent you trust", size: 9)
                }
            }
        } actions: {
            VStack(spacing: 6) {
                if let handoff = services.connectionHandoff {
                    Button("Share this text") { sharing = true }
                        .buttonStyle(ProminentButton())
                        .sheet(isPresented: $sharing) {
                            ShareSheet(text: handoff.text) { shared in
                                sharing = false
                                // Only a share that went through ends the step.
                                // A cancelled one leaves the screen exactly as
                                // it was, because nothing happened.
                                if shared {
                                    services.finishSetup()
                                }
                            }
                        }
                    Button("Copy instead") {
                        UIPasteboard.general.string = handoff.text
                        services.finishSetup()
                    }
                    .buttonStyle(QuietButton())
                }
                // The way past this screen for somebody who does not want to
                // hand the key to anything yet. The text stays in the menu on
                // the everyday screen.
                Button("Later") { services.finishSetup() }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.legend)
            }
        }
    }

    private var handoffPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Legend("agent connection", size: 9, colour: Color(white: 0.51))
            Text(services.connectionHandoff?.text ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    // MARK: - The shape every step shares

    private func stepHeader(step: Int, back: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            Text("efferent")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 8)
            StepBar(step: step, total: 4)
        }
        .frame(height: 34)
    }

    /// A brand row with the step counter, a title, a paragraph, scrolling
    /// content, and one action at the bottom that never moves. The action stays
    /// put because the content above it grows — the day picker opens a calendar
    /// — and a button that drifts off the screen is how a setup gets abandoned.
    private func stepLayout(
        step: Int,
        back: (() -> Void)?,
        title: String,
        blurb: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            stepHeader(step: step, back: back)
                .padding(.horizontal, 20)

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

/// The system share sheet, with the one thing `ShareLink` cannot give: an
/// answer.
///
/// The setup's last step is over the moment the text has gone somewhere, and
/// `ShareLink` never says whether it did — so the screen stayed put behind a
/// finished share, with a button reading "Later" at somebody who had just done
/// it. `UIActivityViewController` reports the outcome, and that is the whole
/// reason for the detour through UIKit.
struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    /// `true` when an activity finished, `false` when the sheet was dismissed.
    let done: (Bool) -> Void

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in done(completed) }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
