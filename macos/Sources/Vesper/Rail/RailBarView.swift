import AppKit
import SwiftUI
import VesperCore

/// The native right rail: 44pt, sidebar material, at the trailing edge of a window's content. It
/// draws the active tab's `RailModel` (top group, flexible space, middle group, foot group) and
/// sends `rail.action` back; the Needs-you button opens the shell's own popover instead.
@MainActor
final class RailBarView: NSVisualEffectView {
    static let width: CGFloat = 44

    private let send: (NativeCommand) -> Void
    private let services: () -> SystemServices?
    private let topStack = RailBarView.makeStack()
    private let middleStack = RailBarView.makeStack()
    private let footStack = RailBarView.makeStack()
    private var buttons: [String: RailButton] = [:]
    private var needsYou: NeedsYouPopover?
    private let menuPopover = RailMenuPopover()
    private var currentTheme: ThemeTokens = ThemeTokens(mode: .dark)

    init(send: @escaping (NativeCommand) -> Void, services: @escaping () -> SystemServices?) {
        self.send = send
        self.services = services
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Right rail")

        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false
        // A separator box has an intrinsic height of 1 and hugs at 750, above the window's
        // stay-put priority (500). Pinned to the rail's full height, that would shrink the whole
        // window to the rail's minimum height (and keep it there in full screen).
        edge.setContentHuggingPriority(.defaultLow, for: .vertical)
        addSubview(edge)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let column = NSStackView(views: [topStack, spacer, middleStack, divider, footStack])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 24),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        return stack
    }

    /// Shows the page's rail, or nothing when it has none.
    func apply(_ model: RailModel?, theme: ThemeTokens? = nil) {
        if let theme { currentTheme = theme }
        guard let model else {
            needsYou?.close()
            isHidden = true
            return
        }
        isHidden = false
        let resolvedTheme = currentTheme
        var used = Set<String>()
        func sync(_ items: [RailItem], into stack: NSStackView) {
            let views = items.map { item -> RailButton in
                let button = buttons[item.id] ?? RailButton { [weak self] button in self?.clicked(button) }
                buttons[item.id] = button
                used.insert(item.id)
                button.configure(item, theme: resolvedTheme)
                return button
            }
            stack.setViews(views, in: .top)
            stack.isHidden = views.isEmpty
        }
        sync(model.top, into: topStack)
        sync(model.middle, into: middleStack)
        sync(model.foot, into: footStack)
        for id in buttons.keys where !used.contains(id) { buttons[id] = nil }
    }

    private func clicked(_ button: RailButton) {
        guard let item = button.item else { return }
        if item.kind == .needsYou {
            let popover = needsYou ?? NeedsYouPopover(services: services, navigate: { [weak self] path in self?.send(.navigate(path: path)) })
            needsYou = popover
            popover.toggle(relativeTo: button)
        } else if let menu = item.menu, !menu.isEmpty {
            // A popover that flies out to the left like Needs-you; clicking the same button again closes it.
            if menuPopover.isShown {
                let same = menuPopover.itemId == item.id
                menuPopover.close()
                if same { return }
            }
            let itemId = item.id
            menuPopover.show(item, relativeTo: button) { [weak self] chosen in
                self?.send(.railAction(itemId: itemId, menuItemId: chosen))
            }
        } else {
            send(.railAction(itemId: item.id, menuItemId: nil))
        }
    }
}

/// One rail button: an icon or avatar, an optional badge (count capsule or dot), a status dot.
@MainActor
final class RailButton: NSButton {
    private(set) var item: RailItem?
    private let onClick: (RailButton) -> Void
    private let activeBar = NSView()
    private let badgeView = RailBadgeView()
    private let statusView = RailStatusDot()
    private var hovering = false
    private var theme: ThemeTokens = ThemeTokens(mode: .dark)
    private var avatarKey: String?
    private var avatarTask: Task<Void, Never>?

    static let size: CGFloat = 32

    init(onClick: @escaping (RailButton) -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 7
        clipsToBounds = false
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false

        activeBar.wantsLayer = true
        activeBar.layer?.cornerRadius = 1.25
        activeBar.isHidden = true

        for sub in [activeBar, badgeView, statusView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            activeBar.widthAnchor.constraint(equalToConstant: 2.5),
            activeBar.heightAnchor.constraint(equalToConstant: 16),
            activeBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            activeBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4.5),
            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: -2),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
            statusView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            statusView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { onClick(self) }

