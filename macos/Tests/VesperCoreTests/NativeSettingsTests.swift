import XCTest
@testable import VesperCore

final class NativeSettingsTests: XCTestCase {
    func testDefaultsKeepPreExistingBehaviourAndLeaveOutwardReachingFeaturesOff() {
        let d = NativeSettings.defaults()
        XCTAssertTrue(d.tray.enabled)
        XCTAssertEqual(d.tray.onLastWindowClose, .dock)
        XCTAssertFalse(d.login.openAtLogin)
        XCTAssertFalse(d.quickCapture.enabled)
        XCTAssertFalse(d.touchId.enabled)
        XCTAssertFalse(d.updates.checkEnabled)
        XCTAssertEqual(d.power.onSleep, .keep)
        XCTAssertTrue(d.power.confirmQuitWithActiveRuns)
        for kind in NotificationKind.all { XCTAssertEqual(d.notifications.kinds[kind], true, kind) }
        XCTAssertEqual(d.quickCapture.shortcut, "Alt+Shift+Space")
        XCTAssertEqual(d.screenshot, NativeSettings.Shortcut(shortcut: "Alt+Shift+S"))
        XCTAssertEqual(d.showHide, NativeSettings.Shortcut(shortcut: "Alt+Shift+V"))
        XCTAssertTrue(d.dock.menu && d.dock.progress)
        XCTAssertTrue(d.backups.excludeFromTimeMachine)
        XCTAssertFalse(d.backups.export.enabled)
        XCTAssertTrue(d.power.easeOffWhenHot)
        XCTAssertEqual(d.workspaces.editor.kind, .terminal)
        XCTAssertEqual(d.workspaces.editor.command, "nvim")
        XCTAssertEqual(d.workspaces.editor.app, "Visual Studio Code")
    }

    func testNormalizeRepairsHostileOrPartialInputFieldByField() {
        let raw: [String: Any] = [
            "tray": ["enabled": "yes", "onLastWindowClose": "menuBar"],
            "notifications": [
                "kinds": ["approval": false, "bogus": false],
                "quietHours": ["enabled": true, "start": "25:00", "end": "07:30"],
            ],
            "quickCapture": ["shortcut": "   "],
            "power": ["onSleep": "hibernate"],
            "stack": ["minFreeDiskGb": -5],
            "updates": ["feedUrl": "http://evil.example/latest"],
        ]
        let n = NativeSettings.normalize(raw)
        XCTAssertTrue(n.tray.enabled, "non-boolean falls back to default")
        XCTAssertEqual(n.tray.onLastWindowClose, .menuBar)
        XCTAssertEqual(NativeSettings.normalize(["tray": ["onLastWindowClose": "vanish"]]).tray.onLastWindowClose, .dock)
        XCTAssertEqual(n.notifications.kinds["approval"], false)
        XCTAssertNil(n.notifications.kinds["bogus"])
        XCTAssertTrue(n.notifications.quietHours.enabled)
        XCTAssertEqual(n.notifications.quietHours.start, "22:00")
        XCTAssertEqual(n.notifications.quietHours.end, "07:30")
        XCTAssertEqual(n.quickCapture.shortcut, "Alt+Shift+Space")
        XCTAssertEqual(n.power.onSleep, .keep)
        XCTAssertEqual(n.stack.minFreeDiskGb, 10)
        XCTAssertEqual(n.updates.feedUrl, defaultUpdateFeedURL, "plain http off loopback is refused")
        XCTAssertEqual(NativeSettings.normalize(["updates": ["feedUrl": "http://localhost:9/latest"]]).updates.feedUrl, "http://localhost:9/latest")
    }

    func testApplyPatchMergesPartialPatchOverCurrentSettings() {
        let current = NativeSettings.normalize(["power": ["onSleep": "pause"], "notifications": ["kinds": ["merged": false]]])
        let next = current.applying(patch: ["notifications": ["kinds": ["question": false]], "login": ["openAtLogin": true]])
        XCTAssertEqual(next.power.onSleep, .pause, "untouched sections are kept")
        XCTAssertEqual(next.notifications.kinds["merged"], false, "untouched kinds are kept")
        XCTAssertEqual(next.notifications.kinds["question"], false)
        XCTAssertTrue(next.login.openAtLogin)
        let bad = next.applying(patch: ["power": ["onSleep": 42]])
        XCTAssertEqual(bad.power.onSleep, .pause, "an invalid patch value keeps the current value, not the default")
    }

