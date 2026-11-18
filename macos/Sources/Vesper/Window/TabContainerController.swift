import AppKit

/// Holds the active tab's content in the split view's content item. Swapping tabs swaps the child,
/// so the split view (and the toolbar's sidebar tracking) never changes.
@MainActor
final class TabContainerController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() { view = NSView() }

    func show(_ controller: NSViewController?) {
        guard controller !== current else { return }
        if let old = current {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        current = controller
        guard let controller else { return }
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
