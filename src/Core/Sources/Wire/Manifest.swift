import Foundation

/// One event, as much of it as the service is allowed to see.
///
/// Times are whole seconds since 1970 rather than strings: half the bytes, no
/// time zone to get wrong, and directly comparable in the index the service
/// keeps. Both are absent on a deletion, which names an event without
/// describing one.
public struct ManifestEntry: Encodable, Equatable, Sendable {
    public let seq: Int64
    public let type: String
    public let metric: String?
    public let start: Int64?
    public let end: Int64?
}

/// The part of a batch that travels in the clear.
///
/// Everything else in this app exists to keep the service blind, so this is the
/// one deliberate exception and it is worth saying plainly what it costs. The
/// manifest carries, per event, its sequence number, its kind, its metric and
/// the interval it covers — no values, no ids, no sources. That lets the
/// service answer "which batches hold sleep in August" without being able to
/// say how anyone slept, which turns a question about one month from a decade
/// of downloads into a handful of them.
///
/// What it gives away is the shape of a life: when you sleep, when you train,
/// when the watch came off. Numbers stay sealed. That was the trade, made
/// knowingly.
///
/// The manifest sits inside the signed body rather than beside it, so the
/// signature that protects the ciphertext protects it too and nobody without
/// the writing key can rewrite it in flight.
///
/// The layout is `[2][uint32 manifest length][deflated manifest][sealed blob]`,
/// and its twin lives in `protocol/manifest.ts`. A body written before
/// manifests existed begins with the sealed-box version instead, which is how a
/// reader tells the two apart without a flag day.
public enum Manifest {
    public static let framedVersion: UInt8 = 2

    public static func entries(for batch: [PendingEvent]) throws -> [ManifestEntry] {
        try batch.map { event in
            let fields = try JSONSerialization.jsonObject(with: event.payload) as? [String: Any] ?? [:]
            return ManifestEntry(
                seq: event.seq,
                type: event.kind.rawValue,
                metric: fields["metric"] as? String,
                start: instant(fields["start"]),
                end: instant(fields["end"])
            )
        }
    }

    public static func body(entries: [ManifestEntry], sealed: Data) throws -> Data {
        let manifest = try Deflate.compress(JSONEncoder().encode(entries))
        var body = Data([framedVersion])
        var length = UInt32(manifest.count).bigEndian
        withUnsafeBytes(of: &length) { body.append(contentsOf: $0) }
        body.append(manifest)
        body.append(sealed)
        return body
    }

    private static func instant(_ value: Any?) -> Int64? {
        guard let text = value as? String, let date = isoFormatter.date(from: text) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}

/// Matches what ``Event/payload(_:)`` writes: `.iso8601`, no fractional seconds.
private let isoFormatter = ISO8601DateFormatter()
