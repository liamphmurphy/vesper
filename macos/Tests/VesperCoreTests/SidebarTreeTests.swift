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
}
