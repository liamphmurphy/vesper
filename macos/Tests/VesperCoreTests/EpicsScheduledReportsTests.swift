import Foundation
import XCTest
@testable import VesperCore

final class EpicsScheduledReportsTests: XCTestCase {

    func testReportsCurrencyAndAxisFormatting() {
        XCTAssertEqual(ReportsLogic.usd(micros: 412_370_000), "$412.37")
        XCTAssertEqual(ReportsLogic.usd(micros: 4_500), "$0.005")
        XCTAssertEqual(ReportsLogic.usd(micros: 200), "< $0.001")
        XCTAssertEqual(ReportsLogic.spendLabel(micros: 1_000_000, unpricedRuns: 1), "≥ $1.00")
        XCTAssertEqual(ReportsLogic.spendLabel(micros: 0, unpricedRuns: 1), "Unknown")
        XCTAssertEqual(ReportsLogic.share(part: 1, total: 4), "25.0%")
        XCTAssertEqual(ReportsLogic.share(part: 1, total: 0), "–")
        XCTAssertEqual(ReportsLogic.costPerPoint(micros: 6_000_000, points: 3), "$2.00")
        XCTAssertNil(ReportsLogic.costPerPoint(micros: 6_000_000, points: 0))
        XCTAssertEqual(ReportsLogic.axisMax(maxMicros: 2_100_000), 2_500_000)
    }

    func testReportsDateRangeValidationAndStacking() {
        XCTAssertNil(ReportsLogic.rangeError(from: "2026-11-01", to: "2026-11-10"))
        XCTAssertNotNil(ReportsLogic.rangeError(from: "2026-11-10", to: "2026-11-01"))
        XCTAssertNotNil(ReportsLogic.rangeError(from: "2025-01-01", to: "2026-11-01"))

        let days = [
            API.CostDay(
                agents: [
                    API.CostPart(costMicros: 500_000, key: "a1"),
                    API.CostPart(costMicros: 300_000, key: "a2"),
                    API.CostPart(costMicros: 100_000, key: "a3"),
                ],
                costMicros: 900_000,
                date: "2026-11-01",
                models: [],
                runs: 3
            ),
        ]
        let stacked = ReportsLogic.stackSeries(days: days, by: .agents, top: 2)
        XCTAssertEqual(stacked.keys, ["a1", ReportsLogic.otherKey])
        XCTAssertEqual(stacked.totals.first?.costMicros, 500_000)
        XCTAssertEqual(stacked.totals.last?.costMicros, 400_000)
        let points = ReportsLogic.chartPoints(from: stacked, by: .agents, agentNames: ["a1": "Ada"])
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.seriesLabel, "Ada")
    }

    func testScheduledValidationAndCron() {
        let validCron = ScheduledLogic.validateCron("0 8 * * 1-5")
        XCTAssertTrue(validCron.isValid)
        let invalidCron = ScheduledLogic.validateCron("not a cron")
        XCTAssertFalse(invalidCron.isValid)

        var draft = ScheduledLogic.TaskDraft.blank()
        XCTAssertNil(draft.maxMinutes)
        XCTAssertNil(draft.maxCostMicros)
        XCTAssertFalse(ScheduledLogic.validate(draft).isValid)
        draft.name = "Daily Digest"
        XCTAssertTrue(ScheduledLogic.validate(draft).isValid)
        let unlimitedInput = draft.toInput()
        XCTAssertNil(unlimitedInput.maxMinutes)
        XCTAssertNil(unlimitedInput.maxCostMicros)

        draft.maxMinutes = 0
        XCTAssertFalse(ScheduledLogic.validate(draft).isValid)
        draft.maxMinutes = 45
        draft.maxCostMicros = 5_000
        XCTAssertFalse(ScheduledLogic.validate(draft).isValid)
        draft.maxCostMicros = 2_500_000
        XCTAssertTrue(ScheduledLogic.validate(draft).isValid)
        let cappedInput = draft.toInput()
        XCTAssertEqual(cappedInput.maxMinutes, 45)
        XCTAssertEqual(cappedInput.maxCostMicros, 2_500_000)

        draft.frequency = .weekly
        draft.weekdays = []
        XCTAssertFalse(ScheduledLogic.validate(draft).isValid)
    }

    func testEpicsOverdueAndRatioHelpers() {
        XCTAssertEqual(EpicsLogic.ratio(done: 2, total: 4), 0.5, accuracy: 0.001)
        XCTAssertEqual(EpicsLogic.ratio(done: 0, total: 0), 0.0, accuracy: 0.001)
        XCTAssertTrue(EpicsLogic.isOverdue(status: .open, targetDate: "2026-11-01", today: "2026-11-22"))
        XCTAssertFalse(EpicsLogic.isOverdue(status: .done, targetDate: "2026-11-01", today: "2026-11-22"))
        XCTAssertFalse(EpicsLogic.isOverdue(status: .open, targetDate: "2026-12-01", today: "2026-11-22"))
    }

    func testReportsNavModelAndCommands() {
        let projects = [
            API.Project(archived: false, color: "green", defaultBranch: "main", id: "p1", key: "PAY", name: "Payments", revision: 1),
            API.Project(archived: true, color: "gray", defaultBranch: "main", id: "p2", key: "OLD", name: "Archived", revision: 1),
        ]
        let costsNav = ReportsLogic.navModel(
            tab: .costs,
            preset: .days30,
            groupBy: .agents,
            projectFilter: "PAY",
            projects: projects
        )
        XCTAssertEqual(costsNav.id, ReportsLogic.navId)
        XCTAssertEqual(costsNav.picker?.value, "costs")
        XCTAssertEqual(costsNav.filters?.map(\.id), [ReportsLogic.rangeFilterId, ReportsLogic.groupFilterId])
        XCTAssertEqual(costsNav.sections.first?.items.map(\.id), ["space:", "space:PAY"])
        XCTAssertEqual(costsNav.selectedId, "space:PAY")

        let highlightsNav = ReportsLogic.navModel(
            tab: .highlights,
            preset: .days7,
            groupBy: .models,
            projectFilter: "",
            projects: projects
        )
        XCTAssertEqual(highlightsNav.filters?.map(\.id), [ReportsLogic.rangeFilterId])
        XCTAssertEqual(highlightsNav.selectedId, "space:")

        XCTAssertEqual(
            ReportsLogic.navAction(for: .navPicker(navigatorId: ReportsLogic.navId, pickerId: ReportsLogic.tabPickerId, value: "highlights")),
            .selectTab(.highlights)
        )
        XCTAssertEqual(
            ReportsLogic.navAction(for: .navFilter(navigatorId: ReportsLogic.navId, filterId: ReportsLogic.rangeFilterId, value: "90", checked: true)),
            .selectRange(.days90)
        )
        XCTAssertEqual(
            ReportsLogic.navAction(for: .navFilter(navigatorId: ReportsLogic.navId, filterId: ReportsLogic.groupFilterId, value: "models", checked: true)),
            .selectGroup(.models)
        )
        XCTAssertEqual(
            ReportsLogic.navAction(for: .navActivate(navigatorId: ReportsLogic.navId, itemId: "space:PAY")),
            .selectSpace("PAY")
        )
        XCTAssertNil(ReportsLogic.navAction(for: .navActivate(navigatorId: "other", itemId: "space:PAY")))
    }
}
