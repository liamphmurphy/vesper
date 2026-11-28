import Foundation
import Observation
import SwiftUI
import VesperCore

/// Per-tab shell state read by the sidebar, toolbar, inspector, and window title.
@MainActor
@Observable
final class ShellState {
    /// The sidebar's list published by the active native screen.
    private(set) var navigator: NavModel? {
        didSet { dropStaleOverrides(old: oldValue, new: navigator) }
    }
    /// The tab's effective color mode (may differ from macOS's when the person forces Dark or Light).
    var pageMode: ColorMode?
    /// Screen requested the sidebar to fold (e.g. Dev terminal theater mode, Browser focus mode); per tab, so switching tabs restores it.
    var sidebarHidden = false
    /// Screen requested the trailing 44pt rail to hide (e.g. Browser focus mode); per tab, so switching tabs restores it.
    var railHidden = false
    /// Playground web view's document title.
    var documentTitle: String?
    /// Active palette and text size for native screens.
    var theme: ThemeTokens?

    /// The native screen showing in this tab and the chrome it describes; nil for playground tabs.
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

    var title: String? { native?.title }
    var subtitle: String? { native?.subtitle }
    /// The title's own menu (rename, archive…).
    var titleMenu: [MenuItem]? { native?.titleMenu }
    var toolbarItems: [ShellToolbarItem] { native?.toolbarItems ?? [] }
    /// The native inspector the screen describes; native screens without a custom inspector fall back
    /// to the default companion (`WorkChat`).
    var inspector: InspectorModel? {
        InspectorLogic.effectiveInspector(
            nativeActive: native != nil,
            nativeInspector: native?.inspector,
            pageInspector: nil,
            defaultCompanionOpen: defaultCompanionOpen,
            path: route
        )
    }
    var route: String?
    /// The native screen's area, set with it by the shell.
    var nativeArea: AreaId?
    /// The area the area bar and tab icon mark.
    var currentArea: AreaId? { native?.areaOverride ?? nativeArea }
    /// Live activity state shown as a compact badge in the tab strip.
    var tabActivity: TabActivityStatus? { native?.tabActivity }

    // Tab navigation state (native history stack for Vesper tabs, WKWebView for playgrounds).
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    /// A failed navigation, shown over the tab with Retry.
    var loadError: String?

    // Local expand/collapse taps, until the screen's own value for that row or section changes.
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
        let next = native?.navigator
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

    /// Fixed top-level areas shown in the sidebar and tab icons.
    static let fallbackShell = ShellModel(
        areas: [
            ShellArea(id: .chat, label: "Chat", icon: "msg", href: "/chat"),
            ShellArea(id: .spaces, label: "Spaces", icon: "spaces", href: "/spaces"),
            ShellArea(id: .knowledge, label: "Knowledge", icon: "wiki", href: "/knowledge"),
            ShellArea(id: .library, label: "Library", icon: "library", href: "/library"),
            ShellArea(id: .browser, label: "Browser", icon: "compass", href: "/browser"),
        ],
        apps: [], currentArea: nil)
}
