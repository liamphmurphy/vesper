import AppKit
import VesperCore
import WebKit

/// Owns a window's persistent `/companion` WKWebView so `<WorkChat />` stays mounted across
/// navigation and tab switches, updating its subject via `companion.context`.
@MainActor
final class CompanionWebController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let services = WebPageServices()

    var onOpenInMain: ((String, Bool) -> Void)?
    var onOpenPlayground: ((URL) -> Void)?
    var ownerWindow: (() -> NSWindow?)?
    var playgroundPorts: () -> [Int] = { defaultPlaygroundPorts }
    var appearanceCommand: (() -> NativeCommand)?
    weak var shellHost: (any ShellHostActions)?

    private var baseURL: URL?
    private var ready = false
    private var loaded = false
    private var pendingContext: CompanionContext?
    private var appearanceMonitor: AppearanceMonitor?

    override init() {
        self.webView = WebViewFactory.makeWebView(kind: .companion, bridge: nil, services: services)
        super.init()
        services.webView = webView
        webView.configuration.userContentController.add(self, name: WebViewFactory.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        appearanceMonitor = AppearanceMonitor { [weak self] in self?.sendAppearance() }
    }

    func connect(_ conn: Connection) {
        let sameServer = baseURL == conn.baseURL
        baseURL = conn.baseURL
        services.baseURL = conn.baseURL
        if loaded && !sameServer {
            ready = false
            loadCompanion(from: conn.baseURL)
        } else if loaded && webView.url == nil {
            loadCompanion(from: conn.baseURL)
        }
    }

    /// Loads `/companion` the first time the companion tab is shown.
    func ensureLoaded() {
        guard !loaded, let baseURL else { return }
        loaded = true
        loadCompanion(from: baseURL)
    }

    func updateContext(_ context: CompanionContext?) {
        let normalized = context ?? CompanionContext()
        if normalized == pendingContext { return }
        pendingContext = normalized
        guard ready else { return }
        ShellBridge.send(.companionContext(normalized), to: webView)
    }

    func teardown() {
        appearanceMonitor?.stop()
        appearanceMonitor = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: WebViewFactory.handlerName)
        services.teardown(from: controller)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    private func loadCompanion(from base: URL) {
        guard let url = URL(string: "/companion", relativeTo: base)?.absoluteURL else { return }
        vlog("companion: loading \(url.path)")
        webView.load(URLRequest(url: url))
    }

    func sendAppearance(_ command: NativeCommand? = nil) {
        guard ready else { return }
        if let command {
            ShellBridge.send(command, to: webView)
            return
        }
        if let custom = appearanceCommand?() {
            ShellBridge.send(custom, to: webView)
            return
        }
        let (accent, mode) = AppearanceMonitor.current()
        ShellBridge.send(.appearance(accent: accent, mode: mode), to: webView)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, let baseURL,
              BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: baseURL) else {
            vlog("companion bridge: dropped message from \(origin.protocol)://\(origin.host):\(origin.port)")
            return
        }
        let decoded: PageMessage
        do {
            decoded = try PageMessage.decode(fromJSONObject: message.body)
        } catch {
            vlog("companion bridge: undecodable message: \(error)")
            return
        }
        vlog("companion bridge: \(ShellBridge.describe(decoded))")
        handle(decoded)
    }

    private func handle(_ message: PageMessage) {
        switch message {
        case .ready:
            ready = true
            sendAppearance()
            if let pendingContext {
                ShellBridge.send(.companionContext(pendingContext), to: webView)
            }
        case .openInMain(let path, let newTab):
            onOpenInMain?(path, newTab)
        case .appearance:
            break
        case .confirmApproval(let requestId, let scope):
            Task { [weak self] in
                let ok = await ShellBridge.services?.confirmApproval(scope: scope) ?? false
                ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self?.webView)
            }
        case .openWorkspaceMenu(let requestId, let folder):
            Task { [weak self] in
                guard let view = self?.webView else { return }
                let ok = await ShellBridge.services?.showWorkspaceMenu(folder: folder, in: view) ?? false
                ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self?.webView)
            }
        case .contextMenu(let requestId, let items, let x, let y):
            let selected = ShellBridge.showContextMenu(items: items, x: x, y: y, in: webView)
            ShellBridge.send(.reply(requestId: requestId, ok: true, selectedId: .some(selected)), to: webView)
        case .confirm(let requestId, let title, let body, let confirmLabel, let cancelLabel, let destructive):
            Task { [weak self] in
                guard let self else { return }
                let win = self.webView.window ?? self.ownerWindow?()
                let ok = await ShellBridge.confirmSheet(
                    title: title, body: body, confirmLabel: confirmLabel,
                    cancelLabel: cancelLabel, destructive: destructive, window: win)
                ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self.webView)
            }
        case .prompt(let requestId, let title, let body, let label, let value, let placeholder, let confirmLabel, let cancelLabel, let maxLength):
            Task { [weak self] in
                guard let self else { return }
                let win = self.webView.window ?? self.ownerWindow?()
                let entered = await ShellBridge.promptSheet(
                    title: title, body: body, label: label, value: value, placeholder: placeholder,
                    confirmLabel: confirmLabel, cancelLabel: cancelLabel, maxLength: maxLength, window: win)
                ShellBridge.send(.reply(requestId: requestId, ok: entered != nil, value: .some(entered)), to: self.webView)
            }
        case .toastShow(let id, let title, let description, let tone, let actionLabel, let durationMs):
            let toast = ToastItemModel(id: id, title: title, description: description, tone: tone, actionLabel: actionLabel, durationMs: durationMs)
            shellHost?.showToast(toast, from: webView)
        case .toastDismiss(let id):
            shellHost?.dismissToast(id: id)
        case .showShortcuts:
            shellHost?.showShortcuts()
        case .commandPaletteOpen(let request):
            shellHost?.openCommandPalette(request)
        case .commandPaletteClose:
            shellHost?.closeCommandPalette()
        case .quickLook(let items, let index):
            shellHost?.showQuickLook(items: items, index: index)
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate & WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["blob", "data", "about"].contains(scheme) { return .allow }
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return .allow }
        guard let baseURL else { return .cancel }

        let openingTab = navigationAction.targetFrame == nil
        switch classifyNavigation(url.absoluteString, serverURL: baseURL.absoluteString, playgroundPorts: playgroundPorts()) {
        case .vesper:
            if !openingTab && url.path == "/companion" { return .allow }
            onOpenInMain?(relativePath(for: url), openingTab)
            return .cancel
        case .playground:
            onOpenPlayground?(url)
            return .cancel
        case .external:
            NSWorkspace.shared.open(url)
            return .cancel
        case .ignore:
            return .cancel
        }
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
        if url == nil || url?.absoluteString.isEmpty == true || ["about", "blob", "data"].contains(scheme) {
            return WebPopup.make(configuration: configuration, features: windowFeatures, parent: webView.window ?? ownerWindow?())
        }
        if let url, let baseURL {
            switch classifyNavigation(url.absoluteString, serverURL: baseURL.absoluteString, playgroundPorts: playgroundPorts()) {
            case .vesper: onOpenInMain?(relativePath(for: url), true)
            case .playground: onOpenPlayground?(url)
            case .external: NSWorkspace.shared.open(url)
            case .ignore: break
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                 type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        vlog("companion web process terminated")
        ready = false
        loaded = false
        ensureLoaded()
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    private func relativePath(for url: URL) -> String {
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        if let f = url.fragment { path += "#" + f }
        return path
    }
}
