import AppKit
import VesperCore
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var app: AppModel!
    /// Menu actions. Later agents assign their implementation here.
    var actions: AppActions { app.actions }
    private var pendingLinks: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let dataDir = Self.resolveDataDirectory(env)
        vlog("data dir: \(dataDir.path)")

        var stack: StackController?
        var dev: Connection?
        if let base = env["VESPER_DEV_BASE_URL"], let token = env["VESPER_DEV_SESSION_TOKEN"], let url = URL(string: base) {
            vlog("dev bypass: using \(base), no stack")
            dev = Connection(baseURL: url, sessionToken: token)
        } else {
            stack = StackController(dataDirectory: dataDir)
        }
        app = AppModel(dataDirectory: dataDir, stack: stack, devConnection: dev)
        NSApp.mainMenu = MainMenu.build(delegate: self)
        ShellBridge.services = app.system
        app.system.start()
        app.aux.start()
        app.startHidden = app.aux.shouldStartHidden()

        if let stack {
            stack.apply(app.settings.settings.stack)
            Task { await stack.start() }
        }
        launched = true
        if let dev {
            Task {
                await app.installCookieIfNeeded(dev)
                app.restoreOrOpenFirstWindow()
                drainPendingLinks()
            }
        } else {
            app.restoreOrOpenFirstWindow()
            drainPendingLinks()
        }
        NSApp.activate()
    }

    /// ~/Library/Application Support/vesper-desktop (Electron's userData), or VESPER_USER_DATA_DIR.
    static func resolveDataDirectory(_ env: [String: String]) -> URL {
        StackController.defaultDataDirectory(environment: env).standardizedFileURL
    }

    // MARK: Lifecycle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vlog("quit: asked to terminate")
        Task {
            for window in app.windows where !(await window.confirmLeavingUnsavedChanges()) {
                vlog("quit: cancelled for unsaved changes")
                Self.replyToTerminate(false)
                return
            }
            guard await app.system.confirmQuit() else {
                vlog("quit: cancelled for active runs")
                Self.replyToTerminate(false)
                return
            }
            app.saveSessionNow()
            vlog("quit: stopping the stack")
            if let stack = app.stack { await stack.stop() }
            vlog("quit: replying yes")
            Self.replyToTerminate(true)
        }
        return .terminateLater
    }

    /// Answers `.terminateLater`, then wakes AppKit's wait for it. While the reply is pending AppKit
    /// blocks in nextEventMatchingMask (NSModalPanelRunLoopMode) and only checks the reply when an
    /// event arrives. ⌘Q is followed by its key-up, but Quit from the menu bar extra or the Dock
    /// leaves no event behind, so the app sat there until the next click (a second Quit).
    private static func replyToTerminate(_ shouldTerminate: Bool) {
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        app.system.shouldTerminateAfterLastWindowClosed()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { app.system.dockMenu() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.newWindow() }
        return true
    }

    // MARK: Deep links

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { app.aux.openFiles(files) }
        pendingLinks += urls.filter { !$0.isFileURL }
        if launched && !app.windows.isEmpty { drainPendingLinks() }
    }

    private func drainPendingLinks() {
        let links = pendingLinks
        pendingLinks = []
        for url in links where url.scheme?.lowercased() == vesperScheme { handleLink(url.absoluteString) }
    }

    func handleLink(_ raw: String) {
        switch DeepLinks.parse(raw) {
        case .rejected(let reason):
            vlog("deep link rejected: \(reason)")
        case .ok(.capture):
            actions.quickCapture()
        case .ok(.navigate(let path)):
            if let controller = app.keyController {
                controller.send(.navigate(path: path))
                controller.window?.makeKeyAndOrderFront(nil)
            } else {
                app.openVesperTab(path: path, nextTo: nil)
            }
            NSApp.activate()
        }
    }

    // MARK: File / app menu actions

    /// ⌘T and the system tab bar's +.
    @objc func newWindowForTab(_ sender: Any?) { app.openNewTab(from: NSApp.keyWindow) }
    @objc func newWindowAction(_ sender: Any?) { app.newWindow() }
    @objc func reopenClosedTab(_ sender: Any?) { app.reopenClosedTab(nextTo: NSApp.keyWindow) }
    /// ⌘W: the active tab of a Vesper window (a window's last tab closes it, the app's only tab
    /// becomes a new chat), else the key window (Settings, a popup).
    @objc func closeTab(_ sender: Any?) {
        if let c = NSApp.keyWindow?.windowController as? MainWindowController, !c.retired {
            c.closeActiveTab()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }
    /// ⇧⌘W: the window with all its tabs.
    @objc func closeAllTabs(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        if compactController != nil { window.performClose(nil); return }
        // performClose runs windowShouldClose, so each tab still asks about unsaved changes.
        for w in window.tabbedWindows ?? [window] { w.performClose(nil) }
    }
    @objc func quickCapture(_ sender: Any?) { actions.quickCapture() }
    @objc func screenshotToChat(_ sender: Any?) { actions.screenshotToChat() }
    @objc func importBackup(_ sender: Any?) { actions.importBackup() }
    @objc func openSettings(_ sender: Any?) { actions.openSettings() }
    @objc func checkForUpdates(_ sender: Any?) { actions.checkForUpdates() }
    @objc func restartStack(_ sender: Any?) { actions.restartStack() }
    @objc func showLogs(_ sender: Any?) { actions.showLogs() }
    @objc func openDocs(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/liamphmurphy/vesper")!)
    }

    // MARK: Edit / View / History

    private var web: WKWebView? { app.keyController?.webView }

    @objc func find(_ sender: Any?) { app.keyController?.send(.command(.find)) }
    /// ⌥⌘F: opens the page's command palette, like the toolbar's search button.
    @objc func focusSearch(_ sender: Any?) { app.keyController?.send(.command(.openCommandMenu)) }
    @objc func toggleSidebarAction(_ sender: Any?) { app.keyController?.split.toggleSidebar(sender) }
    @objc func reload(_ sender: Any?) { web?.reload() }
    @objc func forceReload(_ sender: Any?) { web?.reloadFromOrigin() }
    @objc func zoomIn(_ sender: Any?) { if let web { web.pageZoom = min(web.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ sender: Any?) { if let web { web.pageZoom = max(web.pageZoom - 0.1, 0.3) } }
    @objc func zoomReset(_ sender: Any?) { web?.pageZoom = 1 }
    @objc func goBack(_ sender: Any?) { web?.goBack() }
    @objc func goForward(_ sender: Any?) { web?.goForward() }

    /// Opens Web Inspector. WebKit has no public API for this; "Inspect Element" in the page's
    /// context menu (isInspectable) is the supported route, so this only uses the SPI if present.
    @objc func showInspector(_ sender: Any?) {
        guard let web else { return }
        let sel = NSSelectorFromString("_inspector")
        guard web.responds(to: sel), let inspector = web.perform(sel)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { inspector.perform(show) }
    }

    // MARK: Tabs

    /// The key window's controller when it uses the compact layout.
    private var compactController: MainWindowController? {
        guard let c = NSApp.keyWindow?.windowController as? MainWindowController, c.compact, !c.retired else { return nil }
        return c
    }

    private func tabs() -> (windows: [NSWindow], index: Int)? {
        guard let key = NSApp.keyWindow else { return nil }
        let all = key.tabbedWindows ?? [key]
        return (all, all.firstIndex(of: key) ?? 0)
    }

    @objc func nextTab(_ sender: Any?) {
        if let c = compactController { c.selectNextTab(); return }
        guard let (all, i) = tabs(), all.count > 1 else { return }
        all[(i + 1) % all.count].makeKeyAndOrderFront(nil)
    }

    @objc func previousTab(_ sender: Any?) {
        if let c = compactController { c.selectPreviousTab(); return }
        guard let (all, i) = tabs(), all.count > 1 else { return }
        all[(i - 1 + all.count) % all.count].makeKeyAndOrderFront(nil)
    }

    /// ⌘1–8 select that tab, ⌘9 the last one.
    @objc func selectTab(_ sender: NSMenuItem) {
        if let c = compactController { c.selectNumberedTab(sender.tag); return }
        guard let (all, _) = tabs(), !all.isEmpty else { return }
        let n = sender.tag
        let target = n == 9 ? all.count - 1 : n - 1
        guard all.indices.contains(target) else { return }
        all[target].makeKeyAndOrderFront(nil)
    }

    /// The four system tab commands: the system's in the separate layout, ours in the compact one.
    @objc func moveTabToNewWindowAction(_ sender: Any?) {
        if let c = compactController { app.moveTabToNewWindow(c.content, from: c) } else { forwardToWindow(#selector(NSWindow.moveTabToNewWindow(_:)), sender) }
    }
    @objc func mergeAllWindowsAction(_ sender: Any?) {
        if let c = compactController { app.mergeAllWindows(into: c) } else { forwardToWindow(#selector(NSWindow.mergeAllWindows(_:)), sender) }
    }
    @objc func toggleTabBarAction(_ sender: Any?) { forwardToWindow(#selector(NSWindow.toggleTabBar(_:)), sender) }
    @objc func showAllTabsAction(_ sender: Any?) { forwardToWindow(#selector(NSWindow.toggleTabOverview(_:)), sender) }

    private func forwardToWindow(_ action: Selector, _ sender: Any?) {
        NSApp.sendAction(action, to: nil, from: sender)
    }

    /// Asks the key window whether it would enable `action` (the system tab commands).
    private func windowAllows(_ action: Selector, _ item: NSMenuItem) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let probe = NSMenuItem(title: item.title, action: action, keyEquivalent: "")
        let ok = window.validateMenuItem(probe)
        item.title = probe.title
        return ok
    }

    @objc func toggleCompactLayout(_ sender: Any?) {
        app.aux.update { $0.tabs.layout = $0.tabs.layout == .compact ? .separate : .compact }
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reopenClosedTab(_:)): return app.canReopenClosedTab
        case #selector(goBack(_:)): return web?.canGoBack ?? false
        case #selector(goForward(_:)): return web?.canGoForward ?? false
        case #selector(toggleSidebarAction(_:)):
            guard let controller = app.keyController, controller.hasSidebar, let sidebar = controller.split.splitViewItems.first else { return false }
            item.title = sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(find(_:)), #selector(reload(_:)), #selector(forceReload(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomReset(_:)), #selector(showInspector(_:)):
            return web != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            if let c = compactController { return c.tabs.list.count > 1 }
            return (tabs()?.windows.count ?? 0) > 1
        case #selector(toggleCompactLayout(_:)):
            item.state = app.compactLayout ? .on : .off
            return true
        case #selector(moveTabToNewWindowAction(_:)):
            if let c = compactController { return c.tabs.list.count > 1 }
            return windowAllows(#selector(NSWindow.moveTabToNewWindow(_:)), item)
        case #selector(mergeAllWindowsAction(_:)):
            if let c = compactController { return c.compact && app.compactWindowCount > 1 }
            return windowAllows(#selector(NSWindow.mergeAllWindows(_:)), item)
        case #selector(toggleTabBarAction(_:)):
            return compactController == nil && windowAllows(#selector(NSWindow.toggleTabBar(_:)), item)
        case #selector(showAllTabsAction(_:)):
            return compactController == nil && windowAllows(#selector(NSWindow.toggleTabOverview(_:)), item)
        default: return true
        }
    }
}