    func testIsValidClockTime() {
        XCTAssertTrue(isValidClockTime("00:00"))
        XCTAssertTrue(isValidClockTime("23:59"))
        XCTAssertFalse(isValidClockTime("24:00"))
        XCTAssertFalse(isValidClockTime("7:00"))
        XCTAssertFalse(isValidClockTime(700))
    }

    func testNativeSettingsRoundTripThroughConfigJSONPreservingOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = ConfigFile.url(dataDirectory: dir)
        try Data(#"{"serverUrl":"http://localhost:8080","localCheckoutPath":"/x","playgroundPorts":[8090]}"#.utf8).write(to: cfg)

        var legacy = ConfigFile.loadNative(from: cfg)
        XCTAssertEqual(legacy, NativeSettings.defaults(), "old configs get defaults")

        legacy.tray.onLastWindowClose = .menuBar
        legacy.quickCapture = NativeSettings.Shortcut(shortcut: "CommandOrControl+Shift+K")
        legacy.quickCapture.enabled = true
        try ConfigFile.save(native: legacy, to: cfg)

        let again = ConfigFile.loadNative(from: cfg)
        XCTAssertEqual(again.tray.onLastWindowClose, .menuBar)
        XCTAssertEqual(again.quickCapture.shortcut, "CommandOrControl+Shift+K")
        XCTAssertEqual(again, legacy)
        let raw = ConfigFile.readDictionary(at: cfg)
        XCTAssertEqual(raw["serverUrl"] as? String, "http://localhost:8080")
        XCTAssertEqual(raw["localCheckoutPath"] as? String, "/x")
        XCTAssertEqual(raw["playgroundPorts"] as? [Int], [8090])
        XCTAssertEqual(ConfigFile.loadPlaygroundPorts(from: cfg), [8090])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfg.path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"))
    }

    func testPlaygroundPortsDefaultAndNormalize() {
        XCTAssertEqual(ConfigFile.normalizePlaygroundPorts(nil), [8090, 8091, 8092, 8093, 8094])
        XCTAssertEqual(ConfigFile.normalizePlaygroundPorts([8090, 8090, "8100", 0, 70000, 1.5]), [8090, 8100])
        XCTAssertEqual(ConfigFile.normalizePlaygroundPorts([]), defaultPlaygroundPorts)
    }

    func testRunnerSlotsDefaultsTo2Keeps1To32AndFallsBackOtherwise() {
        XCTAssertEqual(NativeSettings.defaults().stack.runnerSlots, 2)
        for ok in [1, 32, 8] { XCTAssertEqual(NativeSettings.normalize(["stack": ["runnerSlots": ok]]).stack.runnerSlots, ok) }
        let bad: [Any] = [0, 33, 2.5, "abc", NSNull()]
        for b in bad { XCTAssertEqual(NativeSettings.normalize(["stack": ["runnerSlots": b]]).stack.runnerSlots, 2, "\(b)") }
        let next = NativeSettings.normalize([:]).applying(patch: ["stack": ["runnerSlots": 6]])
        XCTAssertEqual(next.stack.runnerSlots, 6)
        XCTAssertEqual(next.stack.minFreeDiskGb, 10, "other stack settings are kept")
    }

    func testExtraCaFileKeepsAnAbsolutePathOrNothing() {
        XCTAssertEqual(NativeSettings.defaults().stack.extraCaFile, "")
        XCTAssertEqual(NativeSettings.normalize(["stack": ["extraCaFile": "/Users/me/zscaler-root.pem"]]).stack.extraCaFile, "/Users/me/zscaler-root.pem")
        let bad: [Any] = ["zscaler-root.pem", "/bad\npath.pem", 3, NSNull()]
        for b in bad { XCTAssertEqual(NativeSettings.normalize(["stack": ["extraCaFile": b]]).stack.extraCaFile, "", "\(b)") }
        let set = NativeSettings.normalize([:]).applying(patch: ["stack": ["extraCaFile": "/Users/me/ca.pem"]])
        XCTAssertEqual(set.stack.extraCaFile, "/Users/me/ca.pem")
        XCTAssertEqual(set.applying(patch: ["stack": ["extraCaFile": ""]]).stack.extraCaFile, "", "Clear empties it")
    }

