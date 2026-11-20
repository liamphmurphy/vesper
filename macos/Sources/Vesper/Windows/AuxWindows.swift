import AppKit
import LocalAuthentication
import Observation
import ServiceManagement
import VesperCore

/// What Settings shows about things that happen outside it (shortcut registration, login item,
/// Time Machine, exports, updates, Quick Actions).
@MainActor
@Observable
final class AuxState {
    var shortcutErrors: [GlobalShortcuts.Kind: String] = [:]
    var loginMessage: String?
    var timeMachineExcluded: Bool?
    var lastExportAt: Date?
    var lastExportError: String?
    var exporting = false
    var backupEncryption: BackupEncryptionStatus?
    var backupEncryptionLoading = false
    var backupEncryptionError: String?
    var servicesInstalled = false
    var lastUpdateCheckAt: Date?
    var checkingForUpdates = false
}

/// The app's auxiliary windows and flows: Settings, Quick Capture, Screenshot to Chat, files in
/// (Dock/window drop, Open With, Quick Actions) and the send picker, Import Backup, scheduled
/// backups and Time Machine, the update check and open-at-login. One per app (`AppModel.aux`).
/// See docs/dev/native-mac-app.md.
@MainActor
final class AuxWindows {
    private(set) weak var app: AppModel?
    let state = AuxState()
    let options = CaptureOptionsStore()
    let shortcuts = GlobalShortcuts()

    private(set) lazy var capture = QuickCaptureController(aux: self)
    private(set) lazy var screenshot = ScreenshotToChat(aux: self)
    private(set) lazy var files = FilesIn(aux: self)
    private(set) lazy var importer = ImportBackupFlow(aux: self)
    private(set) lazy var settingsWindow = SettingsWindowController(aux: self)
    private(set) lazy var shortcutsWindow = ShortcutsWindowController()
    private(set) lazy var commandPalette = CommandPaletteController(aux: self)
    private(set) lazy var quickLook = QuickLookController(aux: self)

    private var launchedAtLoginFlag = false
    private var exportTimer: Timer?
    private var updateTimer: Timer?
    private var started = false

    init(app: AppModel) {
        self.app = app
    }

    /// True in a scratch run (VESPER_USER_DATA_DIR set): nothing here may reach the real Keychain,
    /// ~/Library/Services or login items.
    static var isScratchRun: Bool {
        !(ProcessInfo.processInfo.environment["VESPER_USER_DATA_DIR"] ?? "").isEmpty
    }

    // MARK: Lifecycle

    /// Called once after launch (before the stack is ready).
    func start() {
        guard !started else { return }
        started = true
        launchedAtLoginFlag = Self.detectLaunchedAtLogin()
        options.clientProvider = { [weak self] in self?.client() }
        shortcuts.setHandler(.quickCapture) { [weak self] in self?.quickCapture() }
        shortcuts.setHandler(.screenshot) { [weak self] in self?.screenshotToChat() }
        shortcuts.setHandler(.showHide) { [weak self] in self?.toggleVesper() }
        let state = self.state
        state.servicesInstalled = QuickActions.isInstalled(in: QuickActions.servicesDirectory())
        let saved = AppStateFile.read(dataDirectory: dataDirectory)
        state.lastExportAt = AppStateFile.millis(saved, "lastExportAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        state.lastExportError = saved["lastExportError"] as? String
        state.lastUpdateCheckAt = AppStateFile.millis(saved, "lastUpdateCheckAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        applyShortcuts()
        applyLoginItem()
        options.start()
        Task { await applyTimeMachine() }
        scheduleExport(after: 60)
        scheduleUpdateCheck(after: 10)
        debugOpenWindows()
    }

    private var dataDirectory: URL { app?.dataDirectory ?? StackController.defaultDataDirectory() }
    private var settings: NativeSettings { app?.settings.settings ?? NativeSettings() }

    /// An API client for the signed-in connection, or nil while the stack is starting.
    func client() -> APIClient? {
        app?.connection.map { APIClient(baseURL: $0.baseURL, sessionToken: $0.sessionToken) }
    }

    /// Waits (up to a minute) for the stack to be ready and signed in.
    func whenConnected() async {
        for _ in 0..<120 where client() == nil { try? await Task.sleep(for: .milliseconds(500)) }
    }

    /// Opens a Vesper page (a path like /chat/<id>) in a window and brings the app forward.
    func openHref(_ path: String) {
        NSApp.activate()
        app?.openVesperTab(path: path, nextTo: NSApp.keyWindow)
    }

    // MARK: Entry points the menus, Dock and deep links call

    func quickCapture() { capture.show() }
    func screenshotToChat() { screenshot.start() }
    func importBackup() { importer.start() }
    func openSettings() { settingsWindow.show() }
    func showShortcuts() { shortcutsWindow.show() }
    func openCommandPalette(request: CommandPaletteRequest? = nil, from window: MainWindowController? = nil) {
        commandPalette.open(request: request, from: window)
    }
    func closeCommandPalette() { commandPalette.close(restoreFocus: true) }
    func previewQuickLook(items: [QuickLookItem], index: Int?, from window: NSWindow?) {
        quickLook.preview(items: items, index: index, from: window)
    }
    func cleanupQuickLook() { quickLook.cleanup() }
    func checkForUpdates() { Task { await runUpdateCheck(manual: true) } }

    /// Files opened with the app (Open With, Dock drop, Quick Actions) or dropped on a window.
    func openFiles(_ urls: [URL]) { files.open(urls) }

    // MARK: Login item

    /// True when macOS launched the app because it is a login item (the launch Apple event carries
    /// `keyAELaunchedAsLogInItem`). Captured in `start()`; call after that.
    func launchedAtLogin() -> Bool { launchedAtLoginFlag }

    /// The AppDelegate asks this before opening the first window: a login launch with "start in the
    /// menu bar" on, and the menu bar icon enabled, opens no window.
    func shouldStartHidden() -> Bool {
        Login.shouldStartHidden(settings.login, trayEnabled: settings.tray.enabled, launchedAtLogin: launchedAtLoginFlag)
    }

    private static func detectLaunchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let keyAEPropData: AEKeyword = 0x70726474 // 'prdt'
        let launchedAsLoginItem: UInt32 = 0x6C676974 // 'lgit'
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == launchedAsLoginItem
    }

    /// SMAppService only works for a packaged app, and a scratch/test launch must never register one.
    private var loginItemAllowed: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && !Self.isScratchRun
            || ProcessInfo.processInfo.environment["VESPER_FORCE_LOGIN_ITEM"] == "1"
    }

