import Foundation
import Observation
import SwiftUI
import VesperCore

/// What the page has told one window about itself; the sidebar, toolbar and title read it.
@MainActor
@Observable
final class ShellState {
    var shell: ShellModel?
    /// The sidebar's list: the native screen's when it publishes one, else the page's.
    private(set) var navigator: NavModel? {
        didSet { dropStaleOverrides(old: oldValue, new: navigator) }
    }
    /// The list the page describes; it keeps updating under a native screen's.
    var pageNavigator: NavModel? {
        didSet { syncNavigator() }
    }
    /// The page's effective color mode (it may differ from macOS's when the person forces Dark or Light).
    var pageMode: ColorMode?
    /// True while the page draws a screen's list in its own fallback column.
    var navigatorFallback = false
    /// The page asked for the sidebar to fold (theater mode); per tab, so switching tabs restores it.
    var sidebarHidden = false
    /// The web view's own document title, used until the page sends its `title` message.
    var documentTitle: String?
    /// The right rail the page describes; nil when it has none.
    var rail: RailModel?
    /// The page's palette and text size, for native screens; nil until the page sends them.
    var theme: ThemeTokens?

    // What the page describes (title, toolbar, inspector). While a native screen shows, its own
    // chrome replaces these; they keep updating underneath and return when it goes away.
    var pageTitle: String?
    var pageSubtitle: String?
    var pageTitleMenu: [MenuItem]?
    var pageToolbarItems: [ShellToolbarItem] = []
    var pageInspector: InspectorModel?
    /// The native screen showing in this tab and the chrome it describes; nil while the web view shows.
    var native: NativeChrome? {
        didSet { syncNavigator() }
    }
    /// Custom native sidebar content (e.g., Knowledge's compact NSOutlineView explorer), replacing NavModel list when set.
    var nativeSidebar: AnyView?
    /// Custom native inspector body builder keyed by tab id, used by `.native` inspector tabs when non-nil.
    var nativeInspectorView: ((String) -> AnyView?)?

    static let defaultCompanionKey = "VesperNativeCompanionOpen"
    /// Open state of the native default companion inspector for native screens with no custom inspector.
    private(set) var defaultCompanionOpen = UserDefaults.standard.bool(forKey: ShellState.defaultCompanionKey)

    func setDefaultCompanionOpen(_ open: Bool) {
        guard defaultCompanionOpen != open else { return }
        defaultCompanionOpen = open
        UserDefaults.standard.set(open, forKey: Self.defaultCompanionKey)
    }

    var usesDefaultCompanion: Bool { native != nil && native?.inspector == nil }

    var title: String? { native.map(\.title) ?? pageTitle }
    var subtitle: String? { native.map(\.subtitle) ?? pageSubtitle }
    /// The title's own menu (rename, archive…).
    var titleMenu: [MenuItem]? { native.map(\.titleMenu) ?? pageTitleMenu }
    var toolbarItems: [ShellToolbarItem] { native?.toolbarItems ?? pageToolbarItems }
    /// The native inspector the screen describes; native screens without a custom inspector fall back
    /// to the default companion (`WorkChat`), while web screens keep `pageInspector`.
    var inspector: InspectorModel? {
        InspectorLogic.effectiveInspector(
            nativeActive: native != nil,
            nativeInspector: native?.inspector,
            pageInspector: pageInspector,
            defaultCompanionOpen: defaultCompanionOpen,
            path: route
        )
    }
    var route: String?
    /// The area the page last reported with its route.
    var area: AreaId?
    /// The native screen's area, set with it by the shell.
    var nativeArea: AreaId?
    /// The area the area bar and tab icon mark. Under a native screen the web view is hidden and
    /// its reported route can lag or stick (it kept Knowledge lit after going back to Chat), so the
    /// shown screen's own area wins.
    var currentArea: AreaId? { native != nil ? (native?.areaOverride ?? nativeArea) : area }
    /// The page has sent `ready`: commands will be heard.
    var ready = false

    // Native window state.
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    /// A failed navigation, shown over the page with Retry.
    var loadError: String?

    // Local expand/collapse taps, until the page's own value for that row or section changes
    // (a page-driven "Collapse all" must win over an earlier tap).
    var expandedOverrides: [String: Bool] = [:]
    var collapsedOverrides: [String: Bool] = [:]

    // One click, one command: a row click activates; the triangle alone toggles.
    private var lastActivate: (id: String, at: Date)?
    private var pendingToggles: [String: Task<Void, Never>] = [:]

    func noteActivate(_ id: String) {
        lastActivate = (id, Date())
        if pendingToggles.removeValue(forKey: id).map({ $0.cancel() }) != nil { expandedOverrides[id] = nil }
    }

    func recentlyActivated(_ id: String) -> Bool {
        guard let last = lastActivate, last.id == id else { return false }
        return Date().timeIntervalSince(last.at) < 0.35
    }

    /// Sends the toggle shortly after the click, so a title click that also flips the disclosure can cancel it.
    func scheduleToggle(_ id: String, send: @escaping @MainActor () -> Void) {
        pendingToggles[id]?.cancel()
        pendingToggles[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.pendingToggles[id] = nil
            send()
        }
    }

    private func syncNavigator() {
        let next = native?.navigator ?? pageNavigator
        if next != navigator { navigator = next }
    }

    private func dropStaleOverrides(old: NavModel?, new: NavModel?) {
        guard let new, old?.id == new.id, let old else { expandedOverrides = [:]; collapsedOverrides = [:]; return }
        let before = Self.expandedValues(old), after = Self.expandedValues(new)
        expandedOverrides = expandedOverrides.filter { before[$0.key] == after[$0.key] }
        let oldSections = Dictionary(old.sections.map { ($0.id, $0.collapsed ?? false) }, uniquingKeysWith: { a, _ in a })
        let newSections = Dictionary(new.sections.map { ($0.id, $0.collapsed ?? false) }, uniquingKeysWith: { a, _ in a })
        collapsedOverrides = collapsedOverrides.filter { oldSections[$0.key] == newSections[$0.key] }
        // When navigation switches selection (e.g. via the command palette), clear any local
        // collapse overrides along the new target's path so the sidebar reveals it.
        if let selected = new.selectedId, selected != old.selectedId,
           let path = SidebarTree.path(to: selected, in: new) {
            collapsedOverrides[path.sectionId] = nil
            for ancestor in path.ancestors {
                expandedOverrides[ancestor] = nil
            }
        }
    }

    private static func expandedValues(_ nav: NavModel) -> [String: Bool] {
        var out: [String: Bool] = [:]
        func walk(_ items: [NavItem]) {
            for item in items {
                if let children = item.children, !children.isEmpty { out[item.id] = item.expanded ?? false; walk(children) }
            }
        }
        for section in nav.sections { walk(section.items) }
        return out
    }

    /// Fixed top of the sidebar until the page describes its own.
    static let fallbackShell = ShellModel(
        areas: [
            ShellArea(id: .chat, label: "Chat", icon: "msg", href: "/chat"),
            ShellArea(id: .spaces, label: "Spaces", icon: "spaces", href: "/spaces"),
            ShellArea(id: .knowledge, label: "Knowledge", icon: "wiki", href: "/knowledge"),
            ShellArea(id: .library, label: "Library", icon: "library", href: "/library"),
        ],
        apps: [], currentArea: nil)
}
