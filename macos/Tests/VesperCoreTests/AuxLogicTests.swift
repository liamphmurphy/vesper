import XCTest
@testable import VesperCore

final class AuxLogicTests: XCTestCase {
    // MARK: Global shortcuts

    func testDefaultShortcutBindings() {
        let space = GlobalShortcut.binding(for: defaultQuickCaptureShortcut)
        XCTAssertEqual(space, HotKeyBinding(keyCode: 49, modifiers: GlobalShortcut.option | GlobalShortcut.shift))
        XCTAssertEqual(GlobalShortcut.binding(for: defaultScreenshotShortcut)?.keyCode, 1)
        XCTAssertEqual(GlobalShortcut.binding(for: defaultShowHideShortcut)?.keyCode, 9)
    }

    func testBindingNormalisesAndRejects() {
        XCTAssertEqual(GlobalShortcut.binding(for: "Cmd+Ctrl+k"),
                       HotKeyBinding(keyCode: 40, modifiers: GlobalShortcut.cmd | GlobalShortcut.control))
        XCTAssertEqual(GlobalShortcut.binding(for: "CommandOrControl+F5")?.keyCode, 96)
        XCTAssertNil(GlobalShortcut.binding(for: "Shift+A"))
        XCTAssertNil(GlobalShortcut.binding(for: "A"))
        XCTAssertNil(GlobalShortcut.binding(for: "Alt+F22"))
        XCTAssertNil(GlobalShortcut.binding(for: ""))
    }

    func testRecorderRoundTrips() {
        let acc = GlobalShortcut.accelerator(keyCode: 49, command: false, shift: true, option: true, control: false)
        XCTAssertEqual(acc, "Alt+Shift+Space")
        XCTAssertEqual(GlobalShortcut.binding(for: acc!)?.keyCode, 49)
        XCTAssertNil(GlobalShortcut.accelerator(keyCode: 200, command: true, shift: false, option: false, control: false))
        XCTAssertEqual(Capture.formatAccelerator("Control+Alt+Shift+Command+K"), "⌃⌥⇧⌘K")
        XCTAssertEqual(Capture.systemShortcutConflict("Command+Space"), "Spotlight")
    }

    // MARK: Screenshot, login

