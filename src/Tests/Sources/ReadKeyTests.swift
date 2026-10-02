import CryptoKit
@testable import Efferent
import XCTest

/// The read key, which nobody stores: the phone and every reader make it from
/// the reading key, so the derivation is the contract. These are the vectors
/// the reader's own wire tests hold its script to.
final class ReadKeyTests: XCTestCase {
    /// Bytes 0x01 through 0x20 — a reading key made up for the vector, guarding
    /// nothing.
    static let readingPrivate = Data(Array(UInt8(1) ... UInt8(32)))
    static let bucket = "abucketidmadeupforthistest"
    static let target = "/b/abucketidmadeupforthistest/d?from=2026-08-01&to=2026-08-31"

    private func readKey() throws -> Curve25519.Signing.PrivateKey {
        try ReadKey.derive(from: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.readingPrivate))
    }

    func testTheReadKeyMatchesThePublishedVector() throws {
        let key = try readKey()
        XCTAssertEqual(
            key.rawRepresentation.hex, "39e7d153a3e583b4036f36b661bf06e3714d6c29d969c347d2bbe45e6bdc87be"
        )
        XCTAssertEqual(
            key.publicKey.rawRepresentation.hex,
            "434172a1e4cbfe85eb1097bdc785a22e5a293a0c05ddee75ff146822f9ee53b5"
        )
    }

    /// CryptoKit signs with fresh randomness, so the phone cannot reproduce the
    /// reader's signature byte for byte. What it can do is accept it: the same
    /// key and the same canonical string, or the service would refuse one of
    /// the two.
    func testTheReadersSignatureVerifiesAgainstTheKeyThePhoneMakes() throws {
        let message = CanonicalRequest.read(bucket: Self.bucket, target: Self.target, timestamp: 1_700_000_000)
        XCTAssertEqual(
            String(decoding: message, as: UTF8.self),
            "efferent/v1 read\nabucketidmadeupforthistest\n"
                + "/b/abucketidmadeupforthistest/d?from=2026-08-01&to=2026-08-31\n1700000000"
        )
        let fromPython = Data(hex: "babf8af472d036155a4cbb7bb5385cb0dc360aa18e27c825660609b5d28937f9"
            + "502366c466fbfb9fc724e8d0d3615e47f77b6f9fe62c312b80f3a8267d037900")
        XCTAssertTrue(try readKey().publicKey.isValidSignature(fromPython, for: message))
        XCTAssertFalse(
            try readKey().publicKey.isValidSignature(
                fromPython,
                for: CanonicalRequest.read(bucket: Self.bucket, target: Self.target, timestamp: 1_700_000_001)
            ),
            "the moment is not in the signed string"
        )
    }

    func testTheTargetIsThePathAndQueryAsSent() throws {
        XCTAssertEqual(
            try ReadKey.target(of: XCTUnwrap(URL(string: "https://efferent.example\(Self.target)"))),
            Self.target
        )
        // An empty query leaves no question mark, on the service's side as well.
        XCTAssertEqual(
            try ReadKey.target(of: XCTUnwrap(URL(string: "https://efferent.example/b/x/days?"))),
            "/b/x/days"
        )
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example")),
            readingPublicKey: WireTests.readingPublicKey
        )
        XCTAssertEqual(
            ReadKey.target(of: destination.editsURL(after: "1757228400000-abcdefgh", limit: 200)),
            "/b/\(destination.bucket)/edits?limit=200&after=1757228400000-abcdefgh"
        )
    }

    func testASignedReadCarriesTheReadKeyAndASignatureOverItsOwnTarget() throws {
        let key = try readKey()
        let signer = ReadSigner(bucket: Self.bucket, key: { key }, timestamp: { 1_700_000_000 })
        let url = try XCTUnwrap(URL(string: "https://efferent.example\(Self.target)"))

        let request = try signer.request(url)

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-efferent-timestamp"), "1700000000")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-efferent-reader"), Base64URL.encode(key.publicKey.rawRepresentation)
        )
        let signature = try Base64URL.decode(XCTUnwrap(request.value(forHTTPHeaderField: "x-efferent-signature")))
        XCTAssertTrue(key.publicKey.isValidSignature(
            signature, for: CanonicalRequest.read(bucket: Self.bucket, target: Self.target, timestamp: 1_700_000_000)
        ))
        XCTAssertFalse(
            key.publicKey.isValidSignature(
                signature,
                for: CanonicalRequest.read(
                    bucket: Self.bucket, target: "/b/\(Self.bucket)/d?from=2026-01-01&to=2026-12-31",
                    timestamp: 1_700_000_000
                )
            ),
            "a signature for one range opened another"
        )
    }

    /// The phone's reads go out on the service's clock, the same correction
    /// its uploads already use: a phone whose clock is wrong would otherwise
    /// have every read refused once its read key is registered.
    func testASignedReadIsStampedWithTheServicesClock() throws {
        let store = try Store.inMemory()
        try store.recordClockOffset(-3600)
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example")),
            readingPublicKey: WireTests.readingPublicKey
        )
        let signer = try ReadSigner(
            destination: destination, readKey: readKey(), store: store,
            now: { Date(timeIntervalSince1970: 1_700_003_600) }
        )

        let request = try signer.request(destination.statsURL)

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-efferent-timestamp"), "1700000000")
    }

    /// The phone names the read key to the service with the writer key, over
    /// the registration message, so only the owner of the bucket can say who
    /// reads it.
    func testRegisteringTheReadKeyIsAWriterSignedPutOfItsPublicHalf() throws {
        let destination = try Destination(
            endpoint: XCTUnwrap(URL(string: "https://efferent.example.com")),
            readingPublicKey: WireTests.readingPublicKey
        )
        let identity = DeviceIdentity(account: "reader-registration-test")
        defer { try? identity.forget() }
        let reader = try readKey().publicKey.rawRepresentation
        let request = try ArchiveCreator.readerRequest(
            destination: destination,
            identity: identity,
            readerPublicKey: reader,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(request.url, destination.readerURL)
        XCTAssertEqual(request.url?.path, "/b/\(destination.bucket)/reader")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.httpBody, reader)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-efferent-timestamp"), "1700000000")
        let writer = try identity.signingKey()
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-efferent-writer"),
            Base64URL.encode(writer.publicKey.rawRepresentation)
        )
        let signature = try Base64URL.decode(XCTUnwrap(request.value(forHTTPHeaderField: "x-efferent-signature")))
        XCTAssertTrue(writer.publicKey.isValidSignature(
            signature,
            for: CanonicalRequest.readerRegistration(
                bucket: destination.bucket, timestamp: 1_700_000_000, body: reader
            )
        ))
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
