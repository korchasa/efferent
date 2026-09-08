import CryptoKit
import Foundation

/// Where this phone sends, and under what name.
///
/// Both halves of this are public: an address and the public half of the
/// reading key the phone created. The private half never enters this value.
public struct Destination: Equatable, Codable, Sendable {
    public let endpoint: URL
    /// The 32 raw bytes of the phone's X25519 public key.
    public let readingPublicKey: Data
    /// Derived, never chosen: the hash of the key above.
    public let bucket: String

    public init(endpoint: URL, readingPublicKey: Data) throws {
        guard readingPublicKey.count == 32 else {
            throw DestinationError.malformedKey(bytes: readingPublicKey.count)
        }
        // Refuse a key that is not a point on the curve here, at construction,
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

    /// Where the phone says who may edit.
    public var editorURL: URL {
        bucketURL.appendingPathComponent("editor")
    }

    /// The queue of edits still waiting, or a page of it.
    public func editsURL(after: String? = nil, limit: Int) -> URL {
        var components = URLComponents(
            url: bucketURL.appendingPathComponent("edits"), resolvingAgainstBaseURL: false
        )!
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let after {
            query.append(URLQueryItem(name: "after", value: after))
        }
        components.queryItems = query
        return components.url!
    }

    /// One sealed edit, read with the writer's signature.
    public func editURL(_ name: String) -> URL {
        bucketURL.appendingPathComponent("e").appendingPathComponent(name)
    }

    /// Where the phone says what became of one edit.
    public func outcomeURL(_ name: String) -> URL {
        editURL(name).appendingPathComponent("outcome")
    }

    /// The same archive, at the address this build of the app carries.
    ///
    /// Where to send is deployment configuration; the archive is named by the
    /// reading key, so moving the service moves the archive with it and the
    /// bucket does not change. Without this a phone keeps the address it was
    /// set up with for good: the service left `workers.dev` on 2026-09-05, a
    /// new build changed nothing, and every upload went on to a host that no
    /// longer exists, where Cloudflare answers with a page rather than the
    /// service's own words.
    public func following(_ deployment: Deployment) throws -> Destination {
        guard endpoint != deployment.serviceURL else { return self }
        return try Destination(
            endpoint: deployment.serviceURL,
            readingPublicKey: readingPublicKey
        )
    }
}

public enum DestinationError: Error, Equatable {
    case malformedKey(bytes: Int)
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

    // MARK: - Edits

    /// Each of these names its purpose on its first line, so a captured
    /// message of one kind can never be replayed as another. The same strings
    /// as `canonicalEditorRegistration`, `canonicalEdit`, `canonicalOutcome`
    /// and `canonicalFetch` in `protocol/signing.ts`.
    public static func editorRegistration(bucket: String, timestamp: Int64, body: Data) -> Data {
        canonical(["\(protocolName) editor", bucket, String(timestamp)], body: body)
    }

    public static func edit(bucket: String, timestamp: Int64, sealed: Data) -> Data {
        canonical(["\(protocolName) edit", bucket, String(timestamp)], body: sealed)
    }

    public static func outcome(bucket: String, name: String, timestamp: Int64, body: Data) -> Data {
        canonical(["\(protocolName) outcome", bucket, name, String(timestamp)], body: body)
    }

    /// A fetch has no body, so nothing is hashed: the name is the whole of it.
    public static func fetch(bucket: String, name: String, timestamp: Int64) -> Data {
        Data(["\(protocolName) fetch", bucket, name, String(timestamp)].joined(separator: "\n").utf8)
    }

    /// What a sealed edit is bound to: the bucket alone, because the name is
    /// given by the service after the agent has sealed it.
    public static func associatedData(editBucket bucket: String) -> Data {
        Data("\(protocolName) edit\n\(bucket)".utf8)
    }

    private static func canonical(_ lines: [String], body: Data) -> Data {
        let digest = Data(SHA256.hash(data: body))
        return Data((lines + [Base64URL.encode(digest)]).joined(separator: "\n").utf8)
    }
}
