import XCTest
@testable import VesperCore

final class SpacesLogicTests: XCTestCase {
    func testSuggestWorkKeyAndValidation() {
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "Waterdeep campaign"), "WC")
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "Homelab"), "HOME")
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "A"), "AX")
        XCTAssertEqual(SpacesLogic.suggestWorkKey(for: "123"), "")

        XCTAssertTrue(SpacesLogic.isValidWorkKey("PAY"))
        XCTAssertTrue(SpacesLogic.isValidWorkKey("LAZYAGENTS"))
        XCTAssertFalse(SpacesLogic.isValidWorkKey("A"))
        XCTAssertFalse(SpacesLogic.isValidWorkKey("1ABC"))
        XCTAssertFalse(SpacesLogic.isValidWorkKey("TOO_LONG_KEY"))
    }

    func testTokensBareURLAndInitial() {
        XCTAssertEqual(SpacesLogic.initial(for: "  health"), "H")
        XCTAssertEqual(SpacesLogic.initial(for: "!!!"), "#")
        XCTAssertEqual(SpacesLogic.formatTokens(950), "950")
        XCTAssertEqual(SpacesLogic.formatTokens(1240), "1.2k")
        XCTAssertEqual(SpacesLogic.formatTokens(13100), "13k")
        XCTAssertEqual(SpacesLogic.formatTokens(13100, precise: true), "13.1k")
        XCTAssertEqual(SpacesLogic.bareURL("https://www.examine.com/creatine/"), "examine.com/creatine")
    }
}
