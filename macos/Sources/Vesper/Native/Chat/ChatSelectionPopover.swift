import AppKit
import SwiftUI
import VesperCore

/// Presents a compact floating action pill (`Quote · Thread · Explain · Clip`) directly above
/// highlighted text inside a chat `MarkdownTextView`.
@MainActor
final class ChatSelectionPopoverPresenter {
    static let shared = ChatSelectionPopoverPresenter()

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func show(
        selection: String,
        anchor: MarkdownLinkAnchor,
        theme: ThemeTokens,
        onAction: @escaping @MainActor (ChatSelectionAction, String) -> Void
    ) {
        dismiss()
        guard let cleaned = ChatSelectionLogic.cleanSelection(selection) else { return }

        let parentWindow = anchor.window ?? NSApp.keyWindow
        let visibleFrame = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let pillView = ChatSelectionPillView(theme: theme) { [weak self] action in
            self?.dismiss()
            onAction(action, cleaned)
        }
        let host = NSHostingController(rootView: pillView)
        let size = host.view.fittingSize
        let width = max(250, ceil(size.width))
        let height = max(34, ceil(size.height))

        let preferredX = anchor.screenRect.midX - width / 2
        let clampedX = max(visibleFrame.minX + 8, min(preferredX, visibleFrame.maxX - width - 8))
        var y = anchor.screenRect.maxY + 8
        if y + height > visibleFrame.maxY - 8 {
            y = max(visibleFrame.minY + 8, anchor.screenRect.minY - height - 8)
        }
        let frame = NSRect(x: clampedX, y: y, width: width, height: height)

        let created = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.ignoresMouseEvents = false
        created.hidesOnDeactivate = true
        created.level = .popUpMenu
        created.collectionBehavior = [.transient, .ignoresCycle]
        created.appearance = parentWindow?.effectiveAppearance
        created.contentViewController = host
        created.setFrame(frame, display: true)

        if let parentWindow {
            parentWindow.addChildWindow(created, ordered: .above)
        }
        created.orderFront(nil)
        panel = created
        installDismissHooks(for: parentWindow)
    }

    func dismiss() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers = []
        if let existing = panel {
            existing.parent?.removeChildWindow(existing)
            existing.orderOut(nil)
            panel = nil
        }
    }

    private func installDismissHooks(for parentWindow: NSWindow?) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            let isKey = event.type == .keyDown
            let keyCode = isKey ? event.keyCode : 0
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if isKey {
                    if keyCode == 53 { self.dismiss() }
                    return
                }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                }
            }
            return event
        }
        if let parentWindow {
            let center = NotificationCenter.default
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: parentWindow, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss() }
                })
            }
        }
    }
}

private struct ChatSelectionPillView: View {
    let theme: ThemeTokens
    let onSelect: @MainActor (ChatSelectionAction) -> Void

    var body: some View {
        let p = theme.palette
        HStack(spacing: 2) {
            ForEach(ChatSelectionAction.allCases) { action in
                ChatSelectionActionButton(action: action, theme: theme) {
                    onSelect(action)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            theme.swiftUIColor("surface-raised", fallback: p.surface),
            in: Capsule()
        )
        .overlay(Capsule().stroke(p.border))
        .shadow(color: Color.black.opacity(theme.mode == .dark ? 0.36 : 0.14), radius: 10, y: 4)
        .fixedSize()
    }
}

private struct ChatSelectionActionButton: View {
    let action: ChatSelectionAction
    let theme: ThemeTokens
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        let p = theme.palette
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(action.label)
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
            }
            .foregroundStyle(isHovered ? p.accent : p.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? p.hover : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovered)
        .help(action.menuTitle)
    }
}
