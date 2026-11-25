import AppKit
import SwiftUI
import VesperCore

extension View {
    /// Captures trackpad and mouse scroll-wheel events when the pointer is within this view's visible
    /// bounds, without interfering with SwiftUI hit-testing or drag/tap/pinch gestures.
    /// Return `true` from `onAction` to consume the event, or `false` to pass it through.
    func onCanvasScrollWheel(
        enabled: Bool = true,
        onAction: @escaping (CanvasScrollAction) -> Bool
    ) -> some View {
        background(CanvasScrollWheelAnchor(enabled: enabled, onAction: onAction))
    }
}

private struct CanvasScrollWheelAnchor: NSViewRepresentable {
    let enabled: Bool
    let onAction: (CanvasScrollAction) -> Bool

    func makeNSView(context: Context) -> CanvasScrollWheelAnchorView {
        let view = CanvasScrollWheelAnchorView()
        view.isEnabled = enabled
        view.onAction = onAction
        return view
    }

    func updateNSView(_ nsView: CanvasScrollWheelAnchorView, context: Context) {
        nsView.isEnabled = enabled
        nsView.onAction = onAction
    }

    static func dismantleNSView(_ nsView: CanvasScrollWheelAnchorView, coordinator: ()) {
        nsView.tearDownMonitor()
    }
}

/// Invisible, flipped, pass-through `NSView` that installs a local `.scrollWheel` event monitor
/// while attached to a window so SwiftUI `Canvas` views can support Cmd+scroll zoom and two-finger pan.
private final class CanvasScrollWheelAnchorView: NSView {
    var isEnabled: Bool = true
    var onAction: ((CanvasScrollAction) -> Bool)?

    private var monitor: Any?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDownMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScrollWheel(event)
        }
    }

    func tearDownMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, let win = window, event.window === win else { return event }
        guard !isHiddenOrHasHiddenAncestor else { return event }

        let local = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(local) else { return event }

        let mods = event.modifierFlags
        let input = CanvasScrollInput(
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isMomentum: !event.momentumPhase.isEmpty,
            command: mods.contains(.command),
            control: mods.contains(.control),
            shift: mods.contains(.shift),
            locationX: Double(local.x),
            locationY: Double(local.y)
        )
        let action = CanvasScrollLogic.interpret(input)
        guard action != .ignore else {
            // Swallow the momentum tail of a Cmd/Ctrl+scroll zoom gesture so surrounding views don't scroll.
            return (input.command || input.control) ? nil : event
        }
        guard let onAction else { return event }
        return onAction(action) ? nil : event
    }
}
