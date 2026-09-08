import CryptoKit
@testable import Efferent
import XCTest

/// The Swift half of `protocol/edits.ts` and the edit part of `signing.ts`.
/// The fixtures here are the same bytes `protocol/edits_test.ts` asserts, so
/// a drift on either side fails a test before it fails a phone.
final class EditsTests: XCTestCase {
    static let bucket = "abcdefghijklmnopqrstuvwxyz"
    static let name = "1757228400000-abcdefgh"
    /// base64url(SHA-256("hello")), the digest the TypeScript test pins.
    static let helloDigest = "LPJNul-wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ"

    // MARK: - Canonical messages

    func testEachCanonicalMessageSaysWhatItIsFor() {
        let body = Data("hello".utf8)
        XCTAssertEqual(
            String(decoding: CanonicalRequest.editorRegistration(
                bucket: Self.bucket, timestamp: 1_700_000_000, body: body
            ), as: UTF8.self),
            "efferent/v1 editor\n\(Self.bucket)\n1700000000\n\(Self.helloDigest)"
        )
        XCTAssertEqual(
            String(decoding: CanonicalRequest.edit(
                bucket: Self.bucket, timestamp: 1_700_000_000, sealed: body
            ), as: UTF8.self),
            "efferent/v1 edit\n\(Self.bucket)\n1700000000\n\(Self.helloDigest)"
        )
        XCTAssertEqual(
            String(decoding: CanonicalRequest.outcome(
                bucket: Self.bucket, name: Self.name, timestamp: 1_700_000_000, body: body
            ), as: UTF8.self),
            "efferent/v1 outcome\n\(Self.bucket)\n\(Self.name)\n1700000000\n\(Self.helloDigest)"
        )
        XCTAssertEqual(
            String(decoding: CanonicalRequest.fetch(
                bucket: Self.bucket, name: Self.name, timestamp: 1_700_000_000
            ), as: UTF8.self),
            "efferent/v1 fetch\n\(Self.bucket)\n\(Self.name)\n1700000000"
        )
        XCTAssertEqual(
            String(decoding: CanonicalRequest.associatedData(editBucket: Self.bucket), as: UTF8.self),
            "efferent/v1 edit\n\(Self.bucket)"
        )
    }

    func testAnEditNameIsMillisecondsAndBase32() {
        XCTAssertTrue(EditName.isValid(Self.name))
        XCTAssertFalse(EditName.isValid("1757228400000-ABCDEFGH"))
        XCTAssertFalse(EditName.isValid("175722840000-abcdefgh"))
        XCTAssertFalse(EditName.isValid("1757228400000-abcdefg"))
        XCTAssertFalse(EditName.isValid("../1757228400000-abcdefgh"))
    }

