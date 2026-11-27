import AppKit
import SwiftUI
import VesperCore
import WebKit

enum WindowKind { case vesper, playground }

/// The content area of one window/tab: either a native SwiftUI screen (`.vesper`) or a sandboxed
/// playground `WKWebView` (`.playground`), plus the offline/error overlay.
@MainActor
final class WebContentController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    let app: AppModel
    let kind: WindowKind
    let state: ShellState
    /// Non-nil only for `.playground` tabs; `.vesper` tabs render exclusively via native screens.
    let webView: WKWebView?
    weak var host: MainWindowController?

    /// Path (vesper) or full URL (playground) to load first.
    private(set) var pendingPath: String
    /// Per-tab navigation history for native `.vesper` tabs.
    private var history: NavigationHistory
    private var base: URL?
    private var playgroundURL: URL?
    private var observations: [NSKeyValueObservation] = []
    private var overlay: NSHostingView<OfflineView>?
    /// The native screen shown for `.vesper` tabs.
    private var nativeHost: NativeScreenHostController?

    init(app: AppModel, kind: WindowKind, state: ShellState, path: String) {
        self.app = app
        self.kind = kind
        self.state = state
        let initialHistory = NavigationHistory(initial: path)
        self.history = initialHistory
        self.pendingPath = kind == .vesper ? initialHistory.current : path
        if kind == .playground {
            self.webView = WebViewFactory.makePlaygroundWebView()
            self.playgroundURL = URL(string: path)
        } else {
            self.webView = nil
        }
        super.init(nibName: nil, bundle: nil)
        if let webView {
            webView.navigationDelegate = self
            webView.uiDelegate = self
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.canGoBack = wv.canGoBack } },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.canGoForward = wv.canGoForward } },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.isLoading = wv.isLoading } },
                webView.observe(\.title, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.documentTitleChanged() } },
                webView.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlChanged() } },
            ]
            webView.load(URLRequest(url: playgroundURL ?? URL(string: "about:blank")!))
        }
        syncHistoryState()
        syncNativeScreen(path: pendingPath)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window this tab is in (a background tab's view is detached, so ask the host).
    var ownerWindow: NSWindow? { host?.window ?? (isViewLoaded ? view.window : nil) }

    /// What the tab strip and the window title show: the screen's title, else the document's.
    var displayTitle: String {
        if let title = state.title { return cleanTabTitle(title) }
        if let doc = state.documentTitle, !doc.isEmpty { return cleanTabTitle(doc) }
        return kind == .playground ? "Playground" : "Vesper"
    }

    private func documentTitleChanged() {
        state.documentTitle = webView?.title
        host?.tabTitleChanged(self)
    }

    override func loadView() {
        let container = NSView()
        if let webView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            // Content starts below the unified toolbar (the window extends under it).
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        let overlay = NSHostingView(rootView: OfflineView(
            app: app, state: state, kind: kind,
            retry: { [weak self] in self?.retry() },
            restartStack: { [weak self] in self?.app.actions.restartStack() },
            showLogs: { [weak self] in self?.app.actions.showLogs() }))
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.overlay = overlay
        view = container
        attachNativeHostView()
        track({ [weak self] in
            guard let self else { return false }
            return self.overlayVisible
        }, apply: { [weak overlay] visible in overlay?.isHidden = !visible })
    }

    private var overlayVisible: Bool {
        if state.loadError != nil { return true }
        return kind == .vesper && app.connection == nil
    }

    // MARK: Loading

    /// Called once the server is reachable and signed in (and again after a stack restart).
    func connect(_ conn: Connection) {
        guard kind == .vesper else { return }
        base = conn.baseURL
        state.loadError = nil
    }

    var canGoBack: Bool {
        kind == .playground ? (webView?.canGoBack ?? false) : history.canGoBack
    }

    var canGoForward: Bool {
        kind == .playground ? (webView?.canGoForward ?? false) : history.canGoForward
    }

    func navigate(path: String, replace: Bool = false) {
        guard kind == .vesper else { return }
        if app.handleSettingsPath(path, from: ownerWindow) { return }
        history.navigate(to: path, replace: replace)
        applyNativeNavigation(path: history.current)
    }

    func goBack() {
        if kind == .playground {
            webView?.goBack()
            return
        }
        guard let path = history.goBack() else { return }
        applyNativeNavigation(path: path)
    }

    func goForward() {
        if kind == .playground {
            webView?.goForward()
            return
        }
        guard let path = history.goForward() else { return }
        applyNativeNavigation(path: path)
    }

    private func applyNativeNavigation(path: String) {
        pendingPath = path
        syncHistoryState()
        syncNativeScreen(path: path)
        app.scheduleSessionSave()
    }

    private func syncHistoryState() {
        guard kind == .vesper else { return }
        state.canGoBack = history.canGoBack
        state.canGoForward = history.canGoForward
    }

    func retry() {
        state.loadError = nil
        if let webView, webView.url != nil {
            webView.reload()
        } else if let conn = app.connection {
            connect(conn)
        }
    }

    /// The URL this tab would restore to.
    var currentURLString: String? {
        if let url = webView?.url, url.scheme == "http" || url.scheme == "https" { return url.absoluteString }
        if kind == .vesper, let base, let url = URL(string: pendingPath, relativeTo: base) { return url.absoluteURL.absoluteString }
        return nil
    }

    private func urlChanged() {
        app.scheduleSessionSave()
    }

    // MARK: Native screens

    /// The native screen or the playground web view, whichever shows: the find bar searches it.
    var findTarget: (any FindTarget)? { nativeHost?.context.find ?? webView }

    /// What takes keyboard focus when the tab's content should have it.
    var focusView: NSView { nativeHost?.view ?? webView ?? view }

    /// Sends a shell command to the active native screen.
    func dispatch(_ command: NativeCommand) {
        if case .navigate(let path) = command {
            navigate(path: path)
            return
        }
        guard let nativeHost else { return }
        if state.usesDefaultCompanion {
            switch command {
            case .inspectorVisibility(let open):
                state.setDefaultCompanionOpen(open)
                return
            case .inspectorSelectTab(let tabId):
                if tabId == InspectorLogic.defaultCompanionTabId {
                    state.setDefaultCompanionOpen(true)
                }
                return
            default:
                break
            }
        }
        if NativeCommandRouting.isScreenCommand(command, navigatorId: nativeHost.context.chrome.navigator?.id) {
            nativeHost.context.onCommand?(command)
        }
    }

    /// Shows the native screen registered for `path` (falling back to `/` if an unknown path arrives).
    private func syncNativeScreen(path: String) {
        guard kind == .vesper else { return }
        let match = app.nativeRoutes.resolve(path) ?? app.nativeRoutes.resolve("/")
        if let match {
            state.route = match.path
        }
        state.nativeArea = match?.screen.area
        if let match, let nativeHost, nativeHost.context.match.screen.hostGroup == match.screen.hostGroup {
            nativeHost.context.update(match: match)
            return
        }
        guard match != nil || nativeHost != nil else { return }
        removeNativeHost()
        if let match {
            let context = NativeScreenContext(match: match, store: app.system.store) { [weak self] path, newTab in
                guard let self else { return }
                if newTab { self.app.openVesperTab(path: path, nextTo: self.ownerWindow) } else { self.navigate(path: path) }
            }
            context.replaceRoute = { [weak self] path in self?.navigate(path: path, replace: true) }
            context.onChromeChange = { [weak self] chrome in self?.state.native = chrome }
            context.onSidebarViewChange = { [weak self] view in self?.state.nativeSidebar = view }
            context.onInspectorViewChange = { [weak self] builder in self?.state.nativeInspectorView = builder }
            context.window = { [weak self] in self?.host }
            context.isActiveTabCheck = { [weak self] in
                guard let self else { return false }
                guard let host = self.host else { return true }
                return host.content === self
            }
            context.baseURL = { [weak self] in self?.app.connection?.baseURL }
            context.openCustomAppWindow = { [weak self] slug in self?.app.aux.openCustomAppWindow(slug: slug) }
            context.closeCustomAppWindow = { [weak self] slug in self?.app.aux.closeCustomAppWindow(slug: slug) }
            state.native = context.chrome
            state.nativeSidebar = context.hostedSidebarView
            state.nativeInspectorView = context.hostedInspectorView
            let host = NativeScreenHostController(context: context, state: state)
            nativeHost = host
            addChild(host)
            attachNativeHostView()
            vlog("native screen \(match.screen.rawValue) for \(match.path)")
        }
        host?.findTargetChanged(self)
    }

    private func attachNativeHostView() {
        guard isViewLoaded, let nativeHost, nativeHost.view.superview == nil else { return }
        let hosted = nativeHost.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        if let overlay { view.addSubview(hosted, positioned: .below, relativeTo: overlay) } else { view.addSubview(hosted) }
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func removeNativeHost() {
        guard let host = nativeHost else { return }
        nativeHost = nil
        host.context.detach()
        host.view.removeFromSuperview()
        host.removeFromParent()
        state.native = nil
        state.nativeSidebar = nil
        state.nativeInspectorView = nil
        // This often runs inside the old screen's own SwiftUI update (a redirect from `onAppear` or
        // `onChange`) or mid-event; freeing its NSHostingView there is a use-after-free. Let it go
        // on the next main-queue turn instead.
        DispatchQueue.main.async { withExtendedLifetime(host) {} }
    }

    func teardown() {
        removeNativeHost()
        if let webView {
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.stopLoading()
        }
        observations.removeAll()
    }

    // MARK: Playground link policy

    /// What to do with a link from a playground view. Returns true when it should load here.
    private func route(_ url: URL, openingTab: Bool) -> Bool {
        guard let base = app.connection?.baseURL ?? base else { return false }
        let target = url.absoluteString
        if kind == .playground, let own = playgroundURL, classifyNavigation(target, serverURL: own.absoluteString, playgroundPorts: []) == .vesper {
            if openingTab { app.openPlayground(url: url, nextTo: ownerWindow) }
            return !openingTab
        }
        switch classifyNavigation(target, serverURL: base.absoluteString, playgroundPorts: app.playgroundPorts) {
        case .vesper:
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?" + q }
            if let f = url.fragment { path += "#" + f }
            if app.handleSettingsPath(path, from: ownerWindow) { return false }
            app.openVesperTab(path: path, nextTo: ownerWindow)
        case .playground:
            app.openPlayground(url: url, nextTo: ownerWindow)
        case .external:
            NSWorkspace.shared.open(url)
        case .ignore:
            break
        }
        return false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .cancel }
        if url.isFileURL {
            if navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.sourceFrame.isMainFrame {
                app.aux.openFiles([url])
            }
            return .cancel
        }
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return .allow }
        if navigationAction.targetFrame == nil {
            _ = route(url, openingTab: true)
            return .cancel
        }
        return route(url, openingTab: false) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        WebNavigationPolicy.shouldDownload(navigationResponse) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        WebDownloads.shared.adopt(download, in: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        WebDownloads.shared.adopt(download, in: webView)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        vlog("createWebView url=\(url?.absoluteString ?? "nil")")
        if let url { _ = route(url, openingTab: true) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let host { host.closeTab(self) } else { ownerWindow?.performClose(nil) }
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        vlog("media capture denied for \(origin.protocol)://\(origin.host)")
        return .deny
    }

    // MARK: Navigation results

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.loadError = nil
        vlog("didFinish \(webView.url?.path ?? "?")")
        app.scheduleSessionSave()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        let ns = error as NSError
        // Cancelled loads and policy-cancelled navigations ("Frame load interrupted") are not failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        vlog("navigation failed: \(ns.domain) \(ns.code)")
        state.loadError = ns.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        vlog("web content process terminated")
        webView.reload()
    }

    // MARK: JavaScript dialogs and file pickers (playground pages)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        _ = await presentDialog(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await presentDialog(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await presentDialog(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// A playground's dialog as a sheet on its own window, so it blocks that tab rather than the
    /// whole app; app-modal only when the tab has no window or one already shows a sheet.
    private func presentDialog(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = ownerWindow, window.attachedSheet == nil else { return alert.runModal() }
        window.makeKeyAndOrderFront(nil)
        return await alert.beginSheetModal(for: window)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
