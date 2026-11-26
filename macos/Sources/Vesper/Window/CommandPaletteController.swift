import AppKit
import SwiftUI
import VesperCore

@MainActor
private final class CommandPalettePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class CommandPaletteGlassView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        updateBorderColor()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let border = isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.14)
            self.layer?.borderColor = border.cgColor
        }
    }
}

/// Hosts Vesper's native SwiftUI floating Command Palette (`⌘K` / `⇧⌘K`) in a borderless
/// Spotlight-style `NSPanel` centered over the active window's content pane.
@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    private weak var aux: AuxWindows?
    private weak var targetController: MainWindowController?

    let model = CommandPaletteModel()

    private var panel: CommandPalettePanel?
    private var glassView: CommandPaletteGlassView?
    private var hostingController: NSHostingController<CommandPaletteView>?
    private var baseURL: URL?
    private var lastScope: CommandPaletteScope?
    private var appearanceMonitor: AppearanceMonitor?

    var isVisible: Bool { panel?.isVisible == true }

    init(aux: AuxWindows) {
        self.aux = aux
        super.init()
        wireModel()
        appearanceMonitor = AppearanceMonitor { [weak self] in self?.sendAppearance() }
    }

    func connect(_ conn: Connection) {
        baseURL = conn.baseURL
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

        let theme = currentTheme()
        let panel = ensurePanel()
        applyPanelAppearance(mode: theme.mode)
        model.open(request: resolved, theme: theme)
        position(panel, relativeTo: target)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
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
            target.window?.makeFirstResponder(target.content.focusView)
        }
    }

    func teardown() {
        appearanceMonitor?.stop()
        appearanceMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        glassView = nil
        hostingController = nil
    }

    func sendAppearance(_ command: NativeCommand? = nil) {
        let theme = currentTheme()
        model.updateTheme(theme)
        applyPanelAppearance(mode: theme.mode)
    }

    // MARK: - Private Setup & Layout

    private func wireModel() {
        model.storeProvider = { [weak self] in self?.aux?.store }
        model.clientProvider = { [weak self] in self?.aux?.client() }
        model.browserTabsProvider = { [weak self] in
            self?.aux?.app?.browser.orderedTabs.map(\.record) ?? []
        }
        model.browserProfilesProvider = { [weak self] in
            guard let browser = self?.aux?.app?.browser else { return [] }
            return browser.profiles.map { (id: $0.id, name: $0.name, isActive: $0.id == browser.activeProfileId) }
        }
        model.onSelectBrowserTab = { [weak self] tabId in
            guard let self, let app = self.aux?.app else { return }
            app.browser.selectTab(tabId)
            if let target = self.targetController {
                if !target.isBrowserActive {
                    target.content.navigate(path: "/browser")
                }
                target.window?.makeKeyAndOrderFront(nil)
            } else {
                app.openVesperTab(path: "/browser", nextTo: nil)
            }
        }
        model.onOpenInBrowser = { [weak self] raw in
            guard let self, let app = self.aux?.app,
                  let url = BrowserURLResolver.resolve(raw, searchEngine: app.browser.searchEngine)
            else { return }
            if let target = self.targetController {
                target.openInBrowser(url)
            } else {
                app.browser.openURL(url, inNewTab: true)
                app.openVesperTab(path: "/browser", nextTo: nil)
            }
        }
        model.onSwitchBrowserProfile = { [weak self] profileId in
            guard let self, let app = self.aux?.app else { return }
            app.browser.switchProfile(to: profileId)
            if let target = self.targetController, !target.isBrowserActive {
                target.content.navigate(path: "/browser")
            }
        }
        model.onToggleBrowserSplitView = { [weak self] in
            guard let self, let app = self.aux?.app else { return }
            if let target = self.targetController, !target.isBrowserActive {
                target.content.navigate(path: "/browser")
            }
            app.browser.toggleSplitView()
        }
        model.onOpenBrowserExtensions = { [weak self] in
            guard let self, let app = self.aux?.app else { return }
            if let target = self.targetController, !target.isBrowserActive {
                target.content.navigate(path: "/browser")
            }
            app.browser.triggerExtensionsPopover()
        }
        model.onOpenBrowserAutofill = { [weak self] in
            guard let self, let app = self.aux?.app else { return }
            if let target = self.targetController, !target.isBrowserActive {
                target.content.navigate(path: "/browser")
            }
            app.browser.triggerAutofillPopover()
        }
        model.onClose = { [weak self] restoreFocus in
            self?.close(restoreFocus: restoreFocus)
        }
        model.onNavigate = { [weak self] path, newTab in
            guard let self else { return }
            if SettingsRouteResolver.resolve(path) != nil {
                _ = self.aux?.app?.handleSettingsPath(path, from: self.targetController?.window)
                return
            }
            if newTab {
                self.aux?.app?.openVesperTab(path: path, nextTo: self.targetController?.window)
            } else if let target = self.targetController {
                target.content.navigate(path: path)
                target.window?.makeKeyAndOrderFront(nil)
            } else {
                self.aux?.app?.openVesperTab(path: path, nextTo: nil)
            }
        }
        model.onOpenSettings = { [weak self] destination in
            self?.aux?.openSettings(destination: destination)
        }
        model.onShowShortcuts = { [weak self] in
            self?.aux?.showShortcuts()
        }
        model.onNewWindow = { [weak self] in
            self?.aux?.app?.newWindow()
        }
        model.onOpenCustomAppWindow = { [weak self] slug in
            self?.aux?.openCustomAppWindow(slug: slug)
        }
        model.onToggleSidebar = { [weak self] in
            self?.targetController?.split.toggleSidebar(nil)
        }
        model.onToggleInspector = { [weak self] in
            self?.targetController?.toggleInspector(nil)
        }
        model.onToast = { [weak self] title, tone in
            let toast = ToastItemModel(
                id: "palette-\(UUID().uuidString)",
                title: title,
                description: nil,
                tone: tone,
                actionLabel: nil,
                durationMs: 3200
            )
            self?.targetController?.showNativeToast(toast) { _ in }
        }
    }

    private func currentTheme() -> ThemeTokens {
        if let app = aux?.app {
            return app.effectiveTheme()
        }
        let sys = AppearanceMonitor.current()
        return PaletteTokens.themeTokens(for: .macOSDefault, systemColorMode: sys.mode, systemAccent: sys.accent)
    }

    private func applyPanelAppearance(mode: ColorMode) {
        guard let panel else { return }
        if mode == AppearanceMonitor.current().mode {
            panel.appearance = nil
        } else {
            panel.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        }
        glassView?.updateBorderColor()
    }

    private func ensurePanel() -> CommandPalettePanel {
        if let panel { return panel }
        let initialSize = NSRect(x: 0, y: 0, width: CommandPaletteLayout.defaultWidth, height: CommandPaletteLayout.defaultHeight)
        let panel = CommandPalettePanel(
            contentRect: initialSize,
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
        panel.onEscape = { [weak self] in self?.model.handleEscape() }
        panel.onKeyEquivalent = { [weak self] event in self?.handlePanelKeyEquivalent(event) ?? false }

        let glass = CommandPaletteGlassView(frame: initialSize)
        let host = NSHostingController(rootView: CommandPaletteView(model: model))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        glass.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: glass.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass
        self.glassView = glass
        self.hostingController = host
        self.panel = panel
        return panel
    }

    private func handlePanelKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // ⌘K toggles the palette closed; ⇧⌘K switches to page-scoped (or toggles closed if already scoped).
        if flags == .command && chars == "k" {
            if lastScope == .all || lastScope == nil {
                close(restoreFocus: true)
            } else {
                open(request: CommandPaletteRequest(scope: .all), from: targetController)
            }
            return true
        }
        if flags == [.command, .shift] && chars == "k" {
            if lastScope == .page {
                close(restoreFocus: true)
            } else {
                open(request: CommandPaletteRequest(scope: .page), from: targetController)
            }
            return true
        }

        // ⌘↵ opens in a new tab; ⌥↵ attaches to a new chat; ⇧↵ creates a page in Knowledge mode.
        if event.keyCode == 36 || event.keyCode == 76 {
            if flags == .command {
                model.confirm(newTab: true)
                return true
            }
            if flags == .option {
                model.confirm(attach: true)
                return true
            }
            if flags == .shift && model.isKnowledgeMode {
                model.confirm(createKnowledge: true)
                return true
            }
        }

        // ⌃N / ⌃P move selection down/up (standard macOS Emacs-style list bindings).
        if flags == .control {
            if chars == "n" {
                model.moveDown()
                return true
            }
            if chars == "p" {
                model.moveUp()
                return true
            }
        }

        // ⌥A / ⌥D approve or deny a selected inbox approval.
        if flags == .option {
            if chars == "a" && model.approveSelected() { return true }
            if chars == "d" && model.denySelected() { return true }
        }

        return false
    }

    private func position(_ panel: NSPanel, relativeTo target: MainWindowController?) {
        let parentWindow = target?.window
        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let contentRect = target?.contentPaneScreenFrame.map {
            CommandPaletteRect(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
        }
        let windowRect = parentWindow.map {
            CommandPaletteRect(x: $0.frame.origin.x, y: $0.frame.origin.y, width: $0.frame.width, height: $0.frame.height)
        }
        let visibleRect = CommandPaletteRect(x: visible.origin.x, y: visible.origin.y, width: visible.width, height: visible.height)

        let targetFrame = CommandPaletteLayout.panelFrame(
            contentPane: contentRect,
            window: windowRect,
            visibleScreen: visibleRect
        )
        panel.setFrame(
            NSRect(x: targetFrame.x, y: targetFrame.y, width: targetFrame.width, height: targetFrame.height),
            display: true
        )
    }

    private func enrich(_ initial: CommandPaletteRequest, from target: MainWindowController?, baseURL: URL) -> CommandPaletteRequest {
        var req = initial
        if req.path == nil {
            if let route = target?.state.route, !route.isEmpty {
                let parts = route.split(separator: "?", maxSplits: 1)
                req.path = parts.first.map(String.init) ?? "/"
                if req.search == nil, parts.count > 1 {
                    req.search = "?\(parts[1])"
                }
            } else if let url = target?.content.webView?.url, BridgeOrigin.matches(url: url, base: baseURL) {
                req.path = url.path.isEmpty ? "/" : url.path
                if req.search == nil, let query = url.query, !query.isEmpty {
                    req.search = "?\(query)"
                }
            } else {
                req.path = "/"
            }
        }
        return req
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if panel?.attachedSheet == nil && !model.moreMenuOpen {
            close(restoreFocus: false)
        }
    }
}
