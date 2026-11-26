import AppKit
import Testing
@testable import Vesper

@MainActor
@Suite("HoverTooltip")
struct HoverTooltipTests {
    private func makeHostedAnchor(
        text: String,
        presenter: HoverTooltipPresenter
    ) -> (NSWindow, HoverTrackingNSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = contentView
        let anchor = HoverTrackingNSView(text: text, hint: nil, presenter: presenter)
        anchor.frame = NSRect(x: 20, y: 240, width: 22, height: 22)
        contentView.addSubview(anchor)
        anchor.updateTrackingAreas()
        return (window, anchor)
    }

    @Test("tracking view passes clicks through and registers hover tracking area")
    func trackingViewPassesHitTestThrough() {
        let presenter = HoverTooltipPresenter(requiresKeyWindow: false, verifiesMouseInside: false, delayOverrideMs: 0)
        let (_, anchor) = makeHostedAnchor(text: "Graph view", presenter: presenter)

        #expect(anchor.hitTest(NSPoint(x: 11, y: 11)) == nil)
        let area = anchor.trackingAreas.first
        #expect(area != nil)
        #expect(area?.options.contains(.mouseEnteredAndExited) == true)
        #expect(area?.options.contains(.activeInKeyWindow) == true)
        #expect(area?.options.contains(.inVisibleRect) == true)
    }

    @Test("presenter shows, updates, hands off between siblings, and dismisses on exit or menu open")
    func presenterLifecycle() {
        let presenter = HoverTooltipPresenter(requiresKeyWindow: false, verifiesMouseInside: false, delayOverrideMs: 0)
        let (window, first) = makeHostedAnchor(text: "Graph view", presenter: presenter)
        let second = HoverTrackingNSView(text: "Keep notes connected", hint: nil, presenter: presenter)
        second.frame = NSRect(x: 50, y: 240, width: 22, height: 22)
        window.contentView?.addSubview(second)

        presenter.mouseEntered(ownerID: first.ownerID, text: first.text, hint: nil, anchorView: first)
        #expect(presenter.isVisible)
        #expect(presenter.currentText == "Graph view")

        presenter.update(ownerID: first.ownerID, text: "Done selecting", hint: nil, anchorView: first)
        #expect(presenter.currentText == "Done selecting")

        // Handoff to second icon before first's exit arrives must keep the tooltip alive.
        presenter.mouseEntered(ownerID: second.ownerID, text: second.text, hint: nil, anchorView: second)
        presenter.mouseExited(ownerID: first.ownerID)
        #expect(presenter.isVisible)
        #expect(presenter.currentText == "Keep notes connected")

        // Opening a menu (such as the '+' menu) immediately dismisses the tooltip.
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: nil)
        #expect(!presenter.isVisible)

        // Detaching the hovered view from its window also dismisses the tooltip.
        presenter.mouseEntered(ownerID: second.ownerID, text: second.text, hint: nil, anchorView: second)
        #expect(presenter.isVisible)
        second.removeFromSuperview()
        #expect(!presenter.isVisible)
    }
}