    func applyLoginItem() {
        let wanted = settings.login.openAtLogin
        guard loginItemAllowed else {
            state.loginMessage = wanted ? "Open at login works from the packaged Vesper.app." : nil
            return
        }
        let service = SMAppService.mainApp
        do {
            if wanted, service.status != .enabled { try service.register() }
            if !wanted, service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
        } catch {
            vlog("login item: \(error)")
        }
        let status: LoginItemStatus
        switch service.status {
        case .enabled: status = .enabled
        case .notRegistered: status = .notRegistered
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        @unknown default: status = .unknown
        }
        state.loginMessage = Login.statusMessage(wanted: wanted, status: status)
    }

    // MARK: Shortcuts

    func applyShortcuts() {
        state.shortcutErrors = shortcuts.apply(settings)
    }

    /// Show/Hide: bring Vesper forward from another app, or hide it when it's already in front.
    func toggleVesper() {
        if NSApp.isActive, !NSApp.isHidden, app?.windows.contains(where: { $0.window?.isVisible == true }) == true {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate()
        if let visible = app?.windows.first(where: { $0.window?.isVisible == true })?.window {
            visible.makeKeyAndOrderFront(nil)
        } else {
            app?.newWindow()
        }
    }

    // MARK: Settings changes

    /// Edits settings in place (validated and saved by the store), then re-applies whatever changed.
    func update(_ edit: (inout NativeSettings) -> Void) {
        guard let store = app?.settings else { return }
        let before = store.settings
        let after = store.update(edit)
        settingsChanged(from: before, to: after)
    }

    private func settingsChanged(from before: NativeSettings, to after: NativeSettings) {
        if before.quickCapture != after.quickCapture || before.screenshot != after.screenshot || before.showHide != after.showHide { applyShortcuts() }
        if before.login != after.login { applyLoginItem() }
        if before.backups.excludeFromTimeMachine != after.backups.excludeFromTimeMachine { Task { await applyTimeMachine() } }
        if before.backups.export != after.backups.export { scheduleExport(after: 5) }
        if !before.updates.checkEnabled && after.updates.checkEnabled { scheduleUpdateCheck(after: 1) }
        if before.stack != after.stack { app?.stack?.apply(after.stack) }
        app?.system.applySettingsChanged()
    }

    // MARK: Quick Actions

    /// Installs or removes "Send to Vesper" / "Send Text to Vesper". Only the person flipping the
    /// setting calls this; it needs the packaged app (the workflows run `open -a <Vesper.app>`).
    func setQuickActions(installed: Bool) -> String? {
        guard let bundle = QuickActions.appBundlePath(executablePath: Bundle.main.executablePath ?? ""), !Self.isScratchRun else {
            return "Quick Actions need the packaged Vesper.app."
        }
        do {
            if installed { try QuickActions.install(appPath: bundle, into: QuickActions.servicesDirectory()) }
            else { QuickActions.uninstall(from: QuickActions.servicesDirectory()) }
            state.servicesInstalled = QuickActions.isInstalled(in: QuickActions.servicesDirectory())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var quickActionsAvailable: Bool {
        QuickActions.appBundlePath(executablePath: Bundle.main.executablePath ?? "") != nil && !Self.isScratchRun
    }

    // MARK: Backups

    func applyTimeMachine() async {
        let exclude = settings.backups.excludeFromTimeMachine
        vlog("time machine: applying exclude=\(exclude)")
        state.timeMachineExcluded = await TimeMachine.apply(dataDirectory: dataDirectory, exclude: exclude)
        vlog("time machine: excluded=\(String(describing: state.timeMachineExcluded))")
    }

    private func scheduleExport(after seconds: TimeInterval) {
        exportTimer?.invalidate()
        exportTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.exportIfDue()
                self?.scheduleExport(after: 30 * 60)
            }
        }
    }

    private func exportIfDue() async {
        let exp = settings.backups.export
        guard exp.enabled, !exp.folder.isEmpty, client() != nil else { return }
        let last = state.lastExportAt.map { $0.timeIntervalSince1970 * 1000 }
        guard Backups.isExportDue(lastAt: last, now: Date().timeIntervalSince1970 * 1000, everyHours: exp.everyHours) else { return }
        _ = await exportNow()
    }

    /// Writes an export to the backup folder now. Returns the file, or the reason it failed.
    @discardableResult
    func exportNow() async -> Result<URL, BackupImportError> {
        let exp = settings.backups.export
        guard !exp.folder.isEmpty else { return .failure(BackupImportError("Choose a folder first.")) }
        guard !state.exporting else { return .failure(BackupImportError("An export is already running.")) }
        guard let client = client() else { return .failure(BackupImportError("Vesper isn't ready yet.")) }
        state.exporting = true
        defer { state.exporting = false }
        do {
            let file = try await BackupExporter.export(client: client, folder: exp.folder, keep: exp.keep)
            let now = Date()
            state.lastExportAt = now
            state.lastExportError = nil
            AppStateFile.update(dataDirectory: dataDirectory) {
                $0["lastExportAt"] = now.timeIntervalSince1970 * 1000
                $0.removeValue(forKey: "lastExportError")
            }
            return .success(file)
        } catch {
            let message = String(error.localizedDescription.prefix(300))
            state.lastExportError = message
            AppStateFile.update(dataDirectory: dataDirectory) { $0["lastExportError"] = message }
            return .failure(BackupImportError(message))
        }
    }

    func refreshBackupEncryption() async {
        guard let client = client() else {
            state.backupEncryption = nil
            state.backupEncryptionError = nil
            return
        }
        state.backupEncryptionLoading = true
        defer { state.backupEncryptionLoading = false }
        do {
            state.backupEncryption = try await BackupEncryptionAPI.status(client: client)
            state.backupEncryptionError = nil
        } catch let e as APIError {
            state.backupEncryptionError = e.userMessage
        } catch {
            state.backupEncryptionError = error.localizedDescription
        }
    }

    func setBackupEncryption(password: String) async -> String? {
        guard let client = client() else { return "Vesper isn't ready yet." }
        do {
            state.backupEncryption = try await BackupEncryptionAPI.setPassword(client: client, password: password)
            state.backupEncryptionError = nil
            return nil
        } catch let e as APIError {
            return e.userMessage
        } catch {
            return error.localizedDescription
        }
    }

    func clearBackupEncryption() async -> String? {
        guard let client = client() else { return "Vesper isn't ready yet." }
        do {
            try await BackupEncryptionAPI.clearPassword(client: client)
            state.backupEncryption = BackupEncryptionStatus(
                enabled: false,
                keyConfigured: state.backupEncryption?.keyConfigured ?? true,
                updatedAt: nil
            )
            state.backupEncryptionError = nil
            return nil
        } catch let e as APIError {
            return e.userMessage
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Updates

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private func scheduleUpdateCheck(after seconds: TimeInterval) {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.runUpdateCheck(manual: false)
                self?.scheduleUpdateCheck(after: 6 * 60 * 60)
            }
        }
    }

    /// Opt-in daily check (`manual: false`), or "Check for Updates…" (always runs and always answers).
    func runUpdateCheck(manual: Bool) async {
        if !manual {
            guard settings.updates.checkEnabled else { return }
            let last = state.lastUpdateCheckAt.map { $0.timeIntervalSince1970 * 1000 }
            guard Updates.isCheckDue(lastCheckedAt: last, now: Date().timeIntervalSince1970 * 1000) else { return }
        }
        guard !state.checkingForUpdates else { return }
        state.checkingForUpdates = true
        defer { state.checkingForUpdates = false }
        let current = Self.currentVersion
        do {
            let info = try await UpdateCheck.fetch(feedURL: settings.updates.feedUrl, currentVersion: current)
            let now = Date()
            state.lastUpdateCheckAt = now
            AppStateFile.update(dataDirectory: dataDirectory) { $0["lastUpdateCheckAt"] = now.timeIntervalSince1970 * 1000 }
            if let info {
                if manual || notifiedVersion != info.version { announce(info) }
                AppStateFile.update(dataDirectory: dataDirectory) { $0["lastNotifiedUpdateVersion"] = info.version }
            } else if manual {
                alert("You're up to date", current == "dev" ? "This is a development build." : "Vesper \(current) is the newest version.")
            }
        } catch {
            if manual { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private var notifiedVersion: String? { AppStateFile.read(dataDirectory: dataDirectory)["lastNotifiedUpdateVersion"] as? String }

    private func announce(_ info: UpdateInfo) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Vesper \(info.version) is available"
        alert.informativeText = "\(info.name). Download the new DMG and drag Vesper.app into Applications, replacing the old one. Your data stays in place and is upgraded on the next launch."
        alert.addButton(withTitle: "Open Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: info.url) { NSWorkspace.shared.open(url) }
    }

    private func alert(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: Settings window helpers

    /// Whether any run is queued, starting, running or paused (GET /api/v1/runs?state=live).
    func hasActiveRuns() async -> Bool {
        guard let client = client(),
              let data = try? await client.request("GET", "/api/v1/runs?state=live"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return !((object["runs"] as? [Any]) ?? []).isEmpty
    }

    /// Records a shortcut picked in the recorder: validated first (well formed, not a system
    /// shortcut), then saved; registration problems (already in use) land in `state.shortcutErrors`.
    func setShortcut(_ kind: GlobalShortcuts.Kind, accelerator: String) {
        switch GlobalShortcuts.check(accelerator) {
        case .failure(let e):
            state.shortcutErrors[kind] = e.message
        case .success(let valid):
            state.shortcutErrors[kind] = nil
            update { s in
                switch kind {
                case .quickCapture: s.quickCapture.shortcut = valid
                case .screenshot: s.screenshot.shortcut = valid
                case .showHide: s.showHide.shortcut = valid
                }
            }
        }
    }

    func sendTestNotification() -> String? {
        app?.system.sendTestNotification()
        return nil
    }

    /// Prompts for Touch ID; nil on success, else why not.
    func testTouchId() async -> String? {
        guard let system = app?.system else { return "Vesper isn't ready." }
        return await system.testTouchId() ? nil : (touchIdAvailable ? "Touch ID wasn't confirmed." : "Touch ID isn't available on this Mac.")
    }

    var touchIdAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    // MARK: Debug

    /// VESPER_DEBUG=1 only: VESPER_DEBUG_OPEN=settings:<section>,capture,send:<path>,… opens windows
    /// at launch so they can be screenshotted without driving the UI.
    private func debugOpenWindows() {
        let env = ProcessInfo.processInfo.environment
        guard debugLoggingEnabled, let spec = env["VESPER_DEBUG_OPEN"] else { return }
        for item in spec.split(separator: ",") {
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            Task {
                try? await Task.sleep(for: .seconds(2))
                switch parts[0] {
                case "settings": settingsWindow.show(section: parts.count > 1 ? parts[1] : nil)
                case "capture":
                    capture.show(prefill: env["VESPER_DEBUG_CAPTURE_TEXT"], autoSave: env["VESPER_DEBUG_CAPTURE_SAVE"] == "1")
                case "send":
                    files.offer(parts.count > 1 ? parts[1].split(separator: "|").map(String.init) : [])
                    if env["VESPER_DEBUG_SEND_SUBMIT"] == "1" {
                        try? await Task.sleep(for: .seconds(3))
                        files.picker.debugSubmit()
                    }
                case "import":
                    if let app, let stack = app.stack, let res = BundledResources.locate().flatMap({ BundledResources.resolve(baseDir: $0) }), parts.count > 1 {
                        importer.present(archive: URL(fileURLWithPath: parts[1]), resources: res, stack: stack, aux: self, app: app)
                        if env["VESPER_DEBUG_IMPORT_RUN"] == "1" { importer.debugRun() }
                    }
                case "update": checkForUpdates()
                default: break
                }
            }
        }
    }
}
