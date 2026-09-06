import Foundation
import HealthKit
import os

/// Drives collection: subscribes to HealthKit, works out which days changed,
/// and builds a day when one is asked for.
///
/// Nothing here sends anything. A delivery marks what moved and then calls
/// ``onNewData``; every other way in is asked for by something that sends
/// straight afterwards, so it marks and returns. The uploader decides when
/// anything actually goes.
///
/// The shape to keep in mind: a change is never turned into an update. It is
/// turned into the *date* it happened on, and that day is later read out of
/// Health in full. So what reaches the archive is always what Health says right
/// now, never a running total of differences that has to have been right every
/// time.
public final class HealthCoordinator {
    /// Days re-read on every refresh.
    ///
    /// The Watch syncs late, so yesterday can still grow tomorrow. Re-reading a
    /// week costs almost nothing because a day whose contents did not change is
    /// never uploaded — see ``Uploader``.
    public static let recomputedDays = 7

    /// How often a delivery may ask for the recent past to be re-read.
    ///
    /// Marking the week is free; the pass that follows is not — it reads those
    /// seven days out of Health in full, thousands of readings, for the digest
    /// to say every one is unchanged. Two deliveries twelve seconds apart did
    /// exactly that. Totals are the only reason to re-read blindly and they are
    /// not delivered faster than hourly, so a second look inside this window
    /// cannot find anything the first one missed.
    public static let recentMarkEvery: TimeInterval = 20 * 60

    private let store: Store
    private let reader: HealthReader
    private let healthStore: HKHealthStore
    private let calendar: Calendar
    private let log = Log(category: "health")
    private var observers: [HKObserverQuery] = []

    /// Called after days are marked as needing to go.
    public var onNewData: (() -> Void)?

    public init(
        store: Store,
        healthStore: HKHealthStore = HKHealthStore(),
        calendar: Calendar = Day.calendar()
    ) {
        self.store = store
        self.healthStore = healthStore
        self.calendar = calendar
        reader = HealthReader(healthStore: healthStore, calendar: calendar)
    }

    public func requestAuthorization() async throws {
        try await reader.requestAuthorization()
    }

    public var today: String {
        Day.of(Date(), in: calendar)
    }

    // MARK: - Subscriptions

    /// Subscribe to every type the app collects.
    ///
    /// Call this synchronously from `application(_:didFinishLaunchingWithOptions:)`.
    /// The system launches the app in the background with no interface, and an
    /// observer registered from a `Task` or when a view appears is simply never
    /// registered in that launch — deliveries then stop arriving, with nothing
    /// to show for it.
    public func startObserving() {
        guard HealthReader.isAvailable else {
            log.error("HealthKit is not available on this device")
            return
        }

        for metric in SampleMetric.all {
            enableDelivery(for: metric.type, frequency: .immediate)
        }
        for metric in AggregateMetric.all {
            // Hourly is the real ceiling anyway: the system quietly downgrades
            // `.immediate` for these types. And a total has no anchor to consult,
            // so all a delivery can say is "the recent past moved".
            enableDelivery(for: metric.type, frequency: .hourly)
        }

        // One observer over every type, not one per type.
        //
        // A single-type observer is called once per type, so a Watch catching
        // up woke the app fourteen times in the same second — fourteen reads of
        // the ledger, fourteen asks to send, thirteen of them turned away by the
        // pass already running. This form hands the changed types to one
        // handler, which reads each of them once and asks to send once.
        //
        // Background delivery stays per type: that is where the frequency
        // lives, and the two families want different ones.
        let descriptors = (SampleMetric.all.map(\.type) + AggregateMetric.all.map(\.type))
            .map { HKQueryDescriptor(sampleType: $0, predicate: nil) }
        let query = HKObserverQuery(queryDescriptors: descriptors) {
            [log, weak self] _, changed, completion, error in
            if let error {
                log.error("the observer failed: \(error.localizedDescription)")
                completion()
                return
            }
            Task {
                await self?.collect(changed)
                // Always, and before anything slow. HealthKit treats a missing
                // acknowledgement as a failed delivery, retries, and after a few
                // of those stops waking the app at all — silently, and days later.
                completion()
                self?.onNewData?()
            }
        }
        healthStore.execute(query)
        observers.append(query)
    }

    private func enableDelivery(for type: HKSampleType, frequency: HKUpdateFrequency) {
        healthStore.enableBackgroundDelivery(for: type, frequency: frequency) { [log] enabled, error in
            if let error {
                log.error("background delivery for \(type.identifier) refused: \(error.localizedDescription)")
            } else if !enabled {
                log.error("background delivery for \(type.identifier) was not enabled")
            }
        }
    }

