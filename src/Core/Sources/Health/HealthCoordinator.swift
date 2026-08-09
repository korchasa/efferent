import Foundation
import HealthKit
import os

/// Drives collection: subscribes to HealthKit, turns what arrives into events,
/// and puts them in the outbox.
///
/// Nothing here sends anything. It calls ``onNewData`` when there is something
/// worth sending and lets the uploader decide when that happens.
public final class HealthCoordinator {
    /// Days of daily totals recomputed on every refresh.
    ///
    /// The Watch syncs late, so yesterday can still grow tomorrow. Re-reading a
    /// week costs nothing because unchanged days never leave the device — see
    /// `Store.commit`.
    public static let recomputedDays = 7
    /// Days of hourly totals kept fresh. Shorter than the daily window: hourly
    /// buckets are seven times the volume and settle much sooner.
    public static let hourlyWindowDays = 2

    private let store: Store
    private let reader: HealthReader
    private let healthStore: HKHealthStore
    private let calendar: Calendar
    private let log = Logger(subsystem: "dev.korchasa.efferent", category: "health")
    private var observers: [HKObserverQuery] = []

    /// Called after new events land in the outbox.
    public var onNewData: (() -> Void)?

    public init(store: Store, healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.store = store
        self.healthStore = healthStore
        self.calendar = calendar
        reader = HealthReader(healthStore: healthStore, calendar: calendar)
    }

    public func requestAuthorization() async throws {
        try await reader.requestAuthorization()
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
                _ = try await self?.drain(metric: metric)
            }
        }
        for metric in AggregateMetric.all {
            // Hourly is the real ceiling anyway: the system quietly downgrades
            // `.immediate` for these types.
            subscribe(to: metric.type, frequency: .hourly) { [weak self] in
                _ = try await self?.refreshRecentAggregates(metrics: [metric])
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
                log.error("background delivery for \(type.identifier, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            } else if !enabled {
                log.error("background delivery for \(type.identifier, privacy: .public) was not enabled")
            }
        }

        let query = HKObserverQuery(sampleType: type, predicate: nil) { [log, weak self] _, completion, error in
            if let error {
                log.error("observer for \(type.identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completion()
                return
            }
            Task {
                do {
                    try await work()
                } catch {
                    log.error("collection failed: \(String(describing: error), privacy: .public)")
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

    // MARK: - Collection

    /// Read everything new for one record-by-record metric and store it.
    ///
    /// The events and the new anchor go into a single transaction. That is the
    /// one rule this method exists to keep: an anchor saved without its events
    /// tells HealthKit the data was delivered, and it is never offered again.
    @discardableResult
    public func drain(metric: SampleMetric) async throws -> Int {
        let stored = try store.anchor(for: metric.type.identifier)
        let previous = try stored.flatMap(HKQueryAnchor.decode)

        let batch = try await reader.samples(metric: metric, anchor: previous)
        let result = try store.commit(
            events: batch.events,
            anchor: Anchor(typeIdentifier: metric.type.identifier, value: batch.anchor.encoded())
        )
        if result.enqueued > 0 {
            log.info("\(metric.name, privacy: .public): queued \(result.enqueued) events")
        }
        return result.enqueued
    }

    /// Recompute the recent totals: a week of days, two days of hours.
    @discardableResult
    public func refreshRecentAggregates(
        metrics: [AggregateMetric] = AggregateMetric.all
    ) async throws -> Int {
        let now = Date()
        let dayFrom = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -Self.recomputedDays, to: now) ?? now
        )
        let hourFrom = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -Self.hourlyWindowDays, to: now) ?? now
        )

        var events: [Event] = []
        for metric in metrics {
            events += try await reader.aggregates(metric: metric, from: dayFrom, to: now, bucket: .day)
            events += try await reader.aggregates(metric: metric, from: hourFrom, to: now, bucket: .hour)
        }

        let result = try store.commit(events: events)
        if result.enqueued > 0 {
            log.info("aggregates: queued \(result.enqueued), unchanged \(result.unchanged)")
        }
        return result.enqueued
    }

    /// Everything at once, for the button and for a background refresh.
    @discardableResult
    public func collectEverythingRecent() async throws -> Int {
        var queued = try await refreshRecentAggregates()
        for metric in SampleMetric.all {
            queued += try await drain(metric: metric)
        }
        if queued > 0 {
            onNewData?()
        }
        return queued
    }

    // MARK: - First export

    public struct BackfillStep: Sendable {
        public let metric: String
        public let reached: Date
    }

    /// Walk the history backwards a month at a time, saving progress as it goes.
    ///
    /// This cannot run in the background: Health can hold years, and a wake-up
    /// gets about thirty seconds. It belongs on screen, with a progress bar, and
    /// it has to survive being interrupted — hence the saved boundary per metric.
    ///
    /// Only daily totals are backfilled. Hourly buckets for five years would be
    /// several hundred thousand events for a resolution nobody asks of last
    /// decade; hourly history therefore begins when the app was installed.
    public func backfill(onStep: @Sendable (BackfillStep) -> Void = { _ in }) async throws {
        for metric in AggregateMetric.all {
            guard let earliest = try await earliestSample(for: metric) else { continue }

            var upperBound = try store.backfillProgress(for: metric.name)
                ?? calendar.startOfDay(for: Date())

            while upperBound > earliest {
                try Task.checkCancellation()

                // Rolling months rather than calendar ones: the boundary only
                // has to move backwards steadily, and this cannot land on a
                // month that does not exist.
                let lowerBound = calendar.date(byAdding: .month, value: -1, to: upperBound) ?? earliest
                let events = try await reader.aggregates(
                    metric: metric, from: max(lowerBound, earliest), to: upperBound, bucket: .day
                )
                try store.commit(events: events)
                try store.recordBackfillProgress(lowerBound, for: metric.name)

                upperBound = lowerBound
                onStep(BackfillStep(metric: metric.name, reached: lowerBound))
            }
        }
        onNewData?()
    }

    private func earliestSample(for metric: AggregateMetric) async throws -> Date? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: metric.type)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
            limit: 1
        )
        return try await descriptor.result(for: healthStore).first?.startDate
    }
}
