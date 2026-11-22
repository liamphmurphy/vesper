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
    func apply(_ model: RailModel?) {
        guard let model else {
            needsYou?.close()
            isHidden = true
            return
        }
        isHidden = false
        var used = Set<String>()
        func sync(_ items: [RailItem], into stack: NSStackView) {
            let views = items.map { item -> RailButton in
                let button = buttons[item.id] ?? RailButton { [weak self] button in self?.clicked(button) }
                buttons[item.id] = button
                used.insert(item.id)
                button.configure(item)
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
    private let badgeView = RailBadgeView()
    private let statusView = RailStatusDot()
    private var hovering = false
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
        for sub in [badgeView, statusView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: -3),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            statusView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            statusView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { onClick(self) }

    func configure(_ item: RailItem) {
        self.item = item
        toolTip = item.label
        setAccessibilityLabel(item.label)
        isEnabled = item.disabled != true
        alphaValue = isEnabled ? 1 : 0.4
        badgeView.configure(item.badge)
        statusView.configure(item.status)
        if let avatar = item.avatar {
            showAvatar(avatar)
        } else {
            avatarTask?.cancel()
            avatarKey = nil
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
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

    private func updateAppearance() {
        contentTintColor = item?.active == true ? .labelColor : .secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor = item?.active == true
                ? NSColor.labelColor.withAlphaComponent(0.14)
                : hovering && isEnabled ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
            layer?.backgroundColor = fill.cgColor
        }
        setAccessibilitySelected(item?.active == true)
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

    func configure(_ badge: AreaBadge?) {
        guard let badge else { isHidden = true; return }
        isHidden = false
        text = badge.text.flatMap { $0.isEmpty ? nil : $0 }
        let tone = badge.tone ?? .neutral
        color = tone == .neutral ? .secondaryLabelColor : NSColor(tone.color)
        if let text {
            let width = (text as NSString).size(withAttributes: [.font: Self.font]).width
            widthConstraint?.constant = max(15, ceil(width) + 9)
            heightConstraint?.constant = 15
        } else {
            widthConstraint?.constant = 8
            heightConstraint?.constant = 8
        }
        needsDisplay = true
    }

    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        guard let text else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

/// A small status dot on the icon's corner (a harness's health).
@MainActor
private final class RailStatusDot: NSView {
    private var color: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ tone: Tone?) {
        isHidden = tone == nil
        color = tone.map { NSColor($0.color) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
    }
}
