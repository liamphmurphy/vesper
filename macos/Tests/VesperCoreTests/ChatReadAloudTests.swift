import XCTest
@testable import VesperCore

final class ChatReadAloudTests: XCTestCase {
    func testPlaybackRateCyclesThroughSteps() {
        XCTAssertEqual(ChatPlaybackRate.x1.next(), .x125)
        XCTAssertEqual(ChatPlaybackRate.x125.next(), .x15)
        XCTAssertEqual(ChatPlaybackRate.x15.next(), .x2)
        XCTAssertEqual(ChatPlaybackRate.x2.next(), .x1)
        XCTAssertEqual(ChatPlaybackRate.x125.label, "1.25×")
    }

    func testSnippetStripsMarkdownAndTruncates() {
        let md = "### Heading\n\nHere is a **bold** summary with [a link](https://example.com) and `code`."
        let s = ChatReadAloudLogic.snippet(from: md, maxLength: 40)
        XCTAssertFalse(s.contains("**"))
        XCTAssertFalse(s.contains("https://"))
        XCTAssertLessThanOrEqual(s.count, 40)
        XCTAssertEqual(ChatReadAloudLogic.snippet(from: "   "), "Message")
    }
}
