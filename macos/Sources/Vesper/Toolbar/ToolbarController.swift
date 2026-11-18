import AppKit
import VesperCore

/// The unified toolbar: sidebar toggle, back/forward, then search, New Chat, companion toggle and
/// whatever items the page contributes (`toolbar` message). Title and subtitle are the window's.
@MainActor
final class ToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    private static let nav = NSToolbarItem.Identifier("vesper.nav")
    private static let search = NSToolbarItem.Identifier("vesper.search")
    private static let newChat = NSToolbarItem.Identifier("vesper.newChat")
    private static let companion = NSToolbarItem.Identifier("vesper.companion")
    private static let pagePrefix = "vesper.page."

    private weak var owner: MainWindowController?
    let toolbar: NSToolbar
    private var navItem: NSToolbarItemGroup?
    private var searchItem: NSSearchToolbarItem?
    private var pageItems: [String: ToolbarItem] = [:]
    private var generation = 0

    init(owner: MainWindowController) {
        self.owner = owner
        toolbar = NSToolbar(identifier: "vesper.main")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        let state = owner.state
        track({ (state.canGoBack, state.canGoForward) }) { [weak self] back, forward in
            self?.navItem?.subitems.first?.isEnabled = back
            self?.navItem?.subitems.last?.isEnabled = forward
        }
        track({ state.toolbarItems }) { [weak self] items in self?.applyPageItems(items) }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.nav, .flexibleSpace, Self.newChat, Self.companion, Self.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + pageItems.keys.map { NSToolbarItem.Identifier($0) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.nav:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: [symbol("chevron.left"), symbol("chevron.right")],
                                           selectionMode: .momentary, labels: ["Back", "Forward"], target: self, action: #selector(navigate(_:)))
            group.label = "Back/Forward"
            group.controlRepresentation = .expanded
            group.subitems.first?.isEnabled = owner?.state.canGoBack ?? false
            group.subitems.last?.isEnabled = owner?.state.canGoForward ?? false
            navItem = group
            return group
        case Self.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.toolTip = "Search or jump to (⌘K)"
            item.preferredWidthForSearchField = 220
            item.searchField.placeholderString = "Search or jump to"
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchSubmitted(_:))
            searchItem = item
            return item
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

    // The search field is the toolbar's door into the page's command palette (⌘K): the first
    // keystroke (or Return on an empty field) opens the palette with the text so far and hands
    // the keyboard to the page, where the person keeps typing.
    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSSearchField, field === searchItem?.searchField, !field.stringValue.isEmpty else { return }
        openPalette(query: field.stringValue)
    }

    @objc private func searchSubmitted(_ sender: NSSearchField) {
        openPalette(query: sender.stringValue)
    }

    private func openPalette(query: String) {
        guard let owner else { return }
        searchItem?.searchField.stringValue = ""
        searchItem?.endSearchInteraction()
        owner.window?.makeFirstResponder(owner.content.webView)
        owner.send(.command(.openCommandMenu, query: query.isEmpty ? nil : query))
    }

    /// ⌥⌘F: put the cursor in the toolbar search field.
    func focusSearch() {
        searchItem?.beginSearchInteraction()
    }
    @objc private func newChatTapped() { owner?.send(.command(.newChat)) }
    @objc private func companionTapped() { owner?.send(.command(.toggleCompanion)) }

    // MARK: Page-contributed items

    private func applyPageItems(_ items: [ToolbarItem]) {
        for index in toolbar.items.indices.reversed() where toolbar.items[index].itemIdentifier.rawValue.hasPrefix(Self.pagePrefix) {
            toolbar.removeItem(at: index)
        }
        generation += 1
        pageItems = [:]
        // Page items go before New Chat, companion and search, which stay rightmost.
        let anchor = toolbar.items.firstIndex { $0.itemIdentifier == Self.newChat } ?? toolbar.items.count
        for (i, item) in items.enumerated() {
            let id = "\(Self.pagePrefix)\(generation).\(i)"
            pageItems[id] = item
            toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(id), at: anchor + i)
        }
    }

    private func makePageItem(_ id: NSToolbarItem.Identifier, _ model: ToolbarItem) -> NSToolbarItem {
        let image = SidebarIcons.image(model.icon ?? "dots")
        let item: NSToolbarItem
        switch model.kind {
        case .menu:
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            let itemId = model.id
            let handler: (String) -> Void = { [weak self] menuItemId in
                self?.owner?.send(.toolbarAction(itemId: itemId, menuItemId: menuItemId))
            }
            menuItem.menu = MenuBuilder.menu(from: model.menu ?? [], onSelect: handler)
            menuItem.showsIndicator = false
            item = menuItem
        case .toggle:
            let b = NSButton(image: image, target: self, action: #selector(pageButtonTapped(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .toolbar
            b.state = model.on == true ? .on : .off
            b.identifier = NSUserInterfaceItemIdentifier(model.id)
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
        item.isEnabled = model.disabled != true
        item.isBordered = true
        item.tag = 0
        item.view?.identifier = NSUserInterfaceItemIdentifier(model.id)
        if model.kind == .button { itemIds[ObjectIdentifier(item)] = model.id }
        return item
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
