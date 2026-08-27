import CryptoKit
@testable import Efferent
import XCTest

/// Half of the cross-language check.
///
/// The phone's framing, sealing and signing have to match `protocol/` byte for
/// byte, and nothing on this side can prove that — Swift agreeing with Swift
/// proves only that Swift is consistent. So this test produces a real request
/// with the real code path and prints it; `scripts/interop.ts` then unpacks it,
/// opens each day with the matching private key and checks the signature. If
/// the two implementations ever drift, that is where it shows.
///
/// Two days rather than one, because a batch of one would leave the part that
/// carries most of the risk — where one day ends and the next begins — untested
/// across the two languages.
final class InteropTests: XCTestCase {
    static let bucket = "4kaszsqxorn5h6jpgqq25zomnv"
    static let day = "2026-08-07"
    static let secondDay = "2026-08-08"

    func testEmitARequestForTheReaderToOpen() throws {
        let firstDay = try [
            Event(
                id: "agg:steps:2026-08-07T09:00:00Z:h",
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
                payload: Event.payload(SleepPayload(
                    metric: "sleep",
                    start: Date(timeIntervalSince1970: 1_754_517_600),
                    end: Date(timeIntervalSince1970: 1_754_542_800),
                    stage: "asleepCore",
                    source: "Watch"
                ))
            ),
        ]
        let secondDay = try [
            Event(
                id: "agg:steps:2026-08-08T09:00:00Z:h",
                payload: Event.payload(AggregatePayload(
                    metric: "steps",
                    bucket: "hour",
                    start: Date(timeIntervalSince1970: 1_754_643_600),
                    end: Date(timeIntervalSince1970: 1_754_647_200),
                    value: 1201,
                    unit: "count"
                ))
            ),
        ]

        let frame = try Batch.pack([
            Batch.SealedDay(day: Self.day, blob: seal(firstDay, on: Self.day)),
            Batch.SealedDay(day: Self.secondDay, blob: seal(secondDay, on: Self.secondDay)),
        ])

        // A key made here rather than fetched from the Keychain: the point is
        // the algorithm and the canonical string, not where the key is kept.
        let writer = Curve25519.Signing.PrivateKey()
        let days = [Self.day, Self.secondDay]
        let timestamp: Int64 = 1_700_000_000
        let signature = try writer.signature(
            for: CanonicalRequest.bytes(
                bucket: Self.bucket, days: days, timestamp: timestamp, body: frame
            )
        )

        // A second signature over the same request, stamped now. The fixed one
        // above keeps the check reproducible; this one can actually be sent,
        // because a real service refuses anything far from its own clock.
        let liveTimestamp = Int64(Date().timeIntervalSince1970)
        let liveSignature = try writer.signature(
            for: CanonicalRequest.bytes(
                bucket: Self.bucket, days: days, timestamp: liveTimestamp, body: frame
            )
        )

        // The new phone-first connection crosses a second language boundary:
        // CryptoKit's raw private key has to become the PKCS8 key WebCrypto
        // keeps locally, and the two sides must derive the same bucket.
        let phoneReadingKey = Curve25519.KeyAgreement.PrivateKey()
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example")),
            readingPublicKey: phoneReadingKey.publicKey.rawRepresentation
        )
        let deployment = try Deployment(
            serviceURL: destination.endpoint,
            promptURL: XCTUnwrap(URL(string: "https://efferent.example/prompts/connect/v1")),
            mcpBaseURL: XCTUnwrap(URL(string: "https://efferent.example/mcp/b"))
        )
        let handoff = ConnectionHandoff(
            deployment: deployment,
            destination: destination,
            privateKey: phoneReadingKey.rawRepresentation
        )

        print("EFFERENT_INTEROP_FRAME=\(Base64URL.encode(frame))")
        print("EFFERENT_INTEROP_WRITER=\(Base64URL.encode(writer.publicKey.rawRepresentation))")
        print("EFFERENT_INTEROP_SIGNATURE=\(Base64URL.encode(Data(signature)))")
        print("EFFERENT_INTEROP_TIMESTAMP=\(timestamp)")
        print("EFFERENT_INTEROP_LIVESIGNATURE=\(Base64URL.encode(Data(liveSignature)))")
        print("EFFERENT_INTEROP_LIVETIMESTAMP=\(liveTimestamp)")
        print("EFFERENT_INTEROP_HANDOFF=\(Base64URL.encode(Data(handoff.text.utf8)))")
    }

    private func seal(_ events: [Event], on day: String) throws -> Data {
        try SealedBox.seal(
            readingPublicKey: WireTests.readingPublicKey,
            plaintext: Deflate.compress(NDJSON.body(events)),
            associatedData: CanonicalRequest.associatedData(bucket: Self.bucket, day: day)
        )
    }
}
