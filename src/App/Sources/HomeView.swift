import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var connecting = false
    @State private var reachingBack = false
    @State private var explainingAccess = false
    @State private var confirmingDisconnect = false
    /// Health's own first record, looked at again each time the sheet opens.
    @StateObject private var earliest = EarliestDay()
    @State private var reachSelection: RangeSelection = .everything
    @State private var readingLog = false
    @State private var readingEdits = false
    /// Taps on the name so far. The log is not a feature of this app, so it has
    /// no key of its own: five taps on the name open it, and putting the app
    /// down forgets them.
    @State private var brandTaps = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            agentNotice

            Spacer(minLength: 0)

            // The dial is centred on the room left between the brand row and
            // the block of keys, not on the glass: the bottom of this screen
            // carries far more than the top, so a dial centred on the screen
            // sits visibly low in the space it actually occupies.
            //
            // The line under it used to hang off the dial as an overlay so a
            // long caption could not shove the dial upwards. On a phone shorter
            // than the one it was written on that backfired: an overlay takes
            // no room at all, the two spacers above and below collapsed to
            // nothing, and the caption was drawn straight over the footer,
            // illegibly. Found on the owner's phone, 2026-09-20, in the state a
            // healthy phone sits in nearly all the time. The words are in the
            // stack now and reserve `captionRoom` whatever they say, which is
            // what keeps the dial still: a block centred between two spacers
            // rises by half of whatever grows underneath it, so a caption that
            // gained a line moved the figure on the face. Only something longer
            // than the reserve moves it now, and moving the dial is better than
            // writing over the lines below.
            VStack(spacing: 22) {
                instrument
                caption.frame(minHeight: Self.captionRoom, alignment: .top)
            }

            Spacer(minLength: 0)

            footer
            if !services.agentConnected {
                connect
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            keys
                .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Things that join or leave the shell — the strip about an agent's
        // edits, the lit invitation, the key into the journal — make room at
        // one pace instead of shoving the dial in a single frame.
        .animation(Motion.standard(reduced: reduceMotion), value: noticeShown)
        .animation(Motion.standard(reduced: reduceMotion), value: services.agentConnected)
        .animation(Motion.standard(reduced: reduceMotion), value: services.edits.ever.anything)
        .pageBackground()
        .onChange(of: phase) { _, new in
            if new != .active {
                brandTaps = 0
            }
        }
        .onAppear {
            // Straight out of the walkthrough, the one thing left to do is hand
            // the archive over, so the screen opens on it rather than leaving a
            // lit key for somebody to find. Once only: an archive nobody chose
            // to connect is a decision, not an oversight to nag about.
            if services.offerHandoff {
                services.handoffOffered()
                connecting = true
            }
        }
        .task {
            // The counters move on the upload session's own queue while this
            // screen is open, most visibly during a first export. Cancelled
            // with the view, so it costs nothing when nobody is looking.
            while !Task.isCancelled {
                services.refreshStats()
                // Alongside them, because background refresh is switched in the
                // system settings — which is to say, while this app is not
                // running and cannot be told.
                services.refreshReach()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task {
            // Somebody is looking at this screen, so the phone asks the archive
            // what the agent has sent. Nothing else on an open phone does: the
            // only trigger that fires by itself is Health getting new data, and
            // an edit makes none — which is why an app left open on a still
            // phone used to learn nothing at all.
            //
            // One listing request, no Health and no days, and cancelled with
            // the view. 15 seconds against a promise of 20 leaves the request
            // itself room to finish.
            while !Task.isCancelled {
                await services.deliverEdits()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $readingLog) { LogView() }
        .sheet(isPresented: $readingEdits) { EditsView() }
        .sheet(isPresented: $connecting) { connectSheet }
        .sheet(isPresented: $reachingBack) { reachBackSheet }
        .sheet(isPresented: $explainingAccess) { accessSheet }
        .alert("Disconnect?", isPresented: $confirmingDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await services.disconnect() }
            }
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
                .onTapGesture { countBrandTap() }
            Circle()
                .fill(state.mood == .alight ? Palette.accent : Palette.legend)
                .frame(width: 7, height: 7)
            Legend(state.status, size: 9)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            if let reached = services.stats?.backfillReached {
                // A date rather than a count: a month's letters do not roll.
                Legend("since \(spoken(day: reached))", size: 9)
                    .contentTransition(.opacity)
            }
        }
        .frame(height: 34)
        .animation(Motion.standard, value: state.status)
        .animation(Motion.standard, value: services.stats?.backfillReached)
    }

    /// Five taps on the name open the log, counted within one sitting: the
    /// count starts again whenever the app is put down, so a stray tap today
    /// and another next week never add up to it. No stopwatch, because a rule
    /// that also asks a person to be quick is a rule they cannot be told.
    private func countBrandTap() {
        brandTaps += 1
        guard brandTaps >= 5 else { return }
        brandTaps = 0
        readingLog = true
    }

    /// The rare things, printed on keys along the bottom: reaching further
    /// back, the Health switches, and giving the archive up. Everything a
    /// person does daily is the dial itself, so nothing else belongs here.
    private var keys: some View {
        VStack(spacing: 0) {
            RowDivider()
            if services.edits.ever.anything {
                editsKey
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            HStack(alignment: .top, spacing: 8) {
                KeyButton(label: "reach back", symbol: "clock.arrow.circlepath") {
                    reachSelection = .everything
                    reachingBack = true
                }
                KeyButton(label: "health access", symbol: "heart.text.square") {
                    explainingAccess = true
                }
                if services.agentConnected {
                    KeyButton(label: "connect agent", symbol: "square.and.arrow.up") {
                        connecting = true
                    }
                    .transition(.opacity)
                }
                KeyButton(label: "disconnect", symbol: "power") {
                    confirmingDisconnect = true
                }
            }
            .padding(.top, 14)
        }
    }

    // MARK: - What the agent changed

    /// What an agent has just done, across the top of the screen, until it has
    /// been looked at.
    ///
    /// The one dark surface in the app, and the only thing allowed above the
    /// dial: a run that has just landed is news, and news has a shelf life.
    /// Opening the list is what ends it — the same run tomorrow is history, and
    /// history belongs in the list.
    @ViewBuilder private var agentNotice: some View {
        if services.edits.unseen.total == 0, let held = services.stats?.editsHeldByLock, held > 0 {
            // Listed at the service, not yet in Health, because the screen was
            // locked when this phone looked. Said plainly rather than left as
            // an empty screen: the person is about to unlock the phone anyway,
            // and this is the sentence that makes the wait legible.
            DarkPanel(padding: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Legend("agent edits · on the way", size: 9, colour: Palette.darkLegend)
                    Text(EditWords.onTheWay(held))
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
            .transition(.arriving(reduced: reduceMotion))
        } else if services.edits.unseen.total > 0 {
            DarkPanel(padding: 0) {
                Button { readingEdits = true } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Legend("agent edits · just now", size: 9, colour: Palette.darkLegend)
                        Text(EditWords.summary(services.edits.unseen))
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableKey())

                if services.edits.unseen.written > 0 {
                    Palette.body.frame(height: 1)
                    Button {
                        Task { await services.actOnRecentRun() }
                    } label: {
                        // The one key that cannot be named by an operation: a run
                        // may hold both, so pressing this removes some records
                        // and writes others back. It names the intent instead,
                        // and each record's own page names the operation.
                        Legend("take it all back", size: 11, colour: Palette.accent)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableKey())
                }
            }
            .padding(.top, 12)
            .transition(.arriving(reduced: reduceMotion))
        }
    }

    /// Which strip is across the top, if any, so its arrival can be animated
    /// as one change.
    private var noticeShown: Int {
        if services.edits.unseen.total > 0 { return 2 }
        if let held = services.stats?.editsHeldByLock, held > 0 { return 1 }
        return 0
    }

    /// The way into everything an agent has ever done, once anything has been.
    ///
    /// A key rather than a row: it is named for where it goes and drawn with the
    /// panel and hairline every other key has. Before, it was a bare line
    /// carrying a tally, which read as a caption about today — a person looking
    /// for what happened last week found nothing on this screen offering it.
    private var editsKey: some View {
        WideKeyButton(
            label: "agent edits",
            symbol: "list.bullet.rectangle",
            detail: countedEdits,
            lit: services.edits.unseen.total > 0
        ) { readingEdits = true }
    }

    /// Today's tally while there is one, and the whole journal's when there is
    /// not: a row that said "no edits" on a phone an agent writes to every week
    /// would be a fact about this morning wearing the clothes of a total.
    private var countedEdits: String {
        let today = services.edits.today
        // The question is counted here as well, first, but it never takes the
        // row over: this is the way into the journal, and a row that said only
        // "2 waiting" would leave a person with no way to what an agent did.
        // The ask has a strip of its own across the top for that.
        if today.anything {
            return EditWords.counted(today) + " today"
        }
        return EditWords.counted(services.edits.ever) + " in all"
    }

    // MARK: - Handing the archive to an agent

    /// An archive nobody can read is the state this app is least useful in, so
    /// while the setup text has never gone anywhere the way out of it is a key
    /// across the whole shell, lit. Once it has gone, that key is not news any
    /// more: it steps down into the row with the other things you may do again
    /// one day, and the screen goes back to being the dial.
    private var connect: some View {
        Button("Connect agent") { connecting = true }
            .buttonStyle(ConnectButton())
    }

    private var connectSheet: some View {
        NavigationStack {
            ConnectContent { connecting = false }
                .pageBackground()
                .navigationTitle("Connect your agent")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { connecting = false }
                            .foregroundStyle(Palette.accent)
                    }
                }
        }
    }

    // MARK: - The dial and its face

    private var instrument: some View {
        ZStack {
            // Reading Health again has no figure yet, so the arc walks round
            // until the count comes back.
            Dial(progress: state.progress, mood: state.mood, side: 264, waiting: state.rereading)
            Button {
                services.setPaused(!services.paused)
            } label: {
                face
            }
            .buttonStyle(PressableKey())
            // Starting and stopping is the one thing a person does here daily,
            // and a light tap under the thumb says it took.
            .sensoryFeedback(.impact(weight: .light), trigger: services.paused)
            .accessibilityLabel(services.paused ? "Start sending" : "Stop sending")
            .accessibilityValue(state.spokenValue)
        }
        .frame(width: 264, height: 264)
    }

    private var face: some View {
        VStack(spacing: 6) {
            if state.settled {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Palette.accent)
                    Text("Up to date")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                .transition(.face(reduced: reduceMotion))
            } else {
                VStack(spacing: 6) {
                    Text(state.remaining)
                        .font(.system(size: 44, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        // The figure counts down in place as days go, rather
                        // than being replaced by another figure every two
                        // seconds.
                        .contentTransition(.numericText(countsDown: true))
                    // "days left" read as time — the one thing this number is
                    // not. It says what the days are: work still to do.
                    Legend("days waiting")
                }
                .transition(.face(reduced: reduceMotion))
            }
            Image(systemName: services.paused ? "play.fill" : "pause.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink)
                .contentTransition(.symbolEffect(.replace))
                .padding(.top, 8)
        }
        .frame(width: 186, height: 186)
        .contentShape(Circle())
        .animation(Motion.standard(reduced: reduceMotion), value: state.settled)
        .animation(Motion.standard, value: state.remaining)
        .animation(Motion.snappy, value: services.paused)
    }

    // MARK: - The line under the dial

    /// The room kept under the dial for the words, whatever they turn out to
    /// be. Two lines of legend, which is more than any ordinary caption takes
    /// and enough that none of them moves the dial: a figure that shifts when
    /// the words below it change reads as the figure changing.
    private static let captionRoom: CGFloat = 34

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
                        .contentTransition(.opacity)
                    rule
                }
            } else {
                Legend(state.caption, size: 11, colour: Palette.ink)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
        }
        .frame(width: 330)
        // The sentence under the dial changes in place: the rules either side
        // of it close in or open out with the words.
        .animation(Motion.standard(reduced: reduceMotion), value: state.caption)
        .animation(Motion.standard(reduced: reduceMotion), value: state.problem)
    }

    private var rule: some View {
        Rectangle().fill(Palette.tick).frame(width: 26, height: 1)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.legend)
                Legend("encrypted on device", size: 9)
            }
            // An agent who sent nothing and a phone that never looked are the
            // same empty screen, and one of them is a fault. This is the line
            // that tells them apart — and the one that makes an app iOS has
            // stopped waking recognisable, because its time stops moving.
            if services.agentConnected {
                Legend(
                    deliveryLine.text, size: 9,
                    colour: deliveryLine.isFault ? Palette.alarm : Palette.legend
                )
            }
        }
    }

    /// When the archive was last asked what the agent has sent, or what stopped
    /// the asking. The words are `EditWords`' job; this only hands over what
    /// the phone knows.
    private var deliveryLine: EditWords.DeliveryLine {
        EditWords.delivery(
            paused: services.paused,
            healthUndecided: services.healthWriteUndecided,
            stopped: services.deliveryStop,
            reach: services.reach,
            checked: services.stats?.lastEditCheckAt
        )
    }

    private var state: SyncState {
        SyncState(
            stats: services.stats,
            paused: services.paused,
            rereading: services.rereading,
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
                        RangePicker(
                            earliest: earliest.day,
                            probed: earliest.looked,
                            selection: $reachSelection
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)

                Button("Reach back to here") {
                    let day = RangePicker.startDay(
                        for: reachSelection, earliest: earliest.day, calendar: services.calendar
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
        // Asked every time the sheet opens. Health may have been answered
        // since the last look — or since a look the walkthrough took before its
        // own Health sheet was shown — and a remembered "nothing" would go on
        // offering a range this phone has already outgrown.
        .task { await earliest.look { await services.firstDayInHealth() } }
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
    /// Something went wrong, in words a person can read.
    let problem: String?
    /// Health is being read again at the person's asking, so there is no
    /// figure to give yet.
    let rereading: Bool
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
        rereading: Bool = false,
        problem: String?,
        timeLeft: TimeInterval?,
        progress: Double
    ) {
        let sentDays = stats?.sentDays ?? 0
        let pending = stats?.pendingDays ?? 0
        self.rereading = rereading
        // A dash rather than a figure, because the count during a re-read is
        // of days to look at and not of days owed: the last week is marked
        // first and mostly written off a second later.
        remaining = rereading ? "—" : grouped(pending)

        if let problem {
            self.problem = problem
            status = "stopped"
            caption = ""
            settled = false
            self.progress = progress
            mood = .stopped
            return
        }
        self.problem = nil

        if paused {
            status = "paused"
            caption = "paused"
            settled = false
            self.progress = progress
            mood = .resting
            return
        }

        // Said in words, so the dash is a state and not a missing number. It
        // comes after the pause because a re-read is what starting ends with,
        // and before everything else because those all read the queue the
        // re-read is still changing.
        if rereading {
            status = "reading health"
            caption = "reading health"
            settled = false
            self.progress = progress
            mood = .alight
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
        } else if sentDays == 0 {
            // Not the same fact as "nothing waiting": nothing has ever gone,
            // and the usual reason is that Health is not sharing anything.
            settled = false
            self.progress = 0
            mood = .resting
            status = "nothing sent"
            caption = "nothing sent yet · check health access"
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
        } else {
            settled = true
            self.progress = 1
            mood = .alight
            status = "up to date"
            caption = "every day is in the archive"
        }
    }

    /// What the button is worth saying out loud, which is the state rather than
    /// the figure once the figure is nought.
    var spokenValue: String {
        if rereading {
            // "— days waiting" is what a screen reader would otherwise make
            // of the dash.
            return "Reading Health"
        }
        return settled ? "Up to date" : "\(remaining) days waiting"
    }

    /// How long the archive has been silent, when that is long enough to say.
    /// Three days: a phone in a drawer for a weekend is not news, and a week is
    /// too late to hear about it.
    private static func daysQuiet(since last: Date) -> Int? {
        let days = Int(Date().timeIntervalSince(last) / (24 * 60 * 60))
        return days >= 3 ? days : nil
    }
}

/// The system share sheet, with the one thing `ShareLink` cannot give: an
/// answer.
///
/// Whether the setup text actually went somewhere is what dims the key on the
/// everyday screen, and `ShareLink` never reports the outcome — so a cancelled
/// share would count as a handed-over archive. `UIActivityViewController` says
/// what happened, and that is the whole reason for the detour through UIKit.
struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    /// What the text is called when it travels as a file, which is how AirDrop
    /// takes it.
    var filename = "efferent.txt"
    /// `true` when an activity finished, `false` when the sheet was dismissed.
    let done: (Bool) -> Void

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let item = TextToShare(text, named: filename)
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            item.clean()
            done(completed)
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

/// The text, with a type on it.
///
/// A bare string is guessed at by whoever receives it. The setup prompt begins
/// "Instruction:", and an AirDropped string whose first word ends in a colon is
/// read as a URL scheme: the receiving phone answered "There is no application
/// set to open the URL Instruction:%0AConnect%20the…" and the prompt never
/// arrived. So AirDrop is handed a text file, which is a thing with a type
/// nobody has to guess at, and every other way of sending it is handed the text
/// itself — a message, a note or the clipboard is meant to hold the prompt, not
/// an attachment.
final class TextToShare: NSObject, UIActivityItemSource {
    private let text: String
    private let file: URL?

    init(_ text: String, named filename: String) {
        self.text = text
        file = Self.write(text, named: filename)
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(
        _: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?
    ) -> Any? {
        guard type == .airDrop, let file else { return text }
        return file
    }

    func activityViewController(
        _: UIActivityViewController, dataTypeIdentifierForActivityType _: UIActivity.ActivityType?
    ) -> String {
        UTType.plainText.identifier
    }

    func activityViewController(
        _: UIActivityViewController, subjectForActivityType _: UIActivity.ActivityType?
    ) -> String {
        "Efferent"
    }

    /// The file the AirDrop travels as. It holds the keys that open the
    /// archive, so it is written where only this app can read it and taken away
    /// the moment the sheet is finished with — which is after the transfer,
    /// since that answer is what tells this app the prompt went somewhere.
    private static func write(_ text: String, named filename: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    func clean() {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

/// What the connect sheet shows: the prompt, and the two ways to hand it over.
///
/// Its own view rather than a part of the sheet so that the store screenshot
/// can render it without presenting anything.
struct ConnectContent: View {
    @EnvironmentObject private var services: Services
    @State private var sharing = false
    /// Called once the prompt has gone somewhere, so the sheet can close.
    let done: () -> Void
    /// Off for the store screenshot: an image renderer draws a scroll view as
    /// nothing at all, and the prompt fits the screen without one.
    var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView { explanation }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                explanation
                Spacer(minLength: 0)
            }

            if let handoff = services.connectionHandoff {
                VStack(spacing: 6) {
                    Button("Send the prompt to your agent") { sharing = true }
                        .buttonStyle(ProminentButton())
                        .sheet(isPresented: $sharing) {
                            ShareSheet(text: handoff.text, filename: "efferent-setup.txt") { shared in
                                sharing = false
                                // Only a share that went through counts as
                                // handed over. A cancelled one changes
                                // nothing, because nothing happened.
                                if shared {
                                    services.markAgentConnected()
                                    done()
                                }
                            }
                        }
                    Button("Copy the prompt") {
                        UIPasteboard.general.string = handoff.text
                        services.markAgentConnected()
                        done()
                    }
                    .buttonStyle(QuietButton())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this whole prompt to your agent — ChatGPT, Claude, Gemini, "
                + "whatever you use. The prompt says what to do, where the archive "
                + "is and what opens it.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.body)
                .fixedSize(horizontal: false, vertical: true)
            handoffPanel
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.legend)
                Legend("send this prompt only to an agent you trust", size: 9)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    /// What the phone hands over is one prompt, exactly as the app composes it.
    /// Split into fields on screen, it invites pasting a part of it — and a
    /// part of it opens nothing.
    private var handoffPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Legend("prompt for your agent", size: 9, colour: Palette.darkLegend)
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
}
