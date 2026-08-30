import Foundation

/// The layout a stored day is written in.
///
/// A reader checks it before anything else, so an old agent can refuse a shape
/// it does not understand instead of quietly parsing nonsense. Version 1 was one
/// JSON object per line, each carrying its own HealthKit record id; version 2 is
/// the columnar day in ``Columnar``.
public let dayFormatVersion = 2

/// The version stamped on each event a reader unpacks out of a day.
///
/// It has not moved and is not expected to: the fields of an event are the same
/// fields they always were. Only the way a day packs them changed.
public let eventSchemaVersion = 1

/// One thing that happened in Health, in the shape it travels in.
///
/// There is no id on it, and that is the point of the second format. A record's
/// identity is its metric and the instant it started, which a reader rebuilds;
/// the HealthKit uuid that used to carry it was more than half of everything
/// this app uploaded and no reader ever looked at it.
///
/// There is no kind on an event either, beyond ``Kind``, and nothing lost by
/// that. A day is sent whole and replaces the day before it, so there is nothing
/// to say about a record being removed: it is simply not in the day the next
/// time. What is left is a total or a reading, and a total is the one that names
/// its bucket.
public struct Event: Equatable, Sendable {
    /// Whether this is a de-duplicated total or a single record.
    public enum Kind: String, Sendable, Comparable {
        case total = "agg"
        case record = "hk"

        public static func < (left: Kind, right: Kind) -> Bool {
            left.rawValue < right.rawValue
        }
    }

    public let kind: Kind
    public let metric: String
    /// Present on a total, absent on a record — the only difference between the
    /// two now that nothing carries a kind of its own.
    public let bucket: String?
    public let start: Date
    public let end: Date
    public let source: String?
    public let unit: String?
    public let value: Double?
    public let stage: String?
    public let activity: String?
    public let duration: Double?

    public init(
        kind: Kind,
        metric: String,
        bucket: String? = nil,
        start: Date,
        end: Date,
        source: String? = nil,
        unit: String? = nil,
        value: Double? = nil,
        stage: String? = nil,
        activity: String? = nil,
        duration: Double? = nil
    ) throws {
        guard !metric.isEmpty else { throw EventError.emptyMetric }
        self.kind = kind
        self.metric = metric
        self.bucket = bucket
        self.start = start
        self.end = end
        self.source = source
        self.unit = unit
        self.value = value
        self.stage = stage
        self.activity = activity
        self.duration = duration
    }
}

public enum EventError: Error, Equatable {
    case emptyMetric
}
