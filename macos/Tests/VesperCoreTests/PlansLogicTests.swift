import XCTest
@testable import VesperCore

final class PlansLogicTests: XCTestCase {
    func testPlanLiveStatusAndCounts() {
        XCTAssertTrue(PlansLogic.planLive(state: "planning", runState: "running"))
        XCTAssertTrue(PlansLogic.planLive(state: "planning", runState: "queued"))
        XCTAssertFalse(PlansLogic.planLive(state: "planning", runState: "failed"))
        XCTAssertFalse(PlansLogic.planLive(state: "planning", runState: "completed"))
        XCTAssertFalse(PlansLogic.planLive(state: "review", runState: "completed"))

        XCTAssertEqual(PlansLogic.planStatus(state: "review", runState: "completed"), .init(label: "Review", tone: .human))
        XCTAssertEqual(PlansLogic.planStatus(state: "accepted", runState: "completed"), .init(label: "Accepted", tone: .done))
        XCTAssertEqual(PlansLogic.planStatus(state: "dismissed", runState: "completed"), .init(label: "Dismissed", tone: .neutral))
        XCTAssertEqual(PlansLogic.planStatus(state: "planning", runState: "queued"), .init(label: "Queued", tone: .neutral))
        XCTAssertEqual(PlansLogic.planStatus(state: "planning", runState: "running"), .init(label: "Planning", tone: .review))
        XCTAssertEqual(PlansLogic.planStatus(state: "planning", runState: "cancelled"), .init(label: "Cancelled", tone: .neutral))
        XCTAssertEqual(PlansLogic.planStatus(state: "planning", runState: "failed"), .init(label: "Failed", tone: .blocked))

        XCTAssertEqual(PlansLogic.planCount(state: "planning", runState: "running", proposalCount: 0, acceptedCount: 0), "reading\u{2026}")
        XCTAssertEqual(PlansLogic.planCount(state: "review", runState: "completed", proposalCount: 0, acceptedCount: 0), "no proposals")
        XCTAssertEqual(PlansLogic.planCount(state: "review", runState: "completed", proposalCount: 4, acceptedCount: 0), "0/4 accepted")
        XCTAssertEqual(PlansLogic.planCount(state: "accepted", runState: "completed", proposalCount: 3, acceptedCount: 5), "5/5 accepted")
    }

    func testFirstLineAndBlockerKeysParsing() {
        XCTAssertEqual(PlansLogic.firstLine("\n  \n  Ship native plans  \nSecond line"), "Ship native plans")
        XCTAssertEqual(PlansLogic.parseBlockerKeys("pay-1,  PAY-2\npay-3"), ["PAY-1", "PAY-2", "PAY-3"])
    }

    func testDependencyProblemsDetectsCyclesAndUnselectedDependencies() {
        let a = API.TicketProposal(criteria: [], dependsOn: ["b"], description: "", ref: "a", title: "Alpha")
        let b = API.TicketProposal(criteria: [], dependsOn: ["a"], description: "", ref: "b", title: "Beta")
        let c = API.TicketProposal(criteria: [], dependsOn: ["d"], description: "", ref: "c", title: "Gamma")
        let d = API.TicketProposal(criteria: [], dependsOn: [], description: "", ref: "d", title: "Delta")

        // Valid DAG subset (c + d selected).
        XCTAssertTrue(PlansLogic.dependencyProblems(items: [c, d], selected: ["c", "d"]).isEmpty)

        // Unselected blocker d.
        let unselected = PlansLogic.dependencyProblems(items: [c, d], selected: ["c"])
        XCTAssertEqual(unselected.count, 1)
        XCTAssertTrue(unselected[0].contains("Gamma"))
        XCTAssertTrue(unselected[0].contains("Delta"))

        // Cycle between a and b.
        let cycle = PlansLogic.dependencyProblems(items: [a, b], selected: ["a", "b"])
        XCTAssertEqual(cycle.count, 1)
        XCTAssertTrue(cycle[0].contains("Dependency cycle"))
    }

