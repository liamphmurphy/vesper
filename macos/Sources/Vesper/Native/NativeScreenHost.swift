import AppKit
import SwiftUI
import VesperCore

/// Everything a native screen gets from its tab: the route it shows, the shared data store,
/// navigation, find, and the chrome it describes.
@MainActor
@Observable
final class NativeScreenContext {
    private(set) var match: NativeRouteMatch
    let store: QueryStore
    let find = NativeFindModel()
    var chrome = NativeChrome() {
        didSet { if chrome != oldValue { onChromeChange?(chrome) } }
    }

    /// The screen's handler for its toolbar, title-menu and inspector commands.
    @ObservationIgnored var onCommand: ((NativeCommand) -> Void)?
    @ObservationIgnored var onChromeChange: ((NativeChrome) -> Void)?
    @ObservationIgnored var onSidebarViewChange: ((AnyView?) -> Void)?
    @ObservationIgnored var sidebarView: AnyView? {
        didSet { onSidebarViewChange?(sidebarView) }
    }
    @ObservationIgnored var onInspectorViewChange: ((((String) -> AnyView?)?) -> Void)?
    /// Optional custom SwiftUI body per `.native` inspector tab id; returning nil falls back to declarative sections.
    @ObservationIgnored var inspectorView: ((String) -> AnyView?)? {
        didSet { onInspectorViewChange?(inspectorView) }
    }
    /// The window around the tab, for toasts, shortcuts, Quick Look and its undo manager.
    @ObservationIgnored var window: () -> MainWindowController? = { nil }
    /// The server root this screen connects to (local stack or a remote Tailscale host).
    @ObservationIgnored var baseURL: () -> URL? = { nil }
    /// Opens or focuses a Custom App in its dedicated standalone window.
    @ObservationIgnored var openCustomAppWindow: ((String) -> Void)?
    /// Closes a standalone Custom App window if open (e.g. after deleting the app).
    @ObservationIgnored var closeCustomAppWindow: ((String) -> Void)?
    @ObservationIgnored private let open: (String, Bool) -> Void

    init(match: NativeRouteMatch, store: QueryStore, open: @escaping (_ path: String, _ newTab: Bool) -> Void) {
        self.match = match
        self.store = store
        self.open = open
    }

    /// Opens an in-app path in this tab: a native screen when one is registered, the web view otherwise.
    func navigate(_ path: String) { open(path, false) }

    func openInNewTab(_ path: String) { open(path, true) }

    func openStandaloneCustomApp(slug: String) { openCustomAppWindow?(slug) }

    func closeStandaloneCustomApp(slug: String) { closeCustomAppWindow?(slug) }

    /// Shows a toast in the window; `onEvent` hears its action button, dismissal or timeout.
    func showToast(_ toast: ToastItemModel, onEvent: @escaping @MainActor (ToastEventKind) -> Void = { _ in }) {
        window()?.showNativeToast(toast, onEvent: onEvent)
    }

    func showShortcuts() { window()?.showShortcuts() }

    func showQuickLook(_ items: [QuickLookItem], index: Int? = nil) { window()?.showQuickLook(items: items, index: index) }

    /// The window's undo manager, so ⌘Z (Edit ▸ Undo) undoes a screen's action.
    var undoManager: UndoManager? { window()?.window?.undoManager }

    /// Opens an http(s) link in the default browser (pull requests, results on GitHub).
    func openExternal(_ href: String) {
        if let url = URL(string: href), url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
    }

    /// Resolves an API or media path relative to the active server `baseURL`, or returns an http(s) URL as-is.
    func resolvedURL(_ path: String) -> URL? {
        if let url = URL(string: path), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        guard let base = baseURL() else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    /// Copies plain text to the system pasteboard without coupling SwiftUI views to AppKit.
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Active keyboard modifiers (Command, Shift, Option) without coupling SwiftUI views to AppKit.
    var currentEventModifiers: EventModifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    /// The same screen with new parameters (e.g. another ticket): the screen keeps its state.
    func update(match: NativeRouteMatch) {
        if match != self.match { self.match = match }
    }
}

/// Hosts a tab's native screen over its web view.
@MainActor
final class NativeScreenHostController: NSViewController {
    let context: NativeScreenContext
    private let state: ShellState

    init(context: NativeScreenContext, state: ShellState) {
        self.context = context
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let hosting = NSHostingView(rootView: NativeScreenRoot(context: context, state: state))
        hosting.sizingOptions = []
        view = hosting
    }
}

/// Picks the screen for the route and gives it the page's theme: palette, text size, accent and the
/// page's own light/dark mode (which can differ from macOS's).
struct NativeScreenRoot: View {
    let context: NativeScreenContext
    let state: ShellState

    var body: some View {
        let theme = state.theme ?? ThemeTokens(mode: state.pageMode ?? .light)
        screen
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.palette.background)
            .foregroundStyle(theme.palette.text)
            .tint(theme.palette.accent)
            .environment(\.vesperTheme, theme)
            .environment(\.colorScheme, (state.pageMode ?? theme.mode) == .dark ? .dark : .light)
            .environment(context)
            .vesperTrackHostVisibility()
    }

    @ViewBuilder private var screen: some View {
        switch context.match.screen {
        case .debugPlaceholder: DebugPlaceholderScreen()
        case .inbox: InboxScreen()
        case .library: LibraryScreen()
        case .pdf: PDFScreen()
        case .markdownDebug: MarkdownDebugScreen()
        case .scenesDebug: ScenesDebugScreen()
        case .embedsDebug: ChatEmbedsDebugScreen()
        case .dev: DevScreen()
        case .http: HttpScreen()
        case .learn: LearnScreen()
        case .learnCourse: CourseScreen()
        case .scheduled: ScheduledScreen()
        case .reports: ReportsScreen()
        case .knowledge, .knowledgeGraph, .knowledgePage: KnowledgeScreen()
        case .workflows: WorkflowsScreen()
        case .workflowEditor: WorkflowEditorScreen()
        case .workflowRun: WorkflowRunScreen()
        case .chat, .chatDetail: ChatScreen()
        case .rootLanding, .appsRedirect: RootLandingScreen()
        case .setup: SetupScreen()
        case .appsHome: AppsHomeScreen()
        case .spacesHome: SpacesHomeScreen()
        case .spaceNew: NewSpaceScreen()
        case .spaceDetail: SpaceScreen()
        case .artifactDetail: ArtifactDetailScreen()
        case .artifactReview: ArtifactReviewScreen()
        case .agentDetail: AgentDetailScreen()
        case .docEditor: DocEditorScreen()
        case .slidesEditor: SlidesEditorScreen()
        case .slidesPresent: SlidesPresentScreen()
        case .designEditor: DesignEditorScreen()
        case .designPresent: DesignPresentScreen()
        case .customApp: CustomAppScreen()
        }
    }
}

/// `VESPER_NATIVE_DEBUG=1` (or `defaults write <bundle id> VesperNativeDebugScreens -bool YES`)
/// enables debug-only native screens such as /native-debug.
enum NativeDebug {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VESPER_NATIVE_DEBUG"] == "1"
            || UserDefaults.standard.bool(forKey: "VesperNativeDebugScreens")
    }
}
