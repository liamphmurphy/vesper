import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

extension BrowserProfileColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .teal: .teal
        case .indigo: .indigo
        case .gray: .secondary
        }
    }
}

/// Compact Arc-style left sidebar for Vesper's internal Browser.
/// Published via `context.sidebarView` so the top `AreaBar` stays pinned above it.
struct BrowserSidebarView: View {
    let store: BrowserStore
    let context: NativeScreenContext

    @Environment(\.vesperTheme) private var theme
    @State private var filterText = ""
    @State private var filterOpen = false
    @State private var bookmarksExpanded = true
    @State private var savedLinksExpanded = true
    @State private var historyExpanded = false
    @State private var profilePopoverOpen = false
    @State private var newGroupPopoverOpen = false
    @State private var newGroupName = ""
    @State private var newGroupColor: BrowserProfileColor = .blue
    @State private var editingGroup: BrowserTabGroup?
    @State private var editingBookmark: BrowserBookmark?
    @State private var collapsedBookmarkFolders: Set<String> = []
    @State private var draggedTabID: UUID?

    private static let savedLinksRequest = API.listLibraryItems(kind: .link, offset: 0)

    private var savedLinks: [API.LibraryItem] {
        context.store.entry(Self.savedLinksRequest).data?.items ?? []
    }

    private var normalizedFilter: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesFilter(_ title: String, _ url: String) -> Bool {
        guard !normalizedFilter.isEmpty else { return true }
        return title.lowercased().contains(normalizedFilter) || url.lowercased().contains(normalizedFilter)
    }

    private var shortcutIndexByTabID: [UUID: Int] {
        let ordered = store.orderedTabs
        var map: [UUID: Int] = [:]
        for (idx, tab) in ordered.enumerated() {
            if idx < 8 {
                map[tab.id] = idx + 1
            } else if idx == ordered.count - 1, ordered.count >= 9 {
                map[tab.id] = 9
            }
        }
        return map
    }

