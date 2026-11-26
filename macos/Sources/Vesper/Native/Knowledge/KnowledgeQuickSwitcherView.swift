import AppKit
import SwiftUI
import VesperCore

extension Notification.Name {
    static let vesperOpenKnowledgeQuickSwitcher = Notification.Name("VesperOpenKnowledgeQuickSwitcher")
}

/// Spotlight-style keyboard-first Quick Switcher (`⌘O` / `⌘K`) for Knowledge:
/// fuzzy-jumps to any doc, heading (live current doc + cross-doc), or attachment in `attachments/`.
struct KnowledgeQuickSwitcherView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let controller: KnowledgeShellController
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var scope: KnowledgeQuickSwitcherScope = .all
    @State private var activeIndex = 0
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    private var currentPageId: String? {
        controller.activeDestination.activePageId
    }

    private var currentPage: KnowledgePage? {
        guard let pageId = currentPageId else { return nil }
        return context.store.entry(KnowledgeAPI.getPage(id: pageId)).data
    }

    private var currentHeadings: [KnowledgeOutlineHeading] {
        guard let pageId = currentPageId else { return [] }
        return controller.currentHeadings(for: pageId, loadedPage: currentPage)
    }

    private var results: [KnowledgeQuickSwitcherItem] {
        let pages = controller.rows(in: context)
        let attachments = controller.viewMode == .yours ? controller.attachments(in: context) : []
        let vaultHeadings = context.store.entry(controller.headingsRequest).data?.headings ?? []
        return KnowledgeQuickSwitcherLogic.search(
            query: query,
            scope: scope,
            pages: pages,
            attachments: attachments,
            vaultHeadings: vaultHeadings,
            currentPageId: currentPageId,
            currentPageTitle: currentPage?.title,
            currentHeadings: currentHeadings,
            limit: 40
        )
    }

    private var clampedActiveIndex: Int {
        guard !results.isEmpty else { return 0 }
        return min(max(activeIndex, 0), results.count - 1)
    }

    var body: some View {
        let p = theme.palette
        let items = results
        let selectedIdx = items.isEmpty ? 0 : min(max(activeIndex, 0), items.count - 1)

        ZStack(alignment: .top) {
            Color.black.opacity(theme.mode == .dark ? 0.45 : 0.22)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                searchHeader
                Divider().overlay(p.border)
                scopeBar
                Divider().overlay(p.border)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if items.isEmpty {
                                emptyState
                            } else {
                                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                    resultRow(item, isSelected: idx == selectedIdx) {
                                        activate(item, newTab: context.currentEventModifiers.contains(.command))
                                    }
                                    .id(item.id)
                                    .onHover { hovering in
                                        if hovering { activeIndex = idx }
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIdx) { _, nextIdx in
                        if items.indices.contains(nextIdx) {
                            proxy.scrollTo(items[nextIdx].id, anchor: .center)
                        }
                    }
                }

                Divider().overlay(p.border)
                footerBar
            }
            .frame(width: 580)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .padding(.top, 64)
        }
        .onAppear {
            searchFocused = true
            context.store.load(controller.headingsRequest)
            context.store.load(KnowledgeShellController.attachmentsRequest)
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: query) { _, _ in
            activeIndex = 0
        }
        .onChange(of: scope) { _, _ in
            activeIndex = 0
        }
    }

    private var searchHeader: some View {
        let p = theme.palette
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(p.accent)

            TextField("Jump to doc, #heading, or !attachment\u{2026}", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: theme.pointSize(.body) + 1))
                .focused($searchFocused)
                .onSubmit {
                    confirmSelection(newTab: false, quickLook: false)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear query")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var scopeBar: some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            ForEach(KnowledgeQuickSwitcherScope.allCases) { item in
                let active = scope == item
                Button {
                    scope = item
                } label: {
                    Text(scopeLabel(item))
                        .font(.system(size: theme.pointSize(.micro) + 1, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? p.accent : p.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            active ? theme.swiftUIColor("accent-soft", fallback: p.selected) : .clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Tab to switch")
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.tertiaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    private func scopeLabel(_ s: KnowledgeQuickSwitcherScope) -> String {
        switch s {
        case .all: return "All"
        case .pages: return "Docs"
        case .headings: return "# Headings"
        case .attachments: return "! Attachments"
        }
    }

    private func resultRow(
        _ item: KnowledgeQuickSwitcherItem,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let p = theme.palette
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: item))
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? p.accent : p.secondaryText)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: theme.pointSize(.small) + 0.5, weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: theme.pointSize(.micro) + 0.5))
                            .foregroundStyle(p.tertiaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if let badge = item.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))
                        .foregroundStyle(badge == "Unused" ? theme.swiftUIColor("pill-human-fg", fallback: .orange) : p.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        let p = theme.palette
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let createTitle = cleaned
            .trimmingCharacters(in: CharacterSet(charactersIn: "#!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8) {
            Text(cleaned.isEmpty ? "Start typing to jump across Knowledge." : "No matching docs, headings, or attachments.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
            if !createTitle.isEmpty {
                Button {
                    createPageFromQuery()
                } label: {
                    Label("Create \u{201C}\(createTitle)\u{201D}", systemImage: "plus")
                }
                .buttonStyle(.vesper(.primary))
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footerBar: some View {
        let p = theme.palette
        return HStack(spacing: 12) {
            keyHint("\u{21B5}", "Open")
            keyHint("\u{2318}\u{21B5}", "New tab")
            keyHint("\u{2325}\u{21B5}", "Quick Look")
            keyHint("\u{21E7}\u{21B5}", "New doc")
            Spacer()
            Button {
                onDismiss()
                context.openCommandPalette(CommandPaletteRequest(scope: .all))
            } label: {
                Text("Global Palette")
                    .font(.system(size: theme.pointSize(.micro) + 0.5, weight: .medium))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    private func keyHint(_ keys: String, _ label: String) -> some View {
        let p = theme.palette
        return HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(p.secondaryText)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(p.border))
            Text(label)
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.tertiaryText)
        }
    }

    private func symbol(for item: KnowledgeQuickSwitcherItem) -> String {
        switch item.target {
        case .page(let row):
            return KnowledgeShellLogic.pageSymbol(for: row)
        case .currentHeading, .vaultHeading:
            return "number"
        case .attachment(let att):
            return KnowledgeAttachmentActions.sfSymbol(for: att.contentType, filename: att.filename)
        }
    }

    // MARK: - Activation & Keyboard Monitor

    private func confirmSelection(newTab: Bool, quickLook: Bool) {
        let items = results
        guard !items.isEmpty else {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                createPageFromQuery()
            }
            return
        }
        let item = items[clampedActiveIndex]
        if quickLook, case .attachment(let att) = item.target {
            onDismiss()
            KnowledgeAttachmentActions.openFullscreen(
                url: att.url,
                title: att.filename,
                contentType: att.contentType,
                context: context
            )
            return
        }
        activate(item, newTab: newTab)
    }

    private func activate(_ item: KnowledgeQuickSwitcherItem, newTab: Bool) {
        onDismiss()
        switch item.target {
        case .page(let row):
            controller.openPage(row, in: context, newTab: newTab)
        case .currentHeading(let pageId, _, let heading):
            controller.jumpToHeading(pageId: pageId, heading: heading)
        case .vaultHeading(let row):
            controller.jumpToVaultHeading(row, in: context, newTab: newTab)
        case .attachment(let att):
            controller.openAttachment(att, in: context, newTab: newTab)
        }
    }

    private func createPageFromQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled" : trimmed
        onDismiss()
        controller.createDocument(title: title, inFolder: "Inbox", in: context)
    }

    private func stepScope(backwards: Bool) {
        let all = KnowledgeQuickSwitcherScope.allCases
        guard let idx = all.firstIndex(of: scope) else { return }
        let next = (idx + (backwards ? -1 : 1) + all.count) % all.count
        scope = all[next]
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard context.isActiveTab, event.window === context.window()?.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Escape closes
            if event.keyCode == 53 {
                onDismiss()
                return nil
            }
            // Arrow Up / Ctrl+P
            if event.keyCode == 126 || (flags == .control && chars == "p") {
                let count = results.count
                if count > 0 { activeIndex = (clampedActiveIndex - 1 + count) % count }
                return nil
            }
            // Arrow Down / Ctrl+N
            if event.keyCode == 125 || (flags == .control && chars == "n") {
                let count = results.count
                if count > 0 { activeIndex = (clampedActiveIndex + 1) % count }
                return nil
            }
            // Tab / Shift+Tab switches scope
            if event.keyCode == 48 {
                stepScope(backwards: flags.contains(.shift))
                return nil
            }
            // Return / Enter with modifiers
            if event.keyCode == 36 || event.keyCode == 76 {
                if flags == .command {
                    confirmSelection(newTab: true, quickLook: false)
                    return nil
                }
                if flags == .option {
                    confirmSelection(newTab: false, quickLook: true)
                    return nil
                }
                if flags == .shift {
                    createPageFromQuery()
                    return nil
                }
                if flags.isEmpty {
                    confirmSelection(newTab: false, quickLook: false)
                    return nil
                }
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
