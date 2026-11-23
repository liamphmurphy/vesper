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
}
