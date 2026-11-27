import AppKit
import VesperCore

/// The app's always-on system integration: menu bar extra, notifications, Dock badge/menu/progress,
/// power and thermal handling, Touch ID, the workspace folder menu, the Logs window, quit and
/// last-window policy. One per app (`AppModel.system`). See docs/dev/native-mac-app.md.
///
/// This class owns the monitors (event stream, inbox, runs) and the shared state the menu bar, the
/// Dock and the notifications draw from; the pieces live in MenuBar/, Notifications/, Dock/,
/// Power/, Logs/ and beside this file.
@MainActor
final class SystemServices {
    private weak var app: AppModel?

    private let eventStream = EventStream()
    private let inboxMonitor = InboxMonitor()
    private let runMonitor = RunMonitor()
    /// The native screens' shared data cache: one per app, so every window reads the same answers.
    let store = QueryStore()
    private var client: APIClient?
    private var monitoredConnection: Connection?

    private(set) var items: [InboxItem] = []
    /// The inbox as the right rail's Needs-you popover reads it (observable; `items` isn't).
    let railInbox = RailInbox()
    /// Native data source for the window right rail (PR reviews, Needs you, Settings).
    lazy var nativeRail = NativeRailStore(store: store, railInbox: railInbox)
    private(set) var liveRuns: [RunSummary] = []
    private(set) var badgeCount = 0
    private var dockBadge = ""
    private(set) var pausedByVesper = Set<String>()

    private let notifications = NotificationPresenter()
    private let dock = DockController()
    private lazy var menuBar = MenuBarController { [weak self] action in self?.perform(action) }
    private lazy var power = PowerController(hooks: PowerController.Hooks(
        settings: { [weak self] in self?.settings.power ?? NativeSettings.Power() },
        liveRuns: { [weak self] in self?.liveRuns ?? [] },
        client: { [weak self] in self?.client },
        pause: { [weak self] runs in await self?.pauseRuns(runs) },
        resume: { [weak self] in await self?.resumeRuns() },
        refreshRuns: { [weak self] in await self?.runMonitor.refreshNow() },
        notice: { [weak self] title, body in self?.notifications.notice(title: title, body: body, target: .href("/chat"), silent: true) },
        noticeChanged: { [weak self] in self?.refreshTray() }))
    private var logsWindow: LogsWindowController?
    private var started = false
    private var keyObserver: NSObjectProtocol?

    init(app: AppModel) {
        self.app = app
    }

    private var settings: NativeSettings { app?.settings.settings ?? NativeSettings() }
    var nativeSettings: NativeSettings { settings }

    /// Sends an API call as the signed-in user, then refreshes the inbox (the right rail's popover).
    func sendRailCall(_ call: APICall) async throws {
        guard let client else { throw APIError.unreachable }
        _ = try await client.send(call)
        await inboxMonitor.refreshNow()
    }

    // MARK: Start

    /// Called once after launch (before the stack is ready).
    func start() {
        guard !started, let app else { return }
        started = true

        notifications.onOpen = { [weak self] alert in self?.openHref(alert.href) }
        notifications.onOpenHref = { [weak self] href in self?.openHref(href) }
        notifications.onOpenCustomApp = { [weak self] slug in self?.app?.aux.focusCustomAppOrOpenInMain(slug: slug) }
        notifications.onShowLogs = { [weak self] in self?.showLogs() }
        notifications.onDecide = { [weak self] alert, decision in Task { await self?.decide(alert, decision) } }
        notifications.onReply = { [weak self] alert, text in Task { await self?.reply(alert, text) } }
        notifications.start()

        eventStream.onEvent = { [weak self] type in
            self?.inboxMonitor.handleServerEvent(type)
            self?.runMonitor.handleServerEvent(type)
        }
        eventStream.onServerEvent = { [weak self] event in self?.store.handle(event) }
        // The monitors call back after every refetch; skip unchanged answers so they don't redraw
        // the Dock tile, the menu-bar item and every window's rail.
        inboxMonitor.onBadgeChange = { [weak self] text, count in
            guard let self, text != dockBadge || count != badgeCount else { return }
            badgeCount = count
            dockBadge = text
            dock.setBadge(text)
            refreshTray()
        }
        inboxMonitor.onItems = { [weak self] items in
            guard let self, items != self.items else { return }
            self.items = items
            railInbox.items = items
            refreshTray()
        }
        inboxMonitor.onAlert = { [weak self] alert in self?.showAlert(alert) }
        runMonitor.onFinished = { [weak self] alert in self?.showAlert(alert) }
        runMonitor.onSnapshot = { [weak self] runs in
            guard let self, runs != liveRuns else { return }
            liveRuns = runs
            PowerLogic.prunePausedSet(&pausedByVesper, live: runs)
            power.update()
            refreshTray()
        }

        if let stack = app.stack {
            stack.onCrash = { [weak self] _, willRestart in
                guard let self, !willRestart, let stack = self.app?.stack else { return }
                self.notifications.notice(
                    title: stack.health.title, body: stack.health.nextStep ?? "Open Vesper to restart it.", target: .logs)
            }
        }

        power.start()
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        }