    private func splitBadge(for tab: BrowserTabSession) -> String? {
        guard store.isSplitViewActive else { return nil }
        if store.primaryTab?.id == tab.id { return "L" }
        if store.splitTab?.id == tab.id { return "R" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            if filterOpen {
                filterBar
            }
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    pinnedSection
                    tabGroupsSection
                    openTabsSection
                    bookmarksSection
                    savedLinksSection
                    historySection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .sheet(item: $editingGroup) { group in
            BrowserTabGroupEditorSheet(group: group) { name, color in
                store.renameTabGroup(id: group.id, name: name, color: color)
            }
        }
        .sheet(item: $editingBookmark) { bm in
            BrowserBookmarkEditorSheet(bookmark: bm, existingFolders: store.bookmarkFolders) { title, folder in
                store.updateBookmark(id: bm.id, title: title, folder: folder)
            }
        }
        .task {
            context.store.observe(Self.savedLinksRequest)
            context.store.load(Self.savedLinksRequest)
        }
        .onDisappear {
            context.store.stopObserving(Self.savedLinksRequest.key)
        }
    }

    // MARK: Header, Profile Switcher & Filter

    private var sidebarHeader: some View {
        let profile = store.currentRuntime
        return HStack(spacing: 5) {
            Button {
                profilePopoverOpen.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: profile.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(profile.color.swiftUIColor)
                    Text(profile.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    Capsule()
                        .fill(profile.color.swiftUIColor.opacity(0.12))
                        .overlay(Capsule().stroke(profile.color.swiftUIColor.opacity(0.28), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .hoverTooltip("Switch or manage Browser profiles (isolated cookies, extensions & Keychain)")
            .popover(isPresented: $profilePopoverOpen, arrowEdge: .bottom) {
                BrowserProfileManagerPopover(store: store, isPresented: $profilePopoverOpen)
            }

            Spacer(minLength: 2)

            headerIconButton(symbol: "magnifyingglass", help: "Filter tabs, bookmarks & history") {
                withAnimation(.easeInOut(duration: 0.14)) {
                    filterOpen.toggle()
                    if !filterOpen { filterText = "" }
                }
            }
            headerIconButton(symbol: "folder.badge.plus", help: "New Tab Group (⌘⌃G)") {
                newGroupName = ""
                newGroupColor = BrowserProfileColor.allCases[store.tabGroups.count % BrowserProfileColor.allCases.count]
                newGroupPopoverOpen.toggle()
            }
            .popover(isPresented: $newGroupPopoverOpen, arrowEdge: .bottom) {
                newGroupPopover
            }
            headerIconButton(symbol: "eye.slash", help: "New Private Tab (⌘⇧P)") {
                _ = store.newTab(isPrivate: true, select: true)
            }
            headerIconButton(symbol: "plus", help: "New Web Tab (⌘T)") {
                _ = store.newTab(isPrivate: false, select: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var newGroupPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Tab Group")
                .font(.system(size: 12.5, weight: .semibold))
            TextField("Group name (e.g. Research, PRs)", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { commitNewGroup() }
            HStack(spacing: 6) {
                ForEach(BrowserProfileColor.allCases) { color in
                    Button {
                        newGroupColor = color
                    } label: {
                        Circle()
                            .fill(color.swiftUIColor)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary, lineWidth: newGroupColor == color ? 2 : 0)
                                    .padding(-2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { newGroupPopoverOpen = false }
                    .controlSize(.small)
                Button("Create") { commitNewGroup() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func commitNewGroup() {
        _ = store.createTabGroup(name: newGroupName, color: newGroupColor)
        newGroupPopoverOpen = false
    }

    private func headerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.palette.secondaryText)
                .frame(width: 21, height: 21)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(help)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.tertiaryText)
            TextField("Filter tabs, links, history…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.palette.surface.opacity(0.75)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: Pinned Tabs

    @ViewBuilder
    private var pinnedSection: some View {
        let shortcuts = shortcutIndexByTabID
        let pinned = store.pinnedTabs.filter { matchesFilter($0.displayTitle, $0.urlString) }
        if !pinned.isEmpty {
            sectionHeader("Pinned", count: pinned.count, collapsible: false, expanded: .constant(true))
            ForEach(pinned) { tab in
                tabRowView(tab: tab, shortcut: shortcuts[tab.id])
            }
            Divider().opacity(0.35).padding(.vertical, 4)
        }
    }

    // MARK: Collapsible Tab Groups

    @ViewBuilder
    private var tabGroupsSection: some View {
        let shortcuts = shortcutIndexByTabID
        let groups = store.tabGroups
        if !groups.isEmpty {
            ForEach(groups) { group in
                let groupTabs = store.regularTabs.filter { $0.groupId == group.id && matchesFilter($0.displayTitle, $0.urlString) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                store.toggleTabGroupCollapsed(id: group.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(theme.palette.tertiaryText)
                                    .frame(width: 10)
                                Circle()
                                    .fill(group.color.swiftUIColor)
                                    .frame(width: 7, height: 7)
                                Text(group.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.palette.text)
                                    .lineLimit(1)
                                Text("\(groupTabs.count)")
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(theme.palette.tertiaryText)
                                Spacer(minLength: 2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            _ = store.newTab(isPrivate: false, select: true, groupId: group.id)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(theme.palette.tertiaryText)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip("New tab in \(group.name)")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(group.color.swiftUIColor.opacity(0.08)))
                    .contextMenu {
                        Button("New Tab in Group") {
                            _ = store.newTab(isPrivate: false, select: true, groupId: group.id)
                        }
                        Button("Rename / Recolor…") {
                            editingGroup = group
                        }
                        Divider()
                        Button("Ungroup Tabs") {
                            store.deleteTabGroup(id: group.id, closeTabs: false)
                        }
                        Button("Close Group & Tabs", role: .destructive) {
                            store.deleteTabGroup(id: group.id, closeTabs: true)
                        }
                    }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        handleDropOntoGroup(providers: providers, groupId: group.id)
                    }

                    if !group.isCollapsed {
                        if groupTabs.isEmpty {
                            Text("Drop a tab here or click +")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.palette.tertiaryText)
                                .padding(.leading, 22)
                                .padding(.vertical, 2)
                        } else {
                            ForEach(groupTabs) { tab in
                                tabRowView(tab: tab, shortcut: shortcuts[tab.id])
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
                .padding(.bottom, 3)
            }
            Divider().opacity(0.35).padding(.vertical, 3)
        }
    }

    // MARK: Ungrouped Open Tabs

    @ViewBuilder
    private var openTabsSection: some View {
        let shortcuts = shortcutIndexByTabID
        let validGroupIDs = Set(store.tabGroups.map(\.id))
        let ungrouped = store.regularTabs.filter { tab in
            let inValidGroup = tab.groupId.map { validGroupIDs.contains($0) } ?? false
            return !inValidGroup && matchesFilter(tab.displayTitle, tab.urlString)
        }
        sectionHeader("Tabs", count: ungrouped.count, collapsible: false, expanded: .constant(true))
            .onDrop(of: [.text], isTargeted: nil) { providers in
                handleDropOntoGroup(providers: providers, groupId: nil)
            }

        if ungrouped.isEmpty {
            Text(normalizedFilter.isEmpty ? "No ungrouped tabs" : "No matching tabs")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else {
            ForEach(ungrouped) { tab in
                tabRowView(tab: tab, shortcut: shortcuts[tab.id])
            }
        }
    }

    private func tabRowView(tab: BrowserTabSession, shortcut: Int?) -> some View {
        BrowserTabRow(
            tab: tab,
            shortcutNumber: shortcut,
            splitBadge: splitBadge(for: tab),
            isActive: store.activeTab?.id == tab.id,
            tabGroups: store.tabGroups,
            onSelect: { store.selectTab(tab.id) },
            onClose: { store.closeTab(tab.id) },
            onTogglePin: { store.togglePin(tab.id) },
            onToggleMute: { store.toggleMute(tab.id) },
            onDuplicate: { store.duplicateTab(tab.id) },
            onOpenInSplit: { store.openInSplitView(tabId: tab.id) },
            onAssignGroup: { gid in store.assignTab(tab.id, toGroup: gid) },
            onCreateGroupWithTab: {
                _ = store.createTabGroup(name: "Group \(store.tabGroups.count + 1)", color: .blue, initialTabId: tab.id)
            },
            onCloseOthers: { store.closeOtherTabs(keeping: tab.id) }
        )
        .onDrag {
            draggedTabID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            if let sourceID = draggedTabID, sourceID != tab.id {
                store.moveTab(sourceID, before: tab.id)
                draggedTabID = nil
                return true
            }
            return handleDropReorder(providers: providers, before: tab.id)
        }
    }

    private func handleDropReorder(providers: [NSItemProvider], before targetID: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let sourceID = UUID(uuidString: raw) else { return }
            Task { @MainActor in
                store.moveTab(sourceID, before: targetID)
                draggedTabID = nil
            }
        }
        return true
    }

    private func handleDropOntoGroup(providers: [NSItemProvider], groupId: UUID?) -> Bool {
        if let sourceID = draggedTabID {
            store.assignTab(sourceID, toGroup: groupId)
            draggedTabID = nil
            return true
        }
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String, let sourceID = UUID(uuidString: raw) else { return }
            Task { @MainActor in
                store.assignTab(sourceID, toGroup: groupId)
                draggedTabID = nil
            }
        }
        return true
    }

    // MARK: Bookmarks (with Folders)

    @ViewBuilder
    private var bookmarksSection: some View {
        let items = store.bookmarks.filter { matchesFilter($0.title, $0.url) }
        if !store.bookmarks.isEmpty || !normalizedFilter.isEmpty {
            Divider().opacity(0.35).padding(.vertical, 4)
            sectionHeader("Bookmarks", count: items.count, collapsible: true, expanded: $bookmarksExpanded)
            if bookmarksExpanded {
                let folders = Array(Set(items.compactMap { bm -> String? in
                    let f = bm.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return f.isEmpty ? nil : f
                })).sorted()

                ForEach(folders, id: \.self) { folder in
                    let folderItems = items.filter { ($0.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == folder }
                    let isCollapsed = collapsedBookmarkFolders.contains(folder)
                    Button {
                        if isCollapsed { collapsedBookmarkFolders.remove(folder) } else { collapsedBookmarkFolders.insert(folder) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(theme.palette.tertiaryText)
                                .frame(width: 10)
                            Image(systemName: "folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(theme.palette.secondaryText)
                            Text(folder)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.palette.text)
                                .lineLimit(1)
                            Text("\(folderItems.count)")
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(theme.palette.tertiaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !isCollapsed {
                        ForEach(folderItems) { bm in
                            bookmarkRow(bm).padding(.leading, 10)
                        }
                    }
                }

                let unfiled = items.filter { ($0.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
                ForEach(unfiled) { bm in
                    bookmarkRow(bm)
                }
            }
        }
    }

    private func bookmarkRow(_ bm: BrowserBookmark) -> some View {
        BrowserLinkSidebarRow(
            title: bm.title,
            subtitle: BrowserURLResolver.displayHost(for: bm.url),
            favicon: BrowserFaviconCache.shared.cachedIcon(for: bm.url),
            symbol: "star.fill",
            symbolColor: .yellow
        ) {
            if let url = URL(string: bm.url) {
                store.openURL(url, inNewTab: SidebarView.isCommandClick(), reuseExisting: !SidebarView.isCommandClick())
            }
        }
        .contextMenu {
            Button("Open in New Tab") {
                if let url = URL(string: bm.url) { store.openURL(url, inNewTab: true) }
            }
            Button("Open in Split View") {
                if let url = URL(string: bm.url) {
                    let tab = store.newTab(url: url, select: false)
                    store.openInSplitView(tabId: tab.id)
                }
            }
            Button("Edit Bookmark…") {
                editingBookmark = bm
            }
            Button("Open in Safari") {
                if let url = URL(string: bm.url) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Remove Bookmark", role: .destructive) {
                store.removeBookmark(id: bm.id)
            }
        }
    }

    // MARK: Saved Links (Vesper Reading List)

    @ViewBuilder
    private var savedLinksSection: some View {
        let items = savedLinks.filter { item in
            let url = item.url ?? ""
            return !url.isEmpty && matchesFilter(item.title, url)
        }
        if !savedLinks.isEmpty {
            Divider().opacity(0.35).padding(.vertical, 4)
            sectionHeader("Saved Links", count: items.count, collapsible: true, expanded: $savedLinksExpanded)
            if savedLinksExpanded {
                ForEach(items.prefix(30), id: \.id) { item in
                    let rawURL = item.url ?? ""
                    BrowserLinkSidebarRow(
                        title: item.title.isEmpty ? BrowserURLResolver.displayHost(for: rawURL) : item.title,
                        subtitle: item.site?.isEmpty == false ? item.site! : BrowserURLResolver.displayHost(for: rawURL),
                        favicon: BrowserFaviconCache.shared.cachedIcon(for: rawURL),
                        symbol: "bookmark",
                        symbolColor: theme.palette.secondaryText
                    ) {
                        if let url = URL(string: rawURL) {
                            store.openURL(url, inNewTab: SidebarView.isCommandClick(), reuseExisting: !SidebarView.isCommandClick())
                        }
                    }
                    .contextMenu {
                        Button("Open in New Tab") {
                            if let url = URL(string: rawURL) { store.openURL(url, inNewTab: true) }
                        }
                        Button("Open in Split View") {
                            if let url = URL(string: rawURL) {
                                let tab = store.newTab(url: url, select: false)
                                store.openInSplitView(tabId: tab.id)
                            }
                        }
                        Button("Open in Safari") {
                            if let url = URL(string: rawURL) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let items = store.history.filter { matchesFilter($0.title, $0.url) }
        if !store.history.isEmpty {
            Divider().opacity(0.35).padding(.vertical, 4)
            HStack(spacing: 4) {
                sectionHeader("History", count: items.count, collapsible: true, expanded: $historyExpanded)
                if historyExpanded, !store.history.isEmpty {
                    Button("Clear") {
                        store.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .padding(.trailing, 4)
                }
            }
            if historyExpanded {
                ForEach(items.prefix(35)) { entry in
                    BrowserLinkSidebarRow(
                        title: entry.title,
                        subtitle: BrowserURLResolver.displayHost(for: entry.url),
                        favicon: BrowserFaviconCache.shared.cachedIcon(for: entry.url),
                        symbol: "clock",
                        symbolColor: theme.palette.tertiaryText
                    ) {
                        if let url = URL(string: entry.url) {
                            store.openURL(url, inNewTab: SidebarView.isCommandClick())
                        }
                    }
                    .contextMenu {
                        Button("Open in New Tab") {
                            if let url = URL(string: entry.url) { store.openURL(url, inNewTab: true) }
                        }
                        Button("Remove from History", role: .destructive) {
                            store.removeHistoryEntry(id: entry.id)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int, collapsible: Bool, expanded: Binding<Bool>) -> some View {
        Button {
            if collapsible {
                withAnimation(.easeInOut(duration: 0.14)) { expanded.wrappedValue.toggle() }
            }
        } label: {
            HStack(spacing: 4) {
                if collapsible {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .frame(width: 10)
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .tracking(0.4)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.palette.tertiaryText.opacity(0.8))
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
    }
}

// MARK: - Profile Manager Popover

private struct BrowserProfileManagerPopover: View {
    let store: BrowserStore
    @Binding var isPresented: Bool

    @State private var isAdding = false
    @State private var newName = ""
    @State private var newIcon = "briefcase.fill"
    @State private var newColor: BrowserProfileColor = .purple

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Browser Profiles")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) { isAdding.toggle() }
                } label: {
                    Label(isAdding ? "Cancel" : "New Profile", systemImage: isAdding ? "xmark" : "plus")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            }

            Text("Each profile has its own isolated cookies, tabs, extensions, and Keychain passwords.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            ForEach(store.profiles) { profile in
                let isCurrent = profile.id == store.activeProfileId
                HStack(spacing: 8) {
                    Button {
                        store.switchProfile(to: profile.id)
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: profile.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(profile.color.swiftUIColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name)
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                Text("\(profile.tabs.count) tab\(profile.tabs.count == 1 ? "" : "s") · \(profile.extensionHost.records.count) ext")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(profile.color.swiftUIColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if store.profiles.count > 1 {
                        Button(role: .destructive) {
                            store.deleteProfile(id: profile.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .hoverTooltip("Delete \(profile.name) profile")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(isCurrent ? profile.color.swiftUIColor.opacity(0.12) : Color.clear))
            }

            if isAdding {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Profile name (e.g. Work, Dev)", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { createProfile() }

                    HStack(spacing: 6) {
                        ForEach(BrowserProfileLogic.presetIcons, id: \.self) { sym in
                            Button {
                                newIcon = sym
                            } label: {
                                Image(systemName: sym)
                                    .font(.system(size: 12))
                                    .foregroundStyle(newIcon == sym ? newColor.swiftUIColor : .secondary)
                                    .frame(width: 24, height: 24)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(newIcon == sym ? newColor.swiftUIColor.opacity(0.16) : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(BrowserProfileColor.allCases) { color in
                            Button {
                                newColor = color
                            } label: {
                                Circle()
                                    .fill(color.swiftUIColor)
                                    .frame(width: 15, height: 15)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: newColor == color ? 2 : 0).padding(-2))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Create Profile") { createProfile() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func createProfile() {
        _ = store.createProfile(name: newName, icon: newIcon, color: newColor)
        newName = ""
        isAdding = false
        isPresented = false
    }
}

// MARK: - Tab Group & Bookmark Editor Sheets

private struct BrowserTabGroupEditorSheet: View {
    let group: BrowserTabGroup
    let onSave: (String, BrowserProfileColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: BrowserProfileColor

    init(group: BrowserTabGroup, onSave: @escaping (String, BrowserProfileColor) -> Void) {
        self.group = group
        self.onSave = onSave
        _name = State(initialValue: group.name)
        _color = State(initialValue: group.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tab Group")
                .font(.system(size: 14, weight: .semibold))
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(BrowserProfileColor.allCases) { c in
                    Button {
                        color = c
                    } label: {
                        Circle()
                            .fill(c.swiftUIColor)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary, lineWidth: color == c ? 2 : 0).padding(-2))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(name, color)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 280)
    }
}

private struct BrowserBookmarkEditorSheet: View {
    let bookmark: BrowserBookmark
    let existingFolders: [String]
    let onSave: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var folder: String

    init(bookmark: BrowserBookmark, existingFolders: [String], onSave: @escaping (String, String?) -> Void) {
        self.bookmark = bookmark
        self.existingFolders = existingFolders
        self.onSave = onSave
        _title = State(initialValue: bookmark.title)
        _folder = State(initialValue: bookmark.folder ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Bookmark")
                .font(.system(size: 14, weight: .semibold))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Folder (optional)", text: $folder)
                .textFieldStyle(.roundedBorder)
            if !existingFolders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(existingFolders, id: \.self) { existing in
                            Button(existing) { folder = existing }
                                .controlSize(.small)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(title, folder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

// MARK: - Sidebar Rows

private struct BrowserTabRow: View {
    let tab: BrowserTabSession
    let shortcutNumber: Int?
    let splitBadge: String?
    let isActive: Bool
    let tabGroups: [BrowserTabGroup]
    let onSelect: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onToggleMute: () -> Void
    let onDuplicate: () -> Void
    let onOpenInSplit: () -> Void
    let onAssignGroup: (UUID?) -> Void
    let onCreateGroupWithTab: () -> Void
    let onCloseOthers: () -> Void

    @Environment(\.vesperTheme) private var theme
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            leadingIcon
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? theme.palette.text : theme.palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !tab.displayHost.isEmpty, tab.displayHost.lowercased() != tab.displayTitle.lowercased() {
                    Text(tab.displayHost)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if let splitBadge {
                Text(splitBadge)
                    .font(.system(size: 8.5, weight: .bold).monospaced())
                    .foregroundStyle(theme.palette.accent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(theme.palette.accent.opacity(0.16)))
                    .hoverTooltip("Open in Split View (\(splitBadge == "L" ? "Left" : "Right") pane)")
            }
            if tab.activeShare != nil {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .hoverTooltip("Shared with persona")
            }
            if tab.isMuted || tab.isAudioPlaying {
                Button(action: onToggleMute) {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(tab.isMuted ? theme.palette.tertiaryText : theme.palette.accent)
                }
                .buttonStyle(.plain)
                .hoverTooltip(tab.isMuted ? "Unmute Tab (⌥⌘M)" : "Mute Tab (⌥⌘M)")
            }
            if hovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.secondaryText)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(theme.palette.hover))
                }
                .buttonStyle(.plain)
                .hoverTooltip("Close Tab (⌘W)")
            } else if let shortcutNumber {
                Text("\(shortcutNumber)")
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.palette.tertiaryText.opacity(0.65))
                    .frame(width: 14, alignment: .trailing)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? theme.palette.selected : hovered ? theme.palette.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open in Split View", action: onOpenInSplit)
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
            Button(tab.isMuted ? "Unmute Tab" : "Mute Tab", action: onToggleMute)
            if !tab.isPrivate {
                Menu("Move to Group") {
                    if tab.groupId != nil {
                        Button("Remove from Group") { onAssignGroup(nil) }
                        Divider()
                    }
                    ForEach(tabGroups) { g in
                        Button {
                            onAssignGroup(g.id)
                        } label: {
                            HStack {
                                Text(g.name)
                                if tab.groupId == g.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if !tabGroups.isEmpty { Divider() }
                    Button("New Group with Tab", action: onCreateGroupWithTab)
                }
            }
            Button("Duplicate Tab", action: onDuplicate)
            Button("Reload Tab") { tab.reload() }
            if let url = URL(string: tab.urlString), BrowserURLResolver.isWebURL(url) {
                Button("Copy URL") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(tab.urlString, forType: .string)
                }
                Button("Open in Safari") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Close Other Tabs", action: onCloseOthers)
            Button("Close Tab", role: .destructive, action: onClose)
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
                .frame(width: 14, height: 14)
        } else if tab.isPrivate {
            Image(systemName: "eye.slash")
                .font(.system(size: 11))
                .foregroundStyle(.purple)
                .frame(width: 14, height: 14)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else if tab.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: tab.hasLoadedPage ? "globe" : "plus.square.dashed")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? theme.palette.accent : theme.palette.tertiaryText)
                .frame(width: 14, height: 14)
        }
    }
}

private struct BrowserLinkSidebarRow: View {
    let title: String
    let subtitle: String
    var favicon: NSImage? = nil
    let symbol: String
    let symbolColor: Color
    let onTap: () -> Void

    @Environment(\.vesperTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5))
                        .frame(width: 14)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5))
                        .foregroundStyle(symbolColor)
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                    if !subtitle.isEmpty, subtitle.lowercased() != title.lowercased() {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? theme.palette.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