    func testTheEditAddressesHangOffTheBucket() throws {
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example.com")),
            readingPublicKey: WireTests.readingPublicKey
        )
        let bucket = destination.bucket
        XCTAssertEqual(destination.editorURL.absoluteString, "https://efferent.example.com/b/\(bucket)/editor")
        XCTAssertEqual(
            destination.editsURL(limit: 50).absoluteString,
            "https://efferent.example.com/b/\(bucket)/edits?limit=50"
        )
        XCTAssertEqual(
            destination.editsURL(after: Self.name, limit: 50).absoluteString,
            "https://efferent.example.com/b/\(bucket)/edits?limit=50&after=\(Self.name)"
        )
        XCTAssertEqual(
            destination.editURL(Self.name).absoluteString,
            "https://efferent.example.com/b/\(bucket)/e/\(Self.name)"
        )
        XCTAssertEqual(
            destination.outcomeURL(Self.name).absoluteString,
            "https://efferent.example.com/b/\(bucket)/e/\(Self.name)/outcome"
        )
    }

    // MARK: - Deflate both ways

    func testDeflateReadsBackWhatItWrote() throws {
        let text = Data(String(repeating: "meal,meal,meal,", count: 200).utf8)
        let squeezed = try Deflate.compress(text)
        XCTAssertLessThan(squeezed.count, text.count / 4)
        XCTAssertEqual(try Deflate.decompress(squeezed, limit: text.count), text)
    }

    func testDecompressRefusesToInflatePastItsLimit() throws {
        let text = Data(repeating: 0x61, count: 10000)
        let squeezed = try Deflate.compress(text)
        XCTAssertThrowsError(try Deflate.decompress(squeezed, limit: 9999))
    }

    func testDecompressRefusesBytesThatAreNotDeflate() {
        XCTAssertThrowsError(try Deflate.decompress(Data([0xFF, 0xFE, 0xFD, 0x00, 0x01]), limit: 1024))
    }

    // MARK: - Items

    static let batch = """
    {"v":1,"items":[{"op":"put","id":"agent:meal:2026-09-07:breakfast","metric":"dietaryEnergy","start":1757228400,"end":1757229300,"value":520,"unit":"kcal"},{"op":"put","id":"agent:sleep:2026-09-06:core","metric":"sleep","start":1757196000,"end":1757221200,"stage":"asleepCore"},{"op":"delete","id":"agent:meal:2026-09-01:lunch"}]}
    """

    func testABatchUnpacksIntoItsItems() throws {
        let items = try EditBatch.unpack(Deflate.compress(Data(Self.batch.utf8)))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0], .put(EditItem.Put(
            id: "agent:meal:2026-09-07:breakfast",
            metric: "dietaryEnergy",
            start: 1_757_228_400,
            end: 1_757_229_300,
            value: 520,
            unit: "kcal",
            stage: nil
        )))
        XCTAssertEqual(items[1], .put(EditItem.Put(
            id: "agent:sleep:2026-09-06:core",
            metric: "sleep",
            start: 1_757_196_000,
            end: 1_757_221_200,
            value: nil,
            unit: nil,
            stage: "asleepCore"
        )))
        XCTAssertEqual(items[2], .delete(id: "agent:meal:2026-09-01:lunch"))
    }

    func testABatchIsRefusedForEveryWayItCanBeWrong() throws {
        let bad = [
            #"{"v":2,"items":[{"op":"delete","id":"a"}]}"#,
            #"{"v":1,"items":[{"op":"delete","id":"a"}],"extra":true}"#,
            #"{"v":1,"items":[]}"#,
            #"{"v":1,"items":[{"op":"merge","id":"a"}]}"#,
            #"{"v":1,"items":[{"op":"delete","id":"a b"}]}"#,
            #"{"v":1,"items":[{"op":"delete","id":"a","metric":"sleep"}]}"#,
            #"{"v":1,"items":[{"op":"put","id":"a","metric":"sleep","start":5,"end":2,"stage":"awake"}]}"#,
            #"{"v":1,"items":[{"op":"put","id":"a","metric":"sleep","start":1.5,"end":2,"stage":"awake"}]}"#,
            #"{"v":1,"items":[{"op":"put","id":"a","metric":"sleep","start":1,"end":2,"stage":"awake","note":1}]}"#,
            #"[1,2"#,
        ]
        for text in bad {
            XCTAssertThrowsError(try EditBatch.unpack(Deflate.compress(Data(text.utf8))), text)
        }
        let many = (0 ... 500).map { #"{"op":"delete","id":"id-\#($0)"}"# }.joined(separator: ",")
        XCTAssertThrowsError(try EditBatch.unpack(Deflate.compress(Data(#"{"v":1,"items":[\#(many)]}"#.utf8))))
    }

    /// The phone does not know the catalogue here on purpose: the format only
    /// checks shape, and `HealthWriter` decides whether a metric can be written.
    /// So an unknown metric unpacks and is refused later with a code.
    func testAnUnknownMetricUnpacksAndIsRefusedLater() throws {
        let text = #"{"v":1,"items":[{"op":"put","id":"a","metric":"steps","start":1,"end":2,"value":1,"unit":"count"}]}"#
        let items = try EditBatch.unpack(Deflate.compress(Data(text.utf8)))
        XCTAssertEqual(items.count, 1)
    }

    func testAnOutcomeEncodesCountsAndCodesOnly() throws {
        let outcome = Outcome(applied: 2, refused: [.init(item: 1, code: .badRange)])
        let text = try String(decoding: outcome.encoded(), as: UTF8.self)
        XCTAssertEqual(text, #"{"applied":2,"refused":[{"code":"badRange","item":1}]}"#)
    }

    // MARK: - Opening what the agent sealed

    func testThePhoneOpensWhatWasSealedToItsReadingKey() throws {
        let reading = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = try Deflate.compress(Data(Self.batch.utf8))
        let associated = CanonicalRequest.associatedData(editBucket: Self.bucket)
        let sealed = try SealedBox.seal(
            readingPublicKey: reading.publicKey.rawRepresentation,
            plaintext: plaintext,
            associatedData: associated
        )
        XCTAssertEqual(
            try SealedBox.open(readingPrivateKey: reading, blob: sealed, associatedData: associated),
            plaintext
        )
        XCTAssertThrowsError(try SealedBox.open(
            readingPrivateKey: reading,
            blob: sealed,
            associatedData: CanonicalRequest.associatedData(editBucket: "other")
        ))
        XCTAssertThrowsError(try SealedBox.open(
            readingPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            blob: sealed,
            associatedData: associated
        ))
        var wrongVersion = sealed
        wrongVersion[0] = 1
        XCTAssertThrowsError(try SealedBox.open(
            readingPrivateKey: reading, blob: wrongVersion, associatedData: associated
        ))
        XCTAssertThrowsError(try SealedBox.open(
            readingPrivateKey: reading, blob: Data([2, 0, 0]), associatedData: associated
        ))
    }

    /// The phone names its editor to the service with the writer key, over the
    /// registration message, so the service can check the same bytes.
    func testRegisteringTheEditorIsAWriterSignedPutOfTheRawKey() throws {
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example.com")),
            readingPublicKey: WireTests.readingPublicKey
        )
        let identity = DeviceIdentity(account: "editor-registration-test")
        defer { try? identity.forget() }
        let editor = Curve25519.Signing.PrivateKey()
        let request = try ArchiveCreator.editorRequest(
            destination: destination,
            identity: identity,
            editorPublicKey: editor.publicKey.rawRepresentation,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(request.url, destination.editorURL)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.httpBody, editor.publicKey.rawRepresentation)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-efferent-timestamp"), "1700000000")
        let writer = try identity.signingKey()
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-efferent-writer"),
            Base64URL.encode(writer.publicKey.rawRepresentation)
        )
        let signature = try Base64URL.decode(XCTUnwrap(request.value(forHTTPHeaderField: "x-efferent-signature")))
        XCTAssertTrue(writer.publicKey.isValidSignature(
            signature,
            for: CanonicalRequest.editorRegistration(
                bucket: destination.bucket, timestamp: 1_700_000_000, body: editor.publicKey.rawRepresentation
            )
        ))
    }

    func testTheEditorSignatureIsCheckedAgainstTheCanonicalBytes() throws {
        let editor = Curve25519.Signing.PrivateKey()
        let sealed = Data("sealed bytes".utf8)
        let message = CanonicalRequest.edit(bucket: Self.bucket, timestamp: 1_700_000_000, sealed: sealed)
        let signature = try editor.signature(for: message)
        XCTAssertTrue(EditorSignature.verify(
            publicKey: editor.publicKey.rawRepresentation, signature: signature, message: message
        ))
        XCTAssertFalse(EditorSignature.verify(
            publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
            signature: signature,
            message: message
        ))
        XCTAssertFalse(EditorSignature.verify(
            publicKey: editor.publicKey.rawRepresentation, signature: signature, message: message + Data([0])
        ))
        XCTAssertFalse(EditorSignature.verify(
            publicKey: Data(count: 32), signature: Data(count: 64), message: message
        ), "a key of small order")
        XCTAssertFalse(EditorSignature.verify(
            publicKey: editor.publicKey.rawRepresentation, signature: signature.dropLast(), message: message
        ))
    }
}
