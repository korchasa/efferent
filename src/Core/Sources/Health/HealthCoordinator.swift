import Foundation
import HealthKit
import os

/// Drives collection: subscribes to HealthKit, works out which days changed,
/// and builds a day when one is asked for.
///
/// Nothing here sends anything. It marks days and calls ``onNewData`` when
/// there is something worth sending; the uploader decides when that happens.
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
            subscribe(to: metric.type, frequency: .immediate) { [weak self] in
                _ = try await self?.noteChanges(metric: metric)
            }
        }
        for metric in AggregateMetric.all {
            // Hourly is the real ceiling anyway: the system quietly downgrades
            // `.immediate` for these types. And a total has no anchor to consult,
            // so all a delivery can say is "the recent past moved".
            subscribe(to: metric.type, frequency: .hourly) { [weak self] in
                _ = try self?.markRecentDays()
            }
        }
    }

    private func subscribe(
        to type: HKSampleType,
        frequency: HKUpdateFrequency,
        work: @escaping @Sendable () async throws -> Void
    ) {
        healthStore.enableBackgroundDelivery(for: type, frequency: frequency) { [log] enabled, error in
            if let error {
                log.error("background delivery for \(type.identifier) refused: \(error.localizedDescription)")
            } else if !enabled {
                log.error("background delivery for \(type.identifier) was not enabled")
            }
        }

        let query = HKObserverQuery(sampleType: type, predicate: nil) { [log, weak self] _, completion, error in
            if let error {
                log.error("observer for \(type.identifier) failed: \(error.localizedDescription)")
                completion()
                return
            }
            Task {
                // Written down even when nothing changed. "Health woke the app
                // and there was nothing new" and "Health never woke the app"
                // look identical from the outside, and they are the two halves
                // of every strange sending problem.
                log.info("Health woke us about \(type.identifier)")
                do {
                    try await work()
                } catch {
                    log.error("collection failed: \(String(describing: error))")
                }
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
        log.debug(
            "\(metric.name): Health offered \(changes.days.count) changed days and "
                + "\(changes.removed.count) deletions in \(Uploader.milliseconds(since: started)) ms"
                + (stored == nil ? ", from no anchor at all" : "")
        )
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
        log.debug("the last \(days.count) days were looked at again: \(marked) now waiting")
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
        if marked > 0 {
            onNewData?()
        }
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
        onNewData?()
        return marked
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

        let expected = try Day.range(from: earliest, to: today, in: calendar)
        let held = try await archive.days()
        let missing = expected.filter { !held.contains($0) }
        guard !missing.isEmpty else {
            log.info("archive agrees: all \(expected.count) days are there")
            return 0
        }

        let marked = try store.markMissing(missing)
        log.error(
            "archive is missing \(missing.count) of \(expected.count) days "
                + "(\(missing.first ?? "") … \(missing.last ?? "")); \(marked) owed again"
        )
        onNewData?()
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
