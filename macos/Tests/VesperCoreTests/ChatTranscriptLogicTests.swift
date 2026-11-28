import XCTest
@testable import VesperCore

final class ChatTranscriptLogicTests: XCTestCase {
    // MARK: - Message Segment Parsing

    func testParsesEmbeddedBlocksAndSpecialCardsInOrder() {
        let uuid1 = "01A1BC65-D1CF-748A-8632-82B3F8BA9C9C"
        let uuid2 = "01a1bc65-d1cf-748a-8632-82b3f8ba9c9d"
        let uuid3 = "01a1bc65-d1cf-748a-8632-82b3f8ba9c9e"
        let body = """
        Here is a quick overview [1].

        ```mermaid
        graph TD
          A --> B
        ```

        $$
        E = mc^2
        $$

        ```chart
        {"type":"bar","title":"Latency","y":{"unit":"ms"},"categories":["P50","P95"],"series":[{"name":"API","values":[12,48]}]}
        ```

        ```choices
        Which database?
        - Postgres | Managed relational
        - SQLite | Single file
        ```

        ```recommend
        https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s
        Great walkthrough
        ```

        ```recommend
        https://example.com/guide
        Reference doc
        ```

        ```workflow-run
        \(uuid1)
        Generate a dungeon battle map
        ```

        ```canvas
        \(uuid2)
        ```

        ```pdf
        \(uuid3)
        ```

        ```research-plan
        Local LLM Benchmarks
        length: detailed
        tone: report
        - Throughput | Tokens per second on M5 Pro
        - Memory | Peak RSS under 4-bit quant
        ```

        ```swift
        let x = 42
        ```

        Sources:
        1. [Vesper Docs](https://example.com/docs)
        2. [[Architecture ADR]]
        """

        let parsed = ChatTranscriptLogic.parseMessage(body)
        XCTAssertEqual(parsed.sources.count, 2)
        XCTAssertEqual(parsed.sources[0], ChatListedSource(title: "Vesper Docs", url: "https://example.com/docs", number: 1))
        XCTAssertEqual(parsed.sources[1], ChatListedSource(title: "", url: "", number: 2, ref: "Architecture ADR"))

        // Expect 11 segments: markdown, mermaid, math, chart, choices, grouped recommend (2), workflowRun, canvas, pdf, researchPlan, swift markdown
        XCTAssertEqual(parsed.segments.count, 11)

        guard case .markdown(let intro) = parsed.segments[0] else { return XCTFail("Expected markdown intro") }
        XCTAssertTrue(intro.contains("[1](cite:1)"))

        XCTAssertEqual(parsed.segments[1], .embedded(.mermaid, source: "graph TD\n  A --> B", info: "mermaid", index: 0))
        XCTAssertEqual(parsed.segments[2], .embedded(.math, source: "E = mc^2", info: "math", index: 1))

        if case .chart(let spec) = parsed.segments[3] {
            XCTAssertEqual(spec.type, .bar)
            XCTAssertEqual(spec.title, "Latency")
            XCTAssertEqual(spec.y.unit, "ms")
            XCTAssertEqual(spec.categories, ["P50", "P95"])
        } else {
            XCTFail("Expected chart segment")
        }

        if case .choices(let card) = parsed.segments[4] {
            XCTAssertEqual(card.question, "Which database?")
            XCTAssertEqual(card.options.map(\.label), ["Postgres", "SQLite"])
        } else {
            XCTFail("Expected choices segment")
        }

        if case .recommend(let recs) = parsed.segments[5] {
            XCTAssertEqual(recs.count, 2)
            XCTAssertEqual(recs[0].youtubeVideoID, "dQw4w9WgXcQ")
            XCTAssertEqual(recs[0].youtubeMomentSeconds, 90)
            XCTAssertEqual(recs[1].url, "https://example.com/guide")
        } else {
            XCTFail("Expected grouped recommend segment")
        }

        XCTAssertEqual(parsed.segments[6], .workflowRun(ChatWorkflowRunCard(workflowID: uuid1.lowercased(), input: "Generate a dungeon battle map")))
        XCTAssertEqual(parsed.segments[7], .canvas(id: uuid2))
        XCTAssertEqual(parsed.segments[8], .pdf(id: uuid3))

        if case .researchPlan(let plan) = parsed.segments[9] {
            XCTAssertEqual(plan.title, "Local LLM Benchmarks")
            XCTAssertEqual(plan.length, .detailed)
            XCTAssertEqual(plan.tone, .report)
            XCTAssertEqual(plan.questions.count, 2)
        } else {
            XCTFail("Expected researchPlan segment")
        }

        if case .markdown(let codeBlock) = parsed.segments[10] {
            XCTAssertTrue(codeBlock.contains("let x = 42"))
        } else {
            XCTFail("Expected ordinary swift fence to remain markdown")
        }
    }

    func testInvalidSpecialFencesFallBackToMarkdown() {
        let body = """
        ```chart
        not valid json
        ```

        ```choices
        Only one option
        - Lone
        ```

        ```canvas
        not-a-uuid
        ```
        """
        let segments = ChatTranscriptLogic.parseSegments(body)
        XCTAssertEqual(segments.count, 2)
        guard case .invalidBlock(let kind, let err, let source) = segments[0] else {
            return XCTFail("Expected invalidBlock for bad chart spec, got \(segments[0])")
        }
        XCTAssertEqual(kind, "chart")
        XCTAssertFalse(err.isEmpty)
        XCTAssertTrue(source.contains("not valid json"))
        guard case .markdown(let text) = segments[1] else { return XCTFail("Expected fallback markdown") }
        XCTAssertTrue(text.contains("Only one option"))
        XCTAssertTrue(text.contains("not-a-uuid"))
    }

    func testReplyBlockActivityLabelsForRicherVisualizations() {
        let pairs: [(String, ActivitySceneKind)] = [
            ("stats", .chart),
            ("diff", .writingCode),
            ("compare", .choices),
            ("timeline", .chart),
            ("tree", .diagram),
            ("compare-images", .image),
            ("graph", .diagram),
            ("plot", .chart),
            ("datatable", .chart),
            ("code-group", .writingCode),
            ("kv", .wiki),
            ("json-tree", .readingCode),
            ("http", .http),
            ("tabs", .wiki),
            ("details", .wiki),
        ]
        for (tag, expectedKind) in pairs {
            let info = ChatTurnActivity.statusOf(tool: "reply_block", input: .object(["kind": .string(tag)]))
            XCTAssertEqual(info.kind, expectedKind, "Unexpected kind for \(tag)")
            XCTAssertFalse(info.phrase.isEmpty)
        }
    }

    // MARK: - Context Stripping, Citations & Mentions

    func testStripsWorkAndKnowledgeContextMarkers() {
        let body = "Please review this"
            + ChatContextMarker.legacyWork
            + "Viewing legacy work item."
            + ChatContextMarker.knowledge
            + "Viewing page Architecture/Chat.md"

        let stripped = ChatTranscriptLogic.stripContext(body)
        XCTAssertEqual(stripped.typedBody, "Please review this")
        XCTAssertEqual(stripped.knowledgeContextLines, ["Viewing page Architecture/Chat.md"])
    }

    func testLinkCitationsSkipsCodeAndInlineCode() {
        let md = """
        Claim [1] and `[1]` and [9].

        ```
        array[1]
        ```
        """
        let linked = ChatTranscriptLogic.linkCitations(md, numbers: [1])
        XCTAssertTrue(linked.contains("Claim [1](cite:1) and `[1]` and [9]."))
        XCTAssertTrue(linked.contains("array[1]"))
        XCTAssertEqual(ChatTranscriptLogic.sourceSplitLabel(vesper: 2, web: 3), "2 in Vesper · 3 from the web")
        XCTAssertEqual(ChatTranscriptLogic.summaryText("Answer [1].\n\nSources:\n1. https://example.com"), "Answer.")
    }

    func testMultiPersonaMentionParsing() {
        let text = """
        Hey @Tech Lead and @Meow, check foo@bar.com and `@Dr. Mara`!
        ```
        @IgnoredInFence
        ```
        Also ping @Dr. Mara please.
        """
        let mentions = ChatTranscriptLogic.parseMentions(in: text, knownNames: ["Tech Lead", "Dr. Mara", "Meow"])
        XCTAssertEqual(mentions, ["Tech Lead", "Meow", "Dr. Mara"])
    }

    // MARK: - ChatChartSpec

