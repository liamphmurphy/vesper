import AppKit
import SwiftUI
import VesperCore

/// Floating AppKit tooltip panel shared across toolbar and sidebar icon controls.
///
/// SwiftUI's `.help()` on macOS attaches AppKit's native tooltip tracking rects to backing views
/// that frequently drop or reset on `.buttonStyle(.plain)`, borderless `Menu` buttons, and
/// reactive sidebar refreshes. Presenting a single non-activating child `NSPanel` from an
/// `NSTrackingArea` keeps hover tooltips responsive, unclipped by `NSSplitView` boundaries, and
/// above native sibling controls such as `NSSegmentedControl` and `NSTextField`.
@MainActor
final class HoverTooltipPresenter {
    static let shared = HoverTooltipPresenter()

    private let requiresKeyWindow: Bool
    private let verifiesMouseInside: Bool
    private let delayOverrideMs: Int?
    private let nowMs: () -> Int

    private var activeOwnerID: UUID?
    private var panel: NSPanel?
    private var activeHint: String?
    private var pendingTask: Task<Void, Never>?
    private var lastDismissedAtMs: Int?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(
        requiresKeyWindow: Bool = true,
        verifiesMouseInside: Bool = true,
        delayOverrideMs: Int? = nil,
        nowMs: @escaping () -> Int = { Int(ProcessInfo.processInfo.systemUptime * 1000) }
    ) {
        self.requiresKeyWindow = requiresKeyWindow
        self.verifiesMouseInside = verifiesMouseInside
        self.delayOverrideMs = delayOverrideMs
        self.nowMs = nowMs
    }

    var isVisible: Bool {
        panel != nil
    }

    var currentText: String? {
        guard let panel else { return nil }
        return panel.accessibilityLabel()
    }

    var currentHint: String? {
        guard panel != nil else { return nil }
        return activeHint
    }

    func mouseEntered(
        ownerID: UUID,
        text: String,
        hint: String?,
        anchorView: NSView,
        placement: TooltipPlacement = .below
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if activeOwnerID == ownerID { dismiss() }
            return
        }

        pendingTask?.cancel()
        pendingTask = nil
        activeOwnerID = ownerID
        installDismissHooks(for: anchorView.window)

        let elapsed = lastDismissedAtMs.map { nowMs() - $0 }
        let delayMs = delayOverrideMs ?? HoverTooltipLogic.delayMs(
            isCurrentlyVisible: panel != nil,
            elapsedSinceDismissMs: elapsed
        )

        if delayMs <= 0 {
            showIfStillHovered(ownerID: ownerID, text: trimmed, hint: hint, anchorView: anchorView, placement: placement)
            return
        }

