import XCTest
@testable import VesperCore

final class SidebarTreeTests: XCTestCase {
    private func sampleNav(outerExpanded: Bool, innerExpanded: Bool, sectionCollapsed: Bool? = nil) -> NavModel {
        let leaf = NavItem(id: "p:target", title: "Target Note")
        let inner = NavItem(id: "f:Zeta/Deep", title: "Deep", children: [leaf], expanded: innerExpanded)
        let outer = NavItem(id: "f:Zeta", title: "Zeta", children: [inner], expanded: outerExpanded)
        let top = NavItem(id: "home", title: "Home")
        return NavModel(
            id: "knowledge",
            sections: [
                NavSection(id: "home", items: [top]),
                NavSection(id: "tree", title: "Folders", items: [outer], collapsed: sectionCollapsed),
            ],
            selectedId: "p:target"
        )
    }

    func testVisibilityRespectsFolderAndSectionExpansion() {
        let collapsed = sampleNav(outerExpanded: false, innerExpanded: true)
        XCTAssertFalse(SidebarTree.isVisible("p:target", in: collapsed))
        XCTAssertTrue(SidebarTree.isVisible("f:Zeta", in: collapsed))
        XCTAssertTrue(SidebarTree.isVisible("home", in: collapsed))

        let expanded = sampleNav(outerExpanded: true, innerExpanded: true)
        XCTAssertTrue(SidebarTree.isVisible("p:target", in: expanded))

        // Local overrides take precedence over model flags.
        XCTAssertTrue(SidebarTree.isVisible("p:target", in: collapsed, expandedOverrides: ["f:Zeta": true]))
        XCTAssertFalse(SidebarTree.isVisible("p:target", in: expanded, expandedOverrides: ["f:Zeta/Deep": false]))
        XCTAssertFalse(SidebarTree.isVisible("p:target", in: expanded, collapsedOverrides: ["tree": true]))

        let collapsedSection = sampleNav(outerExpanded: true, innerExpanded: true, sectionCollapsed: true)
        XCTAssertFalse(SidebarTree.isVisible("p:target", in: collapsedSection))
        XCTAssertTrue(SidebarTree.isVisible("p:target", in: collapsedSection, collapsedOverrides: ["tree": false]))
        XCTAssertFalse(SidebarTree.isVisible("p:missing", in: expanded))
    }

    func testPathReturnsSectionAndAncestorFolders() {
        let nav = sampleNav(outerExpanded: false, innerExpanded: false)

        let target = SidebarTree.path(to: "p:target", in: nav)
        XCTAssertEqual(target?.sectionId, "tree")
        XCTAssertEqual(target?.ancestors, ["f:Zeta", "f:Zeta/Deep"])

        let top = SidebarTree.path(to: "home", in: nav)
        XCTAssertEqual(top?.sectionId, "home")
        XCTAssertEqual(top?.ancestors, [])

        XCTAssertNil(SidebarTree.path(to: "p:missing", in: nav))
    }

    func testAppsMenuGroupsYourAppsThenTools() {
        let apps = [
            ShellApp(id: "app:habits", label: "Habits", icon: "star", href: "/apps/habits"),
            ShellApp(id: "tool:/workflows", label: "Workflows", icon: "graph", href: "/workflows"),
            ShellApp(id: "app:budget", label: "Budget", icon: "dollar", href: "/apps/budget"),
            ShellApp(id: "tool:/http", label: "HTTP Client", icon: "plug", href: "/http"),
        ]
        let sections = SidebarTree.appsMenuSections(apps)
        XCTAssertEqual(sections.map(\.title), ["Your apps", "Tools"])
        XCTAssertEqual(sections[0].apps.map(\.label), ["Habits", "Budget"])
        XCTAssertEqual(sections[1].apps.map(\.label), ["Workflows", "HTTP Client"])
    }

    func testAppsMenuDropsEmptyGroups() {
        let tool = ShellApp(id: "tool:/reports", label: "Reports", icon: "dollar", href: "/reports")
        XCTAssertEqual(SidebarTree.appsMenuSections([tool]).map(\.title), ["Tools"])
        XCTAssertEqual(SidebarTree.appsMenuSections([]), [])
    }

    func testAreaClickHandlesNavigationCommandClickAndAppsMenu() {
        XCTAssertEqual(SidebarTree.areaClick(href: "/work", commandClick: false), .navigate("/work"))
        XCTAssertEqual(SidebarTree.areaClick(href: "/work", commandClick: true), .openInNewTab("/work"))
        XCTAssertEqual(SidebarTree.areaClick(href: "/apps", isAppsButton: true, hasApps: false, commandClick: false), .navigate("/apps"))
        XCTAssertEqual(SidebarTree.areaClick(href: "/apps", isAppsButton: true, hasApps: true, commandClick: false), .showAppsMenu)
        XCTAssertEqual(SidebarTree.areaClick(href: "/apps", isAppsButton: true, hasApps: true, commandClick: true), .openInNewTab("/apps"))
        XCTAssertEqual(SidebarTree.areaClick(href: "/apps", isAppsButton: true, hasApps: false, commandClick: true), .openInNewTab("/apps"))
    }
}
