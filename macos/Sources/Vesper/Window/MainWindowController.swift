import AppKit
import SwiftUI
import VesperCore
import WebKit

/// A window: Mail-style split view (native sidebar + web content) and unified toolbar. In the
/// separate layout it holds one tab (and the system groups windows into tabs); in the compact
/// layout it holds several tabs, drawn in its toolbar, and shows the active one.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingIdentifier = "vesper"
    static let defaultSize = NSSize(width: 1280, height: 840)
    static let minSize = NSSize(width: 760, height: 540)

    let app: AppModel
    /// Compact layout: several tabs in this window, drawn by us in the toolbar.
    let compact: Bool
    let tabs = TabsModel()
    let split = NSSplitViewController()
    private let container = TabContainerController()
    private var sidebarItem: NSSplitViewItem?
    private var toolbarController: ToolbarController?
    private var lastContent: WebContentController
    /// Set when the layout switch emptied and closed this window.
    private(set) var retired = false

    /// The active tab. Everything that used to be "the window's page" goes through it.
    var content: WebContentController { tabs.list.active ?? lastContent }
    var state: ShellState { content.state }
    var kind: WindowKind { content.kind }
    var hasSidebar: Bool { sidebarItem != nil }
    var currentURLString: String? { content.currentURLString }

    /// ⌥⌘F: the toolbar's search field, which opens the page's command palette.
    func focusSearch() {
        toolbarController?.focusSearch()
    }

    init(app: AppModel, compact: Bool, tabs initial: [WebContentController], activeIndex: Int = 0) {
        precondition(!initial.isEmpty)
        self.app = app
        self.compact = compact
        self.lastContent = initial[min(max(activeIndex, 0), initial.count - 1)]
        let firstKind = initial[0].kind

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = Self.minSize
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = compact ? .disallowed : .preferred
        window.toolbarStyle = .unified
        window.title = firstKind == .vesper ? "Vesper" : "Playground"
        if compact { window.titleVisibility = .hidden }
        super.init(window: window)
        window.delegate = self

        if compact || firstKind == .vesper {
            let sidebar = NSHostingController(rootView: SidebarHost(tabs: tabs, send: { [weak self] in self?.send($0) }))
            sidebar.sizingOptions = []
            let item = NSSplitViewItem(sidebarWithViewController: sidebar)
            item.minimumThickness = 220
            item.maximumThickness = 400
            item.canCollapse = true
            split.addSplitViewItem(item)
            sidebarItem = item
        }
        split.addSplitViewItem(NSSplitViewItem(viewController: container))
        container.installRail(
            tabs: tabs, send: { [weak self] in self?.send($0) },
            services: { [weak app] in app?.system })
        window.contentViewController = split
        window.setContentSize(Self.defaultSize)
        window.center()

        for tab in initial {
            tab.host = self
            tabs.list.insert(tab, select: false)
        }
        tabs.list.select(activeIndex)
        container.show(content)

        if compact || firstKind == .vesper {
            toolbarController = ToolbarController(owner: self)
            window.toolbar = toolbarController?.toolbar
            track({ [weak self] in self?.state.pageMode }) { [weak self] mode in self?.applyPageMode(mode) }
            track({ [weak self] in (self?.content.displayTitle, self?.state.subtitle) }) { [weak self] title, subtitle in
                guard let self, let title else { return }
                self.window?.title = title
                self.window?.subtitle = self.compact ? "" : (subtitle ?? "")
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Commands

    func send(_ command: NativeCommand) {
        if case .navigate(let path) = command {
            content.navigate(path: path)
        } else {
            content.bridge?.send(command)
        }
    }

    /// Match the window to the page's effective mode, so a person who forces Dark in Vesper while macOS is
    /// Light gets a consistent window. When they agree the window follows the system (no override).
    private func applyPageMode(_ mode: ColorMode?) {
        guard let window else { return }
        guard let mode, mode != AppearanceMonitor.current().mode else { window.appearance = nil; return }
        window.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    }

    func connect(_ conn: Connection) { tabs.list.items.forEach { $0.connect(conn) } }

    /// A tab's document title changed; the window title follows the active tab.
    func tabTitleChanged(_ tab: WebContentController) {
        guard tab === content, tab.state.title == nil else { return }
        window?.title = tab.displayTitle
    }

    var webView: WKWebView { content.webView }

    // MARK: Bounds (session.json stores top-left-origin screen coordinates, as Electron did)

    func currentBounds() -> WindowBounds? {
        guard let window, let screen = NSScreen.screens.first else { return nil }
        let f = window.frame
        return WindowBounds(x: Int(f.minX.rounded()), y: Int((screen.frame.maxY - f.maxY).rounded()),
                            width: Int(f.width.rounded()), height: Int(f.height.rounded()), isMaximized: window.isZoomed)
    }

    func apply(bounds: WindowBounds) {
        guard let window, let screen = NSScreen.screens.first else { return }
        var frame = NSRect(x: 0, y: 0, width: max(bounds.width, Int(Self.minSize.width)), height: max(bounds.height, Int(Self.minSize.height)))
        if let x = bounds.x, let y = bounds.y {
            frame.origin = NSPoint(x: x, y: Int(screen.frame.maxY) - y - Int(frame.height))
            // Ignore a saved position that is no longer on any screen (a display was unplugged).
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setContentSize(frame.size)
                window.center()
                return
            }
            window.setFrame(frame, display: false)
        } else {
            window.setContentSize(frame.size)
            window.center()
        }
        if bounds.isMaximized == true { window.zoom(nil) }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { app.scheduleSessionSave() }
    func windowDidResize(_ notification: Notification) { app.scheduleSessionSave() }
    func windowDidBecomeKey(_ notification: Notification) { app.noteKey(self) }

    /// Set once the person agreed to close despite unsaved changes (or there were none).
    private var closeConfirmed = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed { return true }
        Task { @MainActor [weak self] in
            guard let self, await self.confirmLeavingUnsavedChanges() else { return }
            self.closeConfirmed = true
            sender.close()
        }
        return false
    }

    /// Asks "Leave without saving?" for each tab with unsaved changes (showing that tab first in
    /// the compact layout). true = go ahead.
    func confirmLeavingUnsavedChanges() async -> Bool {
        for tab in tabs.list.items {
            guard await tab.hasUnsavedChanges() else { continue }
            if compact { selectTab(tab) }
            guard await tab.confirmLeavingUnsavedChanges() else { return false }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs.list.items {
            app.recordClosed(url: tab.currentURLString)
            tab.teardown()
        }
        app.windowClosed(self)
    }

    /// The layout switch emptied this window (its tabs live in a new one): close it quietly.
    func retire() {
        retired = true
        closeConfirmed = true
        window?.close()
    }

    // MARK: Tabs

    func addTab(_ tab: WebContentController, at index: Int? = nil, select: Bool = true) {
        tab.host = self
        if let index { tabs.list.insert(tab, at: index, select: select) } else { tabs.list.insertAfterActive(tab, select: select) }
        activeTabChanged(focus: select)
    }

    func selectTab(_ tab: WebContentController) {
        guard let index = tabs.list.items.firstIndex(where: { $0 === tab }) else { return }
        selectTab(at: index)
    }

    func selectTab(at index: Int) {
        tabs.list.select(index)
        activeTabChanged(focus: true)
    }

    func selectNextTab() { tabs.list.selectNext(); activeTabChanged(focus: true) }
    func selectPreviousTab() { tabs.list.selectPrevious(); activeTabChanged(focus: true) }

    func selectNumberedTab(_ n: Int) {
        if tabs.list.selectNumbered(n) { activeTabChanged(focus: true) }
    }

    func moveTab(from: Int, to: Int) {
        tabs.list.move(from: from, to: to)
        app.scheduleSessionSave()
    }

    /// Takes a tab out of this window without closing it (the caller puts it somewhere else).
    @discardableResult
    func detachTab(_ tab: WebContentController) -> WebContentController? {
        guard let index = tabs.list.items.firstIndex(where: { $0 === tab }) else { return nil }
        tabs.list.remove(at: index)
        if tab.host === self { tab.host = nil }
        if !tabs.list.isEmpty { activeTabChanged(focus: false) } else { container.show(nil) }
        return tab
    }

    func detachAllTabs() -> [WebContentController] {
        let all = tabs.list.items
        all.forEach { detachTab($0) }
        return all
    }

    private func activeTabChanged(focus: Bool) {
        let tab = content
        lastContent = tab
        container.show(tab)
        window?.title = tab.displayTitle
        if focus { window?.makeFirstResponder(tab.webView) }
        app.scheduleSessionSave()
    }

    /// Closes one tab after the unsaved-changes check; the window's last tab closes the window.
    func closeTab(_ tab: WebContentController) {
        guard compact else { window?.performClose(nil); return }
        Task { @MainActor [weak self] in
            guard let self, self.tabs.list.items.contains(where: { $0 === tab }) else { return }
            if self.compact { self.selectTab(tab) }
            guard await tab.confirmLeavingUnsavedChanges() else { return }
            self.removeConfirmed(tab)
        }
    }

    func closeActiveTab() { closeTab(content) }

    func closeOtherTabs(than tab: WebContentController) {
        guard let index = tabs.list.items.firstIndex(where: { $0 === tab }) else { return }
        closeTabs(tabs.list.indicesOfOthers(than: index).map { tabs.list.items[$0] })
    }

    func closeTabsToTheRight(of tab: WebContentController) {
        guard let index = tabs.list.items.firstIndex(where: { $0 === tab }) else { return }
        closeTabs(tabs.list.indicesToTheRight(of: index).map { tabs.list.items[$0] })
    }

    private func closeTabs(_ doomed: [WebContentController]) {
        Task { @MainActor [weak self] in
            for tab in doomed {
                guard let self, self.tabs.list.items.contains(where: { $0 === tab }) else { continue }
                self.selectTab(tab)
                guard await tab.confirmLeavingUnsavedChanges() else { return }
                self.removeConfirmed(tab)
            }
        }
    }

    private func removeConfirmed(_ tab: WebContentController) {
        if tabs.list.count <= 1 {
            closeConfirmed = true
            window?.close()
            return
        }
        guard detachTab(tab) != nil else { return }
        app.recordClosed(url: tab.currentURLString)
        tab.teardown()
    }

}
