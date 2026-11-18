import XCTest
@testable import VesperCore

private let GB: Int64 = 1 << 30

final class StackHealthTests: XCTestCase {
    private func base(_ edit: (inout StackHealthInput) -> Void = { _ in }) -> StackHealthInput {
        var i = StackHealthInput(
            arch: "arm64", darwinMajor: 24, starting: false, processRunning: true, freeDiskBytes: 200 * GB,
            minFreeDiskGb: 10, image: RootfsStatus(state: .ready), runnerOnline: true
        )
        edit(&i)
        return i
    }

    func testHealthyStackIsRunning() {
        let h = StackHealthLogic.derive(base())
        XCTAssertEqual(h.phase, .running)
        XCTAssertEqual(TrayModel.iconState(h.phase), .running)
    }

    func testEachNamedFailureStateHasSpecificTitleAndNextStep() {
        struct Case { var edit: (inout StackHealthInput) -> Void; var title: String; var step: String }
        let cases: [Case] = [
            Case(edit: { $0.arch = "x86_64" }, title: "Virtualization unavailable", step: "Apple Silicon"),
            Case(edit: { $0.darwinMajor = 23 }, title: "Virtualization unavailable", step: "macOS 15"),
            Case(edit: { $0.processRunning = false; $0.startError = "Error Domain=VZErrorDomain Code=2" }, title: "Virtualization unavailable", step: "vz.entitlements"),
            Case(edit: { $0.processRunning = false; $0.startError = "embedded postgres: initdb failed" }, title: "Database didn't start", step: "logs"),
            Case(edit: { $0.processRunning = false; $0.startError = "listen 127.0.0.1:8080: bind: address already in use" }, title: "Port in use", step: "Quit the other program"),
            Case(edit: { $0.processRunning = false; $0.startError = "write: no space left on device" }, title: "Disk full", step: "Free up disk space"),
            Case(edit: { $0.processRunning = false; $0.startError = "macOS Keychain safeStorage encryption is unavailable." }, title: "Keychain key unavailable", step: "keychain"),
            Case(edit: { $0.processRunning = false; $0.startError = "Timed out waiting for vesper app to start." }, title: "Stack is slow to start", step: "Restart"),
            Case(edit: { $0.processRunning = false; $0.exit = StackExitInfo(code: 2, stderrTail: "panic: boom") }, title: "Stack stopped", step: "Restart"),
            Case(edit: { $0.processRunning = false; $0.exit = StackExitInfo(code: 2); $0.freeDiskBytes = 1 * GB }, title: "Disk almost full", step: "Free up"),
            Case(edit: { $0.image = RootfsStatus(state: .error, error: "agent-base.erofs not found locally and VESPER_ROOTFS_URL is not set") }, title: "Run image unavailable", step: "build-images.sh"),
            Case(edit: { $0.image = RootfsStatus(state: .error, error: "download rootfs: HTTP 503") }, title: "Run image unavailable", step: "connection"),
            Case(edit: { $0.freeDiskBytes = 3 * GB }, title: "Disk almost full", step: "Free up"),
            Case(edit: { $0.runnerOnline = false }, title: "Runner offline", step: "Restart"),
        ]
        for c in cases {
            let h = StackHealthLogic.derive(base(c.edit))
            XCTAssertEqual(h.title, c.title)
            XCTAssertNotNil(h.nextStep?.range(of: c.step, options: .caseInsensitive), "\(c.title): \(h.nextStep ?? "nil")")
            XCTAssertTrue(h.phase == .error || h.phase == .degraded)
            XCTAssertEqual(TrayModel.iconState(h.phase), .error)
        }
    }

    func testFirstRunStartingThenDownloadingWithProgress() {
        XCTAssertEqual(StackHealthLogic.derive(base { $0.starting = true; $0.processRunning = false }).phase, .starting)
        let h = StackHealthLogic.derive(base { $0.image = RootfsStatus(state: .downloading, downloadedBytes: GB, totalBytes: 4 * GB) })
        XCTAssertEqual(h.phase, .downloading)
        XCTAssertEqual(h.downloadFraction, 0.25)
        XCTAssertEqual(h.downloadedBytes, GB)
        XCTAssertEqual(h.totalBytes, 4 * GB)
        XCTAssertTrue(h.message.contains("1.0 GB of 4.0 GB"), h.message)
        XCTAssertEqual(TrayModel.iconState(h.phase), .starting)
    }

    func testStoppedWhenNoProcessAndNoError() {
        let h = StackHealthLogic.derive(base { $0.processRunning = false })
        XCTAssertEqual(h.phase, .stopped)
    }

    func testClassifyFallsBackToGenericCrash() {
        XCTAssertEqual(StackHealthLogic.classifyStackError("").title, "Stack stopped")
    }

    func testAutoRestartAllowsThreePerTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }
        XCTAssertTrue(StackHealthLogic.shouldAutoRestart(restartTimes: [], now: now))
        XCTAssertTrue(StackHealthLogic.shouldAutoRestart(restartTimes: [ago(1), ago(2)], now: now))
        XCTAssertFalse(StackHealthLogic.shouldAutoRestart(restartTimes: [ago(1), ago(2), ago(3)], now: now))
        XCTAssertTrue(StackHealthLogic.shouldAutoRestart(restartTimes: [ago(660), ago(720), ago(780)], now: now))
    }

    func testDarwinMajorFormatBytesAndReadLogTail() throws {
        XCTAssertEqual(StackHealthLogic.darwinMajor(release: "24.1.0"), 24)
        XCTAssertNil(StackHealthLogic.darwinMajor(release: "garbage"))
        XCTAssertEqual(StackHealthLogic.formatBytes(1536 * 1024 * 1024), "1.5 GB")
        XCTAssertEqual(StackHealthLogic.formatBytes(5 * 1024 * 1024), "5 MB")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("vesper-app.log")
        XCTAssertEqual(StackHealthLogic.readLogTail(file), "")
        try "line one\nline two\nline three\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(StackHealthLogic.readLogTail(file), "line one\nline two\nline three\n")
        XCTAssertEqual(StackHealthLogic.readLogTail(file, maxBytes: 15), "line three\n", "starts at a line boundary")
    }
}

final class StackLaunchTests: XCTestCase {
    private func resources() -> BundledResources {
        BundledResources(
            baseDir: URL(fileURLWithPath: "/x"), vesperBin: URL(fileURLWithPath: "/x/bin/vesper"),
            postgresBinDir: URL(fileURLWithPath: "/x/postgres/bin"), kernelPath: URL(fileURLWithPath: "/x/images/vmlinux"),
            webDistDir: URL(fileURLWithPath: "/x/web"), nodeBin: URL(fileURLWithPath: "/x/node/bin/node")
        )
    }

    func testArgumentsAndEnvironment() {
        let launch = StackLaunch(
            resources: resources(), dataDirectory: URL(fileURLWithPath: "/data"), secretsKey: "k", port: 8080,
            nodeBin: "/x/node/bin/node", rootfsUrl: "https://github.com/liamphmurphy/vesper/releases/download/v0.2.0/agent-base.erofs",
            runnerSlots: 3
        )
        XCTAssertEqual(launch.arguments, ["app", "-data-dir", "/data", "-addr", "127.0.0.1:8080"])
        let env = launch.environment(base: ["PATH": "/bin", "VESPER_NO_SIGNIN": "1", "VESPER_NODE_RUN_AS_NODE": "1"])
        XCTAssertEqual(env["SECRETS_KEY"], "k")
        XCTAssertEqual(env["VESPER_APP_DATA_DIR"], "/data")
        XCTAssertEqual(env["VESPER_APP_ADDR"], "127.0.0.1:8080")
        XCTAssertEqual(env["VESPER_POSTGRES_BIN_DIR"], "/x/postgres/bin")
        XCTAssertEqual(env["VESPER_KERNEL_PATH"], "/x/images/vmlinux")
        XCTAssertEqual(env["VESPER_WEB_DIST_DIR"], "/x/web")
        XCTAssertEqual(env["VESPER_NODE_BIN"], "/x/node/bin/node")
        XCTAssertEqual(env["VESPER_ROOTFS_URL"], launch.rootfsUrl)
        XCTAssertEqual(env["RUNNER_MAX_CONCURRENT"], "3")
        XCTAssertEqual(env["VESPER_APP_SIGN_IN_CODE"], "stdout")
        XCTAssertNil(env["VESPER_NO_SIGNIN"], "never runs without sign-in")
        XCTAssertNil(env["VESPER_NODE_RUN_AS_NODE"])
        XCTAssertEqual(env["PATH"], "/bin")
    }

    func testEnvironmentVariablesWinOverRootfsAndSlots() {
        let launch = StackLaunch(resources: resources(), dataDirectory: URL(fileURLWithPath: "/data"), secretsKey: "k", rootfsUrl: "https://a/b", runnerSlots: 3)
        let env = launch.environment(base: ["VESPER_ROOTFS_URL": "https://mirror.example/rootfs", "RUNNER_MAX_CONCURRENT": "9"])
        XCTAssertEqual(env["VESPER_ROOTFS_URL"], "https://mirror.example/rootfs")
        XCTAssertEqual(env["RUNNER_MAX_CONCURRENT"], "9")
        let none = StackLaunch(resources: resources(), dataDirectory: URL(fileURLWithPath: "/data"), secretsKey: "k").environment(base: [:])
        XCTAssertNil(none["VESPER_ROOTFS_URL"])
        XCTAssertNil(none["RUNNER_MAX_CONCURRENT"])
    }

