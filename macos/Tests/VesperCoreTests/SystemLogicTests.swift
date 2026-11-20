import XCTest
@testable import VesperCore

private func mkRun(_ id: String, _ edit: (inout RunSummary) -> Void = { _ in }) -> RunSummary {
    var r = RunSummary(id: id, state: "running", purpose: "ticket")
    edit(&r)
    return r
}

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

final class PowerThermalTests: XCTestCase {
    let power = NativeSettings.defaults().power

    func testSleepBlockerHeldOnlyWhileRunsAreWorkingAndSettingIsOn() {
        XCTAssertTrue(PowerLogic.wantsSleepBlocker(power, live: [mkRun("a")]))
        XCTAssertFalse(PowerLogic.wantsSleepBlocker(power, live: [mkRun("a") { $0.state = "waiting"; $0.waitReason = "approval" }]))
        XCTAssertFalse(PowerLogic.wantsSleepBlocker(power, live: [mkRun("a") { $0.state = "paused" }]))
        XCTAssertFalse(PowerLogic.wantsSleepBlocker(power, live: []))
        var off = power; off.preventSleepWhileRunning = false
        XCTAssertFalse(PowerLogic.wantsSleepBlocker(off, live: [mkRun("a")]))
    }

    func testPauseOnSleepAndResumeOnlyTheOnesVesperPaused() {
        let live = [mkRun("a"), mkRun("b") { $0.purpose = "chat" }, mkRun("c") { $0.state = "waiting"; $0.waitReason = "checks" }]
        XCTAssertEqual(PowerLogic.runsToPauseOnSleep(power, live: live), [], "keep policy pauses nothing")
        var pause = power; pause.onSleep = .pause
        XCTAssertEqual(PowerLogic.runsToPauseOnSleep(pause, live: live).map(\.id), ["a"])

        var paused: Set<String> = ["a", "gone"]
        let after = [mkRun("a") { $0.state = "paused" }, mkRun("x") { $0.state = "paused" }]
        XCTAssertEqual(PowerLogic.runsToResume(pausedByVesper: paused, live: after), ["a"], "a run the person paused by hand stays paused")
        PowerLogic.prunePausedSet(&paused, live: after)
        XCTAssertEqual(paused, ["a"])
    }

    func testBatteryWarningAndQuitConfirmation() {
        XCTAssertTrue(PowerLogic.batteryWarning(power, onBattery: true, live: [mkRun("a"), mkRun("b")])!.hasPrefix("2 runs are still working"))
        XCTAssertTrue(PowerLogic.batteryWarning(power, onBattery: true, live: [mkRun("a")])!.hasPrefix("1 run is still working"))
        XCTAssertNil(PowerLogic.batteryWarning(power, onBattery: false, live: [mkRun("a")]))
        XCTAssertNil(PowerLogic.batteryWarning(power, onBattery: true, live: [mkRun("a") { $0.state = "paused" }]))
        var quiet = power; quiet.warnOnBattery = false
        XCTAssertNil(PowerLogic.batteryWarning(quiet, onBattery: true, live: [mkRun("a")]))
        XCTAssertTrue(PowerLogic.shouldConfirmQuit(power, stackRunning: true, hasActiveRuns: true))
        XCTAssertFalse(PowerLogic.shouldConfirmQuit(power, stackRunning: false, hasActiveRuns: true))
        var noConfirm = power; noConfirm.confirmQuitWithActiveRuns = false
        XCTAssertFalse(PowerLogic.shouldConfirmQuit(noConfirm, stackRunning: true, hasActiveRuns: true))
    }

