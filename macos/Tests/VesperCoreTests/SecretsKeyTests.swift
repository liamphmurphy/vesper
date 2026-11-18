import XCTest
@testable import VesperCore

private final class FakeKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var writes: [String] = []
    init(_ items: [String: Data] = [:]) { self.items = items }
    static func id(_ service: String, _ account: String) -> String { "\(service)|\(account)" }
    func read(service: String, account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[Self.id(service, account)]
    }
    func write(service: String, account: String, data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[Self.id(service, account)] = data
        writes.append(Self.id(service, account))
    }
}

final class SecretsKeyTests: XCTestCase {
    private let knownKey = Data((0..<32).map { UInt8($0) }).base64EncodedString()
    private let password = Data("kQp0mY2Qx8vC5nAbc1dEfg==".utf8)

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testPBKDF2KeyIsDeterministic16Bytes() {
        let k = SafeStorageCrypto.deriveKey(password: password)
        XCTAssertEqual(k.count, 16)
        XCTAssertEqual(k, SafeStorageCrypto.deriveKey(password: password))
        XCTAssertNotEqual(k, SafeStorageCrypto.deriveKey(password: Data("other".utf8)))
        // RFC-independent check: PBKDF2-HMAC-SHA1("peanuts", "saltysalt", 1003, 16) is Chromium's well-known macOS key shape.
        XCTAssertEqual(SafeStorageCrypto.deriveKey(password: Data("peanuts".utf8)).count, 16)
    }

    func testV10RoundTripAndFormat() throws {
        let enc = try XCTUnwrap(SafeStorageCrypto.encryptV10(Data(knownKey.utf8), password: password))
        XCTAssertEqual(String(decoding: enc.prefix(3), as: UTF8.self), "v10")
        XCTAssertEqual((enc.count - 3) % 16, 0)
        XCTAssertEqual(SafeStorageCrypto.decryptV10(enc, password: password), Data(knownKey.utf8))
        XCTAssertNil(SafeStorageCrypto.decryptV10(enc, password: Data("wrong password".utf8)) .flatMap { $0 == Data(knownKey.utf8) ? $0 : nil })
        XCTAssertNil(SafeStorageCrypto.decryptV10(Data("v11abc".utf8), password: password))
        XCTAssertNil(SafeStorageCrypto.decryptV10(Data("v10".utf8) + Data([1, 2, 3]), password: password))
    }

    func testValidate() throws {
        XCTAssertEqual(try SecretsKeyStore.validate("  \(knownKey)\n"), knownKey)
        XCTAssertThrowsError(try SecretsKeyStore.validate("short"))
        XCTAssertThrowsError(try SecretsKeyStore.validate(Data(repeating: 1, count: 16).base64EncodedString()))
        XCTAssertThrowsError(try SecretsKeyStore.validate("not base64!!"))
    }

    func testLoadsExistingKeychainItem() throws {
        let kc = FakeKeychain([FakeKeychain.id(SecretsKeyStore.service, SecretsKeyStore.account): Data(knownKey.utf8)])
        XCTAssertEqual(try SecretsKeyStore(dataDirectory: try tempDir(), keychain: kc).load(), knownKey)
        XCTAssertTrue(kc.writes.isEmpty)
    }

    func testMigratesElectronFileIntoOwnItem() throws {
        let dir = try tempDir()
        let enc = try XCTUnwrap(SafeStorageCrypto.encryptV10(Data(knownKey.utf8), password: password))
        try enc.write(to: dir.appendingPathComponent("secrets-key.enc"))
        let kc = FakeKeychain([FakeKeychain.id(SecretsKeyStore.legacyService, SecretsKeyStore.legacyAccount): password])
        let store = SecretsKeyStore(dataDirectory: dir, keychain: kc)
        XCTAssertEqual(try store.load(), knownKey)
        XCTAssertEqual(kc.writes, [FakeKeychain.id(SecretsKeyStore.service, SecretsKeyStore.account)])
        XCTAssertEqual(try store.load(), knownKey, "second load comes from the new item")
        XCTAssertEqual(kc.writes.count, 1)
    }

    func testUndecryptableLegacyFileFailsInsteadOfOrphaningSecrets() throws {
        let dir = try tempDir()
        try Data("v10garbagegarbagegarbage!!".utf8).write(to: dir.appendingPathComponent("secrets-key.enc"))
        let kc = FakeKeychain([FakeKeychain.id(SecretsKeyStore.legacyService, SecretsKeyStore.legacyAccount): password])
        XCTAssertThrowsError(try SecretsKeyStore(dataDirectory: dir, keychain: kc).load())
        XCTAssertTrue(kc.writes.isEmpty)
    }

    func testGeneratesAndSavesWhenNothingExists() throws {
        let kc = FakeKeychain()
        let store = SecretsKeyStore(dataDirectory: try tempDir(), keychain: kc)
        let key = try store.load()
        XCTAssertEqual(try SecretsKeyStore.validate(key), key)
        XCTAssertEqual(try store.load(), key)
        XCTAssertEqual(kc.writes.count, 1)
    }
}
