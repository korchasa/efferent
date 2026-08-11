import CryptoKit
import Foundation

/// Where this phone sends, and under what name.
///
/// Both halves of this are public: an address and a reading *public* key. That
/// is what makes pairing a scan of a code shown on a screen rather than the
/// careful transfer of a secret — there is no secret going this way.
public struct Destination: Equatable, Codable, Sendable {
    public let endpoint: URL
    /// The 32 raw bytes of the reader's X25519 public key.
    public let readingPublicKey: Data
    /// Derived, never chosen: the hash of the key above.
    public let bucket: String

    public init(endpoint: URL, readingPublicKey: Data) throws {
        guard readingPublicKey.count == 32 else {
            throw PairingError.malformedKey(bytes: readingPublicKey.count)
        }
        // Refuse a key that is not a point on the curve here, at pairing time,
        // rather than at the first background upload where nobody is watching.
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: readingPublicKey)

        self.endpoint = endpoint
        self.readingPublicKey = readingPublicKey
        bucket = Self.bucket(for: readingPublicKey)
    }

    /// 26 characters of base32 over the hash — 130 bits, far out of reach of
    /// guessing. It is the only thing standing between a stranger and the
    /// ciphertext, so it is never posted anywhere public.
    public static func bucket(for readingPublicKey: Data) -> String {
        let digest = SHA256.hash(data: readingPublicKey)
        return String(Base32.encode(Data(digest)).prefix(26))
    }

    public var bucketURL: URL {
        endpoint.appendingPathComponent("b").appendingPathComponent(bucket)
    }

    /// Where one day is read back.
    public func dayURL(_ day: String) -> URL {
        bucketURL.appendingPathComponent("d").appendingPathComponent(day)
    }

    /// Where days are written, however many of them share the request. Writing
    /// is addressed by the batch and reading by the day because that is what
    /// each side actually asks for: the phone has days to hand over and no
    /// interest in which, a reader wants one date.
    public var daysURL: URL {
        bucketURL.appendingPathComponent("days")
    }

    /// What the archive holds, in counts rather than contents.
    public var statsURL: URL {
        bucketURL.appendingPathComponent("stats")
    }
}

public enum PairingError: Error, Equatable {
    case malformedKey(bytes: Int)
    case notJSON
    case unsupportedVersion(Int)
    case unsupportedScheme(String?)
}

/// The payload behind the code the reader shows.
///
/// `{"v":1,"url":"https://…","pk":"<base64url>"}` — deliberately small enough to
/// scan reliably, and deliberately carrying nothing worth protecting.
public enum Pairing {
    public static func parse(_ scanned: String) throws -> Destination {
        struct Payload: Decodable {
            let v: Int
            let url: URL
            let pk: String
        }

        guard let data = scanned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            throw PairingError.notJSON
        }
        guard payload.v == 1 else { throw PairingError.unsupportedVersion(payload.v) }

        // http is allowed because a reader on the same network is a normal way
        // to run this; the batch is sealed either way, so the scheme decides
        // who can see the metadata, not the readings.
        guard let scheme = payload.url.scheme, scheme == "https" || scheme == "http" else {
            throw PairingError.unsupportedScheme(payload.url.scheme)
        }

        return try Destination(
            endpoint: payload.url,
            readingPublicKey: Base64URL.decode(payload.pk)
        )
    }
}

/// The exact bytes both sides sign.
///
/// Every field the service acts on is in here, the body's hash included. A
/// signature over the headers alone would let anyone swap the payload.
public enum CanonicalRequest {
    public static let protocolName = "efferent/v1"

    /// The days are named as well as hashed, which looks like a belt over
    /// braces since they are inside the body the hash covers. What it buys is
    /// that the service has to prove its own reading of the frame: it verifies
    /// against the days it unpacked, so a parse that came out differently from
    /// what this packed fails there rather than storing a day under a date
    /// nobody meant.
    public static func bytes(
        bucket: String, days: [String], timestamp: Int64, body: Data
    ) -> Data {
        let digest = Data(SHA256.hash(data: body))
        let line = [
            protocolName,
            bucket,
            days.joined(separator: ","),
            String(timestamp),
            Base64URL.encode(digest),
        ].joined(separator: "\n")
        return Data(line.utf8)
    }

    /// What the sealed day is bound to.
    ///
    /// With the bucket and the date inside the tag, a service that cannot read a
    /// day also cannot move it somewhere else or answer one date with another
    /// date's object — the decryption simply stops working.
    public static func associatedData(bucket: String, day: String) -> Data {
        Data("\(protocolName)\n\(bucket)\n\(day)".utf8)
    }
}