    func testDesiredSlotLimitEasesOffForHeatAndLowPowerNeverRaises() {
        func limit(_ t: ThermalState = .nominal, lpm: Bool = false, enabled: Bool = true, max: Int = 4) -> Int? {
            Thermal.desiredSlotLimit(ThermalInput(enabled: enabled, thermal: t, lowPowerMode: lpm, maxSlots: max))
        }
        XCTAssertNil(limit())
        XCTAssertNil(limit(.fair))
        XCTAssertEqual(limit(.serious), 2)
        XCTAssertEqual(limit(lpm: true), 2)
        XCTAssertEqual(limit(.critical), 1)
        XCTAssertNil(limit(.critical, enabled: false))
        XCTAssertNil(limit(.serious, max: 1), "a cap equal to max is no cap")
        XCTAssertEqual(limit(.serious, max: 3), 1)
        XCTAssertNil(limit(.critical, max: 0))
        XCTAssertTrue(Thermal.parseLowPowerMode(" displaysleep 10\n lowpowermode         1\n"))
        XCTAssertFalse(Thermal.parseLowPowerMode(" lowpowermode         0\n"))
        XCTAssertFalse(Thermal.parseLowPowerMode(""))
        XCTAssertEqual(Thermal.easingOffLabel(limit: 1, thermal: .critical, lowPowerMode: false), "Mac is hot: 1 run at a time")
        XCTAssertEqual(Thermal.easingOffLabel(limit: 2, thermal: .nominal, lowPowerMode: true), "Low Power Mode: 2 runs at a time")
        XCTAssertNil(Thermal.easingOffLabel(limit: nil, thermal: .critical, lowPowerMode: true))
    }
}

final class BackupsTests: XCTestCase {
    func testTimeMachineTargetsAreOnlyRebuildableFolders() {
        XCTAssertEqual(Backups.timeMachineTargets(dataDirectory: "/Users/l/Library/Application Support/Vesper"), [
            "/Users/l/Library/Application Support/Vesper/vm", "/Users/l/Library/Application Support/Vesper/images",
        ])
        XCTAssertEqual(Backups.parseIsExcluded("[Excluded]    /a/vm\n"), true)
        XCTAssertEqual(Backups.parseIsExcluded("[Included]    /a/vm\n"), false)
        XCTAssertNil(Backups.parseIsExcluded("tmutil: error"))
    }

    func testScheduledExportNamesDueTimesAndPruningOnlyOurFiles() {
        XCTAssertEqual(Backups.exportFileName(date(2026, 1, 2, 3, 4)), "vesper-export-2026-01-02-0304.zip")
        XCTAssertEqual(Backups.exportFileName(date(2026, 1, 2, 3, 4), encrypted: true), "vesper-export-2026-01-02-0304.vesper.enc")
        let names = [
            "vesper-export-2026-11-15-0900.zip", "vesper-export-2026-11-17-0900.zip", "vesper-export-2026-11-16-0900.zip",
            "vesper-export-2026-11-14-0900.zip", "notes.txt", "vesper-export-latest.zip", "vesper-export-2026-11-17-0900.zip.part",
        ]
        XCTAssertEqual(Backups.exportsToPrune(names, keep: 2), ["vesper-export-2026-11-15-0900.zip", "vesper-export-2026-11-14-0900.zip"])
        XCTAssertEqual(Backups.exportsToPrune(names, keep: 0).count, 3, "always keeps at least the newest")
        let mixed = [
            "vesper-export-2026-11-15-0900.zip",
            "vesper-export-2026-11-17-0900.vesper.enc",
            ".vesper-export-2026-11-14-0900.vesper.enc.icloud",
            "vesper-export-2026-11-16-0900.vesper.enc",
        ]
        XCTAssertEqual(
            Backups.exportsToPrune(mixed, keep: 2),
            ["vesper-export-2026-11-15-0900.zip", ".vesper-export-2026-11-14-0900.vesper.enc.icloud"]
        )
        // Evicted iCloud Drive placeholders sort by their export timestamp alongside local zips.
        let icloudNames = [
            "vesper-export-2026-11-15-0900.zip",
            ".vesper-export-2026-11-17-0900.zip.icloud",
            ".vesper-export-2026-11-14-0900.zip.icloud",
            "vesper-export-2026-11-16-0900.zip",
            ".notes.txt.icloud",
            ".vesper-export-latest.zip.icloud",
            ".vesper-export-2026-11-17-0900.zip",
            "vesper-export-2026-11-17-0900.zip.icloud",
        ]
        XCTAssertEqual(
            Backups.exportsToPrune(icloudNames, keep: 2),
            ["vesper-export-2026-11-15-0900.zip", ".vesper-export-2026-11-14-0900.zip.icloud"],
            "keeps the newest evicted placeholder and local zip, prunes older evicted and local exports, ignores unrelated files"
        )
        let h = 60.0 * 60 * 1000
        XCTAssertTrue(Backups.isExportDue(lastAt: nil, now: 10 * h, everyHours: 24))
        XCTAssertFalse(Backups.isExportDue(lastAt: 1 * h, now: 10 * h, everyHours: 24))
        XCTAssertTrue(Backups.isExportDue(lastAt: 1 * h, now: 26 * h, everyHours: 24))
        XCTAssertTrue(Backups.isExportDue(lastAt: 50 * h, now: 10 * h, everyHours: 24), "a clock that moved back exports")
    }
}

