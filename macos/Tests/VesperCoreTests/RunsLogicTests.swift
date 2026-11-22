import XCTest
@testable import VesperCore

private let testCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return c
}()

private let testLocale = Locale(identifier: "en_US")
private let testNow = testCalendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 15))!

private func testISO(_ dayOffset: Int = 0, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> String {
    let date = testCalendar.date(from: DateComponents(
        year: 2026, month: 11, day: 15 - dayOffset, hour: hour, minute: minute, second: second
    ))!
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) -> T {
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(T.self, from: data)
}

private func mkAgent(_ handle: String = "builder", _ name: String = "Builder") -> API.AgentRef {
    API.AgentRef(colorIndex: 0, handle: handle, id: "agent-\(handle)", name: name)
}

private func mkRun(_ id: String, _ over: [String: Any] = [:]) -> API.Run {
    var json: [String: Any] = [
        "id": id,
        "ticket_key": "WEB-1",
        "work_title": "Run \(id)",
        "purpose": "ticket",
        "project_key": "WEB",
        "agent": ["id": "a1", "handle": "builder", "name": "Builder", "color_index": 0],
        "mode": "managed",
        "state": "running",
        "harness": "claude-code",
        "model": "opus",
        "started_at": testISO(0, 12),
        "tool_calls": 2,
        "input_tokens": 1200,
        "output_tokens": 350,
        "cost_usd": 0.42,
        "cost_source": "harness",
        "plan": [],
        "scopes": [],
        "approval_scopes": [],
    ]
    json.merge(over) { $1 }
    return decode(API.Run.self, json)
}

private func mkEvent(_ seq: Int, _ type: String, _ payload: [String: Any] = [:], at: String? = nil) -> API.RunEvent {
    decode(API.RunEvent.self, [
        "seq": seq,
        "type": type,
        "at": at ?? testISO(0, 12, 0, min(59, seq)),
        "payload": payload,
    ])
}

private func mkTurn(_ seq: Int, trigger: String = "start", status: String = "done", exitCode: Int? = 0, hasLog: Bool = true, inputMessage: String = "") -> API.RunTurn {
    var json: [String: Any] = [
        "seq": seq,
        "trigger": trigger,
        "started_at": testISO(0, 12, seq),
        "status": status,
        "has_log": hasLog,
        "input_message": inputMessage,
        "usage": ["input_tokens": 800, "output_tokens": 200, "cost_usd": 0.25, "cost_source": "harness", "tool_calls": 3],
    ]
    if let exitCode { json["exit_code"] = exitCode }
    if status == "done" {
        json["process_started_at"] = testISO(0, 12, seq)
        json["ended_at"] = testISO(0, 12, seq, 30)
    }
    return decode(API.RunTurn.self, json)
}

private func mkApproval(_ id: String, state: String = "pending", preview: String = "rm -rf /tmp/x") -> API.Approval {
    decode(API.Approval.self, [
        "id": id,
        "scope": "shell:exec",
        "action_summary": "Run shell command",
        "risk_summary": "Modifies workspace files",
        "action_preview": preview,
        "state": state,
        "agent": ["id": "a1", "handle": "builder", "name": "Builder", "color_index": 0],
        "ticket_key": "WEB-1",
        "run_id": "r1",
        "brokered": false,
        "created_at": testISO(0, 12),
    ])
}

private func mkInboxItem(_ id: String, kind: String, runId: String? = nil) -> API.InboxItem {
    var json: [String: Any] = [
        "id": id,
        "kind": kind,
        "title": "Item \(id)",
        "summary": "Summary \(id)",
        "href": "/inbox",
        "project": "WEB",
        "ticket_key": "WEB-1",
        "created_at": testISO(0, 11),
        "resolved": false,
        "read": false,
        "needs_you": true,
    ]
    if let runId { json["run_id"] = runId }
    return decode(API.InboxItem.self, json)
}

final class RunsLogicTests: XCTestCase {
    func testViewModesAnchorsAndTabs() {
        XCTAssertEqual(RunsLogic.parseAnchor("#turn-3"), RunsLogic.Anchor(kind: .turn, number: 3))
        XCTAssertEqual(RunsLogic.parseAnchor("event-42"), RunsLogic.Anchor(kind: .event, number: 42))
        XCTAssertNil(RunsLogic.parseAnchor("#turn-x"))
        XCTAssertNil(RunsLogic.parseAnchor("#top"))

        XCTAssertEqual(RunsLogic.pickViewMode(view: nil, tab: nil, anchor: nil), .thread)
        XCTAssertEqual(RunsLogic.pickViewMode(view: "details", tab: nil, anchor: nil), .trace)
        XCTAssertEqual(RunsLogic.pickViewMode(view: nil, tab: "graph", anchor: nil), .graph)
        XCTAssertEqual(RunsLogic.pickViewMode(view: "simple", tab: nil, anchor: RunsLogic.Anchor(kind: .turn, number: 2)), .trace)

        XCTAssertEqual(
            RunsLogic.viewTabs(traceCount: 8, fileCount: 2, childRunCount: 0, mode: .thread).map(\.mode),
            [.thread, .trace, .files]
        )
        XCTAssertEqual(
            RunsLogic.viewTabs(traceCount: 8, fileCount: 0, childRunCount: 1, mode: .thread).map(\.mode),
            [.thread, .trace, .graph, .files]
        )
        XCTAssertEqual(
            RunsLogic.viewTabs(traceCount: 8, fileCount: 0, childRunCount: 0, mode: .graph).map(\.mode),
            [.thread, .trace, .graph, .files]
        )
    }

    func testStatusCharacterWorkHrefAndRunLine() {
        let waitingRun = mkRun("r1", ["state": "waiting", "wait_reason": "approval"])
        XCTAssertEqual(RunsLogic.statusBadge(for: waitingRun), RunsLogic.StatusBadge(label: "Waiting · approval", tone: "human"))
        XCTAssertEqual(RunsLogic.characterState(for: waitingRun), .needsYou)
        XCTAssertTrue(RunsLogic.isLive(waitingRun))

        let runningRun = mkRun("r2", [
            "state": "running",
            "plan": [
                ["position": 1, "text": "Read code", "state": "done"],
                ["position": 2, "text": "Write tests", "state": "current"],
            ],
        ])
        XCTAssertEqual(RunsLogic.characterState(for: runningRun), .coding)
        XCTAssertEqual(RunsLogic.runLine(runningRun), "Step 2 of 2 · Write tests")

        let replyRun = mkRun("r3", ["state": "waiting", "wait_reason": "human_reply", "purpose": "ticket", "ticket_key": "VES-9"])
        XCTAssertTrue(RunsLogic.waitsForReply(replyRun))
        XCTAssertEqual(RunsLogic.workHref(for: replyRun), "/tickets/VES-9")

        let chatReply = mkRun("r4", ["state": "waiting", "wait_reason": "human_reply", "purpose": "chat", "chat_id": "c-1", "project_key": "VES", "ticket_key": ""])
        XCTAssertFalse(RunsLogic.waitsForReply(chatReply))
        XCTAssertEqual(RunsLogic.workHref(for: chatReply), "/chat/c-1?project=VES")

        let noKeyTicket = mkRun("r5", ["purpose": "ticket", "ticket_key": ""])
        XCTAssertNil(RunsLogic.workHref(for: noKeyTicket))
    }

    func testCostUsageCacheAndTokenBreakdown() {
        let parent = mkRun("p", ["cost_usd": 1.25, "cost_source": "harness", "input_tokens": 1000, "cached_input_tokens": 850])
        let child = mkRun("c", ["cost_usd": 0.5, "cost_source": "harness", "model": "sonnet"])
        let detail = API.RunDetail(approvals: [], childRuns: [child], events: [], run: parent, turns: [])

        let cost = RunsLogic.costSummary(for: detail)
        XCTAssertEqual(cost.primary, "$1.25")
        XCTAssertEqual(cost.subSuffix, "+$0.50 sub")
        XCTAssertEqual(cost.combined, "$1.25 (+$0.50 sub)")

        let unpricedChild = mkRun("c2", ["cost_usd": 0.1, "cost_source": "unknown"])
        let detailUnpriced = API.RunDetail(approvals: [], childRuns: [unpricedChild], events: [], run: parent, turns: [])
        XCTAssertEqual(RunsLogic.costSummary(for: detailUnpriced).subSuffix, "≥ +$0.10 sub")

        let models = RunsLogic.usageByModel([parent, child, unpricedChild])
        XCTAssertEqual(models.map(\.model), ["opus", "sonnet"])
        XCTAssertEqual(models[0].summary, "2 runs · ≥ $1.35")

        XCTAssertEqual(RunsLogic.cacheShare(input: 1000, cached: 850), 0.85)
        XCTAssertNil(RunsLogic.cacheShare(input: 0, cached: 0))

        let tb = RunsLogic.tokenBreakdown(eventPayload: [
            "input_tokens": .int(500),
            "output_tokens": .int(120),
            "cached_tokens": .int(400),
        ])
        XCTAssertEqual(tb, RunsLogic.TokenBreakdown(input: 500, output: 120, cached: 400, uncached: 100, unknown: 0, hasBreakdown: true))
        XCTAssertEqual(RunsLogic.compactNumber(2_100_000), "2.1M")
        XCTAssertEqual(RunsLogic.compactNumber(18_400), "18.4K")
        XCTAssertEqual(RunsLogic.compactNumber(420), "420")
    }

    func testGroupRunsNeedsNavigationAndEventsPaging() {
        let runs = [
            mkRun("a", ["state": "running", "started_at": testISO(0, 14)]),
            mkRun("q", ["state": "queued", "started_at": testISO(0, 13)]),
            mkRun("w", ["state": "waiting", "wait_reason": "approval"]),
            mkRun("t", ["state": "completed", "ended_at": testISO(0, 11)]),
            mkRun("y", ["state": "failed", "ended_at": testISO(1, 10)]),
            mkRun("a"),
        ]
        let groups = RunsLogic.groupRuns(runs, skipIds: ["w"], now: testNow, calendar: testCalendar, locale: testLocale)
        XCTAssertEqual(groups.map(\.label), ["Running", "Queued", "Earlier today", "Yesterday"])
        XCTAssertEqual(groups[0].runs.map(\.id), ["a"])
        XCTAssertEqual(groups[1].runs.map(\.id), ["q"])
        XCTAssertEqual(groups[2].runs.map(\.id), ["t"])
        XCTAssertEqual(groups[3].runs.map(\.id), ["y"])

        let items = [mkInboxItem("1", kind: "approval", runId: "r1"), mkInboxItem("2", kind: "question", runId: "r2"), mkInboxItem("3", kind: "mention")]
        XCTAssertEqual(RunsLogic.nextNeedsItem(in: items, afterRunId: "r1")?.id, "2")
        XCTAssertEqual(RunsLogic.nextNeedsItem(in: items, afterRunId: "r2")?.id, "3")
        XCTAssertEqual(RunsLogic.itemHref(items[0], listQuery: "project=WEB"), "/runs/r1?project=WEB")
        XCTAssertEqual(RunsLogic.itemHref(items[2]), "/inbox")

        let slotEvents = [mkEvent(1, "lifecycle", ["state": "starting", "runner": "runner-2", "backend": "microvm"])]
        XCTAssertEqual(RunsLogic.runnerSlot(from: slotEvents)?.runner, "runner-2")
        XCTAssertEqual(RunsLogic.runnerSlot(from: slotEvents)?.backend, "microvm")

        let qEvents = [
            mkEvent(1, "tool_call", ["tool": "mcp__lazyagents__await_human", "input": ["reason": "Which region?"]]),
            mkEvent(2, "lifecycle", ["state": "waiting", "reason": "human_reply"]),
        ]
        XCTAssertEqual(RunsLogic.latestQuestion(from: qEvents), "Which region?")

        let known = (1...40).map { mkEvent($0, "message", ["text": "\($0)"]) }
        XCTAssertEqual(RunsLogic.nextEventsCursor(known: known), 8)
        XCTAssertEqual(RunsLogic.nextEventsCursor(known: Array(known.prefix(10))), 0)
        let merged = RunsLogic.mergeEvents(existing: [known[0], known[2]], incoming: [known[1], known[2], known[3]])
        XCTAssertEqual(merged.map(\.seq), [1, 2, 3, 4])
    }

    func testControlsReplyAndContextDock() {
        let paused = mkRun("r1", ["state": "paused", "mode": "managed"])
        XCTAssertEqual(
            RunsLogic.controlState(for: paused),
            RunsLogic.ControlState(canPause: false, canResume: true, resumeLabel: "Resume", canCancel: true, canRetry: false)
        )
        let failed = mkRun("r2", ["state": "failed", "ticket_key": "WEB-1"])
        XCTAssertTrue(RunsLogic.controlState(for: failed).canRetry)
        XCTAssertFalse(RunsLogic.controlState(for: failed).canCancel)

        XCTAssertNil(RunsLogic.replyCommentRequest(ticketKey: "WEB-1", agentHandle: "builder", body: "   "))
        let commentReq = RunsLogic.replyCommentRequest(ticketKey: "WEB-1", agentHandle: "builder", body: "Ship it")
        XCTAssertEqual(commentReq?.path, "/api/v1/tickets/WEB-1/comments")

        let project = API.Project(archived: false, color: "#555", defaultBranch: "main", id: "p1", key: "WEB", name: "Web", revision: 1)
        let mockupGate = API.MockupGate(approved: false, fromEpic: false, mockups: [], required: false)
        let ticket = API.Ticket(
            approvals: [],
            artifacts: [],
            blockedBy: [],
            blocks: [],
            branch: "feat/runs",
            createdAt: testISO(1),
            criteria: [API.Criterion(done: true, id: "c1", position: 1, text: "Native views"), API.Criterion(done: false, id: "c2", position: 2, text: "Tests pass")],
            dependencyRevision: 1,
            descriptionMd: "desc",
            epic: API.EpicRef(id: "e1", name: "Native App"),
            epicReview: false,
            id: "t1",
            key: "WEB-1",
            labels: [],
            mockupGate: mockupGate,
            pr: API.PullRequest(additions: 40, deletions: 12, number: 580, state: .open, url: "https://github.com/org/repo/pull/580"),
            priority: .high,
            project: project,
            requiresMockup: false,
            revision: 1,
            status: .inProgress,
            title: "Native Runs",
            updatedAt: testISO(0)
        )
        let run = mkRun("r1", [
            "plan": [["position": 1, "text": "Port logic", "state": "done"], ["position": 2, "text": "Build UI", "state": "current"]],
            "cached_input_tokens": 900,
        ])
        let detail = API.RunDetail(approvals: [], childRuns: [mkRun("child1")], events: [], run: run, turns: [mkTurn(1)])
        let dock = RunsLogic.buildContextDock(detail: detail, ticket: ticket, now: testNow, calendar: testCalendar, locale: testLocale)
        XCTAssertEqual(dock.plan.done, 1)
        XCTAssertEqual(dock.plan.total, 2)
        XCTAssertEqual(dock.code?.prNumber, 580)
        XCTAssertEqual(dock.usage.cacheSharePct, 75)
        XCTAssertEqual(dock.rawLogPath, "/api/v1/runs/r1/turns/1/log")
        let sections = RunsLogic.buildInspectorSections(dock: dock, mode: .trace)
        XCTAssertTrue(sections.contains { $0.id == "plan" })
        XCTAssertTrue(sections.contains { $0.id == "usage" })
        XCTAssertTrue(sections.contains { $0.id == "ticket" })
        XCTAssertTrue(sections.contains { $0.id == "code" })
    }

    func testRunThreadLogicFoldsTurnsToolsSubagentsAndTrace() {
        XCTAssertEqual(RunThreadLogic.toolName("mcp__lazyagents__read_page"), "lazyagents.read_page")
        XCTAssertEqual(RunThreadLogic.toolName("Bash"), "Bash")
        XCTAssertEqual(RunThreadLogic.argSummary(.object(["command": .string("swift test")])), "swift test")
        XCTAssertEqual(
            RunThreadLogic.toolLink(tool: "mcp__lazyagents__read_page", input: .object(["ref": .string("Arch/Go")]))?.href,
            "/wiki/Arch/Go"
        )
        XCTAssertEqual(RunThreadLogic.activityKind(forTool: "Bash", input: .object(["command": .string("npm run test")])).kind, .tests)

        let children = [
            mkRun("c1", ["agent": ["id": "a2", "handle": "rev", "name": "Rev", "color_index": 1], "started_at": testISO(0, 12, 0, 11)]),
            mkRun("c2", ["agent": ["id": "a2", "handle": "rev", "name": "Rev", "color_index": 1], "started_at": testISO(0, 12, 0, 13)]),
        ]
        let events: [API.RunEvent] = [
            mkEvent(1, "lifecycle", ["state": "turn_started", "turn": 1]),
            mkEvent(2, "message", ["kind": "thinking", "text": "**Inspecting code**\nDetails here"]),
            mkEvent(3, "message", ["text": "Working on it\nSecond line"]),
            mkEvent(4, "tool_call", ["id": "t4", "tool": "Read", "input": ["file_path": "a.swift"]]),
            mkEvent(5, "tool_result", ["id": "t4", "output": "ok"]),
            mkEvent(6, "message", ["kind": "step", "step": 1, "state": "done"]),
            mkEvent(7, "tool_call", ["id": "t7", "tool": "mcp__lazyagents__delegate", "input": ["agent": "@rev", "task": "Review part 1"]], at: testISO(0, 12, 0, 10)),
            mkEvent(8, "tool_call", ["id": "t8", "tool": "mcp__lazyagents__delegate", "input": ["agent": "@rev", "task": "Review part 2"]], at: testISO(0, 12, 0, 12)),
            mkEvent(9, "error", ["message": "Rate limited"]),
        ]
        let run = mkRun("r1", ["plan": [["position": 1, "text": "Read", "state": "done"]]])
        let detail = API.RunDetail(approvals: [mkApproval("ap1")], childRuns: children, events: events, run: run, turns: [mkTurn(1)])

        let thread = RunThreadLogic.buildThread(detail: detail)
        XCTAssertEqual(thread.pendingApprovals.count, 1)
        XCTAssertEqual(thread.finalMessage, "Working on it\nSecond line")
        XCTAssertEqual(thread.items.count, 6)
        if case .turnHeader(_, let turn, _, let label, _, let tools) = thread.items[0] {
            XCTAssertEqual(turn, 1)
            XCTAssertEqual(label, "Working on it")
            XCTAssertEqual(tools.count, 1)
        } else {
            XCTFail("Expected turnHeader first")
        }
        if case .subagentGroup(_, _, _, let groupItems) = thread.items[4] {
            XCTAssertEqual(groupItems.count, 2)
            XCTAssertEqual(groupItems[0].child?.id, "c1")
            XCTAssertEqual(groupItems[1].child?.id, "c2")
        } else {
            XCTFail("Expected grouped subagents")
        }

        let traceAll = RunThreadLogic.buildTrace(detail: detail)
        XCTAssertEqual(traceAll.counts.all, 7)
        XCTAssertEqual(traceAll.counts.messages, 1)
        XCTAssertEqual(traceAll.counts.tools, 3)
        XCTAssertEqual(traceAll.counts.errors, 1)

        let traceErrors = RunThreadLogic.buildTrace(detail: detail, filter: .errors, search: "rate")
        XCTAssertEqual(traceErrors.groups.count, 1)
        XCTAssertEqual(traceErrors.groups[0].entries.count, 1)
    }

    func testRunFilesLogicDiffParsingAndExtraction() {
        XCTAssertEqual(RunFilesLogic.language(forPath: "macos/Sources/Vesper/App.swift"), "swift")
        XCTAssertEqual(RunFilesLogic.language(forPath: "web/lib/run-graph.ts"), "typescript")
        XCTAssertEqual(RunFilesLogic.language(forPath: "Dockerfile"), "docker")
        XCTAssertNil(RunFilesLogic.language(forPath: "README"))

        XCTAssertEqual(RunFilesLogic.parseHunkHeader("@@ -10,4 +12,6 @@ func test()")?.oldStart, 10)
        XCTAssertEqual(RunFilesLogic.parseHunkHeader("@@ -10,4 +12,6 @@ func test()")?.newStart, 12)
        XCTAssertNil(RunFilesLogic.parseHunkHeader("not a hunk"))

        let patch = """
        @@ -5,3 +5,4 @@
         keep
        -old
        +new1
        +new2
         tail
        """
        let hunks = RunFilesLogic.parseHunks(patch)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].rows.map(\.kind), [.context, .deletion, .addition, .addition, .context])
        XCTAssertEqual(hunks[0].rows[1].oldLine, 6)
        XCTAssertEqual(hunks[0].rows[2].newLine, 6)

        let synth = RunFilesLogic.synthesizeEditDiff(oldString: "a\nb\nc", newString: "a\nB\nC\nc")
        XCTAssertEqual(synth.rows.map(\.kind), [.context, .deletion, .addition, .addition, .context])

        let events: [API.RunEvent] = [
            mkEvent(1, "tool_call", ["id": "r1", "tool": "Read", "input": ["file_path": "b.go"]]),
            mkEvent(2, "tool_result", ["id": "r1", "output": "package main\n"]),
            mkEvent(3, "tool_call", ["id": "e1", "tool": "Edit", "input": ["file_path": "a.swift", "old_string": "let x = 1", "new_string": "let x = 2"]]),
            mkEvent(4, "tool_result", ["id": "e1", "output": "ok"]),
        ]
        let files = RunFilesLogic.extractFiles(from: events)
        XCTAssertEqual(files.map(\.path), ["a.swift", "b.go"])
        XCTAssertTrue(files[0].isChanged)
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[0].language, "swift")
        XCTAssertFalse(files[1].isChanged)
        XCTAssertEqual(files[1].snippets.first?.code, "package main\n")
    }

    func testRunsNavModelAndCommands() {
        var input = RunsNav.Input()
        input.project = "VES"
        input.projects = [("VES", "Vesper", false), ("OLD", "Old", true)]
        input.agents = [("ada", "Ada")]
        input.hideDone = true
        input.search = "bug"
        input.needs = [RunsNav.NeedsRow(id: "n1", title: "Approve", subtitle: "Approval · VES", trailing: "1h", tone: .human)]
        input.groups = [RunsNav.Group(key: "running", label: "Running", count: 1, runs: [
            RunsNav.RunRow(id: "r1", title: "Fix bug", subtitle: "VES-1 · Ada", trailing: "4m", dot: .running),
        ])]
        input.hasMore = true
        input.statusLine = ("1 busy · $2 this week", "/reports")
        input.selectedId = RunsNav.runItemId("r1")

        let model = RunsNav.model(input)
        XCTAssertEqual(model.id, "runs")
        XCTAssertEqual(model.sections.map(\.id), ["status", "needs-you", "runs-running", "more"])
        XCTAssertEqual(model.sections[1].badge, NavBadge(text: "1"))
        XCTAssertEqual(model.sections[2].badge, NavBadge(text: "1"))
        XCTAssertEqual(model.selectedId, "run:r1")

        XCTAssertEqual(RunsNav.action(for: .navSearch(navigatorId: RunsNav.id, searchId: RunsNav.searchId, value: "test")), .search("test"))
        XCTAssertEqual(RunsNav.action(for: .navFilter(navigatorId: RunsNav.id, filterId: RunsNav.optionsFilter, value: RunsNav.hideDoneValue, checked: true)), .toggleHideDone(true))
        XCTAssertEqual(RunsNav.action(for: .navActivate(navigatorId: RunsNav.id, itemId: "run:r1", newTab: true)), .openRun("r1", newTab: true))
        XCTAssertNil(RunsNav.action(for: .navActivate(navigatorId: "work-activity", itemId: "run:r1")))
    }
}
