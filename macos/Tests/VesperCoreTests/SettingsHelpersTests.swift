import XCTest
@testable import VesperCore

final class SettingsHelpersTests: XCTestCase {
    func testMemoryTagsImportAndExportMarkdown() {
        XCTAssertEqual(MemoryUIHelpers.parseTags(" a, #B ,a,,c , #Foo "), ["a", "b", "c", "foo"])
        XCTAssertEqual(MemoryUIHelpers.parseTags((1...20).map { "t\($0)" }.joined(separator: ",")).count, 12)

        let raw = """
        Here is what I remember:
        ```json
        {"memories":[
          {"title":"Uses Nix","summary":"Develops on NixOS","body":"Uses flakes","type":"preference","tags":["nix","#devtools"]},
          {"title":"Retired","summary":"Old","superseded_by":"m2"},
          {"title":"Persona only","summary":"Secret","persona_id":"p1"},
          {"summary":"No explicit title becomes title","type":"UNKNOWN"}
        ]}
        ```
        """
        let parsed = MemoryUIHelpers.parseImport(raw)
        XCTAssertNil(parsed.error)
        XCTAssertEqual(parsed.skipped, 2)
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(parsed.entries[0].title, "Uses Nix")
        XCTAssertEqual(parsed.entries[0].tags, ["nix", "devtools"])
        XCTAssertEqual(parsed.entries[1].type, "other")

        let md = MemoryUIHelpers.exportMarkdown(memories: [
            API.Memory(body: "Body detail", createdAt: "2026-01-01", id: "m1", source: "manual", summary: "Summary", tags: ["a"], title: "Title", type: "fact", updatedAt: "2026-01-02"),
        ], exportedAt: "2026-01-03")
        XCTAssertTrue(md.contains("## Title"))
        XCTAssertTrue(md.contains("- Tags: a"))
    }

    func testPersonaHelpersValidateReposAndColors() {
        XCTAssertEqual(PersonaUIHelpers.parseHex("AABBCC"), "#aabbcc")
        XCTAssertNil(PersonaUIHelpers.parseHex("#xyz123"))

        XCTAssertEqual(PersonaUIHelpers.checkRepoURL("https://github.com/org/repo.git"), .ok("https://github.com/org/repo.git"))
        XCTAssertEqual(PersonaUIHelpers.checkRepoURL("git@github.com:org/repo.git"), .ok("git@github.com:org/repo.git"))
        if case .error(let msg) = PersonaUIHelpers.checkRepoURL("https://token@github.com/org/repo.git") {
            XCTAssertTrue(msg.contains("Credentials"))
        } else {
            XCTFail("expected credential rejection")
        }

        XCTAssertNil(PersonaUIHelpers.contrastWarning(hex: "#ffffff", against: "#18181b"))
        XCTAssertNotNil(PersonaUIHelpers.contrastWarning(hex: "#222222", against: "#18181b"))
    }

    func testAPISecretAndProviderHelpers() {
        XCTAssertEqual(APISecretsHelpers.handleFor(name: "99 Bottles API!"), "s-99-bottles-api")
        XCTAssertEqual(APISecretsHelpers.hostOf("https://API.GitHub.com:443/users"), "api.github.com")
        XCTAssertNil(APISecretsHelpers.hostOf("not a host!"))
        XCTAssertEqual(APISecretsHelpers.splitScopes("read, write\nread profile"), ["read", "write", "profile"])

        // Header: {"alg":"none"}, Payload: {"exp":1893456000} -> base64url eyJleHAiOjE4OTM0NTYwMDB9
        let jwt = "eyJhbGciOiJub25lIn0.eyJleHAiOjE4OTM0NTYwMDB9.sig"
        XCTAssertEqual(APISecretsHelpers.jwtExpiry(jwt), Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertNil(APISecretsHelpers.jwtExpiry("plain-secret"))

        let anthropicOnly = [
            API.SecretInfo(createdAt: "2026-01-01", id: "1", name: "harness:anthropic", updatedAt: "2026-01-01"),
        ]
        let missing = ProviderSecretsHelpers.missingConnections(anthropicOnly)
        XCTAssertEqual(missing.map(\.name), ["harness:openai"])
        XCTAssertEqual(ProviderSecretsHelpers.savedMessage(name: "harness:anthropic"), "harness:anthropic saved. Claude Code is now available.")
    }

    func testOwnerAuthAPIParsesFieldAndRateLimitErrors() async throws {
        let transport: HTTPTransport = { req in
            let url = req.url!
            if url.path == "/api/v1/auth/status" {
                let body = Data(#"{"claimed":true,"password_set":false,"signed_in":true}"#.utf8)
                return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if url.path == "/api/v1/auth/setup" {
                let body = Data(#"{"message":"use 8 to 256 characters","field":"password"}"#.utf8)
                return (body, HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            }
            let body = Data(#"{"message":"That username and password don't match."}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let client = APIClient(baseURL: URL(string: "http://localhost:8080")!, sessionToken: "tok", transport: transport)

        let status = try await OwnerAuthAPI.status(using: client)
        XCTAssertEqual(status, OwnerAuthStatus(claimed: true, passwordSet: false, signedIn: true))

        let setupRes = await OwnerAuthAPI.setup(login: "liam", password: "short", using: client)
        XCTAssertEqual(setupRes, .failure(message: "use 8 to 256 characters", field: .password))

        let loginRes = await OwnerAuthAPI.login(login: "liam", password: "wrong", using: client)
        XCTAssertEqual(loginRes, .failure(message: "That username and password don't match.", field: nil))
    }
}
