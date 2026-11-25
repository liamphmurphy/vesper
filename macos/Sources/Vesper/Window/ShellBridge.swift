import AppKit
import VesperCore
import WebKit

/// One window's side of the page bridge (docs/dev/native-mac-app.md, "Page ↔ shell bridge").
/// Receives page messages (origin-checked, decoded, folded into `ShellState`) and sends commands.
@MainActor
final class ShellBridge: NSObject, WKScriptMessageHandler {
    let state: ShellState
    /// The Vesper server origin; messages from anywhere else are dropped. Set on connect.
    var baseURL: URL?
    weak var webView: WKWebView?
    /// The app's system services, for requests that need them (Touch ID, the workspace menu).
    static weak var services: SystemServices?
    /// Called when the route changes (session saving).
    var onRouteChange: (() -> Void)?
    /// Called when the page (or companion) asks to open an in-app path in the main pane.
    var onOpenInMain: ((String, Bool) -> Void)?
    /// Called when an embedded panel asks to forward an event back to the main page.
    var onPanelEvent: ((String, String, String?) -> Void)?
    /// Window host for overlays shared across tabs (toast HUD, shortcuts, command palette, Quick Look).
    weak var shellHost: (any ShellHostActions)?

    private var appearanceMonitor: AppearanceMonitor?
    var appearanceCommand: (() -> NativeCommand)?
    var ownsAppearance: () -> Bool = { false }

    init(state: ShellState, appearanceCommand: (() -> NativeCommand)? = nil, ownsAppearance: @escaping () -> Bool = { false }) {
        self.state = state
        self.appearanceCommand = appearanceCommand
        self.ownsAppearance = ownsAppearance
        super.init()
        appearanceMonitor = AppearanceMonitor { [weak self] in self?.sendAppearance() }
    }

    /// macOS's accent colour, effective appearance, and native Appearance settings; sent once ready.
    func sendAppearance(_ command: NativeCommand? = nil) {
        guard state.ready else { return }
        if let command {
            send(command)
            return
        }
        if let custom = appearanceCommand?() {
            send(custom)
            return
        }
        let (accent, mode) = AppearanceMonitor.current()
        send(.appearance(accent: accent, mode: mode))
    }

