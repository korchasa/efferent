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

    func testPhoneBuildsTheThreeFieldConnectionHandoff() throws {
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example.com")),
            readingPublicKey: Self.readingPublicKey
        )
        let deployment = try Deployment(
            serviceURL: destination.endpoint,
            mcpBaseURL: XCTUnwrap(URL(string: "https://efferent.example.com/mcp/b"))
        )
        let handoff = ConnectionHandoff(
            deployment: deployment,
            destination: destination,
            privateKey: Data(repeating: 7, count: 32)
        )

        XCTAssertEqual(
            handoff.mcpURL.absoluteString,
            "https://efferent.example.com/mcp/b/\(Self.expectedBucket)"
        )
        XCTAssertTrue(handoff.readingKey.hasPrefix("efferent-reading-v1."))
        XCTAssertTrue(handoff.text.contains("call setup_guide first"))
        XCTAssertFalse(handoff.text.contains("Prompt:"))
        XCTAssertTrue(handoff.text.contains("MCP:\n\(handoff.mcpURL.absoluteString)"))
        XCTAssertTrue(handoff.text.contains("Reading key:\n\(handoff.readingKey)"))
        XCTAssertFalse(handoff.mcpURL.absoluteString.contains(handoff.readingKey))
    }

    func testThePhoneFollowsTheAddressItsBuildCarries() throws {
        let stored = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example.workers.dev")),
            readingPublicKey: Self.readingPublicKey
        )
        let deployment = try Deployment(
            serviceURL: XCTUnwrap(URL(string: "https://efferent.example.com")),
            mcpBaseURL: XCTUnwrap(URL(string: "https://efferent.example.com/mcp/b"))
        )

        let moved = try stored.following(deployment)

        XCTAssertEqual(moved.endpoint, deployment.serviceURL)
        // The archive is named by the key, so moving the service moves the
        // archive with it. A bucket that changed here would leave a decade of
        // days behind under a name nothing would ever ask for again.
        XCTAssertEqual(moved.bucket, stored.bucket)
        XCTAssertEqual(moved.readingPublicKey, stored.readingPublicKey)
    }

    func testAPhoneAlreadyOnTheBuildsAddressIsLeftAlone() throws {
        let deployment = try Deployment(
            serviceURL: XCTUnwrap(URL(string: "https://efferent.example.com")),
            mcpBaseURL: XCTUnwrap(URL(string: "https://efferent.example.com/mcp/b"))
        )
        let stored = try Destination(
            endpoint: deployment.serviceURL,
            readingPublicKey: Self.readingPublicKey
        )

        XCTAssertEqual(try stored.following(deployment), stored)
    }

    func testARefusalRepeatsOnlyWhatTheServiceItselfSaid() {
        let said = ConnectionError.refusal(
            status: 403,
            body: Data(#"{"error":"signature does not match the request"}"#.utf8)
        )
        XCTAssertEqual(
            said, .server(status: 403, message: "signature does not match the request")
        )
    }

    func testAPageInPlaceOfAnAnswerNeverBecomesTheMessage() {
        // The screen draws the message as one unbounded run of text, so a page
        // from whatever stands in front of the service becomes the whole app.
        let page = "<!DOCTYPE html><html><svg>" + String(repeating: "x", count: 20000) + "</svg>"
        guard case let .server(status, message) = ConnectionError.refusal(
            status: 404, body: Data(page.utf8)
        ) else { return XCTFail("a refusal is a server error") }
        XCTAssertEqual(status, 404)
        XCTAssertFalse(message.contains("<"))
        XCTAssertLessThan(message.count, 100)
    }

    func testArchiveCreationIsAnEmptySignedRequest() throws {
        let account = "writer-test-\(UUID().uuidString)"
        let identity = DeviceIdentity(service: "dev.korchasa.efferent.tests", account: account)
        defer { try? identity.forget() }
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example.com")),
            readingPublicKey: Self.readingPublicKey
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let request = try ArchiveCreator.request(
            destination: destination, identity: identity, now: date
        )

        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url, destination.bucketURL)
        XCTAssertEqual(request.httpBody, Data())
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-efferent-timestamp"), "1700000000")
        let signature = try Base64URL.decode(XCTUnwrap(
            request.value(forHTTPHeaderField: "x-efferent-signature")
        ))
        let key = try identity.signingKey()
        XCTAssertTrue(key.publicKey.isValidSignature(
            signature,
            for: CanonicalRequest.bytes(
                bucket: destination.bucket, days: [], timestamp: 1_700_000_000, body: Data()
            )
        ))
    }

    /// The service checks this string byte for byte. A stray separator or a
    /// reordered field here means every upload is refused.
    func testTheCanonicalRequestIsTheOneTheServiceRebuilds() {
        let bytes = CanonicalRequest.bytes(
            bucket: "b", days: ["2026-08-06", "2026-08-07"],
            timestamp: 1_700_000_000, body: Data("x".utf8)
        )

        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(
            Array(lines.prefix(4)),
            ["efferent/v1", "b", "2026-08-06,2026-08-07", "1700000000"]
        )
        // base64url of SHA-256("x"), as the reader computes it.
        XCTAssertEqual(lines[4], "LXEWQrcmsEQBYnyp-6wy9chTD7GQPMTbAiWHF5IaSIE")
    }

    // MARK: - Batching

    /// The layout the reader parses, spelled out here so a change to it fails
    /// on this side too rather than only in the cross-language check.
    func testAFrameIsDayThenLengthThenBlob() throws {
        let frame = try Batch.pack([
            Batch.SealedDay(day: "2026-08-06", blob: Data([0xAA, 0xBB])),
            Batch.SealedDay(day: "2026-08-07", blob: Data([0xCC])),
        ])

        XCTAssertEqual(frame.count, (10 + 4 + 2) + (10 + 4 + 1))
        XCTAssertEqual(String(decoding: frame[0 ..< 10], as: UTF8.self), "2026-08-06")
        XCTAssertEqual(Array(frame[10 ..< 14]), [0, 0, 0, 2], "the length is four bytes, big-endian")
        XCTAssertEqual(Array(frame[14 ..< 16]), [0xAA, 0xBB])
        XCTAssertEqual(String(decoding: frame[16 ..< 26], as: UTF8.self), "2026-08-07")
        XCTAssertEqual(Array(frame[26 ..< 30]), [0, 0, 0, 1])
        XCTAssertEqual(Array(frame[30 ..< 31]), [0xCC])
    }

    /// The same days have to pack to the same bytes: the body's hash is what
    /// the signature covers, so anything that varied would be unverifiable.
    func testTheSameDaysAlwaysPackToTheSameBytes() throws {
        let days = [
            Batch.SealedDay(day: "2026-08-06", blob: Data([1])),
            Batch.SealedDay(day: "2026-08-07", blob: Data([2, 2])),
        ]

        XCTAssertEqual(try Batch.pack(days), try Batch.pack(days))
    }

    /// Two copies of a day in one request would ask which one wins — a question
    /// with no answer the phone could predict. The frame refuses to pose it.
    func testAFrameRefusesRepeatedOrOutOfOrderDays() {
        let blob = Data([1])

        XCTAssertThrowsError(try Batch.pack([
            Batch.SealedDay(day: "2026-08-07", blob: blob),
            Batch.SealedDay(day: "2026-08-07", blob: blob),
        ])) { error in
            XCTAssertEqual(
                error as? Batch.BatchError, .outOfOrder(previous: "2026-08-07", next: "2026-08-07")
            )
        }
        XCTAssertThrowsError(try Batch.pack([
            Batch.SealedDay(day: "2026-08-07", blob: blob),
            Batch.SealedDay(day: "2026-08-06", blob: blob),
        ]))
        XCTAssertThrowsError(try Batch.pack([Batch.SealedDay(day: "2026-02-31", blob: blob)]))
        XCTAssertThrowsError(try Batch.pack([]))
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

    func testTheHPKELayoutIsVersionEncapsulatedKeyThenCiphertext() throws {
        let plaintext = Data("0123456789".utf8)

        let blob = try SealedBox.seal(
            readingPublicKey: Self.readingPublicKey,
            plaintext: plaintext,
            associatedData: CanonicalRequest.associatedData(bucket: "abc", day: "2026-08-07")
        )

        XCTAssertEqual(blob.first, SealedBox.version)
        // 1 version + 32 encapsulated X25519 key + plaintext + 16 tag.
        XCTAssertEqual(blob.count, 1 + 32 + plaintext.count + 16)
    }
}
