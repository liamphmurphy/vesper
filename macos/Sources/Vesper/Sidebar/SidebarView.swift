import AppKit
import SwiftUI
import VesperCore

/// The sidebar of a window: it shows the active tab's state, so switching tabs swaps the whole list.
struct SidebarHost: View {
    let tabs: TabsModel
    let send: (NativeCommand) -> Void
    let openInNewTab: (String) -> Void

    var body: some View {
        if let tab = tabs.list.active {
            SidebarView(state: tab.state, send: send, openInNewTab: openInNewTab)
                .environment(\.vesperTheme, tab.state.theme ?? ThemeTokens(mode: .dark))
                .id(ObjectIdentifier(tab))
        }
    }
}

/// The native sidebar: a pinned bar of the areas (with the Apps menu), the screen's compact header
/// (title, actions, search, filters), then its scrolling list, all drawn from the `NavModel` the page
/// describes. The first two stay put while the list scrolls. Everything user-driven goes out through `send`.
private struct SidebarScrollTarget: Equatable, Sendable {
    let navId: String
    let itemId: String
}

struct SidebarView: View {
    let state: ShellState
    let send: (NativeCommand) -> Void
    let openInNewTab: (String) -> Void
    @Environment(\.vesperTheme) private var theme

    static func isCommandClick() -> Bool {
        NSEvent.modifierFlags.contains(.command) || NSApp.currentEvent?.modifierFlags.contains(.command) == true
    }

    private var scrollTarget: SidebarScrollTarget? {
        guard let nav = state.navigator, let selected = nav.selectedId else { return nil }
        guard SidebarTree.isVisible(
            selected,
            in: nav,
            expandedOverrides: state.expandedOverrides,
            collapsedOverrides: state.collapsedOverrides
        ) else { return nil }
        return SidebarScrollTarget(navId: nav.id, itemId: selected)
    }

