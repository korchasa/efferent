import CryptoKit
@testable import Efferent
import XCTest

/// The other half of the cross-language check, in the other direction.
///
/// `InteropTests` has the phone seal and sign a request for the reader to
/// open. Writing goes the opposite way: the reader seals and signs an edit
/// that the phone has to open, and nothing on this side can prove that the
/// two agree — Swift opening what Swift sealed proves only that Swift is
/// consistent. So `scripts/interop.ts` seals and signs an edit with the
/// TypeScript side, hands it over in the environment, and this test takes it
/// through exactly the checks `Applier` makes: the editor signature over the
/// canonical message, the box with the bucket in its tag, and the items.
///
/// The fixture arrives base64url-encoded in `EFFERENT_EDIT_FIXTURE`, which
/// `xcodebuild` passes through from `TEST_RUNNER_EFFERENT_EDIT_FIXTURE`. Its
/// keys are made for that one run and never written anywhere. Without it the
/// test is skipped, so the ordinary suite is not tied to the script.
final class EditInteropTests: XCTestCase {
    private struct Fixture: Decodable {
        let bucket: String
        /// The raw X25519 private half the edit was sealed to.
        let readingPrivate: String
        let editor: String
        let timestamp: Int64
        let signature: String
        let sealed: String
    }

    func testOpenAnEditTheReaderSealed() throws {
        guard let encoded = ProcessInfo.processInfo.environment["EFFERENT_EDIT_FIXTURE"] else {
            throw XCTSkip("no edit fixture in the environment; `deno task interop` provides one")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Base64URL.decode(encoded))
        let sealed = Base64URL.decode(fixture.sealed)
        let editor = Base64URL.decode(fixture.editor)

        // What the service checked and what the phone checks again: the editor
        // signed these very bytes, for this bucket, at that time.
        let message = CanonicalRequest.edit(bucket: fixture.bucket, timestamp: fixture.timestamp, sealed: sealed)
        XCTAssertTrue(
            EditorSignature.verify(publicKey: editor, signature: Base64URL.decode(fixture.signature), message: message),
            "the phone could not verify a signature the reader made"
        )
        XCTAssertFalse(
            EditorSignature.verify(
                publicKey: editor,
                signature: Base64URL.decode(fixture.signature),
                message: CanonicalRequest.edit(bucket: fixture.bucket, timestamp: fixture.timestamp + 1, sealed: sealed)
            ),
            "a signature verified over another time — the timestamp is not in the canonical message"
        )

        // The box is bound to the bucket; the same bytes under another one must not open.
        let reading = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Base64URL.decode(fixture.readingPrivate))
        XCTAssertThrowsError(try SealedBox.open(
            readingPrivateKey: reading,
            blob: sealed,
            associatedData: CanonicalRequest.associatedData(editBucket: "other")
        ), "an edit opened under another bucket — the bucket is not bound into the tag")
        let plaintext = try SealedBox.open(
            readingPrivateKey: reading,
            blob: sealed,
            associatedData: CanonicalRequest.associatedData(editBucket: fixture.bucket)
        )

        let items = try EditBatch.unpack(plaintext)
        XCTAssertFalse(items.isEmpty)
        let metrics = items.map { item -> String in
            switch item {
            case let .put(put): return put.metric
            case .delete: return "delete"
            }
        }
        print("EFFERENT_INTEROP_EDIT_ITEMS=\(items.count)")
        print("EFFERENT_INTEROP_EDIT_IDS=\(items.map(\.id).joined(separator: ","))")
        print("EFFERENT_INTEROP_EDIT_METRICS=\(metrics.joined(separator: ","))")
    }
}
