import CryptoKit
@testable import Efferent
import XCTest

/// Half of the cross-language check.
///
/// The phone's sealing and signing have to match `protocol/` byte for byte, and
/// nothing on this side can prove that — Swift agreeing with Swift proves only
/// that Swift is consistent. So this test produces a real batch with the real
/// code path and prints it; `scripts/interop.ts` then opens it with the matching
/// private key and checks the signature. If the two implementations ever drift,
/// that is where it shows.
final class InteropTests: XCTestCase {
    static let bucket = "4kaszsqxorn5h6jpgqq25zomnv"
    static let seqFrom: Int64 = 1
    static let seqTo: Int64 = 2

    func testEmitABatchForTheReaderToOpen() throws {
        let store = try Store.inMemory()
        try store.commit(events: [
            Event(
                id: "agg:steps:2026-08-07T09:00:00Z:h",
                kind: .aggregate,
                payload: Event.payload(AggregatePayload(
                    metric: "steps",
                    bucket: "hour",
                    start: Date(timeIntervalSince1970: 1_754_557_200),
                    end: Date(timeIntervalSince1970: 1_754_560_800),
                    value: 842,
                    unit: "count"
                ))
            ),
            Event(
                id: "hk:sleep:9A2C",
                kind: .deletion,
                payload: Event.payload(DeletionPayload(metric: "sleep"))
            ),
        ])

        let lines = try NDJSON.body(store.pending(limit: 10))
        let associatedData = CanonicalRequest.associatedData(
            bucket: Self.bucket, seqFrom: Self.seqFrom, seqTo: Self.seqTo
        )
        let blob = try SealedBox.seal(
            readingPublicKey: WireTests.readingPublicKey,
            plaintext: Deflate.compress(lines),
            associatedData: associatedData
        )

        // A key made here rather than fetched from the Keychain: the point is
        // the algorithm and the canonical string, not where the key is kept.
        let writer = Curve25519.Signing.PrivateKey()
        let timestamp: Int64 = 1_700_000_000
        let signature = try writer.signature(
            for: CanonicalRequest.bytes(
                bucket: Self.bucket,
                seqFrom: Self.seqFrom,
                seqTo: Self.seqTo,
                timestamp: timestamp,
                body: blob
            )
        )

        // A second signature over the same batch, stamped now. The fixed one
        // above keeps the check reproducible; this one can actually be posted,
        // because a real service refuses anything far from its own clock.
        let liveTimestamp = Int64(Date().timeIntervalSince1970)
        let liveSignature = try writer.signature(
            for: CanonicalRequest.bytes(
                bucket: Self.bucket,
                seqFrom: Self.seqFrom,
                seqTo: Self.seqTo,
                timestamp: liveTimestamp,
                body: blob
            )
        )

        print("EFFERENT_INTEROP_BLOB=\(Base64URL.encode(blob))")
        print("EFFERENT_INTEROP_WRITER=\(Base64URL.encode(writer.publicKey.rawRepresentation))")
        print("EFFERENT_INTEROP_SIGNATURE=\(Base64URL.encode(Data(signature)))")
        print("EFFERENT_INTEROP_TIMESTAMP=\(timestamp)")
        print("EFFERENT_INTEROP_LIVESIGNATURE=\(Base64URL.encode(Data(liveSignature)))")
        print("EFFERENT_INTEROP_LIVETIMESTAMP=\(liveTimestamp)")
    }
}