    var body: some View {
        let shell = ShellState.fallbackShell
        VStack(spacing: 0) {
            AreaBar(shell: shell, current: state.currentArea, send: send, openInNewTab: openInNewTab)
            if let customSidebar = state.nativeSidebar {
                customSidebar
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let nav = state.navigator {
                    NavHeader(nav: nav, send: send).id(nav.id)
                }
                ScrollViewReader { proxy in
                    List(selection: navSelection) {
                        if let nav = state.navigator {
                            NavContent(nav: nav, state: state, send: send)
                        }
                    }
                    .listStyle(.sidebar)
                    // Denser rows than the sidebar default, so a long chat list or file tree shows more of itself.
                    .environment(\.defaultMinListRowHeight, max(20, (22 * theme.typeScale).rounded()))
                    .task(id: scrollTarget) {
                        guard let target = scrollTarget, !state.recentlyActivated(target.itemId) else { return }
                        // Let newly expanded DisclosureGroups materialize child rows in NSOutlineView before scrolling.
                        try? await Task.sleep(for: .milliseconds(60))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target.itemId, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// The selected row: the screen's selected nav row. Setting it is a user click: the page
    /// navigates, the shell only reports. (The areas are buttons in the bar above, not rows.)
    private var navSelection: Binding<String?> {
        Binding(
            get: {
                // Report a nav selection only once its row is visible: a page may name the selection
                // before the row loads or before its ancestor folders expand, and the List won't
                // re-apply an unchanged value when the row appears later. Going from nil to the id
                // makes it select the row.
                guard let nav = state.navigator, let selected = nav.selectedId else { return nil }
                return SidebarTree.isVisible(
                    selected,
                    in: nav,
                    expandedOverrides: state.expandedOverrides,
                    collapsedOverrides: state.collapsedOverrides
                ) ? selected : nil
            },
            set: { id in
                guard let id, let nav = state.navigator, id != nav.selectedId else { return }
                // ⌘-click opens the row in a new tab (as in Safari); the page decides, since it knows the href.
                let newTab = Self.isCommandClick()
                if newTab, state.recentlyActivated(id) { return }
                state.noteActivate(id)
                send(.navActivate(navigatorId: nav.id, itemId: id, newTab: newTab))
            })
    }
}

// MARK: - Area bar

/// The areas as one row of icons, pinned above the list (the old vertical rows took ~150pt of it).
/// Apps pops up a menu of Custom Apps and Tools instead of expanding in place.
private struct AreaBar: View {
    let shell: ShellModel
    let current: AreaId?
    let send: (NativeCommand) -> Void
    let openInNewTab: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shell.areas) { area in
                AreaButton(label: area.label, symbol: SidebarIcons.symbolName(area.icon), badge: area.badge, selected: current == area.id) {
                    activate(href: area.href)
                }
                .contextMenu {
                    Button {
                        openInNewTab(area.href)
                    } label: {
                        Label("Open in New Tab", systemImage: SidebarIcons.symbolName("external"))
                    }
                }
            }
            AreaButton(label: "Apps", symbol: SidebarIcons.symbolName("dashboard"), badge: nil, selected: current == .apps) {
                activate(href: "/apps", isAppsButton: true)
            }
            .contextMenu {
                Button {
                    openInNewTab("/apps")
                } label: {
                    Label("Open in New Tab", systemImage: SidebarIcons.symbolName("external"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func activate(href: String, isAppsButton: Bool = false) {
        switch SidebarTree.areaClick(
            href: href,
            isAppsButton: isAppsButton,
            hasApps: !shell.apps.isEmpty,
            commandClick: SidebarView.isCommandClick()
        ) {
        case .navigate(let path):
            send(.navigate(path: path))
        case .openInNewTab(let path):
            openInNewTab(path)
        case .showAppsMenu:
            popUpAppsMenu()
        }
    }

    private func openMenuPath(_ path: String) {
        if SidebarView.isCommandClick() {
            openInNewTab(path)
        } else {
            send(.navigate(path: path))
        }
    }

    /// Custom Apps (the /apps page), then your apps and the tools as grouped items.
    private func popUpAppsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hub = ClosureMenuItem(title: "Custom Apps", handler: { _ in openMenuPath("/apps") }, id: "apps")
        hub.image = SidebarIcons.image("dashboard")
        menu.addItem(hub)
        for section in SidebarTree.appsMenuSections(shell.apps) {
            menu.addItem(.separator())
            let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for app in section.apps {
                let item = ClosureMenuItem(title: app.label, handler: { _ in openMenuPath(app.href) }, id: app.id)
                item.image = SidebarIcons.image(app.icon)
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private struct AreaButton: View {
    let label: String
    let symbol: String
    let badge: AreaBadge?
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.14) : hovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Circle().fill((badge.tone ?? .neutral).color).frame(width: 6, height: 6).padding(.top, 4).padding(.trailing, 8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .hoverTooltip(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Nav model

private struct NavContent: View {
    let nav: NavModel
    let state: ShellState
    let send: (NativeCommand) -> Void

    var body: some View {
        ForEach(nav.sections) { section in
            NavSectionView(nav: nav, section: section, state: state, send: send)
        }
        // The List never draws the selection on the rows of its last section (a screen's saved views
        // stayed unselected while the queues above them highlighted). A section after them, with an
        // unselectable 1pt row, makes them selectable. Verified by hand: removing it brings the bug back.
        Section { Color.clear.frame(height: 1).selectionDisabled().accessibilityHidden(true) }
    }
}

/// The screen's header, pinned above the list: one compact line of title, search toggle and actions,
/// then the filters and picker. Search is a field that opens from the magnifier, so it costs a row
/// only while it's in use.
private struct NavHeader: View {
    let nav: NavModel
    let send: (NativeCommand) -> Void
    @Environment(\.vesperTheme) private var theme
    @State private var search = ""
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool
    @State private var debounce: Task<Void, Never>?

    /// At most three choices whose labels add up to about the sidebar's width.
    static func fitsSegmented(_ labels: [String]) -> Bool {
        labels.count <= 3 && labels.reduce(0) { $0 + $1.count } <= 24
    }

    @ViewBuilder private var actionButtons: some View {
        ForEach(nav.actions ?? []) { action in
            ActionButton(action: action) { menuId in
                send(.navAction(navigatorId: nav.id, actionId: action.id, itemId: nil, menuItemId: menuId))
            }
        }
    }

    /// Closing clears the text too, so the list isn't left filtered by a field that's no longer showing.
    private func closeSearch() {
        search = ""
        searchOpen = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if nav.title != nil || nav.search != nil || !(nav.actions ?? []).isEmpty {
                HStack(spacing: 4) {
                    if let title = nav.title {
                        Text(title).font(theme.scaledFont(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                    }
                    Spacer(minLength: 4)
                    if nav.search != nil {
                        Button {
                            if searchOpen { closeSearch() } else { searchOpen = true }
                        } label: {
                            Image(systemName: "magnifyingglass").foregroundStyle(searchOpen ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(searchOpen ? "Close search" : "Search")
                    }
                    actionButtons
                }
            }
            if let filters = nav.filters, !filters.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(filters) { filter in
                        FilterMenu(filter: filter) { value, checked in
                            send(.navFilter(navigatorId: nav.id, filterId: filter.id, value: value, checked: checked))
                        }
                    }
                }
            }
            if let picker = nav.picker {
                let selection = Binding(get: { picker.value }, set: { send(.navPicker(navigatorId: nav.id, pickerId: picker.id, value: $0)) })
                // A segmented control only fits a few short choices (e.g. Yours / Agent knowledge);
                // more (one per persona) become a pop-up menu that can't overflow the sidebar.
                if Self.fitsSegmented(picker.options.map(\.label)) {
                    Picker(picker.id, selection: selection) {
                        ForEach(picker.options, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                } else {
                    Picker(picker.id, selection: selection) {
                        ForEach(picker.options, id: \.value) { option in
                            if let icon = option.icon {
                                Label(option.label, systemImage: SidebarIcons.symbolName(icon)).tag(option.value)
                            } else {
                                Text(option.label).tag(option.value)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let s = nav.search, searchOpen {
                TextField(s.placeholder, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($searchFocused)
                    // Esc closes the field (clearing it), as the web's search does.
                    .onExitCommand { closeSearch() }
                    .onAppear { searchFocused = true }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The search state lives on the header, not the field, so a query the page already holds (a
        // restored tab, a shared filter) keeps the field open and filled while it's applied.
        .onAppear {
            if let s = nav.search, !s.value.isEmpty { search = s.value; searchOpen = true }
        }
        .onChange(of: nav.search?.value) { _, new in
            guard let new, new != search else { return }
            search = new
            if !new.isEmpty { searchOpen = true }
        }
        .onChange(of: search) { _, new in
            guard let s = nav.search, new != s.value else { return }
            debounce?.cancel()
            debounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                send(.navSearch(navigatorId: nav.id, searchId: s.id, value: new))
            }
        }
    }
}

private struct ActionButton: View {
    let action: NavAction
    let onChoose: (String?) -> Void
    @State private var hovered = false

    var body: some View {
        content.disabled(action.disabled == true)
    }

    @ViewBuilder private var content: some View {
        if let menu = action.menu, !menu.isEmpty {
            // A plain button that pops up an NSMenu: SwiftUI's Menu collapses to zero width in a
            // sidebar header row, which hid Knowledge's + (New) menu.
            styled(Button {
                let ns = MenuBuilder.menu(from: menu) { onChoose($0) }
                ns.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } label: { buttonFace })
        } else {
            styled(Button { onChoose(nil) } label: { buttonFace })
        }
    }

    @ViewBuilder private func styled<V: View>(_ button: V) -> some View {
        if action.showsLabel == true {
            button
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help(action.label)
        } else {
            button
                .buttonStyle(.borderless)
                .help(action.label)
        }
    }

    @ViewBuilder private var buttonFace: some View {
        let symbol = SidebarIcons.symbolName(action.icon)
        if action.showsLabel == true {
            let accent = action.accent == true
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(action.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(accent ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    accent
                        ? Color.accentColor.opacity(hovered ? 0.22 : 0.14)
                        : Color.primary.opacity(hovered ? 0.14 : 0.08)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    accent
                        ? Color.accentColor.opacity(0.32)
                        : Color.primary.opacity(hovered ? 0.22 : 0.14),
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        } else {
            let tint = action.accent == true ? Color.accentColor : Color.secondary
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

/// A pull-down with check marks: a filter in the header row.
private struct FilterMenu: View {
    let filter: NavFilterMenu
    let onChoose: (String, Bool) -> Void

    private var title: String {
        if filter.multiple == true { return filter.label }
        let checked = filter.options.first { $0.checked }?.label
        return checked.map { "\(filter.label): \($0)" } ?? filter.label
    }

    var body: some View {
        Menu {
            ForEach(filter.options, id: \.value) { option in
                Toggle(option.label, isOn: Binding(
                    get: { option.checked },
                    // A single-choice option stays selected when chosen again.
                    set: { onChoose(option.value, filter.multiple == true ? $0 : true) }))
            }
        } label: {
            HStack(spacing: 4) {
                if let icon = filter.icon { Image(systemName: SidebarIcons.symbolName(icon)) }
                Text(title).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(filter.label)
    }
}

/// Lays children out left to right, wrapping to a new line when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

private struct NavSectionView: View {
    let nav: NavModel
    let section: NavSection
    let state: ShellState
    let send: (NativeCommand) -> Void
    @Environment(\.vesperTheme) private var theme
    @State private var titleHovered = false

    private var isExpanded: Bool {
        !(state.collapsedOverrides[section.id] ?? section.collapsed ?? false)
    }

    private var hasHeader: Bool {
        section.title != nil || !(section.actions ?? []).isEmpty || section.badge != nil
    }

    private func toggleSection() {
        let open = !isExpanded
        withAnimation(.easeInOut(duration: 0.15)) {
            state.collapsedOverrides[section.id] = !open
        }
        // The protocol has no section message; nav.toggle with the section id is the closest signal.
        if section.collapsible == true {
            send(.navToggle(navigatorId: nav.id, itemId: section.id, expanded: open))
        }
    }

    var body: some View {
        // Render section headers as non-selectable rows inside a headerless Section so macOS's
        // sidebar outline view never injects a hover disclosure arrow (which shifted header actions
        // like "New Chat" left and pushed the header past the row's trailing edge).
        Section {
            if hasHeader {
                header
                    .selectionDisabled()
            }
            if isExpanded {
                rows
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let title = section.title {
                Button(action: toggleSection) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(theme.scaledFont(size: 11, weight: .semibold))
                            .foregroundStyle(titleHovered ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        if let badge = section.badge { BadgeView(text: badge.text, tone: badge.tone) }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { titleHovered = $0 }
                .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
            } else {
                if let badge = section.badge { BadgeView(text: badge.text, tone: badge.tone) }
                Spacer(minLength: 0)
            }
            ForEach(section.actions ?? []) { action in
                ActionButton(action: action) { menuId in
                    send(.navAction(navigatorId: nav.id, actionId: action.id, itemId: nil, menuItemId: menuId))
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var rows: some View {
        if section.items.isEmpty {
            if let empty = section.emptyText {
                Text(empty).font(theme.font(.small)).foregroundStyle(.secondary)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true).selectionDisabled()
            }
        } else {
            ForEach(section.items) { item in
                NavRow(nav: nav, item: item, state: state, send: send)
            }
        }
    }
}

private struct NavRow: View {
    let nav: NavModel
    let item: NavItem
    let state: ShellState
    let send: (NativeCommand) -> Void

    private var expanded: Binding<Bool> {
        Binding(
            get: { state.expandedOverrides[item.id] ?? item.expanded ?? false },
            set: { open in
                // A click on the row's title activates it (nav.activate); only the disclosure triangle
                // toggles. If the title click also flips the disclosure, the activation wins.
                if state.recentlyActivated(item.id) { return }
                state.expandedOverrides[item.id] = open
                state.scheduleToggle(item.id) { send(.navToggle(navigatorId: nav.id, itemId: item.id, expanded: open)) }
            })
    }

    var body: some View {
        if let children = item.children, !children.isEmpty {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(children) { child in NavRow(nav: nav, item: child, state: state, send: send) }
            } label: { label }
            .id(item.id)
            .tag(item.id)
        } else {
            label
                .id(item.id)
                .tag(item.id)
        }
    }

    private var label: some View {
        NavRowLabel(item: item)
            .contentShape(Rectangle())
            .selectionDisabled(item.disabled == true)
            .disabled(item.disabled == true)
            .simultaneousGesture(
                TapGesture().modifiers(.command).onEnded {
                    guard item.disabled != true else { return }
                    guard !state.recentlyActivated(item.id) else { return }
                    state.noteActivate(item.id)
                    send(.navActivate(navigatorId: nav.id, itemId: item.id, newTab: true))
                }
            )
            .contextMenu {
                if let menu = item.contextMenu, !menu.isEmpty {
                    MenuItems(items: menu) { id in
                        send(.navAction(navigatorId: nav.id, actionId: id, itemId: item.id, menuItemId: nil))
                    }
                }
            }
    }
}

private struct NavRowLabel: View {
    let item: NavItem
    @Environment(\.vesperTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let status = item.status {
                Circle().fill(status.color).frame(width: 7, height: 7)
            }
            if let avatar = item.avatar {
                AvatarView(avatar: avatar)
            } else if let icon = item.icon {
                Image(systemName: SidebarIcons.symbolName(icon))
                    .font(theme.scaledFont(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(theme.font(.body)).lineLimit(1)
                if let sub = item.subtitle { Text(sub).font(theme.scaledFont(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let trailing = item.trailing { Text(trailing).font(theme.scaledFont(size: 11)).foregroundStyle(.secondary) }
            if let badge = item.badge { BadgeView(text: badge.text, tone: badge.tone) }
        }
    }
}

struct AvatarView: View {
    let avatar: Avatar
    @State private var picture: NSImage?

    var body: some View {
        let fill = Color(cssHex: avatar.color) ?? .gray
        ZStack {
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                Circle().fill(fill)
                Text(avatar.initials.prefix(2)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .task(id: avatar.imageUrl) {
            picture = nil
            guard let url = avatar.imageUrl else { return }
            picture = await AvatarImages.shared.image(for: url)
        }
    }
}

struct BadgeView: View {
    let text: String?
    let tone: Tone?

    var body: some View {
        let color = (tone ?? .neutral).color
        if let text, !text.isEmpty {
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(tone == nil || tone == .neutral ? Color.secondary : color))
        } else {
            Circle().fill(color).frame(width: 7, height: 7)
        }
    }
}

/// A protocol MenuItem tree as SwiftUI menu content (context menus and header menus).
struct MenuItems: View {
    let items: [MenuItem]
    let onChoose: (String) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.separator == true {
                Divider()
            } else if let children = item.children, !children.isEmpty {
                Menu(item.label ?? "") { AnyView(MenuItems(items: children, onChoose: onChoose)) }
            } else {
                Button(role: item.destructive == true ? .destructive : nil) { onChoose(item.id) } label: {
                    if item.checked == true {
                        Label(item.label ?? "", systemImage: "checkmark")
                    } else if let icon = item.icon {
                        Label(item.label ?? "", systemImage: SidebarIcons.symbolName(icon))
                    } else {
                        Text(item.label ?? "")
                    }
                }
                .disabled(item.disabled == true)
            }
        }
    }
}