    /// What one wake-up does: read the metrics Health says moved, and mark the
    /// recent past when a total moved.
    ///
    /// Every metric is read even if an earlier one failed. They share nothing —
    /// each has its own anchor — and one metric Health is unhappy about is no
    /// reason to leave the other six unread until the next delivery.
    func collect(_ changed: Set<HKSampleType>?) async {
        let plan = Self.plan(for: changed)
        // Written down even when nothing changed. "Health woke the app and
        // there was nothing new" and "Health never woke the app" look identical
        // from the outside, and they are the two halves of every strange
        // sending problem.
        log.info(Self.woke(plan))

        if plan.totals {
            do {
                _ = try markRecentDaysIfDue()
            } catch {
                log.error("marking the recent past failed: \(String(describing: error))")
            }
        }
        for metric in plan.metrics {
            do {
                _ = try await noteChanges(metric: metric)
            } catch {
                log.error("\(metric.name): collection failed: \(String(describing: error))")
            }
        }
    }

    /// What a set of changed types asks to be done. Kept apart from the doing
    /// so the mapping can be read and tested without a Health store.
    struct Plan {
        /// Whether to mark the recent past. Totals have no anchor, so all any
        /// of them can say is "the recent past moved" — and once is enough,
        /// however many of them said it.
        let totals: Bool
        let metrics: [SampleMetric]
        /// What moved, in the order the work runs.
        let names: [String]
        /// Health would not say what moved. Everything is read: an unknown
        /// change is not the same as no change.
        let unnamed: Bool
    }

    /// How a wake-up reads in the log.
    ///
    /// The empty case is real and not a fault: Health delivers to a freshly
    /// registered observer whether or not anything has moved, and on a phone
    /// with nothing stored for these types that delivery names nothing.
    static func woke(_ plan: Plan) -> String {
        if plan.unnamed {
            return "Health woke us without saying what moved, so everything is read"
        }
        if plan.names.isEmpty {
            return "Health woke us with nothing to say about anything we collect"
        }
        return "Health woke us about " + plan.names.joined(separator: ", ")
    }

    static func plan(for changed: Set<HKSampleType>?) -> Plan {
        guard let changed else {
            return Plan(totals: true, metrics: SampleMetric.all, names: [], unnamed: true)
        }
        let moved = Set(changed.map(\.identifier))
        let totals = AggregateMetric.all.filter { moved.contains($0.type.identifier) }
        let metrics = SampleMetric.all.filter { moved.contains($0.type.identifier) }
        return Plan(
            totals: !totals.isEmpty,
            metrics: metrics,
            names: totals.map(\.name) + metrics.map(\.name),
            unnamed: false
        )
    }

    public func stopObserving() {
        for query in observers {
            healthStore.stop(query)
        }
        observers.removeAll()
    }

    // MARK: - Noticing

    /// Work out which days `metric` changed on, and mark them.
    ///
    /// The days and the new anchor go down in one transaction. That is the one
    /// rule this method exists to keep: an anchor saved without its marks tells
    /// HealthKit the change was handled, and it is never offered again.
    @discardableResult
    public func noteChanges(metric: SampleMetric) async throws -> Int {
        let stored = try store.anchor(for: metric.type.identifier)
        let previous = try stored.flatMap(HKQueryAnchor.decode)

        let started = Date()
        let changes = try await reader.changedDays(metric: metric, anchor: previous)
        // Written down when Health had something to say, and on the first read
        // of a metric, which is the one time an empty answer is worth knowing
        // about. The rest of the time this is every wake-up saying "nothing".
        if !changes.days.isEmpty || !changes.removed.isEmpty || stored == nil {
            log.debug(
                "\(metric.name): Health offered \(changes.days.count) changed days and "
                    + "\(changes.removed.count) deletions in \(Uploader.milliseconds(since: started)) ms"
                    + (stored == nil ? ", from no anchor at all" : "")
            )
        }
        // A deletion arrives as a bare identifier, so the day it was in has to
        // come from what was written down when the day was last sent.
        let removedDays = try store.days(ofRemoved: changes.removed)

        let marked = try store.markDirty(
            changes.days.union(removedDays),
            anchor: Anchor(
                typeIdentifier: metric.type.identifier, value: changes.anchor.encoded()
            )
        )
        if marked > 0 {
            log.info("\(metric.name): \(marked) days to re-read")
        }
        return marked
    }

