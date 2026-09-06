import CryptoKit
import Foundation

/// The reading key pair owned by the phone.
///
/// Its private half is kept in the Keychain. It is exported only when the owner
/// deliberately shares a connection handoff, and it never appears in a URL or
/// in a request to the archive service.
public struct ReadingIdentity {
    private let keychain: KeychainItem

    public init(service: String = "dev.korchasa.efferent", account: String = "reader") {
        keychain = KeychainItem(service: service, account: account)
    }

    public func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let stored = try keychain.read() {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
        }
        let created = Curve25519.KeyAgreement.PrivateKey()
        try keychain.save(created.rawRepresentation)
        return created
    }

    public func existingPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let stored = try keychain.read() else { return nil }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
    }

    public func forget() throws {
        try keychain.delete()
    }
}

/// Public deployment addresses embedded in one build of the app.
public struct Deployment: Equatable, Sendable {
    public let serviceURL: URL
    public let mcpBaseURL: URL

    public init(serviceURL: URL, mcpBaseURL: URL) throws {
        for url in [serviceURL, mcpBaseURL] {
            guard let scheme = url.scheme, scheme == "https" || scheme == "http" else {
                throw ConnectionError.unsupportedScheme(url.scheme)
            }
        }
        self.serviceURL = serviceURL
        self.mcpBaseURL = mcpBaseURL
    }

    public static func load(bundle: Bundle = .main) throws -> Deployment {
        func address(_ key: String) throws -> URL {
            guard let text = bundle.object(forInfoDictionaryKey: key) as? String,
                  let url = URL(string: text), !text.isEmpty
            else {
                throw ConnectionError.missingDeploymentValue(key)
            }
            return url
        }
        return try Deployment(
            serviceURL: address("EfferentServiceURL"),
            mcpBaseURL: address("EfferentMCPBaseURL")
        )
    }
}

/// Everything an unprepared agent receives from the phone.
///
/// `readingKey` is one value but contains both raw X25519 halves. Including the
/// public half lets a local importer prove the secret belongs to the bucket in
/// the MCP URL before it overwrites any local state.
public struct ConnectionHandoff: Equatable, Sendable {
    public static let instruction =
        "Connect the supplied Efferent MCP and call setup_guide first. Keep the reading key local and never pass it to a remote tool."

    public let mcpURL: URL
    public let readingKey: String

    public init(deployment: Deployment, destination: Destination, privateKey: Data) {
        mcpURL = deployment.mcpBaseURL.appendingPathComponent(destination.bucket)
        readingKey = [
            "efferent-reading-v1",
            Base64URL.encode(privateKey),
            Base64URL.encode(destination.readingPublicKey),
        ].joined(separator: ".")
    }

    public var text: String {
        """
        Instruction:
        \(Self.instruction)

        MCP:
        \(mcpURL.absoluteString)

        Reading key:
        \(readingKey)
        """
    }
}

public enum ConnectionError: Error, Equatable {
    case missingDeploymentValue(String)
    case unsupportedScheme(String?)
    case server(status: Int, message: String)

    /// A refusal in words that can go on a screen.
    ///
    /// The service answers a refusal in JSON, and its `error` is one sentence
    /// written to be read. A body of anything else was not written by the
    /// service: an address it no longer answers at is answered by whatever
    /// stands in front of it, with a page. The screen draws this message as one
    /// unbounded run of red text, so such a page becomes the whole app — which
    /// is what a phone showed on 2026-09-06. Only the service's own words get
    /// through; anything else is named by its status alone.
    public static func refusal(status: Int, body: Data) -> ConnectionError {
        struct Said: Decodable { let error: String }
        guard let said = try? JSONDecoder().decode(Said.self, from: body) else {
            return .server(status: status, message: "the answer did not come from the service")
        }
        return .server(status: status, message: String(said.error.prefix(200)))
    }
}

/// Claims the logical archive before there is a day to upload.
public enum ArchiveCreator {
    public static func request(
        destination: Destination,
        identity: DeviceIdentity,
        now: Date = Date()
    ) throws -> URLRequest {
        let body = Data()
        let key = try identity.signingKey()
        let timestamp = Int64(now.timeIntervalSince1970)
        let signature = try key.signature(
            for: CanonicalRequest.bytes(
                bucket: destination.bucket, days: [], timestamp: timestamp, body: body
            )
        )

        var request = URLRequest(url: destination.bucketURL)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(timestamp), forHTTPHeaderField: "x-efferent-timestamp")
        request.setValue(
            Base64URL.encode(key.publicKey.rawRepresentation), forHTTPHeaderField: "x-efferent-writer"
        )
        request.setValue(Base64URL.encode(Data(signature)), forHTTPHeaderField: "x-efferent-signature")
        return request
    }

    public static func create(
        destination: Destination,
        identity: DeviceIdentity,
        session: URLSession = .shared
    ) async throws {
        let (body, response) = try await session.data(for: request(
            destination: destination, identity: identity
        ))
        guard let http = response as? HTTPURLResponse else {
            throw ConnectionError.server(status: 0, message: "the server did not return HTTP")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ConnectionError.refusal(status: http.statusCode, body: body)
        }
    }
}
