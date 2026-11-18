import AppKit
import SwiftUI
import VesperCore
import WebKit

/// One window = one tab: Mail-style split view (native sidebar + web content) and unified toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingIdentifier = "vesper"
    static let defaultSize = NSSize(width: 1280, height: 840)
    static let minSize = NSSize(width: 760, height: 540)

    let app: AppModel
    let kind: WindowKind
    let state = ShellState()
    let content: WebContentController
    let split = NSSplitViewController()
    private var toolbarController: ToolbarController?

    /// ⌥⌘F: the toolbar's search field, which opens the page's command palette.
    func focusSearch() {
        toolbarController?.focusSearch()
    }

    var currentURLString: String? { content.currentURLString }

    init(app: AppModel, kind: WindowKind, path: String) {
        self.app = app
        self.kind = kind
        self.content = WebContentController(app: app, kind: kind, state: state, path: path)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = Self.minSize
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        window.title = kind == .vesper ? "Vesper" : "Playground"
        super.init(window: window)
        window.delegate = self
        content.host = self

        if kind == .vesper {
            let sidebar = NSHostingController(rootView: SidebarView(state: state, send: { [weak self] in self?.send($0) }))
            sidebar.sizingOptions = []
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
            sidebarItem.minimumThickness = 220
            sidebarItem.maximumThickness = 400
            sidebarItem.canCollapse = true
            split.addSplitViewItem(sidebarItem)
        }
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        window.setContentSize(Self.defaultSize)
        window.center()

        if kind == .vesper {
            toolbarController = ToolbarController(owner: self)
            window.toolbar = toolbarController?.toolbar
            track({ [weak self] in (self?.state.title, self?.state.subtitle) }) { [weak self] title, subtitle in
                guard let self, let title else { return }
                self.window?.title = cleanTabTitle(title)
                self.window?.subtitle = subtitle ?? ""
            }
        }
        content.bridge?.onRouteChange = { [weak self] in self?.app.scheduleSessionSave() }
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

    func connect(_ conn: Connection) { content.connect(conn) }

    /// Falls back to the document title until the page sends its own `title` messages.
    func webTitleChanged() {
        guard state.title == nil else { return }
        window?.title = cleanTabTitle(content.webView.title)
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
    func windowDidBecomeKey(_ notification: Notification) { app.scheduleSessionSave() }

    func windowWillClose(_ notification: Notification) {
        let url = currentURLString
        content.teardown()
        app.windowClosed(self, url: url)
    }
}
