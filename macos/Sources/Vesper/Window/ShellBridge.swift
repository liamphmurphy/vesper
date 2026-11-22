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
                let entered = await Self.promptSheet(
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
        }
    }

    /// The page's confirmAction as a sheet on its window: Return confirms, Esc cancels.
    private func confirmSheet(title: String, body: String?, confirmLabel: String, cancelLabel: String?, destructive: Bool) async -> Bool {
        await Self.confirmSheet(title: title, body: body, confirmLabel: confirmLabel, cancelLabel: cancelLabel, destructive: destructive, window: webView?.window)
    }

    static func confirmSheet(title: String, body: String?, confirmLabel: String, cancelLabel: String?, destructive: Bool, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = body ?? ""
        let confirm = alert.addButton(withTitle: confirmLabel)
        confirm.hasDestructiveAction = destructive
        // NSAlert only gives Esc to a button titled "Cancel"; the page may name it "Keep editing".
        alert.addButton(withTitle: cancelLabel ?? "Cancel").keyEquivalent = "\u{1b}"
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        // A sheet already up (another confirm, the unsaved-changes alert) would make this one queue
        // invisibly; answer no instead, as the in-app dialog does when replaced.
        guard window.attachedSheet == nil else { return false }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func promptSheet(
        title: String,
        body: String?,
        label: String?,
        value: String?,
        placeholder: String?,
        confirmLabel: String,
        cancelLabel: String?,
        maxLength: Int?,
        window: NSWindow?
    ) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body ?? label ?? ""
        let confirm = alert.addButton(withTitle: confirmLabel)
        alert.addButton(withTitle: cancelLabel ?? "Cancel").keyEquivalent = "\u{1b}"

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead
        field.placeholderString = placeholder ?? label
        if let value {
            field.stringValue = maxLength.map { String(value.prefix($0)) } ?? value
        }
        let delegate = PromptFieldDelegate(confirmButton: confirm, maxLength: maxLength)
        field.delegate = delegate
        confirm.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.layout()

        let accepted: Bool
        if let window {
            guard window.attachedSheet == nil else { return nil }
            Task { @MainActor in
                field.selectText(nil)
            }
            accepted = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        } else {
            field.selectText(nil)
            accepted = alert.runModal() == .alertFirstButtonReturn
        }
        withExtendedLifetime(delegate) {}
        return accepted ? field.stringValue : nil
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

@MainActor
private final class PromptFieldDelegate: NSObject, NSTextFieldDelegate {
    weak var confirmButton: NSButton?
    let maxLength: Int?

    init(confirmButton: NSButton, maxLength: Int?) {
        self.confirmButton = confirmButton
        self.maxLength = maxLength
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if let maxLength, field.stringValue.count > maxLength {
            field.stringValue = String(field.stringValue.prefix(maxLength))
        }
        confirmButton?.isEnabled = !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