    func testScreenshotNameAndArguments() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_924_309) // 2026-11-17 14:05:09 UTC
        XCTAssertEqual(Screenshot.fileName(date, calendar: cal), "Screenshot 2026-11-17 at 14.05.09.png")
        XCTAssertEqual(Screenshot.arguments(file: "/tmp/x.png"), ["-i", "-x", "-t", "png", "/tmp/x.png"])
        XCTAssertNil(Screenshot.arguments(file: "x.png"))
    }

    func testStartHiddenNeedsEverything() {
        var login = NativeSettings.Login()
        login.openAtLogin = true
        XCTAssertTrue(Login.shouldStartHidden(login, trayEnabled: true, launchedAtLogin: true))
        XCTAssertFalse(Login.shouldStartHidden(login, trayEnabled: false, launchedAtLogin: true))
        XCTAssertFalse(Login.shouldStartHidden(login, trayEnabled: true, launchedAtLogin: false))
        login.startHidden = false
        XCTAssertFalse(Login.shouldStartHidden(login, trayEnabled: true, launchedAtLogin: true))
        XCTAssertNil(Login.statusMessage(wanted: false, status: .requiresApproval))
        XCTAssertNotNil(Login.statusMessage(wanted: true, status: .requiresApproval))
        XCTAssertNil(Login.statusMessage(wanted: true, status: .enabled))
    }

    // MARK: Quick Actions

    func testQuickActionBundleContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(QuickActions.isInstalled(in: dir))
        let app = "/Applications/It's Vesper.app"
        let bundles = try QuickActions.install(appPath: app, into: dir)
        XCTAssertEqual(bundles.map(\.lastPathComponent), ["Send to Vesper.workflow", "Send Text to Vesper.workflow"])
        XCTAssertTrue(QuickActions.isInstalled(in: dir))
        let files = try String(contentsOf: dir.appendingPathComponent("Send to Vesper.workflow/Contents/document.wflow"), encoding: .utf8)
        XCTAssertTrue(files.contains("open -a '/Applications/It'\\''s Vesper.app' &quot;$@&quot;"))
        XCTAssertTrue(files.contains("<integer>1</integer>"))
        XCTAssertTrue(files.contains("com.apple.Automator.fileSystemObject"))
        let info = try String(contentsOf: dir.appendingPathComponent("Send Text to Vesper.workflow/Contents/Info.plist"), encoding: .utf8)
        XCTAssertTrue(info.contains("<string>Send Text to Vesper</string>"))
        XCTAssertTrue(info.contains("NSSendTypes"))
        XCTAssertFalse(info.contains("NSSendFileTypes"))
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: dir.appendingPathComponent("Send to Vesper.workflow/Contents/Info.plist")), format: nil
        ) as? [String: Any]
        XCTAssertNotNil(plist?["NSServices"])
        let wflow = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: dir.appendingPathComponent("Send Text to Vesper.workflow/Contents/document.wflow")), format: nil
        ) as? [String: Any]
        let action = ((wflow?["actions"] as? [[String: Any]])?.first?["action"] as? [String: Any])?["ActionParameters"] as? [String: Any]
        XCTAssertEqual(action?["COMMAND_STRING"] as? String, QuickActions.textScript(appPath: app))
        QuickActions.uninstall(from: dir)
        XCTAssertFalse(QuickActions.isInstalled(in: dir))
    }

    func testScriptsQuoteThePath() {
        XCTAssertEqual(QuickActions.filesScript(appPath: "/A/It's.app"), "open -a '/A/It'\\''s.app' \"$@\"\n")
        XCTAssertTrue(QuickActions.textScript(appPath: "/A.app").contains("open -a '/A.app' \"$f\""))
        XCTAssertEqual(QuickActions.appBundlePath(executablePath: "/Applications/Vesper.app/Contents/MacOS/Vesper"), "/Applications/Vesper.app")
        XCTAssertNil(QuickActions.appBundlePath(executablePath: "/repo/macos/.build/debug/Vesper"))
    }

    // MARK: Backup import

    func testImportArguments() {
        XCTAssertEqual(BackupImport.inspectArguments(archive: "/a.zip"), ["app-import", "-inspect", "/a.zip"])
        XCTAssertEqual(BackupImport.importArguments(dataDirectory: "/d", archive: "/a.zip", dropSecrets: false), ["app-import", "-data-dir", "/d", "/a.zip"])
        XCTAssertEqual(BackupImport.importArguments(dataDirectory: "/d", archive: "/a.zip", dropSecrets: true), ["app-import", "-data-dir", "/d", "-drop-secrets", "/a.zip"])
    }

    func testImportEnvironment() {
        let base = ["PATH": "/bin", "VESPER_NO_SIGNIN": "1", "SECRETS_KEY": "old"]
        let env = BackupImport.importEnvironment(base: base, postgresBinDir: "/pg/bin", secretsKey: " key \n", dropSecrets: false)
        XCTAssertEqual(env["SECRETS_KEY"], "key")
        XCTAssertEqual(env["VESPER_POSTGRES_BIN_DIR"], "/pg/bin")
        XCTAssertNil(env["VESPER_NO_SIGNIN"])
        XCTAssertEqual(BackupImport.importEnvironment(base: base, postgresBinDir: "/pg", secretsKey: "key", dropSecrets: true)["SECRETS_KEY"], "")
        XCTAssertEqual(BackupImport.inspectEnvironment(base: base, currentKey: nil)["SECRETS_KEY"], "")
    }

    func testCLIErrorExtraction() {
        let out = "noise\n{\"level\":\"ERROR\",\"err\":\"the provided SECRETS_KEY does not match\"}\n"
        XCTAssertEqual(BackupImport.extractCLIError(stdout: out, stderr: "x", fallback: "f"), "the provided SECRETS_KEY does not match")
        XCTAssertEqual(BackupImport.extractCLIError(stdout: "", stderr: " boom \n", fallback: "f"), "boom")
        XCTAssertEqual(BackupImport.extractCLIError(stdout: "", stderr: "", fallback: "f"), "f")
    }

    func testInspectionDecodes() throws {
        let json = #"{"exportedAt":"2026-01-01T00:00:00Z","appVersion":"1.0.0","schemaVersion":42,"tableCount":3,"totalRows":10,"objectCount":2,"secretsKeyFingerprint":"abc","encryptedSecretRows":4,"matchesCurrentKey":false}"#
        let insp = try JSONDecoder().decode(BackupInspection.self, from: Data(json.utf8))
        XCTAssertTrue(insp.hasEncryptedSecrets)
        XCTAssertEqual(insp.schemaVersion, 42)
        let none = try JSONDecoder().decode(BackupInspection.self, from: Data(#"{"exportedAt":"x","appVersion":"","schemaVersion":1,"tableCount":0,"totalRows":0,"objectCount":0,"encryptedSecretRows":0,"matchesCurrentKey":false}"#.utf8))
        XCTAssertFalse(none.hasEncryptedSecrets)
    }

    func testRunningAFakeBinary() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("vesper")
        try "#!/bin/sh\nif [ \"$2\" = \"-inspect\" ]; then echo '{\"exportedAt\":\"x\",\"appVersion\":\"1\",\"schemaVersion\":1,\"tableCount\":0,\"totalRows\":0,\"objectCount\":0,\"encryptedSecretRows\":0,\"matchesCurrentKey\":true}'; exit 0; fi\necho '{\"err\":\"nope\"}' >&2; exit 3\n"
            .write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let insp = try await BackupImport.inspect(vesperBin: bin, archive: "/a.zip", currentKey: nil, environment: [:])
        XCTAssertTrue(insp.matchesCurrentKey)
        do {
            try await BackupImport.run(vesperBin: bin, postgresBinDir: dir, dataDirectory: dir.path, archive: "/a.zip", secretsKey: nil, dropSecrets: true, environment: [:])
            XCTFail("expected a failure")
        } catch let e as BackupImportError {
            XCTAssertEqual(e.message, "nope")
        }
    }

    // MARK: Export

    private func makeClient() -> APIClient { APIClient(baseURL: URL(string: "http://127.0.0.1:1")!, sessionToken: "tok") }

    func testExportWritesPrunesAndLocksDown() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["vesper-export-2026-01-01-0100.zip", "vesper-export-2026-01-02-0100.zip", "notes.txt"] {
            try Data("old".utf8).write(to: dir.appendingPathComponent(n))
        }
        let seen = LockedBox<URLRequest?>(nil)
        let now = Date(timeIntervalSince1970: 1_794_924_309)
        let file = try await BackupExporter.export(client: makeClient(), folder: dir.path, keep: 2, now: now) { request in
            seen.value = request
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Data("zipdata".utf8).write(to: tmp)
            return (tmp, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(file.lastPathComponent, Backups.exportFileName(now))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "zipdata")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(seen.value?.url?.path, "/api/v1/instance/export")
        XCTAssertEqual(seen.value?.value(forHTTPHeaderField: "Cookie"), "vesper_session=tok")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["notes.txt", Backups.exportFileName(now), "vesper-export-2026-01-02-0100.zip"].sorted())
        XCTAssertFalse(left.contains { $0.hasSuffix(".part") })
    }

    func testExportFailureLeavesNothingBehind() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await BackupExporter.export(client: makeClient(), folder: dir.path, keep: 3) { request in
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
                try Data("err".utf8).write(to: tmp)
                return (tmp, HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("expected failure")
        } catch let e as BackupImportError {
            XCTAssertEqual(e.message, "The server answered 500.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        do {
            _ = try await BackupExporter.export(client: makeClient(), folder: "/nonexistent-\(UUID().uuidString)", keep: 3)
            XCTFail("expected failure")
        } catch let e as BackupImportError {
            XCTAssertEqual(e.message, "The export folder isn't a folder.")
        }
    }

    func testAppStateKeepsOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        AppStateFile.update(dataDirectory: dir) { $0["lastVersion"] = "1.2.3" }
        AppStateFile.update(dataDirectory: dir) { $0["lastExportAt"] = 1234.0 }
        let s = AppStateFile.read(dataDirectory: dir)
        XCTAssertEqual(s["lastVersion"] as? String, "1.2.3")
        XCTAssertEqual(AppStateFile.millis(s, "lastExportAt"), 1234)
        XCTAssertNil(AppStateFile.millis(s, "lastVersion"))
    }

    // MARK: Options and updates

    func testCaptureOptionsParse() {
        let id = "11111111-1111-4111-8111-111111111111"
        let personas = CaptureOptions.parsePersonas(Data(#"{"personas":[{"id":"\#(id)","name":"Ada"},{"id":"bad","name":"x"}],"default_persona_id":"\#(id)"}"#.utf8))
        XCTAssertEqual(personas.personas, [PersonaSummary(id: id, name: "Ada")])
        XCTAssertEqual(personas.defaultPersonaId, id)
        let projects = CaptureOptions.parseProjects(Data(#"[{"key":"ABC","name":"A"},{"key":"OLD","name":"O","archived":true},{"key":"bad key","name":"B"}]"#.utf8))
        XCTAssertEqual(projects, [ProjectSummary(key: "ABC", name: "A")])
        let chats = CaptureOptions.parseChats(Data(#"{"chats":[{"id":"\#(id)","title":"Hi"},{"id":"zzz","title":"no"}]}"#.utf8))
        XCTAssertEqual(chats, [ChatSummary(id: id, title: "Hi")])
    }

    func testUpdateCheckUsesFeed() async throws {
        let release = #"{"tag_name":"v2.0.0","name":"Two","html_url":"https://github.com/liamphmurphy/vesper/releases/tag/v2.0.0"}"#
        let seen = LockedBox<URLRequest?>(nil)
        let info = try await UpdateCheck.fetch(feedURL: defaultUpdateFeedURL, currentVersion: "1.0.0") { r in seen.value = r; return Data(release.utf8) }
        XCTAssertEqual(info?.version, "2.0.0")
        XCTAssertEqual(seen.value?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        let same = try await UpdateCheck.fetch(feedURL: defaultUpdateFeedURL, currentVersion: "2.0.0") { _ in Data(release.utf8) }
        XCTAssertNil(same)
        let junk = try await UpdateCheck.fetch(feedURL: defaultUpdateFeedURL, currentVersion: "1.0.0") { _ in Data("nope".utf8) }
        XCTAssertNil(junk)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
