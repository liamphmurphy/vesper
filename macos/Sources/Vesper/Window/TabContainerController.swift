import AppKit
import VesperCore

/// Holds the active tab's content in the split view's content item, with the native right rail
/// at its trailing edge. Swapping tabs swaps the child, so the split view (and the toolbar's
/// sidebar tracking) never changes; the rail redraws from the new active tab's state.
@MainActor
final class TabContainerController: NSViewController {
    private(set) var current: NSViewController?
    private var rail: RailBarView?
    private var railWidth: NSLayoutConstraint?

    override func loadView() { view = NSView() }

    /// Draws the active tab's right rail. `tabs` is observed, so a tab switch or a new `rail` message redraws it.
    func installRail(tabs: TabsModel, send: @escaping (NativeCommand) -> Void, services: @escaping () -> SystemServices?) {
        precondition(rail == nil)
        let bar = RailBarView(send: send, services: services)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        view.addSubview(bar)
        let width = bar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            width,
        ])
        rail = bar
        railWidth = width
        track({ [weak tabs] in tabs?.list.active?.state.rail }) { [weak self] model in
            self?.railWidth?.constant = model == nil ? 0 : RailBarView.width
            self?.rail?.apply(model)
        }
        if let current { attach(current.view) }
    }

    func show(_ controller: NSViewController?) {
        guard controller !== current else { return }
        if let old = current {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        current = controller
        guard let controller else { return }
        addChild(controller)
        attach(controller.view)
    }

    private func attach(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        if child.superview !== view { view.addSubview(child, positioned: .below, relativeTo: rail) }
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: rail?.leadingAnchor ?? view.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
