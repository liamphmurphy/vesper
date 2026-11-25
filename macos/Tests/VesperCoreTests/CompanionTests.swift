import Foundation
import XCTest
@testable import VesperCore

final class CompanionTests: XCTestCase {
    func testPairingPayloadURIRoundTrip() throws {
        let fp = String(repeating: "a1", count: 32)
        let payload = CompanionPairingPayload(
            v: 1,
            name: "Liam-MBP",
            port: 8443,
            certSHA256: fp,
            code: "vcp_abc123",
            lanHosts: ["192.168.1.42"],
            tailscaleHosts: ["liam-mbp.tailnet.ts.net", "100.64.0.10"],
            bonjourService: "_vesper._tcp"
        )
        let uri = try payload.encodeURI()
        XCTAssertTrue(uri.hasPrefix("vesper-pair://v1?data="))

        let decoded = try CompanionPairingPayload.decode(uri: uri)
        XCTAssertEqual(decoded, payload)
    }

    func testPairingPayloadRejectsInvalidSchemeAndFingerprint() {
        XCTAssertThrowsError(try CompanionPairingPayload.decode(uri: "https://example.com")) { err in
            XCTAssertEqual(err as? CompanionPairingError, .invalidURI)
        }

        let badFP = CompanionPairingPayload(
            v: 1,
            name: "Mac",
            port: 8443,
            certSHA256: "not-a-sha256",
            code: "vcp_abc",
            lanHosts: ["192.168.1.10"],
            tailscaleHosts: []
        )
        if let uri = try? badFP.encodeURI() {
            XCTAssertThrowsError(try CompanionPairingPayload.decode(uri: uri)) { err in
                XCTAssertEqual(err as? CompanionPairingError, .invalidFingerprint)
            }
        }
    }

    func testEndpointResolverPrefersLANAndFailsOverToTailscale() async {
        // 1. Both reachable -> picks LAN first.
        let lanHit = await CompanionEndpointResolver.resolve(
            lanHosts: ["192.168.1.42"],
            tailscaleHosts: ["mac.tailnet.ts.net", "100.64.0.10"],
            port: 8443,
            bonjourLANHosts: ["192.168.1.50"],
            probe: { url in
                url.host == "192.168.1.50" || url.host == "mac.tailnet.ts.net"
            }
        )
        XCTAssertEqual(lanHit?.transport, .lan)
        XCTAssertEqual(lanHit?.url.absoluteString, "https://192.168.1.50:8443")

        // 2. LAN unreachable -> fails over to Tailscale MagicDNS.
        let tsHit = await CompanionEndpointResolver.resolve(
            lanHosts: ["192.168.1.42"],
            tailscaleHosts: ["mac.tailnet.ts.net", "100.64.0.10"],
            port: 8443,
            probe: { url in
                url.host == "mac.tailnet.ts.net"
            }
        )
        XCTAssertEqual(tsHit?.transport, .tailscale)
        XCTAssertEqual(tsHit?.url.absoluteString, "https://mac.tailnet.ts.net:8443")

        // 3. Neither reachable -> returns nil (Mac sleeping / offline).
        let none = await CompanionEndpointResolver.resolve(
            lanHosts: ["192.168.1.42"],
            tailscaleHosts: ["100.64.0.10"],
            port: 8443,
            probe: { _ in false }
        )
        XCTAssertNil(none)
    }

    func testTLSPinningMatchesSHA256() {
        let fakeDER = Data("vesper-test-cert-der".utf8)
        let fp = CompanionTLSPinning.fingerprintSHA256(of: fakeDER)
        XCTAssertEqual(fp.count, 64)
        XCTAssertTrue(CompanionTLSPinning.matches(derData: fakeDER, expectedHex: fp))
        XCTAssertTrue(CompanionTLSPinning.matches(derData: fakeDER, expectedHex: fp.uppercased()))
        XCTAssertFalse(CompanionTLSPinning.matches(derData: Data("other".utf8), expectedHex: fp))
    }

    func testAPIClientBearerAuthorizationHeader() {
        let client = APIClient(baseURL: URL(string: "https://192.168.1.42:8443")!, auth: .bearer("vcd_secret"))
        var req = URLRequest(url: URL(string: "https://192.168.1.42:8443/api/v1/chats")!)
        client.authorize(&req)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer vcd_secret")
        XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"))
    }
}
