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
    private let companionBonjour = CompanionBonjourAdvertiser()

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
        app.system.start()
        app.aux.start()
        app.startHidden = app.aux.shouldStartHidden()

        if let stack {
            stack.apply(app.settings.settings.stack)
            companionBonjour.update(
                enabled: app.settings.settings.stack.companionEnabled,
                port: app.settings.settings.stack.companionPort
            )
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

    /// `terminate` can be called from inside a main-queue block, where a plain `.terminateLater`
    /// cleanup can't start; the coordinator copes with that (see QuitCoordinator).
    private lazy var quit = QuitCoordinator(
        cleanup: { [unowned self] in await prepareToQuit() },
        reply: { shouldTerminate in
            vlog("quit: replying \(shouldTerminate ? "yes" : "no")")
            Self.replyToTerminate(shouldTerminate)
        },
        terminate: {
            vlog("quit: cleanup finished after unwinding; quitting again")
            NSApp.terminate(nil)
        }
    )

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vlog("quit: asked to terminate")
        return quit.shouldTerminate()
    }

    /// Active runs, then the stack. false: stay open.
    private func prepareToQuit() async -> Bool {
        guard await app.system.confirmQuit() else {
            vlog("quit: cancelled for active runs")
            return false
        }
        app.saveSessionNow()
        app.aux.cleanupQuickLook()
        vlog("quit: stopping the stack")
        if let stack = app.stack { await stack.stop() }
        return true
    }

    /// Answers `.terminateLater`, then wakes AppKit's wait for it. While the reply is pending AppKit
    /// blocks in nextEventMatchingMask (NSModalPanelRunLoopMode) and only checks the reply when an
    /// event arrives; posting one means the reply never waits for the person's next click.
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

    /// ⌘T and the system tab bar's +. When Browser is active, opens a new web tab inside Browser.
    @objc func newWindowForTab(_ sender: Any?) {
        if let c = app.keyController, c.isBrowserActive {
            _ = app.browser.newTab(isPrivate: false, select: true)
            return
        }
        app.openNewTab(from: NSApp.keyWindow)
    }
    @objc func newWindowAction(_ sender: Any?) { app.newWindow() }
    @objc func reopenClosedTab(_ sender: Any?) {
        if let c = app.keyController, c.isBrowserActive, app.browser.canReopenClosedTab {
            app.browser.reopenClosedTab()
            return
        }
        app.reopenClosedTab(nextTo: NSApp.keyWindow)
    }
    /// ⌘W: closes the active web tab when Browser is active, else the active Vesper tab (or key window).
    @objc func closeTab(_ sender: Any?) {
        if let c = NSApp.keyWindow?.windowController as? MainWindowController, !c.retired {
            if c.isBrowserActive {
                app.browser.closeActiveTab()
            } else {
                c.closeActiveTab()
            }
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
    @objc func showShortcuts(_ sender: Any?) { actions.showShortcuts() }
    @objc func checkForUpdates(_ sender: Any?) { actions.checkForUpdates() }
    @objc func restartStack(_ sender: Any?) { actions.restartStack() }
    @objc func showLogs(_ sender: Any?) { actions.showLogs() }
    @objc func openDocs(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/liamphmurphy/vesper")!)
    }

    // MARK: Edit / View / History

    private var web: WKWebView? {
        app.keyController?.webView
    }

    @objc func find(_ sender: Any?) { app.keyController?.showFindBar() }
    @objc func findNext(_ sender: Any?) { app.keyController?.findNext() }
    @objc func findPrevious(_ sender: Any?) { app.keyController?.findPrevious() }
    @objc func useSelectionForFind(_ sender: Any?) { app.keyController?.useSelectionForFind() }
    private func isOnKnowledgeRoute(_ controller: MainWindowController?) -> Bool {
        guard let route = controller?.state.route else { return false }
        return route == "/knowledge" || route.hasPrefix("/knowledge/") || route.hasPrefix("/knowledge?") || route.hasPrefix("/wiki/")
    }

    /// ⌘K: opens Knowledge Quick Switcher when in Knowledge, otherwise opens the global command palette.
    @objc func openCommandPalette(_ sender: Any?) {
        if let controller = app.keyController, isOnKnowledgeRoute(controller), let window = controller.window {
            NotificationCenter.default.post(name: .vesperOpenKnowledgeQuickSwitcher, object: window)
            return
        }
        app.aux.openCommandPalette(request: CommandPaletteRequest(scope: .all), from: app.keyController)
    }
    /// ⌘O: opens Knowledge Quick Switcher (or Knowledge-scoped Command Palette from other screens).
    @objc func openQuickSwitcher(_ sender: Any?) {
        if let controller = app.keyController, isOnKnowledgeRoute(controller), let window = controller.window {
            NotificationCenter.default.post(name: .vesperOpenKnowledgeQuickSwitcher, object: window)
            return
        }
        app.aux.openCommandPalette(request: CommandPaletteRequest(scope: .knowledge), from: app.keyController)
    }
    /// ⇧⌘K: opens the floating command palette scoped to the current view.
    @objc func openScopedCommandPalette(_ sender: Any?) {
        app.aux.openCommandPalette(request: CommandPaletteRequest(scope: .page), from: app.keyController)
    }
    /// ⌥⌘F: opens the floating command palette, like the toolbar's search button.
    @objc func focusSearch(_ sender: Any?) {
        app.aux.openCommandPalette(request: CommandPaletteRequest(scope: .all), from: app.keyController)
    }
    @objc func toggleSidebarAction(_ sender: Any?) { app.keyController?.split.toggleSidebar(sender) }
    @objc func toggleInspectorAction(_ sender: Any?) { app.keyController?.toggleInspector(sender) }
    @objc func reload(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true {
            app.browser.activeTab?.reload(fromOrigin: false)
            return
        }
        web?.reload()
    }
    @objc func forceReload(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true {
            app.browser.activeTab?.reload(fromOrigin: true)
            return
        }
        web?.reloadFromOrigin()
    }
    @objc func zoomIn(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true {
            app.browser.adjustZoom(delta: 0.1)
            return
        }
        if let web {
            web.pageZoom = min(web.pageZoom + 0.1, 3)
            return
        }
        app.aux.update { s in
            var next = s.effectiveAppearance
            next.textSize = next.textSize.steppedIn()
            s.appearance = next
        }
    }
    @objc func zoomOut(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true {
            app.browser.adjustZoom(delta: -0.1)
            return
        }
        if let web {
            web.pageZoom = max(web.pageZoom - 0.1, 0.3)
            return
        }
        app.aux.update { s in
            var next = s.effectiveAppearance
            next.textSize = next.textSize.steppedOut()
            s.appearance = next
        }
    }
    @objc func zoomReset(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true {
            app.browser.resetZoom()
            return
        }
        if let web {
            web.pageZoom = 1
            return
        }
        app.aux.update { s in
            var next = s.effectiveAppearance
            next.textSize = .default
            s.appearance = next
        }
    }
    @objc func goBack(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true, let tab = app.browser.activeTab, tab.canGoBack {
            tab.goBack()
            return
        }
        app.keyController?.content.goBack()
    }
    @objc func goForward(_ sender: Any?) {
        if app.keyController?.isBrowserActive == true, let tab = app.browser.activeTab, tab.canGoForward {
            tab.goForward()
            return
        }
        app.keyController?.content.goForward()
    }

    // MARK: Browser Menu Actions

    @objc func focusBrowserAddressBar(_ sender: Any?) {
        guard let c = app.keyController else { return }
        if !c.isBrowserActive {
            c.content.navigate(path: "/browser")
        }
        app.browser.focusAddressBar()
    }

    @objc func newPrivateBrowserTab(_ sender: Any?) {
        guard let c = app.keyController else { return }
        if !c.isBrowserActive {
            c.content.navigate(path: "/browser")
        }
        _ = app.browser.newTab(isPrivate: true, select: true)
    }

    @objc func newBrowserTabGroup(_ sender: Any?) {
        guard let c = app.keyController, c.isBrowserActive else { return }
        let n = app.browser.tabGroups.count + 1
        _ = app.browser.createTabGroup(name: "Group \(n)", initialTabId: app.browser.activeTab?.id)
    }

    @objc func toggleBrowserSplitView(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.toggleSplitView()
    }

    @objc func toggleBrowserFocusMode(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.toggleFocusMode()
    }

    @objc func swapBrowserSplitPanes(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.swapSplitPanes()
    }

    @objc func toggleBrowserTabMute(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.toggleMute()
    }

    @objc func captureBrowserRegionScreenshot(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.beginRegionCapture()
    }

    @objc func openBrowserAutofill(_ sender: Any?) {
        guard let c = app.keyController else { return }
        if !c.isBrowserActive {
            c.content.navigate(path: "/browser")
        }
        app.browser.triggerAutofillPopover()
    }

    @objc func openBrowserExtensions(_ sender: Any?) {
        guard let c = app.keyController else { return }
        if !c.isBrowserActive {
            c.content.navigate(path: "/browser")
        }
        app.browser.triggerExtensionsPopover()
    }

    @objc func toggleBrowserReaderMode(_ sender: Any?) {
        guard let c = app.keyController, c.isBrowserActive, let tab = app.browser.activeTab else { return }
        let isDark = (c.state.pageMode ?? c.state.theme?.mode) == .dark
        Task { await tab.toggleReaderMode(darkMode: isDark) }
    }

    @objc func toggleBrowserBookmark(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.toggleBookmark()
    }

    @objc func highlightBrowserSelection(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        Task { await app.browser.highlightSelection() }
    }

    @objc func toggleBrowserAutoFollow(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.setAutoFollowCompanionTab(!app.browser.isAutoFollowEnabled)
    }

    @objc func openBrowserPageInSafari(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true,
              let raw = app.browser.activeTab?.urlString,
              let url = URL(string: raw),
              BrowserURLResolver.isWebURL(url)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func nextBrowserTab(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.selectNextTab()
    }

    @objc func previousBrowserTab(_ sender: Any?) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.selectPreviousTab()
    }

    @objc func selectBrowserTab(_ sender: NSMenuItem) {
        guard app.keyController?.isBrowserActive == true else { return }
        app.browser.selectNumberedTab(sender.tag)
    }

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
        case #selector(reopenClosedTab(_:)):
            if app.keyController?.isBrowserActive == true {
                return app.browser.canReopenClosedTab || app.canReopenClosedTab
            }
            return app.canReopenClosedTab
        case #selector(goBack(_:)):
            if app.keyController?.isBrowserActive == true, app.browser.activeTab?.canGoBack == true {
                return true
            }
            return app.keyController?.content.canGoBack ?? false
        case #selector(goForward(_:)):
            if app.keyController?.isBrowserActive == true, app.browser.activeTab?.canGoForward == true {
                return true
            }
            return app.keyController?.content.canGoForward ?? false
        case #selector(focusBrowserAddressBar(_:)), #selector(newPrivateBrowserTab(_:)),
             #selector(openBrowserAutofill(_:)), #selector(openBrowserExtensions(_:)):
            return app.keyController?.kind == .vesper
        case #selector(newBrowserTabGroup(_:)), #selector(toggleBrowserSplitView(_:)):
            return app.keyController?.isBrowserActive == true
        case #selector(swapBrowserSplitPanes(_:)):
            return app.keyController?.isBrowserActive == true && app.browser.isSplitViewActive
        case #selector(toggleBrowserTabMute(_:)):
            guard app.keyController?.isBrowserActive == true, let tab = app.browser.activeTab else { return false }
            item.title = tab.isMuted ? "Unmute Tab" : "Mute Tab"
            return tab.hasLoadedPage
        case #selector(toggleBrowserReaderMode(_:)), #selector(toggleBrowserBookmark(_:)),
             #selector(openBrowserPageInSafari(_:)), #selector(captureBrowserRegionScreenshot(_:)):
            return app.keyController?.isBrowserActive == true && app.browser.activeTab?.hasLoadedPage == true
        case #selector(nextBrowserTab(_:)), #selector(previousBrowserTab(_:)):
            return app.keyController?.isBrowserActive == true && app.browser.tabs.count > 1
        case #selector(selectBrowserTab(_:)):
            guard app.keyController?.isBrowserActive == true else { return false }
            return BrowserTabListLogic.indexForNumberedShortcut(item.tag, count: app.browser.tabs.count) != nil
        case #selector(toggleSidebarAction(_:)):
            guard let controller = app.keyController, controller.hasSidebar, let sidebar = controller.split.splitViewItems.first else { return false }
            item.title = sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(toggleInspectorAction(_:)):
            guard let controller = app.keyController, controller.hasInspector, controller.kind == .vesper else { return false }
            let isOpen = (controller.state.inspector?.open ?? false) || !controller.isInspectorCollapsed
            item.title = isOpen ? "Hide Inspector" : "Show Inspector"
            return true
        case #selector(find(_:)), #selector(useSelectionForFind(_:)):
            return (NSApp.keyWindow?.windowController as? MainWindowController) != nil
        case #selector(reload(_:)), #selector(forceReload(_:)), #selector(showInspector(_:)):
            return web != nil
        case #selector(zoomIn(_:)):
            if app.keyController?.isBrowserActive == true || web != nil { return true }
            return app.settings.settings.effectiveAppearance.textSize.canStepIn
        case #selector(zoomOut(_:)):
            if app.keyController?.isBrowserActive == true || web != nil { return true }
            return app.settings.settings.effectiveAppearance.textSize.canStepOut
        case #selector(zoomReset(_:)):
            if app.keyController?.isBrowserActive == true || web != nil { return true }
            return app.settings.settings.effectiveAppearance.textSize != .default
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            guard let controller = app.keyController else { return false }
            return controller.isFindBarVisible && controller.hasFindQuery
        case #selector(openCommandPalette(_:)), #selector(openQuickSwitcher(_:)), #selector(openScopedCommandPalette(_:)), #selector(focusSearch(_:)):
            guard let controller = app.keyController, controller.kind == .vesper else { return false }
            let route = controller.state.route
            return route != "/dev" && route?.hasPrefix("/dev/") != true
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
