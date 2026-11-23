import XCTest
@testable import VesperCore

final class AgentDetailLogicTests: XCTestCase {
    func testTabNormalizationHandlesLegacyAliases() {
        XCTAssertEqual(AgentDetailLogic.Tab.from(queryParam: nil), .overview)
        XCTAssertEqual(AgentDetailLogic.Tab.from(queryParam: "scopes"), .scopes)
        XCTAssertEqual(AgentDetailLogic.Tab.from(queryParam: "definition"), .settings)
        XCTAssertEqual(AgentDetailLogic.Tab.from(queryParam: "runs"), .activity)
        XCTAssertEqual(AgentDetailLogic.Tab.from(queryParam: "unknown"), .overview)
    }

    func testWildcardScopeEvaluationAndProjectTightening() {
        let agent: [String: API.ScopeMode] = [
            "db:*": .allowed,
            "db:drop": .denied,
            "git:push": .requiresApproval,
        ]
        XCTAssertEqual(AgentDetailLogic.modeFor(scopes: agent, scope: "db:read").mode, .allowed)
        XCTAssertEqual(AgentDetailLogic.modeFor(scopes: agent, scope: "db:drop").mode, .denied)
        XCTAssertEqual(AgentDetailLogic.modeFor(scopes: agent, scope: "unknown:op").mode, .denied)

        // Project overrides can tighten allowed -> requiresApproval, never widen denied -> allowed.
        let override: [String: API.ScopeMode] = [
            "db:read": .requiresApproval,
            "db:drop": .allowed,
        ]
        let effRead = AgentDetailLogic.effectiveMode(agent: agent, override: override, scope: "db:read")
        XCTAssertEqual(effRead.mode, .requiresApproval)
        XCTAssertEqual(effRead.source, "project")

        let effDrop = AgentDetailLogic.effectiveMode(agent: agent, override: override, scope: "db:drop")
        XCTAssertEqual(effDrop.mode, .denied)
        XCTAssertEqual(effDrop.source, "agent")
    }

    func testScopeChangesClassification() {
        let before: [String: API.ScopeMode] = ["git:push": .denied, "shell": .allowed]
        let after: [String: API.ScopeMode] = ["git:push": .requiresApproval, "shell": .denied]
        let changes = AgentDetailLogic.scopeChanges(before: before, after: after)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first(where: { $0.scope == "git:push" })?.kind, .approval)
        XCTAssertEqual(changes.first(where: { $0.scope == "shell" })?.kind, .tightens)
    }

    func testNavModelListsAgentsAndSections() {
        let pike = API.Agent(
            colorIndex: 0,
            handle: "pike",
            id: "ag-1",
            kind: .main,
            model: "sonnet",
            name: "Pike",
            role: "Engineer",
            specialty: "Go",
            status: .running
        )
        let nav = AgentDetailLogic.navModel(
            agents: [pike],
            overviews: [],
            activeHandle: "pike",
            activeTab: .scopes
        )
        XCTAssertEqual(nav.id, AgentDetailLogic.navId)
        XCTAssertEqual(nav.selectedId, "agent:pike")
        XCTAssertEqual(nav.sections.map(\.id), ["agents", "sections"])
        XCTAssertEqual(nav.sections[0].items.first?.status, .done)
        XCTAssertEqual(nav.sections[1].items.first(where: { $0.id == "tab:scopes" })?.trailing, "Current")

        XCTAssertEqual(
            AgentDetailLogic.navAction(for: .navAction(navigatorId: AgentDetailLogic.navId, actionId: AgentDetailLogic.backToWorkAction)),
            .backToWork
        )
        XCTAssertEqual(
            AgentDetailLogic.navAction(for: .navActivate(navigatorId: AgentDetailLogic.navId, itemId: "agent:pike", newTab: true)),
            .openAgent(handle: "pike", newTab: true)
        )
        XCTAssertEqual(
            AgentDetailLogic.navAction(for: .navActivate(navigatorId: AgentDetailLogic.navId, itemId: "tab:tokens")),
            .selectTab(.tokens)
        )
    }
}
