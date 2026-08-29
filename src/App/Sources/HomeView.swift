import SwiftUI
import UIKit

/// The everyday screen: one dial in the middle of the shell, and a line under
/// it.
///
/// The face of the dial is the button, and it carries the figure it is about —
/// how many days are still to go — so the thing you look at and the thing you
/// press are the same thing. The scale around it is that figure turning into
/// progress. The line underneath is the one sentence a number cannot say, and
/// it must never let the states look alike: everything sent, nothing ever sent,
/// and stopped days ago are different facts, and each one says so in its own
/// words. Everything sent is the good state and is drawn as one — a mark on the
/// face rather than a nought.
struct HomeView: View {
    @EnvironmentObject private var services: Services

    @State private var reachingBack = false
    @State private var explainingAccess = false
    @State private var confirmingDisconnect = false
    @State private var earliest: String?
    @State private var probed = false
    @State private var reachSelection: RangeSelection = .everything

    var body: some View {
        ZStack {
            // The brand row and the footer are pinned around the outside rather
            // than stacked with the dial, so nothing above or below it can push
            // the dial off centre as its own text grows.
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }

            instrument.overlay(alignment: .top) { caption.offset(y: 286) }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pageBackground()
        .task {
            // The counters move on the upload session's own queue while this
            // screen is open, most visibly during a first export. Cancelled
            // with the view, so it costs nothing when nobody is looking.
            while !Task.isCancelled {
                services.refreshStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $reachingBack) { reachBackSheet }
        .sheet(isPresented: $explainingAccess) { accessSheet }
        .alert("Disconnect?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) { services.disconnect() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(
                "This phone forgets its signing and reading keys. It can never write to this "
                    + "archive again, and the archive can be read only if its setup text was "
                    + "already saved somewhere else."
            )
        }
    }

    // MARK: - The brand row

    private var header: some View {
        HStack(spacing: 9) {
            Text("efferent")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink)
            Circle()
                .fill(state.mood == .alight ? Palette.accent : Palette.legend)
                .frame(width: 7, height: 7)
            Legend(state.status, size: 9)
            Spacer(minLength: 8)
            menu
        }
        .frame(height: 34)
    }

    /// The rare things, behind one key. Everything a person does daily is the
    /// dial itself, so this holds what is done once a year: reaching further
    /// back, the Health switches, the setup text, and giving the archive up.
    private var menu: some View {
        Menu {
            Button {
                reachSelection = .everything
                reachingBack = true
            } label: {
                Label("Reach further back…", systemImage: "clock.arrow.circlepath")
            }
            Button {
                explainingAccess = true
            } label: {
                Label("Health access", systemImage: "heart.text.square")
            }
            if let handoff = services.connectionHandoff {
                ShareLink(item: handoff.text) {
                    Label("Connect an agent", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                confirmingDisconnect = true
            } label: {
                Label("Disconnect this phone", systemImage: "xmark.circle")
            }
        } label: {
            HStack(spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Circle().fill(Palette.ink).frame(width: 3, height: 3)
                }
            }
            .frame(width: 34, height: 34)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
        }
    }

    // MARK: - The dial and its face

    private var instrument: some View {
        ZStack {
            Dial(progress: state.progress, mood: state.mood, side: 264)
            Button {
                services.setPaused(!services.paused)
            } label: {
                face
            }
            .buttonStyle(.plain)
            .accessibilityLabel(services.paused ? "Start sending" : "Stop sending")
            .accessibilityValue(state.spokenValue)
        }
        .frame(width: 264, height: 264)
    }

    private var face: some View {
        VStack(spacing: 6) {
            if state.settled {
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text("Up to date")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            } else {
                Text(state.remaining)
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                // "days left" read as time — the one thing this number is not.
                // It says what the days are: work still to do.
                Legend("days waiting")
            }
            Image(systemName: services.paused ? "play.fill" : "pause.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .padding(.top, 8)
        }
        .frame(width: 186, height: 186)
        .contentShape(Circle())
    }

    // MARK: - The line under the dial

    private var caption: some View {
        VStack(spacing: 8) {
            if let problem = state.problem {
                // An error is a sentence to read, not a legend to glance at, so
                // it keeps the ordinary face and the alarm colour.
                Text(problem)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.alarm)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.caption.count <= 24 {
                HStack(spacing: 10) {
                    rule
                    Legend(state.caption, size: 11, colour: Palette.ink)
                    rule
                }
            } else {
                Legend(state.caption, size: 11, colour: Palette.ink)
                    .multilineTextAlignment(.center)
            }

            if let note = state.note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.body)
            }
        }
        .frame(width: 330)
    }

    private var rule: some View {
        Rectangle().fill(Palette.tick).frame(width: 26, height: 1)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            RowDivider()
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.legend)
                Legend("encrypted on device", size: 9)
                Spacer(minLength: 8)
                if let reached = services.stats?.backfillReached {
                    Legend("since \(spoken(day: reached))", size: 9)
                }
            }
            .padding(.top, 12)
        }
    }

    private var state: SyncState {
        SyncState(
            stats: services.stats,
            paused: services.paused,
            problem: services.lastError,
            timeLeft: services.timeLeft,
            progress: services.syncProgress
        )
    }

    // MARK: - Reaching further back

    private var reachBackSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Everything from the day you choose up to today is queued again. "
                            + "Efferent skips a day that is already in the archive.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.body)
                            .fixedSize(horizontal: false, vertical: true)
                        RangePicker(earliest: earliest, probed: probed, selection: $reachSelection)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)

                Button("Reach back to here") {
                    let day = RangePicker.startDay(
                        for: reachSelection, earliest: earliest, calendar: Day.calendar()
                    )
                    reachingBack = false
                    Task { await services.exportHistory(from: day) }
                }
                .buttonStyle(ProminentButton())
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .pageBackground()
            .navigationTitle("Reach further back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { reachingBack = false }
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .task {
            if !probed {
                earliest = await services.firstDayInHealth()
                probed = true
            }
        }
    }

    // MARK: - Health access

    /// There is deliberately no "access granted" anywhere in this app: Health
    /// never reports what a person allowed, so any such claim would be a guess
    /// worn as a fact. What this screen can honestly do is say where the
    /// switches live, and offer to ask again for anything still unanswered.
    private var accessSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Apple never tells an app what you allowed. Nothing here can confirm it — "
                    + "the switches in Health are the only record.")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("In Health: your picture, top right → Apps and Services → Efferent.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(spacing: 6) {
                    Button("Open Health") {
                        if let url = URL(string: "x-apple-health://"),
                           UIApplication.shared.canOpenURL(url)
                        {
                            UIApplication.shared.open(url)
                        }
                        explainingAccess = false
                    }
                    .buttonStyle(ProminentButton())
                    Button("Ask again for anything unanswered") {
                        explainingAccess = false
                        Task { await services.requestHealthAccess() }
                    }
                    .buttonStyle(QuietButton())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pageBackground()
            .navigationTitle("Health access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { explainingAccess = false }
                        .foregroundStyle(Palette.accent)
                }
            }
        }
    }
}

