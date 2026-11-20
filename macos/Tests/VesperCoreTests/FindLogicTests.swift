import XCTest
@testable import VesperCore

final class FindLogicTests: XCTestCase {
    func testNormalizeSelectionTakesFirstNonEmptyLineAndCapsLength() {
        XCTAssertNil(FindLogic.normalizeSelection(nil))
        XCTAssertNil(FindLogic.normalizeSelection("   \n  \t  "))
        XCTAssertEqual(FindLogic.normalizeSelection("\n  hello world  \nsecond line"), "hello world")
        let long = String(repeating: "a", count: 250)
        XCTAssertEqual(FindLogic.normalizeSelection(long)?.count, 200)
    }

    func testShouldSearchAndStatusText() {
        XCTAssertFalse(FindLogic.shouldSearch(query: ""))
        XCTAssertTrue(FindLogic.shouldSearch(query: "vesper"))

        XCTAssertNil(FindLogic.statusText(query: "", hasResult: true, matchFound: false))
        XCTAssertNil(FindLogic.statusText(query: "vesper", hasResult: false, matchFound: false))
        XCTAssertNil(FindLogic.statusText(query: "vesper", hasResult: true, matchFound: true))
        XCTAssertEqual(FindLogic.statusText(query: "vesper", hasResult: true, matchFound: false), "No matches")
    }
}
