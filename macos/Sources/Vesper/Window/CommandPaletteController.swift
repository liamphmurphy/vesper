import AppKit
import VesperCore
import WebKit

@MainActor
private final class CommandPalettePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
private final class CommandPaletteGlassView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }
}

/// Hosts the app's persistent floating Liquid Glass Command Palette (`⌘K`) in a borderless
/// Spotlight-style `NSPanel` backed by `/command-palette`.
@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private weak var aux: AuxWindows?
    private weak var targetController: MainWindowController?

    let webView: WKWebView
    let services = WebPageServices()

    private var panel: CommandPalettePanel?
    private var glassView: CommandPaletteGlassView?
    private var baseURL: URL?
    private var loaded = false
    private var ready = false
    private var pendingRequest: CommandPaletteRequest?
    private var lastScope: CommandPaletteScope?
    private var appearanceMonitor: AppearanceMonitor?

    var isVisible: Bool { panel?.isVisible == true }

    init(aux: AuxWindows) {
        self.aux = aux
        self.webView = WebViewFactory.makeWebView(kind: .commandPalette, bridge: nil, services: services)
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
            loadPalette(from: conn.baseURL)
        } else if loaded && webView.url == nil {
            loadPalette(from: conn.baseURL)
        }
    }

    func open(request: CommandPaletteRequest?, from source: MainWindowController?) {
        if baseURL == nil, let conn = aux?.app?.connection {
            connect(conn)
        }
        guard let baseURL else { return }

        let target = source ?? aux?.app?.keyController
        let resolved = enrich(request ?? CommandPaletteRequest(), from: target, baseURL: baseURL)

        if isVisible && panel?.isKeyWindow == true && resolved.query == nil && resolved.scope == lastScope {
            close(restoreFocus: true)
            return
        }

        targetController = target
        lastScope = resolved.scope
        ensureLoaded()

        let panel = ensurePanel()
        position(panel, relativeTo: target?.window)

        pendingRequest = resolved
        if ready {
            ShellBridge.send(.paletteOpen(request: resolved), to: webView)
        }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func close(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus, let target = targetController {
            target.window?.makeKeyAndOrderFront(nil)
            target.window?.makeFirstResponder(target.content.webView)
        }
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

    // MARK: Private layout & loading

    private func ensureLoaded() {
        guard !loaded, let baseURL else { return }
        loaded = true
        loadPalette(from: baseURL)
    }

    private func loadPalette(from base: URL) {
        guard let url = URL(string: "/command-palette", relativeTo: base)?.absoluteURL else { return }
        vlog("commandPalette: loading \(url.path)")
        webView.load(URLRequest(url: url))
    }

    private func ensurePanel() -> CommandPalettePanel {
        if let panel { return panel }
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close(restoreFocus: true) }

        let glass = CommandPaletteGlassView(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        webView.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            webView.topAnchor.constraint(equalTo: glass.topAnchor),
            webView.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass
        self.glassView = glass
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, relativeTo parentWindow: NSWindow?) {
        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(880, max(540, visible.width - 48))
        let height = min(560, max(360, visible.height - 80))
        let anchor = parentWindow?.frame ?? visible
        let rawX = anchor.midX - width / 2
        let topOffset = min(anchor.height * 0.12, 110)
        let rawY = anchor.maxY - topOffset - height
        let x = min(max(rawX, visible.minX + 16), visible.maxX - width - 16)
        let y = min(max(rawY, visible.minY + 16), visible.maxY - height - 16)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func enrich(_ initial: CommandPaletteRequest, from target: MainWindowController?, baseURL: URL) -> CommandPaletteRequest {
        var req = initial
        if req.path == nil {
            if let url = target?.content.webView.url, BridgeOrigin.matches(url: url, base: baseURL) {
                req.path = url.path.isEmpty ? "/" : url.path
                if req.search == nil, let query = url.query, !query.isEmpty {
                    req.search = "?\(query)"
                }
            } else {
                req.path = target?.state.route ?? "/"
            }
        }
        return req
    }

    func sendAppearance(_ command: NativeCommand? = nil) {
        guard ready else { return }
        if let command {
            ShellBridge.send(command, to: webView)
            return
        }
        if let custom = aux?.app?.currentAppearanceCommand() {
            ShellBridge.send(custom, to: webView)
            return
        }
        let (accent, mode) = AppearanceMonitor.current()
        ShellBridge.send(.appearance(accent: accent, mode: mode), to: webView)
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if panel?.attachedSheet == nil {
            close(restoreFocus: false)
        }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, let baseURL,
              BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: baseURL) else {
            vlog("commandPalette bridge: dropped message from \(origin.protocol)://\(origin.host):\(origin.port)")
            return
        }
        let decoded: PageMessage
        do {
            decoded = try PageMessage.decode(fromJSONObject: message.body)
        } catch {
            vlog("commandPalette bridge: undecodable message: \(error)")
            return
        }
        vlog("commandPalette bridge: \(ShellBridge.describe(decoded))")
        handle(decoded)
    }

    private func handle(_ message: PageMessage) {
        switch message {
        case .ready:
            ready = true
            sendAppearance()
            if let pendingRequest {
                ShellBridge.send(.paletteOpen(request: pendingRequest), to: webView)
            }
        case .openInMain(let path, let newTab):
            close(restoreFocus: true)
            if newTab {
                aux?.app?.openVesperTab(path: path, nextTo: targetController?.window)
            } else if let target = targetController {
                target.content.navigate(path: path)
                target.window?.makeKeyAndOrderFront(nil)
            } else {
                aux?.app?.openVesperTab(path: path, nextTo: nil)
            }
        case .commandPaletteClose:
            close(restoreFocus: true)
        case .commandPaletteOpen(let request):
            open(request: request, from: targetController)
        case .showShortcuts:
            close(restoreFocus: false)
            aux?.showShortcuts()
        case .toastShow(let id, let title, let description, let tone, let actionLabel, let durationMs):
            let toast = ToastItemModel(id: id, title: title, description: description, tone: tone, actionLabel: actionLabel, durationMs: durationMs)
            targetController?.showToast(toast, from: webView)
        case .toastDismiss(let id):
            targetController?.dismissToast(id: id)
        case .quickLook(let items, let index):
            close(restoreFocus: false)
            targetController?.showQuickLook(items: items, index: index)
        case .confirmApproval(let requestId, let scope):
            Task { [weak self] in
                let ok = await ShellBridge.services?.confirmApproval(scope: scope) ?? false
                ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self?.webView)
            }
        case .contextMenu(let requestId, let items, let x, let y):
            let selected = ShellBridge.showContextMenu(items: items, x: x, y: y, in: webView)
            ShellBridge.send(.reply(requestId: requestId, ok: true, selectedId: .some(selected)), to: webView)
        case .confirm(let requestId, let title, let body, let confirmLabel, let cancelLabel, let destructive):
            Task { [weak self] in
                guard let self else { return }
                let ok = await ShellBridge.confirmSheet(
                    title: title, body: body, confirmLabel: confirmLabel,
                    cancelLabel: cancelLabel, destructive: destructive, window: self.panel
                )
                ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self.webView)
            }
        case .prompt(let requestId, let title, let body, let label, let value, let placeholder, let confirmLabel, let cancelLabel, let maxLength):
            Task { [weak self] in
                guard let self else { return }
                let entered = await ShellBridge.promptSheet(
                    title: title, body: body, label: label, value: value, placeholder: placeholder,
                    confirmLabel: confirmLabel, cancelLabel: cancelLabel, maxLength: maxLength, window: self.panel
                )
                ShellBridge.send(.reply(requestId: requestId, ok: entered != nil, value: .some(entered)), to: self.webView)
            }
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
        switch classifyNavigation(url.absoluteString, serverURL: baseURL.absoluteString, playgroundPorts: aux?.app?.playgroundPorts ?? defaultPlaygroundPorts) {
        case .vesper:
            if !openingTab && url.path == "/command-palette" { return .allow }
            let rawPath = url.path.isEmpty ? "/" : url.path
            let query = url.query.map { "?\($0)" } ?? ""
            let fragment = url.fragment.map { "#\($0)" } ?? ""
            let path = "\(rawPath)\(query)\(fragment)"
            close(restoreFocus: true)
            if openingTab {
                aux?.app?.openVesperTab(path: path, nextTo: targetController?.window)
            } else if let target = targetController {
                target.content.navigate(path: path)
            } else {
                aux?.app?.openVesperTab(path: path, nextTo: nil)
            }
            return .cancel
        case .playground:
            close(restoreFocus: false)
            aux?.app?.openPlayground(url: url, nextTo: targetController?.window)
            return .cancel
        case .external:
            NSWorkspace.shared.open(url)
            return .cancel
        case .ignore:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, let baseURL else { return nil }
        switch classifyNavigation(url.absoluteString, serverURL: baseURL.absoluteString, playgroundPorts: aux?.app?.playgroundPorts ?? defaultPlaygroundPorts) {
        case .vesper:
            let rawPath = url.path.isEmpty ? "/" : url.path
            let query = url.query.map { "?\($0)" } ?? ""
            let fragment = url.fragment.map { "#\($0)" } ?? ""
            let path = "\(rawPath)\(query)\(fragment)"
            close(restoreFocus: true)
            aux?.app?.openVesperTab(path: path, nextTo: targetController?.window)
        case .playground:
            close(restoreFocus: false)
            aux?.app?.openPlayground(url: url, nextTo: targetController?.window)
        case .external:
            NSWorkspace.shared.open(url)
        case .ignore:
            break
        }
        return nil
    }
}
