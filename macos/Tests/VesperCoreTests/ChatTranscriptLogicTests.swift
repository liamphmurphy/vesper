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

        ```dispatch
        LAZYAGENTS-283
        lazyagents-284
        BAD-
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

        // Expect 12 segments: markdown, mermaid, math, chart, choices, dispatch, grouped recommend (2), workflowRun, canvas, pdf, researchPlan, swift markdown
        XCTAssertEqual(parsed.segments.count, 12)

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

        XCTAssertEqual(parsed.segments[5], .dispatch(ChatDispatchCard(ticketKeys: ["LAZYAGENTS-283", "LAZYAGENTS-284"])))

        if case .recommend(let recs) = parsed.segments[6] {
            XCTAssertEqual(recs.count, 2)
            XCTAssertEqual(recs[0].youtubeVideoID, "dQw4w9WgXcQ")
            XCTAssertEqual(recs[0].youtubeMomentSeconds, 90)
            XCTAssertEqual(recs[1].url, "https://example.com/guide")
        } else {
            XCTFail("Expected grouped recommend segment")
        }

        XCTAssertEqual(parsed.segments[7], .workflowRun(ChatWorkflowRunCard(workflowID: uuid1.lowercased(), input: "Generate a dungeon battle map")))
        XCTAssertEqual(parsed.segments[8], .canvas(id: uuid2))
        XCTAssertEqual(parsed.segments[9], .pdf(id: uuid3))

        if case .researchPlan(let plan) = parsed.segments[10] {
            XCTAssertEqual(plan.title, "Local LLM Benchmarks")
            XCTAssertEqual(plan.length, .detailed)
            XCTAssertEqual(plan.tone, .report)
            XCTAssertEqual(plan.questions.count, 2)
        } else {
            XCTFail("Expected researchPlan segment")
        }

        if case .markdown(let codeBlock) = parsed.segments[11] {
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
        XCTAssertEqual(segments.count, 1)
        guard case .markdown(let text) = segments[0] else { return XCTFail("Expected fallback markdown") }
        XCTAssertTrue(text.contains("not valid json"))
        XCTAssertTrue(text.contains("Only one option"))
        XCTAssertTrue(text.contains("not-a-uuid"))
    }

    // MARK: - Context Stripping, Citations & Mentions

    func testStripsWorkAndKnowledgeContextMarkers() {
        let ticket = ChatWorkSubject.ticket(key: "LAZYAGENTS-283", title: "Native Chat")
        let run = ChatWorkSubject.run(id: "r1", title: "Build core", agent: "Meow", ticketKey: "LAZYAGENTS-283")
        let body = ChatWorkSubject.withWorkContext("Please review this", viewing: run, pinned: ticket)
            + ChatContextMarker.knowledge
            + "Viewing page Architecture/Chat.md"

        let stripped = ChatTranscriptLogic.stripContext(body)
        XCTAssertEqual(stripped.typedBody, "Please review this")
        XCTAssertEqual(stripped.workContextLines.count, 2)
        XCTAssertTrue(stripped.workContextLines[0].hasPrefix("Pinned ticket LAZYAGENTS-283"))
        XCTAssertTrue(stripped.workContextLines[1].hasPrefix("Viewing run r1"))
        XCTAssertEqual(stripped.knowledgeContextLines, ["Viewing page Architecture/Chat.md"])
        XCTAssertEqual(ticket.label, "LAZYAGENTS-283 · Native Chat")
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

        XCTAssertEqual(ChatDispatchCard.planLine(stepsTotal: 4, stepsDone: 1, currentStep: "Write tests"), "Step 2 of 4 · Write tests")
        XCTAssertTrue(ChatDispatchCard.runEnded("completed"))
        XCTAssertFalse(ChatDispatchCard.runEnded("running"))

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
            "chats-pinned", "chats-today", "chats-yesterday", "chats-previous-7-days", "chats-older", "spaces",
        ])

        // Running wins over unread on pinned chat
        let pinnedItem = model.sections[0].items[0]
        XCTAssertEqual(pinnedItem.status, .done)
        XCTAssertNil(pinnedItem.badge)

        // Open chat suppresses unread badge
        let openItem = model.sections[1].items[0]
        XCTAssertNil(openItem.badge)

        // Closed unread chat gets badge
        let unreadItem = model.sections[2].items[0]
        XCTAssertEqual(unreadItem.badge, NavBadge(text: "2", tone: .human))

        // Filters & picker
        XCTAssertEqual(model.filters?.map(\.id), ["chat-space", "chat-persona"])
        XCTAssertEqual(model.picker?.id, "persona")

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

        // Context menus include "Open in New Tab" for active chats, archived chats, search hits, and spaces
        let activeMenu = ChatNav.chatMenu(archived: false, pinned: false)
        XCTAssertEqual(activeMenu.first?.id, ChatNav.MenuAction.openInNewTab)
        XCTAssertEqual(activeMenu.first?.label, "Open in New Tab")
        XCTAssertEqual(activeMenu.first?.icon, "external")

        let archivedMenu = ChatNav.chatMenu(archived: true, pinned: false)
        XCTAssertEqual(archivedMenu.first?.id, ChatNav.MenuAction.openInNewTab)
        XCTAssertEqual(archivedMenu.first?.label, "Open in New Tab")

        let hit = ChatNav.hitItem(ChatNav.SearchHit(messageId: "m1", chatId: "c-today", chatTitle: "Open today", role: "user", snippet: "hello"))
        XCTAssertEqual(hit.contextMenu?.map(\.id), [ChatNav.MenuAction.openInNewTab])

        let spaceItem = model.sections.last?.items.first
        XCTAssertEqual(spaceItem?.contextMenu?.map(\.id), [ChatNav.MenuAction.openInNewTab])
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
        let body1 = "Check ticket:\n```dispatch\nLAZYAGENTS-1\n```"
        let body2 = "Plain reply with no cards."
        let body3 = "Canvas:\n```canvas\n01a1bc65-d1cf-748a-8632-82b3f8ba9c9d\n```"

        let first = cache.parsed(messageId: "m1", bodyMd: body1, extractSources: true, knownPersonaNames: ["Meow"])
        let second = cache.parsed(messageId: "m1", bodyMd: body1, extractSources: true, knownPersonaNames: ["Meow"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(first.hasDispatchSegment)
        XCTAssertFalse(first.hasWorkflowRunSegment)
        XCTAssertFalse(first.hasCanvasSegment)

        let plain = cache.parsed(messageId: "m2", bodyMd: body2, extractSources: true, knownPersonaNames: ["Meow"])
        XCTAssertEqual(cache.count, 2)
        XCTAssertFalse(plain.hasDispatchSegment)

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
}
