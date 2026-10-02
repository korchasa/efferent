import CryptoKit
import Foundation

/// The key a read of the archive is signed with.
///
/// Nobody stores it. Its seed is HKDF-SHA256 over the raw private half of the
/// reading key, with an empty salt and the info `efferent/v1 read`, so the
/// phone and every reader that holds the reading key make the same key, and the
/// reading key itself never travels. The phone registers the public half with
/// the service; from then on a read has to be signed with it, and the bucket id
/// alone opens nothing.
///
/// The same derivation as `read_key` in the reader's script, and both are held
/// to one published vector: `ReadKeyTests` here, `ReadKey` in the reader's wire
/// tests.
public enum ReadKey {
    public static let info = Data("efferent/v1 read".utf8)

    public static func derive(
        from reading: Curve25519.KeyAgreement.PrivateKey
    ) throws -> Curve25519.Signing.PrivateKey {
        // An empty salt is the RFC's own default — HMAC pads it to the same
        // block of zeros as thirty-two zero bytes — and it is what the reader's
        // hand-written HKDF passes.
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: reading.rawRepresentation),
            salt: Data(),
            info: info,
            outputByteCount: 32
        )
        return try seed.withUnsafeBytes { bytes in
            try Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes))
        }
    }

    /// The path and query of `url` exactly as a request carries them, which is
    /// what the service reads off its side as `pathname + search`.
    ///
    /// An empty query leaves no question mark behind on either side, so a
    /// listing asked for with no parameters signs the bare path.
    public static func target(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.path
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return path }
        return "\(path)?\(query)"
    }
}

/// Signs reads as the read key, against the service's clock.
///
/// Built for a phone that holds its reading key. A legacy archive that was
/// joined from a reader holds no private half here, never registers a read
/// key, and reads unsigned — the service answers it on the bucket id as it
/// always did.
public struct ReadSigner {
    private let bucket: String
    private let key: () throws -> Curve25519.Signing.PrivateKey
    private let timestamp: () -> Int64

    public init(
        bucket: String,
        key: @escaping () throws -> Curve25519.Signing.PrivateKey,
        timestamp: @escaping () -> Int64
    ) {
        self.bucket = bucket
        self.key = key
        self.timestamp = timestamp
    }

    /// Signed with `readKey`, at the moment the service's clock says as this
    /// phone last learned it. A phone whose clock is wrong would otherwise have
    /// every read refused for being out of time, exactly as its uploads once
    /// were.
    public init(
        destination: Destination,
        readKey: Curve25519.Signing.PrivateKey,
        store: Store,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(
            bucket: destination.bucket,
            key: { readKey },
            timestamp: {
                let offset = (try? store.clockOffset()) ?? 0
                return Int64(now().timeIntervalSince1970 + offset)
            }
        )
    }

    /// A GET of `url`, carrying the three headers that sign it.
    public func request(_ url: URL) throws -> URLRequest {
        let key = try key()
        let timestamp = timestamp()
        let signature = try key.signature(for: CanonicalRequest.read(
            bucket: bucket, target: ReadKey.target(of: url), timestamp: timestamp
        ))
        var request = URLRequest(url: url)
        request.setValue(String(timestamp), forHTTPHeaderField: "x-efferent-timestamp")
        request.setValue(
            Base64URL.encode(key.publicKey.rawRepresentation), forHTTPHeaderField: "x-efferent-reader"
        )
        request.setValue(Base64URL.encode(Data(signature)), forHTTPHeaderField: "x-efferent-signature")
        return request
    }
}
