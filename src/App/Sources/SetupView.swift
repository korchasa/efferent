import SwiftUI

/// First launch, from an empty app to one that is sending.
///
/// Four screens and a pause: what this is, what it reads, how far back to go,
/// and who may read it afterwards. The archive is made in the pause — that is
/// not a decision anybody can make wrongly, so it is told rather than asked.
struct SetupView: View {
    @EnvironmentObject private var services: Services

    private enum Step { case welcome, access, range, preparing, connect }

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

    private var welcome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                AppMark()
                VStack(spacing: 10) {
                    Text("Efferent")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Text("Your Apple Health history, sealed on this phone and readable only by you.")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }
            .padding(.top, 76)

            VStack(alignment: .leading, spacing: 24) {
                promise(
                    "lock",
                    "The key stays here",
                    "Every day is encrypted before it leaves. Nothing on the way can open it."
                )
                promise(
                    "arrow.up.to.line",
                    "It keeps up on its own",
                    "New readings go out in the background, roughly once an hour."
                )
                promise(
                    "sparkles",
                    "Ask an assistant about it",
                    "Hand your agent one setup text. It reads your history on your own machine."
                )
            }
            .padding(.top, 52)
            .padding(.horizontal, 2)

            Spacer(minLength: 20)

            VStack(spacing: 14) {
                Button("Get Started") { step = .access }
                    .buttonStyle(ProminentButton())
                Text("Setup takes about a minute.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Palette.accent)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - What it reads

    private var access: some View {
        stepLayout(
            back: { step = .welcome },
            title: "What Efferent reads",
            blurb: "Next, Health asks which data to share. Turn on what you want in your "
                + "archive — Efferent only ever reads."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Card {
                    category("A", "Activity", "Steps, distance, flights, energy, exercise and stand time")
                    RowDivider(inset: 59)
                    category("H", "Heart and breathing",
                             "Heart rate and variability, resting rate, respiratory rate, blood oxygen")
                    RowDivider(inset: 59)
                    category("S", "Sleep", "Time asleep and its stages")
                    RowDivider(inset: 59)
                    category("W", "Workouts", "Kind, length and energy")
                }
                Text("Health never tells an app what you allowed. Efferent will not claim to "
                    + "know — if nothing is ever sent, this is the first thing to check.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            VStack(spacing: 14) {
                Button("Choose in Health") {
                    Task {
                        await services.requestHealthAccess()
                        step = .range
                    }
                }
                .buttonStyle(ProminentButton())
                Button("Not now") { step = .range }
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    private func category(_ initial: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 13) {
            Text(initial)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30)
                .background(Palette.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - How far back

    private var range: some View {
        stepLayout(
            back: { step = .access },
            title: "How far back?",
            blurb: "Days before this stay on the phone. You can reach further back later, "
                + "at any time."
        ) {
            RangePicker(earliest: earliest, probed: probed, selection: $selection)
        } actions: {
            VStack(spacing: 12) {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start syncing") {
                    step = .preparing
                    Task {
                        await services.prepareArchive(startingFrom: startDay)
                        step = .connect
                    }
                }
                .buttonStyle(ProminentButton())
            }
        }
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
        return "Everything since \(spoken(day: day)) goes up now. The first pass runs in the "
            + "background and needs nobody watching."
    }

    // MARK: - Making the archive

    private var preparing: some View {
        VStack(spacing: 30) {
            EmberRing(progress: 0.18, mood: .alight)
                .frame(width: 72, height: 72)
            VStack(spacing: 8) {
                Text("Creating your archive")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text("Making the key that opens it, and claiming a place to keep the sealed days.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Who may read it

    private var connect: some View {
        stepLayout(
            back: nil,
            title: "Connect an assistant",
            blurb: "Your agent needs one short setup text. It carries the key that opens your "
                + "archive, so it belongs on your own machine and nowhere else."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        handoffField("INSTRUCTION", "Call setup_guide first. Keep the reading key local.")
                        Palette.hairline.frame(height: 1)
                        handoffField("ARCHIVE", services.destination?.endpoint.host() ?? "—")
                        Palette.hairline.frame(height: 1)
                        handoffField("READING KEY", "held on this phone until you share it")
                    }
                    .padding(18)
                }
                Text("Share it into a private note or file, never into a chat with a service. "
                    + "Efferent keeps syncing whether or not an assistant is connected.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            VStack(spacing: 14) {
                if let handoff = services.connectionHandoff {
                    ShareLink(item: handoff.text) {
                        Label("Share setup text", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(ProminentButton())
                }
                Button("Later") { services.finishSetup() }
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    private func handoffField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(Palette.tertiary)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The shape every step shares

    /// A back arrow, a title, a paragraph, scrolling content, and one action at
    /// the bottom that never moves. The action stays put because the content
    /// above it grows — the day picker opens a calendar — and a button that
    /// drifts off the screen is how a setup gets abandoned.
    private func stepLayout(
        back: (() -> Void)?,
        title: String,
        blurb: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                if let back {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    }
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        Text(blurb)
                            .font(.system(size: 17))
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 12)

                    content()
                        .padding(.horizontal, 18)
                        .padding(.top, 22)
                }
                .padding(.bottom, 18)
            }
            .scrollBounceBehavior(.basedOnSize)

            actions()
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
    }
}
