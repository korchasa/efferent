import SwiftUI
import UIKit

/// The everyday screen: one button in the middle of the screen, the ring around
/// it, and a line underneath.
///
/// The button carries the number it is about — how many days are still to go —
/// so the thing you look at and the thing you press are the same thing, and the
/// ring around it is that number turning into progress. The line underneath is
/// the one sentence a number cannot say, and it must never let the three states
/// look alike: nothing waiting, nothing ever sent, and stopped days ago are
/// different facts, and each one says so in its own words.
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
            // The title and the footer are pinned around the outside rather
            // than stacked with the button, so nothing above or below it can
            // push the button off centre as its own text grows.
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)

            ring.overlay(alignment: .top) { caption.offset(y: 292) }
        }
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

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Efferent")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer()
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
                        Label("Share setup text", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    confirmingDisconnect = true
                } label: {
                    Label("Disconnect this phone", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.tertiary)
                    .frame(width: 36, height: 36)
                    .background(Palette.chip, in: Circle())
            }
        }
        .frame(height: 44)
    }

    // MARK: - The ring and the button

    private var ring: some View {
        ZStack {
            EmberRing(progress: services.syncProgress, mood: state.mood)
            Button {
                services.setPaused(!services.paused)
            } label: {
                VStack(spacing: 0) {
                    Text(state.remaining)
                        .font(.system(size: 44, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    // "days left" read as time — the one thing this number is
                    // not. It says what the days are: work still to do.
                    Text("days to send")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.secondary)
                    Image(systemName: services.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.top, 12)
                }
                .frame(width: 174, height: 174)
                .background(Palette.disc, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(services.paused ? "Start sending" : "Stop sending")
            .accessibilityValue("\(state.remaining) days to send")
        }
        .frame(width: 270, height: 270)
    }

    // MARK: - The line under the button

    private var caption: some View {
        Text(state.caption)
            .font(.system(size: 15))
            .foregroundStyle(state.mood == .stopped ? Palette.alarm : Palette.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock")
                .font(.system(size: 11, weight: .semibold))
            Text(footerText)
                .font(.system(size: 13))
        }
        .foregroundStyle(Palette.tertiary)
    }

    private var footerText: String {
        guard let reached = services.stats?.backfillReached else { return "Encrypted here" }
        return "Encrypted here · history since \(spoken(day: reached))"
    }

    private var state: SyncState {
        SyncState(
            stats: services.stats,
            paused: services.paused,
            problem: services.lastError,
            timeLeft: services.timeLeft
        )
    }

    // MARK: - Reaching further back

    private var reachBackSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Everything from the day you pick up to today is queued again. "
                            + "Days already in the archive are recognised and not sent twice.")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        RangePicker(earliest: earliest, probed: probed, selection: $reachSelection)
                    }
                    .padding(.horizontal, 18)
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
                .padding(.horizontal, 22)
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
    /// worn as a fact. What this screen can honestly do is say where the switch
    /// lives, and offer to ask again for anything still unanswered.
    private var accessSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Health does not tell an app what it was allowed to read. If the count on "
                    + "the main screen is not moving, this is the thing to check.")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("In Health: your picture, top right → Apps and Services → Efferent.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                VStack(spacing: 14) {
                    Button("Open Health") {
                        if let url = URL(string: "x-apple-health://"),
                           UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url)
                        }
                        explainingAccess = false
                    }
                    .buttonStyle(ProminentButton())
                    Button("Ask again for anything unanswered") {
                        explainingAccess = false
                        Task { await services.requestHealthAccess() }
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 22)
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
/// The button answers "how much is left"; this answers "and how long will that
/// take", which is the only other thing anybody wants to know while it runs.
/// How many days are already in the archive, and when the last one went, are
/// not questions the everyday screen exists to answer — a count nobody acts on
/// is furniture, and it was crowding out the sentence that matters.
struct SyncState {
    /// The figure inside the button: days still to send.
    let remaining: String
    let caption: String
    let mood: RingMood

    init(stats: Stats?, paused: Bool, problem: String?, timeLeft: TimeInterval?) {
        let sentDays = stats?.sentDays ?? 0
        let pending = stats?.pendingDays ?? 0
        remaining = grouped(pending)

        if let problem {
            caption = problem
            mood = .stopped
            return
        }

        if paused {
            caption = "paused"
            mood = .resting
            return
        }

        mood = .alight
        if pending > 0 {
            // No estimate until the phone has watched enough days go to have
            // one. "Sending" is the honest thing to say meanwhile.
            caption = timeLeft.map { "\(spoken(duration: $0)) left" } ?? "sending"
        } else if sentDays == 0 {
            // Not the same fact as "nothing waiting": nothing has ever gone,
            // and the usual reason is that Health is not sharing anything.
            caption = "nothing sent yet · check Health access"
        } else if let last = stats?.lastUploadAt, let quiet = Self.daysQuiet(since: last) {
            // The screen does not report when the last day went — nobody acts
            // on that. It reports the silence, and only once the silence is
            // itself the news: an archive that quietly stopped growing looks
            // exactly like one that is up to date.
            caption = "nothing sent for \(quiet) days"
        } else {
            caption = "up to date"
        }
    }

    /// How long the archive has been silent, when that is long enough to say.
    /// Three days: a phone in a drawer for a weekend is not news, and a week is
    /// too late to hear about it.
    private static func daysQuiet(since last: Date) -> Int? {
        let days = Int(Date().timeIntervalSince(last) / (24 * 60 * 60))
        return days >= 3 ? days : nil
    }
}

