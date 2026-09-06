import CryptoKit
import DeviceCheck
import Foundation

/// Apple's word that a bucket is being claimed by this app, on a real iPhone.
///
/// The service has no accounts, so anybody who knows its address can ask it for
/// a bucket. The archive is safe either way — the first writer keeps the bucket
/// and only their key is accepted afterwards — but a bucket costs storage for
/// years, and nothing except the ceilings stood between a script in a loop and
/// the bill. App Attest is what makes the caller cost a device.
///
/// It is asked for once in the life of an installation, at the claim. Every
/// upload after it is already bound to the bucket by the key the claim
/// registered, so attesting one would prove nothing that is not already proved.
public struct Attestation: Equatable, Sendable {
    /// Apple's attestation object, CBOR, about five kilobytes.
    public let object: Data
    /// The 32 bytes that name the attested key.
    public let keyId: Data

    public init(object: Data, keyId: Data) {
        self.object = object
        self.keyId = keyId
    }
}

public enum AttestationFailure: Error, Equatable {
    /// The simulator has no App Attest, and neither has a Mac. A build running
    /// there cannot claim a bucket, and saying so beats a signature that is
    /// refused for a reason nobody can see.
    case notAvailableOnThisDevice
    case appleRefused(String)
    case malformedKeyIdentifier
}

/// Everything the claim needs from App Attest, so a test can stand in for it.
public protocol Attesting: Sendable {
    var isAvailable: Bool { get }
    func attest(challenge: Data) async throws -> Attestation
}

public struct DeviceAttester: Attesting {
    public init() {}

    public var isAvailable: Bool {
        DCAppAttestService.shared.isSupported
    }

    /// A fresh key, attested over this exact challenge.
    ///
    /// The key is generated here and never kept: it is used once, to be
    /// attested, and the service stores the public half it learns from Apple's
    /// certificate. Keeping it would only invite a second use, and an attested
    /// key can be attested once.
    public func attest(challenge: Data) async throws -> Attestation {
        let service = DCAppAttestService.shared
        guard service.isSupported else { throw AttestationFailure.notAvailableOnThisDevice }
        do {
            let identifier = try await service.generateKey()
            let object = try await service.attestKey(
                identifier, clientDataHash: Data(SHA256.hash(data: challenge))
            )
            guard let keyId = Data(base64Encoded: identifier) else {
                throw AttestationFailure.malformedKeyIdentifier
            }
            return Attestation(object: object, keyId: keyId)
        } catch let failure as AttestationFailure {
            throw failure
        } catch {
            throw AttestationFailure.appleRefused(String(describing: error))
        }
    }
}
