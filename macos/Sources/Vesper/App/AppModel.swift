import AppKit
import Observation
import VesperCore

/// A signed-in connection to the Vesper server the windows load pages from.
struct Connection: Equatable {
    var baseURL: URL
    var sessionToken: String
}

/// App-wide state: the stack, the connection, the open windows and the closed-tab stack.
@MainActor
@Observable
final class AppModel {
    let dataDirectory: URL
    /// nil in the dev bypass (VESPER_DEV_BASE_URL + VESPER_DEV_SESSION_TOKEN).
    private(set) var stack: StackController?
    /// nil until the stack is ready and signed in.
    private(set) var connection: Connection?

    @ObservationIgnored private(set) var windows: [MainWindowController] = []
    @ObservationIgnored private var closedTabs = ClosedTabStack()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cookieInstalledFor: Connection?
    @ObservationIgnored private var restoringSession = false
    @ObservationIgnored var playgroundPorts = defaultPlaygroundPorts
    /// Menu/tray/Dock actions; they forward to `system` and `aux`.
    @ObservationIgnored lazy var actions: AppActions = DefaultAppActions(app: self)
    /// Native settings (config.json "native"), shared by every subsystem.
    let settings: SettingsStore
    /// Menu bar, notifications, Dock, power, Touch ID, workspace menu, logs, quit policy.
    @ObservationIgnored lazy var system = SystemServices(app: self)
    /// Settings, Quick Capture, Screenshot, files in, Import Backup, backups, updates, login item.
    @ObservationIgnored lazy var aux = AuxWindows(app: self)

    var sessionFileURL: URL { SessionStore.fileURL(dataDirectory: dataDirectory) }

    init(dataDirectory: URL, stack: StackController?, devConnection: Connection?) {
        self.dataDirectory = dataDirectory
        self.settings = SettingsStore(dataDirectory: dataDirectory)
        self.stack = stack
        self.connection = devConnection
        AvatarImages.shared.connection = devConnection
        if let stack {
            track({ stack.session }, apply: { [weak self] session in
                self?.setConnection(session.map { Connection(baseURL: $0.baseURL, sessionToken: $0.sessionToken) })
            })
        }
    }

    // MARK: Connection

    private func setConnection(_ new: Connection?) {
        guard new != connection else { return }
        connection = new
        AvatarImages.shared.connection = new
        guard let new else { return }
        Task {
            await installCookieIfNeeded(new)
            for window in windows { window.connect(new) }
            if windows.isEmpty { restoreOrOpenFirstWindow() }
        }
    }

    func installCookieIfNeeded(_ conn: Connection) async {
        guard cookieInstalledFor != conn else { return }
        cookieInstalledFor = conn
        await WebViewFactory.installSessionCookie(baseURL: conn.baseURL, token: conn.sessionToken)
    }

    // MARK: Windows

    /// Login launch with "start in the menu bar": the first automatic window open is skipped; the
    /// menu bar item, the Dock and deep links still open windows.
    @ObservationIgnored var startHidden = false

    /// At launch: restore session.json tabs, or one window at "/".
    func restoreOrOpenFirstWindow() {
        guard windows.isEmpty else { return }
        if startHidden { return }
        let saved = SessionStore.load(from: sessionFileURL)
        restoringSession = true
        defer { restoringSession = false }
        var paths = saved.tabs.compactMap(restorablePath)
        if paths.isEmpty { paths = ["/"] }
        var first: MainWindowController?
        var created: [MainWindowController] = []
        for path in paths {
            let controller = makeVesperWindow(path: path)
            if let first {
                first.window?.addTabbedWindow(controller.window!, ordered: .above)
            } else {
                first = controller
                if let bounds = saved.bounds { controller.apply(bounds: bounds) }
            }
            created.append(controller)
        }
        let active = created.indices.contains(saved.activeIndex) ? saved.activeIndex : 0
        for (i, c) in created.enumerated() where i != active { c.window?.orderFront(nil) }
        created[active].showWindow(nil)
        created[active].window?.makeKeyAndOrderFront(nil)
        if let conn = connection { Task { await installCookieIfNeeded(conn); created.forEach { $0.connect(conn) } } }
    }