final class UpdatesTests: XCTestCase {
    func testVersionsCompareSemverStyleWithPreReleasesFirst() {
        XCTAssertEqual(Updates.parseVersion("v1.2.3-beta.1"), ParsedVersion(major: 1, minor: 2, patch: 3, pre: "beta.1"))
        XCTAssertNil(Updates.parseVersion("1.2"))
        XCTAssertEqual(Updates.compareVersions("0.2.0", "0.1.9"), 1)
        XCTAssertEqual(Updates.compareVersions("0.1.0", "0.1.0"), 0)
        XCTAssertEqual(Updates.compareVersions("1.0.0-rc.1", "1.0.0"), -1)
        XCTAssertEqual(Updates.compareVersions("v1.10.0", "1.9.9"), 1)
    }

    func testPickUpdateAcceptsOnlyNewerPublishedReleasesOnTrustedHttpsHosts() {
        let feed = "https://api.github.com/repos/liamphmurphy/vesper/releases/latest"
        let rel: [String: Any] = ["tag_name": "v0.2.0", "html_url": "https://github.com/liamphmurphy/vesper/releases/tag/v0.2.0", "name": "Vesper 0.2", "draft": false, "prerelease": false]
        func with(_ k: String, _ v: Any) -> [String: Any] { var r = rel; r[k] = v; return r }
        XCTAssertEqual(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: rel), UpdateInfo(version: "0.2.0", url: rel["html_url"] as! String, name: "Vesper 0.2"))
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.2.0", feedURL: feed, release: rel), "not newer")
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: with("prerelease", true)))
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: with("draft", true)))
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: with("html_url", "https://evil.example/download")))
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: with("html_url", "http://github.com/x")))
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: with("tag_name", "latest")))
        XCTAssertNil(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: feed, release: nil))
        let own = "https://updates.example.net/vesper/latest.json"
        XCTAssertEqual(Updates.pickUpdate(currentVersion: "0.1.0", feedURL: own, release: with("html_url", "https://updates.example.net/vesper/0.2.0"))?.version, "0.2.0")
    }

    func testVersionTransitionAndCheckDue() {
        XCTAssertEqual(Updates.versionTransition(lastVersion: nil, currentVersion: "0.1.0"), .firstRun)
        XCTAssertEqual(Updates.versionTransition(lastVersion: "0.1.0", currentVersion: "0.1.0"), .same)
        XCTAssertEqual(Updates.versionTransition(lastVersion: "0.1.0", currentVersion: "0.2.0"), .upgrade)
        XCTAssertEqual(Updates.versionTransition(lastVersion: "0.3.0", currentVersion: "0.2.0"), .downgrade)
        let day = 24.0 * 60 * 60 * 1000
        XCTAssertTrue(Updates.isCheckDue(lastCheckedAt: nil, now: 5 * day))
        XCTAssertFalse(Updates.isCheckDue(lastCheckedAt: 4.5 * day, now: 5 * day))
        XCTAssertTrue(Updates.isCheckDue(lastCheckedAt: 3 * day, now: 5 * day))
        XCTAssertTrue(Updates.isCheckDue(lastCheckedAt: 9 * day, now: 5 * day), "a clock that moved back re-checks")
    }
}

final class WorkspaceOpenTests: XCTestCase {
    func testWorkspaceFoldersOpenOnlyInsideARunnersRoot() {
        let roots = ["/Users/l/Vesper Workspaces"]
        XCTAssertTrue(WorkspaceOpen.isInsideRoots("/Users/l/Vesper Workspaces/run-1", roots: roots))
        XCTAssertFalse(WorkspaceOpen.isInsideRoots("/Users/l/Vesper Workspaces", roots: roots), "the root itself isn't a workspace")
        XCTAssertFalse(WorkspaceOpen.isInsideRoots("/Users/l/Vesper Workspaces-evil/x", roots: roots))
        XCTAssertFalse(WorkspaceOpen.isInsideRoots("/Users/l/Vesper Workspaces/../.ssh", roots: roots))
        XCTAssertFalse(WorkspaceOpen.isInsideRoots("relative/run-1", roots: roots))
        XCTAssertFalse(WorkspaceOpen.isInsideRoots("/Users/l/Vesper Workspaces/run-1", roots: []))
    }

