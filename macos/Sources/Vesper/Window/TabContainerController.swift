import AppKit
import WebKit

/// Holds the active tab's content in the split view's content item, plus the floating find bar.
/// Swapping tabs swaps the child under the find bar so the split view and toolbar never rebuild.
@MainActor
final class TabContainerController: NSViewController {
    private(set) var current: NSViewController?
    let findBar = FindBarViewController()

    override func loadView() {
        let root = NSView()
        view = root

        addChild(findBar)
        findBar.view.translatesAutoresizingMaskIntoConstraints = false
        findBar.view.isHidden = true
        root.addSubview(findBar.view)
        NSLayoutConstraint.activate([
            findBar.view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            findBar.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        ])
    }

    func show(_ controller: NSViewController?) {
        guard controller !== current else { return }
        if let old = current {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        current = controller
        guard let controller else {
            updateFindTarget(nil)
            return
        }
        addChild(controller)
        attach(controller.view)
    }

    func updateFindTarget(_ webView: WKWebView?) {
        if findBar.targetWebView !== webView {
            if findBar.isVisible {
                findBar.dismiss(restoreFocus: false)
            }
            findBar.targetWebView = webView
        }
    }

    func teardown() {
        findBar.teardown()
    }

    private func attach(_ child: NSView) {
        _ = view
        child.translatesAutoresizingMaskIntoConstraints = false
        if child.superview !== view {
            if findBar.view.superview === view {
                view.addSubview(child, positioned: .below, relativeTo: findBar.view)
            } else {
                view.addSubview(child)
            }
        }
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
