import CryptoKit
import Foundation

/// Sealing a batch for a reader who is not here.
///
/// The phone holds only the reading public key, so it can write into the bucket
/// and cannot read it back. That is a feature, not a limitation: a lost or
/// seized phone gives up nothing about the history it already sent. Every batch
/// takes a throwaway key pair whose private half disappears with the function
/// call, so there is no long-lived key on the device worth stealing.
///
/// This must stay byte-compatible with `protocol/sealedbox.ts`. The pieces are
/// X25519, HKDF-SHA256 and AES-256-GCM, which both CryptoKit and WebCrypto
/// already have — no library is vendored on either side.
public enum SealedBox {
    public static let version: UInt8 = 1

    private static let info = Data("efferent/v1 sealed box".utf8)

    /// `[version][ephemeral public key][nonce][ciphertext and tag]`.
    ///
    /// The version leads so that changing algorithm later is a decision the
    /// reader makes, rather than a decode that fails in a puzzling way.
    public static func seal(
        readingPublicKey: Data, plaintext: Data, associatedData: Data
    ) throws -> Data {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: readingPublicKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation

        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        // Both public keys go into the salt, so a key agreed for one reader can
        // never be reused against another.
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPublic + readingPublicKey,
            sharedInfo: info,
            outputByteCount: 32
        )

        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: associatedData)

        var blob = Data([version])
        blob.append(ephemeralPublic)
        blob.append(Data(nonce))
        blob.append(box.ciphertext)
        blob.append(box.tag)
        return blob
    }
}
