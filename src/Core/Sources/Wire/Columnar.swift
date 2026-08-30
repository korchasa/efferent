import Foundation

/// Assembles the body for one day: a single JSON object holding columns.
///
/// The line format this replaced spent more than half of every upload on the
/// HealthKit record id — 58% of the bytes, measured over a decade of real days —
/// and repeated the metric, the unit and the source device on every one of a
/// thousand heartbeats. Here rows that agree on all of that share a series and
/// name it once, times travel as whole seconds counted from the first row, and
/// the id is gone. The same decade comes out at an eighth of the size.
///
/// A day has to encode to the same bytes twice or the whole design falls over:
/// the body is what decides whether a day has changed since it was last sent,
/// and HealthKit does not promise to hand records back in the same order twice.
/// Sorting used to do that by id. With no id left, the order is over the content
/// itself — series by their shared fields, rows by their instants and values —
/// and a test shuffles real days to prove it.
///
/// Two consequences worth stating plainly, because both were found by trying
/// them rather than by reading the code:
///
/// - **Seconds are the resolution.** Instants are stored as whole seconds since
///   1970. The line format said the same thing in ISO-8601 and truncated just as
///   quietly; here it is the shape of the field.
/// - **A field with no column would not travel.** Which is why a column is not a
///   name in a list but a property of ``Event``: adding one to the struct without
///   adding it here does not compile.
public enum Columnar {
    public static func body(_ events: [Event]) throws -> Data {
        var groups: [Key: [Event]] = [:]
        for event in events {
            groups[Key(event), default: []].append(event)
        }

        var series: [Series] = []
        for key in groups.keys.sorted() {
            let rows = groups[key]!.sorted(by: precedes)
            let first = second(rows[0].start)

            var starts: [Int64] = []
            var durations: [Int64] = []
            var previous = first
            for row in rows {
                let moment = second(row.start)
                starts.append(moment - previous)
                previous = moment
                durations.append(second(row.end) - moment)
            }

            series.append(Series(
                k: key.kind.rawValue,
                metric: key.metric,
                bucket: key.bucket,
                unit: key.unit,
                source: key.source,
                t0: first,
                t: starts,
                d: durations,
                value: column(rows, \.value),
                stage: column(rows, \.stage),
                activity: column(rows, \.activity),
                duration: column(rows, \.duration)
            ))
        }

        return try encoder.encode(Document(series: series, v: dayFormatVersion))
    }

    /// Whole seconds since 1970, rounded down, which is where a day's resolution
    /// actually lives. `Date` from HealthKit carries a fraction nobody stores.
    static func second(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// A column, or nothing at all when no row in the series has that field.
    private static func column<T>(
        _ rows: [Event], _ field: KeyPath<Event, T?>
    ) -> [T?]? {
        let values = rows.map { $0[keyPath: field] }
        return values.contains(where: { $0 != nil }) ? values : nil
    }

    /// A total order over a row's content. It replaces sorting by id, so it has
    /// to separate every pair of rows the format keeps apart — two sleep stages
    /// beginning in the same second differ only past the third field.
    private static func precedes(_ left: Event, _ right: Event) -> Bool {
        if left.start != right.start {
            return left.start < right.start
        }
        if left.end != right.end {
            return left.end < right.end
        }
        if left.value != right.value {
            return isBefore(left.value, right.value)
        }
        if left.stage != right.stage {
            return isBefore(left.stage, right.stage)
        }
        if left.activity != right.activity {
            return isBefore(left.activity, right.activity)
        }
        return isBefore(left.duration, right.duration)
    }

    /// Nothing sorts before something, and two of nothing are equal.
    private static func isBefore<T: Comparable>(_ left: T?, _ right: T?) -> Bool {
        switch (left, right) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case let (left?, right?): return left < right
        }
    }

    /// What every row in a series has in common, and therefore says once.
    private struct Key: Hashable, Comparable {
        let kind: Event.Kind
        let metric: String
        let bucket: String?
        let unit: String?
        let source: String?

        init(_ event: Event) {
            kind = event.kind
            metric = event.metric
            bucket = event.bucket
            unit = event.unit
            source = event.source
        }

        static func < (left: Key, right: Key) -> Bool {
            if left.kind != right.kind {
                return left.kind < right.kind
            }
            if left.metric != right.metric {
                return left.metric < right.metric
            }
            if left.bucket != right.bucket {
                return before(left.bucket, right.bucket)
            }
            if left.unit != right.unit {
                return before(left.unit, right.unit)
            }
            return before(left.source, right.source)
        }

        private static func before(_ left: String?, _ right: String?) -> Bool {
            switch (left, right) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (left?, right?): return left < right
            }
        }
    }

    private struct Series: Encodable {
        let k: String
        let metric: String
        let bucket: String?
        let unit: String?
        let source: String?
        let t0: Int64
        let t: [Int64]
        let d: [Int64]
        let value: [Double?]?
        let stage: [String?]?
        let activity: [String?]?
        let duration: [Double?]?
    }

    private struct Document: Encodable {
        let series: [Series]
        let v: Int
    }
}

/// Keys sorted so that the same day always produces the same bytes. Slashes are
/// left alone because a source device name is allowed to hold one and escaping
/// it would only make the day bigger.
private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()
