import XCTest
@testable import VesperCore

/// Ported from the terminal cases of web/lib/dev-workspace.test.mjs, plus the native-only rules.
final class DevTerminalLogicTests: XCTestCase {
    func testSocketURLUsesTheAppsHostAndTheWorkspacePort() throws {
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:43117"))
        XCTAssertEqual(DevTerminalLogic.socketURL(base: local, port: 8090, cols: 120, rows: 36)?.absoluteString,
                       "ws://127.0.0.1:8090/ws?cols=120&rows=36")
        let tailnet = try XCTUnwrap(URL(string: "https://vesper.tailnet.ts.net"))
        XCTAssertEqual(DevTerminalLogic.socketURL(base: tailnet, port: 8091, cols: 0, rows: -3)?.absoluteString,
                       "wss://vesper.tailnet.ts.net:8091/ws?cols=1&rows=1")
        let v6 = try XCTUnwrap(URL(string: "http://[::1]:8080"))
        XCTAssertEqual(DevTerminalLogic.socketURL(base: v6, port: 8092, cols: 80, rows: 24)?.absoluteString,
                       "ws://[::1]:8092/ws?cols=80&rows=24")
        XCTAssertNil(DevTerminalLogic.socketURL(base: local, port: 0, cols: 80, rows: 24))
    }

    func testOriginMatchesTheServersAllowList() throws {
        // server/cmd/vesper origins(): scheme://host[:port], no path or trailing slash.
        XCTAssertEqual(DevTerminalLogic.origin(of: try XCTUnwrap(URL(string: "http://127.0.0.1:43117/"))), "http://127.0.0.1:43117")
        XCTAssertEqual(DevTerminalLogic.origin(of: try XCTUnwrap(URL(string: "https://vesper.example.com/app"))), "https://vesper.example.com")
        XCTAssertEqual(DevTerminalLogic.origin(of: try XCTUnwrap(URL(string: "http://[::1]:8080"))), "http://[::1]:8080")
    }