    func configure(_ item: RailItem, theme: ThemeTokens = ThemeTokens(mode: .dark)) {
        self.item = item
        self.theme = theme
        toolTip = item.label
        setAccessibilityLabel(item.label)
        isEnabled = item.disabled != true
        alphaValue = isEnabled ? 1 : 0.4
        badgeView.configure(item.badge, theme: theme)
        statusView.configure(item.status, theme: theme, pulse: item.status == .accent)
        if let avatar = item.avatar {
            showAvatar(avatar)
        } else {
            avatarTask?.cancel()
            avatarKey = nil
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: item.active == true ? .medium : .regular)
            image = SidebarIcons.image(item.icon ?? "circle").withSymbolConfiguration(config)
            image?.isTemplate = true
        }
        updateAppearance()
    }

    private func showAvatar(_ avatar: Avatar) {
        let key = "\(avatar.initials)|\(avatar.color ?? "")|\(avatar.imageUrl ?? "")"
        guard key != avatarKey else { return }
        avatarKey = key
        image = Self.avatarImage(avatar, picture: nil)
        avatarTask?.cancel()
        guard let url = avatar.imageUrl else { return }
        avatarTask = Task { @MainActor [weak self] in
            guard let picture = await AvatarImages.shared.image(for: url), !Task.isCancelled else { return }
            self?.image = Self.avatarImage(avatar, picture: picture)
        }
    }

    /// A 24pt circle: the picture, else the initials on the avatar's color.
    static func avatarImage(_ avatar: Avatar, picture: NSImage?) -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let clip = NSBezierPath(ovalIn: rect)
            if let picture {
                NSGraphicsContext.saveGraphicsState()
                clip.addClip()
                picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                (avatar.color.flatMap { NSColor(Color(cssHex: $0) ?? .gray) } ?? NSColor.systemGray).setFill()
                clip.fill()
                let text = NSAttributedString(
                    string: String(avatar.initials.prefix(2)),
                    attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black.withAlphaComponent(0.75)])
                let box = text.size()
                text.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    var isActiveBarVisible: Bool { !activeBar.isHidden }

    private func updateAppearance() {
        let isActive = item?.active == true
        let accent = theme.nsColor("accent", fallback: .controlAccentColor)
        contentTintColor = isActive ? accent : (hovering ? .labelColor : .secondaryLabelColor)
        activeBar.isHidden = !isActive
        effectiveAppearance.performAsCurrentDrawingAppearance {
            activeBar.layer?.backgroundColor = accent.cgColor
            let fill: NSColor = isActive
                ? accent.withAlphaComponent(0.14)
                : hovering && isEnabled ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
            layer?.backgroundColor = fill.cgColor
        }
        setAccessibilitySelected(isActive)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateAppearance() }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
}

/// A count capsule, or a dot when there is no text.
@MainActor
private final class RailBadgeView: NSView {
    private var text: String?
    private var color: NSColor = .systemRed
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        widthConstraint = widthAnchor.constraint(equalToConstant: 8)
        heightConstraint = heightAnchor.constraint(equalToConstant: 8)
        widthConstraint?.isActive = true
        heightConstraint?.isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ badge: AreaBadge?, theme: ThemeTokens) {
        guard let badge else { isHidden = true; return }
        isHidden = false
        text = badge.text.flatMap { $0.isEmpty ? nil : $0 }
        let tone = badge.tone ?? .neutral
        color = Self.resolvedColor(for: tone, theme: theme)
        if let text {
            let width = (text as NSString).size(withAttributes: [.font: Self.font]).width
            widthConstraint?.constant = max(17, ceil(width) + 11)
            heightConstraint?.constant = 17
        } else {
            widthConstraint?.constant = 9
            heightConstraint?.constant = 9
        }
        needsDisplay = true
    }

    private static func resolvedColor(for tone: Tone, theme: ThemeTokens) -> NSColor {
        switch tone {
        case .neutral:
            return .secondaryLabelColor
        case .accent:
            return theme.nsColor("accent", fallback: .controlAccentColor)
        case .human:
            return theme.nsColor("state-human", fallback: theme.nsColor("accent", fallback: .systemOrange))
        case .done:
            return theme.nsColor("state-done", fallback: .systemGreen)
        case .blocked, .danger:
            return theme.nsColor("pill-blocked-fg", fallback: .systemRed)
        case .warning:
            return theme.nsColor("state-progress", fallback: .systemOrange)
        }
    }

    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)

    override func draw(_ dirtyRect: NSRect) {
        // Cutout ring separates the badge cleanly from the underlying rail glyph.
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        let inner = bounds.insetBy(dx: 1.5, dy: 1.5)
        color.setFill()
        NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
        guard let text else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2), withAttributes: attrs)
    }
}

/// A small status dot on the icon's corner (a harness's health or live running activity).
@MainActor
private final class RailStatusDot: NSView {
    private var color: NSColor?
    private static let pulseKey = "vesper.rail.status.pulse"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ tone: Tone?, theme: ThemeTokens, pulse: Bool = false) {
        isHidden = tone == nil
        switch tone {
        case .accent:
            color = theme.nsColor("accent", fallback: .controlAccentColor)
        case .done:
            color = theme.nsColor("state-done", fallback: .systemGreen)
        case .blocked, .danger:
            color = theme.nsColor("pill-blocked-fg", fallback: .systemRed)
        case .human, .warning:
            color = theme.nsColor("state-human", fallback: .systemOrange)
        case .neutral:
            color = .secondaryLabelColor
        case nil:
            color = nil
        }
        needsDisplay = true

        let shouldPulse = pulse && tone != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldPulse {
            if layer?.animation(forKey: Self.pulseKey) == nil {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 1.0
                anim.toValue = 0.38
                anim.duration = 0.95
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(anim, forKey: Self.pulseKey)
            }
        } else {
            layer?.removeAnimation(forKey: Self.pulseKey)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
    }
}