    /// Mark the recent past as worth re-reading. Cheap: an unchanged day is
    /// noticed as unchanged when it is built, and never leaves the phone.
    @discardableResult
    public func markRecentDays() throws -> Int {
        let startOfWindow = calendar.date(
            byAdding: .day, value: -(Self.recomputedDays - 1), to: Date()
        ) ?? Date()
        let days = try Day.range(
            from: Day.of(startOfWindow, in: calendar), to: today, in: calendar
        )
        let marked = try store.markDirty(days)
        // Only when it found something. Every Health delivery runs this, and a
        // week that has not moved is the ordinary answer, fourteen times a burst.
        if marked > 0 {
            log.debug("the last \(days.count) days were looked at again: \(marked) now waiting")
        }
        return marked
    }

    /// ``markRecentDays()`` with that floor under it, for deliveries.
    ///
    /// Only totals need the blind re-read, and only deliveries arrive faster
    /// than the data can change. A person pressing refresh gets the unthrottled
    /// one, and samples are never throttled at all: their anchors say precisely
    /// what moved, which is both cheap and exact.
    @discardableResult
    func markRecentDaysIfDue() throws -> Int {
        if let last = try store.lastRecentMarkAt(),
           Date().timeIntervalSince(last) < Self.recentMarkEvery
        {
            return 0
        }
        let marked = try markRecentDays()
        try store.recordRecentMark()
        return marked
    }

    /// Everything at once, for the button and for a background refresh.
    @discardableResult
    public func refresh() async throws -> Int {
        let started = Date()
        var marked = try markRecentDays()
        for metric in SampleMetric.all {
            marked += try await noteChanges(metric: metric)
        }
        log.info(
            "asked Health for everything new: \(marked) days waiting after it, "
                + "\(Uploader.milliseconds(since: started)) ms"
        )
        return marked
    }

    // MARK: - First export

    /// The first day Health has anything about, or nil when it has nothing.
    ///
    /// Asked before the person is offered a starting point, so the offer can
    /// name a real date and a real number of days rather than a guess.
    public func firstDay() async throws -> String? {
        try await reader.earliestDay()
    }

    /// Mark every day Health has anything about, back to its very first record
    /// or to the day the person asked for, whichever is later.
    ///
    /// One transaction and a second of work, because marking a day is a row and
    /// nothing more. What takes the time afterwards is the sending, and that
    /// resumes on its own: a day is either still marked or it is not.
    ///
    /// A start earlier than Health's own first record is neither an error nor
    /// honoured: there is nothing there to send, and writing it down as the day
    /// reached would claim history the archive does not have. The record only
    /// ever moves backwards for the same reason — asking for a shorter range
    /// than one already covered adds nothing and must not un-claim the rest.
    @discardableResult
    public func markHistory(from start: String? = nil) async throws -> Int {
        guard let earliest = try await reader.earliestDay() else {
            log.info("no history in Health to export")
            return 0
        }
        let first = max(earliest, start ?? earliest)
        let days = try Day.range(from: first, to: today, in: calendar)
        let marked = try store.markDirty(days)
        let reached = try store.backfillReached()
        try store.recordBackfillReached(min(reached ?? first, first))
        log.info("history back to \(first): \(marked) days to send")
        try await seedAnchors()
        return marked
    }

    /// Give every metric that has no anchor yet one that stands at now.
    ///
    /// The first anchored read of a metric is offered its whole history, and
    /// on a fresh install that read used to come *after* the first export had
    /// sent most of it: 1 737 days went back into the queue as "changed" a
    /// half hour after they had reached the archive, and the phone read every
    /// one of them out of Health again to learn that nothing had moved. Done
    /// here, right after the history is marked, the same read marks nothing —
    /// the days are already waiting — and only the anchor is written down.
    /// It costs the one full read a first anchor always costs, about a minute
    /// for a decade, before the first upload rather than on top of it.
    private func seedAnchors() async throws {
        let started = Date()
        var seeded = 0
        for metric in SampleMetric.all where try store.anchor(for: metric.type.identifier) == nil {
            try await noteChanges(metric: metric)
            seeded += 1
        }
        if seeded > 0 {
            log.info(
                "\(seeded) metrics got their first anchor in "
                    + "\(Uploader.milliseconds(since: started)) ms"
            )
        }
    }

    // MARK: - Checking the archive

