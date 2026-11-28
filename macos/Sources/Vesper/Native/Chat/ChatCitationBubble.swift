import AppKit
import Observation
import SwiftUI
import VesperCore

/// Presents a rectangular floating citation card anchored directly to the clicked inline `[n]`
/// citation badge, styled like the rail's GitHub notification and inbox popovers with a spring
/// bubble-open animation and a direct link to the source.
@MainActor
final class ChatCitationBubblePresenter {
    static let shared = ChatCitationBubblePresenter()

    static let cardWidth: CGFloat = 300
    /// Transparent margin around the card inside the borderless panel so the drop shadow and
    /// spring overshoot never clip against the window bounds.
    static let panelPadding: CGFloat = 20

    struct ActiveKey: Equatable {
        let messageId: String
        let number: Int
    }

    @Observable
    @MainActor
    final class BubbleAnimationState {
        var isOpen = false
    }

    private var panel: NSPanel?
    private var activeKey: ActiveKey?
    private var animationState: BubbleAnimationState?
    private var closeTask: Task<Void, Never>?
    private var monitorInstallTask: Task<Void, Never>?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel != nil }
    var currentKey: ActiveKey? { activeKey }

    func toggle(
        messageId: String,
        source: ChatListedSource,
        previewRequest: APIRequest<API.LinkPreviews>?,
        anchor: MarkdownLinkAnchor?,
        context: NativeScreenContext,
        theme: ThemeTokens
    ) {
        let number = source.number ?? 0
        let key = ActiveKey(messageId: messageId, number: number)
        if activeKey == key, panel != nil {
            dismiss(animated: true)
            return
        }
        show(
            key: key,
            source: source,
            previewRequest: previewRequest,
            anchor: anchor,
            context: context,
            theme: theme
        )
    }

    func dismiss(animated: Bool = true) {
        closeTask?.cancel()
        closeTask = nil
        monitorInstallTask?.cancel()
        monitorInstallTask = nil
        removeDismissHooks()

        guard let existing = panel else {
            activeKey = nil
            animationState = nil
            return
        }

        activeKey = nil
        if !animated {
            tearDown(panel: existing)
            return
        }

        if let state = animationState {
            withAnimation(.easeIn(duration: 0.13)) {
                state.isOpen = false
            }
        }
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            if self.panel === existing {
                self.tearDown(panel: existing)
            }
        }
    }

    private func show(
        key: ActiveKey,
        source: ChatListedSource,
        previewRequest: APIRequest<API.LinkPreviews>?,
        anchor: MarkdownLinkAnchor?,
        context: NativeScreenContext,
        theme: ThemeTokens
    ) {
        if let existing = panel {
            tearDown(panel: existing)
        }
        closeTask?.cancel()
        closeTask = nil
        monitorInstallTask?.cancel()
        monitorInstallTask = nil
        removeDismissHooks()

        let parentWindow = anchor?.window ?? NSApp.keyWindow
        let anchorRect: CGRect
        if let rect = anchor?.screenRect, !rect.isEmpty {
            anchorRect = rect
        } else {
            let mouse = NSEvent.mouseLocation
            anchorRect = CGRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16)
        }

        let visibleFrame = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let state = BubbleAnimationState()
        let pad = Self.panelPadding

        // Measure the rectangular card's natural height before placing it so it hugs its content
        // snugly like the rail's inbox and GitHub notification popovers.
        let initialPlacement = CitationBubblePlacement.place(
            anchor: TooltipRect(
                x: anchorRect.minX,
                y: anchorRect.minY,
                width: anchorRect.width,
                height: anchorRect.height
            ),
            bubbleSize: TooltipSize(width: Self.cardWidth, height: 140),
            visibleFrame: TooltipRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        )

        func makeView(placement: CitationBubblePlacement.Placement) -> some View {
            ChatCitationBubbleView(
                source: source,
                previewRequest: previewRequest,
                placement: placement,
                animationState: state,
                onDismiss: { [weak self] in self?.dismiss(animated: true) }
            )
            .environment(context)
            .environment(\.vesperTheme, theme)
        }

        let measuringHost = NSHostingController(rootView: makeView(placement: initialPlacement))
        let measured = measuringHost.view.fittingSize
        let cardHeight = max(108, measured.height - pad * 2)

        let placement = CitationBubblePlacement.place(
            anchor: TooltipRect(
                x: anchorRect.minX,
                y: anchorRect.minY,
                width: anchorRect.width,
                height: anchorRect.height
            ),
            bubbleSize: TooltipSize(width: Self.cardWidth, height: cardHeight),
            visibleFrame: TooltipRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: visibleFrame.height
            )
        )

        let panelFrame = NSRect(
            x: placement.origin.x - pad,
            y: placement.origin.y - pad,
            width: Self.cardWidth + pad * 2,
            height: cardHeight + pad * 2
        )

        let host = NSHostingController(rootView: makeView(placement: placement))
        let created = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.ignoresMouseEvents = false
        created.hidesOnDeactivate = true
        created.level = .popUpMenu
        created.collectionBehavior = [.transient, .ignoresCycle]
        created.appearance = parentWindow?.effectiveAppearance
        created.contentViewController = host
        created.setFrame(panelFrame, display: true)

        if let parentWindow {
            parentWindow.addChildWindow(created, ordered: .above)
        }
        created.orderFront(nil)

        self.panel = created
        self.activeKey = key
        self.animationState = state

        // Trigger the spring bubble-open on the next main-actor tick so SwiftUI sees the
        // initial collapsed state first, and install the click-outside monitor after the
        // opening click has finished dispatching.
        monitorInstallTask = Task { @MainActor [weak self, weak parentWindow, weak created] in
            guard !Task.isCancelled, let self, let created, self.panel === created else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                state.isOpen = true
            }
            self.installDismissHooks(for: parentWindow)
        }
    }

    private func tearDown(panel existing: NSPanel) {
        existing.parent?.removeChildWindow(existing)
        existing.orderOut(nil)
        if panel === existing {
            panel = nil
            animationState = nil
        }
    }

    private func installDismissHooks(for parentWindow: NSWindow?) {
        removeDismissHooks()

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            let isKeyDown = event.type == .keyDown
            let keyCode = isKeyDown ? event.keyCode : 0
            let consume = MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return false }
                if isKeyDown {
                    if keyCode == 53 { // Escape
                        self.dismiss(animated: true)
                        return true
                    }
                    return false
                }
                if !panel.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss(animated: true)
                }
                return false
            }
            return consume ? nil : event
        }

        let center = NotificationCenter.default
        let dismissOnNotify: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(animated: false)
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
        if let parentWindow {
            for name in [
                NSWindow.willCloseNotification,
                NSWindow.didResizeNotification,
                NSWindow.didResignKeyNotification,
            ] {
                observers.append(center.addObserver(
                    forName: name,
                    object: parentWindow,
                    queue: .main,
                    using: dismissOnNotify
                ))
            }
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

/// Rectangular floating popover card matching the rail's inbox and GitHub notification boxes:
/// header bar, hairline divider, source title + URL/path, and a full-width footer action row,
/// animated out of the clicked citation number.
private struct ChatCitationBubbleView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let source: ChatListedSource
    let previewRequest: APIRequest<API.LinkPreviews>?
    let placement: CitationBubblePlacement.Placement
    let animationState: ChatCitationBubblePresenter.BubbleAnimationState
    let onDismiss: () -> Void

    @State private var hoveringFooter = false
    @State private var hoveringLink = false

    private var preview: API.LinkPreview? {
        guard let previewRequest, !source.url.isEmpty else { return nil }
        let previews = context.store.entry(previewRequest).data?.previews ?? []
        return previews.first(where: { $0.url == source.url })
    }

    private var originAnchor: UnitPoint {
        UnitPoint(x: placement.anchorUnitX, y: placement.anchorUnitY)
    }

    private func openSource() {
        onDismiss()
        guard let dest = CitationBubblePlacement.destination(source: source) else { return }
        switch dest {
        case .external(let url):
            context.openExternal(url)
        case .knowledgePath(let path):
            context.navigate(path)
        }
    }

    var body: some View {
        let p = theme.palette
        let title = CitationBubblePlacement.displayTitle(source: source, previewTitle: preview?.title)
        let destinationLabel = CitationBubblePlacement.displayDestination(source: source, previewSite: preview?.site)
        let isWeb = !source.url.isEmpty
        let hasDestination = CitationBubblePlacement.destination(source: source) != nil

        VStack(alignment: .leading, spacing: 0) {
            // Header strip matching rail popovers
            HStack(spacing: 6) {
                if let n = source.number {
                    Text("\(n)")
                        .font(.system(size: theme.pointSize(.micro), weight: .bold, design: .monospaced))
                        .foregroundStyle(p.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(p.selected, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Image(systemName: isWeb ? "globe" : "doc.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.tertiaryText)
                Text(destinationLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close citation")
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 7)

            Divider()

            // Source name & link
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if hasDestination {
                    Button {
                        openSource()
                    } label: {
                        Text(isWeb ? source.url : destinationLabel)
                            .font(.system(size: 11, design: isWeb ? .monospaced : .default))
                            .foregroundStyle(p.accent)
                            .underline(hoveringLink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringLink = $0 }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if hasDestination {
                Divider()

                // Full-width footer row consistent with NeedsYouPopover ("Show all in Inbox >")
                Button {
                    openSource()
                } label: {
                    HStack {
                        Text(isWeb ? "Open link" : "Open page")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.text)
                        Spacer()
                        Image(systemName: isWeb ? "arrow.up.right" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(hoveringFooter ? p.selected.opacity(0.6) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringFooter = $0 }
            }
        }
        .frame(width: ChatCitationBubblePresenter.cardWidth, alignment: .leading)
        .background(
            theme.swiftUIColor("surface-raised", fallback: p.surface),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(p.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(theme.mode == .dark ? 0.42 : 0.16), radius: 14, x: 0, y: 6)
        .scaleEffect(animationState.isOpen ? 1.0 : 0.24, anchor: originAnchor)
        .opacity(animationState.isOpen ? 1.0 : 0.0)
        .offset(y: animationState.isOpen ? 0 : (placement.placedAbove ? 6 : -6))
        .padding(ChatCitationBubblePresenter.panelPadding)
    }
}
