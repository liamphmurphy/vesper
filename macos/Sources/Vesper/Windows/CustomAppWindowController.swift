import AppKit
import SwiftUI
import VesperCore
import WebKit

/// Dedicated lightweight standalone macOS window for a single Vesper Custom App (`/apps/<slug>?standalone=1`).
/// Chromeless (no Vesper sidebar, tab strip, or right inspector) with a compact unified toolbar providing
/// Reload, a native Permissions popover, and "Open in Vesper", hosting the native SwiftUI `CustomAppScreen`.
@MainActor
final class CustomAppWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static let reloadItemId = NSToolbarItem.Identifier("vesper.customApp.reload")
    private static let permissionsItemId = NSToolbarItem.Identifier("vesper.customApp.permissions")
    private static let openInVesperItemId = NSToolbarItem.Identifier("vesper.customApp.openInVesper")

    let app: AppModel
    let slug: String
    let toastStore = ToastStore()
    var webView: WKWebView? { nil }

    private let onClose: () -> Void
    private let detailRequest: APIRequest<API.CustomAppDetail>
    private let screenContext: NativeScreenContext
    private let runtimeModel: StandaloneCustomAppModel
    private var permissionsPopover: NSPopover?
    private weak var permissionsButton: NSButton?
    private var closed = false

    init(app: AppModel, slug: String, onClose: @escaping () -> Void) {
        self.app = app
        self.slug = slug
        self.onClose = onClose
        self.detailRequest = API.getCustomApp(slug: slug)
        self.runtimeModel = StandaloneCustomAppModel(theme: app.effectiveTheme())

        let match = NativeRouteMatch(
            screen: .customApp,
            path: CustomAppStandaloneLogic.standalonePath(slug: slug),
            params: ["slug": slug],
            query: ["standalone": "1"]
        )
        let ctx = NativeScreenContext(match: match, store: app.system.store) { [weak app] targetPath, newTab in
            guard let app else { return }
            if newTab {
                app.openVesperTab(path: targetPath, nextTo: app.keyController?.window)
                NSApp.activate()
            } else {
                app.aux.openInMainWindow(targetPath)
            }
        }
        ctx.window = { [weak app] in app?.keyController }
        ctx.baseURL = { [weak app] in app?.connection?.baseURL }
        ctx.openCustomAppWindow = { [weak app] nextSlug in app?.aux.openCustomAppWindow(slug: nextSlug) }
        ctx.closeCustomAppWindow = { [weak app] nextSlug in app?.aux.closeCustomAppWindow(slug: nextSlug) }
        self.screenContext = ctx

        let initialRect = NSRect(
            x: 0,
            y: 0,
            width: CustomAppStandaloneLogic.defaultWindowWidth,
            height: CustomAppStandaloneLogic.defaultWindowHeight
        )
        let window = NSWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .automatic
        window.minSize = NSSize(
            width: CustomAppStandaloneLogic.minWindowWidth,
            height: CustomAppStandaloneLogic.minWindowHeight
        )
        window.title = Self.initialTitle(slug: slug, store: app.system.store)

        super.init(window: window)
        window.delegate = self

        let rootView = StandaloneCustomAppRootView(
            slug: slug,
            context: screenContext,
            model: runtimeModel,
            toastStore: toastStore,
            onOpenInWorkbench: { [weak self] in self?.openInVesper(nil) }
        )
        let hosting = NSHostingController(rootView: rootView)
        window.contentViewController = hosting
        _ = hosting.view

        let autosaveName = CustomAppStandaloneLogic.frameAutosaveName(slug: slug)
        if !window.setFrameUsingName(autosaveName) {
            window.setContentSize(initialRect.size)
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)

        let toolbar = NSToolbar(identifier: "vesper.customApp.\(slug)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        app.system.store.observe(detailRequest)
        app.system.store.load(detailRequest)

        bindState()
        applyPageMode(runtimeModel.theme.mode)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func initialTitle(slug: String, store: QueryStore) -> String {
        if let detail = store.entry(API.getCustomApp(slug: slug)).data {
            return detail.name
        }
        if let summary = store.entry(API.listCustomApps()).data?.apps.first(where: { $0.slug == slug }) {
            return summary.name
        }
        return slug
    }

    private func bindState() {
        track({ [weak self] () -> String in
            guard let self else { return "" }
            if let name = self.app.system.store.entry(self.detailRequest).data?.name, !name.isEmpty {
                return name
            }
            return Self.initialTitle(slug: self.slug, store: self.app.system.store)
        }) { [weak self] title in
            if !title.isEmpty {
                self?.window?.title = title
            }
        }
        track({ [weak self] () -> Int in
            guard let self, let detail = self.app.system.store.entry(self.detailRequest).data else { return 0 }
            return CustomAppStandaloneLogic.buildPermissions(from: detail).pendingRequestCount
        }) { [weak self] pendingCount in
            self?.updatePermissionsButton(pendingCount: pendingCount)
        }
    }

    func connect(_ conn: Connection) {
        app.system.store.load(detailRequest)
    }

    func applyAppearanceCommand(_ command: NativeCommand) {
        let theme = app.effectiveTheme()
        runtimeModel.theme = theme
        applyPageMode(theme.mode)
        if permissionsPopover?.isShown == true {
            rebuildPermissionsPopoverContent()
        }
    }

    func focus() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func applyPageMode(_ mode: ColorMode?) {
        guard let window else { return }
        guard let mode, mode != AppearanceMonitor.current().mode else {
            window.appearance = nil
            return
        }
        window.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    }

    // MARK: Toolbar Actions

    @objc private func reloadApp(_ sender: Any?) {
        runtimeModel.reloadNonce += 1
    }

    @objc private func togglePermissionsPopover(_ sender: Any?) {
        if let popover = permissionsPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let anchor = (sender as? NSView) ?? permissionsButton else { return }
        app.system.store.load(detailRequest)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = makePermissionsViewController()
        permissionsPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc private func openInVesper(_ sender: Any?) {
        permissionsPopover?.performClose(nil)
        app.aux.openInMainWindow(CustomAppStandaloneLogic.workbenchPath(slug: slug))
    }

    private func makePermissionsViewController() -> NSHostingController<CustomAppPermissionsPopoverView> {
        let view = CustomAppPermissionsPopoverView(
            slug: slug,
            store: app.system.store,
            theme: app.effectiveTheme(),
            onOpenInVesper: { [weak self] in self?.openInVesper(nil) }
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        return host
    }

    private func rebuildPermissionsPopoverContent() {
        permissionsPopover?.contentViewController = makePermissionsViewController()
    }

    private func updatePermissionsButton(pendingCount: Int) {
        guard let button = permissionsButton else { return }
        let symbolName = pendingCount > 0 ? "shield.lefthalf.filled" : "shield"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Permissions")
        button.contentTintColor = pendingCount > 0 ? .controlAccentColor : nil
        button.toolTip = pendingCount > 0
            ? "Permissions (\(pendingCount) requested)"
            : "Permissions"
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.reloadItemId, Self.permissionsItemId, Self.openInVesperItemId]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.reloadItemId:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Reload"
            item.paletteLabel = "Reload"
            item.toolTip = "Reload app (\u{2318}R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
            item.target = self
            item.action = #selector(reloadApp(_:))
            item.isBordered = true
            return item
        case Self.permissionsItemId:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Permissions"
            item.paletteLabel = "Permissions"
            let btn = NSButton(
                image: NSImage(systemSymbolName: "shield", accessibilityDescription: "Permissions") ?? NSImage(),
                target: self,
                action: #selector(togglePermissionsPopover(_:))
            )
            btn.bezelStyle = .toolbar
            btn.toolTip = "Permissions"
            permissionsButton = btn
            item.view = btn
            if let detail = app.system.store.entry(detailRequest).data {
                updatePermissionsButton(pendingCount: CustomAppStandaloneLogic.buildPermissions(from: detail).pendingRequestCount)
            }
            return item
        case Self.openInVesperItemId:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Open in Vesper"
            item.paletteLabel = "Open in Vesper"
            let btn = NSButton(title: "Open in Vesper", target: self, action: #selector(openInVesper(_:)))
            btn.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            btn.imagePosition = .imageLeading
            btn.bezelStyle = .toolbar
            btn.controlSize = .small
            btn.toolTip = "Open in Vesper to edit code, inspect SQLite, or chat"
            item.view = btn
            return item
        default:
            return nil
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        permissionsPopover?.performClose(nil)
        permissionsPopover = nil
        app.system.store.stopObserving(detailRequest.key)
        if let client = app.aux.client() {
            let slug = self.slug
            Task {
                _ = try? await client.send(CustomAppStandaloneLogic.notifyWindowClosedRequest(slug: slug))
            }
        }
        toastStore.teardown()
        onClose()
    }
}

@MainActor
@Observable
private final class StandaloneCustomAppModel {
    var theme: ThemeTokens
    var reloadNonce: Int = 0

    init(theme: ThemeTokens) {
        self.theme = theme
    }
}

private struct StandaloneCustomAppRootView: View {
    let slug: String
    let context: NativeScreenContext
    let model: StandaloneCustomAppModel
    let toastStore: ToastStore
    let onOpenInWorkbench: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            CustomAppScreen(
                overrideSlug: slug,
                standalone: true,
                reloadNonce: model.reloadNonce,
                onOpenInWorkbench: onOpenInWorkbench
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(model.theme.palette.background)
            .foregroundStyle(model.theme.palette.text)
            .tint(model.theme.palette.accent)
            .environment(\.vesperTheme, model.theme)
            .environment(\.colorScheme, model.theme.mode == .dark ? .dark : .light)
            .environment(context)

            if !toastStore.toasts.isEmpty {
                ToastOverlayView(store: toastStore)
                    .frame(maxWidth: 440)
                    .padding(.bottom, 20)
            }
        }
    }
}
