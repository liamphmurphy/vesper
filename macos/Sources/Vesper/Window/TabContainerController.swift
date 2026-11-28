import AppKit
import WebKit

/// Holds the window's mounted tab view controllers in the split view's content item, plus the
/// floating find bar. Inactive tabs stay mounted and hidden (`isHidden = true`) up to a bounded
/// MRU cap so switching tabs avoids tearing down and rebuilding SwiftUI `NSHostingView` trees,
/// while their edge Auto Layout constraints are deactivated while hidden so split-view and window
/// resizes never relayout inactive tabs.
@MainActor
final class TabContainerController: NSViewController {
    static let defaultMaxMountedTabs = 12

    private(set) var current: NSViewController?
    private var mounted: [NSViewController] = []
    private var activeConstraints: [ObjectIdentifier: [NSLayoutConstraint]] = [:]
    private let maxMountedTabs: Int
    let findBar = FindBarViewController()

    var mountedCount: Int { mounted.count }

    init(maxMountedTabs: Int = defaultMaxMountedTabs) {
        self.maxMountedTabs = max(1, maxMountedTabs)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
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
            freezeHidden(old)
        }
        current = controller
        guard let controller else {
            updateFindTarget(nil)
            return
        }
        if let existingIdx = mounted.firstIndex(where: { $0 === controller }) {
            mounted.remove(at: existingIdx)
            mounted.append(controller)
            pinVisible(controller)
            return
        }
        addChild(controller)
        attachSubviewIfNeeded(controller.view)
        pinVisible(controller)
        mounted.append(controller)
        evictOverflowTabsIfNeeded()
    }

    /// Removes a closed or moved tab from this container so it can be torn down or re-hosted cleanly.
    func detach(_ controller: NSViewController) {
        if current === controller {
            current = nil
        }
        mounted.removeAll { $0 === controller }
        unmount(controller)
    }

    func updateFindTarget(_ target: (any FindTarget)?) {
        if findBar.target !== target {
            if findBar.isVisible {
                findBar.dismiss(restoreFocus: false)
            }
            findBar.target = target
        }
    }

    func teardown() {
        findBar.teardown()
        let all = mounted
        mounted.removeAll()
        current = nil
        for controller in all {
            unmount(controller)
        }
    }

    private func evictOverflowTabsIfNeeded() {
        while mounted.count > maxMountedTabs {
            guard let victimIdx = mounted.firstIndex(where: { $0 !== current }) else { break }
            let victim = mounted.remove(at: victimIdx)
            unmount(victim)
        }
    }

    private func unmount(_ controller: NSViewController) {
        let key = ObjectIdentifier(controller)
        if let constraints = activeConstraints.removeValue(forKey: key) {
            NSLayoutConstraint.deactivate(constraints)
        }
        if controller.isViewLoaded {
            if controller.view.superview === view {
                controller.view.removeFromSuperview()
            }
            controller.view.isHidden = false
        }
        if controller.parent === self {
            controller.removeFromParent()
        }
    }

    /// Deactivates edge constraints on an inactive tab while keeping it in the view hierarchy so
    /// split-view and window resize animations skip laying out hidden SwiftUI hosting trees.
    private func freezeHidden(_ controller: NSViewController) {
        let key = ObjectIdentifier(controller)
        if let constraints = activeConstraints.removeValue(forKey: key) {
            NSLayoutConstraint.deactivate(constraints)
        }
        let child = controller.view
        let frozenFrame = child.frame
        child.translatesAutoresizingMaskIntoConstraints = true
        child.autoresizingMask = []
        child.frame = frozenFrame
        child.isHidden = true
    }

    /// Re-attaches edge constraints for the active tab so it tracks the container's current bounds.
    private func pinVisible(_ controller: NSViewController) {
        _ = view
        let child = controller.view
        attachSubviewIfNeeded(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        let key = ObjectIdentifier(controller)
        if activeConstraints[key] == nil {
            let constraints = [
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
            NSLayoutConstraint.activate(constraints)
            activeConstraints[key] = constraints
        }
        child.isHidden = false
        view.needsLayout = true
    }

    private func attachSubviewIfNeeded(_ child: NSView) {
        _ = view
        guard child.superview !== view else { return }
        if findBar.view.superview === view {
            view.addSubview(child, positioned: .below, relativeTo: findBar.view)
        } else {
            view.addSubview(child)
        }
    }
}
