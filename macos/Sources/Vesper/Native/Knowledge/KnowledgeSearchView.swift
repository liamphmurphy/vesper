import SwiftUI
import VesperCore

/// Full-text and structured Knowledge search with tag, folder, property, audience, kind, orphan, and unresolved filters.
struct KnowledgeSearchView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Bindable var controller: KnowledgeShellController

    @State private var results: [KnowledgePageRow] = []
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var searchError: String?
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    var body: some View {
        let p = theme.palette
        let allRows = controller.rows(in: context)
        let tree = KnowledgeShellLogic.buildTree(from: allRows, prioritizeInbox: true)
        let folders = KnowledgeShellLogic.folderPaths(in: tree)
        let tags = KnowledgeShellLogic.extractTags(from: allRows)
        let propKeys = KnowledgeShellLogic.extractPropertyKeys(from: allRows)
        let visibleResults = results.filter { controller.searchFilter.matchesClientSidePropertyKey($0) }

        VStack(spacing: 0) {
            searchHeader(folders: folders, tags: tags, propKeys: propKeys)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Divider().overlay(p.border)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        resultsBody(visibleResults)
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: context.find.current) { _, idx in
                    guard let idx, idx < visibleResults.count else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(visibleResults[idx].id, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: visibleResults.map(\.title), initial: true) { _, titles in
            context.find.texts = titles
        }
        .onAppear {
            queryFocused = true
            runSearch(reset: true)
        }
        .onChange(of: controller.searchFilter) { _, _ in
            scheduleSearch()
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    // MARK: - Search Controls

    private func searchHeader(
        folders: [String],
        tags: [(tag: String, count: Int)],
        propKeys: [String]
    ) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(p.tertiaryText)
                    TextField("Search pages, titles, summaries\u{2026}", text: $controller.searchFilter.text)
                        .textFieldStyle(.plain)
                        .font(.system(size: theme.pointSize(.reading)))
                        .focused($queryFocused)
                        .onSubmit {
                            debounceTask?.cancel()
                            runSearch(reset: true)
                        }
                    if !controller.searchFilter.text.isEmpty {
                        Button {
                            controller.searchFilter.text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(queryFocused ? p.accent : p.border))

                if controller.searchFilter.hasActiveFilters {
                    Button("Clear") {
                        controller.searchFilter = KnowledgeSearchFilter()
                    }
                    .buttonStyle(.vesper())
                }
            }

            FlowLayout(spacing: 8) {
                // Tag filter
                HStack(spacing: 4) {
                    Text("#")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                    TextField("tag", text: $controller.searchFilter.tag)
                        .textFieldStyle(.plain)
                        .frame(width: 90)
                        .font(.system(size: theme.pointSize(.small)))
                    if !tags.isEmpty {
                        Menu {
                            Button("Any tag") { controller.searchFilter.tag = "" }
                            Divider()
                            ForEach(tags.prefix(30), id: \.tag) { item in
                                Button("#\(item.tag) (\(item.count))") {
                                    controller.searchFilter.tag = item.tag
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))

                // Folder picker
                Menu {
                    Button("Any folder") { controller.searchFilter.folder = "" }
                    Divider()
                    ForEach(folders, id: \.self) { folder in
                        Button(folder) { controller.searchFilter.folder = folder }
                    }
                } label: {
                    filterPillLabel(
                        symbol: "folder",
                        text: controller.searchFilter.folder.isEmpty ? "Folder: Any" : controller.searchFilter.folder,
                        active: !controller.searchFilter.folder.isEmpty
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Audience picker
                Menu {
                    Button("Any audience") { controller.searchFilter.audience = nil }
                    Divider()
                    ForEach(KnowledgeAudience.allCases, id: \.self) { aud in
                        Button(aud.rawValue.capitalized) {
                            controller.searchFilter.audience = aud
                        }
                    }
                } label: {
                    filterPillLabel(
                        symbol: "lock",
                        text: controller.searchFilter.audience.map { "Audience: \($0.rawValue.capitalized)" } ?? "Audience: Any",
                        active: controller.searchFilter.audience != nil
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Kind picker
                Menu {
                    Button("Any kind") { controller.searchFilter.kind = nil }
                    Divider()
                    ForEach(KnowledgePageKind.allCases, id: \.self) { kind in
                        Button(kind.rawValue.capitalized) {
                            controller.searchFilter.kind = kind
                        }
                    }
                } label: {
                    filterPillLabel(
                        symbol: "doc.text",
                        text: controller.searchFilter.kind.map { "Kind: \($0.rawValue.capitalized)" } ?? "Kind: Any",
                        active: controller.searchFilter.kind != nil
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Property key = value
                HStack(spacing: 4) {
                    TextField("property", text: $controller.searchFilter.propertyKey)
                        .textFieldStyle(.plain)
                        .frame(width: 78)
                        .font(.system(size: theme.pointSize(.small)))
                    if !propKeys.isEmpty {
                        Menu {
                            Button("Clear property") {
                                controller.searchFilter.propertyKey = ""
                                controller.searchFilter.propertyValue = ""
                            }
                            Divider()
                            ForEach(propKeys.prefix(25), id: \.self) { key in
                                Button(key) { controller.searchFilter.propertyKey = key }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    Text("=")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                    TextField("value", text: $controller.searchFilter.propertyValue)
                        .textFieldStyle(.plain)
                        .frame(width: 78)
                        .font(.system(size: theme.pointSize(.small)))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))

                toggleChip(title: "Orphans", isOn: $controller.searchFilter.orphansOnly)
                toggleChip(title: "Unresolved", isOn: $controller.searchFilter.unresolvedOnly)
                toggleChip(title: "Include agent", isOn: $controller.searchFilter.includeAgent)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func filterPillLabel(symbol: String, text: String, active: Bool) -> some View {
        let p = theme.palette
        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: theme.pointSize(.small)))
                .lineLimit(1)
        }
        .foregroundStyle(active ? p.accent : p.text)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(active ? theme.swiftUIColor("accent-soft", fallback: p.selected) : p.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? p.accent : p.border))
    }

    private func toggleChip(title: String, isOn: Binding<Bool>) -> some View {
        let p = theme.palette
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: theme.pointSize(.small), weight: isOn.wrappedValue ? .semibold : .regular))
                .foregroundStyle(isOn.wrappedValue ? p.accent : p.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(isOn.wrappedValue ? theme.swiftUIColor("accent-soft", fallback: p.selected) : p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(isOn.wrappedValue ? p.accent : p.border))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results

    @ViewBuilder
    private func resultsBody(_ visibleResults: [KnowledgePageRow]) -> some View {
        let p = theme.palette
        if let searchError {
            QueryErrorView(message: searchError) {
                runSearch(reset: true)
            }
        } else if isLoading && visibleResults.isEmpty {
            VStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { _ in SkeletonBar(height: 36) }
            }
        } else if visibleResults.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(p.tertiaryText)
                Text("No matching pages")
                    .vesperText(.heading, theme)
                Text("Try fewer filters, another #tag, or enable Include agent.")
                    .vesperText(.body, theme)
                    .foregroundStyle(p.secondaryText)
            }
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        } else {
            HStack {
                Text("\(visibleResults.count)\(hasMore ? "+" : "") \(visibleResults.count == 1 ? "result" : "results")")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            VStack(spacing: 0) {
                ForEach(visibleResults) { row in
                    resultRow(row)
                        .id(row.id)
                    Divider().overlay(p.rowBorder)
                }
            }

            if hasMore {
                Button(isLoadingMore ? "Loading\u{2026}" : "Load more") {
                    runSearch(reset: false)
                }
                .buttonStyle(.vesper())
                .disabled(isLoadingMore)
                .padding(.top, 6)
            }
        }
    }

    private func resultRow(_ row: KnowledgePageRow) -> some View {
        let p = theme.palette
        let hit = context.find.matches(row.title)
        let rowTags = KnowledgeShellLogic.tags(of: row.properties)

        return Button {
            let newTab = context.currentEventModifiers.contains(.command)
            controller.openPage(row, in: context, newTab: newTab)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: KnowledgeShellLogic.pageSymbol(for: row))
                    .font(.system(size: 14))
                    .foregroundStyle(p.tertiaryText)
                    .padding(.top, 2)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(KnowledgeShellLogic.displayTitle(for: row))
                            .font(.system(size: theme.pointSize(.body), weight: .semibold))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        if row.pending > 0 {
                            TonePill(label: "\(row.pending) pending", tone: "human")
                        }
                        if row.unresolved > 0 {
                            TonePill(label: "\(row.unresolved) unresolved", tone: "neutral")
                        }
                    }

                    Text(KnowledgeShellLogic.folderDisplay(of: row.path) + (row.summary.isEmpty ? "" : " \u{00B7} \(row.summary)"))
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(2)

                    if !rowTags.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(rowTags.prefix(6), id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.system(size: theme.pointSize(.micro) + 1))
                                    .foregroundStyle(p.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Capsule())
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(KnowledgeShellLogic.relativeAgo(row.updatedAt))
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                    Text(row.audience.rawValue.capitalized)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(hit ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { controller.openPage(row, in: context) }
            Button("Open in New Tab") { controller.openPage(row, in: context, newTab: true) }
            Divider()
            Button("Copy [[wikilink]]") { controller.copyPageWikilink(row, in: context) }
            Button("Copy Link") { controller.copyPageLink(row, in: context) }
            Divider()
            Button("Rename\u{2026}") { controller.sheet = .renamePage(row) }
            Button("Move to\u{2026}") { controller.sheet = .move(target: .page(row)) }
            Button("Delete\u{2026}", role: .destructive) { controller.sheet = .delete(target: .page(row)) }
        }
    }

    // MARK: - Search Execution

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            runSearch(reset: true)
        }
    }

    private func runSearch(reset: Bool) {
        guard let client = context.store.client else {
            searchError = APIError.unauthorized.userMessage
            return
        }
        var filter = controller.searchFilter
        filter.offset = reset ? 0 : results.count
        let request = filter.buildRequest()

        if reset {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        searchError = nil

        Task {
            do {
                let table = try await client.send(request)
                guard !Task.isCancelled else { return }
                if reset {
                    results = table.rows
                } else {
                    var seen = Set(results.map(\.id))
                    for row in table.rows where seen.insert(row.id).inserted {
                        results.append(row)
                    }
                }
                hasMore = table.hasMore
                isLoading = false
                isLoadingMore = false
            } catch is CancellationError {
                return
            } catch {
                searchError = (error as? APIError)?.userMessage ?? error.localizedDescription
                isLoading = false
                isLoadingMore = false
            }
        }
    }
}
