import AppKit
import Observation
import SwiftUI
import VesperCore

@MainActor
@Observable
private final class InspectorPopoutState {
    var isPoppedOut = false
}

/// Hosts the native inspector split pane: full-height vibrancy backdrop, compact header strip,
/// declarative SwiftUI `InspectorBodyView`, the window's persistent `CompanionWebController`, and
/// the persistent `InspectorPanelWebController`.
/// Also handles popping the inspector out into a floating `NSPanel` and re-docking it.
@MainActor
final class InspectorViewController: NSViewController {
    private let tabs: TabsModel
    private let send: (NativeCommand) -> Void
    private let navigate: (String, Bool) -> Void
    private let openPlayground: (URL) -> Void
    private let onPopOutChanged: (Bool) -> Void

    let companion = CompanionWebController()
    let panelWeb = InspectorPanelWebController()
    private let bodyContainer = NSView()
    private let separator = NSBox()
    private var headerHost: NSHostingView<InspectorHeaderView>?
    private var nativeHost: NSHostingController<InspectorBodyHost>?
    private var popout: InspectorPopoutController?
    private let popoutState = InspectorPopoutState()
    var isPoppedOut: Bool { popoutState.isPoppedOut }
    weak var shellHost: (any ShellHostActions)? {
        didSet {
            companion.shellHost = shellHost
            panelWeb.shellHost = shellHost
        }
    }

    init(
        tabs: TabsModel,
        send: @escaping (NativeCommand) -> Void,
        navigate: @escaping (String, Bool) -> Void,
        openPlayground: @escaping (URL) -> Void,
        onPopOutChanged: @escaping (Bool) -> Void,
        onPanelEvent: @escaping (String, String, String?) -> Void
    ) {
        self.tabs = tabs
        self.send = send
        self.navigate = navigate
        self.openPlayground = openPlayground
        self.onPopOutChanged = onPopOutChanged
        super.init(nibName: nil, bundle: nil)
        companion.onOpenInMain = navigate
        companion.onOpenPlayground = openPlayground
        panelWeb.onOpenInMain = navigate
        panelWeb.onOpenPlayground = openPlayground
        panelWeb.onPanelEvent = onPanelEvent
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        view = backdrop

        let header = NSHostingView(rootView: makeHeaderView())
        header.translatesAutoresizingMaskIntoConstraints = false
        headerHost = header

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let native = NSHostingController(rootView: InspectorBodyHost(
            tabs: tabs,
            send: send,
            navigate: navigate,
            openURL: { NSWorkspace.shared.open($0) }
        ))
        native.sizingOptions = []
        addChild(native)
        native.view.translatesAutoresizingMaskIntoConstraints = false
        nativeHost = native

        companion.webView.translatesAutoresizingMaskIntoConstraints = false
        panelWeb.webView.translatesAutoresizingMaskIntoConstraints = false

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(header)
        bodyContainer.addSubview(separator)
        bodyContainer.addSubview(native.view)
        bodyContainer.addSubview(companion.webView)
        bodyContainer.addSubview(panelWeb.webView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            native.view.topAnchor.constraint(equalTo: separator.bottomAnchor),
            native.view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            native.view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            native.view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            companion.webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            companion.webView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            companion.webView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            companion.webView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            panelWeb.webView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            panelWeb.webView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            panelWeb.webView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            panelWeb.webView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])

        attachBodyContainer(to: backdrop)

