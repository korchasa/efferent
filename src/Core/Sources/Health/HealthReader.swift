import Foundation
import HealthKit

/// Time buckets aggregates are cut into.
public enum Bucket: String, Sendable {
    case hour = "h"
    case day = "d"

    var components: DateComponents {
        switch self {
        case .hour: return DateComponents(hour: 1)
        case .day: return DateComponents(day: 1)
        }
    }

    /// A boundary the buckets line up with. Days start where the person's own
    /// calendar starts them, which is not midnight UTC.
    func anchor(before date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        switch self {
        case .day: return startOfDay
        case .hour: return calendar.date(bySetting: .minute, value: 0, of: startOfDay) ?? startOfDay
        }
    }

    var label: String {
        switch self {
        case .hour: return "hour"
        case .day: return "day"
        }
    }
}

/// Turns HealthKit into events. Knows nothing about sending or storing.
public struct HealthReader {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    public init(healthStore: HKHealthStore, calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    public static var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Every type the app asks to read.
    public static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for metric in AggregateMetric.all {
            types.insert(metric.type)
        }
        for metric in SampleMetric.all {
            types.insert(metric.type)
        }
        return types
    }

    public func requestAuthorization() async throws {
        guard Self.isAvailable else { throw HealthError.notAvailableOnThisDevice }
        try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    // MARK: - Aggregates

    /// De-duplicated totals for `metric`, one event per bucket that has data.
    ///
    /// Buckets with nothing in them are skipped rather than sent as zero. The
    /// receiver already knows how far the stream has got from the sequence
    /// number, so a gap is unambiguous, and an hour of zeros every night would
    /// be most of the traffic.
    public func aggregates(
        metric: AggregateMetric, from: Date, to: Date, bucket: Bucket
    ) async throws -> [Event] {
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(
                type: metric.type,
                predicate: HKQuery.predicateForSamples(withStart: from, end: to)
            ),
            options: .cumulativeSum,
            anchorDate: bucket.anchor(before: from, calendar: calendar),
            intervalComponents: bucket.components
        )

        let collection = try await descriptor.result(for: healthStore)
        var events: [Event] = []

        for statistics in collection.statistics() {
            guard statistics.startDate >= from, statistics.startDate < to else { continue }
            guard let sum = statistics.sumQuantity() else { continue }

            let payload = try Event.payload(AggregatePayload(
                metric: metric.name,
                bucket: bucket.label,
                start: statistics.startDate,
                end: statistics.endDate,
                value: sum.doubleValue(for: metric.unit),
                unit: metric.unit.unitString
            ))
            try events.append(Event(
                id: Self.aggregateID(metric: metric.name, start: statistics.startDate, bucket: bucket),
                kind: .aggregate,
                payload: payload
            ))
        }
        return events
    }

    /// `agg:steps:2026-08-07T09:00:00Z:h` — recomputing the same bucket always
    /// produces the same id, which is what makes the daily re-scan free.
    static func aggregateID(metric: String, start: Date, bucket: Bucket) -> String {
        "agg:\(metric):\(iso.string(from: start)):\(bucket.rawValue)"
    }

    // MARK: - Samples

    public struct SampleBatch {
        public let events: [Event]
        public let anchor: HKQueryAnchor
    }

    /// Everything added or removed for `metric` since `anchor`.
    ///
    /// Deletions matter as much as additions: a person who removes a mistaken
    /// workout expects it gone everywhere, and without these events the server
    /// would keep it for good. A deletion reuses the id of the sample it
    /// removes, so the receiver needs no lookup table to know what to drop.
    public func samples(
        metric: SampleMetric, anchor: HKQueryAnchor?, limit: Int = HKObjectQueryNoLimit
    ) async throws -> SampleBatch {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: metric.type)],
            anchor: anchor,
            limit: limit == HKObjectQueryNoLimit ? nil : limit
        )
        let result = try await descriptor.result(for: healthStore)

        var events: [Event] = []
        for sample in result.addedSamples {
            try events.append(Event(
                id: Self.sampleID(metric: metric.name, uuid: sample.uuid),
                kind: .sample,
                payload: metric.encode(sample)
            ))
        }
        for deleted in result.deletedObjects {
            try events.append(Event(
                id: Self.sampleID(metric: metric.name, uuid: deleted.uuid),
                kind: .deletion,
                payload: Event.payload(DeletionPayload(metric: metric.name))
            ))
        }
        return SampleBatch(events: events, anchor: result.newAnchor)
    }

    static func sampleID(metric: String, uuid: UUID) -> String {
        "hk:\(metric):\(uuid.uuidString)"
    }
}

/// One formatter, created once: `ISO8601DateFormatter` is expensive to build and
/// these ids are produced thousands at a time during the first export.
let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

// MARK: - Anchor archiving

extension HKQueryAnchor {
    static func decode(_ data: Data) throws -> HKQueryAnchor? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func encoded() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: true)
    }
}
