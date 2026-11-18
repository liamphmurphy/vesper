import SwiftUI
import VesperCore

/// The native sidebar: the shell section (areas, Apps) on top, then the current screen's list,
/// drawn from the `NavModel` the page describes. Everything user-driven goes out through `send`.
struct SidebarView: View {
    let state: ShellState
    let send: (NativeCommand) -> Void

    var body: some View {
        let shell = state.shell ?? ShellState.fallbackShell
        List(selection: navSelection) {
            ShellSection(shell: shell, send: send)
            if let nav = state.navigator {
                NavContent(nav: nav, state: state, send: send)
            }
        }
        .listStyle(.sidebar)
    }

    /// The selected row: the screen's selected nav row, else the current area (so an area looks like
    /// a native source-list selection). Setting it is a user click: the page navigates, the shell only
    /// reports. Areas navigate from their own tap (so re-clicking the current area works too).
    private var navSelection: Binding<String?> {
        Binding(
            get: { state.navigator?.selectedId ?? (state.shell ?? ShellState.fallbackShell).currentArea.map { ShellSection.areaTag($0) } },
            set: { id in
                guard let id, !id.hasPrefix(ShellSection.areaPrefix), let nav = state.navigator, id != nav.selectedId else { return }
                state.noteActivate(id)
                send(.navActivate(navigatorId: nav.id, itemId: id))
            })
    }
}

// MARK: - Shell section

private struct ShellSection: View {
    let shell: ShellModel
    let send: (NativeCommand) -> Void
    @State private var appsExpanded = true

    static let areaPrefix = "area:"
    static func areaTag(_ id: AreaId) -> String { areaPrefix + id.rawValue }

    var body: some View {
        Section {
            ForEach(shell.areas) { area in
                HStack {
                    Label(area.label, systemImage: SidebarIcons.symbolName(area.icon))
                    Spacer()
                    if let badge = area.badge { BadgeView(text: badge.text, tone: badge.tone) }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { send(.navigate(path: area.href)) })
                .tag(Self.areaTag(area.id))
            }
            if !shell.apps.isEmpty {
                DisclosureGroup(isExpanded: $appsExpanded) {
                    ForEach(shell.apps) { app in
                        Button { send(.navigate(path: app.href)) } label: {
                            Label(app.label, systemImage: SidebarIcons.symbolName(app.icon)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                    }
                } label: {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
                .selectionDisabled()
            }
        }
    }
}

// MARK: - Nav model

private struct NavContent: View {
    let nav: NavModel
    let state: ShellState
    let send: (NativeCommand) -> Void

    var body: some View {
        Section {
            NavHeader(nav: nav, send: send)
        }
        ForEach(nav.sections) { section in
            NavSectionView(nav: nav, section: section, state: state, send: send)
        }
    }
}

private struct NavHeader: View {
    let nav: NavModel
    let send: (NativeCommand) -> Void
    @State private var search = ""
    @State private var debounce: Task<Void, Never>?

    @ViewBuilder private var actionButtons: some View {
        ForEach(nav.actions ?? []) { action in
            ActionButton(action: action) { menuId in
                send(.navAction(navigatorId: nav.id, actionId: action.id, itemId: nil, menuItemId: menuId))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = nav.title, (nav.actions ?? []).count > 2 {
                // Many actions would squeeze the title to "Know…": title on its own line, actions below.
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                HStack(spacing: 2) {
                    actionButtons
                    Spacer(minLength: 0)
                }
            } else if nav.title != nil || !(nav.actions ?? []).isEmpty {
                HStack {
                    if let title = nav.title { Text(title).font(.title3.weight(.semibold)).lineLimit(1).layoutPriority(1) }
                    Spacer(minLength: 4)
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
                Picker(picker.id, selection: Binding(get: { picker.value }, set: { send(.navPicker(navigatorId: nav.id, pickerId: picker.id, value: $0)) })) {
                    ForEach(picker.options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let s = nav.search {
                TextField(s.placeholder, text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { search = s.value }
                    .onChange(of: s.value) { _, new in if new != search { search = new } }
                    .onChange(of: search) { _, new in
                        guard new != s.value else { return }
                        debounce?.cancel()
                        debounce = Task {
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            send(.navSearch(navigatorId: nav.id, searchId: s.id, value: new))
                        }
                    }
            }
        }
        .selectionDisabled()
    }
}

private struct ActionButton: View {
    let action: NavAction
    let onChoose: (String?) -> Void

    var body: some View {
        content.disabled(action.disabled == true)
    }

    @ViewBuilder private var content: some View {
        if let menu = action.menu, !menu.isEmpty {
            // A plain button that pops up an NSMenu: SwiftUI's Menu collapses to zero width in a
            // sidebar header row, which hid Knowledge's + (New) menu.
            Button {
                let ns = MenuBuilder.menu(from: menu) { onChoose($0) }
                ns.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } label: {
                Image(systemName: SidebarIcons.symbolName(action.icon)).foregroundStyle(action.accent == true ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(action.label)
        } else {
            Button { onChoose(nil) } label: {
                Image(systemName: SidebarIcons.symbolName(action.icon)).foregroundStyle(action.accent == true ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(action.label)
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
private struct FlowLayout: Layout {
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

    private var expanded: Binding<Bool> {
        Binding(
            get: { !(state.collapsedOverrides[section.id] ?? section.collapsed ?? false) },
            set: { open in
                state.collapsedOverrides[section.id] = !open
                // The protocol has no section message; nav.toggle with the section id is the closest signal.
                send(.navToggle(navigatorId: nav.id, itemId: section.id, expanded: open))
            })
    }

    var body: some View {
        if section.collapsible == true, section.title != nil {
            Section(isExpanded: expanded) { rows } header: { header }
        } else {
            Section { rows } header: { if section.title != nil || !(section.actions ?? []).isEmpty || section.badge != nil { header } }
        }
    }

    private var header: some View {
        HStack {
            Text(section.title ?? "")
            if let badge = section.badge { BadgeView(text: badge.text, tone: badge.tone) }
            Spacer()
            ForEach(section.actions ?? []) { action in
                ActionButton(action: action) { menuId in
                    send(.navAction(navigatorId: nav.id, actionId: action.id, itemId: nil, menuItemId: menuId))
                }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if section.items.isEmpty {
            if let empty = section.emptyText {
                Text(empty).font(.callout).foregroundStyle(.secondary)
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
            .tag(item.id)
        } else {
            label.tag(item.id)
        }
    }

    private var label: some View {
        NavRowLabel(item: item)
            .selectionDisabled(item.disabled == true)
            .disabled(item.disabled == true)
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

    var body: some View {
        HStack(spacing: 8) {
            if let status = item.status {
                Circle().fill(status.color).frame(width: 7, height: 7)
            }
            if let avatar = item.avatar {
                AvatarView(avatar: avatar)
            } else if let icon = item.icon {
                Image(systemName: SidebarIcons.symbolName(icon)).foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let sub = item.subtitle { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if let trailing = item.trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            if let badge = item.badge { BadgeView(text: badge.text, tone: badge.tone) }
        }
    }
}

private struct AvatarView: View {
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

private struct BadgeView: View {
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
private struct MenuItems: View {
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
