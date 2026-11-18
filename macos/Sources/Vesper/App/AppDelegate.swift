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

        if let stack { Task { await stack.start() } }
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
        // INTEGRATE: use StackController.defaultDataDirectory() once it exists.
        if let override = env["VESPER_USER_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("vesper-desktop")
    }

    // MARK: Lifecycle

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // INTEGRATE: confirm quit when runs are active (power.confirmQuitWithActiveRuns).
        app.saveSessionNow()
        guard let stack = app.stack else { return .terminateNow }
        Task {
            await stack.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // INTEGRATE: tray.closeLastWindow setting (stay in Dock / menu bar only / quit).
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.newWindow() }
        return true
    }

    // MARK: Deep links

    func application(_ application: NSApplication, open urls: [URL]) {
        // INTEGRATE: also route dropped/opened files (drop.ts) here.
        pendingLinks += urls
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

    @objc func newWindowForTab(_ sender: Any?) { app.openVesperTab(path: "/", nextTo: NSApp.keyWindow) }
    @objc func newWindowAction(_ sender: Any?) { app.newWindow() }
    @objc func reopenClosedTab(_ sender: Any?) { app.reopenClosedTab(nextTo: NSApp.keyWindow) }
    @objc func closeAllTabs(_ sender: Any?) {
        guard let window = NSApp.keyWindow else { return }
        for w in window.tabbedWindows ?? [window] { w.close() }
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
    @objc func focusSearch(_ sender: Any?) { app.keyController?.focusSearch() }
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

    private func tabs() -> (windows: [NSWindow], index: Int)? {
        guard let key = NSApp.keyWindow else { return nil }
        let all = key.tabbedWindows ?? [key]
        return (all, all.firstIndex(of: key) ?? 0)
    }

    @objc func nextTab(_ sender: Any?) {
        guard let (all, i) = tabs(), all.count > 1 else { return }
        all[(i + 1) % all.count].makeKeyAndOrderFront(nil)
    }

    @objc func previousTab(_ sender: Any?) {
        guard let (all, i) = tabs(), all.count > 1 else { return }
        all[(i - 1 + all.count) % all.count].makeKeyAndOrderFront(nil)
    }

    /// ⌘1–8 select that tab, ⌘9 the last one.
    @objc func selectTab(_ sender: NSMenuItem) {
        guard let (all, _) = tabs(), !all.isEmpty else { return }
        let n = sender.tag
        let target = n == 9 ? all.count - 1 : n - 1
        guard all.indices.contains(target) else { return }
        all[target].makeKeyAndOrderFront(nil)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(reopenClosedTab(_:)): return app.canReopenClosedTab
        case #selector(goBack(_:)): return web?.canGoBack ?? false
        case #selector(goForward(_:)): return web?.canGoForward ?? false
        case #selector(toggleSidebarAction(_:)):
            guard let split = app.keyController?.split, app.keyController?.kind == .vesper, let sidebar = split.splitViewItems.first else { return false }
            item.title = sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(find(_:)), #selector(reload(_:)), #selector(forceReload(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomReset(_:)), #selector(showInspector(_:)):
            return web != nil
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return (tabs()?.windows.count ?? 0) > 1
        default: return true
        }
    }
}