    func testResolveBundledResources() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-res-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(BundledResources.resolve(baseDir: dir))
        for p in ["bin/vesper", "postgres/bin/postgres", "images/vmlinux", "web/server.js"] {
            let url = dir.appendingPathComponent(p)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        let r = try XCTUnwrap(BundledResources.resolve(baseDir: dir))
        XCTAssertEqual(r.postgresBinDir.path, dir.appendingPathComponent("postgres/bin").path)
        XCTAssertNotNil(r.kernelPath)
        XCTAssertNotNil(r.webDistDir)
        XCTAssertNil(r.nodeBin)
        XCTAssertEqual(BundledResources.locate(environment: ["VESPER_RESOURCES_DIR": dir.path]), URL(fileURLWithPath: dir.path, isDirectory: true))
        // Without the bundled node, dev falls back to VESPER_NODE_BIN.
        XCTAssertEqual(StackLaunch.resolveNode(resources: r, environment: ["VESPER_NODE_BIN": "/opt/node"]), "/opt/node")
    }

    func testReleaseAssetUrl() {
        XCTAssertEqual(Updates.releaseAssetUrl(version: "0.2.0", assetName: "agent-base.erofs"), "https://github.com/liamphmurphy/vesper/releases/download/v0.2.0/agent-base.erofs")
        XCTAssertEqual(Updates.releaseAssetUrl(version: "v1.0.0-rc.1", assetName: "Vesper-arm64.dmg"), "https://github.com/liamphmurphy/vesper/releases/download/v1.0.0-rc.1/Vesper-arm64.dmg")
        XCTAssertNil(Updates.releaseAssetUrl(version: "dev", assetName: "agent-base.erofs"))
        XCTAssertNil(Updates.releaseAssetUrl(version: "0.2.0", assetName: "../../x"))
        XCTAssertNil(Updates.releaseAssetUrl(version: "0.2.0", assetName: "a?b"))
        XCTAssertNil(Updates.releaseAssetUrl(version: "0.2.0", assetName: "x", repo: "evil.example/../a"))
    }

    func testOutputCollectorKeepsSignInCodeOutOfTheLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-collect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("vesper-app.log")
        let log = StackLogWriter(url: logURL)
        let collector = StackOutputCollector(log: log)
        final class Box: @unchecked Sendable { var url: String? }
        let box = Box()
        collector.onReady = { box.url = $0 }
        collector.process("starting postgres", isStderr: false)
        collector.process("VESPER_SIGN_IN_CODE=s3cr3t", isStderr: false)
        collector.process("VESPER_READY_URL=http://127.0.0.1:8080", isStderr: false)
        collector.process("boom", isStderr: true)
        log.close()
        XCTAssertEqual(box.url, "http://127.0.0.1:8080")
        XCTAssertEqual(collector.takeSignInCode(), "s3cr3t")
        XCTAssertNil(collector.takeSignInCode())
        XCTAssertEqual(collector.stderrTail, "boom\n")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains("s3cr3t"))
        XCTAssertFalse(text.contains("VESPER_SIGN_IN_CODE"))
        XCTAssertTrue(text.contains("starting postgres\n"))
        XCTAssertTrue(text.contains("boom\n"))
    }

    func testSessionCookieParsing() throws {
        let url = URL(string: "http://127.0.0.1:8080/api/v1/sign-in")!
        let response = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: nil,
            headerFields: ["Set-Cookie": "vesper_session=abc123; Path=/; HttpOnly; SameSite=Lax", "Location": "/"]
        )!
        XCTAssertEqual(StackSignIn.sessionToken(from: response), "abc123")
        let none = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "/"])!
        XCTAssertNil(StackSignIn.sessionToken(from: none))
    }

    func testDefaultDataDirectory() {
        XCTAssertEqual(StackController.defaultDataDirectory(environment: ["VESPER_USER_DATA_DIR": "/tmp/vd"]).path, "/tmp/vd")
        XCTAssertTrue(StackController.defaultDataDirectory(environment: [:]).path.hasSuffix("Library/Application Support/vesper-desktop"))
    }

    func testScratchSecretsKeyNeedsAScratchDataDir() {
        XCTAssertNil(StackController.scratchSecretsKey(environment: ["VESPER_SCRATCH_SECRETS_KEY": "k"]))
        XCTAssertNil(StackController.scratchSecretsKey(environment: ["VESPER_USER_DATA_DIR": "/x"]))
        XCTAssertEqual(StackController.scratchSecretsKey(environment: ["VESPER_USER_DATA_DIR": "/x", "VESPER_SCRATCH_SECRETS_KEY": "k"]), "k")
    }
}
