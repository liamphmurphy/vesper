import Foundation
import Observation
import VesperCore

/// What the page has told one window about itself; the sidebar, toolbar and title read it.
@MainActor
@Observable
final class ShellState {
    var shell: ShellModel?
    var navigator: NavModel? {
        didSet { expandedOverrides = [:]; collapsedOverrides = [:] }
    }
    /// True while the page draws a screen's list in its own fallback column.
    var navigatorFallback = false
    var toolbarItems: [ToolbarItem] = []
    var title: String?
    var subtitle: String?
    var route: String?
    var area: AreaId?
    /// The page has sent `ready`: commands will be heard.
    var ready = false

    // Native window state.
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    /// A failed navigation, shown over the page with Retry.
    var loadError: String?

    // Local expand/collapse taps, until the page sends a new model.
    var expandedOverrides: [String: Bool] = [:]
    var collapsedOverrides: [String: Bool] = [:]

    /// Fixed top of the sidebar until the page describes its own.
    static let fallbackShell = ShellModel(
        areas: [
            ShellArea(id: .chat, label: "Chat", icon: "msg", href: "/chat"),
            ShellArea(id: .work, label: "Work", icon: "tickets", href: "/work"),
            ShellArea(id: .knowledge, label: "Knowledge", icon: "wiki", href: "/knowledge"),
            ShellArea(id: .library, label: "Library", icon: "library", href: "/library"),
        ],
        apps: [], currentArea: nil)
}
