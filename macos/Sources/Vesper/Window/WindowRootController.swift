import AppKit
import VesperCore

/// Window root controller: hosts the 3-pane `NSSplitViewController` (`Sidebar | Content | Inspector`)
/// beside the stationary 44pt native `RailBarView` at the trailing edge. Keeping the rail outside
/// the split view ensures opening or closing the native inspector never shifts the rail buttons
/// away from the pointer.
@MainActor
final class WindowRootController: NSViewController, NSUserInterfaceValidations {
    let split: NSSplitViewController
    private var rail: RailBarView?
    private var railWidth: NSLayoutConstraint?
    private var splitTrailing: NSLayoutConstraint?

    var onToggleSidebar: ((Any?) -> Void)?
    var onToggleInspector: ((Any?) -> Void)?
    var canToggleSidebar: (() -> Bool)?
    var canToggleInspector: (() -> Bool)?

    init(split: NSSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        view = root
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split.view)

        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: root.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        if let rail {
            attachRail(rail, to: root)
        } else {
            let trailing = split.view.trailingAnchor.constraint(equalTo: root.trailingAnchor)
            trailing.isActive = true
            splitTrailing = trailing
        }
    }

    /// Installs the stationary trailing rail and binds its width and items to the active tab.
    func installRail(tabs: TabsModel, send: @escaping (NativeCommand) -> Void, services: @escaping () -> SystemServices?) {
        precondition(rail == nil)
        let bar = RailBarView(send: send, services: services)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        rail = bar
        if isViewLoaded {
            attachRail(bar, to: view)
        }
        track({ [weak tabs] in tabs?.list.active?.state.rail }) { [weak self] model in
            self?.railWidth?.constant = model == nil ? 0 : RailBarView.width
            self?.rail?.apply(model)
        }
    }

    private func attachRail(_ bar: RailBarView, to root: NSView) {
        splitTrailing?.isActive = false
        splitTrailing = nil
        root.addSubview(bar)
        let width = bar.widthAnchor.constraint(equalToConstant: 0)
        railWidth = width
        let trailing = split.view.trailingAnchor.constraint(equalTo: bar.leadingAnchor)
        splitTrailing = trailing
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            width,
            trailing,
        ])
    }

    @objc func toggleSidebar(_ sender: Any?) {
        onToggleSidebar?(sender)
    }

    @objc func toggleInspector(_ sender: Any?) {
        onToggleInspector?(sender)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleSidebar(_:)):
            return canToggleSidebar?() ?? false
        case #selector(toggleInspector(_:)):
            return canToggleInspector?() ?? false
        default:
            return true
        }
    }
}
