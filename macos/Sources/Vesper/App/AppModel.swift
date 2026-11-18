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
    /// The layout windows are built in right now (the setting, once applied).
    @ObservationIgnored private(set) var compactLayout = false
    @ObservationIgnored private weak var lastKey: MainWindowController?
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
        compactLayout = settings.settings.tabs.layout == .compact
        track({ [weak self] in self?.settings.settings.tabs.layout }) { [weak self] layout in
            if let layout { self?.applyLayout(layout) }
        }
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
        let active = paths.indices.contains(saved.activeIndex) ? saved.activeIndex : 0
        let tabs = paths.map { makeTab(kind: .vesper, path: $0) }
        var created: [MainWindowController]
        if compactLayout {
            created = [makeWindow(tabs: tabs, active: active)]
        } else {
            created = tabs.map { makeWindow(tabs: [$0]) }
            for (prev, c) in zip(created, created.dropFirst()) { prev.window?.addTabbedWindow(c.window!, ordered: .above) }
        }
        if let bounds = saved.bounds { created[0].apply(bounds: bounds) }
        let front = compactLayout ? created[0] : created[active]
        for c in created where c !== front { c.window?.orderFront(nil) }
        front.showWindow(nil)
        front.window?.makeKeyAndOrderFront(nil)
        if let conn = connection { Task { await installCookieIfNeeded(conn); tabs.forEach { $0.connect(conn) } } }
        Task { @MainActor [weak self] in self?.debugOpenTabs() }
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

    /// A tab with its own page, state and bridge, not yet in any window.
    func makeTab(kind: WindowKind, path: String) -> WebContentController {
        startHidden = false
        let tab = WebContentController(app: self, kind: kind, state: ShellState(), path: path)
        tab.bridge?.onRouteChange = { [weak self] in self?.scheduleSessionSave() }
        if let conn = connection, !restoringSession { tab.connect(conn) }
        return tab
    }

    @discardableResult
    func makeWindow(tabs: [WebContentController], active: Int = 0) -> MainWindowController {
        let controller = MainWindowController(app: self, compact: compactLayout, tabs: tabs, activeIndex: active)
        windows.append(controller)
        scheduleSessionSave()
        return controller
    }

    /// Opens a Vesper page in a new tab next to `window`, or in a new window if there is none.
    func openVesperTab(path: String, nextTo window: NSWindow?) {
        place(makeTab(kind: .vesper, path: path), nextTo: window)
    }

    func openPlayground(url: URL, nextTo window: NSWindow?) {
        place(makeTab(kind: .playground, path: url.absoluteString), nextTo: window)
    }

    /// The window a new tab joins in the compact layout: the one it was opened from, else the key one.
    private func compactTarget(nextTo window: NSWindow?) -> MainWindowController? {
        if let c = window?.windowController as? MainWindowController, c.compact, !c.retired { return c }
        if let c = NSApp.keyWindow?.windowController as? MainWindowController, c.compact, !c.retired { return c }
        return windows.last { $0.compact && !$0.retired }
    }

    private func place(_ tab: WebContentController, nextTo window: NSWindow?) {
        if compactLayout {
            if let target = compactTarget(nextTo: window) {
                target.addTab(tab)
                target.showWindow(nil)
                target.window?.makeKeyAndOrderFront(nil)
            } else {
                let controller = makeWindow(tabs: [tab])
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
            }
            return
        }
        let controller = makeWindow(tabs: [tab])
        if let new = controller.window, let window = window ?? NSApp.keyWindow,
           window.tabbingIdentifier == new.tabbingIdentifier, window !== new {
            window.addTabbedWindow(new, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func newWindow() {
        let controller = makeWindow(tabs: [makeTab(kind: .vesper, path: "/")])
        if compactLayout {
            if let key = NSApp.keyWindow, key.windowController is MainWindowController, let window = controller.window {
                window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 28, y: key.frame.maxY - 28))
            }
        } else {
            controller.window?.tabbingMode = .disallowed
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if !compactLayout { controller.window?.tabbingMode = .preferred }
    }

    func duplicateTab(_ tab: WebContentController, in host: MainWindowController) {
        guard let copy = makeCopy(of: tab),
              let index = host.tabs.list.items.firstIndex(where: { $0 === tab }) else { return }
        host.addTab(copy, at: index + 1)
    }

    /// A fresh tab at `tab`'s page: its Vesper path with the query, or its playground URL.
    /// Nil for a playground that never loaded.
    private func makeCopy(of tab: WebContentController) -> WebContentController? {
        switch tab.kind {
        case .vesper: return makeTab(kind: .vesper, path: tab.pendingPath)
        case .playground:
            guard let url = tab.currentURLString else { return nil }
            return makeTab(kind: .playground, path: url)
        }
    }

    /// Compact layout: the tab, page and all, becomes its own window.
    func moveTabToNewWindow(_ tab: WebContentController, from host: MainWindowController) {
        guard host.compact, host.tabs.list.count > 1, host.detachTab(tab) != nil else { return }
        let controller = makeWindow(tabs: [tab])
        if let from = host.window, let window = controller.window {
            window.setFrame(from.frame.offsetBy(dx: 28, dy: -28), display: false)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Compact layout: every other window's tabs join this window, in order.
    func mergeAllWindows(into target: MainWindowController) {
        guard target.compact else { return }
        for other in windows where other !== target && other.compact && !other.retired {
            for tab in other.detachAllTabs() { target.addTab(tab, at: target.tabs.list.count, select: false) }
            other.retire()
        }
        target.window?.makeKeyAndOrderFront(nil)
    }

    var compactWindowCount: Int { windows.filter { $0.compact && !$0.retired }.count }

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

    func windowClosed(_ controller: MainWindowController) {
        windows.removeAll { $0 === controller }
        scheduleSessionSave()
    }

    func recordClosed(url: String?) {
        if let url { closedTabs.push(url) }
        scheduleSessionSave()
    }

    func noteKey(_ controller: MainWindowController) {
        lastKey = controller
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
        guard let refWindow = ref?.window, let ref else { return }
        let urls: [String?]
        let active: Int
        if ref.compact {
            let tabs = ref.tabs.list.items
            urls = tabs.map { $0.kind == .vesper ? $0.currentURLString : nil }
            active = ref.tabs.list.activeIndex
        } else {
            let group = (refWindow.tabbedWindows ?? [refWindow]).compactMap { $0.windowController as? MainWindowController }
            urls = group.map { $0.kind == .vesper ? $0.currentURLString : nil }
            active = group.firstIndex { $0 === ref } ?? 0
        }
        guard let state = sessionState(urls: urls, activeIndex: active, bounds: ref.currentBounds()) else { return }
        do { try SessionStore.save(state, to: sessionFileURL) } catch { vlog("session save failed: \(error)") }
    }

    // MARK: Layout

    /// Rebuilds the open windows in the other tab layout. The tabs themselves (pages, history,
    /// sidebar models) move to the new windows as they are, so nothing reloads; order, active tab and
    /// window frames carry over.
    private func applyLayout(_ layout: TabLayout) {
        let compact = layout == .compact
        guard compact != compactLayout else { return }
        compactLayout = compact
        let old = windows.filter { !$0.retired }
        vlog("tab layout -> \(layout.rawValue), \(old.count) window(s)")
        guard !old.isEmpty else { return }

        struct Group {
            var tabs: [WebContentController]
            var active: Int
            var frame: NSRect
            var isLast: Bool
        }
        var groups: [Group] = []
        let last = lastKey.flatMap { old.contains($0) ? $0 : nil } ?? old.last
        if compact {
            var seen = Set<ObjectIdentifier>()
            for w in old where !seen.contains(ObjectIdentifier(w)) {
                guard let window = w.window else { continue }
                let members = (window.tabbedWindows ?? [window]).compactMap { $0.windowController as? MainWindowController }
                members.forEach { seen.insert(ObjectIdentifier($0)) }
                let selected = window.tabGroup?.selectedWindow?.windowController as? MainWindowController ?? w
                groups.append(Group(tabs: members.map(\.content), active: members.firstIndex { $0 === selected } ?? 0,
                                    frame: selected.window?.frame ?? window.frame, isLast: members.contains { $0 === last }))
            }
        } else {
            for w in old {
                guard let window = w.window else { continue }
                groups.append(Group(tabs: w.tabs.list.items, active: w.tabs.list.activeIndex, frame: window.frame, isLast: w === last))
            }
        }
        groups.sort { !$0.isLast && $1.isLast }

        restoringSession = true
        defer { restoringSession = false; scheduleSessionSave() }
        old.forEach { _ = $0.detachAllTabs() }
        var shown: [(front: MainWindowController, all: [MainWindowController])] = []
        for g in groups {
            if compact {
                let c = makeWindow(tabs: g.tabs, active: g.active)
                c.window?.setFrame(g.frame, display: false)
                shown.append((c, [c]))
            } else {
                let cs = g.tabs.map { makeWindow(tabs: [$0]) }
                for c in cs { c.window?.setFrame(g.frame, display: false) }
                for (prev, c) in zip(cs, cs.dropFirst()) { prev.window?.addTabbedWindow(c.window!, ordered: .above) }
                shown.append((cs[min(g.active, cs.count - 1)], cs))
            }
        }
        let keyWasMain = NSApp.keyWindow?.windowController is MainWindowController
        for (i, entry) in shown.enumerated() {
            for c in entry.all where c !== entry.front { c.window?.orderFront(nil) }
            entry.front.showWindow(nil)
            if i == shown.count - 1 && keyWasMain { entry.front.window?.makeKeyAndOrderFront(nil) } else { entry.front.window?.orderFront(nil) }
        }
        old.forEach { $0.retire() }
    }

    // MARK: Debugging

    /// Debug only (VESPER_DEBUG=1): VESPER_DEBUG_OPEN_TABS=/a,/b opens those tabs once the first window is up;
    /// VESPER_DEBUG_LAYOUT_AFTER=<seconds> flips the tab layout setting after that long.
    private func debugOpenTabs() {
        guard debugLoggingEnabled else { return }
        let env = ProcessInfo.processInfo.environment
        if let list = env["VESPER_DEBUG_OPEN_TABS"] {
            for path in list.split(separator: ",") { openVesperTab(path: String(path), nextTo: nil) }
        }
        if let secs = env["VESPER_DEBUG_LAYOUT_AFTER"].flatMap(Double.init) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(secs))
                self?.aux.update { $0.tabs.layout = $0.tabs.layout == .compact ? .separate : .compact }
            }
        }
    }
}
