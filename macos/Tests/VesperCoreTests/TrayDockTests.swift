import XCTest
@testable import VesperCore

private let P1 = "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
private let P2 = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b"

private func mkRun(_ id: String, _ edit: (inout RunSummary) -> Void = { _ in }) -> RunSummary {
    var r = RunSummary(id: id, state: "running", purpose: "ticket", ticketKey: "PAY-1", workTitle: "Work \(id)", agent: AgentRef(name: "Pike"))
    edit(&r)
    return r
}

private func item(_ id: String, _ edit: (inout InboxItem) -> Void = { _ in }) -> InboxItem {
    var i = InboxItem(id: id, kind: "approval", title: "Item \(id)", href: "/runs/\(id)", createdAt: "2026-11-17T10:00:00Z", needsYou: true)
    edit(&i)
    return i
}

private let running = StackHealth(phase: .running, title: "Vesper is running", actions: [.logs])

private func labels(_ menu: [TrayMenuItem]) -> [String] { menu.map { $0.label ?? "---" } }

final class TrayModelTests: XCTestCase {
    func testNewestNeedsYouKeepsOpenItemsNewestFirst() {
        let list = TrayModel.newestNeedsYou([
            item("old") { $0.createdAt = "2026-11-16T10:00:00Z" },
            item("new") { $0.createdAt = "2026-11-17T12:00:00Z" },
            item("read") { $0.read = true },
            item("news") { $0.needsYou = false },
            item("done") { $0.resolved = true },
        ])
        XCTAssertEqual(list.map(\.id), ["new", "old"])
    }

    func testBuildTrayMenuListsStatusNeedsYouRunningAndActionsInOrder() {
        let menu = TrayModel.buildTrayMenu(TrayMenuInput(
            health: running, localStack: true,
            items: [item("1") { $0.ticketKey = "PAY-2" }, item("2")],
            runs: [mkRun("r1"), mkRun("r2") { $0.purpose = "chat" }, mkRun("r3") { $0.state = "paused" }],
            quickCapture: ShortcutSetting(enabled: true, shortcut: "Alt+Shift+Space")
        ))
        XCTAssertEqual(labels(menu), [
            "● Vesper is running", "---", "Needs you (2)", "PAY-2 · Item 1", "Item 2", "---", "Running (2)",
            "Pike: Work r1", "Pike: Work r3 (paused)", "---", "Open Vesper", "Quick Capture…", "Pause Runs (1)", "---",
            "Restart Stack", "Show Logs…", "---", "Settings…", "Quit Vesper",
        ])
        XCTAssertEqual(menu.first { $0.label == "PAY-2 · Item 1" }?.action, .openHref("/runs/1"))
        XCTAssertEqual(menu.first { $0.label == "Pike: Work r1" }?.action, .openHref("/runs/r1"))
    }

    func testBuildTrayMenuCapsSectionsOffersResumeShowsErrorsAndHidesLocalOnlyItems() {
        let items = (0..<8).map { item(String($0)) }
        let menu = TrayModel.buildTrayMenu(TrayMenuInput(
            health: StackHealth(phase: .error, title: "Disk full", message: "m", nextStep: "Free up disk space, then restart the stack."),
            localStack: false, items: items, pausedByVesper: 2, maxPerSection: 3
        ))
        let l = labels(menu)
        XCTAssertEqual(l[0], "⚠ Disk full")
        XCTAssertEqual(l[1], "Free up disk space, then restart the stack.")
        XCTAssertTrue(l.contains("Show all 8 in Inbox…"))
        XCTAssertEqual(l.filter { $0.hasPrefix("Item ") }.count, 3)
        XCTAssertTrue(l.contains("Resume Runs (2)"))
        XCTAssertFalse(l.contains("Restart Stack"))
        XCTAssertFalse(l.contains("Quick Capture…"))
        let pause = TrayModel.buildTrayMenu(TrayMenuInput(health: running)).first { $0.label == "Pause Runs" }
        if case .item(_, _, let enabled, _) = pause { XCTAssertFalse(enabled) } else { XCTFail("no Pause Runs item") }
    }

    func testTitleTooltipClipAndLastWindowPolicy() {
        XCTAssertEqual(TrayModel.trayTitle(count: 0, showCount: true), "")
        XCTAssertEqual(TrayModel.trayTitle(count: 3, showCount: true), "3")
        XCTAssertEqual(TrayModel.trayTitle(count: 3, showCount: false), "")
        XCTAssertEqual(TrayModel.trayTitle(count: 250, showCount: true), "99+")
        XCTAssertEqual(TrayModel.trayTooltip(running, count: 1), "Vesper: Vesper is running · 1 needs you")
        XCTAssertEqual(TrayModel.trayTooltip(running, count: 2), "Vesper: Vesper is running · 2 need you")
        XCTAssertEqual(TrayModel.trayTooltip(running, count: 0), "Vesper: Vesper is running")
        XCTAssertEqual(TrayModel.clipLabel("a  b\n c"), "a b c")
        XCTAssertEqual(TrayModel.clipLabel(String(repeating: "x", count: 60)).count, 48)
        XCTAssertEqual(TrayModel.lastWindowClosedAction(trayEnabled: true, policy: .dock), .stay)
        XCTAssertEqual(TrayModel.lastWindowClosedAction(trayEnabled: true, policy: .menuBar), .hideDock)
        XCTAssertEqual(TrayModel.lastWindowClosedAction(trayEnabled: false, policy: .menuBar), .stay, "never invisible without a tray")
        XCTAssertEqual(TrayModel.lastWindowClosedAction(trayEnabled: false, policy: .quit), .quit)
    }

