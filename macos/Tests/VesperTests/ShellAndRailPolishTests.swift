import AppKit
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("ShellAndRailPolish")
struct ShellAndRailPolishTests {
    @Test("hides duplicate section header when sole section repeats navigator title (e.g. Spaces)")
    func hidesRedundantSpacesSectionHeader() {
        let section = NavSection(
            id: "spaces",
            title: "Spaces",
            items: [],
            badge: NavBadge(text: "4")
        )
        let spacesNav = NavModel(id: "spaces", title: "Spaces", sections: [section])
        #expect(SidebarView.hidesRedundantSectionHeader(nav: spacesNav, section: section))

        // Distinct section titles or multi-section navigators keep their section headers.
        let secondSection = NavSection(id: "archived", title: "Archived", items: [])
        let multiNav = NavModel(id: "spaces", title: "Spaces", sections: [section, secondSection])
        #expect(!SidebarView.hidesRedundantSectionHeader(nav: multiNav, section: section))

        let collapsibleSection = NavSection(id: "spaces", title: "Spaces", items: [], collapsible: true)
        let collapsibleNav = NavModel(id: "spaces", title: "Spaces", sections: [collapsibleSection])
        #expect(!SidebarView.hidesRedundantSectionHeader(nav: collapsibleNav, section: collapsibleSection))
    }

    @Test("RailButton shows trailing accent bar and palette tint only when active")
    func railButtonActiveAccentBar() {
        let button = RailButton { _ in }
        let theme = ThemeTokens(mode: .dark)
        let inactive = RailItem(id: "dock.tab:activity", label: "Activity", icon: "activity", status: .accent, active: false)
        button.configure(inactive, theme: theme)
        #expect(!button.isActiveBarVisible)

        let active = RailItem(id: "dock.tab:activity", label: "Activity", icon: "activity", status: .accent, active: true)
        button.configure(active, theme: theme)
        #expect(button.isActiveBarVisible)
    }
}