/// What the screen says, worked out in one place so the wording is one thing to
/// read and to change.
///
/// The face answers "how much is left"; the line under the dial answers "and
/// how long will that take", which is the only other thing anybody wants to
/// know while it runs. How many days are already in the archive, and when the
/// last one went, are not questions the everyday screen exists to answer — a
/// count nobody acts on is furniture, and it was crowding out the sentence that
/// matters.
struct SyncState {
    /// The figure on the face: days still to send.
    let remaining: String
    /// The word beside the indicator at the top.
    let status: String
    /// The legend under the dial.
    let caption: String
    /// The one plain sentence some states add under that legend.
    let note: String?
    /// Something went wrong, in words a person can read.
    let problem: String?
    /// Everything Health has offered is in the archive, and that is good news.
    let settled: Bool
    /// How much of the scale is lit. Not always the same as how much of the run
    /// is done: with nothing waiting the run is complete by arithmetic, and a
    /// full scale under "nothing sent yet" would announce a finished job at
    /// somebody whose archive is empty.
    let progress: Double
    let mood: RingMood

    init(
        stats: Stats?,
        paused: Bool,
        problem: String?,
        timeLeft: TimeInterval?,
        progress: Double
    ) {
        let sentDays = stats?.sentDays ?? 0
        let pending = stats?.pendingDays ?? 0
        remaining = grouped(pending)

        if let problem {
            self.problem = problem
            status = "stopped"
            caption = ""
            note = nil
            settled = false
            self.progress = progress
            mood = .stopped
            return
        }
        self.problem = nil

        if paused {
            status = "paused"
            caption = "paused"
            note = nil
            settled = false
            self.progress = progress
            mood = .resting
            return
        }

        if pending > 0 {
            settled = false
            self.progress = progress
            mood = .alight
            status = "sending"
            // No estimate until the phone has watched enough days go to have
            // one. "Sending" is the honest thing to say meanwhile.
            caption = timeLeft.map { "\(spoken(duration: $0)) left" } ?? "sending"
            note = nil
        } else if sentDays == 0 {
            // Not the same fact as "nothing waiting": nothing has ever gone,
            // and the usual reason is that Health is not sharing anything.
            settled = false
            self.progress = 0
            mood = .resting
            status = "nothing sent"
            caption = "nothing sent yet · check health access"
            note = nil
        } else if let last = stats?.lastUploadAt, let quiet = Self.daysQuiet(since: last) {
            // The screen does not report when the last day went — nobody acts
            // on that. It reports the silence, and only once the silence is
            // itself the news: an archive that quietly stopped growing looks
            // exactly like one that is up to date.
            settled = false
            self.progress = 1
            mood = .resting
            status = "quiet"
            caption = "nothing sent for \(quiet) days"
            note = nil
        } else {
            settled = true
            self.progress = 1
            mood = .alight
            status = "up to date"
            caption = "every day is in the archive"
            note = "Efferent sends each new day by itself."
        }
    }

    /// What the button is worth saying out loud, which is the state rather than
    /// the figure once the figure is nought.
    var spokenValue: String {
        settled ? "Up to date" : "\(remaining) days waiting"
    }

    /// How long the archive has been silent, when that is long enough to say.
    /// Three days: a phone in a drawer for a weekend is not news, and a week is
    /// too late to hear about it.
    private static func daysQuiet(since last: Date) -> Int? {
        let days = Int(Date().timeIntervalSince(last) / (24 * 60 * 60))
        return days >= 3 ? days : nil
    }
}