    func testShowHideAndDockSettingsDefaultSafelyAndRepair() {
        let n = NativeSettings.normalize(["showHide": ["enabled": "yes", "shortcut": " "], "dock": ["menu": false, "progress": 1]])
        XCTAssertEqual(n.showHide, NativeSettings.Shortcut(shortcut: "Alt+Shift+V"))
        XCTAssertFalse(n.dock.menu)
        XCTAssertTrue(n.dock.progress)
    }

    func testNewSettingsRepairBadInput() {
        let n = NativeSettings.normalize([
            "backups": ["export": ["folder": "relative/dir", "everyHours": 0, "keep": 1000]],
            "workspaces": ["terminalApp": "Ghostty", "editor": ["kind": "emacs", "command": "nvim; rm -rf ~", "app": "Zed"]],
        ])
        XCTAssertEqual(n.backups.export.folder, "")
        XCTAssertEqual(n.backups.export.everyHours, 24)
        XCTAssertEqual(n.backups.export.keep, 7)
        XCTAssertEqual(n.workspaces.terminalApp, "Ghostty")
        XCTAssertEqual(n.workspaces.editor.kind, .terminal)
        XCTAssertEqual(n.workspaces.editor.command, "nvim", "a command with ; is refused")
        XCTAssertEqual(n.workspaces.editor.app, "Zed")
    }

    func testAppNamesTerminalCommandsAndFoldersAreValidated() {
        for ok in ["Terminal", "iTerm", "Visual Studio Code", "Cursor", "Zed Preview"] { XCTAssertTrue(isValidAppName(ok), ok) }
        for bad in ["", " Terminal", "a/b", "Terminal\"; x", String(repeating: "x", count: 65)] { XCTAssertFalse(isValidAppName(bad), bad) }
        for ok in ["nvim", "hx", "nvim -c Explore", "emacs -nw"] { XCTAssertTrue(isValidTerminalCommand(ok), ok) }
        for bad in ["", "nvim;ls", "nvim && ls", "$(id)", "`id`", "nvim | x", "nvim > f", "nvim 'a'", "nvim  x"] {
            XCTAssertFalse(isValidTerminalCommand(bad), bad)
        }
        XCTAssertEqual(normalizeFolder("/Users/liam/Backups/", fallback: ""), "/Users/liam/Backups")
        XCTAssertEqual(normalizeFolder("", fallback: "/x"), "")
        XCTAssertEqual(normalizeFolder("~/Backups", fallback: "/x"), "/x")
        XCTAssertEqual(normalizeFolder("/a\nb", fallback: "/x"), "/x")
    }

    @MainActor
    func testSettingsStoreSavesAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(dataDirectory: dir)
        XCTAssertEqual(store.settings, NativeSettings.defaults())
        store.update { $0.tray.showCount = false }
        store.apply(patch: ["power": ["onSleep": "pause"]])
        let other = SettingsStore(dataDirectory: dir)
        XCTAssertFalse(other.settings.tray.showCount)
        XCTAssertEqual(other.settings.power.onSleep, .pause)
    }

    func testAppearanceDefaultsNilNormalizesAndSupportsClearingOverridesViaPatch() throws {
        XCTAssertNil(NativeSettings.defaults().appearance)
        XCTAssertEqual(NativeSettings.defaults().effectiveAppearance, .macOSDefault)

        let configured = NativeSettings.normalize([
            "appearance": [
                "mode": "dark",
                "palette": "custom",
                "textSize": "large",
                "showHarnessActivity": false,
                "custom": [
                    "base": "nord",
                    "dark": ["accent": "#AABBCC", "bg": "evil"],
                    "light": ["bg": "#ffffff"],
                ],
            ],
        ])
        XCTAssertEqual(configured.appearance?.mode, .dark)
        XCTAssertEqual(configured.appearance?.palette, "custom")
        XCTAssertEqual(configured.appearance?.textSize, .large)
        XCTAssertEqual(configured.appearance?.custom.base, "nord")
        XCTAssertEqual(configured.appearance?.custom.dark, ["accent": "#aabbcc"])

        let cleared = configured.applying(patch: ["appearance": ["custom": ["dark": [:] as [String: Any]]]])
        XCTAssertEqual(cleared.appearance?.custom.dark, [:])
        XCTAssertEqual(cleared.appearance?.custom.light, ["bg": "#ffffff"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = ConfigFile.url(dataDirectory: dir)
        try ConfigFile.save(native: cleared, to: cfg)
        let reloaded = ConfigFile.loadNative(from: cfg)
        XCTAssertEqual(reloaded.appearance, cleared.appearance)
    }
}
