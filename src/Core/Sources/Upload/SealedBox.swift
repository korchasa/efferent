import CryptoKit
import Foundation

/// RFC 9180 base-mode HPKE for a reader who is not present.
///
/// The phone holds only the recipient's public key. Every call creates and
/// discards the sender's ephemeral key inside CryptoKit, so the phone cannot
/// open either the new ciphertext or anything it uploaded before. This must
/// stay byte-compatible with `protocol/sealedbox.ts` and the Python reference
/// in the MCP setup guide.
public enum SealedBox {
    public static let version: UInt8 = 2

    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    private static let info = Data("efferent/v2 hpke".utf8)

    /// `[version][32-byte encapsulated key][ciphertext and 16-byte tag]`.
    public static func seal(
        readingPublicKey: Data, plaintext: Data, associatedData: Data
    ) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: readingPublicKey)
        var sender = try HPKE.Sender(recipientKey: recipient, ciphersuite: suite, info: info)
        let ciphertext = try sender.seal(plaintext, authenticating: associatedData)

        var blob = Data([version])
        blob.append(sender.encapsulatedKey)
        blob.append(ciphertext)
        return blob
    }

    public enum OpenError: Error, Equatable {
        case wrongVersion(UInt8?)
        case tooShort
    }

    /// The other direction, for an edit an agent sealed to this phone's
    /// reading key. Only version 2: the phone never wrote version 1 edits and
    /// has no reason to read one.
    public static func open(
        readingPrivateKey: Curve25519.KeyAgreement.PrivateKey, blob: Data, associatedData: Data
    ) throws -> Data {
        guard let first = blob.first else { throw OpenError.wrongVersion(nil) }
        guard first == version else { throw OpenError.wrongVersion(first) }
        // The encapsulated key and at least a tag.
        guard blob.count >= 1 + 32 + 16 else { throw OpenError.tooShort }
        let encapsulated = blob.subdata(in: 1 ..< 33)
        let ciphertext = blob.subdata(in: 33 ..< blob.count)
        var recipient = try HPKE.Recipient(
            privateKey: readingPrivateKey,
            ciphersuite: suite,
            info: info,
            encapsulatedKey: encapsulated
        )
        return try recipient.open(ciphertext, authenticating: associatedData)
    }
}
