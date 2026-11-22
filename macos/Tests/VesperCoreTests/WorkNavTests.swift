import XCTest
@testable import VesperCore

/// Ported from the Work cases of web/lib/native-shell/screens.test.mjs.
final class WorkNavTests: XCTestCase {
    private func input() -> WorkNav.Input {
        var i = WorkNav.Input()
        i.project = "VES"
        i.projects = [("VES", "Vesper", false), ("OLD", "Old", true)]
        i.agents = [("ada", "Ada")]
        i.filter = .needsYou
        i.counts = WorkLogic.ViewCounts(all: 5, needsYou: 2, active: 1, failed: 0)
        i.needs = [WorkNav.NeedsRow(id: "n1", title: "Review", trailing: "2h")]
        i.groups = [WorkNav.Group(label: "Active", runs: [
            WorkNav.RunRow(id: "r1", title: "Fix bug", avatar: Avatar(initials: "A", color: "#A3A6FF"), trailing: "wait", dot: .human),
        ])]
        i.statusLine = ("1 busy · 4 slots · $2.00 7d", "/reports?tab=costs&range=7&project=VES")
        return i
    }

    func testHeaderOverviewViewMenuAndWaitingAfterActive() {
        let m = WorkNav.model(input())
        XCTAssertEqual(m.id, "work-activity")
        XCTAssertEqual(m.title, "Work")
        XCTAssertEqual(m.actions?.map(\.id), ["new-ticket"])
        XCTAssertEqual(m.filters?.map(\.id), ["filter-space", "filter-agent", "view"])
        XCTAssertEqual(m.filters?[0].options.map { [$0.value, "\($0.checked)"] }, [["", "false"], ["VES", "true"]])
        XCTAssertEqual(m.filters?[1].options.map(\.label), ["All personas", "Ada"])
        XCTAssertEqual(m.filters?[2].options.map { "\($0.value) \($0.label) \($0.checked)" }, [
            "all All runs (5) false", "needs_you Needs you (2) true", "active Running & queued (1) false", "failed Failed today (0) false",
        ])
        XCTAssertEqual(m.picker?.value, "activity")
        XCTAssertEqual(m.picker?.options.map(\.label), ["Runs", "Tasks"])
        XCTAssertEqual(m.search?.placeholder, "Filter runs…")
        XCTAssertEqual(m.sections.map(\.id), ["overview", "runs-Active", "needs-you", "status"])
        XCTAssertEqual(m.sections[0].items[0].id, "work:overview")
        XCTAssertEqual(m.sections[0].items[0].badge, NavBadge(text: "2", tone: .human))
        XCTAssertEqual(m.sections[1...2].map(\.title), ["Active", "Waiting"])
        XCTAssertEqual(m.sections[1...2].map(\.badge), [NavBadge(text: "1"), NavBadge(text: "1")])
        let row = m.sections[1].items[0]
        XCTAssertEqual(row, NavItem(id: "run:r1", title: "Fix bug", avatar: Avatar(initials: "A", color: "#A3A6FF"), status: .human, trailing: "wait"))
        XCTAssertNil(row.href)
        XCTAssertEqual(m.sections[2].items[0].icon, "inbox")
        XCTAssertEqual(m.sections[3].items[0].href, "/reports?tab=costs&range=7&project=VES")
        XCTAssertEqual(m.selectedId, "work:overview")
    }

    func testNeedsComeFirstWithoutAnActiveGroupAndLoadMoreLast() {
        var i = input()
        i.groups = [WorkNav.Group(label: "Yesterday", runs: [WorkNav.RunRow(id: "r2", title: "Old", avatar: nil, trailing: "1d", dot: .done)])]
        i.hasMore = true
        i.activityCount = 3
        let m = WorkNav.model(i)
        XCTAssertEqual(m.sections.map(\.id), ["overview", "needs-you", "runs-Yesterday", "more", "status"])
        XCTAssertEqual(m.sections[1].title, "Needs you")
        XCTAssertNil(m.sections[2].items[0].status, "a finished run has no status dot, as on the web")
        XCTAssertEqual(m.sections[3].items[0].id, "load-more")
        XCTAssertEqual(m.picker?.options.first?.label, "Runs 3")
    }