        track({ [weak app] in app?.connection }) { [weak self] connection in self?.connectionChanged(connection) }
        track({ [weak app] in app?.settings.settings }) { [weak self] _ in self?.applySettingsChanged() }
        track({ [weak app] in app?.stack?.health }) { [weak self] _ in
            self?.refreshTray()
            self?.refreshDockProgress()
        }
    }

    // MARK: Monitors

    private func connectionChanged(_ connection: Connection?) {
        guard connection != monitoredConnection else { return }
        monitoredConnection = connection
        eventStream.stop()
        inboxMonitor.stop()
        runMonitor.stop()
        nativeRail.stop()
        dock.stopPersonaRefresh()
        power.reset()
        BrowserShareToken.reset()
        items = []
        railInbox.items = []
        liveRuns = []
        badgeCount = 0
        dockBadge = ""
        dock.setBadge("")
        guard let connection else {
            client = nil
            store.setClient(nil)
            power.update()
            refreshTray()
            return
        }
        let client = APIClient(baseURL: connection.baseURL, sessionToken: connection.sessionToken)
        self.client = client
        store.setClient(client)
        eventStream.start(client: client)
        inboxMonitor.start(client: client)
        runMonitor.start(client: client)
        nativeRail.start()
        dock.startPersonaRefresh(client: client)
        power.applyThermal()
        refreshTray()
    }

    // MARK: Settings

    /// Re-applies tray, notifications, power and Dock settings. The Settings window calls this after
    /// a change; changes made any other way are picked up on their own.
    func applySettingsChanged() {
        guard started else { return }
        if settings.tray.enabled {
            menuBar.ensure()
            refreshTray()
        } else {
            menuBar.destroy()
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        }
        power.update()
        power.applyThermal()
        refreshDockProgress()
    }

    // MARK: Health, tray, Dock

    private var health: StackHealth {
        app?.stack?.health ?? StackHealth(phase: .running, title: "Vesper is running")
    }

    private func refreshTray() {
        guard menuBar.isActive else { return }
        let s = settings
        menuBar.render(
            TrayMenuInput(
                health: health, localStack: app?.stack != nil, items: items, runs: liveRuns,
                pausedByVesper: pausedByVesper.count,
                quickCapture: ShortcutSetting(enabled: s.quickCapture.enabled, shortcut: s.quickCapture.shortcut),
                screenshot: ShortcutSetting(enabled: s.screenshot.enabled, shortcut: s.screenshot.shortcut),
                notice: power.easingOffNotice),
            count: badgeCount, showCount: s.tray.showCount)
    }

    private func refreshDockProgress() {
        dock.setProgress(settings.dock.progress ? DockModel.dockProgress(health) : -1)
    }

    /// The Dock icon's right-click menu.
    func dockMenu() -> NSMenu? {
        guard settings.dock.menu else { return nil }
        return dock.menu(items: items) { [weak self] action in self?.perform(action) }
    }

    func perform(_ action: TrayAction) {
        guard let app else { return }
        switch action {
        case .open: showMainWindow()
        case .openHref(let href): openHref(href)
        case .quickCapture: app.actions.quickCapture()
        case .screenshot: app.actions.screenshotToChat()
        case .pauseRuns: Task { await pauseRuns(RunLogic.pausableRuns(liveRuns)) }
        case .resumeRuns: Task { await resumeRuns() }
        case .restartStack: app.actions.restartStack()
        case .showLogs: showLogs()
        case .preferences: app.actions.openSettings()
        case .quit:
            vlog("quit: chosen from the menu bar or Dock")
            NSApp.terminate(nil)
        }
    }

    // MARK: Windows

    /// Brings Vesper forward, opening a window when there is none.
    func showMainWindow() {
        guard let app else { return }
        restoreRegularPolicy()
        if let controller = vesperController() {
            if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            app.newWindow()
        }
        NSApp.activate()
    }

    /// Opens a Vesper page (a relative href from the server) in the current window, or a new one.
    func openHref(_ href: String) {
        guard let app, href.hasPrefix("/"), !href.hasPrefix("//") else { return }
        restoreRegularPolicy()
        if let controller = vesperController() {
            if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
            controller.send(.navigate(path: href))
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            app.openVesperTab(path: href, nextTo: nil)
        }
        NSApp.activate()
    }

    private func vesperController() -> MainWindowController? {
        guard let app else { return nil }
        if let key = app.keyController, key.kind == .vesper { return key }
        return app.windows.first { $0.kind == .vesper }
    }

    private func restoreRegularPolicy() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    private func windowBecameKey(_ window: NSWindow?) {
        guard let window, window.canBecomeMain, NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: Alerts

    private func showAlert(_ alert: DesktopAlert) {
        let policy = settings.notifications
        guard NotificationLogic.shouldShowAlert(alert, policy, now: Date()) else { return }
        notifications.show(alert, policy: policy)
    }

    /// Settings › Test notification.
    func sendTestNotification() {
        notifications.sendTest(silent: !settings.notifications.sound)
    }

    /// Custom App OS bridge notification (`os.notifications`); returns false in an unbundled debug binary.
    func sendCustomAppNotification(slug: String, title: String, subtitle: String?, body: String, silent: Bool) -> Bool {
        notifications.customAppNotice(
            slug: slug,
            title: title,
            subtitle: subtitle,
            body: body,
            silent: silent || !settings.notifications.sound
        )
    }

    private func decide(_ alert: DesktopAlert, _ decision: NotificationLogic.Decision) async {
        guard let call = NotificationLogic.decisionRequest(alert, decision) else { return openHref(alert.href) }
        if decision == .approve, let scope = NotificationLogic.touchIdScopeForKind(alert.kind) {
            guard await TouchID.confirm(settings.touchId, scope: scope) else {
                notifications.notice(title: "Not approved", body: "Touch ID wasn't confirmed. Open Vesper to decide.", target: .href(alert.href), silent: true)
                return
            }
        }
        let verb = decision == .approve ? "approve" : "decline"
        guard let client else {
            notifications.notice(title: "Couldn't \(verb)", body: "Open Vesper to decide.", target: .href(alert.href))
            return
        }
        do {
            try await client.send(call)
            await inboxMonitor.refreshNow()
        } catch {
            notifications.notice(title: "Couldn't \(verb)", body: Self.message(error, fallback: "Open Vesper to decide."), target: .href(alert.href))
        }
    }

    private func reply(_ alert: DesktopAlert, _ text: String) async {
        guard let call = NotificationLogic.replyRequest(alert, text) else { return openHref(alert.href) }
        do {
            guard let client else { throw APIError.unreachable }
            try await client.send(call)
        } catch {
            notifications.notice(title: "Reply not sent", body: Self.message(error, fallback: "Open Vesper to reply."), target: .href(alert.href))
        }
    }

    private static func message(_ error: Error, fallback: String) -> String {
        (error as? APIError)?.userMessage ?? fallback
    }

    // MARK: Runs: pause / resume

    private func pauseRuns(_ runs: [RunSummary]) async {
        guard let client else { return }
        await withTaskGroup(of: String?.self) { group in
            for run in runs {
                group.addTask { await Self.post(client, "/api/v1/runs/\(run.id)/pause", id: run.id) }
            }
            for await id in group { if let id { pausedByVesper.insert(id) } }
        }
        await runMonitor.refreshNow()
    }

    private func resumeRuns() async {
        guard let client else { return }
        await runMonitor.refreshNow()
        let ids = PowerLogic.runsToResume(pausedByVesper: pausedByVesper, live: liveRuns)
        await withTaskGroup(of: String?.self) { group in
            for id in ids {
                group.addTask { await Self.post(client, "/api/v1/runs/\(id)/resume", id: id) }
            }
            for await id in group { if let id { pausedByVesper.remove(id) } }
        }
        await runMonitor.refreshNow()
    }

    /// POSTs an empty body; the run id back on success.
    private nonisolated static func post(_ client: APIClient, _ path: String, id: String) async -> String? {
        do {
            try await client.send(APICall(path: path, body: [:]))
            return id
        } catch {
            return nil
        }
    }

    // MARK: Touch ID

    /// The page asked to confirm an approval (`confirmApproval`). true = go ahead.
    /// Fails closed: when Touch ID is on for the scope and the prompt fails or is cancelled, refuse.
    func confirmApproval(scope: ApprovalScope) async -> Bool {
        guard let app else { return false }
        return await TouchID.confirm(app.settings.settings.touchId, scope: TouchIdScope(rawValue: scope.rawValue))
    }

    /// Settings › Test Touch ID.
    func testTouchId() async -> Bool {
        guard TouchID.canPrompt() else { return false }
        return await TouchID.authenticate(reason: "test Touch ID for approvals")
    }

    // MARK: Workspace menu

    /// The page asked for the workspace folder menu (`openWorkspaceMenu`) at the mouse location.
    /// true when the person picked something and it opened.
    func showWorkspaceMenu(folder: String, in view: NSView) async -> Bool {
        guard let client, let dir = await WorkspaceMenu.allowedFolder(folder, client: client) else {
            vlog("workspace menu: folder refused")
            return false
        }
        let workspaces = settings.workspaces
        guard let target = await WorkspaceMenu().pick(settings: workspaces, in: view) else { return false }
        do {
            try await WorkspaceMenu.open(target, dir: dir, settings: workspaces)
            return true
        } catch let failure as WorkspaceOpenFailure {
            notifications.notice(title: "Couldn't open the folder", body: failure.message, silent: true)
        } catch {
            notifications.notice(title: "Couldn't open the folder", body: error.localizedDescription, silent: true)
        }
        return false
    }

    // MARK: Quit and last window

    /// Before quitting: false cancels the quit (e.g. runs are active and the person said no).
    func confirmQuit() async -> Bool {
        let active = runMonitor.latest.filter(RunLogic.isActive)
        guard PowerLogic.shouldConfirmQuit(settings.power, stackRunning: app?.stack?.isProcessRunning ?? false, hasActiveRuns: !active.isEmpty) else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Runs are still working."
        alert.informativeText = "Quitting Vesper stops the local stack and interrupts \(active.count == 1 ? "the run" : "\(active.count) runs")."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// `tray.onLastWindowClose`: whether closing the last window quits the app.
    func shouldTerminateAfterLastWindowClosed() -> Bool {
        let s = settings.tray
        switch TrayModel.lastWindowClosedAction(trayEnabled: s.enabled, policy: s.onLastWindowClose) {
        case .quit:
            return true
        case .hideDock:
            NSApp.setActivationPolicy(.accessory)
            return false
        case .stay:
            return false
        }
    }

    // MARK: Logs

    /// View › Show Logs… and the menu bar's Show Logs….
    func showLogs() {
        guard let app else { return }
        if logsWindow == nil {
            let stack = app.stack
            let url = stack?.logFileURL ?? app.dataDirectory.appendingPathComponent("logs/vesper-app.log")
            let dir = app.dataDirectory
            logsWindow = LogsWindowController(
                logURL: url,
                readTail: { stack?.recentLogTail() ?? StackHealthLogic.readLogTail(dir.appendingPathComponent("logs/vesper-app.log"), maxBytes: 256 * 1024) },
                restart: { [weak app] in app?.actions.restartStack() })
        }
        logsWindow?.present()
    }
}
