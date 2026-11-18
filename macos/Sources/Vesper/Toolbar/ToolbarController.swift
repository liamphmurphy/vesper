import AppKit
import VesperCore

/// The unified toolbar: sidebar toggle, back/forward (navigational, so they sit before the window
/// title), the title's own menu, the page's items, then New Chat, companion toggle and search.
/// Title and subtitle are the window's.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate {
    private static let nav = NSToolbarItem.Identifier("vesper.nav")
    private static let tabStrip = NSToolbarItem.Identifier("vesper.tabs")
    private static let search = NSToolbarItem.Identifier("vesper.search")
    private static let newChat = NSToolbarItem.Identifier("vesper.newChat")
    private static let companion = NSToolbarItem.Identifier("vesper.companion")
    private static let titleMenu = NSToolbarItem.Identifier("vesper.titleMenu")
    private static let titleLabel = NSToolbarItem.Identifier("vesper.titleLabel")
    private static let pagePrefix = "vesper.page."

    private weak var owner: MainWindowController?
    let toolbar: NSToolbar
    private var navItem: NSToolbarItemGroup?
    private var pageItems: [String: ToolbarItem] = [:]
    private var shownItems: [ToolbarItem] = []
    private var shownTitleMenu: [MenuItem]?
    private var titleField: NSTextField?
    private var subtitleField: NSTextField?
    private var generation = 0

    init(owner: MainWindowController) {
        self.owner = owner
        toolbar = NSToolbar(identifier: owner.compact ? "vesper.compact" : "vesper.main")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        // Everything follows the window's active tab: switching tabs rebinds the toolbar to its state.
        track({ [weak owner] in (owner?.state.canGoBack ?? false, owner?.state.canGoForward ?? false) }) { [weak self] back, forward in
            self?.navItem?.subitems.first?.isEnabled = back
            self?.navItem?.subitems.last?.isEnabled = forward
        }
        track({ [weak owner] in owner?.state.toolbarItems ?? [] }) { [weak self] items in
            guard let self, items != self.shownItems else { return }
            self.shownItems = items
            self.rebuildPageItems()
        }
        track({ [weak owner] in (owner?.content.displayTitle ?? "", owner?.state.subtitle ?? "") }) { [weak self] title, subtitle in
            self?.titleField?.stringValue = title
            self?.subtitleField?.stringValue = subtitle
            self?.subtitleField?.isHidden = subtitle.isEmpty
        }
        track({ [weak owner] in owner?.state.titleMenu }) { [weak self] menu in
            let menu = (menu?.isEmpty ?? true) ? nil : menu
            guard let self, menu != self.shownTitleMenu else { return }
            self.shownTitleMenu = menu
            self.rebuildPageItems()
        }
        track({ [weak owner] in owner?.kind == .vesper }) { [weak self] isVesper in
            // A playground page has no bridge: New Chat, the companion and search have nobody to talk to.
            self?.pageOnlyItemsEnabled = isVesper
        }
    }

    private var pageOnlyItemsEnabled = true {
        didSet {
            for item in toolbar.items where [Self.newChat, Self.companion, Self.search].contains(item.itemIdentifier) {
                item.isEnabled = pageOnlyItemsEnabled
            }
        }
    }

    private var tabStripItem: NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: Self.tabStrip)
        item.label = "Tabs"
        item.paletteLabel = "Tabs"
        let host = owner
        let actions = TabStripActions(
            select: { [weak host] in host?.selectTab($0) },
            close: { [weak host] in host?.closeTab($0) },
            newTab: { [weak host] in host?.app.openNewTab(from: host?.window) },
            closeOthers: { [weak host] in host?.closeOtherTabs(than: $0) },
            closeToTheRight: { [weak host] in host?.closeTabsToTheRight(of: $0) },
            moveToNewWindow: { [weak host] tab in if let host { host.app.moveTabToNewWindow(tab, from: host) } },
            duplicate: { [weak host] tab in if let host { host.app.duplicateTab(tab, in: host) } },
            reopenClosed: { [weak host] in host?.app.reopenClosedTab(nextTo: host?.window) },
            canReopen: { [weak host] in host?.app.canReopenClosedTab ?? false },
            move: { [weak host] in host?.moveTab(from: $0, to: $1) })
        item.view = TabStripView.hostView(model: owner?.tabs ?? TabsModel(), actions: actions)
        item.visibilityPriority = .high
        return item
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if owner?.compact == true {
            return [Self.newChat, .toggleSidebar, .sidebarTrackingSeparator, Self.nav, Self.tabStrip, Self.companion, Self.search]
        }
        return [Self.newChat, .toggleSidebar, .sidebarTrackingSeparator, Self.nav, .flexibleSpace, Self.companion, Self.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.titleMenu, Self.titleLabel] + pageItems.keys.map { NSToolbarItem.Identifier($0) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.nav:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: [symbol("chevron.left"), symbol("chevron.right")],
                                           selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navigate(_:)))
            group.label = "Back/Forward"
            group.controlRepresentation = .expanded
            // Navigational items lead the toolbar, right after the sidebar's separator and before the window title.
            group.isNavigational = true
            group.subitems.first?.isEnabled = owner?.state.canGoBack ?? false
            group.subitems.last?.isEnabled = owner?.state.canGoForward ?? false
            navItem = group
            return group
        case Self.tabStrip:
            return tabStripItem
        case Self.search:
            return button(identifier, label: "Search", symbol: "magnifyingglass", tip: "Search (⌘K)", action: #selector(searchTapped))
        case Self.titleMenu:
            return makeTitleMenuItem(identifier)
        case Self.titleLabel:
            return makeTitleLabelItem(identifier)
        case Self.newChat:
            return button(identifier, label: "New Chat", symbol: "square.and.pencil", tip: "New Chat", action: #selector(newChatTapped))
        case Self.companion:
            return button(identifier, label: "Companion", symbol: "sidebar.right", tip: "Toggle companion", action: #selector(companionTapped))
        default:
            guard identifier.rawValue.hasPrefix(Self.pagePrefix), let item = pageItems[identifier.rawValue] else { return nil }
            return makePageItem(identifier, item)
        }
    }

    // MARK: Fixed items

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private func button(_ id: NSToolbarItem.Identifier, label: String, symbol name: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = symbol(name)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        let web = owner?.content.webView
        if sender.selectedIndex == 0 { web?.goBack() } else { web?.goForward() }
    }

    /// ⌥⌘F and the toolbar button both open the page's command palette (⌘K).
    func focusSearch() { searchTapped() }
    @objc private func searchTapped() { owner?.send(.command(.openCommandMenu)) }
    @objc private func newChatTapped() { owner?.send(.command(.newChat)) }
    @objc private func companionTapped() { owner?.send(.command(.toggleCompanion)) }


    // MARK: Title menu and page-contributed items

    /// Replaces the title menu and the page's items. Order: [..., nav, (flexible space), title menu,
    /// leading items, ... trailing items, New Chat, companion, search]; in Compact the leading items
    /// follow the tab strip. Leading items sit right after the title because the title is placed
    /// after the navigational group and everything else follows it.
    private func rebuildPageItems() {
        for index in toolbar.items.indices.reversed() {
            let id = toolbar.items[index].itemIdentifier
            if id == Self.titleMenu || id == Self.titleLabel || id.rawValue.hasPrefix(Self.pagePrefix) { toolbar.removeItem(at: index) }
        }
        generation += 1
        pageItems = [:]
        let trailingAt = toolbar.items.firstIndex { $0.itemIdentifier == Self.companion } ?? toolbar.items.count
        let leadingAt = owner?.compact == true
            ? trailingAt
            : (toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace } ?? trailingAt)

        var counter = 0
        func register(_ item: ToolbarItem) -> NSToolbarItem.Identifier {
            let id = "\(Self.pagePrefix)\(generation).\(counter)"
            counter += 1
            pageItems[id] = item
            return NSToolbarItem.Identifier(id)
        }
        // Trailing first: inserting them leaves the earlier leading anchor where it was.
        let trailing = shownItems.filter { $0.placement != .leading }
        for (i, item) in trailing.enumerated() {
            toolbar.insertItem(withItemIdentifier: register(item), at: trailingAt + i)
        }
        var at = leadingAt
        // Leading items sit beside the title, which the system would otherwise stretch across the free
        // space: draw the title ourselves in that case and hide the window's.
        let ownTitle = owner?.compact != true && (shownTitleMenu != nil || shownItems.contains { $0.placement == .leading })
        owner?.window?.titleVisibility = ownTitle || owner?.compact == true ? .hidden : .visible
        if ownTitle {
            toolbar.insertItem(withItemIdentifier: Self.titleLabel, at: at)
            at += 1
        }
        // Separate: the title itself opens its menu (a small chevron inside the title label).
        // Compact: the tabs replace the title, so the menu hangs off a "⋯" item.
        if shownTitleMenu != nil, owner?.compact == true {
            toolbar.insertItem(withItemIdentifier: Self.titleMenu, at: at)
            at += 1
        }
        for item in shownItems where item.placement == .leading {
            toolbar.insertItem(withItemIdentifier: register(item), at: at)
            at += 1
        }
    }

    private func makeTitleLabelItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Title"
        item.paletteLabel = "Title"
        func label(_ font: NSFont, _ color: NSColor, _ text: String) -> NSTextField {
            let f = NSTextField(labelWithString: text)
            f.font = font
            f.textColor = color
            f.lineBreakMode = .byTruncatingTail
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return f
        }
        let title = label(.systemFont(ofSize: 13, weight: .semibold), .labelColor, owner?.content.displayTitle ?? "")
        let subtitle = label(.systemFont(ofSize: 11), .secondaryLabelColor, owner?.state.subtitle ?? "")
        subtitle.isHidden = subtitle.stringValue.isEmpty
        titleField = title
        subtitleField = subtitle
        // With a title menu, a small chevron follows the title and clicking the title opens the menu,
        // like a document title in other Mac apps.
        var titleRow: NSView = title
        if shownTitleMenu != nil {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Title menu")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)) ?? NSImage())
            chevron.contentTintColor = .secondaryLabelColor
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [title, chevron])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4
            titleRow = row
        }
        let stack = TitleMenuStack(views: [titleRow, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        if shownTitleMenu != nil {
            stack.onClick = { [weak self, weak stack] in
                guard let self, let stack, let items = self.shownTitleMenu else { return }
                let menu = MenuBuilder.menu(from: items) { [weak self] menuItemId in
                    self?.owner?.send(.titleAction(menuItemId: menuItemId))
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: stack)
            }
            stack.toolTip = "Actions for this page’s title"
            stack.setAccessibilityRole(.popUpButton)
            stack.setAccessibilityLabel(title.stringValue)
        }
        item.view = stack
        return item
    }

    private func makeTitleMenuItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        let compact = owner?.compact == true
        let symbol = NSImage(systemSymbolName: compact ? "ellipsis" : "chevron.down",
                             accessibilityDescription: compact ? "Chat actions" : "Title menu") ?? NSImage()
        // Small and light, so the chevron reads as part of the title rather than a separate button.
        item.image = compact ? symbol
            : (symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) ?? symbol)
        item.label = compact ? "More" : "Title menu"
        item.paletteLabel = "Title menu"
        item.toolTip = "Actions for this page’s title"
        item.menu = MenuBuilder.menu(from: shownTitleMenu ?? []) { [weak self] menuItemId in
            self?.owner?.send(.titleAction(menuItemId: menuItemId))
        }
        item.showsIndicator = false
        item.isBordered = !compact ? false : true
        return item
    }

    private func makePageItem(_ id: NSToolbarItem.Identifier, _ model: ToolbarItem) -> NSToolbarItem {
        let picture = model.avatar.map { Self.avatarImage($0, picture: nil) }
        let image = picture ?? SidebarIcons.image(model.icon ?? "dots")
        let titled = model.showsLabel == true
        let item: NSToolbarItem
        switch model.kind {
        case .menu:
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            let itemId = model.id
            let handler: (String) -> Void = { [weak self] menuItemId in
                self?.owner?.send(.toolbarAction(itemId: itemId, menuItemId: menuItemId))
            }
            menuItem.menu = MenuBuilder.menu(from: model.menu ?? [], onSelect: handler)
            menuItem.showsIndicator = titled
            item = menuItem
        case .toggle:
            let b = NSButton(image: image, target: self, action: #selector(pageButtonTapped(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .toolbar
            b.state = model.on == true ? .on : .off
            b.identifier = NSUserInterfaceItemIdentifier(model.id)
            if titled { b.title = model.label; b.imagePosition = .imageLeading }
            b.setAccessibilityLabel(model.label)
            if model.accent == true { b.contentTintColor = .controlAccentColor }
            item = NSToolbarItem(itemIdentifier: id)
            item.view = b
        case .button:
            item = NSToolbarItem(itemIdentifier: id)
            item.target = self
            item.action = #selector(pageButtonTapped(_:))
        }
        item.label = model.label
        item.paletteLabel = model.label
        item.toolTip = model.label
        item.image = image
        if titled { item.title = model.label }
        item.isEnabled = model.disabled != true
        item.isBordered = true
        item.tag = 0
        item.view?.identifier = NSUserInterfaceItemIdentifier(model.id)
        if model.kind == .button { itemIds[ObjectIdentifier(item)] = model.id }
        if let avatar = model.avatar, let url = avatar.imageUrl {
            // The picture sits behind the session cookie: fetched with it, initials until it arrives.
            Task { @MainActor [weak item] in
                guard let loaded = await AvatarImages.shared.image(for: url), let item else { return }
                let circle = Self.avatarImage(avatar, picture: loaded)
                item.image = circle
                (item.view as? NSButton)?.image = circle
            }
        }
        return item
    }

    /// A round avatar for the toolbar: the picture cropped to a circle, or initials on the colour.
    static func avatarImage(_ avatar: Avatar, picture: NSImage?, size: CGFloat = 20) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            if let picture, picture.size.width > 0, picture.size.height > 0 {
                let side = min(picture.size.width, picture.size.height)
                let crop = NSRect(x: (picture.size.width - side) / 2, y: (picture.size.height - side) / 2, width: side, height: side)
                picture.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
            } else {
                (NSColor.fromCSS(avatar.color) ?? .systemGray).setFill()
                rect.fill()
                let text = NSAttributedString(string: String(avatar.initials.prefix(2)), attributes: [
                    .font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold), .foregroundColor: NSColor.white,
                ])
                let box = text.size()
                text.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private var itemIds: [ObjectIdentifier: String] = [:]

    @objc private func pageButtonTapped(_ sender: Any?) {
        if let button = sender as? NSButton, let id = button.identifier?.rawValue {
            owner?.send(.toolbarAction(itemId: id))
        } else if let item = sender as? NSToolbarItem, let id = itemIds[ObjectIdentifier(item)] {
            owner?.send(.toolbarAction(itemId: id))
        }
    }
}

/// The toolbar's own title; when it has a menu, a click anywhere on it opens the menu.
private final class TitleMenuStack: NSStackView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Labels and the chevron would swallow the click; the whole title is the button.
        guard onClick != nil else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }
}