    func testEasingNoticeAndScreenshotItem() {
        let menu = TrayModel.buildTrayMenu(TrayMenuInput(
            health: running, screenshot: ShortcutSetting(enabled: true, shortcut: "Alt+Shift+S"), notice: "Mac is hot: 1 run at a time"
        ))
        XCTAssertEqual(labels(menu)[1], "Mac is hot: 1 run at a time")
        let shot = menu.first { $0.label == "Screenshot to Chat…" }
        XCTAssertEqual(shot?.action, .screenshot)
        if case .item(_, _, _, let acc) = shot { XCTAssertEqual(acc, "Alt+Shift+S") } else { XCTFail() }
        let off = TrayModel.buildTrayMenu(TrayMenuInput(health: running, screenshot: ShortcutSetting(enabled: false, shortcut: "Alt+Shift+S")))
        XCTAssertFalse(labels(off).contains("Screenshot to Chat…"))
    }

    func testStatusLineForDownloadAndOtherPhases() {
        let dl = StackHealth(phase: .downloading, title: "Downloading", downloadedBytes: 1, totalBytes: 4)
        XCTAssertEqual(labels(TrayModel.buildTrayMenu(TrayMenuInput(health: dl)))[0], "○ Downloading run image (25%)")
        XCTAssertEqual(labels(TrayModel.buildTrayMenu(TrayMenuInput(health: StackHealth(phase: .downloading, title: "d"))))[0], "○ Downloading run image…")
        XCTAssertEqual(labels(TrayModel.buildTrayMenu(TrayMenuInput(health: .initial)))[0], "○ Starting…")
        XCTAssertEqual(labels(TrayModel.buildTrayMenu(TrayMenuInput(health: StackHealth(phase: .stopped, title: "x"))))[0], "○ Stack stopped")
        let restart = TrayModel.buildTrayMenu(TrayMenuInput(health: .initial)).first { $0.label == "Restart Stack" }
        if case .item(_, _, let enabled, _) = restart { XCTAssertFalse(enabled, "can't restart while starting") } else { XCTFail() }
    }
}

final class DockModelTests: XCTestCase {
    func testDockMenuListsNeedsYouNewChatsPerPersonaAndCapture() {
        let menu = DockModel.buildDockMenu(DockMenuInput(
            items: [item("1") { $0.ticketKey = "PAY-2" }, item("2") { $0.read = true }],
            personas: [PersonaSummary(id: P1, name: "Meow"), PersonaSummary(id: P2, name: "Elminster")],
            screenshot: true
        ))
        XCTAssertEqual(labels(menu), [
            "Needs you (1)", "PAY-2 · Item 1", "---", "New Chat", "New Chat with Meow", "New Chat with Elminster", "---",
            "Quick Capture…", "Screenshot to Chat…",
        ])
        XCTAssertEqual(menu.first { $0.label == "New Chat with Meow" }?.action, .openHref("/chat?new&persona=\(P1)"))
        XCTAssertEqual(menu.first { $0.label == "PAY-2 · Item 1" }?.action, .openHref("/runs/1"))
    }

    func testDockMenuCapsItemsAndPersonasDropsBadIdsAndHidesEmptySections() {
        let many = (0..<8).map { item(String($0)) }
        var personas = [PersonaSummary(id: "not-a-uuid", name: "Bad"), PersonaSummary(id: P1, name: "  ")]
        for i in 0..<9 { personas.append(PersonaSummary(id: String(P2.dropLast()) + String(i), name: "P\(i)")) }
        let menu = DockModel.buildDockMenu(DockMenuInput(items: many, personas: personas, screenshot: false, maxItems: 3, maxPersonas: 2))
        let l = labels(menu)
        XCTAssertEqual(l.filter { $0.hasPrefix("Item ") }.count, 3)
        XCTAssertTrue(l.contains("Show all 8 in Inbox…"))
        XCTAssertEqual(l.filter { $0.hasPrefix("New Chat with") }, ["New Chat with P0", "New Chat with P1"])
        XCTAssertFalse(l.contains("Screenshot to Chat…"))
        XCTAssertEqual(labels(DockModel.buildDockMenu(DockMenuInput(screenshot: false)))[0], "New Chat", "no Needs-you header when nothing needs you")
    }

