import Foundation

/// Several sealed days in one request.
///
/// A day is still the unit of the archive: one object, written whole, replaced
/// whole. This is only about how days travel. The first export is a decade of
/// them, and a request each would be thousands of round trips from a phone that
/// is awake for a couple of seconds at a time — a day is a few kilobytes, so
/// what costs is the request, not what is in it.
///
/// Each day is sealed on its own, with its own date bound into the tag, before
/// it is packed. The service unpacks the frame and stores the blobs exactly as
/// they arrived, so nothing about the archive changes and a reader cannot tell
/// whether a day travelled alone or with thirty others.
///
///     10 bytes  the day, ASCII `YYYY-MM-DD`
///      4 bytes  how long the sealed blob is, big-endian
///      n bytes  the sealed blob
///
/// repeated to the end of the body. There is no count and no header: the body
/// ends where it ends, and anything left over is a truncated frame rather than
/// something to skip.
///
/// Days ascend and never repeat. That is what makes the frame canonical — the
/// same days in the same versions always pack to the same bytes, which the
/// signature over the body depends on — and it removes the one question a batch
/// could otherwise ask: which of two copies of a day wins. There is never a
/// second copy.
///
/// The other half of this lives in `protocol/batch.ts`, and `deno task interop`
/// is what proves the two still write the same bytes.
public enum Batch {
    /// How many days one request may carry: a month. The wire's limit, not this
    /// device's — every day in a batch is a separate write on the far side, and
    /// a Worker gets a limited number of those per request.
    public static let maxDaysPerRequest = 31

    private static let dayBytes = 10
    private static let headerBytes = dayBytes + 4

    public struct SealedDay: Sendable, Equatable {
        public let day: String
        /// Ciphertext, exactly as it will be stored.
        public let blob: Data

        public init(day: String, blob: Data) {
            self.day = day
            self.blob = blob
        }
    }

    public enum BatchError: Error, Equatable {
        case empty
        case tooMany(Int)
        case notADay(String)
        case outOfOrder(previous: String, next: String)
        case emptyBody(String)
    }

    public static func pack(_ days: [SealedDay]) throws -> Data {
        guard !days.isEmpty else { throw BatchError.empty }
        guard days.count <= maxDaysPerRequest else { throw BatchError.tooMany(days.count) }

        let calendar = Day.calendar()
        var previous = ""
        var body = Data()
        body.reserveCapacity(days.reduce(0) { $0 + headerBytes + $1.blob.count })

        for entry in days {
            guard Day.isValid(entry.day, in: calendar) else { throw BatchError.notADay(entry.day) }
            guard entry.day > previous else {
                throw BatchError.outOfOrder(previous: previous, next: entry.day)
            }
            guard !entry.blob.isEmpty else { throw BatchError.emptyBody(entry.day) }
            previous = entry.day

            body.append(contentsOf: Array(entry.day.utf8))
            withUnsafeBytes(of: UInt32(entry.blob.count).bigEndian) { body.append(contentsOf: $0) }
            body.append(entry.blob)
        }
        return body
    }
}
