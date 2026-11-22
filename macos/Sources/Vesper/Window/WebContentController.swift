import AppKit
import SwiftUI
import VesperCore
import WebKit

enum WindowKind { case vesper, playground }

/// The content area of one window/tab: one WKWebView, the offline/error overlay, and the
/// navigation policy (routing.ts: same origin stays, playground and external leave).
@MainActor
final class WebContentController: NSViewController, WKNavigationDelegate, WKUIDelegate {
    let app: AppModel
    let kind: WindowKind
    let state: ShellState
    let bridge: ShellBridge?
    let services: WebPageServices?
    let webView: WKWebView
    weak var host: MainWindowController?

    /// Path (vesper) or full URL (playground) to load first.
    private(set) var pendingPath: String
    private var base: URL?
    private var playgroundURL: URL?
    private var observations: [NSKeyValueObservation] = []
    private var overlay: NSHostingView<OfflineView>?
    /// The native screen drawn over the web view for the current path, if one is registered.
    private var nativeHost: NativeScreenHostController?

    init(app: AppModel, kind: WindowKind, state: ShellState, path: String) {
        self.app = app
        self.kind = kind
        self.state = state
        self.pendingPath = path
        if kind == .vesper {
            let bridge = ShellBridge(
                state: state,
                appearanceCommand: { [weak app] in
                    if let cmd = app?.currentAppearanceCommand() { return cmd }
                    let (accent, mode) = AppearanceMonitor.current()
                    return .appearance(accent: accent, mode: mode)
                },
                ownsAppearance: { [weak app] in app?.ownsAppearance ?? false }
            )
            self.bridge = bridge
            let services = WebPageServices()
            self.services = services
            self.webView = WebViewFactory.makeWebView(kind: .vesper, bridge: bridge, services: services)
            bridge.webView = webView
            services.webView = webView
        } else {
            self.bridge = nil
            self.services = nil
            self.webView = WebViewFactory.makeWebView(kind: .playground, bridge: nil)
            self.playgroundURL = URL(string: path)
        }
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.canGoForward = wv.canGoForward } },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in MainActor.assumeIsolated { self?.state.isLoading = wv.isLoading } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.documentTitleChanged() } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlChanged() } },
        ]
        if kind == .playground { webView.load(URLRequest(url: playgroundURL ?? URL(string: "about:blank")!)) }
        syncNativeScreen(path: path)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window this tab is in (a background tab's view is detached, so ask the host).
    var ownerWindow: NSWindow? { host?.window ?? (isViewLoaded ? view.window : nil) }

    /// What the tab strip and the window title show: the page's title, else the document's.
    var displayTitle: String {
        if let title = state.title { return cleanTabTitle(title) }
        if let doc = state.documentTitle, !doc.isEmpty { return cleanTabTitle(doc) }
        return kind == .playground ? "Playground" : "Vesper"
    }

    private func documentTitleChanged() {
        state.documentTitle = webView.title
        host?.tabTitleChanged(self)
    }

    override func loadView() {
        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        // Content starts below the unified toolbar (the window extends under it).
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
        let sameServer = base == conn.baseURL
        base = conn.baseURL
        bridge?.baseURL = conn.baseURL
        services?.baseURL = conn.baseURL
        state.loadError = nil
        if sameServer, webView.url != nil {
            webView.reload()
        } else if let url = URL(string: pendingPath, relativeTo: conn.baseURL)?.absoluteURL {
            vlog("loading \(url.path)")
            webView.load(URLRequest(url: url))
        }
    }

    func navigate(path: String) {
        guard kind == .vesper else { return }
        if app.handleSettingsPath(path, from: ownerWindow) { return }
        // Show the native screen now rather than after the page's router changes the URL.
        syncNativeScreen(path: path)
        if state.ready {
            bridge?.send(.navigate(path: path))
        } else if let base, let url = URL(string: path, relativeTo: base)?.absoluteURL {
            webView.load(URLRequest(url: url))
        }
    }

    func retry() {
        state.loadError = nil
        if webView.url != nil { webView.reload() } else if let conn = app.connection { connect(conn) }
    }

    /// The URL this tab would restore to.
    var currentURLString: String? {
        if let url = webView.url, url.scheme == "http" || url.scheme == "https" { return url.absoluteString }
        if kind == .vesper, let base, let url = URL(string: pendingPath, relativeTo: base) { return url.absoluteURL.absoluteString }
        return nil
    }

    private func urlChanged() {
        if kind == .vesper, let url = webView.url, let base, BridgeOrigin.matches(url: url, base: base) {
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?" + q }
            pendingPath = path
            syncNativeScreen(path: path)
        }
        app.scheduleSessionSave()
    }

    // MARK: Native screens

    /// The native screen or the web view, whichever shows: the find bar searches it.
    var findTarget: (any FindTarget)? { nativeHost?.context.find ?? webView }

    /// What takes keyboard focus when the tab's content should have it.
    var focusView: NSView { nativeHost?.view ?? webView }

    /// Sends a shell command to the screen it belongs to: the native screen's toolbar, title-menu,
    /// inspector and own navigator commands go to it while it shows; everything else goes to the page.
    func dispatch(_ command: NativeCommand) {
        if case .navigate(let path) = command {
            navigate(path: path)
        } else if let nativeHost, NativeCommandRouting.isScreenCommand(command, navigatorId: nativeHost.context.chrome.navigator?.id) {
            nativeHost.context.onCommand?(command)
        } else {
            bridge?.send(command)
        }
    }

    /// Shows the native screen registered for `path` over the web view, or removes it when there's
    /// none. The web view keeps running underneath, so history, the sidebar and the page's own
    /// chrome stay current for when it shows again.
    private func syncNativeScreen(path: String) {
        guard kind == .vesper else { return }
        let match = app.nativeRoutes.resolve(path)
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
            context.onChromeChange = { [weak self] chrome in self?.state.native = chrome }
            context.onSidebarViewChange = { [weak self] view in self?.state.nativeSidebar = view }
            context.window = { [weak self] in self?.host }
            context.baseURL = { [weak self] in self?.app.connection?.baseURL }
            state.native = context.chrome
            state.nativeSidebar = context.sidebarView
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
        webView.isHidden = true
        if view.window?.firstResponder === webView { view.window?.makeFirstResponder(hosted) }
    }

    private func removeNativeHost() {
        guard let host = nativeHost else { return }
        nativeHost = nil
        let hadFocus = host.isViewLoaded && (view.window?.firstResponder as? NSView)?.isDescendant(of: host.view) == true
        host.view.removeFromSuperview()
        host.removeFromParent()
        state.native = nil
        state.nativeSidebar = nil
        webView.isHidden = false
        if hadFocus { view.window?.makeFirstResponder(webView) }
    }

    func teardown() {
        removeNativeHost()
        bridge?.teardown(from: webView.configuration.userContentController)
        services?.teardown(from: webView.configuration.userContentController)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
        webView.stopLoading()
    }

    // MARK: Link policy

    /// What to do with a link from this view. Returns true when it should load here.
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
            if kind == .vesper && !openingTab { return true }
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
        // <a download>, including blob: and data: URLs, goes to ~/Downloads (before any link routing,
        // which would hand a blob: URL to the workspace).
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .cancel }
        // A file dropped on the window that the page didn't take: offer it to a chat, as the
        // Electron app did (drop.ts), instead of navigating to file://. Only a browser-initiated
        // main-frame navigation counts: a page's own link, redirect or subframe never reaches a chat.
        if url.isFileURL {
            if navigationAction.navigationType == .other,
               navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.sourceFrame.isMainFrame {
                app.aux.openFiles([url])
            }
            return .cancel
        }
        let scheme = url.scheme?.lowercased() ?? ""
        // The page's own blob:/data:/about: documents open in a popup (target=_blank) or here.
        if ["blob", "data", "about"].contains(scheme) && kind == .vesper { return .allow }
        // Subframes (e.g. embedded previews) are governed by the page's own policy.
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
        let scheme = url?.scheme?.lowercased() ?? ""
        vlog("createWebView url=\(url?.absoluteString ?? "nil")")
        // window.open("") / about:blank and blob:/data: targets need a real window the opener can
        // write to or navigate later (connector sign-in); links to pages open as tabs.
        if kind == .vesper, url == nil || url?.absoluteString.isEmpty == true || ["about", "blob", "data"].contains(scheme) {
            return WebPopup.make(configuration: configuration, features: windowFeatures, parent: ownerWindow)
        }
        if let url { _ = route(url, openingTab: true) }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let host { host.closeTab(self) } else { ownerWindow?.performClose(nil) }
    }

    // MARK: Unsaved changes

    /// Whether the page reports unsaved changes (web/lib/leave-guard.ts). WKWebView never runs
    /// beforeunload prompts, so the shell asks. A page that doesn't answer within a second counts
    /// as having none, so a hung page can always be closed.
    func hasUnsavedChanges() async -> Bool {
        let web = webView
        let check = Task { @MainActor () -> Bool in
            let result = try? await web.callAsyncJavaScript(
                "return typeof window.__vesperHasUnsavedChanges === 'function' && window.__vesperHasUnsavedChanges() === true;",
                contentWorld: .page)
            return (result as? Bool) ?? false
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(1)); check.cancel() }
        let value = await check.value
        timeout.cancel()
        return value
    }

    /// Asks "Leave without saving?" when the page has unsaved changes. true = go ahead.
    func confirmLeavingUnsavedChanges() async -> Bool {
        guard await hasUnsavedChanges() else { return true }
        let alert = NSAlert()
        alert.messageText = "Leave without saving?"
        alert.informativeText = "Changes you made on this page may not be saved."
        alert.addButton(withTitle: "Leave")
        alert.addButton(withTitle: "Stay")
        if let window = ownerWindow {
            window.makeKeyAndOrderFront(nil)
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Screen/camera/microphone capture (getDisplayMedia in the frame-capture feature): only the
    /// Vesper origin's main frame is offered the system prompt; everything else is refused.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard kind == .vesper, frame.isMainFrame, let base = app.connection?.baseURL ?? base,
              BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: base) else {
            vlog("media capture denied for \(origin.protocol)://\(origin.host)")
            return .deny
        }
        vlog("media capture prompt for type \(type.rawValue)")
        return .prompt
    }

    // MARK: Navigation results

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.loadError = nil
        vlog("didFinish \(webView.url?.path ?? "?")")
        app.scheduleSessionSave()
        if debugLoggingEnabled, ProcessInfo.processInfo.environment["VESPER_DEBUG_SELFTEST"] == "1", kind == .vesper {
            runBridgeSelfTest()
        }
        runDebugScript()
    }

    /// Debug only: VESPER_DEBUG_JS=<file> runs that file's JavaScript (as an async function body) after
    /// each load and logs the result, to exercise WebKit behaviour without the page's help.
    private func runDebugScript() {
        guard debugLoggingEnabled, kind == .vesper, let path = ProcessInfo.processInfo.environment["VESPER_DEBUG_JS"],
              let source = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        webView.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page) { result in
            MainActor.assumeIsolated { vlog("debug js: \(result)") }
        }
    }

    /// Debug only: posts messages as a page would and answers the first command, to exercise the
    /// bridge when the web side does not speak it yet.
    private func runBridgeSelfTest() {
        let js = """
        const post = (m) => window.webkit.messageHandlers.vesper.postMessage(m);
        window.addEventListener("vesper-native", (e) => post({v:1, type:"title", title:"got " + e.detail.type}));
        post({v:1, type:"ready", path:"/chat"});
        post({v:1, type:"route", path:"/chat", area:"chat"});
        post({v:1, type:"shell", model:{areas:[{id:"chat",label:"Chat",icon:"msg",href:"/chat"}], apps:[], currentArea:"chat"}});
        post({v:1, type:"bogus"});
        """
        webView.evaluateJavaScript(js) { [weak self] _, error in
            MainActor.assumeIsolated {
                vlog("selftest injected error=\(String(describing: error))")
                self?.bridge?.send(.command(.find))
            }
        }
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

    // MARK: JavaScript dialogs and file pickers

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

    /// A page's dialog as a sheet on its own window, so it blocks that tab rather than the whole
    /// app; app-modal only when the tab has no window or one already shows a sheet.
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