    func testChartValidationAndFormatting() {
        // Invalid JSON
        if case .failure(let err) = ChatChartSpec.parse("{bad") {
            XCTAssertEqual(err.message, "This chart isn't valid JSON.")
        } else { XCTFail("Expected failure") }

        // Scatter chart with 2 series and table rows
        let scatterJSON = """
        {
          "type": "scatter",
          "title": "Cost vs Speed",
          "x": {"label": "Tokens"},
          "y": {"label": "Cost", "unit": "$"},
          "series": [
            {"name": "Fast", "points": [[1000, 0.25], [2500, 0.5]]},
            {"name": "Deep", "points": [[1000, 1.5]]}
          ]
        }
        """
        guard case .success(let spec) = ChatChartSpec.parse(scatterJSON) else {
            return XCTFail("Expected valid scatter spec")
        }
        let table = spec.tableRows()
        XCTAssertEqual(table.headers, ["Series", "Tokens", "Cost"])
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.rows[0], ["Fast", "1K", "$0.25"])

        // Line chart with gap
        let lineJSON = """
        {"type":"line","y":{"unit":"%"},"categories":["Jan","Feb","Mar"],"series":[{"name":"Uptime","values":[99.9,null,99.5]}]}
        """
        guard case .success(let lineSpec) = ChatChartSpec.parse(lineJSON) else {
            return XCTFail("Expected valid line spec")
        }
        XCTAssertEqual(lineSpec.tableRows().rows[1], ["Feb", "—"])

