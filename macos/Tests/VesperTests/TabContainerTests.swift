import AppKit
import Testing
@testable import Vesper

@MainActor
@Suite("TabContainerController mounted tab switching")
struct TabContainerTests {
    private final class TrackingVC: NSViewController {
        var windowMoves = 0

        override func loadView() {
            let v = TrackingView()
            v.onMoveToWindow = { [weak self] in self?.windowMoves += 1 }
            view = v
        }
    }

    private final class TrackingView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }

    private func makeHostedContainer(maxMountedTabs: Int = TabContainerController.defaultMaxMountedTabs) -> (NSWindow, TabContainerController) {
        let container = TabContainerController(maxMountedTabs: maxMountedTabs)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = container
        _ = container.view
        return (window, container)
    }

    @Test("switching tabs hides inactive tabs instead of detaching them from the window")
    func switchingPreservesWindowAttachment() {
        let (_, container) = makeHostedContainer()
        let tabA = TrackingVC()
        let tabB = TrackingVC()

        container.show(tabA)
        #expect(container.current === tabA)
        #expect(container.mountedCount == 1)
        #expect(!tabA.view.isHidden)
        #expect(tabA.view.superview === container.view)
        let aMovesAfterFirstShow = tabA.windowMoves

        container.show(tabB)
        #expect(container.current === tabB)
        #expect(container.mountedCount == 2)
        #expect(tabA.view.isHidden)
        #expect(!tabB.view.isHidden)
        #expect(tabA.view.superview === container.view)
        #expect(tabA.parent === container)
        #expect(tabA.windowMoves == aMovesAfterFirstShow)
        let bMovesAfterFirstShow = tabB.windowMoves

        // Switching back to tabA unhides it without any viewDidMoveToWindow teardown/reattach.
        container.show(tabA)
        #expect(container.current === tabA)
        #expect(!tabA.view.isHidden)
        #expect(tabB.view.isHidden)
        #expect(tabA.windowMoves == aMovesAfterFirstShow)
        #expect(tabB.windowMoves == bMovesAfterFirstShow)
    }

    @Test("detaching a tab removes it from the container and resets isHidden for reuse")
    func detachUnmountsAndUnhides() {
        let (_, container) = makeHostedContainer()
        let tabA = TrackingVC()
        let tabB = TrackingVC()

        container.show(tabA)
        container.show(tabB)
        #expect(tabA.view.isHidden)

        container.detach(tabA)
        #expect(container.mountedCount == 1)
        #expect(tabA.view.superview == nil)
        #expect(tabA.parent == nil)
        #expect(!tabA.view.isHidden)

        container.detach(tabB)
        #expect(container.mountedCount == 0)
        #expect(container.current == nil)
        #expect(tabB.view.superview == nil)
    }

    @Test("LRU eviction caps mounted background tabs while keeping the active tab")
    func evictsLeastRecentlyUsedHiddenTab() {
        let (_, container) = makeHostedContainer(maxMountedTabs: 2)
        let tabA = TrackingVC()
        let tabB = TrackingVC()
        let tabC = TrackingVC()

        container.show(tabA)
        container.show(tabB)
        // Touch tabA so tabB becomes the least recently used hidden tab.
        container.show(tabA)
        container.show(tabC)

        #expect(container.mountedCount == 2)
        #expect(container.current === tabC)
        #expect(tabA.view.superview === container.view)
        #expect(tabA.view.isHidden)
        #expect(tabB.view.superview == nil)
        #expect(tabB.parent == nil)
        #expect(!tabB.view.isHidden)
    }
}
