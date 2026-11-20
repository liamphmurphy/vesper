import XCTest
@testable import VesperCore

final class QuickLookLogicTests: XCTestCase {
    func testClampIndex() {
        XCTAssertEqual(QuickLookLogic.clampIndex(nil, count: 5), 0)
        XCTAssertEqual(QuickLookLogic.clampIndex(-3, count: 5), 0)
        XCTAssertEqual(QuickLookLogic.clampIndex(2, count: 5), 2)
        XCTAssertEqual(QuickLookLogic.clampIndex(9, count: 5), 4)
        XCTAssertEqual(QuickLookLogic.clampIndex(2, count: 0), 0)
    }

    func testSafeFilenameSanitizesTraversalAndAppendsExtension() {
        XCTAssertEqual(
            QuickLookLogic.safeFilename(
                filename: "../../secret/diagram.png",
                fallbackTitle: "Architecture",
                urlPathComponent: "content",
                preferredExtension: "png"
            ),
            "diagram.png"
        )
        XCTAssertEqual(
            QuickLookLogic.safeFilename(
                filename: "...",
                fallbackTitle: "Q4 Review Deck",
                urlPathComponent: "content",
                preferredExtension: "pdf"
            ),
            "Q4 Review Deck.pdf"
        )
        XCTAssertEqual(
            QuickLookLogic.safeFilename(
                filename: nil,
                fallbackTitle: "",
                urlPathComponent: nil,
                preferredExtension: "txt"
            ),
            "Preview.txt"
        )
    }
}
