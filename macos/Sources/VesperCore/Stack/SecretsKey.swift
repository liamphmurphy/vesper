import CommonCrypto
import Foundation
import Security

// The secrets key (SECRETS_KEY for `vesper app`): 32 random bytes, base64. The Electron app kept it
// in `<dataDir>/secrets-key.enc`, encrypted with Chromium's safeStorage ("v10": AES-128-CBC). This
// app keeps it in its own Keychain item and migrates the old file once. Never log the key.

public enum SecretsKeyError: Error, Equatable, CustomStringConvertible {
    case keychain(OSStatus)
    case invalidFormat
    case decryptFailed
    case randomFailed

    public var description: String {
        switch self {
        case .keychain(let status): return "Keychain key unavailable (OSStatus \(status))."
        case .invalidFormat: return "SECRETS_KEY must be a 32-byte base64 string."
        case .decryptFailed: return "The old safeStorage secrets key couldn't be decrypted."
        case .randomFailed: return "Couldn't generate a secrets key."
        }
    }
}

/// A generic-password Keychain. Tests inject a fake and never touch the real Keychain.
public protocol KeychainStore: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
}

public struct SystemKeychain: KeychainStore {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretsKeyError.keychain(status) }
        return item as? Data
    }

    public func write(service: String, account: String, data: Data) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretsKeyError.keychain(status) }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecretsKeyError.keychain(addStatus) }
    }
}

/// Chromium os_crypt "v10" decryption (what Electron's safeStorage wrote on macOS).
public enum SafeStorageCrypto {
    static let salt = Array("saltysalt".utf8)
    static let iv = [UInt8](repeating: 0x20, count: 16)
    static let iterations: UInt32 = 1003

    /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1003 iterations, 16 bytes).
    public static func deriveKey(password: Data) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let pw = password.map { Int8(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations, &key, key.count
        )
        return Data(key)
    }

    /// Strips the "v10" prefix and decrypts AES-128-CBC (IV of 16 spaces, PKCS7). Nil when it isn't v10 or doesn't decrypt.
    public static func decryptV10(_ encrypted: Data, password: Data) -> Data? {
        let prefix = Data("v10".utf8)
        guard encrypted.starts(with: prefix) else { return nil }
        let body = Array(encrypted.dropFirst(prefix.count))
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }
        return crypt(operation: CCOperation(kCCDecrypt), input: body, key: Array(deriveKey(password: password)))
    }

    /// The inverse, for tests (and for completeness): "v10" + AES-128-CBC.
    public static func encryptV10(_ plain: Data, password: Data) -> Data? {
        guard let body = crypt(operation: CCOperation(kCCEncrypt), input: Array(plain), key: Array(deriveKey(password: password))) else { return nil }
        return Data("v10".utf8) + body
    }

    private static func crypt(operation: CCOperation, input: [UInt8], key: [UInt8]) -> Data? {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, input, input.count, &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }
}

public struct SecretsKeyStore: Sendable {
    public static let service = "com.vesper.mac"
    public static let account = "secrets-key"
    /// The Keychain item Chromium's safeStorage keeps its password in, for the Electron app.
    public static let legacyService = "vesper-desktop Safe Storage"
    public static let legacyAccount = "vesper-desktop Key"

    let keychain: KeychainStore
    let dataDirectory: URL

    public init(dataDirectory: URL, keychain: KeychainStore = SystemKeychain()) {
        self.dataDirectory = dataDirectory
        self.keychain = keychain
    }

    /// Throws unless `key` is base64 text that decodes to 32 bytes. Returns it trimmed.
    public static func validate(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z0-9+/=]+\z"#, options: .regularExpression) != nil,
              trimmed.utf16.count % 4 == 0, let decoded = Data(base64Encoded: trimmed), decoded.count == 32
        else { throw SecretsKeyError.invalidFormat }
        return trimmed
    }

    /// The key: our Keychain item, else the Electron file migrated into it, else a new random one.
    public func load() throws -> String {
        if let data = try keychain.read(service: Self.service, account: Self.account),
           let text = String(data: data, encoding: .utf8), let valid = try? Self.validate(text)
        {
            return valid
        }
        if let migrated = try migrateLegacyFile() {
            try keychain.write(service: Self.service, account: Self.account, data: Data(migrated.utf8))
            return migrated
        }
        let fresh = try Self.generate()
        try keychain.write(service: Self.service, account: Self.account, data: Data(fresh.utf8))
        return fresh
    }

    /// Replaces the stored key (after an import brings its own).
    public func save(_ key: String) throws -> String {
        let valid = try Self.validate(key)
        try keychain.write(service: Self.service, account: Self.account, data: Data(valid.utf8))
        return valid
    }

    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SecretsKeyError.randomFailed }
        return Data(bytes).base64EncodedString()
    }

    var legacyFileURL: URL { dataDirectory.appendingPathComponent("secrets-key.enc") }

    /// Decrypts `<dataDir>/secrets-key.enc`, or nil when it doesn't exist. Throws if it exists but
    /// can't be decrypted: generating a new key then would orphan every encrypted secret.
    func migrateLegacyFile() throws -> String? {
        guard let encrypted = try? Data(contentsOf: legacyFileURL) else { return nil }
        guard let password = try keychain.read(service: Self.legacyService, account: Self.legacyAccount),
              let plain = SafeStorageCrypto.decryptV10(encrypted, password: password),
              let text = String(data: plain, encoding: .utf8)
        else { throw SecretsKeyError.decryptFailed }
        return try Self.validate(text)
    }
}
