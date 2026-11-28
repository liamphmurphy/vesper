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

    @Test("RailButton uses instant HoverTooltipPresenter with shortcut hints instead of native NSView toolTip")
    func railButtonUsesInstantHoverTooltip() {
        let presenter = HoverTooltipPresenter(requiresKeyWindow: false, verifiesMouseInside: false, delayOverrideMs: 0)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = root

        let button = RailButton(tooltipPresenter: presenter) { _ in }
        button.frame = NSRect(x: 360, y: 120, width: 32, height: 32)
        root.addSubview(button)

        let theme = ThemeTokens(mode: .dark)
        let item = RailItem(id: "settings", label: "Settings", icon: "gear", active: false)
        button.configure(item, theme: theme)
        #expect(button.toolTip == nil)

        let dummyEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            trackingNumber: 1,
            userData: nil
        )!
        button.mouseEntered(with: dummyEvent)
        #expect(presenter.isVisible)
        #expect(presenter.currentText == "Settings")
        #expect(presenter.currentHint == "⌘,")

        // Updating the configured item while hovered refreshes the tooltip live.
        let activeTab = RailItem(id: "dock.tab:activity", label: "Activity (working)", icon: "activity", active: true)
        button.configure(activeTab, theme: theme)
        #expect(presenter.currentText == "Activity (working)")
        #expect(presenter.currentHint == "⌘\\")

        button.mouseExited(with: dummyEvent)
        #expect(!presenter.isVisible)
    }
}
