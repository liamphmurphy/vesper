import AppKit
import Quartz
import SwiftUI
import VesperCore
import WebKit

/// A window: Mail-style split view (native sidebar + web content) and unified toolbar. In the
/// separate layout it holds one tab (and the system groups windows into tabs); in the compact
/// layout it holds several tabs, drawn in its toolbar, and shows the active one.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarItemValidation, ShellHostActions {
    static let tabbingIdentifier = "vesper"
    static let defaultSize = NSSize(width: 1280, height: 840)
    static let minSize = NSSize(width: 760, height: 540)

    let app: AppModel
    /// Compact layout: several tabs in this window, drawn by us in the toolbar.
    let compact: Bool
    let tabs = TabsModel()
    let split = NSSplitViewController()
    let toastStore = ToastStore()
    private let container = TabContainerController()
    private var rootController: WindowRootController?
    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorController: InspectorViewController?
    private var inspectorCollapseObservation: NSKeyValueObservation?
    private var inspectorSyncDepth = 0
    private var isSyncingInspector: Bool { inspectorSyncDepth > 0 }
    private var lastObservedInspectorTab: ObjectIdentifier?
    private var lastInspectorWidthClass: InspectorWidth?
    private var isAnimatingPinnedWidth = false
    /// Set while the sidebar is folded because the page asked (theater mode), so only that fold is undone.
    private var sidebarFoldedForPage = false
    private var toolbarController: ToolbarController?
    private var lastContent: WebContentController
    /// Set when the layout switch emptied and closed this window.
    private(set) var retired = false

    /// The active tab. Everything that used to be "the window's page" goes through it.
    var content: WebContentController { tabs.list.active ?? lastContent }
    var state: ShellState { content.state }
    var kind: WindowKind { content.kind }
    var hasSidebar: Bool { sidebarItem != nil }
    var hasInspector: Bool { inspectorItem != nil }
    var isInspectorCollapsed: Bool { inspectorItem?.isCollapsed ?? true }
    var inspectorDividerIndex: Int { InspectorLogic.inspectorDividerIndex(hasSidebar: hasSidebar) }
    var currentURLString: String? { content.currentURLString }

    /// ⌥⌘F: open the native floating command palette anchored to this window.
    func focusSearch() {
        openCommandPalette(CommandPaletteRequest(scope: .all))
    }

    var isFindBarVisible: Bool { container.findBar.isVisible }
    var hasFindQuery: Bool { container.findBar.hasQuery }

    func showFindBar(initialQuery: String? = nil) {
        container.updateFindTarget(content.findTarget)
        container.findBar.present(initialQuery: initialQuery)
    }

    func findNext() {
        container.updateFindTarget(content.findTarget)
        container.findBar.findNext()
    }

    func findPrevious() {
        container.updateFindTarget(content.findTarget)
        container.findBar.findPrevious()
    }

    func useSelectionForFind() {
        let target = content.webView
        Task { @MainActor [weak self, weak target] in
            guard let self, let target, self.content.webView === target else { return }
            let raw = (try? await target.callAsyncJavaScript(
                "return window.getSelection()?.toString() ?? ''",
                arguments: [:], in: nil, contentWorld: .page
            )) as? String
            guard let normalized = FindLogic.normalizeSelection(raw) else { return }
            self.showFindBar(initialQuery: normalized)
        }
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

        let hasNativeChrome = compact || firstKind == .vesper
        if hasNativeChrome {
            let sidebar = NSHostingController(rootView: SidebarHost(tabs: tabs, send: { [weak self] in self?.send($0) }))
            sidebar.sizingOptions = []
            let item = NSSplitViewItem(sidebarWithViewController: sidebar)
            item.allowsFullHeightLayout = true
            item.minimumThickness = 220
            item.maximumThickness = 400
            item.canCollapse = true
            split.addSplitViewItem(item)
            sidebarItem = item
        }
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 380
        split.addSplitViewItem(contentItem)

        if hasNativeChrome {
            let inspector = InspectorViewController(
                tabs: tabs,
                send: { [weak self] in self?.send($0) },
                navigate: { [weak self] path, newTab in self?.openInMain(path: path, newTab: newTab) },
                openPlayground: { [weak self] url in self?.app.openPlayground(url: url, nextTo: self?.window) },
                onPopOutChanged: { [weak self] poppedOut in self?.inspectorPopOutChanged(poppedOut) },
                onPanelEvent: { [weak self] tabId, event, payloadJson in self?.handlePanelEvent(tabId: tabId, event: event, payloadJson: payloadJson) }
            )
            inspector.companion.ownerWindow = { [weak self] in self?.window }
            inspector.companion.playgroundPorts = { [weak app] in app?.playgroundPorts ?? defaultPlaygroundPorts }
            inspector.companion.appearanceCommand = { [weak app] in
                if let cmd = app?.currentAppearanceCommand() { return cmd }
                let (accent, mode) = AppearanceMonitor.current()
                return .appearance(accent: accent, mode: mode)
            }
            inspector.panelWeb.ownerWindow = { [weak self] in self?.window }
            inspector.panelWeb.playgroundPorts = { [weak app] in app?.playgroundPorts ?? defaultPlaygroundPorts }
            inspector.panelWeb.appearanceCommand = { [weak app] in
                if let cmd = app?.currentAppearanceCommand() { return cmd }
                let (accent, mode) = AppearanceMonitor.current()
                return .appearance(accent: accent, mode: mode)
            }
            if let conn = app.connection { inspector.connect(conn) }
            let inspItem = NSSplitViewItem(inspectorWithViewController: inspector)
            inspItem.allowsFullHeightLayout = true
            inspItem.minimumThickness = 280
            inspItem.maximumThickness = 640
            inspItem.canCollapse = true
            inspItem.isCollapsed = true
            // AppKit requires the inspector split item to be the final item in NSSplitViewController.
            split.addSplitViewItem(inspItem)
            inspector.shellHost = self
            inspectorItem = inspItem
            inspectorController = inspector

            inspectorCollapseObservation = inspItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                // Take the Sendable Bool from the change rather than capturing the (non-Sendable) split item.
                let newCollapsed = change.newValue
                MainActor.assumeIsolated {
                    guard let self, !self.isSyncingInspector else { return }
                    guard let collapsed = newCollapsed ?? self.inspectorItem?.isCollapsed else { return }
                    let model = self.state.inspector
                    let poppedOut = self.inspectorController?.isPoppedOut == true
                    guard InspectorLogic.handlesToggleNatively(model: model, poppedOut: poppedOut) else { return }
                    let actualOpen = !collapsed
                    let expectedOpen = InspectorLogic.shouldShowNativeInspector(model: model, poppedOut: poppedOut)
                    if actualOpen != expectedOpen {
                        self.send(.inspectorVisibility(open: actualOpen))
                    }
                }
            }
        }

        let root = WindowRootController(split: split)
        root.installRail(
            tabs: tabs,
            showHarnessActivity: { [weak app] in app?.settings.settings.effectiveAppearance.showHarnessActivity ?? true },
            send: { [weak self] in self?.handleRailCommand($0) },
            services: { [weak app] in app?.system }
        )
        root.installToasts(store: toastStore)
        root.onToggleSidebar = { [weak self] sender in self?.split.toggleSidebar(sender) }
        root.onToggleInspector = { [weak self] sender in self?.toggleInspector(sender) }
        root.canToggleSidebar = { [weak self] in self?.hasSidebar == true }
        root.canToggleInspector = { [weak self] in self?.hasInspector == true && self?.kind == .vesper }
        rootController = root

        window.contentViewController = root
        _ = root.view
        window.setContentSize(Self.defaultSize)
        window.center()

        for tab in initial {
            attachTab(tab)
            tabs.list.insert(tab, select: false)
        }
        tabs.list.select(activeIndex)
        container.show(content)
        container.updateFindTarget(content.findTarget)
        container.findBar.onDismiss = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.content.focusView)
        }

        if hasNativeChrome {
            toolbarController = ToolbarController(owner: self)
            window.toolbar = toolbarController?.toolbar
            track({ [weak self] in self?.state.pageMode }) { [weak self] mode in self?.applyPageMode(mode) }
            track({ [weak self] in (self?.content.displayTitle, self?.state.subtitle) }) { [weak self] title, subtitle in
                guard let self, let title else { return }
                self.window?.title = title
                self.window?.subtitle = self.compact ? "" : (subtitle ?? "")
            }
            track({ [weak self] in (self?.tabs.list.active.map { ObjectIdentifier($0) }, self?.state.inspector) }) { [weak self] tabId, model in
                self?.syncInspectorVisibility(tabId: tabId, model: model)
            }
            track({ [weak self] in self?.state.sidebarHidden ?? false }) { [weak self] hidden in
                self?.syncSidebarHidden(hidden)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Commands

    func send(_ command: NativeCommand) {
        content.dispatch(command)
    }

    /// A tab switched between its web view and a native screen: the find bar follows the active one.
    func findTargetChanged(_ tab: WebContentController) {
        guard tab === content else { return }
        container.updateFindTarget(tab.findTarget)
    }

    @objc func toggleInspector(_ sender: Any?) {
        guard hasInspector, kind == .vesper else { return }
        if inspectorController?.isPoppedOut == true {
            inspectorController?.togglePopOut()
            return
        }
        if InspectorLogic.handlesToggleNatively(model: state.inspector, poppedOut: false) {
            let targetCollapsed = !isInspectorCollapsed
            let widthClass = InspectorLogic.activeTab(in: state.inspector)?.width ?? .regular
            let applyDesired = !targetCollapsed && widthClass != lastInspectorWidthClass
            if applyDesired {
                lastInspectorWidthClass = widthClass
            }
            animateInspector(collapsed: targetCollapsed, widthClass: widthClass, applyDesiredWidth: applyDesired)
            send(.inspectorVisibility(open: !targetCollapsed))
        } else {
            send(.command(.toggleCompanion))
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == .toggleInspector {
            return kind == .vesper && hasInspector
        }
        return true
    }

    private func handleRailCommand(_ command: NativeCommand) {
        if case .railAction(let itemId, let menuItemId) = command {
            if itemId == "settings" && menuItemId == nil {
                app.aux.openSettings()
                return
            }
            if itemId == "customization" && menuItemId == nil {
                app.aux.openSettings(destination: .pane(pane: .memory))
                return
            }
            if itemId == "pr" && menuItemId == "pr.setup" {
                app.aux.openSettings(destination: .pane(pane: .secrets))
                return
            }
        }
        if case .railAction(let itemId, let menuItemId) = command, menuItemId == nil {
            if let tabId = InspectorLogic.railDockTabId(from: itemId),
               let model = state.inspector,
               let targetTab = model.tabs.first(where: { $0.id == tabId }),
               targetTab.kind != .web {
                if inspectorController?.isPoppedOut == true {
                    inspectorController?.bringPopoutToFront()
                    send(.inspectorSelectTab(tabId: tabId))
                    return
                }
                let currentlyOpen = InspectorLogic.shouldShowNativeInspector(model: model, poppedOut: false)
                if !currentlyOpen {
                    let widthClass = targetTab.width ?? .regular
                    let applyDesired = widthClass != lastInspectorWidthClass
                    if applyDesired {
                        lastInspectorWidthClass = widthClass
                    }
                    animateInspector(collapsed: false, widthClass: widthClass, applyDesiredWidth: applyDesired)
                    send(.inspectorSelectTab(tabId: tabId))
                    return
                }
                if tabId == InspectorLogic.activeTab(in: model)?.id {
                    animateInspector(collapsed: true)
                    send(.inspectorVisibility(open: false))
                    return
                }
                send(.inspectorSelectTab(tabId: tabId))
                return
            }
        }
        send(command)
    }

    private func handlePanelEvent(tabId: String, event: String, payloadJson: String?) {
        let cmd = NativeCommand.panelEvent(tabId: tabId, event: event, payloadJson: payloadJson)
        if event == "composerDrop" {
            for tab in tabs.list.items where tab.kind == .vesper {
                tab.bridge?.send(cmd)
            }
            return
        }
        content.bridge?.send(cmd)
    }

    private func openInMain(path: String, newTab: Bool) {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return }
        if app.handleSettingsPath(path, from: window) { return }
        if newTab || kind != .vesper {
            app.openVesperTab(path: path, nextTo: window)
        } else {
            content.navigate(path: path)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func inspectorPopOutChanged(_ poppedOut: Bool) {
        syncInspectorVisibility(tabId: tabs.list.active.map { ObjectIdentifier($0) }, model: state.inspector)
        if !poppedOut && InspectorLogic.handlesToggleNatively(model: state.inspector, poppedOut: false) {
            send(.inspectorVisibility(open: true))
        }
    }

    /// Folds the sidebar while the active tab's page asks for the whole window, and unfolds it after,
    /// unless the person folded it themselves: a sidebar that was already folded stays folded.
    private func syncSidebarHidden(_ hidden: Bool) {
        guard let item = sidebarItem else { return }
        if hidden {
            guard !item.isCollapsed else { return }
            sidebarFoldedForPage = true
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                item.animator().isCollapsed = true
            }
        } else if sidebarFoldedForPage {
            sidebarFoldedForPage = false
            guard item.isCollapsed else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                item.animator().isCollapsed = false
            }
        }
    }

    private func syncInspectorVisibility(tabId: ObjectIdentifier?, model: InspectorModel?) {
        guard let item = inspectorItem else { return }
        let active = InspectorLogic.activeTab(in: model)
        let widthClass = active?.width ?? .regular
        let thickness = InspectorLogic.thickness(for: active?.width)

        let wantOpen = InspectorLogic.shouldShowNativeInspector(model: model, poppedOut: inspectorController?.isPoppedOut == true)
        let targetCollapsed = !wantOpen
        let tabSwitched = tabId != lastObservedInspectorTab
        lastObservedInspectorTab = tabId

        let wasCollapsed = item.isCollapsed
        let widthChanged = widthClass != lastInspectorWidthClass
        if wantOpen && widthChanged {
            lastInspectorWidthClass = widthClass
        }

        if item.isCollapsed != targetCollapsed {
            if tabSwitched {
                isAnimatingPinnedWidth = false
                item.minimumThickness = CGFloat(thickness.min)
                item.maximumThickness = CGFloat(thickness.max)
                inspectorSyncDepth += 1
                item.isCollapsed = targetCollapsed
                inspectorSyncDepth -= 1
                if wantOpen && widthChanged {
                    applyInspectorWidth(widthClass, animated: false)
                }
            } else {
                animateInspector(collapsed: targetCollapsed, widthClass: widthClass, applyDesiredWidth: wantOpen && widthChanged)
            }
        } else if !isAnimatingPinnedWidth || widthChanged {
            isAnimatingPinnedWidth = false
            item.minimumThickness = CGFloat(thickness.min)
            item.maximumThickness = CGFloat(thickness.max)
            if wantOpen && (wasCollapsed || widthChanged) {
                applyInspectorWidth(widthClass, animated: !tabSwitched)
            }
        }
    }

    private func desiredInspectorWidth(for widthClass: InspectorWidth?) -> CGFloat {
        let splitWidth = split.splitView.bounds.width
        let thickness = InspectorLogic.thickness(for: widthClass)
        guard splitWidth > 0 else { return CGFloat(thickness.preferred) }
        let sidebarWidth = (hasSidebar && sidebarItem?.isCollapsed == false) ? (sidebarItem?.viewController.view.frame.width ?? 0) : 0
        let dividerCount = CGFloat((hasSidebar ? 1 : 0) + 1)
        let available = Double(splitWidth - sidebarWidth - dividerCount * split.splitView.dividerThickness)
        return CGFloat(InspectorLogic.desiredWidth(for: widthClass, availableWidth: available))
    }

    private func applyInspectorWidth(_ widthClass: InspectorWidth?, animated: Bool) {
        guard let item = inspectorItem, !item.isCollapsed else { return }
        let divider = inspectorDividerIndex
        guard split.splitView.arrangedSubviews.count > divider + 1 else { return }
        let splitWidth = split.splitView.bounds.width
        guard splitWidth > 0 else { return }
        let desired = desiredInspectorWidth(for: widthClass)
        let dividerPos = splitWidth - desired - split.splitView.dividerThickness
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                split.splitView.animator().setPosition(dividerPos, ofDividerAt: divider)
            }
        } else {
            split.splitView.setPosition(dividerPos, ofDividerAt: divider)
        }
    }

    private func animateInspector(collapsed: Bool, widthClass: InspectorWidth? = nil, applyDesiredWidth: Bool = false) {
        guard let item = inspectorItem, item.isCollapsed != collapsed else { return }
        let effectiveWidth = widthClass ?? InspectorLogic.activeTab(in: state.inspector)?.width
        let thickness = InspectorLogic.thickness(for: effectiveWidth)
        let pinnedForAnimation = !collapsed && applyDesiredWidth && split.splitView.bounds.width > 0
        if pinnedForAnimation {
            let desired = desiredInspectorWidth(for: effectiveWidth)
            isAnimatingPinnedWidth = true
            item.minimumThickness = desired
            item.maximumThickness = desired
        } else {
            isAnimatingPinnedWidth = false
            item.minimumThickness = CGFloat(thickness.min)
            item.maximumThickness = CGFloat(thickness.max)
        }
        inspectorSyncDepth += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.allowsImplicitAnimation = true
            item.animator().isCollapsed = collapsed
        }, completionHandler: {
            Task { @MainActor [weak self, effectiveWidth, pinnedForAnimation] in
                guard let self else { return }
                if pinnedForAnimation, self.isAnimatingPinnedWidth, let insp = self.inspectorItem {
                    self.isAnimatingPinnedWidth = false
                    let activeWidth = InspectorLogic.activeTab(in: self.state.inspector)?.width ?? effectiveWidth
                    let current = InspectorLogic.thickness(for: activeWidth)
                    insp.minimumThickness = CGFloat(current.min)
                    insp.maximumThickness = CGFloat(current.max)
                }
                self.inspectorSyncDepth = max(0, self.inspectorSyncDepth - 1)
            }
        })
    }

    private func attachTab(_ tab: WebContentController) {
        tab.host = self
        tab.bridge?.onOpenInMain = { [weak self] path, newTab in
            self?.openInMain(path: path, newTab: newTab)
        }
        tab.bridge?.shellHost = self
    }

    // MARK: ShellHostActions

    func showToast(_ toast: ToastItemModel, from webView: WKWebView?) {
        toastStore.show(toast, from: webView)
    }

    /// A toast a native screen shows; its action, dismissal or timeout comes back to `onEvent`.
    func showNativeToast(_ toast: ToastItemModel, onEvent: @escaping @MainActor (ToastEventKind) -> Void) {
        toastStore.show(toast, from: nil, onEvent: onEvent)
    }

    func dismissToast(id: String) {
        toastStore.dismissFromPage(id: id)
    }

    func showShortcuts() {
        app.aux.showShortcuts()
    }

    func openCommandPalette(_ request: CommandPaletteRequest?) {
        app.aux.openCommandPalette(request: request, from: self)
    }

    func closeCommandPalette() {
        app.aux.closeCommandPalette()
    }

    func showQuickLook(items: [QuickLookItem], index: Int?) {
        app.aux.previewQuickLook(items: items, index: index, from: window)
    }

    // MARK: QLPreviewPanelController

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { app.aux.quickLook.hasItems }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let active = QLPreviewPanel.shared() else { return }
            app.aux.quickLook.attach(to: active)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let active = QLPreviewPanel.shared() else { return }
            app.aux.quickLook.detach(from: active)
        }
    }

    /// Match the window to the page's effective mode, so a person who forces Dark in Vesper while macOS is
    /// Light gets a consistent window. When they agree the window follows the system (no override).
    private func applyPageMode(_ mode: ColorMode?) {
        guard let window else { return }
        guard let mode, mode != AppearanceMonitor.current().mode else { window.appearance = nil; return }
        window.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    }

    func applyAppearanceCommand(_ command: NativeCommand) {
        inspectorController?.companion.sendAppearance(command)
        inspectorController?.panelWeb.sendAppearance(command)
    }

    func connect(_ conn: Connection) {
        tabs.list.items.forEach { $0.connect(conn) }
        inspectorController?.connect(conn)
    }

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
        inspectorCollapseObservation = nil
        inspectorController?.teardown()
        container.teardown()
        toastStore.teardown()
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
        attachTab(tab)
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
        container.updateFindTarget(tab.findTarget)
        window?.title = tab.displayTitle
        window?.toolbar?.validateVisibleItems()
        if focus { window?.makeFirstResponder(tab.webView) }
        app.scheduleSessionSave()
    }

    /// Closes one tab after the unsaved-changes check. A window's last tab closes the window, unless
    /// it is the app's only tab: then a new chat with the default persona takes its place, so ⌘W
    /// never quits Vesper.
    func closeTab(_ tab: WebContentController) {
        if !compact && closeOutcome != .openNewChat { window?.performClose(nil); return }
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

    /// What closing one of this window's tabs does now. In the separate layout every tab is a
    /// window, so the other windows include this tab's siblings.
    private var closeOutcome: TabCloseOutcome {
        TabCloseOutcome.decide(tabsInWindow: tabs.list.count,
                               otherWindows: app.windows.filter { $0 !== self && !$0.retired }.count)
    }

    private func removeConfirmed(_ tab: WebContentController) {
        switch closeOutcome {
        case .removeTab: remove(tab)
        case .closeWindow:
            closeConfirmed = true
            window?.close()
        case .openNewChat: replaceWithNewChat(tab)
        }
    }

    private func remove(_ tab: WebContentController) {
        guard detachTab(tab) != nil else { return }
        app.recordClosed(url: tab.currentURLString)
        tab.teardown()
    }

    private func replaceWithNewChat(_ tab: WebContentController) {
        let path = DockModel.newChatHref()
        // A separate-layout playground window has no sidebar or toolbar to show Vesper in, so the
        // chat opens in a Vesper window (tabbed onto this one) and this one closes.
        guard hasSidebar else {
            app.openVesperTab(path: path, nextTo: window)
            closeConfirmed = true
            window?.close()
            return
        }
        addTab(app.makeTab(kind: .vesper, path: path))
        remove(tab)
    }

}