    func testNewChatHrefOnlyPutsValidPersonaIdInLink() {
        XCTAssertEqual(DockModel.newChatHref(), "/chat?new")
        XCTAssertEqual(DockModel.newChatHref(personaId: P1), "/chat?new&persona=\(P1)")
        XCTAssertEqual(DockModel.newChatHref(personaId: "x&next=//evil"), "/chat?new")
    }

    func testDockProgressFollowsRunImageDownloadOnly() {
        func dl(_ done: Int64, _ total: Int64) -> StackHealth { StackHealth(phase: .downloading, title: "", downloadedBytes: done, totalBytes: total) }
        XCTAssertEqual(DockModel.dockProgress(dl(1, 4)), 0.25)
        XCTAssertEqual(DockModel.dockProgress(dl(5, 4)), 1)
        XCTAssertEqual(DockModel.dockProgress(dl(1, 0)), -1, "unknown size: no bar")
        XCTAssertEqual(DockModel.dockProgress(running), -1)
    }

    func testShowHideActionHidesOnlyWhenInFrontWithAWindow() {
        XCTAssertEqual(DockModel.showHideAction(appFocused: true, visibleWindows: 1), .hide)
        XCTAssertEqual(DockModel.showHideAction(appFocused: false, visibleWindows: 1), .show)
        XCTAssertEqual(DockModel.showHideAction(appFocused: true, visibleWindows: 0), .show)
    }
}

// Mirrors web/lib/inbox.test.mjs's tray cases.
final class InboxTrayTests: XCTestCase {
    private func at(_ min: Int) -> String {
        let base = Date(timeIntervalSince1970: 1_794_052_800)  // fixed
        return ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(-min * 60)))
    }
    private func item(_ id: String, _ kind: String, _ min: Int, needs: Bool = true, resolved: Bool = false, read: Bool = false) -> InboxItem {
        InboxItem(id: id, kind: kind, title: id, createdAt: at(min), resolved: resolved, read: read, needsYou: needs)
    }

    func testTrayItemsSplitAndOrder() {
        let items = [
            item("a2", "approval", 30), item("a1", "approval", 60), item("q1", "question", 10),
            item("m-ask", "mention", 5), item("gate", "workflow_gate", 2), item("done", "approval", 90, resolved: true),
            item("m-fyi", "mention", 20, needs: false), item("pr", "pr_approved", 50, needs: false, read: true),
            item("sched", "scheduled", 1, needs: false),
        ]
        let t = InboxTray.items(items)
        XCTAssertEqual(t.needs.map(\.id), ["a1", "a2", "q1", "m-ask", "gate"])
        XCTAssertEqual(t.updates.map(\.id), ["sched", "m-fyi", "pr"])
        XCTAssertEqual(t.unread, ["sched", "m-fyi"])
        XCTAssertEqual(InboxTray.items(items, updatesLimit: 1).updates.map(\.id), ["sched"])
    }

    func testActions() {
        XCTAssertEqual(InboxTray.action(kind: "approval"), .approve)
        XCTAssertEqual(InboxTray.action(kind: "question"), .reply)
        XCTAssertEqual(InboxTray.action(kind: "question", hasRun: false), .open(label: "Open"))
        XCTAssertEqual(InboxTray.action(kind: "dispatch"), .dispatch)
        XCTAssertEqual(InboxTray.action(kind: "review"), .open(label: "Open review"))
        XCTAssertEqual(InboxTray.action(kind: "planning"), .open(label: "Review plan"))
        XCTAssertEqual(InboxTray.action(kind: "pr_approved"), .open(label: "Open on GitHub"))
        XCTAssertEqual(InboxTray.action(kind: "pr_ci_failed"), .open(label: "Fix CI"))
        XCTAssertEqual(InboxTray.action(kind: "pr_review_comments"), .open(label: "Address comments"))
        XCTAssertEqual(InboxTray.action(kind: "stalled"), .open(label: "Open run"))
    }

    func testExternalHrefAndReadRules() {
        XCTAssertTrue(InboxTray.isExternalHref("https://github.com/o/r/pull/1"))
        XCTAssertFalse(InboxTray.isExternalHref("/tickets/WEB-4"))
        XCTAssertTrue(InboxTray.shouldMarkRead(item("u", "merged", 1, needs: false)))
        XCTAssertFalse(InboxTray.shouldMarkRead(item("u", "merged", 1, needs: false, read: true)))
        XCTAssertFalse(InboxTray.shouldMarkRead(item("n", "approval", 1)))
        XCTAssertTrue(InboxTray.shouldMarkRead(item("n", "mention", 1)))
        XCTAssertEqual(InboxTray.readRequest("x").path, "/api/v1/inbox/read")
    }
}
