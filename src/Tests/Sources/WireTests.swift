import CryptoKit
@testable import Efferent
import XCTest

final class WireTests: XCTestCase {
    /// The fixed reading key the cross-language check uses. A test key with no
    /// value: its private half sits in `scripts/interop.ts`, in the open.
    static let readingPublicKey = Base64URL.decode("YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w")
    static let expectedBucket = "4kaszsqxorn5h6jpgqq25zomnv"

    func testBase32MatchesTheReferenceEncoding() {
        XCTAssertEqual(Base32.encode(Data("foobar".utf8)), "mzxw6ytboi")
    }

    /// Swift and the reader must land on the same bucket from the same key, or
    /// the phone would write somewhere nobody is looking.
    func testTheBucketNameMatchesTheOneTheReaderComputes() {
        XCTAssertEqual(Destination.bucket(for: Self.readingPublicKey), Self.expectedBucket)
    }

    func testPairingReadsTheCodeTheReaderShows() throws {
        let code = #"{"v":1,"url":"https://efferent.example.com","pk":"YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w"}"#

        let destination = try Pairing.parse(code)

        XCTAssertEqual(destination.bucket, Self.expectedBucket)
        XCTAssertEqual(destination.endpoint.host(), "efferent.example.com")
        XCTAssertEqual(
            destination.dayURL("2026-08-07").absoluteString,
            "https://efferent.example.com/b/\(Self.expectedBucket)/d/2026-08-07"
        )
    }

    func testPairingRefusesAKeyOfTheWrongLength() {
        let code = #"{"v":1,"url":"https://example.com","pk":"AAAA"}"#

        XCTAssertThrowsError(try Pairing.parse(code)) { error in
            XCTAssertEqual(error as? PairingError, .malformedKey(bytes: 3))
        }
    }

    func testPairingRefusesAVersionItDoesNotKnow() {
        let code = #"{"v":2,"url":"https://example.com","pk":"YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w"}"#

        XCTAssertThrowsError(try Pairing.parse(code)) { error in
            XCTAssertEqual(error as? PairingError, .unsupportedVersion(2))
        }
    }

    func testPairingRefusesAnythingThatIsNotAnHTTPAddress() {
        let code = #"{"v":1,"url":"ftp://example.com","pk":"YAvPaXBsGTnyrLF6FcE1oI2EjHmIeKAg07zRX51nI2w"}"#

        XCTAssertThrowsError(try Pairing.parse(code)) { error in
            XCTAssertEqual(error as? PairingError, .unsupportedScheme("ftp"))
        }
    }

    /// The service checks this string byte for byte. A stray separator or a
    /// reordered field here means every upload is refused.
    func testTheCanonicalRequestIsTheOneTheServiceRebuilds() {
        let bytes = CanonicalRequest.bytes(
            bucket: "b", day: "2026-08-07", timestamp: 1_700_000_000, body: Data("x".utf8)
        )

        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(Array(lines.prefix(4)), ["efferent/v1", "b", "2026-08-07", "1700000000"])
        // base64url of SHA-256("x"), as the reader computes it.
        XCTAssertEqual(lines[4], "LXEWQrcmsEQBYnyp-6wy9chTD7GQPMTbAiWHF5IaSIE")
    }

    func testAssociatedDataBindsTheBucketAndTheDay() {
        let data = CanonicalRequest.associatedData(bucket: "abc", day: "2026-08-07")

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "efferent/v1\nabc\n2026-08-07")
    }

    func testDeflateActuallyShrinksABatch() throws {
        let lines = (0 ..< 200)
            .map { #"{"id":"agg:steps:\#($0):h","v":1,"metric":"steps","bucket":"hour"}"# }
            .joined(separator: "\n")
        let original = Data(lines.utf8)

        let packed = try Deflate.compress(original)

        XCTAssertLessThan(packed.count, original.count / 5)
    }

    /// Sealing twice must never repeat. A day is rewritten whenever it changes,
    /// so a service that saw identical bytes would learn that a day went up
    /// again unchanged — and it has no business knowing even that.
    func testSealingTheSameDayTwiceGivesDifferentBytes() throws {
        let aad = CanonicalRequest.associatedData(bucket: "abc", day: "2026-08-07")

        let first = try SealedBox.seal(
            readingPublicKey: Self.readingPublicKey, plaintext: Data("same".utf8), associatedData: aad
        )
        let second = try SealedBox.seal(
            readingPublicKey: Self.readingPublicKey, plaintext: Data("same".utf8), associatedData: aad
        )

        XCTAssertNotEqual(first, second)
    }

    func testTheSealedLayoutIsVersionKeyNonceThenCiphertext() throws {
        let plaintext = Data("0123456789".utf8)

        let blob = try SealedBox.seal(
            readingPublicKey: Self.readingPublicKey,
            plaintext: plaintext,
            associatedData: CanonicalRequest.associatedData(bucket: "abc", day: "2026-08-07")
        )

        XCTAssertEqual(blob.first, SealedBox.version)
        // 1 version + 32 ephemeral key + 12 nonce + plaintext + 16 tag
        XCTAssertEqual(blob.count, 1 + 32 + 12 + plaintext.count + 16)
    }
}