    func testLoadingErrorAndEmptyStates() {
        var i = WorkNav.Input()
        i.loading = true
        XCTAssertEqual(WorkNav.model(i).sections.map(\.id), ["overview", "loading"])
        XCTAssertEqual(WorkNav.model(i).sections[1].emptyText, "Loading")
        i.loading = false
        i.error = "boom"
        XCTAssertEqual(WorkNav.model(i).sections[1].items.map(\.id), ["retry"])
        i.error = nil
        XCTAssertEqual(WorkNav.model(i).sections[1].emptyText, "No runs in this view.")
        i.search = "x"
        XCTAssertEqual(WorkNav.model(i).sections[1].emptyText, "No runs match.")
        XCTAssertEqual(WorkNav.model(i).sections.count, 2, "no status line without text")
    }

    func testAvatarsFallBackToTheAgentsHueAndInitials() {
        let agent = API.AgentRef(colorIndex: 9, handle: "ada", id: "a1", name: "Ada Lovelace")
        let plain = WorkNav.avatar(for: agent, personas: [], base: nil) { $0 == "quill" ? "#112233" : nil }
        XCTAssertEqual(plain, Avatar(initials: "AL", color: "#112233"))
        XCTAssertEqual(WorkNav.avatar(for: agent, personas: [], base: nil) { _ in "var(--x)" }.color, nil)
        XCTAssertEqual(WorkNav.initials("  Assistant "), "A")
        XCTAssertEqual(WorkNav.initials(""), "?")
    }

    func testCommandsDecode() {
        let id = WorkNav.id
        XCTAssertEqual(WorkNav.action(for: .navAction(navigatorId: id, actionId: "new-ticket"), project: "VES"),
                       .open("/tickets/new?project=VES", newTab: false))
        XCTAssertEqual(WorkNav.action(for: .navFilter(navigatorId: id, filterId: "filter-space", value: "", checked: true), project: nil), .project(""))
        XCTAssertEqual(WorkNav.action(for: .navFilter(navigatorId: id, filterId: "filter-agent", value: "ada", checked: true), project: nil), .agent("ada"))
        XCTAssertEqual(WorkNav.action(for: .navFilter(navigatorId: id, filterId: "view", value: "failed", checked: true), project: nil), .filter(.failed))
        XCTAssertNil(WorkNav.action(for: .navFilter(navigatorId: id, filterId: "view", value: "bogus", checked: true), project: nil))
        XCTAssertEqual(WorkNav.action(for: .navPicker(navigatorId: id, pickerId: "work-view", value: "tickets"), project: "VES"),
                       .open("/tickets?project=VES", newTab: false))
        XCTAssertEqual(WorkNav.action(for: .navPicker(navigatorId: id, pickerId: "work-view", value: "activity"), project: nil), .overview)
        XCTAssertEqual(WorkNav.action(for: .navSearch(navigatorId: id, searchId: "work-search", value: "q"), project: nil), .search("q"))
        XCTAssertEqual(WorkNav.action(for: .navActivate(navigatorId: id, itemId: "work:overview"), project: nil), .overview)
        XCTAssertEqual(WorkNav.action(for: .navActivate(navigatorId: id, itemId: "load-more"), project: nil), .loadMore)
        XCTAssertEqual(WorkNav.action(for: .navActivate(navigatorId: id, itemId: "retry"), project: nil), .retry)
        XCTAssertEqual(WorkNav.action(for: .navActivate(navigatorId: id, itemId: "run:r1", newTab: true), project: nil), .openRun("r1", newTab: true))
        XCTAssertEqual(WorkNav.action(for: .navActivate(navigatorId: id, itemId: "needs:n1"), project: nil), .openNeeds("n1", newTab: false))
        XCTAssertNil(WorkNav.action(for: .navActivate(navigatorId: "runs", itemId: "run:r1"), project: nil), "another navigator's command")
        XCTAssertNil(WorkNav.action(for: .toolbarAction(itemId: "work.needs"), project: nil))
    }
}
