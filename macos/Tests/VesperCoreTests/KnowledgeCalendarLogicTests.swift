import XCTest
@testable import VesperCore

final class KnowledgeCalendarLogicTests: XCTestCase {
    func testMonthGridMondayFirstLayout() {
        // November 2026 starts on Sunday (lead = 6) and has 30 days.
        let weeks = KnowledgeCalendarLogic.monthGrid(year: 2026, month: 11)
        XCTAssertEqual(weeks.count, 6)
        XCTAssertEqual(weeks[0], [nil, nil, nil, nil, nil, nil, 1])
        XCTAssertEqual(weeks[1], [2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(weeks[5], [30, nil, nil, nil, nil, nil, nil])

        // June 2026 starts on Monday (lead = 0) and has 30 days.
        let june = KnowledgeCalendarLogic.monthGrid(year: 2026, month: 6)
        XCTAssertEqual(june.first, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(june.last, [29, 30, nil, nil, nil, nil, nil])
    }

    func testShiftedMonthWrapsYears() {
        let dec = KnowledgeCalendarLogic.shiftedMonth(year: 2026, month: 1, delta: -1)
        XCTAssertEqual(dec.year, 2025)
        XCTAssertEqual(dec.month, 12)

        let jan = KnowledgeCalendarLogic.shiftedMonth(year: 2026, month: 12, delta: 1)
        XCTAssertEqual(jan.year, 2027)
        XCTAssertEqual(jan.month, 1)
    }

    func testISODayAndFolderSanitization() {
        XCTAssertEqual(KnowledgeCalendarLogic.isoDay(year: 2026, month: 3, day: 7), "2026-03-07")
        XCTAssertEqual(KnowledgeCalendarLogic.monthTitle(year: 2026, month: 11), "November 2026")
        XCTAssertEqual(KnowledgeCalendarLogic.sanitizedFolder(" /Campaign/NPCs/ "), "Campaign/NPCs")
    }
}