    func testRealpathResolvesSymlinksBeforeTheContainmentCheck() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-ws-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root"), inside = root.appendingPathComponent("run-1"), outside = base.appendingPathComponent("secret")
        for d in [inside, outside] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNotNil(WorkspaceOpen.isAllowedWorkspace(inside.path, rootDirs: [root.path]))
        XCTAssertNil(WorkspaceOpen.isAllowedWorkspace(link.path, rootDirs: [root.path]), "a symlink out of the root is refused")
        XCTAssertNil(WorkspaceOpen.isAllowedWorkspace(root.path, rootDirs: [root.path]))
        XCTAssertNil(WorkspaceOpen.isAllowedWorkspace(base.appendingPathComponent("missing").path, rootDirs: [root.path]))
    }

    func testOpenCommandBuildsSafeCommandsForEachTarget() throws {
        let ws = NativeSettings.defaults().workspaces
        let dir = "/Users/l/W/it's \"here\""
        XCTAssertNil(try WorkspaceOpen.openCommand(.finder, dir: dir, workspaces: ws))
        var ghostty = ws; ghostty.terminalApp = "Ghostty"
        XCTAssertEqual(try WorkspaceOpen.openCommand(.terminal, dir: dir, workspaces: ghostty), OpenCommand(file: "/usr/bin/open", args: ["-a", "Ghostty", dir]))
        var zed = ws; zed.editor.kind = .app; zed.editor.app = "Zed"
        XCTAssertEqual(try WorkspaceOpen.openCommand(.editor, dir: dir, workspaces: zed), OpenCommand(file: "/usr/bin/open", args: ["-a", "Zed", dir]))
        let nvim = try XCTUnwrap(WorkspaceOpen.openCommand(.editor, dir: dir, workspaces: ws))
        XCTAssertEqual(nvim.file, "/usr/bin/osascript")
        XCTAssertEqual(nvim.args[1], #"tell application "Terminal" to do script "cd '/Users/l/W/it'\\''s \"here\"' && nvim .""#)
        var hostile = ws; hostile.editor.command = "nvim; curl evil"
        XCTAssertTrue(try XCTUnwrap(WorkspaceOpen.openCommand(.editor, dir: "/w/x", workspaces: hostile)).args[1].hasSuffix("&& nvim .\""))
        XCTAssertEqual(WorkspaceOpen.appleScriptString(#"a\b"c"#), #""a\\b\"c""#)
        XCTAssertThrowsError(try WorkspaceOpen.openCommand(.terminal, dir: "relative", workspaces: ws))
        XCTAssertEqual(WorkspaceOpen.shQuote("/Applications/Ves'per.app"), #"'/Applications/Ves'\''per.app'"#)
    }
}

final class BiometricsTests: XCTestCase {
    func testTouchIdDecision() {
        var on = NativeSettings.TouchId()
        on.enabled = true
        on.scopes["push_requests"] = false
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: "run_approvals", canPrompt: true), .prompt)
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: "push_requests", canPrompt: true), .skip)
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: "run_approvals", canPrompt: false), .promptWithPassword, "no sensor: account password, not a skip")
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: "push_requests", canPrompt: false), .skip, "scope off stays off")
        var disabled = on; disabled.enabled = false
        XCTAssertEqual(Biometrics.touchIdDecision(disabled, scope: "run_approvals", canPrompt: true), .skip)
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: "everything", canPrompt: true), .prompt, "unknown scope still gated")
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: nil, canPrompt: false), .promptWithPassword)
        XCTAssertEqual(Biometrics.touchIdDecision(on, scope: .secretApprovals, canPrompt: true), .prompt)
        XCTAssertEqual(Biometrics.touchIdReason(.pushRequests), "approve a push and pull request")
    }
}
