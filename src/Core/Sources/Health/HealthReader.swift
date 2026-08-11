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

/// One event with the two things only this layer can work out: the day it
/// belongs to, and — for a record HealthKit can later report as deleted — the
/// identifier it will be named by.
///
/// Both travel alongside the event rather than inside it. They are the device's
/// own bookkeeping and mean nothing to whoever reads the archive.
public struct Reading: Sendable {
    public let event: Event
    public let day: String
    public let identifier: UUID?
}

/// Turns HealthKit into events. Knows nothing about sending or storing.
public struct HealthReader {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    public init(healthStore: HKHealthStore, calendar: Calendar = Day.calendar()) {
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
    /// Buckets with nothing in them are skipped rather than sent as zero. A day
    /// is sent whole, so an absent bucket is unambiguous — nothing happened —
    /// and an hour of zeros every night would be most of the traffic.
    public func aggregates(
        metric: AggregateMetric, from: Date, to: Date, bucket: Bucket
    ) async throws -> [Reading] {
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
        var readings: [Reading] = []

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
            try readings.append(Reading(
                event: Event(
                    id: Self.aggregateID(
                        metric: metric.name, start: statistics.startDate, bucket: bucket
                    ),
                    payload: payload
                ),
                day: Day.of(statistics.startDate, in: calendar),
                identifier: nil
            ))
        }
        return readings
    }

    /// `agg:steps:2026-08-07T09:00:00Z:h` — recomputing the same bucket always
    /// produces the same id, which is what makes re-reading a day cheap.
    static func aggregateID(metric: String, start: Date, bucket: Bucket) -> String {
        "agg:\(metric):\(iso.string(from: start)):\(bucket.rawValue)"
    }

    // MARK: - Samples

    /// Every record of `metric` that starts within the interval.
    ///
    /// By start rather than by overlap, and that is a decision worth naming: a
    /// night of sleep that begins before midnight belongs to the evening it
    /// began in. Overlap would put it in two days, and a day that is written
    /// whole cannot hold half a record twice.
    public func samples(metric: SampleMetric, from: Date, to: Date) async throws -> [Reading] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [
                .sample(
                    type: metric.type,
                    predicate: HKQuery.predicateForSamples(
                        withStart: from, end: to, options: .strictStartDate
                    )
                ),
            ],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        return try await descriptor.result(for: healthStore).map { sample in
            try Reading(
                event: Event(
                    id: Self.sampleID(metric: metric.name, uuid: sample.uuid),
                    payload: metric.encode(sample)
                ),
                day: Day.of(sample.startDate, in: calendar),
                identifier: sample.uuid
            )
        }
    }

    /// What changed for `metric` since `anchor`, as days rather than as data.
    ///
    /// The events themselves are thrown away here on purpose. A change is only
    /// ever a reason to rebuild the day it happened in; the day is then read
    /// from Health in full, which is what makes the upload the truth rather than
    /// a running total of differences that has to stay correct forever.
    ///
    /// Deletions come back as bare identifiers — no date — so their days are not
    /// in here. The caller looks those up in what it wrote down earlier.
    public func changedDays(
        metric: SampleMetric, anchor: HKQueryAnchor?
    ) async throws -> (days: Set<String>, removed: [UUID], anchor: HKQueryAnchor) {
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.sample(type: metric.type)],
            anchor: anchor
        )
        let result = try await descriptor.result(for: healthStore)

        var days: Set<String> = []
        for sample in result.addedSamples {
            days.insert(Day.of(sample.startDate, in: calendar))
        }
        return (days, result.deletedObjects.map(\.uuid), result.newAnchor)
    }

    static func sampleID(metric: String, uuid: UUID) -> String {
        "hk:\(metric):\(uuid.uuidString)"
    }

    /// The first day Health has anything at all about, or nil on an empty store.
    ///
    /// It is where the first export stops walking backwards. Asked of the
    /// aggregate types only: a phone whose oldest record is a step count from
    /// 2015 has nothing before that to find.
    public func earliestDay() async throws -> String? {
        var earliest: Date?
        for metric in AggregateMetric.all {
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: metric.type)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                limit: 1
            )
            if let first = try await descriptor.result(for: healthStore).first?.startDate {
                earliest = min(earliest ?? first, first)
            }
        }
        return earliest.map { Day.of($0, in: calendar) }
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