        track({ [weak tabs, weak popoutState] () -> (InspectorModel?, String?, [String], Bool) in
            let poppedOut = popoutState?.isPoppedOut ?? false
            guard let tabs else { return (nil, nil, [], poppedOut) }
            let model = tabs.list.active?.state.inspector
            let route = tabs.list.active?.state.route
            var seen = Set<String>()
            var keepKeys: [String] = []
            for item in tabs.list.items {
                for tab in item.state.inspector?.tabs ?? [] {
                    if tab.kind == .panel, let key = tab.panel?.key, seen.insert(key).inserted {
                        keepKeys.append(key)
                    }
                }
            }
            return (model, route, keepKeys, poppedOut)
        }) { [weak self] model, route, keepKeys, _ in
            self?.apply(model, route: route, keepKeys: keepKeys)
        }
    }

    func connect(_ conn: Connection) {
        companion.connect(conn)
        panelWeb.connect(conn)
    }

    func teardown() {
        dockBack(notify: false)
        companion.teardown()
        panelWeb.teardown()
    }

    func togglePopOut() {
        if isPoppedOut {
            dockBack(notify: true)
        } else {
            popOut()
        }
    }

    func bringPopoutToFront() {
        popout?.window?.makeKeyAndOrderFront(nil)
    }

    private func apply(_ model: InspectorModel?, route: String?, keepKeys: [String]) {
        let active = InspectorLogic.activeTab(in: model)
        let isCompanion = active?.kind == .companion
        let isPanel = active?.kind == .panel
        nativeHost?.view.isHidden = isCompanion || isPanel
        companion.webView.isHidden = !isCompanion
        panelWeb.webView.isHidden = !isPanel
        if isCompanion && (model?.open == true || isPoppedOut) {
            companion.ensureLoaded()
        }
        if isPanel && (model?.open == true || isPoppedOut) {
            panelWeb.ensureLoaded()
        }
        companion.updateContext(model?.companion)
        panelWeb.updateContext(InspectorPanelContext(
            active: isPanel ? active?.panel : nil,
            keepKeys: keepKeys,
            path: route
        ))
        popout?.window?.title = active?.label ?? "Inspector"
    }

    private func makeHeaderView() -> InspectorHeaderView {
        InspectorHeaderView(
            tabs: tabs,
            isPoppedOut: isPoppedOut,
            onSelectTab: { [weak self] tabId in
                self?.send(.inspectorSelectTab(tabId: tabId))
            },
            onHeaderAction: { [weak self] tabId, actionId, menuId in
                self?.send(.inspectorAction(tabId: tabId, actionId: actionId, itemId: nil, menuItemId: menuId))
            },
            onPopOutToggle: { [weak self] in
                self?.togglePopOut()
            }
        )
    }

    private func attachBodyContainer(to host: NSView) {
        bodyContainer.removeFromSuperview()
        host.addSubview(bodyContainer)
        NSLayoutConstraint.activate([
            bodyContainer.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    private func popOut() {
        guard !isPoppedOut else { return }
        popoutState.isPoppedOut = true
        headerHost?.rootView = makeHeaderView()
        let active = InspectorLogic.activeTab(in: tabs.list.active?.state.inspector)
        let activeTitle = active?.label ?? "Inspector"
        let popSize = InspectorLogic.popoutSize(for: active?.width)
        let panel = InspectorPopoutController(
            title: activeTitle,
            size: NSSize(width: popSize.width, height: popSize.height),
            ownerFrame: view.window?.frame
        ) { [weak self] in
            self?.dockBack(notify: true)
        }
        if let content = panel.backdropView {
            attachBodyContainer(to: content)
        }
        popout = panel
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        onPopOutChanged(true)
    }

    private func dockBack(notify: Bool) {
        guard isPoppedOut else { return }
        popoutState.isPoppedOut = false
        let existing = popout
        popout = nil
        existing?.closeSilently()
        headerHost?.rootView = makeHeaderView()
        attachBodyContainer(to: view)
        if notify {
            onPopOutChanged(false)
        }
    }
}

/// Floating utility panel holding the popped-out inspector without tearing down its WebViews.
@MainActor
private final class InspectorPopoutController: NSWindowController, NSWindowDelegate {
    private var onClose: (() -> Void)?
    private(set) var backdropView: NSVisualEffectView?

    init(title: String, size: NSSize, ownerFrame: NSRect?, onClose: @escaping () -> Void) {
        self.onClose = onClose
        var origin = NSPoint(x: 120, y: 120)
        if let f = ownerFrame {
            origin = NSPoint(x: f.maxX - size.width - 24, y: f.midY - size.height / 2)
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 360)

        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        panel.contentView = backdrop
        self.backdropView = backdrop

        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func closeSilently() {
        onClose = nil
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        handler?()
    }
}