    /// A saved tab URL as a path on the current server (the port may differ from Electron's).
    private func restorablePath(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host else { return nil }
        if let base = connection?.baseURL {
            if classifyNavigation(raw, serverURL: base.absoluteString, playgroundPorts: playgroundPorts) == .playground { return nil }
            guard BridgeOrigin.normalizedHost(host) == BridgeOrigin.normalizedHost(base.host ?? "") else { return nil }
        } else if BridgeOrigin.normalizedHost(host) != "localhost" {
            return nil
        } else if playgroundPorts.contains(url.port ?? 80) {
            return nil
        }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        return path
    }

    @discardableResult
    func makeVesperWindow(path: String) -> MainWindowController {
        startHidden = false
        let controller = MainWindowController(app: self, kind: .vesper, path: path)
        register(controller)
        return controller
    }

    private func register(_ controller: MainWindowController) {
        windows.append(controller)
        if let conn = connection, !restoringSession { controller.connect(conn) }
        scheduleSessionSave()
    }

    /// Opens a Vesper page in a new tab next to `window`, or in a new window if there is none.
    func openVesperTab(path: String, nextTo window: NSWindow?) {
        let controller = makeVesperWindow(path: path)
        place(controller, nextTo: window)
    }

    func openPlayground(url: URL, nextTo window: NSWindow?) {
        let controller = MainWindowController(app: self, kind: .playground, path: url.absoluteString)
        register(controller)
        place(controller, nextTo: window)
    }

    private func place(_ controller: MainWindowController, nextTo window: NSWindow?) {
        guard let new = controller.window else { return }
        if let window = window ?? NSApp.keyWindow, window.tabbingIdentifier == new.tabbingIdentifier, window !== new {
            window.addTabbedWindow(new, ordered: .above)
        }
        controller.showWindow(nil)
        new.makeKeyAndOrderFront(nil)
    }

    func newWindow() {
        let controller = makeVesperWindow(path: "/")
        controller.window?.tabbingMode = .disallowed
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.tabbingMode = .preferred
    }

    func reopenClosedTab(nextTo window: NSWindow?) {
        guard let raw = closedTabs.pop(), let base = connection?.baseURL else { return }
        switch classifyNavigation(raw, serverURL: base.absoluteString, playgroundPorts: playgroundPorts) {
        case .vesper:
            if let url = URL(string: raw) {
                var path = url.path.isEmpty ? "/" : url.path
                if let q = url.query { path += "?" + q }
                openVesperTab(path: path, nextTo: window)
            }
        case .playground:
            if let url = URL(string: raw) { openPlayground(url: url, nextTo: window) }
        default: break
        }
    }

    var keyController: MainWindowController? {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? MainWindowController
            ?? windows.first
    }

    func windowClosed(_ controller: MainWindowController, url: String?) {
        windows.removeAll { $0 === controller }
        if let url { closedTabs.push(url) }
        scheduleSessionSave()
    }

    var canReopenClosedTab: Bool { closedTabs.size > 0 }

    // MARK: Session

    func scheduleSessionSave() {
        guard !restoringSession else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveSessionNow()
        }
    }

    func saveSessionNow() {
        saveTask?.cancel()
        let ref = (NSApp.keyWindow?.windowController as? MainWindowController) ?? windows.first
        guard let refWindow = ref?.window else { return }
        let group = (refWindow.tabbedWindows ?? [refWindow]).compactMap { $0.windowController as? MainWindowController }
        let tabs = group.filter { $0.kind == .vesper }
        let pairs = tabs.compactMap { c in c.currentURLString.map { (c, $0) } }
        let urls = pairs.map(\.1)
        guard !urls.isEmpty else { return }
        let activeIdx = pairs.firstIndex { $0.0 === ref } ?? 0
        let state = SessionState(tabs: urls, activeIndex: min(activeIdx, urls.count - 1), bounds: ref?.currentBounds())
        do { try SessionStore.save(state, to: sessionFileURL) } catch { vlog("session save failed: \(error)") }
    }
}