        // Compact numbers, units, and nice ticks
        XCTAssertEqual(ChatChartSpec.compactNumber(2_500_000), "2.5M")
        XCTAssertEqual(ChatChartSpec.compactNumber(1_000), "1K")
        XCTAssertEqual(ChatChartSpec.withUnit("-12", unit: "$"), "-$12")
        XCTAssertEqual(ChatChartSpec.withUnit("98.5", unit: "%"), "98.5%")
        XCTAssertEqual(ChatChartSpec.withUnit("42", unit: "ms"), "42 ms")
        let ticks = ChatChartSpec.niceTicks(min: 0, max: 87, count: 5)
        XCTAssertEqual(ticks.first, 0)
        XCTAssertGreaterThanOrEqual(ticks.last ?? 0, 87)
    }

    // MARK: - ChatCardsLogic

    func testCardsHelpersAndStatusSlot() {
        let choices = ChatChoicesCard(question: "Pick", options: [
            ChatChoicesCard.Option(label: "Option [A]"),
            ChatChoicesCard.Option(label: "Option B"),
        ])
        XCTAssertEqual(ChatChoicesCard.choicePrompt("Option [A]"), "Going with: Option A")
        XCTAssertEqual(choices.chosenOption(nextMessageBody: "Going with: Option A"), "Option [A]")

        XCTAssertEqual(ChatRecommendCard.videoEmbedURL(id: "dQw4w9WgXcQ"), "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0")
        XCTAssertNil(ChatRecommendCard.videoEmbedURL(id: "short"))
        let prompt = ChatRecommendCard.summarizePrompt(url: "https://example.com", title: "My [Page]", isVideo: false)
        XCTAssertEqual(prompt, "Summarize this page: [My Page](https://example.com)")
        XCTAssertEqual(ChatRecommendCard.summaryRequestURL(from: prompt), "https://example.com")

        // Status slot priority ordering and collapsing
        let entries = [
            ChatStatusSlotEntry(key: "live-1", kind: .live),
            ChatStatusSlotEntry(key: "block-1", kind: .blocking),
            ChatStatusSlotEntry(key: "needs-1", kind: .needsYou, pinned: true),
            ChatStatusSlotEntry(key: "err-1", kind: .error),
        ]
        let split = ChatStatusSlotEntry.split(entries, expanded: false)
        XCTAssertEqual(split.shown.map(\.key), ["block-1", "needs-1"])
        XCTAssertEqual(split.hidden.map(\.key), ["err-1", "live-1"])

        // Media & proposal display helpers
        XCTAssertEqual(ChatCardDisplay.mediaStageStates(stages: ChatCardDisplay.audioStages, currentStage: "render", state: "running"), [.done, .active, .pending, .pending])
        XCTAssertEqual(ChatCardDisplay.waveBars(peaks: nil, count: 4), [0.08, 0.08, 0.08, 0.08])
        XCTAssertEqual(ChatCardDisplay.mediaClock(ms: 65_000), "1:05")
        XCTAssertEqual(ChatCardDisplay.videoPlannedMeta(width: 1920, height: 1080, fps: 30, durationMs: 15_000), "1920×1080 · 30 fps · 15 s")
        XCTAssertFalse(ChatCardDisplay.canApprovePersonaProposal(state: "pending", avatarState: "pending"))
        XCTAssertTrue(ChatCardDisplay.canApprovePersonaProposal(state: "pending", avatarState: "ready"))
        XCTAssertEqual(ChatCardDisplay.secretSentAs(placement: "bearer", key: "", handle: "github"), "Authorization: Bearer ‹github›")
    }

    // MARK: - ChatTurnActivity

    func testTurnActivityFoldingAndStepRail() {
        XCTAssertEqual(ChatTurnActivity.bareTool("mcp__lazyagents__read_page"), "read_page")
        XCTAssertEqual(ChatTurnActivity.bareTool("mcp__github__create_pull_request"), "github.create_pull_request")
        XCTAssertEqual(ChatTurnActivity.statusOf(tool: "Bash", input: .object(["command": .string("go test ./...")])).kind, .tests)
        XCTAssertEqual(ChatTurnActivity.statusOf(tool: "reply_block", input: .object(["kind": .string("chart")])).kind, .chart)

        let events: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "message", at: "2026-11-22T05:00:01Z", payload: ["role": .string("assistant"), "text": .string("Let me check the tests.")]),
            ChatRunEvent(seq: 2, type: "tool_call", at: "2026-11-22T05:00:02Z", payload: ["id": .string("c1"), "tool": .string("Read"), "input": .object(["file_path": .string("a.swift")])]),
            ChatRunEvent(seq: 3, type: "tool_result", at: "2026-11-22T05:00:04Z", payload: ["id": .string("c1"), "output": .string("ok")]),
            ChatRunEvent(seq: 4, type: "tool_call", at: "2026-11-22T05:00:05Z", payload: ["id": .string("c2"), "tool": .string("Bash"), "input": .object(["command": .string("swift test")])]),
        ]
        let now = APIDate.parse("2026-11-22T05:00:20Z")!
        let activity = ChatTurnActivity.fold(events: events, since: "2026-11-22T05:00:00Z", now: now)

        XCTAssertEqual(activity.openingLine, "Let me check the tests.")
        XCTAssertEqual(activity.status.kind, .tests)
        XCTAssertEqual(activity.steps.count, 2)
        XCTAssertEqual(activity.steps[0].kind, .readingCode)
        XCTAssertEqual(activity.steps[0].state, .done)
        XCTAssertEqual(activity.steps[1].kind, .tests)
        XCTAssertEqual(activity.steps[1].state, .active)
        XCTAssertEqual(activity.elapsedMs, 20_000)
        XCTAssertFalse(activity.between)
        XCTAssertFalse(activity.quiet)
        XCTAssertEqual(ChatTurnActivity.formatSpan(ms: 245_000), "4m 05s")
        XCTAssertEqual(ChatTurnActivity.replyCost(0.0004), "< $0.001")
        XCTAssertEqual(ChatTurnActivity.replyCost(0.042), "$0.042")
        XCTAssertEqual(ChatTurnActivity.replyCost(1.5), "$1.50")
    }

    func testRunningSinceAndTurnWindowsScopeSharedRunPerTurn() {
        func msg(
            id: String,
            role: API.ChatMessage.Role,
            at: String,
            seq: Int,
            runId: String? = nil,
            turnSeq: Int? = nil
        ) -> API.ChatMessage {
            API.ChatMessage(bodyMd: id, createdAt: at, id: id, role: role, runId: runId, seq: seq, turnSeq: turnSeq)
        }

        let t0 = "2026-11-22T05:00:00Z"
        let t1 = "2026-11-22T05:01:00Z"
        let t2 = "2026-11-22T05:02:00Z"
        let t3 = "2026-11-22T05:03:00Z"
        let t4 = "2026-11-22T05:04:00Z"
        let t5 = "2026-11-22T05:05:00Z"

        let u1 = msg(id: "u1", role: .user, at: t0, seq: 1, runId: "r1", turnSeq: 1)
        let s1 = msg(id: "s1", role: .user, at: t1, seq: 2) // mid-turn steer
        let a1 = msg(id: "a1", role: .assistant, at: t2, seq: 3, runId: "r1", turnSeq: 1)
        let u2 = msg(id: "u2", role: .user, at: t3, seq: 4, runId: "r1", turnSeq: 2)
        let a2 = msg(id: "a2", role: .assistant, at: t4, seq: 5, runId: "r1", turnSeq: 2)
        let f2 = msg(id: "f2", role: .assistant, at: t5, seq: 6, runId: "r1", turnSeq: 3) // automatic follow-up

        // Mid-turn steer keeps the starting user message as runningSince.
        XCTAssertEqual(ChatTurnActivity.runningSince(for: []), nil)
        XCTAssertEqual(ChatTurnActivity.runningSince(for: [u1]), t0)
        XCTAssertEqual(ChatTurnActivity.runningSince(for: [u1, s1]), t0)
        // New user message resets runningSince to the new turn even when sharing runId "r1".
        XCTAssertEqual(ChatTurnActivity.runningSince(for: [u1, s1, a1, u2]), t3)
        // Automatic follow-up starts after the prior reply.
        XCTAssertEqual(ChatTurnActivity.runningSince(for: [u1, s1, a1, u2, a2]), t4)

        let windows = ChatTurnActivity.turnWindows(for: [u1, s1, a1, u2, a2, f2])
        XCTAssertEqual(windows["a1"], ChatTurnWindow(since: t0, until: t3, followup: false))
        XCTAssertEqual(windows["a2"], ChatTurnWindow(since: t3, until: t4, followup: false))
        XCTAssertEqual(windows["f2"], ChatTurnWindow(since: t4, until: nil, followup: true))
    }

    func testLiveFoldResetsForNewTurnOnSharedRunAndSkipsSubagentChildCalls() {
        let turn1Events: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "message", at: "2026-11-22T05:00:01Z", payload: ["role": .string("assistant"), "text": .string("Checking SVGs from turn 1.")]),
            ChatRunEvent(seq: 2, type: "tool_call", at: "2026-11-22T05:00:02Z", payload: ["id": .string("c1"), "tool": .string("generate_image"), "input": .object([:])]),
            ChatRunEvent(seq: 3, type: "tool_result", at: "2026-11-22T05:00:05Z", payload: ["id": .string("c1"), "is_error": .bool(true)]),
            ChatRunEvent(seq: 4, type: "tool_call", at: "2026-11-22T05:00:06Z", payload: ["id": .string("c2"), "tool": .string("request_push"), "input": .object([:])]),
            ChatRunEvent(seq: 5, type: "tool_result", at: "2026-11-22T05:00:08Z", payload: ["id": .string("c2"), "output": .string("ok")]),
        ]
        let turn2Events: [ChatRunEvent] = [
            ChatRunEvent(seq: 6, type: "tool_call", at: "2026-11-22T05:25:01Z", payload: ["id": .string("sub1"), "tool": .string("Read"), "subagent": .bool(true)]),
            ChatRunEvent(seq: 7, type: "tool_result", at: "2026-11-22T05:25:02Z", payload: ["id": .string("sub1"), "subagent": .bool(true)]),
            ChatRunEvent(seq: 8, type: "message", at: "2026-11-22T05:25:03Z", payload: ["role": .string("assistant"), "text": .string("Generating video examples now.")]),
            ChatRunEvent(seq: 9, type: "tool_call", at: "2026-11-22T05:25:04Z", payload: ["id": .string("c3"), "tool": .string("start_video"), "input": .object([:])]),
        ]
        let allEvents = turn1Events + turn2Events
        let turn2Start = "2026-11-22T05:25:00Z"

        // Before turn 2 emits any events, live card scoped to turn2Start starts completely fresh.
        let fresh = ChatTurnActivity.fold(
            events: turn1Events,
            since: turn2Start,
            now: APIDate.parse("2026-11-22T05:25:03Z")!
        )
        XCTAssertNil(fresh.openingLine)
        XCTAssertTrue(fresh.steps.isEmpty)
        XCTAssertEqual(fresh.status.kind, .thinking)
        XCTAssertEqual(fresh.elapsedMs, 3_000)

        // Once turn 2 runs, it sees only turn 2's opening line, steps, and elapsed time — never turn 1 or subagent child tools.
        let active = ChatTurnActivity.fold(
            events: allEvents,
            since: turn2Start,
            now: APIDate.parse("2026-11-22T05:25:10Z")!
        )
        XCTAssertEqual(active.openingLine, "Generating video examples now.")
        XCTAssertEqual(active.status.kind, .videoRender)
        XCTAssertEqual(active.steps.map(\.kind), [.videoRender])
        XCTAssertEqual(active.elapsedMs, 10_000)

        // Turn 1's finished card keeps its own steps in history, bounded by turn 1's reply time.
        let finishedTurn1 = ChatTurnActivity.finishedTurn(
            events: allEvents,
            outcome: .done,
            since: "2026-11-22T05:00:00Z",
            until: "2026-11-22T05:00:12Z",
            end: APIDate.epoch("2026-11-22T05:00:12Z")
        )
        XCTAssertEqual(finishedTurn1.steps.map(\.kind), [.image, .push])
        XCTAssertEqual(finishedTurn1.steps.map(\.state), [.failed, .done])
        XCTAssertEqual(finishedTurn1.durationMs, 12_000)
        XCTAssertEqual(
            ChatTurnActivity.finishedSummary(outcome: .done, stepCount: finishedTurn1.steps.count, durationMs: finishedTurn1.durationMs),
            "Worked for 12s · 2 steps"
        )
    }

    func testEndedTurnsAndFinishedTurnOutcomesAndBookkeepingFilter() {
        func msg(
            id: String,
            role: API.ChatMessage.Role,
            at: String,
            seq: Int,
            runId: String? = nil,
            turnSeq: Int? = nil
        ) -> API.ChatMessage {
            API.ChatMessage(bodyMd: id, createdAt: at, id: id, role: role, runId: runId, seq: seq, turnSeq: turnSeq)
        }

        let t0 = "2026-11-22T06:00:00Z"
        let t1 = "2026-11-22T06:00:10Z"
        let t2 = "2026-11-22T06:00:20Z"
        let t3 = "2026-11-22T06:00:30Z"
        let t4 = "2026-11-22T06:00:40Z"
        let t5 = "2026-11-22T06:00:50Z"

        let messages = [
            msg(id: "u1", role: .user, at: t0, seq: 1, runId: "r1", turnSeq: 1),
            msg(id: "a1", role: .assistant, at: t1, seq: 2, runId: "r1", turnSeq: 1),
            msg(id: "u2", role: .user, at: t2, seq: 3, runId: "r1", turnSeq: 2),
            msg(id: "f2", role: .system, at: t3, seq: 4, runId: "r1", turnSeq: 2),
            msg(id: "note", role: .system, at: t3, seq: 5), // non-failure note
            msg(id: "u3", role: .user, at: t4, seq: 6, runId: "r2", turnSeq: 1),
            msg(id: "u4", role: .user, at: t5, seq: 7, runId: "r2", turnSeq: 2),
        ]

        let endedIdle = ChatTurnActivity.endedTurns(for: messages, running: false)
        XCTAssertEqual(endedIdle["f2"], ChatEndedTurn(outcome: .failed, since: t2, until: t3, end: APIDate.epoch(t3)))
        XCTAssertEqual(endedIdle["u3"], ChatEndedTurn(outcome: .stopped, since: t4, until: t5))
        XCTAssertEqual(endedIdle["u4"], ChatEndedTurn(outcome: .stopped, since: t5))
        XCTAssertNil(endedIdle["u1"])
        XCTAssertNil(endedIdle["note"])

        // While running, the newest unanswered user message belongs to the live card, not endedTurns.
        let endedRunning = ChatTurnActivity.endedTurns(for: messages, running: true)
        XCTAssertNil(endedRunning["u4"])
        XCTAssertNotNil(endedRunning["u3"])

        let windows = ChatTurnActivity.turnWindows(for: messages)
        XCTAssertEqual(
            ChatTurnActivity.historicalRunIds(for: messages, turnWindows: windows, endedTurns: endedIdle),
            ["r1", "r2"]
        )

        // Bookkeeping-only turns produce no finished strip.
        let bookkeepingOnly: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "tool_call", at: t0, payload: ["id": .string("b1"), "tool": .string("set_chat_title")]),
            ChatRunEvent(seq: 2, type: "tool_result", at: t1, payload: ["id": .string("b1")]),
            ChatRunEvent(seq: 3, type: "lifecycle", at: t1, payload: ["state": .string("reply_block"), "kind": .string("choices")]),
        ]
        XCTAssertTrue(ChatTurnActivity.finishedTurn(events: bookkeepingOnly, outcome: .done).steps.isEmpty)

        // Failed turn marks its active step failed and folds earlier steps before the first failure.
        let failedEvents: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "tool_call", at: "2026-11-22T06:00:21Z", payload: ["id": .string("c1"), "tool": .string("Read")]),
            ChatRunEvent(seq: 2, type: "tool_result", at: "2026-11-22T06:00:23Z", payload: ["id": .string("c1")]),
            ChatRunEvent(seq: 3, type: "tool_call", at: "2026-11-22T06:00:24Z", payload: ["id": .string("c2"), "tool": .string("Bash"), "input": .object(["command": .string("swift test")])]),
        ]
        let failed = ChatTurnActivity.finishedTurn(events: failedEvents, outcome: .failed, since: t2, until: t3, end: APIDate.epoch(t3))
        XCTAssertEqual(failed.steps.map(\.state), [.done, .failed])
        XCTAssertEqual(failed.durationMs, 10_000)
        let foldedFailure = ChatTurnActivity.foldStepsFromFailure(failed.steps)
        XCTAssertEqual(foldedFailure.earlier, 1)
        XCTAssertEqual(foldedFailure.shown.map(\.state), [.failed])
        XCTAssertEqual(ChatTurnActivity.finishedSummary(outcome: .failed, stepCount: 1, durationMs: 500), "Failed · 1 step")
        XCTAssertEqual(ChatTurnActivity.finishedSummary(outcome: .stopped, stepCount: 2, durationMs: 5_000), "Stopped after 5s · 2 steps")
    }

    func testSplitPhaseTimersAndPureThinkingDurationMath() {
        let t0 = "2026-11-22T07:00:00Z"
        let ts: (Int) -> String = { sec in
            let m = sec / 60
            let s = sec % 60
            return String(format: "2026-11-22T07:%02d:%02dZ", m, s)
        }
        let date: (Int) -> Date = { APIDate.parse(ts($0))! }

        // 1. Initial thinking with heartbeats: phaseElapsed counts continuously from t0 (heartbeats don't reset it).
        let thinkingOnly: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "lifecycle", at: ts(2), payload: ["state": .string("activity"), "phase": .string("thinking"), "detail": .string("Checking architecture")]),
            ChatRunEvent(seq: 2, type: "lifecycle", at: ts(10), payload: ["state": .string("activity"), "phase": .string("thinking")]),
        ]
        let f1 = ChatTurnActivity.fold(events: thinkingOnly, since: t0, now: date(12))
        XCTAssertEqual(f1.timingPhase, .thinking)
        XCTAssertEqual(f1.elapsedMs, 12_000)
        XCTAssertEqual(f1.phaseElapsedMs, 12_000)
        XCTAssertEqual(f1.thinkingDurationMs, 12_000)
        XCTAssertEqual(f1.activePhase, .thinking(detail: "Checking architecture"))

        // 2. Transition into an active tool resets phaseElapsed and freezes thinkingDurationMs.
        let duringTool = thinkingOnly + [
            ChatRunEvent(seq: 3, type: "message", at: ts(12), payload: ["kind": .string("thinking"), "text": .string("**Running tests**\nNeed baseline output.")]),
            ChatRunEvent(seq: 4, type: "tool_call", at: ts(12), payload: ["id": .string("c1"), "tool": .string("Bash"), "input": .object(["command": .string("swift test")])]),
        ]
        let f2 = ChatTurnActivity.fold(events: duringTool, since: t0, now: date(30))
        XCTAssertEqual(f2.timingPhase, .tool)
        XCTAssertEqual(f2.status.kind, .tests)
        XCTAssertEqual(f2.elapsedMs, 30_000)
        XCTAssertEqual(f2.phaseElapsedMs, 18_000)
        XCTAssertEqual(f2.thinkingDurationMs, 12_000)
        XCTAssertEqual(f2.thinkingBlocks.count, 1)
        XCTAssertEqual(f2.thinkingBlocks[0].heading, "Running tests")

        // 3. Tool finishes -> transitions back to thinking and resets phaseElapsed.
        let backToThinking = duringTool + [
            ChatRunEvent(seq: 5, type: "tool_result", at: ts(30), payload: ["id": .string("c1"), "output": .string("pass")]),
        ]
        let f3 = ChatTurnActivity.fold(events: backToThinking, since: t0, now: date(35))
        XCTAssertEqual(f3.timingPhase, .thinking)
        XCTAssertEqual(f3.elapsedMs, 35_000)
        XCTAssertEqual(f3.phaseElapsedMs, 5_000)
        XCTAssertEqual(f3.thinkingDurationMs, 17_000) // 12s + 5s, excluding 18s Bash

        // 4. Parallel multi-tool burst + subagent child events + reply streaming excluded from thinking.
        let fullTurn = backToThinking + [
            ChatRunEvent(seq: 6, type: "tool_call", at: ts(37), payload: ["id": .string("c2"), "tool": .string("Read"), "input": .object(["file_path": .string("a.swift")])]),
            ChatRunEvent(seq: 7, type: "tool_call", at: ts(38), payload: ["id": .string("c3"), "tool": .string("Grep"), "input": .object(["pattern": .string("foo")])]),
            ChatRunEvent(seq: 8, type: "tool_call", at: ts(39), payload: ["id": .string("sub1"), "tool": .string("Read"), "subagent": .bool(true)]),
            ChatRunEvent(seq: 9, type: "tool_result", at: ts(40), payload: ["id": .string("sub1"), "subagent": .bool(true)]),
            ChatRunEvent(seq: 10, type: "tool_result", at: ts(41), payload: ["id": .string("c2"), "output": .string("ok")]),
            // c3 still open until ts(44) -> stays in .tool phase!
            ChatRunEvent(seq: 11, type: "tool_result", at: ts(44), payload: ["id": .string("c3"), "output": .string("ok")]),
            ChatRunEvent(seq: 12, type: "message", at: ts(47), payload: ["kind": .string("thinking"), "text": .string("## Summarizing\nAll good.")]),
            ChatRunEvent(seq: 13, type: "lifecycle", at: ts(48), payload: ["state": .string("activity"), "phase": .string("writing_reply")]),
            ChatRunEvent(seq: 14, type: "lifecycle", at: ts(52), payload: ["state": .string("reply_block"), "kind": .string("chart")]),
            ChatRunEvent(seq: 15, type: "message", at: ts(56), payload: ["role": .string("assistant"), "text": .string("Here are the results.")]),
        ]
        // Mid-parallel check at ts(42): c2 closed, c3 still open -> still .tool since ts(37).
        let midParallel = ChatTurnActivity.fold(events: Array(fullTurn.prefix(10)), since: t0, now: date(42))
        XCTAssertEqual(midParallel.timingPhase, .tool)
        XCTAssertEqual(midParallel.phaseElapsedMs, 5_000)
        XCTAssertEqual(midParallel.thinkingDurationMs, 19_000) // 12s + 7s

        // Writing reply excludes streaming time from thinking.
        let duringReply = ChatTurnActivity.fold(events: Array(fullTurn.prefix(13)), since: t0, now: date(51))
        XCTAssertEqual(duringReply.timingPhase, .writingReply)
        XCTAssertEqual(duringReply.phaseElapsedMs, 3_000)
        XCTAssertEqual(duringReply.thinkingDurationMs, 23_000) // 12s + 7s + 4s

        // Finished turn: total = 60s, pure thinking = 12 + 7 + 4 = 23s (excludes 18s Bash, 7s parallel tools, 12s reply streaming).
        let finished = ChatTurnActivity.finishedTurn(
            events: fullTurn,
            outcome: .done,
            since: t0,
            until: ts(60),
            end: APIDate.epoch(ts(60))
        )
        XCTAssertEqual(finished.durationMs, 60_000)
        XCTAssertEqual(finished.thinkingDurationMs, 23_000)
        XCTAssertEqual(finished.thinkingBlocks.count, 2)
        XCTAssertEqual(finished.thinkingBlocks[1].heading, "Summarizing")
        XCTAssertEqual(
            ChatTurnActivity.finishedSummary(
                outcome: .done,
                stepCount: finished.steps.count,
                durationMs: finished.durationMs,
                thinkingDurationMs: finished.thinkingDurationMs
            ),
            "Worked for 1m 00s · Thought for 23s · 4 steps"
        )

        // Reasoning-only turn (no tool calls) keeps steps empty while recording thinkingDurationMs and thinkingBlocks.
        let thoughtOnlyEvents: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "lifecycle", at: ts(1), payload: ["state": .string("activity"), "phase": .string("thinking")]),
            ChatRunEvent(seq: 2, type: "message", at: ts(9), payload: ["kind": .string("thinking"), "text": .string("Just thinking.")]),
            ChatRunEvent(seq: 3, type: "lifecycle", at: ts(9), payload: ["state": .string("activity"), "phase": .string("writing_reply")]),
        ]
        let thoughtOnly = ChatTurnActivity.finishedTurn(
            events: thoughtOnlyEvents,
            outcome: .done,
            since: t0,
            until: ts(14),
            end: APIDate.epoch(ts(14))
        )
        XCTAssertTrue(thoughtOnly.steps.isEmpty)
        XCTAssertEqual(thoughtOnly.durationMs, 14_000)
        XCTAssertEqual(thoughtOnly.thinkingDurationMs, 9_000)
        XCTAssertEqual(thoughtOnly.thinkingBlocks.map(\.text), ["Just thinking."])
    }

    private func planEvent(_ seq: Int, _ rows: [(String, String)], subagent: Bool = false) -> ChatRunEvent {
        var payload: [String: JSONValue] = [
            "state": .string("plan"),
            "source": .string("codex"),
            "steps": .array(rows.enumerated().map { i, row in
                .object(["id": .string(String(i + 1)), "title": .string(row.0), "status": .string(row.1)])
            }),
        ]
        if subagent { payload["subagent"] = .bool(true) }
        return ChatRunEvent(seq: seq, type: "lifecycle", at: String(format: "2026-11-22T08:00:%02dZ", seq), payload: payload)
    }

    /// Codex and Antigravity have no TodoWrite calls: their plan reaches the client only as the server's plan events
    /// (mirrors "a server plan event drives the steps…" in web/lib/chat-ui.test.mjs).
    func testServerPlanEventsDriveStepsWithoutPlanToolCalls() {
        let events: [ChatRunEvent] = [
            planEvent(1, [("Find it", "in_progress"), ("Fix it", "pending")]),
            ChatRunEvent(seq: 2, type: "tool_call", at: "2026-11-22T08:00:02Z", payload: ["id": .string("c2"), "tool": .string("shell"), "input": .object(["command": .string("rg retry")])]),
            ChatRunEvent(seq: 3, type: "tool_result", at: "2026-11-22T08:00:03Z", payload: ["id": .string("c2")]),
            planEvent(4, [("Find it", "completed"), ("Fix it", "in_progress")]),
            ChatRunEvent(seq: 5, type: "tool_call", at: "2026-11-22T08:00:05Z", payload: ["id": .string("c5"), "tool": .string("apply_patch"), "input": .object(["files": .array([.string("update poller.go")])])]),
        ]
        let folded = ChatTurnActivity.fold(events: events, since: "2026-11-22T08:00:00Z", now: APIDate.parse("2026-11-22T08:00:06Z")!)
        XCTAssertTrue(folded.planned)
        XCTAssertEqual(folded.steps.map(\.title), ["Find it", "Fix it"])
        XCTAssertEqual(folded.steps.map(\.state), [.done, .active])
        XCTAssertEqual(ChatTurnActivity.planProgress(steps: folded.steps, planned: folded.planned)?.progressLabel, "1/2 steps")

        // A sub agent's plan isn't the turn's, and an empty plan clears it.
        let other = ChatTurnActivity.fold(
            events: [planEvent(1, [("Theirs", "pending")], subagent: true), events[1], events[2]],
            since: "2026-11-22T08:00:00Z", now: APIDate.parse("2026-11-22T08:00:06Z")!
        )
        XCTAssertFalse(other.planned)
        let cleared = ChatTurnActivity.fold(
            events: events + [planEvent(6, [])],
            since: "2026-11-22T08:00:00Z", now: APIDate.parse("2026-11-22T08:00:07Z")!
        )
        XCTAssertFalse(cleared.planned)
    }

    func testServerPlanEventsWinOverRawTodoWriteAndFinishedTurnReadsThem() {
        let events: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "tool_call", at: "2026-11-22T08:00:01Z", payload: [
                "id": .string("p1"), "tool": .string("TodoWrite"),
                "input": .object(["todos": .array([.object(["content": .string("Raw title"), "status": .string("in_progress")])])]),
            ]),
            ChatRunEvent(seq: 2, type: "tool_result", at: "2026-11-22T08:00:02Z", payload: ["id": .string("p1")]),
            planEvent(3, [("Server title", "in_progress")]),
            ChatRunEvent(seq: 4, type: "tool_call", at: "2026-11-22T08:00:04Z", payload: ["id": .string("c4"), "tool": .string("set_plan"), "input": .object([:])]),
            ChatRunEvent(seq: 5, type: "tool_result", at: "2026-11-22T08:00:05Z", payload: ["id": .string("c4")]),
            ChatRunEvent(seq: 6, type: "tool_call", at: "2026-11-22T08:00:06Z", payload: ["id": .string("c6"), "tool": .string("Read"), "input": .object(["file_path": .string("/r/a.go")])]),
            ChatRunEvent(seq: 7, type: "tool_result", at: "2026-11-22T08:00:07Z", payload: ["id": .string("c6")]),
            planEvent(8, [("Server title", "failed")]),
        ]
        let finished = ChatTurnActivity.finishedTurn(events: events, outcome: .done)
        XCTAssertEqual(finished.steps.map(\.title), ["Server title"])
        XCTAssertEqual(finished.steps.map(\.state), [.failed])
    }

    func testPlanProgressWithFailedStepsAndLongTurnUsageDelay() {
        let t0 = "2026-11-22T08:00:00Z"
        let events: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "tool_call", at: "2026-11-22T08:00:01Z", payload: [
                "id": .string("p1"),
                "tool": .string("TodoWrite"),
                "input": .object(["todos": .array([
                    .object(["content": .string("Inspect code"), "status": .string("in_progress")]),
                    .object(["content": .string("Run tests"), "status": .string("pending")]),
                    .object(["content": .string("Ship fix"), "status": .string("pending")]),
                ])]),
            ]),
            ChatRunEvent(seq: 2, type: "tool_result", at: "2026-11-22T08:00:02Z", payload: ["id": .string("p1")]),
            ChatRunEvent(seq: 3, type: "tool_call", at: "2026-11-22T08:00:03Z", payload: ["id": .string("c1"), "tool": .string("Read")]),
            ChatRunEvent(seq: 4, type: "tool_result", at: "2026-11-22T08:00:04Z", payload: ["id": .string("c1")]),
            ChatRunEvent(seq: 5, type: "tool_call", at: "2026-11-22T08:00:05Z", payload: [
                "id": .string("p2"),
                "tool": .string("TodoWrite"),
                "input": .object(["todos": .array([
                    .object(["content": .string("Inspect code"), "status": .string("completed")]),
                    .object(["content": .string("Run tests"), "status": .string("in_progress")]),
                    .object(["content": .string("Ship fix"), "status": .string("pending")]),
                ])]),
            ]),
            ChatRunEvent(seq: 6, type: "tool_result", at: "2026-11-22T08:00:06Z", payload: ["id": .string("p2")]),
            ChatRunEvent(seq: 7, type: "tool_call", at: "2026-11-22T08:00:07Z", payload: ["id": .string("c2"), "tool": .string("Bash"), "input": .object(["command": .string("swift test")])]),
            ChatRunEvent(seq: 8, type: "tool_result", at: "2026-11-22T08:00:10Z", payload: ["id": .string("c2"), "is_error": .bool(true)]),
            ChatRunEvent(seq: 9, type: "tool_call", at: "2026-11-22T08:00:11Z", payload: [
                "id": .string("p3"),
                "tool": .string("TodoWrite"),
                "input": .object(["todos": .array([
                    .object(["content": .string("Inspect code"), "status": .string("completed")]),
                    .object(["content": .string("Run tests"), "status": .string("completed")]),
                    .object(["content": .string("Ship fix"), "status": .string("in_progress")]),
                ])]),
            ]),
            ChatRunEvent(seq: 10, type: "tool_result", at: "2026-11-22T08:00:12Z", payload: ["id": .string("p3")]),
        ]

        let folded = ChatTurnActivity.fold(events: events, since: t0, now: APIDate.parse("2026-11-22T08:00:15Z")!)
        XCTAssertTrue(folded.planned)
        let progress = ChatTurnActivity.planProgress(steps: folded.steps, planned: folded.planned)
        XCTAssertNotNil(progress)
        XCTAssertEqual(progress?.completed, 1)
        XCTAssertEqual(progress?.failed, 1)
        XCTAssertEqual(progress?.total, 3)
        XCTAssertEqual(progress?.activeStep?.title, "Ship fix")
        XCTAssertEqual(progress?.progressLabel, "1/3 steps · 1 failed")

        // Planless turn returns nil.
        XCTAssertNil(ChatTurnActivity.planProgress(steps: folded.steps, planned: false))

        // Long-turn usage refresh delay math.
        XCTAssertEqual(ChatTurnActivity.longTurnUsageRefreshDelayMs(sinceEpochMs: nil, nowEpochMs: 100_000), 60_000)
        XCTAssertEqual(ChatTurnActivity.longTurnUsageRefreshDelayMs(sinceEpochMs: 100_000, nowEpochMs: 100_000), 60_000)
        XCTAssertEqual(ChatTurnActivity.longTurnUsageRefreshDelayMs(sinceEpochMs: 100_000, nowEpochMs: 145_000), 15_000)
        XCTAssertEqual(ChatTurnActivity.longTurnUsageRefreshDelayMs(sinceEpochMs: 100_000, nowEpochMs: 160_000), 0)
        XCTAssertEqual(ChatTurnActivity.longTurnUsageRefreshDelayMs(sinceEpochMs: 100_000, nowEpochMs: 195_000), 0)
    }

    func testLiveEventsRequestScopesBySinceAndMatchesRunEventsInvalidation() {
        let since = "2026-11-25T04:55:13.123456Z"
        let scoped = ChatTurnActivity.liveEventsRequest(runId: "run-1", since: since)
        XCTAssertEqual(scoped.path, "/api/v1/runs/run-1/events")
        XCTAssertEqual(scoped.query, [URLQueryItem(name: "since", value: since)])

        let unscopedNil = ChatTurnActivity.liveEventsRequest(runId: "run-1", since: nil)
        XCTAssertTrue(unscopedNil.query.isEmpty)

        let unscopedBlank = ChatTurnActivity.liveEventsRequest(runId: "run-1", since: "   ")
        XCTAssertTrue(unscopedBlank.query.isEmpty)
        XCTAssertEqual(unscopedNil.key, unscopedBlank.key)

        // Live SSE `run.events` hints must still invalidate the ?since=... cached entry.
        let inv = LiveUpdates.invalidation(for: ServerEvent(type: "run.events", ids: ["run-1"]))
        XCTAssertTrue(inv.matches(scoped.key))
        XCTAssertTrue(inv.matches(unscopedNil.key))
        XCTAssertFalse(inv.matches(ChatTurnActivity.liveEventsRequest(runId: "run-2", since: since).key))
    }

    func testToolTargetsDecisionNarrationsAndSubagentLanes() {
        // Concrete target extraction across common tool families.
        XCTAssertEqual(
            ChatTurnActivity.targetOf(tool: "Read", input: .object(["file_path": .string("/workspace/macos/Sources/Vesper/ActivitySceneView.swift")])),
            "Vesper/ActivitySceneView.swift"
        )
        XCTAssertEqual(
            ChatTurnActivity.targetOf(tool: "Grep", input: .object(["pattern": .string("ActivitySceneTransitioner")])),
            "ActivitySceneTransitioner"
        )
        XCTAssertEqual(
            ChatTurnActivity.targetOf(tool: "Bash", input: .object(["command": .string("swift test --filter ActivitySceneTests")])),
            "swift test --filter ActivitySceneTests"
        )
        XCTAssertEqual(
            ChatTurnActivity.targetOf(tool: "WebFetch", input: .object(["url": .string("https://developer.apple.com/documentation/swiftui")])),
            "developer.apple.com/documentation/swiftui"
        )
        XCTAssertEqual(
            ChatTurnActivity.targetOf(tool: "mcp__lazyagents__run_subagents", input: .object(["tasks": .array([.object([:]), .object([:]), .object([:])])])),
            "3 parallel workers"
        )

        // Decision narration tag parsing.
        let approach = ChatTurnActivity.parseNarration("New approach: drive live refreshes off SSE instead of 1.5s polling.")
        XCTAssertEqual(approach?.tag, .approach)
        XCTAssertEqual(approach?.text, "drive live refreshes off SSE instead of 1.5s polling.")
        let surprise = ChatTurnActivity.parseNarration("Surprise: LiveUpdates already invalidates run.events.")
        XCTAssertEqual(surprise?.tag, .surprise)
        XCTAssertEqual(surprise?.text, "LiveUpdates already invalidates run.events.")

        // Full turn with opening line, tagged narrations, concrete targets, and parallel subagents.
        let t0 = "2026-11-28T05:00:00Z"
        let events: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "message", at: "2026-11-28T05:00:01Z", payload: ["role": .string("assistant"), "text": .string("Checking the renderer and tests.")]),
            ChatRunEvent(seq: 2, type: "tool_call", at: "2026-11-28T05:00:02Z", payload: [
                "id": .string("c1"), "tool": .string("Read"),
                "input": .object(["file_path": .string("/workspace/macos/Sources/Vesper/Native/Shared/ActivitySceneView.swift")]),
            ]),
            ChatRunEvent(seq: 3, type: "tool_result", at: "2026-11-28T05:00:03Z", payload: ["id": .string("c1"), "output": .string("ok")]),
            ChatRunEvent(seq: 4, type: "message", at: "2026-11-28T05:00:04Z", payload: [
                "role": .string("assistant"),
                "text": .string("Surprise: ActivitySceneView was capped at 24fps."),
            ]),
            ChatRunEvent(seq: 5, type: "tool_call", at: "2026-11-28T05:00:05Z", payload: [
                "id": .string("c2"), "tool": .string("mcp__lazyagents__run_subagents"),
                "input": .object(["tasks": .array([.object([:]), .object([:])])]),
            ]),
            // Two parallel subagents racing inside c2: sub-a finishes, sub-b is actively grepping.
            ChatRunEvent(seq: 6, type: "lifecycle", at: "2026-11-28T05:00:05Z", payload: [
                "state": .string("subagent_queued"), "subagent": .bool(true),
                "subagent_id": .string("sub-a"), "subagent_type": .string("explorer"),
                "subagent_role": .string("Scene Auditor"), "subagent_tier": .string("fast"),
            ]),
            ChatRunEvent(seq: 7, type: "lifecycle", at: "2026-11-28T05:00:05Z", payload: [
                "state": .string("subagent_started"), "subagent": .bool(true),
                "subagent_id": .string("sub-a"), "subagent_type": .string("explorer"),
                "subagent_role": .string("Scene Auditor"), "subagent_tier": .string("fast"),
            ]),
            ChatRunEvent(seq: 8, type: "tool_call", at: "2026-11-28T05:00:06Z", payload: [
                "id": .string("sa1"), "tool": .string("Read"),
                "input": .object(["file_path": .string("/workspace/macos/Sources/VesperCore/Native/ActivitySceneRenderer.swift")]),
                "subagent": .bool(true), "subagent_id": .string("sub-a"), "subagent_type": .string("explorer"),
            ]),
            ChatRunEvent(seq: 9, type: "lifecycle", at: "2026-11-28T05:00:07Z", payload: [
                "state": .string("subagent_finished"), "status": .string("completed"), "duration_ms": .int(2000), "tool_calls": .int(1),
                "subagent": .bool(true), "subagent_id": .string("sub-a"), "subagent_type": .string("explorer"),
            ]),
            ChatRunEvent(seq: 10, type: "lifecycle", at: "2026-11-28T05:00:06Z", payload: [
                "state": .string("subagent_started"), "subagent": .bool(true),
                "subagent_id": .string("sub-b"), "subagent_type": .string("helper"),
                "subagent_role": .string("Test Runner"), "subagent_tier": .string("standard"),
            ]),
            ChatRunEvent(seq: 11, type: "tool_call", at: "2026-11-28T05:00:08Z", payload: [
                "id": .string("sb1"), "tool": .string("Bash"),
                "input": .object(["command": .string("swift test --filter ActivitySceneTests")]),
                "subagent": .bool(true), "subagent_id": .string("sub-b"), "subagent_type": .string("helper"),
            ]),
        ]

        let live = ChatTurnActivity.fold(events: events, since: t0, now: APIDate.parse("2026-11-28T05:00:10Z")!)
        XCTAssertEqual(live.openingLine, "Checking the renderer and tests.")
        XCTAssertEqual(live.status.kind, .subagent)
        XCTAssertEqual(live.activeTarget, "2 parallel workers")
        XCTAssertEqual(live.toolCallCount, 2)
        XCTAssertEqual(live.latestNarration?.tag, .surprise)
        XCTAssertEqual(live.latestNarration?.text, "ActivitySceneView was capped at 24fps.")

        // Parent steps stay unpolluted by subagent child tools, carry concrete targets + narration tags.
        XCTAssertEqual(live.steps.count, 2)
        XCTAssertEqual(live.steps[0].detail, "Shared/ActivitySceneView.swift")
        XCTAssertEqual(live.steps[1].detail, "2 parallel workers")
        XCTAssertEqual(live.steps[1].tag, .surprise)
        XCTAssertEqual(live.steps[1].intent, "ActivitySceneView was capped at 24fps.")

        // Inline subagent lanes capture both completed and live running workers.
        XCTAssertEqual(live.subagents.count, 2)
        XCTAssertEqual(live.subagents[0].displayName, "Scene Auditor")
        XCTAssertEqual(live.subagents[0].tier, "fast")
        XCTAssertEqual(live.subagents[0].state, .done)
        XCTAssertEqual(live.subagents[0].durationMs, 2000)
        XCTAssertEqual(live.subagents[0].toolCallCount, 1)

        XCTAssertEqual(live.subagents[1].displayName, "Test Runner")
        XCTAssertEqual(live.subagents[1].tier, "standard")
        XCTAssertEqual(live.subagents[1].state, .running)
        XCTAssertEqual(live.subagents[1].currentStatus?.kind, .tests)
        XCTAssertEqual(live.subagents[1].currentTarget, "swift test --filter ActivitySceneTests")
        XCTAssertEqual(live.subagents[1].toolCallCount, 1)

        // Finished turn preserves subagent lanes and tool count, and ignores trailing final reply as narration.
        let finishedEvents = events + [
            ChatRunEvent(seq: 12, type: "tool_result", at: "2026-11-28T05:00:11Z", payload: ["id": .string("c2"), "output": .string("done")]),
            ChatRunEvent(seq: 13, type: "message", at: "2026-11-28T05:00:12Z", payload: ["role": .string("assistant"), "text": .string("All done!")]),
        ]
        let finished = ChatTurnActivity.finishedTurn(events: finishedEvents, outcome: .done, since: t0, until: "2026-11-28T05:00:12Z")
        XCTAssertEqual(finished.subagents.count, 2)
        XCTAssertEqual(finished.toolCallCount, 2)
        let afterReply = ChatTurnActivity.fold(events: finishedEvents, since: t0, now: APIDate.parse("2026-11-28T05:00:13Z")!)
        XCTAssertEqual(afterReply.latestNarration?.tag, .surprise)
    }

    // MARK: - ChatNav

    func testChatNavGroupingIndicatorsFiltersAndActions() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = APIDate.parse("2026-11-22T15:00:00Z")!

        var input = ChatNav.Input()
        input.now = now
        input.calendar = utc
        input.viewedChatId = "c-today"
        input.spaces = [
            ChatNav.SpaceRow(id: "s1", name: "Vesper", color: "#5B4BD6", chatCount: 3, workKey: "VES"),
            ChatNav.SpaceRow(id: "s2", name: "Old", workArchived: true),
        ]
        input.personas = [
            ChatNav.FilterOption(value: "p1", label: "Meow"),
            ChatNav.FilterOption(value: "p2", label: "Tech Lead"),
        ]
        input.chats = [
            ChatNav.ChatRow(id: "c-pin", title: "Pinned thread", state: "running", unread: 4, pinned: true, createdAt: "2026-10-01T10:00:00Z", spaceId: "s1", personaId: "p1", personaName: "Meow"),
            ChatNav.ChatRow(id: "c-today", title: "Open today", state: "idle", unread: 3, createdAt: "2026-11-22T12:00:00Z", spaceId: "s1", personaId: "p1"),
            ChatNav.ChatRow(id: "c-yest", title: "Yesterday unread", state: "idle", unread: 2, createdAt: "2026-11-21T18:00:00Z", spaceId: "s1", personaId: "p2"),
            ChatNav.ChatRow(id: "c-week", title: "Four days ago", createdAt: "2026-11-18T10:00:00Z"),
            ChatNav.ChatRow(id: "c-old", title: "Last month", createdAt: "2026-10-15T10:00:00Z"),
        ]

        let model = ChatNav.model(input)
        XCTAssertEqual(model.id, "chats")
        XCTAssertEqual(model.selectedId, "c-today")
        XCTAssertEqual(model.sections.map(\.id), [
            "chats-pinned", "chats-today", "chats-yesterday", "chats-previous-7-days", "chats-older",
        ])

        // Running wins over unread on pinned chat; chat rows omit tiled photo avatars
        let pinnedItem = model.sections[0].items[0]
        XCTAssertEqual(pinnedItem.status, .done)
        XCTAssertNil(pinnedItem.badge)
        XCTAssertNil(pinnedItem.avatar)

        // Open chat suppresses unread badge
        let openItem = model.sections[1].items[0]
        XCTAssertNil(openItem.badge)

        // Closed unread chat gets badge
        let unreadItem = model.sections[2].items[0]
        XCTAssertEqual(unreadItem.badge, NavBadge(text: "2", tone: .human))

        // Calmer sidebar: no stacked Space/Persona filter dropdowns or persona picker
        XCTAssertNil(model.filters)
        XCTAssertNil(model.picker)

        // Command mapping
        XCTAssertEqual(ChatNav.action(for: .navAction(navigatorId: "chats", actionId: "new-chat")), .newChat(personaId: nil))
        XCTAssertEqual(ChatNav.action(for: .navActivate(navigatorId: "chats", itemId: "c-today", newTab: true)), .selectChat(id: "c-today", newTab: true))
        XCTAssertEqual(ChatNav.action(for: .navActivate(navigatorId: "chats", itemId: "hit:m1", newTab: false)), .selectSearchHit(messageId: "m1", newTab: false))
        XCTAssertEqual(ChatNav.action(for: .navActivate(navigatorId: "chats", itemId: "space:s1", newTab: false)), .selectSpace(id: "s1", newTab: false))
        XCTAssertEqual(ChatNav.action(for: .navFilter(navigatorId: "chats", filterId: "chat-space", value: "s1", checked: true)), .filterSpace("s1"))
        XCTAssertEqual(ChatNav.action(for: .navAction(navigatorId: "chats", actionId: "pin", itemId: "c-today")), .pinChat(id: "c-today", pinned: true))
        XCTAssertEqual(ChatNav.action(for: .navAction(navigatorId: "chats", actionId: "open-new-tab", itemId: "c-today")), .selectChat(id: "c-today", newTab: true))
        XCTAssertEqual(ChatNav.action(for: .navAction(navigatorId: "chats", actionId: "open-new-tab", itemId: "hit:m1")), .selectSearchHit(messageId: "m1", newTab: true))
        XCTAssertEqual(ChatNav.action(for: .navAction(navigatorId: "chats", actionId: "open-new-tab", itemId: "space:s1")), .selectSpace(id: "s1", newTab: true))

        // Context menus include "Open in New Tab" for active chats, archived chats, and search hits
        let activeMenu = ChatNav.chatMenu(archived: false, pinned: false)
        XCTAssertEqual(activeMenu.first?.id, ChatNav.MenuAction.openInNewTab)
        XCTAssertEqual(activeMenu.first?.label, "Open in New Tab")
        XCTAssertEqual(activeMenu.first?.icon, "external")

        let archivedMenu = ChatNav.chatMenu(archived: true, pinned: false)
        XCTAssertEqual(archivedMenu.first?.id, ChatNav.MenuAction.openInNewTab)
        XCTAssertEqual(archivedMenu.first?.label, "Open in New Tab")

        let hit = ChatNav.hitItem(ChatNav.SearchHit(messageId: "m1", chatId: "c-today", chatTitle: "Open today", role: "user", snippet: "hello"))
        XCTAssertEqual(hit.contextMenu?.map(\.id), [ChatNav.MenuAction.openInNewTab])
    }

    func testChatListPersonaQuerySendsAllForTheAllPick() {
        // An omitted persona_id means "default persona" to the server, so "All" must say so.
        XCTAssertEqual(ChatNav.listPersonaQuery(""), "all")
        XCTAssertEqual(ChatNav.listPersonaQuery("p2"), "p2")
        XCTAssertEqual(API.listChats(personaId: ChatNav.listPersonaQuery("")).pathAndQuery, "/api/v1/chats?persona_id=all")
    }

    // MARK: - 500-Message Transcript Benchmark / Smoke Test

    func test500MessageTranscriptParsesLinearlyWithZeroWebViewDependencies() {
        let templates = [
            "Simple reply with @Meow and citation [1].\n\nSources:\n1. [Doc](https://example.com/1)",
            "Check this diagram:\n```mermaid\ngraph LR\n  A-->B\n```\nDone.",
            "Metrics:\n```chart\n{\"type\":\"line\",\"categories\":[\"Q1\",\"Q2\",\"Q3\"],\"series\":[{\"name\":\"Rev\",\"values\":[10,20,35]}]}\n```",
            "Pick one:\n```choices\nNext step?\n- Ship | Deploy now\n- Wait | Run soak test\n```",
            "Watch:\n```recommend\nhttps://youtu.be/dQw4w9WgXcQ?t=42\nDemo clip\n```\n\n```recommend\nhttps://example.com/blog\nPost\n```",
        ]

        var messages: [String] = []
        messages.reserveCapacity(500)
        for i in 0..<500 {
            let base = templates[i % templates.count]
            messages.append("Message #\(i): \(base)")
        }

        let start = Date()
        var totalSegments = 0
        for msg in messages {
            let parsed = ChatTranscriptLogic.parseMessage(msg, knownPersonaNames: ["Meow"])
            totalSegments += parsed.segments.count
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(totalSegments, 700)
        XCTAssertLessThan(elapsed, 5.0, "Parsing 500 mixed transcript messages took \(elapsed)s (expected fast linear scan)")
    }

    func testParsedMessageCacheReusesEntriesAndEnforcesBound() {
        let cache = ChatParsedMessageCache(maxEntries: 2)
        let body1 = "Run workflow:\n```workflow-run\n01a1bc65-d1cf-748a-8632-82b3f8ba9c9c\nBuild map\n```"
        let body2 = "Plain reply with no cards."
        let body3 = "Canvas:\n```canvas\n01a1bc65-d1cf-748a-8632-82b3f8ba9c9d\n```"

        let first = cache.parsed(messageId: "m1", bodyMd: body1, extractSources: true, knownPersonaNames: ["Meow"])
        let second = cache.parsed(messageId: "m1", bodyMd: body1, extractSources: true, knownPersonaNames: ["Meow"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(first.hasWorkflowRunSegment)
        XCTAssertFalse(first.hasCanvasSegment)

        let plain = cache.parsed(messageId: "m2", bodyMd: body2, extractSources: true, knownPersonaNames: ["Meow"])
        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(plain.hasWorkflowRunSegment)

        // Adding a third distinct entry evicts the oldest so memory stays bounded.
        let canvas = cache.parsed(messageId: "m3", bodyMd: body3, extractSources: true, knownPersonaNames: ["Meow"])
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(canvas.hasCanvasSegment)

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Transcript Load State & Tail Window

    func testLoadStateStaysLoadingUntilFirstPayloadLands() {
        // Uncached chat on frame 1 (before .task flips isFetching) still has hasData == false
        // and must show the skeleton rather than mounting an empty bottom-anchored ScrollView.
        XCTAssertEqual(
            ChatTranscriptWindow.loadState(hasData: false, hasError: false, isEmpty: true),
            .loading
        )
        // Error with no cached data shows the error state.
        XCTAssertEqual(
            ChatTranscriptWindow.loadState(hasData: false, hasError: true, isEmpty: true),
            .error
        )
        // Loaded chat with zero messages (brand-new empty chat) is ready.
        XCTAssertEqual(
            ChatTranscriptWindow.loadState(hasData: true, hasError: false, isEmpty: true),
            .ready
        )
        // Cached chat whose background refetch failed keeps rendering its cached messages.
        XCTAssertEqual(
            ChatTranscriptWindow.loadState(hasData: true, hasError: true, isEmpty: false),
            .ready
        )
    }

    func testVisibleRangeAndExpansionForLongHistory() {
        let initial = ChatTranscriptWindow.initialLimit
        XCTAssertEqual(ChatTranscriptWindow.visibleRange(totalCount: 0, visibleLimit: initial), 0..<0)
        XCTAssertEqual(ChatTranscriptWindow.visibleRange(totalCount: 12, visibleLimit: initial), 0..<12)
        XCTAssertEqual(ChatTranscriptWindow.hiddenCount(totalCount: 12, visibleLimit: initial), 0)

        // Long history renders only the trailing window initially.
        XCTAssertEqual(ChatTranscriptWindow.visibleRange(totalCount: 100, visibleLimit: initial), 70..<100)
        XCTAssertEqual(ChatTranscriptWindow.hiddenCount(totalCount: 100, visibleLimit: initial), 70)

        // Expanding reveals one page at a time and clamps at totalCount.
        let page1 = ChatTranscriptWindow.expandedLimit(currentLimit: initial, totalCount: 100, pageSize: 30)
        XCTAssertEqual(page1, 60)
        XCTAssertEqual(ChatTranscriptWindow.visibleRange(totalCount: 100, visibleLimit: page1), 40..<100)

        let page2 = ChatTranscriptWindow.expandedLimit(currentLimit: page1, totalCount: 100, pageSize: 30)
        XCTAssertEqual(page2, 90)

        let page3 = ChatTranscriptWindow.expandedLimit(currentLimit: page2, totalCount: 100, pageSize: 30)
        XCTAssertEqual(page3, 100)
        XCTAssertEqual(ChatTranscriptWindow.hiddenCount(totalCount: 100, visibleLimit: page3), 0)
    }

    func testEffectiveLimitExpandsToIncludeOlderJumpTargetWithContext() {
        let ids = (0..<100).map { "m-\($0)" }

        // Target already inside the trailing window leaves the limit unchanged.
        XCTAssertEqual(
            ChatTranscriptWindow.effectiveLimit(messageIds: ids, visibleLimit: 30, targetMessageId: "m-85"),
            30
        )

        // Older target expands to include the target plus 5 messages of preceding context.
        XCTAssertEqual(
            ChatTranscriptWindow.effectiveLimit(messageIds: ids, visibleLimit: 30, targetMessageId: "m-20"),
            85
        )
        XCTAssertEqual(ChatTranscriptWindow.visibleRange(totalCount: 100, visibleLimit: 85), 15..<100)

        // Target near the very start clamps cleanly at index 0.
        XCTAssertEqual(
            ChatTranscriptWindow.effectiveLimit(messageIds: ids, visibleLimit: 30, targetMessageId: "m-2"),
            100
        )

        // Unknown target falls back to the current limit.
        XCTAssertEqual(
            ChatTranscriptWindow.effectiveLimit(messageIds: ids, visibleLimit: 30, targetMessageId: "missing"),
            30
        )
    }

    func testAdjustedLimitForAppendPreservesExpandedTopBoundary() {
        // Unexpanded window stays bounded at initialLimit when new messages arrive.
        XCTAssertEqual(
            ChatTranscriptWindow.adjustedLimitForAppend(
                currentLimit: ChatTranscriptWindow.initialLimit,
                previousCount: 80,
                newCount: 82
            ),
            ChatTranscriptWindow.initialLimit
        )

        // Expanded window grows by the appended delta so earlier messages don't slip back out.
        XCTAssertEqual(
            ChatTranscriptWindow.adjustedLimitForAppend(currentLimit: 60, previousCount: 80, newCount: 82),
            62
        )
        XCTAssertEqual(
            ChatTranscriptWindow.adjustedLimitForAppend(currentLimit: 60, previousCount: 80, newCount: 80),
            60
        )
    }

    func testEarlierButtonLabelFormatsCounts() {
        XCTAssertEqual(ChatTranscriptWindow.earlierButtonLabel(hiddenCount: 0, pageSize: 30), "")
        XCTAssertEqual(ChatTranscriptWindow.earlierButtonLabel(hiddenCount: 1, pageSize: 30), "Show 1 earlier message")
        XCTAssertEqual(ChatTranscriptWindow.earlierButtonLabel(hiddenCount: 12, pageSize: 30), "Show 12 earlier messages")
        XCTAssertEqual(
            ChatTranscriptWindow.earlierButtonLabel(hiddenCount: 70, pageSize: 30),
            "Show 30 earlier messages (70 hidden)"
        )
    }

    func testChatScrollLockLogicTracksPinningAndAutoScrollRules() {
        // Content shorter than container is always pinned at bottom.
        XCTAssertEqual(
            ChatScrollLockLogic.distanceFromBottom(contentHeight: 300, containerHeight: 600, contentOffsetY: 0),
            0
        )
        XCTAssertTrue(ChatScrollLockLogic.isNearBottom(distanceFromBottom: 0))
        XCTAssertTrue(ChatScrollLockLogic.isNearBottom(distanceFromBottom: 72))
        XCTAssertFalse(ChatScrollLockLogic.isNearBottom(distanceFromBottom: 73))

        // Mid-scroll distance includes bottom inset.
        let dist = ChatScrollLockLogic.distanceFromBottom(
            contentHeight: 2000,
            containerHeight: 600,
            contentOffsetY: 900,
            contentInsetBottom: 40
        )
        XCTAssertEqual(dist, 540)
        XCTAssertFalse(ChatScrollLockLogic.isNearBottom(distanceFromBottom: dist))

        // Auto-scroll rules: user messages always scroll; arriving replies only scroll when pinned.
        XCTAssertTrue(ChatScrollLockLogic.shouldAutoScrollOnNewMessage(isNearBottom: false, isUserMessage: true))
        XCTAssertTrue(ChatScrollLockLogic.shouldAutoScrollOnNewMessage(isNearBottom: true, isUserMessage: false))
        XCTAssertFalse(ChatScrollLockLogic.shouldAutoScrollOnNewMessage(isNearBottom: false, isUserMessage: false))

        XCTAssertTrue(ChatScrollLockLogic.shouldAutoScrollOnRunningStart(isNearBottom: true, lastMessageIsUser: false))
        XCTAssertTrue(ChatScrollLockLogic.shouldAutoScrollOnRunningStart(isNearBottom: false, lastMessageIsUser: true))
        XCTAssertFalse(ChatScrollLockLogic.shouldAutoScrollOnRunningStart(isNearBottom: false, lastMessageIsUser: false))

        // Jump pill labels reflect unread count and live running state.
        XCTAssertEqual(ChatScrollLockLogic.jumpPillLabel(unreadReplies: 0, isRunning: false), "Latest")
        XCTAssertEqual(ChatScrollLockLogic.jumpPillLabel(unreadReplies: 0, isRunning: true), "Follow reply")
        XCTAssertEqual(ChatScrollLockLogic.jumpPillLabel(unreadReplies: 1, isRunning: false), "New reply")
        XCTAssertEqual(ChatScrollLockLogic.jumpPillLabel(unreadReplies: 3, isRunning: true), "3 new replies")

        // Image attachment detection for composer thumbnail rendering.
        let png = ChatComposerAttachment(filename: "shot.png", contentType: "image/png", sizeBytes: 1024)
        let webp = ChatComposerAttachment(filename: "shot.webp", contentType: "IMAGE/WEBP", sizeBytes: 1024)
        let pdf = ChatComposerAttachment(filename: "spec.pdf", contentType: "application/pdf", sizeBytes: 1024)
        XCTAssertTrue(png.isImage)
        XCTAssertTrue(webp.isImage)
        XCTAssertFalse(pdf.isImage)
    }
}