    // MARK: Page -> shell

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, let baseURL,
              BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: baseURL) else {
            vlog("bridge: dropped message from \(origin.protocol)://\(origin.host):\(origin.port) mainFrame=\(frame.isMainFrame)")
            return
        }
        let decoded: PageMessage
        do {
            decoded = try PageMessage.decode(fromJSONObject: message.body)
        } catch {
            vlog("bridge: undecodable message: \(error)")
            return
        }
        vlog("bridge: \(Self.describe(decoded))")
        handle(decoded)
    }

    private func handle(_ message: PageMessage) {
        switch message {
        case .ready(let path):
            state.ready = true
            state.route = path
            sendAppearance()
        case .route(let path, let area):
            state.route = path
            state.area = area
            onRouteChange?()
        case .title(let title, let subtitle, let menu):
            state.pageTitle = title
            state.pageSubtitle = subtitle
            state.pageTitleMenu = menu
        case .rail(let model): state.rail = model
        case .inspector(let model): state.pageInspector = model
        case .panelEvent(let tabId, let event, let payloadJson): onPanelEvent?(tabId, event, payloadJson)
        case .openInMain(let path, let newTab): onOpenInMain?(path, newTab)
        case .shell(let model): state.shell = model
        case .navigator(let model): state.pageNavigator = model
        case .navigatorFallback(let active): state.navigatorFallback = active
        case .sidebarHidden(let hidden): state.sidebarHidden = hidden
        case .toolbar(let items): state.pageToolbarItems = items
        case .appearance(let mode, let background, let theme):
            if !ownsAppearance() {
                state.pageMode = mode
                if let theme { state.theme = theme }
            }
            if let color = NSColor.fromCSS(background) {
                webView?.underPageBackgroundColor = color
                WebViewFactory.lastPageBackground = color
            }
        case .confirmApproval(let requestId, let scope):
            Task { [weak self] in
                let ok = await Self.services?.confirmApproval(scope: scope) ?? false
                self?.send(.reply(requestId: requestId, ok: ok))
            }
        case .openWorkspaceMenu(let requestId, let folder):
            Task { [weak self] in
                guard let view = self?.webView else { return }
                let ok = await Self.services?.showWorkspaceMenu(folder: folder, in: view) ?? false
                self?.send(.reply(requestId: requestId, ok: ok))
            }
        case .contextMenu(let requestId, let items, let x, let y):
            showContextMenu(requestId: requestId, items: items, x: x, y: y)
        case .confirm(let requestId, let title, let body, let confirmLabel, let cancelLabel, let destructive):
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.confirmSheet(title: title, body: body, confirmLabel: confirmLabel, cancelLabel: cancelLabel, destructive: destructive)
                self.send(.reply(requestId: requestId, ok: ok))
            }
        case .prompt(let requestId, let title, let body, let label, let value, let placeholder, let confirmLabel, let cancelLabel, let maxLength):
            Task { [weak self] in
                guard let self else { return }
                let entered = await NativeDialogs.promptSheet(
                    title: title, body: body, label: label, value: value, placeholder: placeholder,
                    confirmLabel: confirmLabel, cancelLabel: cancelLabel, maxLength: maxLength, window: self.webView?.window
                )
                self.send(.reply(requestId: requestId, ok: entered != nil, value: .some(entered)))
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
        case .openCustomAppWindow(let slug):
            guard AppsHomeLogic.validateSlug(slug) == nil else { return }
            shellHost?.openCustomAppWindow(slug: slug)
        }
    }

    /// The page's confirmAction as a sheet on its window: Return confirms, Esc cancels.
    private func confirmSheet(title: String, body: String?, confirmLabel: String, cancelLabel: String?, destructive: Bool) async -> Bool {
        await NativeDialogs.confirmSheet(title: title, body: body, confirmLabel: confirmLabel, cancelLabel: cancelLabel, destructive: destructive, window: webView?.window)
    }

    private func showContextMenu(requestId: String, items: [MenuItem], x: Double, y: Double) {
        guard let webView else {
            send(.reply(requestId: requestId, ok: false, error: "no web view"))
            return
        }
        let selected = Self.showContextMenu(items: items, x: x, y: y, in: webView)
        send(.reply(requestId: requestId, ok: true, selectedId: .some(selected)))
    }

    static func showContextMenu(items: [MenuItem], x: Double, y: Double, in webView: WKWebView) -> String? {
        var selected: String?
        let menu = MenuBuilder.menu(from: items) { selected = $0 }
        // The page sends CSS pixels, which View › Zoom scales into view points. Its y grows
        // downward; AppKit's y grows upward unless the view is flipped.
        let px = x * webView.pageZoom, py = y * webView.pageZoom
        let point = NSPoint(x: px, y: webView.isFlipped ? py : webView.bounds.height - py)
        menu.popUp(positioning: nil, at: point, in: webView)
        return selected
    }

    // MARK: Shell -> page

    func send(_ command: NativeCommand) {
        Self.send(command, to: webView)
    }

    static func send(_ command: NativeCommand, to webView: WKWebView?) {
        guard let webView else { return }
        do {
            let data = try JSONEncoder().encode(command)
            let object = try JSONSerialization.jsonObject(with: data)
            vlog("send: \(String(decoding: data, as: UTF8.self))")
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(
                        #"window.dispatchEvent(new CustomEvent("vesper-native", { detail: cmd }))"#,
                        arguments: ["cmd": object], in: nil, contentWorld: .page)
                } catch {
                    vlog("send failed: \(error)")
                }
            }
        } catch {
            vlog("encode failed: \(error)")
        }
    }

    func teardown(from controller: WKUserContentController) {
        appearanceMonitor?.stop()
        appearanceMonitor = nil
        controller.removeScriptMessageHandler(forName: WebViewFactory.handlerName)
    }

    static func describe(_ m: PageMessage) -> String {
        switch m {
        case .ready(let p): "ready \(p)"
        case .route(let p, let a): "route \(p) area=\(a?.rawValue ?? "nil")"
        case .title(let t, _, _): "title \(t)"
        case .rail(let m): "rail \(m == nil ? "none" : "items")"
        case .inspector(let m): "inspector \(m == nil ? "none" : "\(m!.id) open=\(m!.open) tab=\(m!.activeTabId)")"
        case .panelEvent(let tabId, let event, _): "panelEvent \(tabId).\(event)"
        case .openInMain(let p, let newTab): "openInMain \(p) newTab=\(newTab)"
        case .shell(let s): "shell areas=\(s.areas.count) apps=\(s.apps.count)"
        case .navigator(let n): "navigator \(n?.id ?? "nil") selected=\(n?.selectedId ?? "nil") rows=\(n?.sections.flatMap { $0.items.map(\.id) }.prefix(12).joined(separator: ",") ?? "")"
        case .navigatorFallback(let a): "navigatorFallback \(a)"
        case .sidebarHidden(let h): "sidebarHidden \(h)"
        case .toolbar(let i): "toolbar \(i.count) items"
        case .appearance(let m, _, _): "appearance \(m.rawValue)"
        case .confirmApproval(let r, let s): "confirmApproval \(r) \(s.rawValue)"
        case .openWorkspaceMenu(let r, _): "openWorkspaceMenu \(r)"
        case .contextMenu(let r, let i, _, _): "contextMenu \(r) \(i.count) items"
        case .confirm(let r, _, _, _, _, _): "confirm \(r)"
        case .prompt(let r, _, _, _, _, _, _, _, _): "prompt \(r)"
        case .toastShow(let id, _, _, let tone, _, _): "toastShow \(id) \(tone.rawValue)"
        case .toastDismiss(let id): "toastDismiss \(id)"
        case .showShortcuts: "showShortcuts"
        case .commandPaletteOpen(let req): "commandPaletteOpen \(req?.scope?.rawValue ?? "all")"
        case .commandPaletteClose: "commandPaletteClose"
        case .quickLook(let items, let idx): "quickLook \(items.count) items index=\(idx.map(String.init) ?? "nil")"
        case .openCustomAppWindow(let slug): "openCustomAppWindow \(slug)"
        }
    }
}
