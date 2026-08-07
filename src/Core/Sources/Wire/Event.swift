import Foundation

/// Schema version stamped on every line this device emits.
///
/// The receiver reads it before anything else, so an old agent can refuse a
/// format it does not understand instead of quietly parsing nonsense.
public let eventSchemaVersion = 1

/// One thing that happened in Health, in the shape it travels in.
///
/// `id` is derived from the data itself — never from a counter — so the same
/// fact always carries the same id. That is what makes a re-send free: the
/// receiver overwrites a row instead of growing a duplicate, and the device is
/// therefore allowed to be careless and send a batch twice.
public struct Event: Equatable, Sendable {
    /// Stable identity of the fact, e.g. `agg:steps:2026-08-07T09:00Z:h`.
    public let id: String
    public let kind: Kind
    /// The kind-specific fields, already encoded as a canonical JSON object.
    /// Build it with ``payload(_:)`` — hand-rolled bytes will break change
    /// detection in the outbox.
    public let payload: Data

    public enum Kind: String, Sendable {
        /// A bucketed, de-duplicated total: steps per hour, energy per day.
        case aggregate = "health.agg"
        /// A single record kept as-is: a sleep interval, a workout, a heart rate.
        case sample = "health.sample"
        /// A record the person removed from Health.
        case deletion = "health.delete"
    }

    public init(id: String, kind: Kind, payload: Data) throws {
        guard !id.isEmpty else {
            throw EventError.emptyIdentifier
        }
        guard payload.first == UInt8(ascii: "{"), payload.last == UInt8(ascii: "}") else {
            throw EventError.payloadIsNotAnObject(id: id)
        }
        self.id = id
        self.kind = kind
        self.payload = payload
    }

    /// Encode kind-specific fields into a canonical payload.
    ///
    /// Keys come out sorted and dates as ISO-8601, so encoding the same values
    /// twice yields byte-identical output. The outbox compares those bytes to
    /// decide whether anything actually changed, and an unstable encoder would
    /// make every re-scan look like new data.
    public static func payload(_ fields: some Encodable) throws -> Data {
        try canonicalEncoder.encode(fields)
    }
}

public enum EventError: Error, Equatable {
    case emptyIdentifier
    case payloadIsNotAnObject(id: String)
}

private let canonicalEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()
