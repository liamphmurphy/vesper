import CryptoKit
import Foundation
import Security

/// SHA-256 certificate pinning helpers for the Mac companion's self-signed TLS listener.
public enum CompanionTLSPinning {
    /// Returns the lowercase 64-character hex SHA-256 digest of a DER-encoded X.509 certificate.
    public static func fingerprintSHA256(of derData: Data) -> String {
        let digest = SHA256.hash(data: derData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison between a certificate's DER bytes and an expected hex SHA-256 pin.
    public static func matches(derData: Data, expectedHex: String) -> Bool {
        let normalized = expectedHex.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 64 else { return false }
        let actual = fingerprintSHA256(of: derData)
        let a = Array(actual.utf8)
        let b = Array(normalized.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Builds an ephemeral `URLSession` pinned to the given leaf certificate SHA-256 fingerprint.
    public static func makePinnedSession(
        fingerprintSHA256: String,
        timeoutForRequest: TimeInterval = 15,
        timeoutForResource: TimeInterval = 60
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeoutForRequest
        config.timeoutIntervalForResource = timeoutForResource
        let delegate = PinnedTLSSessionDelegate(expectedFingerprintSHA256: fingerprintSHA256)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

/// `URLSessionDelegate` that trusts a server certificate iff its leaf DER SHA-256 matches the
/// fingerprint exchanged during QR pairing. Fails closed for everything else.
public final class PinnedTLSSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let expectedFingerprintSHA256: String

    public init(expectedFingerprintSHA256: String) {
        self.expectedFingerprintSHA256 = expectedFingerprintSHA256.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        if CompanionTLSPinning.matches(derData: der, expectedHex: expectedFingerprintSHA256) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
