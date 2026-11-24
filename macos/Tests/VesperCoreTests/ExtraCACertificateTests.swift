import Foundation
import XCTest
@testable import VesperCore

final class ExtraCACertificateTests: XCTestCase {
    // Public self-signed test X.509 certificates (no private keys stored).
    private static let rootDER = Data(base64Encoded: "MIIBkDCCATegAwIBAgIUUIO8lzaegUYLBCy8gGo7+mJslYMwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTVmVzcGVyIFRlc3QgUm9vdCBDQTAeFw0yNjExMjQwMzExMzlaFw0zNjExMjEwMzExMzlaMB4xHDAaBgNVBAMME1Zlc3BlciBUZXN0IFJvb3QgQ0EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS2ARlXFVXkr0hEz6MOutLasgnAuYcbMg53wxu7DZ8oa2dMj4HFNFteR7YjcCyzr3eavp8A6+oVZ3G9adAWe6N2o1MwUTAdBgNVHQ4EFgQUNT7QbnTorSqBATBNRuyCe0DWehAwHwYDVR0jBBgwFoAUNT7QbnTorSqBATBNRuyCe0DWehAwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiASHuYM3a/ogutjsDhLeJ+ucf5Jc7Rhe7IbyCk8FfYhZAIgcI97Ppzl+7+Q51Ztm/m9KWpFAmCBc8Na0ocQ/ycov3k=")!
    private static let intermediateDER = Data(base64Encoded: "MIIBoTCCAUegAwIBAgIUHnuDR6K4HfVHg83LGLXusKCxigAwCgYIKoZIzj0EAwIwJjEkMCIGA1UEAwwbVmVzcGVyIFRlc3QgSW50ZXJtZWRpYXRlIENBMB4XDTI2MTEyNDAzMTEzOVoXDTM2MTEyMTAzMTEzOVowJjEkMCIGA1UEAwwbVmVzcGVyIFRlc3QgSW50ZXJtZWRpYXRlIENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjaiFJLePigIzUaSx3t/85qy0Y20sy8Zm3Vy4Tlr7pwirwUhVkP2io3491eszekKgCLf81ocuO2FtDvZIRs2fBaNTMFEwHQYDVR0OBBYEFLYHTgRsnOh/nCv4tiT6oBniUY5yMB8GA1UdIwQYMBaAFLYHTgRsnOh/nCv4tiT6oBniUY5yMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhANnmUI+irtVKXuNh1RCdklWks7qwDEZlvFTMAYZ76gRIAiBii0Pxt03iING9nLLQZW4VKpBhDzAi5vtGEdeq7wVofw==")!

    private static func pem(_ der: Data, crlf: Bool = false) -> String {
        let nl = crlf ? "\r\n" : "\n"
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            .replacingOccurrences(of: "\n", with: nl)
        return "-----BEGIN CERTIFICATE-----\(nl)\(b64)\(nl)-----END CERTIFICATE-----\(nl)"
    }

    func testAcceptsPEMAndDERCertificates() {
        XCTAssertTrue(ExtraCACertificate.isValidCertificateData(Data(Self.pem(Self.rootDER).utf8)))
        XCTAssertTrue(ExtraCACertificate.isValidCertificateData(Data(Self.pem(Self.rootDER, crlf: true).utf8)))
        let bundle = "# exported from Keychain\n" + Self.pem(Self.rootDER) + "\nsubject=intermediate\n" + Self.pem(Self.intermediateDER)
        XCTAssertTrue(ExtraCACertificate.isValidCertificateData(Data(bundle.utf8)))
        XCTAssertTrue(ExtraCACertificate.isValidCertificateData(Self.rootDER))
        var concatenatedDER = Data()
        concatenatedDER.append(Self.rootDER)
        concatenatedDER.append(Self.intermediateDER)
        XCTAssertTrue(ExtraCACertificate.isValidCertificateData(concatenatedDER))
    }

    func testRejectsPrivateKeysGarbageAndOversizedData() {
        let withKey = Self.pem(Self.rootDER) + "-----BEGIN PRIVATE KEY-----\nZmFrZQ==\n-----END PRIVATE KEY-----\n"
        XCTAssertFalse(ExtraCACertificate.isValidCertificateData(Data(withKey.utf8)))
        let badPEM = "-----BEGIN CERTIFICATE-----\nnot-a-cert\n-----END CERTIFICATE-----\n"
        XCTAssertFalse(ExtraCACertificate.isValidCertificateData(Data(badPEM.utf8)))
        XCTAssertFalse(ExtraCACertificate.isValidCertificateData(Data("plain text".utf8)))
        XCTAssertFalse(ExtraCACertificate.isValidCertificateData(Data()))
        // Valid DER followed by trailing garbage must be rejected.
        var trailingGarbage = Data(Self.rootDER)
        trailingGarbage.append(contentsOf: [0x01, 0x02, 0x03])
        XCTAssertFalse(ExtraCACertificate.isValidCertificateData(trailingGarbage))
        XCTAssertFalse(ExtraCACertificate.isValidCertificateData(Data(repeating: 0, count: ExtraCACertificate.maxFileBytes + 1)))
    }

    func testValidateFileChecksPathAndContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-ca-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cer = dir.appendingPathComponent("zscaler.cer")
        try Self.rootDER.write(to: cer)
        XCTAssertNil(ExtraCACertificate.validateFile(at: cer))

        let bad = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: bad)
        XCTAssertNotNil(ExtraCACertificate.validateFile(at: bad))

        let colonURL = dir.appendingPathComponent("bad:name.pem")
        XCTAssertNotNil(ExtraCACertificate.validateFile(at: colonURL))
    }
}