        pendingTask = Task { @MainActor [weak self, weak anchorView] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, let self, let anchorView else { return }
            self.showIfStillHovered(ownerID: ownerID, text: trimmed, hint: hint, anchorView: anchorView, placement: placement)
        }
    }

    func update(
        ownerID: UUID,
        text: String,
        hint: String?,
        anchorView: NSView,
        placement: TooltipPlacement = .below
    ) {
        guard activeOwnerID == ownerID, panel != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }
        showIfStillHovered(ownerID: ownerID, text: trimmed, hint: hint, anchorView: anchorView, placement: placement)
    }

    func mouseExited(ownerID: UUID) {
        guard activeOwnerID == ownerID else { return }
        dismiss()
    }

    func dismiss() {
        pendingTask?.cancel()
        pendingTask = nil
        activeOwnerID = nil
        activeHint = nil
        if let existing = panel {
            existing.parent?.removeChildWindow(existing)
            existing.orderOut(nil)
            panel = nil
            lastDismissedAtMs = nowMs()
        }
        removeDismissHooks()
    }

    private func showIfStillHovered(
        ownerID: UUID,
        text: String,
        hint: String?,
        anchorView: NSView,
        placement: TooltipPlacement
    ) {
        guard activeOwnerID == ownerID else { return }
        guard let window = anchorView.window, !anchorView.isHiddenOrHasHiddenAncestor else {
            dismiss()
            return
        }
        if requiresKeyWindow && !window.isKeyWindow {
            dismiss()
            return
        }

        let rectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorScreenRect = window.convertToScreen(rectInWindow)
        guard !anchorScreenRect.isEmpty else {
            dismiss()
            return
        }
        if verifiesMouseInside && !anchorScreenRect.contains(NSEvent.mouseLocation) {
            dismiss()
            return
        }

        let content = buildContentView(text: text, hint: hint, appearance: window.effectiveAppearance)
        let size = content.fittingSize
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = HoverTooltipLogic.origin(
            anchor: TooltipRect(
                x: anchorScreenRect.minX,
                y: anchorScreenRect.minY,
                width: anchorScreenRect.width,
                height: anchorScreenRect.height
            ),
            tooltipSize: TooltipSize(width: size.width, height: size.height),
            visibleFrame: TooltipRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: screenFrame.width,
                height: screenFrame.height
            ),
            gap: placement == .leading ? 8 : 6,
            placement: placement
        )
        let frame = NSRect(x: origin.x, y: origin.y, width: size.width, height: size.height)

        let targetPanel: NSPanel
        if let existing = panel {
            if existing.parent !== window {
                existing.parent?.removeChildWindow(existing)
                window.addChildWindow(existing, ordered: .above)
            }
            targetPanel = existing
        } else {
            let created = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = true
            created.ignoresMouseEvents = true
            created.hidesOnDeactivate = true
            created.level = .popUpMenu
            created.collectionBehavior = [.transient, .ignoresCycle]
            window.addChildWindow(created, ordered: .above)
            panel = created
            targetPanel = created
        }

        activeHint = hint
        targetPanel.appearance = window.effectiveAppearance
        targetPanel.contentView = content
        targetPanel.setAccessibilityLabel(text)
        targetPanel.setFrame(frame, display: true)
        targetPanel.orderFront(nil)
    }

    private func buildContentView(text: String, hint: String?, appearance: NSAppearance) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping

        var arranged: [NSView] = [label]
        if let hint, !hint.isEmpty {
            let hintLabel = NSTextField(labelWithString: hint)
            hintLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            hintLabel.textColor = .secondaryLabelColor
            hintLabel.lineBreakMode = .byClipping
            arranged.append(hintLabel)
        }

        let stack = NSStackView(views: arranged)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.appearance = appearance
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 6
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        appearance.performAsCurrentDrawingAppearance {
            effect.layer?.borderColor = NSColor.separatorColor.cgColor
        }

        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        effect.layoutSubtreeIfNeeded()
        return effect
    }

    private func installDismissHooks(for window: NSWindow?) {
        removeDismissHooks()

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
            return event
        }

        let center = NotificationCenter.default
        let dismissOnNotify: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main,
            using: dismissOnNotify
        ))
        observers.append(center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main,
            using: dismissOnNotify
        ))
        if let window {
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main,
                using: dismissOnNotify
            ))
            observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main,
                using: dismissOnNotify
            ))
        }
    }

    private func removeDismissHooks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}

/// Transparent AppKit tracking view that observes mouse entry/exit without intercepting clicks or menus.
final class HoverTrackingNSView: NSView {
    let ownerID = UUID()
    var text: String
    var hint: String?
    var placement: TooltipPlacement
    var presenter: HoverTooltipPresenter
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(
        text: String,
        hint: String?,
        placement: TooltipPlacement = .below,
        presenter: HoverTooltipPresenter = .shared,
        onHoverChange: ((Bool) -> Void)? = nil
    ) {
        self.text = text
        self.hint = hint
        self.placement = placement
        self.presenter = presenter
        self.onHoverChange = onHoverChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
        presenter.mouseEntered(ownerID: ownerID, text: text, hint: hint, anchorView: self, placement: placement)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
        presenter.mouseExited(ownerID: ownerID)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            onHoverChange?(false)
            presenter.mouseExited(ownerID: ownerID)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

private struct HoverTooltipAnchor: NSViewRepresentable {
    let text: String
    let hint: String?
    let placement: TooltipPlacement
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(text: text, hint: hint, placement: placement, onHoverChange: onHoverChange)
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        let changed = nsView.text != text || nsView.hint != hint || nsView.placement != placement
        nsView.text = text
        nsView.hint = hint
        nsView.placement = placement
        nsView.onHoverChange = onHoverChange
        if changed {
            nsView.presenter.update(ownerID: nsView.ownerID, text: text, hint: hint, anchorView: nsView, placement: placement)
        }
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let hint: String?
    let placement: TooltipPlacement
    let highlightHover: Bool
    let cornerRadius: CGFloat

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(highlightHover && isHovered ? Color.primary.opacity(0.08) : .clear)
            )
            .background(
                HoverTooltipAnchor(text: text, hint: hint, placement: placement) { hovered in
                    isHovered = hovered
                }
            )
            .accessibilityLabel(text)
    }
}

extension View {
    /// Reliable floating hover tooltip backed by an AppKit `NSPanel` and `NSTrackingArea`.
    func hoverTooltip(
        _ text: String,
        hint: String? = nil,
        placement: TooltipPlacement = .below,
        highlightHover: Bool = false,
        cornerRadius: CGFloat = 5
    ) -> some View {
        modifier(HoverTooltipModifier(
            text: text,
            hint: hint,
            placement: placement,
            highlightHover: highlightHover,
            cornerRadius: cornerRadius
        ))
    }
}
