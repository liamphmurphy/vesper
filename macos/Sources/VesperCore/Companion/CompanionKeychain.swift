import Foundation
import Security

/// Persistence abstraction for the paired Mac's metadata and secret bearer token.
public protocol CompanionCredentialStore: Sendable {
    func loadToken() -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
    func loadHost() -> CompanionPairedHost?
    func saveHost(_ host: CompanionPairedHost) throws
    func deleteHost() throws
}

public enum CompanionKeychainError: Error, Sendable {
    case osStatus(OSStatus)
}

/// Production store: keeps the companion bearer token in the Apple Keychain and non-secret host
/// metadata in `UserDefaults`.
public final class KeychainCompanionStore: CompanionCredentialStore, @unchecked Sendable {
    private let service: String
    private let account: String
    private let hostDefaultsKey: String

    public init(
        service: String = "com.liamphmurphy.vesper.companion",
        account: String = "device-token",
        hostDefaultsKey: String = "vesper.companion.pairedHost"
    ) {
        self.service = service
        self.account = account
        self.hostDefaultsKey = hostDefaultsKey
    }

    public func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveToken(_ token: String) throws {
        try? deleteToken()
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionKeychainError.osStatus(status) }
    }

    public func deleteToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionKeychainError.osStatus(status)
        }
    }

    public func loadHost() -> CompanionPairedHost? {
        guard let data = UserDefaults.standard.data(forKey: hostDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(CompanionPairedHost.self, from: data)
    }

    public func saveHost(_ host: CompanionPairedHost) throws {
        let data = try JSONEncoder().encode(host)
        UserDefaults.standard.set(data, forKey: hostDefaultsKey)
    }

    public func deleteHost() throws {
        UserDefaults.standard.removeObject(forKey: hostDefaultsKey)
    }
}

/// In-memory store for unit tests and SwiftUI previews.
public final class InMemoryCompanionStore: CompanionCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var host: CompanionPairedHost?

    public init(token: String? = nil, host: CompanionPairedHost? = nil) {
        self.token = token
        self.host = host
    }

    public func loadToken() -> String? {
        lock.withLock { token }
    }

    public func saveToken(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    public func deleteToken() throws {
        lock.withLock { self.token = nil }
    }

    public func loadHost() -> CompanionPairedHost? {
        lock.withLock { host }
    }

    public func saveHost(_ host: CompanionPairedHost) throws {
        lock.withLock { self.host = host }
    }

    public func deleteHost() throws {
        lock.withLock { self.host = nil }
    }
}
