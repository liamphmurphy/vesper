import AppKit
import SwiftUI
import VesperCore

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

    private var indexedOrderedTabs: [(shortcut: Int?, tab: BrowserTabSession)] {
        let ordered = store.orderedTabs
        return ordered.enumerated().map { idx, tab in
            let number: Int?
            if idx < 8 {
                number = idx + 1
            } else if idx == ordered.count - 1, ordered.count >= 9 {
                number = 9
            } else {
                number = nil
            }
            return (number, tab)
        }
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
                    openTabsSection
                    bookmarksSection
                    savedLinksSection
                    historySection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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

    // MARK: Header & Filter

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Text("Browser")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.text)
            Spacer(minLength: 4)
            headerIconButton(symbol: "magnifyingglass", help: "Filter tabs, bookmarks & history") {
                withAnimation(.easeInOut(duration: 0.14)) {
                    filterOpen.toggle()
                    if !filterOpen { filterText = "" }
                }
            }
            headerIconButton(symbol: "eye.slash", help: "New Private Tab (⌘⇧P)") {
                _ = store.newTab(isPrivate: true, select: true)
            }
            headerIconButton(symbol: "plus", help: "New Web Tab (⌘T)") {
                _ = store.newTab(isPrivate: false, select: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func headerIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.secondaryText)
                .frame(width: 22, height: 22)
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
        let pinned = indexedOrderedTabs.filter { $0.tab.isPinned && matchesFilter($0.tab.displayTitle, $0.tab.urlString) }
        if !pinned.isEmpty {
            sectionHeader("Pinned", count: pinned.count, collapsible: false, expanded: .constant(true))
            ForEach(pinned, id: \.tab.id) { entry in
                BrowserTabRow(
                    tab: entry.tab,
                    shortcutNumber: entry.shortcut,
                    isActive: store.activeTab?.id == entry.tab.id,
                    onSelect: { store.selectTab(entry.tab.id) },
                    onClose: { store.closeTab(entry.tab.id) },
                    onTogglePin: { store.togglePin(entry.tab.id) },
                    onDuplicate: { store.duplicateTab(entry.tab.id) },
                    onCloseOthers: { store.closeOtherTabs(keeping: entry.tab.id) }
                )
            }
            Divider().opacity(0.35).padding(.vertical, 4)
        }
    }

    // MARK: Open Tabs

    @ViewBuilder
    private var openTabsSection: some View {
        let regular = indexedOrderedTabs.filter { !$0.tab.isPinned && matchesFilter($0.tab.displayTitle, $0.tab.urlString) }
        sectionHeader("Tabs", count: regular.count, collapsible: false, expanded: .constant(true))
        if regular.isEmpty {
            Text(normalizedFilter.isEmpty ? "No open tabs" : "No matching tabs")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else {
            ForEach(regular, id: \.tab.id) { entry in
                BrowserTabRow(
                    tab: entry.tab,
                    shortcutNumber: entry.shortcut,
                    isActive: store.activeTab?.id == entry.tab.id,
                    onSelect: { store.selectTab(entry.tab.id) },
                    onClose: { store.closeTab(entry.tab.id) },
                    onTogglePin: { store.togglePin(entry.tab.id) },
                    onDuplicate: { store.duplicateTab(entry.tab.id) },
                    onCloseOthers: { store.closeOtherTabs(keeping: entry.tab.id) }
                )
            }
        }
    }

    // MARK: Bookmarks

    @ViewBuilder
    private var bookmarksSection: some View {
        let items = store.bookmarks.filter { matchesFilter($0.title, $0.url) }
        if !store.bookmarks.isEmpty || !normalizedFilter.isEmpty {
            Divider().opacity(0.35).padding(.vertical, 4)
            sectionHeader("Bookmarks", count: items.count, collapsible: true, expanded: $bookmarksExpanded)
            if bookmarksExpanded {
                ForEach(items) { bm in
                    BrowserLinkSidebarRow(
                        title: bm.title,
                        subtitle: BrowserURLResolver.displayHost(for: bm.url),
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
                        Button("Open in Safari") {
                            if let url = URL(string: bm.url) { NSWorkspace.shared.open(url) }
                        }
                        Divider()
                        Button("Remove Bookmark", role: .destructive) {
                            store.removeBookmark(id: bm.id)
                        }
                    }
                }
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

// MARK: - Sidebar Rows

private struct BrowserTabRow: View {
    let tab: BrowserTabSession
    let shortcutNumber: Int?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onDuplicate: () -> Void
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
            if tab.activeShare != nil {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .hoverTooltip("Shared with persona")
            }
            if tab.isAudioPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.accent)
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
            Button(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
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
    let symbol: String
    let symbolColor: Color
    let onTap: () -> Void

    @Environment(\.vesperTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5))
                    .foregroundStyle(symbolColor)
                    .frame(width: 14)
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
