import Foundation

/// Schema version stamped on every line this device emits.
///
/// The receiver reads it before anything else, so an old agent can refuse a
/// format it does not understand instead of quietly parsing nonsense.
public let eventSchemaVersion = 1

/// One thing that happened in Health, in the shape it travels in.
///
/// `id` is derived from the data itself — never from a counter — so the same
/// fact always carries the same id whichever day it is read on and however many
/// times. It is what a reader keys by.
///
/// There is no kind on an event any more, and nothing lost by that. A day is
/// sent whole and replaces the day before it, so there is nothing to say about
/// a record being removed: it is simply not in the day the next time. What is
/// left is a total or a reading, and a total is the one that names its bucket.
public struct Event: Equatable, Sendable {
    /// Stable identity of the fact, e.g. `agg:steps:2026-08-07T09:00Z:h`.
    public let id: String
    /// The fields, already encoded as a canonical JSON object. Build it with
    /// ``payload(_:)`` — hand-rolled bytes will break change detection.
    public let payload: Data

    public init(id: String, payload: Data) throws {
        guard !id.isEmpty else {
            throw EventError.emptyIdentifier
        }
        guard payload.first == UInt8(ascii: "{"), payload.last == UInt8(ascii: "}") else {
            throw EventError.payloadIsNotAnObject(id: id)
        }
        self.id = id
        self.payload = payload
    }

    /// Encode the fields into a canonical payload.
    ///
    /// Keys come out sorted and dates as ISO-8601, so encoding the same values
    /// twice yields byte-identical output. A day is only re-sent when its bytes
    /// differ from the ones already up there, and an unstable encoder would make
    /// every re-read look like a change.
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
