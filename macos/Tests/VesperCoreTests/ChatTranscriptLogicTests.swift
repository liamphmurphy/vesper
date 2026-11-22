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
}
