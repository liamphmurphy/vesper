import XCTest
@testable import VesperCore

final class ChatFindContextFoldingTests: XCTestCase {
    func testContextMeterFormattingAndTones() {
        XCTAssertEqual(ChatContextMeterLogic.formatTokens(0), "0")
        XCTAssertEqual(ChatContextMeterLogic.formatTokens(950), "950")
        XCTAssertEqual(ChatContextMeterLogic.formatTokens(12_500), "12.5k")
        XCTAssertEqual(ChatContextMeterLogic.formatTokens(42_000), "42k")
        XCTAssertEqual(ChatContextMeterLogic.formatTokens(160_000), "160k")

        let low = ChatContextMeterLogic.state(contextTokens: 40_000, effectiveLimit: 160_000)
        XCTAssertEqual(low.tone, .neutral)
        XCTAssertEqual(low.label, "40k / 160k")

        let warn = ChatContextMeterLogic.state(contextTokens: 128_000, effectiveLimit: 160_000)
        XCTAssertEqual(warn.tone, .warning)

        let danger = ChatContextMeterLogic.state(contextTokens: 150_000, effectiveLimit: 160_000)
        XCTAssertEqual(danger.tone, .danger)

        let disabled = ChatContextMeterLogic.state(contextTokens: 25_000, effectiveLimit: 0)
        XCTAssertEqual(disabled.tone, .neutral)
        XCTAssertEqual(disabled.label, "25k tok")
    }

    func testReplyFoldingThresholdsAndPreview() {
        XCTAssertFalse(ChatReplyFoldingLogic.isFoldableReply("Short message"))
        XCTAssertTrue(ChatReplyFoldingLogic.isFoldableReply(String(repeating: "x", count: 2400)))
        let manyLines = (0..<45).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertTrue(ChatReplyFoldingLogic.isFoldableReply(manyLines))

        let preview = ChatReplyFoldingLogic.collapsedPreview("A\nB\nC\nD\nE\nF", maxLines: 3)
        XCTAssertEqual(preview, "A\nB\nC")
    }

    func testContextBreakdownSumsToTotalAndOmitsMemoryInTemporaryChat() {
        let normal = ChatContextMeterLogic.breakdown(
            contextTokens: 20_000,
            messages: [],
            hasSpace: true,
            hasPersona: true,
            isTemporary: false
        )
        XCTAssertEqual(normal.reduce(0) { $0 + $1.tokens }, 20_000)
        XCTAssertTrue(normal.contains { $0.category == .memory })
        XCTAssertTrue(normal.contains { $0.category == .spaceKnowledge })

        let temp = ChatContextMeterLogic.breakdown(
            contextTokens: 10_000,
            messages: [],
            hasSpace: false,
            hasPersona: true,
            isTemporary: true
        )
        XCTAssertEqual(temp.reduce(0) { $0 + $1.tokens }, 10_000)
        XCTAssertFalse(temp.contains { $0.category == .memory })
    }

    func testMemoryDiffExtractionParsesSaveUpdateAndForgetEvents() {
        let events: [ChatRunEvent] = [
            ChatRunEvent(seq: 1, type: "tool_call", at: "2026-11-27T10:00:01Z", payload: [
                "id": .string("c1"),
                "tool": .string("mcp__lazyagents__save_memory"),
                "input": .object(["title": .string("Prefers Go"), "summary": .string("Strong Go preference"), "type": .string("preference")]),
            ]),
            ChatRunEvent(seq: 2, type: "tool_result", at: "2026-11-27T10:00:02Z", payload: [
                "id": .string("c1"),
                "output": .string("{\"id\":\"mem-1\",\"action\":\"created\",\"about\":\"person\",\"title\":\"Prefers Go\"}"),
            ]),
            ChatRunEvent(seq: 3, type: "tool_call", at: "2026-11-27T10:00:03Z", payload: [
                "id": .string("c2"),
                "tool": .string("mcp_lazyagents_forget_memory"),
                "input": .object(["id": .string("mem-2")]),
            ]),
            ChatRunEvent(seq: 4, type: "tool_result", at: "2026-11-27T10:00:04Z", payload: [
                "id": .string("c2"),
                "output": .string("{\"forgotten\":\"mem-2\",\"title\":\"Old habit\"}"),
            ]),
        ]

        let turn = ChatTurnActivity.finishedTurn(events: events, outcome: .done)
        XCTAssertEqual(turn.memoryDiffs.count, 2)
        XCTAssertEqual(turn.memoryDiffs[0].action, .created)
        XCTAssertEqual(turn.memoryDiffs[0].memoryId, "mem-1")
        XCTAssertEqual(turn.memoryDiffs[0].title, "Prefers Go")
        XCTAssertEqual(turn.memoryDiffs[1].action, .forgotten)
        XCTAssertEqual(turn.memoryDiffs[1].memoryId, "mem-2")
        XCTAssertEqual(turn.memoryDiffs[1].title, "Old habit")
    }
}
