import XCTest
@testable import VesperCore

/// Starts the real bundled stack. Opt-in: `VESPER_STACK_IT=1 swift test --filter StackIntegrationTests`.
/// Needs `macos/staged` populated (bin/vesper rebuilt with the sign-in-code change, postgres, web).
@MainActor
final class StackIntegrationTests: XCTestCase {
    func testStartSignInInboxStop() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VESPER_STACK_IT"] == "1", "set VESPER_STACK_IT=1 to run")

        // <repo>/macos/Tests/VesperCoreTests/StackIntegrationTests.swift
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = repo.appendingPathComponent("macos/staged", isDirectory: true)
        let dataDir = URL(fileURLWithPath: "/tmp").appendingPathComponent("vesper-it-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        var env = ProcessInfo.processInfo.environment
        env["VESPER_RESOURCES_DIR"] = resources.path
        env["VESPER_APP_DISABLE_RUNNER"] = "1"
        let testKey = Data((0..<32).map { UInt8($0 &* 7 &+ 1) }).base64EncodedString()
        let port = 18_000 + Int.random(in: 0..<1_000)
        let stack = StackController(
            dataDirectory: dataDir,
            options: StackOptions(port: port, secretsKey: { testKey }, environment: env, startupTimeout: .seconds(60))
        )

        await stack.start()
        let failure = stack.startError ?? ""
        let session = try XCTUnwrap(stack.session, "stack didn't sign in: \(stack.health.title) / \(failure)\n\(stack.recentLogTail(maxBytes: 4000))")
        XCTAssertEqual(session.baseURL.port, port)
        XCTAssertFalse(session.sessionToken.isEmpty)
        XCTAssertTrue(stack.isProcessRunning)

        var request = URLRequest(url: session.baseURL.appendingPathComponent("api/v1/inbox"))
        request.setValue("\(StackSession.cookieName)=\(session.sessionToken)", forHTTPHeaderField: "Cookie")
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        // The same call through the app's client, and a health poll.
        let inbox: [String: APIValue] = try await XCTUnwrap(stack.makeAPIClient()).get("/api/v1/inbox")
        XCTAssertNotNil(inbox["items"] ?? .null)
        await stack.pollOnce()

        // The sign-in code never reaches the log.
        let log = stack.recentLogTail()
        XCTAssertFalse(log.contains("VESPER_SIGN_IN_CODE"))

        await stack.stop()
        XCTAssertFalse(stack.isProcessRunning)
        XCTAssertNil(stack.session)
        XCTAssertEqual(stack.health.phase, .stopped)
    }
}
