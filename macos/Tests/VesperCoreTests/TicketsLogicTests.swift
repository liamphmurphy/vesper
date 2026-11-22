import Foundation
import XCTest
@testable import VesperCore

final class TicketsLogicTests: XCTestCase {

    func testCompareKeysOrdersByPrefixThenNumber() {
        XCTAssertTrue(TicketsLogic.compareKeys("PAY-2", "PAY-10"))
        XCTAssertFalse(TicketsLogic.compareKeys("PAY-10", "PAY-2"))
        XCTAssertTrue(TicketsLogic.compareKeys("ABC-1", "PAY-1"))
    }

    func testParseAndStripFilterTokens() {
        let parsed = TicketsLogic.parseFilterText("status:todo priority:high login bug")
        XCTAssertEqual(parsed.tokens.count, 2)
        XCTAssertEqual(parsed.text, "login bug")
        let stripped = TicketsLogic.withoutProjectToken("project:PAY status:todo crash")
        XCTAssertFalse(stripped.contains("project:PAY"))
        XCTAssertTrue(stripped.contains("status:todo"))
        XCTAssertTrue(stripped.contains("crash"))
    }

    func testBoardVisibleStatusesAndReorderCard() {
        let withoutCanceled = TicketsBoardLogic.visibleStatuses(includeCanceled: false)
        XCTAssertFalse(withoutCanceled.contains(.canceled))
        let withCanceled = TicketsBoardLogic.visibleStatuses(includeCanceled: true)
        XCTAssertTrue(withCanceled.contains(.canceled))

        let reordered = TicketsBoardLogic.reorderCard(key: "PAY-3", before: "PAY-1", in: ["PAY-1", "PAY-2", "PAY-3"])
        XCTAssertEqual(reordered, ["PAY-3", "PAY-1", "PAY-2"])

        let appended = TicketsBoardLogic.reorderCard(key: "PAY-1", before: nil, in: ["PAY-1", "PAY-2", "PAY-3"])
        XCTAssertEqual(appended, ["PAY-2", "PAY-3", "PAY-1"])
    }

    func testDetailTicketKeyValidationAndBlockers() {
        XCTAssertTrue(TicketDetailLogic.isValidTicketKey("PAY-123"))
        XCTAssertTrue(TicketDetailLogic.isValidTicketKey("LAZYAGENTS-273"))
        XCTAssertFalse(TicketDetailLogic.isValidTicketKey("invalid"))
        XCTAssertEqual(TicketDetailLogic.normalizeTicketKey("  pay-42 "), "PAY-42")
        XCTAssertTrue(TicketDetailLogic.isValidDescriptionChange(original: "a", draft: "b"))
        XCTAssertFalse(TicketDetailLogic.isValidDescriptionChange(original: "a", draft: "a"))
    }

    func testDetailMoveCriterion() {
        let items = [
            TicketDetailLogic.DraftCriterion(id: "1", text: "First", done: false),
            TicketDetailLogic.DraftCriterion(id: "2", text: "Second", done: true),
            TicketDetailLogic.DraftCriterion(id: "3", text: "Third", done: false),
        ]
        let movedDown = TicketDetailLogic.moveCriterion(items, at: 0, delta: 1)
        XCTAssertEqual(movedDown.map(\.id), ["2", "1", "3"])
        let movedUp = TicketDetailLogic.moveCriterion(items, at: 2, delta: -1)
        XCTAssertEqual(movedUp.map(\.id), ["1", "3", "2"])
    }

    func testSavedViewQueryNormalization() {
        let parsed = TicketsLogic.parseQueryString("sort=priority&status=todo")
        XCTAssertEqual(parsed["sort"], "priority")
        XCTAssertEqual(parsed["status"], "todo")
        let normalizedA = TicketsLogic.normalizedViewQuery(["status": "todo", "sort": "priority"])
        let normalizedB = TicketsLogic.normalizedViewQuery(["sort": "priority", "status": "todo"])
        XCTAssertEqual(normalizedA, normalizedB)
    }

    func testNavItemIdentifiers() {
        XCTAssertEqual(TicketsNav.epicItemId("ep-1"), "epic:ep-1")
        XCTAssertEqual(TicketsNav.savedViewItemId("sv-9"), "sv:sv-9")
    }
}
