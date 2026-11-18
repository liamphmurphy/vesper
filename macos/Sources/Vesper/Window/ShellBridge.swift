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

    private var appearanceMonitor: AppearanceMonitor?

    init(state: ShellState) {
        self.state = state
        super.init()
        appearanceMonitor = AppearanceMonitor { [weak self] in self?.sendAppearance() }
    }

    /// macOS's accent colour and appearance, for the page's macOS palette. Only once the page can hear it.
    func sendAppearance() {
        guard state.ready else { return }
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
        case .title(let title, let subtitle):
            state.title = title
            state.subtitle = subtitle
        case .shell(let model): state.shell = model
        case .navigator(let model): state.navigator = model
        case .navigatorFallback(let active): state.navigatorFallback = active
        case .toolbar(let items): state.toolbarItems = items
        case .appearance(let mode): state.pageMode = mode
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
        }
    }

    private func showContextMenu(requestId: String, items: [MenuItem], x: Double, y: Double) {
        guard let webView else {
            send(.reply(requestId: requestId, ok: false, error: "no web view"))
            return
        }
        var selected: String?
        let menu = MenuBuilder.menu(from: items) { selected = $0 }
        // The page's y grows downward; AppKit's y grows upward unless the view is flipped.
        let point = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        menu.popUp(positioning: nil, at: point, in: webView)
        send(.reply(requestId: requestId, ok: true, selectedId: .some(selected)))
    }

    // MARK: Shell -> page

    func send(_ command: NativeCommand) {
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

    private static func describe(_ m: PageMessage) -> String {
        switch m {
        case .ready(let p): "ready \(p)"
        case .route(let p, let a): "route \(p) area=\(a?.rawValue ?? "nil")"
        case .title(let t, _): "title \(t)"
        case .shell(let s): "shell areas=\(s.areas.count) apps=\(s.apps.count)"
        case .navigator(let n): "navigator \(n?.id ?? "nil")"
        case .navigatorFallback(let a): "navigatorFallback \(a)"
        case .toolbar(let i): "toolbar \(i.count) items"
        case .appearance(let m): "appearance \(m.rawValue)"
        case .confirmApproval(let r, let s): "confirmApproval \(r) \(s.rawValue)"
        case .openWorkspaceMenu(let r, _): "openWorkspaceMenu \(r)"
        case .contextMenu(let r, let i, _, _): "contextMenu \(r) \(i.count) items"
        }
    }
}

/// Builds an NSMenu from the protocol's MenuItem tree (the enum itself lives in System/MenuBuilder.swift).
@MainActor
extension MenuBuilder {
    static func menu(from items: [MenuItem], onSelect: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separator == true { menu.addItem(.separator()); continue }
            let mi = ClosureMenuItem(title: item.label ?? "", handler: onSelect, id: item.id)
            mi.isEnabled = item.disabled != true
            if item.checked == true { mi.state = .on }
            if let icon = item.icon { mi.image = SidebarIcons.image(icon) }
            if item.destructive == true {
                mi.attributedTitle = NSAttributedString(string: item.label ?? "", attributes: [.foregroundColor: NSColor.systemRed])
            }
            if let children = item.children, !children.isEmpty {
                mi.submenu = Self.menu(from: children, onSelect: onSelect)
                mi.target = nil
                mi.action = nil
            }
            menu.addItem(mi)
        }
        return menu
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: (String) -> Void
    private let itemId: String

    init(title: String, handler: @escaping (String) -> Void, id: String) {
        self.handler = handler
        self.itemId = id
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler(itemId) }
}

/// Watches macOS's accent colour and light/dark setting and calls `onChange` when either may have changed.
@MainActor
final class AppearanceMonitor: NSObject {
    private var observation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private let onChange: () -> Void
    private var last = ""

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        observation = NSApp?.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            Task { @MainActor in self?.fire() }
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        })
        for name in ["AppleColorPreferencesChangedNotification", "AppleInterfaceThemeChangedNotification"] {
            distributed.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.fire() }
            })
        }
        last = Self.signature()
    }

    /// Called when the window closes.
    func stop() {
        observation = nil
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        for t in distributed { DistributedNotificationCenter.default().removeObserver(t) }
        tokens = []; distributed = []
    }

    private func fire() {
        let now = Self.signature()
        guard now != last else { return }
        last = now
        onChange()
    }

    private static func signature() -> String {
        let (accent, mode) = current()
        return "\(accent)/\(mode.rawValue)"
    }

    /// The system accent as "#RRGGBB" (resolved for the effective appearance) and the app's effective mode.
    static func current() -> (accent: String, mode: ColorMode) {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let mode: ColorMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        var hex = "#0A84FF"
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                hex = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
        }
        return (hex, mode)
    }
}
