import SwiftUI
import UIKit

/// First launch, from an empty app to one that is sending.
///
/// Three screens and a pause: what this is, what it reads, and how far back to
/// go. The archive is made in the pause — that is not a decision anybody can
/// make wrongly, so it is told rather than asked. Handing the archive to an
/// agent is not part of the walkthrough: it needs a decision about somebody
/// else's software, it can be done at any time, and a setup that ends on it
/// leaves the phone waiting on a step nobody has to take today. The everyday
/// screen asks for it instead, and keeps asking until it is done.
struct SetupView: View {
    @EnvironmentObject private var services: Services

    private enum Step { case welcome, access, range, preparing }

    @State private var step: Step = .welcome
    @State private var earliest: String?
    @State private var probed = false
    @State private var selection: RangeSelection = .everything

    var body: some View {
        Group {
            switch step {
            case .welcome: welcome
            case .access: access
            case .range: range
            case .preparing: preparing
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
                Legend("3 steps · about a minute", size: 9)
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
                        // Only an archive that exists ends the walkthrough.
                        // Walking on regardless would drop somebody onto the
                        // everyday screen with nowhere to send and no way to
                        // tell that anything went wrong.
                        if services.destination == nil {
                            step = .range
                        } else {
                            services.finishSetup()
                        }
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
            StepBar(step: step, total: 3)
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