    func testResizeMessageIsTheServersControlFrame() throws {
        let raw = DevTerminalLogic.resizeMessage(cols: 132, rows: 0)
        XCTAssertTrue(raw.hasPrefix("{"), "the runner only parses frames starting with {")
        let decoded = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["type"] as? String, "resize")
        XCTAssertEqual(decoded?["cols"] as? Int, 132)
        XCTAssertEqual(decoded?["rows"] as? Int, 1)
    }

    func testStatusToneAndLabel() {
        XCTAssertEqual(DevTerminalLogic.statusTone(.ready), "done")
        XCTAssertEqual(DevTerminalLogic.statusTone(.starting), "human")
        XCTAssertEqual(DevTerminalLogic.statusTone(.error), "blocked")
        XCTAssertEqual(DevTerminalLogic.statusTone(.stopped), "neutral")
        XCTAssertEqual(DevTerminalLogic.statusLabel(enabled: false, state: .stopped, step: nil), "Stopped (not configured)")
        XCTAssertEqual(DevTerminalLogic.statusLabel(enabled: true, state: .starting, step: "Installing Nix + LazyVim"),
                       "Starting · Installing Nix + LazyVim")
        XCTAssertEqual(DevTerminalLogic.statusLabel(enabled: true, state: .starting, step: ""), "Starting…")
        XCTAssertEqual(DevTerminalLogic.statusLabel(enabled: true, state: .ready, step: nil), "Ready")
        XCTAssertEqual(DevTerminalLogic.statusLabel(enabled: true, state: .error, step: nil), "Error")
        XCTAssertEqual(DevTerminalLogic.statusLabel(enabled: true, state: .stopped, step: nil), "Stopped")
    }

    func testPillPrefersTheSocketState() {
        XCTAssertTrue(DevTerminalLogic.pill(connection: .connected, enabled: true, state: .ready, step: nil) == ("Connected · tmux", "done"))
        XCTAssertTrue(DevTerminalLogic.pill(connection: .connecting, enabled: true, state: .ready, step: nil) == ("Connecting…", "done"))
        XCTAssertTrue(DevTerminalLogic.pill(connection: .disconnected, enabled: true, state: .starting, step: "Cloning")
            == ("Starting · Cloning", "human"))
    }

    func testBusyPollsWhileStartingOrActing() {
        XCTAssertTrue(DevTerminalLogic.isBusy(state: .starting, action: nil))
        XCTAssertTrue(DevTerminalLogic.isBusy(state: .ready, action: "sync"))
        XCTAssertFalse(DevTerminalLogic.isBusy(state: .ready, action: nil))
        XCTAssertFalse(DevTerminalLogic.isBusy(state: .ready, action: ""))
    }

    func testFullscreenShortcutIsCmdOrCtrlShiftEnterOnly() {
        func check(_ key: String = "\r", cmd: Bool = false, ctrl: Bool = true, opt: Bool = false, shift: Bool = true) -> Bool {
            DevTerminalLogic.isFullscreenShortcut(key: key, command: cmd, control: ctrl, option: opt, shift: shift)
        }
        XCTAssertTrue(check())
        XCTAssertTrue(check(cmd: true, ctrl: false))
        XCTAssertTrue(check("\u{3}", cmd: true, ctrl: false))
        XCTAssertFalse(check(shift: false))
        XCTAssertFalse(check(opt: true))
        XCTAssertFalse(check(cmd: false, ctrl: false))
        XCTAssertFalse(check("f"))
    }

    func testShortcutGroupsFollowTheTmuxPrefix() {
        let groups = DevTerminalLogic.shortcutGroups(tmuxPrefix: nil)
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { !$0.items.isEmpty })
        XCTAssertEqual(groups[1].title, "tmux (Ctrl+b prefix)")
        XCTAssertEqual(DevTerminalLogic.tmuxPrefixLabel(.cA), "Ctrl+a")
        XCTAssertEqual(DevTerminalLogic.tmuxPrefixLabel(.cSpace), "Ctrl+Space")
        let custom = DevTerminalLogic.shortcutGroups(tmuxPrefix: .cA)
        XCTAssertEqual(custom[1].title, "tmux (Ctrl+a prefix)")
        XCTAssertEqual(custom[1].items[0].keys, "Ctrl+a c")
    }

    func testOsc52CopiesUTF8WritesOnly() {
        XCTAssertEqual(DevTerminalLogic.osc52Text(Data("hello world".utf8)), "hello world")
        XCTAssertEqual(DevTerminalLogic.osc52Text(Data("héllo ✓\nline".utf8)), "héllo ✓\nline")
        XCTAssertNil(DevTerminalLogic.osc52Text(Data()))
        XCTAssertNil(DevTerminalLogic.osc52Text(Data([0xff, 0xfe])))
        let limit = DevTerminalLogic.osc52MaxPayload / 4 * 3
        XCTAssertNotNil(DevTerminalLogic.osc52Text(Data(repeating: 0x41, count: limit)))
        XCTAssertNil(DevTerminalLogic.osc52Text(Data(repeating: 0x41, count: limit + 1)))
    }

    func testSnapshotLinesTrimTrailingBlanksAndCap() {
        let text = "$ go test ./...  \nPASS\n   \n\n"
        XCTAssertEqual(DevTerminalLogic.snapshotLines(text, maxLines: 120), ["$ go test ./...", "PASS"])
        XCTAssertEqual(DevTerminalLogic.snapshotLines(text, maxLines: 1), ["PASS"])
        XCTAssertEqual(DevTerminalLogic.snapshotLines("\n  \n"), [])
    }

    func testSnapshotMarkdownAndFilename() {
        let at = Date(timeIntervalSince1970: 1_794_809_730) // 2026-11-16T06:15:30Z
        XCTAssertEqual(DevTerminalLogic.snapshotFilename(at: at), "dev-terminal-20261116-061530.md")
        let md = DevTerminalLogic.snapshotMarkdown(lines: ["$ ls", "vesper"], selection: "vesper", cols: 120, rows: 36, at: at)
        XCTAssertTrue(md.hasPrefix("# Dev terminal snapshot\n\n- Captured: 2026-11-16T06:15:30.000Z\n- Size: 120x36\n"))
        XCTAssertTrue(md.contains("## Selected text\n\n```\nvesper\n```"))
        XCTAssertTrue(md.contains("## Visible terminal output (2 lines)\n\n```\n$ ls\nvesper\n```"))
        XCTAssertTrue(md.hasSuffix("```\n"))
        let empty = DevTerminalLogic.snapshotMarkdown(lines: [], selection: "  ", cols: 80, rows: 24, at: at)
        XCTAssertFalse(empty.contains("Selected text"))
        XCTAssertTrue(empty.hasSuffix("## Visible terminal output (0 lines)\n\n(empty)\n"))
        XCTAssertEqual(DevTerminalLogic.fence("a ``` b"), "````\na ``` b\n````")
    }

    func testSecureInputStaysBalanced() {
        XCTAssertTrue(DevTerminalLogic.wantsSecureInput(enabled: true, terminalFocused: true, windowIsKey: true))
        XCTAssertFalse(DevTerminalLogic.wantsSecureInput(enabled: true, terminalFocused: true, windowIsKey: false))
        XCTAssertFalse(DevTerminalLogic.wantsSecureInput(enabled: false, terminalFocused: true, windowIsKey: true))
        var balance = SecureInputBalance()
        XCTAssertNil(balance.update(wanted: false))
        XCTAssertEqual(balance.update(wanted: true), .enable)
        XCTAssertNil(balance.update(wanted: true), "a second focus must not enable twice")
        XCTAssertEqual(balance.update(wanted: false), .disable)
        XCTAssertNil(balance.update(wanted: false))
    }

    func testThemeIsTheWebsGruvbox() {
        XCTAssertEqual(DevTerminalTheme.ansi.count, 16)
        XCTAssertTrue((DevTerminalTheme.ansi + [DevTerminalTheme.background, DevTerminalTheme.foreground, DevTerminalTheme.selection])
            .allSatisfy { RGBA(hex: $0) != nil })
    }

    func testNavModelListsWorkspaceActionsAndRepos() {
        let ws = API.DevWorkspace(
            action: nil,
            arch: nil,
            customGitconfig: nil,
            customTmuxConf: nil,
            customZshrc: nil,
            enabled: true,
            error: nil,
            extraPackages: [],
            nixMode: .default,
            port: .value(8090),
            repos: [API.DevWorkspaceRepo(directory: "vesper", repoUrl: "https://github.com/o/vesper")],
            state: .ready,
            step: nil,
            tmuxPrefix: .cA,
            updatedAt: "2026-11-22T00:00:00Z"
        )
        let nav = DevTerminalLogic.navModel(workspace: ws, connection: .connected)
        XCTAssertEqual(nav.id, DevTerminalLogic.navId)
        XCTAssertEqual(nav.sections.map(\.id), ["status", "actions", "repos"])
        XCTAssertEqual(nav.sections[0].items.first?.status, .done)
        XCTAssertEqual(nav.sections[2].items.map(\.title), ["vesper"])

        let disconnected = DevTerminalLogic.navModel(workspace: ws, connection: .disconnected)
        let actionIds = disconnected.sections[1].items.map(\.id)
        XCTAssertTrue(actionIds.contains(DevTerminalLogic.reconnectItem))
        XCTAssertTrue(actionIds.contains(DevTerminalLogic.sendToChatItem))

        XCTAssertEqual(
            DevTerminalLogic.navAction(for: .navActivate(navigatorId: DevTerminalLogic.navId, itemId: DevTerminalLogic.syncReposItem)),
            .syncRepos
        )
        XCTAssertEqual(
            DevTerminalLogic.navAction(for: .navActivate(navigatorId: DevTerminalLogic.navId, itemId: DevTerminalLogic.fullscreenItem)),
            .fullscreen
        )
        XCTAssertNil(DevTerminalLogic.navAction(for: .navActivate(navigatorId: "other", itemId: DevTerminalLogic.syncReposItem)))
    }
}