    /// Find the days the archive should hold and does not, and owe them again.
    ///
    /// This is the only thing that ever tests the device's own bookkeeping. A
    /// fingerprint says "the archive already holds exactly this day", and until
    /// something asks the archive, that is a belief rather than a fact. When it
    /// turns out false — a bucket recreated, objects deleted, a move that
    /// dropped some — nothing else in the design recovers from it: the day
    /// rebuilds identically, matches the fingerprint, and is never sent again.
    ///
    /// The comparison is against what *should* be there rather than against
    /// what this device remembers sending, so it also catches days that were
    /// never sent at all — a backfill cut short, a batch that failed while
    /// nobody was watching.
    ///
    /// A listing that cannot be read throws, and nothing is marked. That matters
    /// more than it looks: a half-read listing would name most of the archive as
    /// missing and set a decade re-uploading.
    @discardableResult
    public func reconcile(with archive: Archive) async throws -> Int {
        guard let earliest = try await reader.earliestDay() else { return 0 }

        // Only as far back as this phone was ever asked to go. Health knows
        // days from 2018; somebody who chose "the last 30 days" has an archive
        // that starts a month ago, and every day before it is missing on
        // purpose. Compared against Health's own first day instead, this check
        // would owe eight years of history back every time it ran, throw away
        // their fingerprints, and set the phone re-reading a decade a day.
        let start = try max(earliest, store.backfillReached() ?? earliest)
        let expected = try Day.range(from: start, to: today, in: calendar)
        let held = try await archive.days()
        let missing = expected.filter { held[$0] == nil }

        // A day that is there but the wrong size. The device wrote down how big
        // the object it sent was, so a write that landed cut short — the one
        // damage a listing of names can never show — is caught here and owed
        // again. Days sent before this was written down have nothing recorded
        // and are left alone rather than suspected.
        let sent = try store.sentBytes()
        let truncated = expected.filter { day in
            guard let there = held[day], let ours = sent[day] else { return false }
            return there != ours
        }

        let owed = missing + truncated
        guard !owed.isEmpty else {
            log.info("archive agrees: all \(expected.count) days are there, at the right size")
            return 0
        }

        let marked = try store.markMissing(owed)
        log.error(
            "archive is missing \(missing.count) of \(expected.count) days "
                + "(\(missing.first ?? "") … \(missing.last ?? "")) and holds "
                + "\(truncated.count) at the wrong size; \(marked) owed again"
        )
        // No ask to send from here. The only caller is the uploader's own check
        // at the start of a pass, so an ask would be refused by the pass that
        // made it — every time, by construction. That pass reads the queue after
        // the check, so it takes these days in the same round anyway.
        return marked
    }

    // MARK: - Building

    /// Read `days` out of Health, whole.
    ///
    /// Queried as one span rather than a day at a time. Health answers a range
    /// almost as fast as a single day, and the first export asks for thousands
    /// of them — per-day queries would turn a minute into an hour for no
    /// difference in the result.
    ///
    /// Hourly totals only from the day the app was installed. Buckets by the
    /// hour for a decade would be several hundred thousand readings at a
    /// resolution nobody asks of last decade, and daily totals for that history
    /// are what people actually look at.
    public func build(days: [String]) async throws -> [String: DayContents] {
        guard let first = days.min(), let last = days.max() else { return [:] }
        let span = try (start: Day.bounds(first, in: calendar).start,
                        end: Day.bounds(last, in: calendar).end)
        let wanted = Set(days)
        let hourlyFrom = try store.installedDay(defaultingTo: today)

        log.debug("building \(days.count) days from \(first) to \(last)")
        var readings: [Reading] = []
        for metric in AggregateMetric.all {
            readings += try await reader.aggregates(
                metric: metric, from: span.start, to: span.end, bucket: .day
            )
            if last >= hourlyFrom {
                let hourly = try Day.bounds(max(first, hourlyFrom), in: calendar).start
                readings += try await reader.aggregates(
                    metric: metric, from: hourly, to: span.end, bucket: .hour
                )
            }
        }
        for metric in SampleMetric.all {
            readings += try await reader.samples(metric: metric, from: span.start, to: span.end)
        }

        // Every wanted day gets an entry, including the ones Health had nothing
        // for. A day that came back empty is a fact about that day — and without
        // an entry it would stay marked forever, retried on every pass.
        var contents: [String: DayContents] = [:]
        for day in wanted {
            contents[day] = DayContents(events: [], sampleIdentifiers: [])
        }
        for reading in readings where wanted.contains(reading.day) {
            contents[reading.day]?.add(reading)
        }
        log.debug(
            "Health gave back \(readings.count) readings for those days"
                + (readings.isEmpty ? " — nothing at all is being shared" : "")
        )
        return contents
    }
}

/// One day as it will be sent: the events, and the identifiers of the records
/// they came from.
public struct DayContents: Sendable {
    public private(set) var events: [Event]
    /// What HealthKit will name if one of these records is later deleted. Kept
    /// on the device, never sent.
    public private(set) var sampleIdentifiers: [UUID]

    public init(events: [Event], sampleIdentifiers: [UUID]) {
        self.events = events
        self.sampleIdentifiers = sampleIdentifiers
    }

    mutating func add(_ reading: Reading) {
        events.append(reading.event)
        if let identifier = reading.identifier {
            sampleIdentifiers.append(identifier)
        }
    }
}