    func testReadSourcesExtractsAndDeduplicatesMcpAndContextReads() {
        let events: [API.RunEvent] = [
            API.RunEvent(
                at: "2026-11-22T00:00:01Z",
                payload: [
                    "call_id": .string("c1"),
                    "tool": .string("mcp__vesper__get_ticket"),
                    "input": .object(["ticket": .string("LAZYAGENTS-307")]),
                ],
                seq: 1,
                type: .toolCall
            ),
            API.RunEvent(
                at: "2026-11-22T00:00:02Z",
                payload: ["call_id": .string("c1")],
                seq: 2,
                type: .toolResult
            ),
            API.RunEvent(
                at: "2026-11-22T00:00:03Z",
                payload: [
                    "call_id": .string("c2"),
                    "tool": .string("Read"),
                    "input": .object(["file_path": .string("/workspace/.lazyagents/context/spec.md")]),
                ],
                seq: 3,
                type: .toolCall
            ),
            API.RunEvent(
                at: "2026-11-22T00:00:04Z",
                payload: [
                    "call_id": .string("c3"),
                    "tool": .string("Read"),
                    "input": .object(["file_path": .string("/workspace/server/main.go")]),
                ],
                seq: 4,
                type: .toolCall
            ),
            API.RunEvent(
                at: "2026-11-22T00:00:05Z",
                payload: [
                    "call_id": .string("c4"),
                    "tool": .string("mcp__vesper__get_ticket"),
                    "input": .object(["ticket": .string("LAZYAGENTS-307")]),
                ],
                seq: 5,
                type: .toolCall
            ),
        ]

        let sources = PlansLogic.readSources(from: events)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].label, "LAZYAGENTS-307")
        XCTAssertEqual(sources[0].ref, "/tickets/LAZYAGENTS-307")
        XCTAssertTrue(sources[0].done)
        XCTAssertEqual(sources[1].label, "spec.md")
        XCTAssertFalse(sources[1].done)
    }

    func testNavModelFiltersPlansAndDecodesCommands() {
        func plan(id: String, project: String, goal: String, state: API.PlanningSession.State, runState: String) -> API.PlanningSession {
            API.PlanningSession(
                artifactId: nil,
                contextRefs: [],
                createdAt: "2026-11-22T00:00:00Z",
                epicId: nil,
                goal: goal,
                harness: "claude_code",
                id: id,
                model: "sonnet",
                outcome: nil,
                project: project,
                proposalCount: 3,
                proposals: [],
                readyKeys: [],
                revision: 1,
                runId: "run-\(id)",
                runState: runState,
                sourceVersionId: nil,
                state: state,
                ticketKeys: [],
                updatedAt: "2026-11-22T00:00:00Z"
            )
        }

        let plans = [
            plan(id: "p1", project: "PAY", goal: "Migrate billing\nMore detail", state: .review, runState: "completed"),
            plan(id: "p2", project: "WEB", goal: "Redesign sidebar", state: .accepted, runState: "completed"),
        ]
        let model = PlansLogic.navModel(plans: plans, projects: [], selectedId: "p1")
        XCTAssertEqual(model.id, PlansLogic.navId)
        XCTAssertEqual(model.selectedId, "p1")
        XCTAssertEqual(model.sections.first?.items.map(\.title), ["Migrate billing", "Redesign sidebar"])
        XCTAssertEqual(model.sections.first?.items.first?.status, .human)
        XCTAssertEqual(model.sections.first?.items.last?.status, .done)

        let bySpace = PlansLogic.navModel(plans: plans, projects: [], projectFilter: "WEB", selectedId: nil)
        XCTAssertEqual(bySpace.sections.first?.items.map(\.id), ["p2"])

        let bySearch = PlansLogic.navModel(plans: plans, projects: [], search: "billing", selectedId: nil)
        XCTAssertEqual(bySearch.sections.first?.items.map(\.id), ["p1"])

        XCTAssertEqual(PlansLogic.navAction(for: .navAction(navigatorId: PlansLogic.navId, actionId: PlansLogic.newPlanAction)), .newPlan)
        XCTAssertEqual(PlansLogic.navAction(for: .navActivate(navigatorId: PlansLogic.navId, itemId: "p1", newTab: true)), .selectPlan("p1", newTab: true))
        XCTAssertEqual(PlansLogic.navAction(for: .navFilter(navigatorId: PlansLogic.navId, filterId: PlansLogic.spaceFilterId, value: "PAY", checked: true)), .filterSpace("PAY"))
        XCTAssertEqual(PlansLogic.navAction(for: .navSearch(navigatorId: PlansLogic.navId, searchId: PlansLogic.searchId, value: "foo")), .search("foo"))
        XCTAssertEqual(PlansLogic.navAction(for: .navActivate(navigatorId: PlansLogic.navId, itemId: PlansLogic.retryItemId)), .retry)
        XCTAssertNil(PlansLogic.navAction(for: .navActivate(navigatorId: "other", itemId: "p1")))
    }
}
