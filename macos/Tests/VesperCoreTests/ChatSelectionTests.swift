import XCTest
@testable import VesperCore

final class ChatSelectionTests: XCTestCase {
    func testCleanSelectionFiltersShortAndTrims() {
        XCTAssertNil(ChatSelectionLogic.cleanSelection("   "))
        XCTAssertNil(ChatSelectionLogic.cleanSelection("a"))
        XCTAssertEqual(ChatSelectionLogic.cleanSelection("  hello world  "), "hello world")
    }

    func testSelectionPromptsFormatBlockquotesAndMentions() {
        let quoted = ChatSelectionLogic.quotePrompt(selection: "line 1\nline 2", speakerName: "Tech Lead", hostName: "Judy")
        XCTAssertTrue(quoted.hasPrefix("@Tech Lead"))
        XCTAssertTrue(quoted.contains("> line 1\n> line 2"))

        let sameHost = ChatSelectionLogic.quotePrompt(selection: "key point", speakerName: "Judy", hostName: "Judy")
        XCTAssertFalse(sameHost.hasPrefix("@"))
        XCTAssertEqual(sameHost, "> key point\n\n")

        let explain = ChatSelectionLogic.explainPrompt(selection: "CAS loop")
        XCTAssertTrue(explain.contains("Explain this part"))
        XCTAssertTrue(explain.contains("> CAS loop"))

        let thread = ChatSelectionLogic.threadPrefill(selection: "edge case")
        XCTAssertEqual(thread, "> edge case\n\n")
    }
}
