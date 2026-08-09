import CryptoKit
import Foundation
import Security

/// The key that proves an upload came from this phone.
///
/// Encryption says nothing about authorship. Without a signature, anyone who
/// learned a bucket name could fill it with rubbish — unreadable rubbish, but
/// enough to exhaust the storage and drown the real readings. So the device
/// makes this key once and signs every upload with it; the first upload into an
/// empty bucket claims the bucket, and afterwards only this key is accepted.
///
/// It has nothing to do with reading. It cannot decrypt anything, and the
/// reading key cannot sign — which is the point. Handing an agent the ability to
/// read must never hand it the ability to forge.
public struct DeviceIdentity {
    private let keychain: KeychainItem

    public init(service: String = "dev.korchasa.efferent", account: String = "writer") {
        keychain = KeychainItem(service: service, account: account)
    }

    /// The signing key, made on first use.
    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        if let stored = try keychain.read() {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
        }
        let created = Curve25519.Signing.PrivateKey()
        try keychain.save(created.rawRepresentation)
        return created
    }

    /// Forget the key. The bucket it claimed can never be written to again, so
    /// this belongs behind an explicit disconnect and nowhere else.
    public func forget() throws {
        try keychain.delete()
    }
}

/// One blob of bytes in the Keychain.
///
/// Accessibility is `afterFirstUnlock`, and that is load-bearing. Uploads are
/// started by HealthKit deliveries that arrive while the phone sits locked in a
/// pocket; under `whenUnlocked` the read would return nothing and every
/// background send would fail without ever saying why.
public struct KeychainItem {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func read() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { throw KeychainError.malformedItem }
        return data
    }

    public func save(_ data: Data) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }

        var insert = baseQuery()
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.unexpectedStatus(added) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedItem
}
