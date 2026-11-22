import SwiftUI
import VesperCore

/// Hosts Knowledge's custom native inspector tabs (`Links`, `Properties`, `Query`, `History`, `Reviews`)
/// inside the window's native right inspector split pane and its floating popout panel.
struct KnowledgeInspectorHost: View {
    let context: NativeScreenContext
    let controller: KnowledgeShellController
    let tab: KnowledgeSidePanelsView.Tab

    var body: some View {
        Group {
            if case .page(let pageId) = controller.activeDestination {
                let entry = context.store.entry(KnowledgeAPI.getPage(id: pageId))
                if let page = entry.data {
                    KnowledgeSidePanelsView(page: page, tab: tab) { tag in
                        controller.openSearch(tag: tag, in: context)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading page\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Open a page to inspect its \(tab.rawValue.lowercased()).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .environment(context)
        .environment(\.vesperTheme, controller.theme)
        .environment(\.colorScheme, controller.colorScheme)
    }
}

/// Native Knowledge inspector panel rendered inside the right-rail inspector (and floating popout):
/// Backlinks & Unlinked Mentions, Properties Inspector, Query Table, Version History, and Reviews.
struct KnowledgeSidePanelsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case links = "Links"
        case properties = "Properties"
        case query = "Query"
        case history = "History"
        case reviews = "Reviews"

        var id: String { rawValue }

        init?(inspectorTabId: String) {
            switch inspectorTabId {
            case KnowledgeInspectorLogic.linksTabId: self = .links
            case KnowledgeInspectorLogic.propertiesTabId: self = .properties
            case KnowledgeInspectorLogic.queryTabId: self = .query
            case KnowledgeInspectorLogic.historyTabId: self = .history
            case KnowledgeInspectorLogic.reviewsTabId: self = .reviews
            default: return nil
            }
        }
    }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let page: KnowledgePage
    let tab: Tab
    let onSelectTag: (String) -> Void

    @State private var newTag = ""
    @State private var newPropKey = ""
    @State private var newPropType: KnowledgePropertyType = .text
    @State private var newPropValue = ""
    @State private var editingPropKey: String?
    @State private var editingPropValue = ""
    @State private var savingProps = false
    @State private var propError: String?

    @State private var linkingMentionId: String?
    @State private var restoringVersionId: String?
    @State private var panelError: String?

    @State private var queryText = ""
    @State private var queryTableFilter = ""
    @State private var querySortColumn: KnowledgeQuerySortColumn = .updatedAt
    @State private var querySortDirection: KnowledgeQuerySortDirection = .descending
    @State private var customQueryTable: KnowledgePageTable?
    @State private var customQueryLoading = false

    private var networkRequest: APIRequest<KnowledgeNetwork> {
        KnowledgeAPI.getNetwork(includeAgent: page.audience == .agent)
    }

    private var candidatesRequest: APIRequest<KnowledgePageTable> {
        KnowledgeAPI.listPages(includeAgent: page.audience == .agent, limit: 200)
    }

    private var savedQueryRequest: APIRequest<KnowledgePageTable> {
        KnowledgeAPI.getSavedQuery(id: page.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let panelError {
                    Text(panelError)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                switch tab {
                case .links:
                    linksPanel
                case .properties:
                    propertiesPanel
                case .query:
                    queryPanel
                case .history:
                    historyPanel
                case .reviews:
                    KnowledgeReviewView(page: page)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: page.id) {
            context.store.load(networkRequest)
            context.store.load(candidatesRequest)
            if page.properties["query"] != nil {
                context.store.load(savedQueryRequest)
            }
        }
    }

    // MARK: - Links & Unlinked Mentions

    private var linksPanel: some View {
        let p = theme.palette
        let network = context.store.entry(networkRequest).data ?? KnowledgeNetwork()
        let candidates = context.store.entry(candidatesRequest).data?.rows ?? []
        let backlinks = KnowledgePanelsLogic.backlinks(for: page.id, in: network)
        let outgoing = KnowledgePanelsLogic.outgoingLinks(for: page.id, in: network)
        let mentions = KnowledgePanelsLogic.findUnlinkedMentions(
            of: page,
            in: candidates,
            linkedSourceIds: Set(backlinks.map(\.id))
        )

        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Backlinks", count: backlinks.count)
            if backlinks.isEmpty {
                emptyCaption("No other pages link here yet.")
            } else {
                ForEach(backlinks) { item in
                    linkRow(title: item.title, subtitle: KnowledgeShellLogic.folderDisplay(of: item.path)) {
                        context.navigate(KnowledgeShellLogic.pageHref(id: item.id, title: item.title))
                    }
                }
            }

            sectionHeader("Outgoing links", count: outgoing.resolved.count + outgoing.unresolved.count)
            if outgoing.resolved.isEmpty && outgoing.unresolved.isEmpty {
                emptyCaption("No outgoing wikilinks on this page.")
            } else {
                ForEach(outgoing.resolved) { item in
                    linkRow(title: item.title, subtitle: KnowledgeShellLogic.folderDisplay(of: item.path)) {
                        context.navigate(KnowledgeShellLogic.pageHref(id: item.id, title: item.title))
                    }
                }
                ForEach(outgoing.unresolved, id: \.self) { missing in
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                        Text(missing)
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        TonePill(label: "Unresolved", tone: "neutral")
                    }
                    .padding(7)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }

            sectionHeader("Unlinked mentions", count: mentions.count)
            if mentions.isEmpty {
                emptyCaption("No unlinked mentions found in page summaries.")
            } else {
                ForEach(mentions) { mention in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button(mention.pageTitle) {
                                context.navigate(KnowledgeShellLogic.pageHref(id: mention.pageId, title: mention.pageTitle))
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.accent)
                            .lineLimit(1)

                            Spacer()

                            Button(linkingMentionId == mention.id ? "Linking…" : "Link") {
                                linkMention(mention)
                            }
                            .buttonStyle(.vesper())
                            .controlSize(.mini)
                            .disabled(linkingMentionId != nil)
                        }
                        Text(mention.snippet)
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }
        }
    }

    // MARK: - Typed Properties Inspector

    private var propertiesPanel: some View {
        let p = theme.palette
        let tags = KnowledgeShellLogic.tags(of: page.properties)
        let fields = KnowledgePanelsLogic.editableProperties(from: page.properties)

        return VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Tags", count: tags.count)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Button("#\(tag)") { onSelectTag(tag) }
                                .buttonStyle(.plain)
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(p.accent)
                            Button {
                                saveProperties(KnowledgePanelsLogic.removingTag(tag, from: page.properties))
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .disabled(savingProps)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Capsule())
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add tag…", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: theme.pointSize(.small)))
                    .onSubmit { addTag() }
                Button("Add") { addTag() }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                    .disabled(savingProps || newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider().overlay(p.border)

            sectionHeader("Properties", count: fields.count)
            if fields.isEmpty {
                emptyCaption("No custom properties on this page.")
            } else {
                ForEach(fields) { field in
                    propertyRow(field)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Add property")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                TextField("Key (e.g. status, due)", text: $newPropKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: theme.pointSize(.small)))
                Picker("Type", selection: $newPropType) {
                    ForEach(KnowledgePropertyType.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                TextField(propertyPlaceholder(for: newPropType), text: $newPropValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: theme.pointSize(.small)))
                    .onSubmit { addProperty() }
                Button("Save property") { addProperty() }
                    .buttonStyle(.vesper(.primary))
                    .controlSize(.small)
                    .disabled(savingProps || newPropKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))

            if let propError {
                Text(propError)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
    }

    private func propertyRow(_ field: KnowledgePropertyField) -> some View {
        let p = theme.palette
        let isEditing = editingPropKey == field.key

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(field.key)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.secondaryText)
                TonePill(label: field.type.rawValue, tone: "neutral")
                Spacer()
                if field.type == .bool, case .bool(let current) = field.value {
                    Toggle("", isOn: Binding(
                        get: { current },
                        set: { next in
                            saveProperties(KnowledgePanelsLogic.settingProperty(field.key, value: .bool(next), in: page.properties))
                        }
                    ))
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(savingProps)
                } else {
                    Button {
                        if isEditing {
                            editingPropKey = nil
                        } else {
                            editingPropKey = field.key
                            editingPropValue = KnowledgePanelsLogic.formatQueryCell(field.value)
                        }
                    } label: {
                        Image(systemName: isEditing ? "xmark" : "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    saveProperties(KnowledgePanelsLogic.removingProperty(field.key, from: page.properties))
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                .buttonStyle(.plain)
                .disabled(savingProps)
            }

            if isEditing {
                HStack(spacing: 6) {
                    TextField("Value", text: $editingPropValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: theme.pointSize(.small)))
                        .onSubmit {
                            let parsed = KnowledgePanelsLogic.parsePropertyValue(editingPropValue, as: field.type)
                            saveProperties(KnowledgePanelsLogic.settingProperty(field.key, value: parsed, in: page.properties))
                            editingPropKey = nil
                        }
                    Button("Save") {
                        let parsed = KnowledgePanelsLogic.parsePropertyValue(editingPropValue, as: field.type)
                        saveProperties(KnowledgePanelsLogic.settingProperty(field.key, value: parsed, in: page.properties))
                        editingPropKey = nil
                    }
                    .buttonStyle(.vesper(.primary))
                    .controlSize(.mini)
                    .disabled(savingProps)
                }
            } else if field.type != .bool {
                Text(KnowledgeShellLogic.formatPropertyValue(field.value))
                    .vesperText(.small, theme)
                    .foregroundStyle(p.text)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
    }

    // MARK: - Query Table Panel

    private var queryPanel: some View {
        let p = theme.palette
        let savedEntry = page.properties["query"] != nil ? context.store.entry(savedQueryRequest) : nil
        let table = customQueryTable ?? savedEntry?.data
        let rawRows = table?.rows ?? []
        let columns = KnowledgePanelsLogic.queryTableColumns(for: rawRows, maxColumns: 3)
        let rows = KnowledgePanelsLogic.filterAndSortQueryRows(
            rawRows,
            filterText: queryTableFilter,
            sortColumn: querySortColumn,
            direction: querySortDirection
        )

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Query pages", count: rows.count)

            HStack(spacing: 6) {
                TextField("Search query…", text: $queryText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: theme.pointSize(.small)))
                    .onSubmit { runCustomQuery() }
                Button(customQueryLoading ? "…" : "Run") { runCustomQuery() }
                    .buttonStyle(.vesper(.primary))
                    .controlSize(.small)
                    .disabled(customQueryLoading)
            }

            if !rawRows.isEmpty {
                HStack(spacing: 6) {
                    TextField("Filter rows…", text: $queryTableFilter)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: theme.pointSize(.small)))
                    Button {
                        if querySortColumn == .title {
                            querySortDirection = querySortDirection.toggled
                        } else {
                            querySortColumn = .title
                            querySortDirection = .ascending
                        }
                    } label: {
                        Image(systemName: querySortDirection == .ascending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                    .help("Sort by title")
                }
            }

            if rows.isEmpty {
                emptyCaption(page.properties["query"] != nil
                             ? "No pages match this query yet."
                             : "Run a query above to inspect matching pages and properties.")
            } else {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Button(KnowledgeShellLogic.displayTitle(for: row)) {
                            context.navigate(KnowledgeShellLogic.pageHref(id: row.id, title: row.title))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.accent)
                        .lineLimit(1)

                        ForEach(columns, id: \.self) { col in
                            let val = KnowledgePanelsLogic.formatQueryCell(row.properties[col])
                            if val != "—" {
                                HStack(spacing: 4) {
                                    Text("\(col):")
                                        .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                        .foregroundStyle(p.tertiaryText)
                                    Text(val)
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(p.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                        }

                        HStack {
                            Text(row.audience.rawValue.capitalized)
                            Spacer()
                            Text(KnowledgeShellLogic.relativeAgo(row.updatedAt))
                        }
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }
        }
    }

    // MARK: - Version History & Restore

    private var historyPanel: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Version history", count: page.versions.count)
            if page.versions.isEmpty {
                emptyCaption("No saved versions yet.")
            } else {
                ForEach(page.versions) { version in
                    let isCurrent = version.id == page.versionId
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(version.label.isEmpty ? "v\(version.seq)" : version.label)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                .foregroundStyle(p.text)
                            if isCurrent {
                                TonePill(label: "Current", tone: "done")
                            }
                            Spacer()
                            Text(KnowledgeShellLogic.relativeAgo(version.createdAt))
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                        }
                        if !version.note.isEmpty {
                            Text(version.note)
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(3)
                        }
                        HStack {
                            Text(version.authorType == "agent" ? "Persona edit" : "You")
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                            Spacer()
                            if !isCurrent {
                                Button(restoringVersionId == version.id ? "Restoring…" : "Restore") {
                                    restoreVersion(version)
                                }
                                .buttonStyle(.vesper())
                                .controlSize(.mini)
                                .disabled(restoringVersionId != nil)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }
        }
    }

    // MARK: - Helpers & Mutations

    private func sectionHeader(_ title: String, count: Int) -> some View {
        let p = theme.palette
        return HStack {
            Text(title.uppercased())
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.tertiaryText)
            Spacer()
            Text("\(count)")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.tertiaryText)
        }
    }

    private func emptyCaption(_ text: String) -> some View {
        Text(text)
            .vesperText(.small, theme)
            .foregroundStyle(theme.palette.tertiaryText)
    }

    private func linkRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.accent)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        }
        .buttonStyle(.plain)
    }

    private func propertyPlaceholder(for type: KnowledgePropertyType) -> String {
        switch type {
        case .text: return "Value"
        case .number: return "42"
        case .bool: return "true or false"
        case .date: return "YYYY-MM-DD"
        case .list: return "item 1, item 2"
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newTag = ""
        saveProperties(KnowledgePanelsLogic.addingTag(trimmed, to: page.properties))
    }

    private func addProperty() {
        let key = newPropKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let value = KnowledgePanelsLogic.parsePropertyValue(newPropValue, as: newPropType)
        newPropKey = ""
        newPropValue = ""
        saveProperties(KnowledgePanelsLogic.settingProperty(key, value: value, in: page.properties))
    }

    private func saveProperties(_ updated: [String: JSONValue]) {
        propError = nil
        savingProps = true
        Task {
            defer { savingProps = false }
            do {
                _ = try await context.store.mutate(
                    KnowledgeAPI.updatePage(
                        id: page.id,
                        body: KnowledgePageInput(properties: updated, baseVersionId: page.versionId)
                    ),
                    invalidating: KnowledgeAPI.invalidation
                )
            } catch {
                propError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func linkMention(_ mention: KnowledgeUnlinkedMention) {
        guard let client = context.store.client else { return }
        panelError = nil
        linkingMentionId = mention.id
        Task {
            defer { linkingMentionId = nil }
            do {
                let sourcePage = try await client.send(KnowledgeAPI.getPage(id: mention.pageId))
                guard let body = sourcePage.bodyMd,
                      let patched = KnowledgePanelsLogic.linkFirstMention(
                        in: body,
                        term: mention.matchedTerm,
                        targetTitle: page.title
                      )
                else {
                    panelError = "Could not find an unlinked occurrence of \"\(mention.matchedTerm)\" in \(mention.pageTitle)."
                    return
                }
                _ = try await context.store.mutate(
                    KnowledgeAPI.updatePage(
                        id: sourcePage.id,
                        body: KnowledgePageInput(
                            bodyMd: patched,
                            baseVersionId: sourcePage.versionId,
                            note: "Linked mention to \(page.title)"
                        )
                    ),
                    invalidating: KnowledgeAPI.invalidation
                )
            } catch {
                panelError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func runCustomQuery() {
        guard let client = context.store.client else { return }
        panelError = nil
        customQueryLoading = true
        let q = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { customQueryLoading = false }
            do {
                let body = KnowledgePageQuery(
                    text: q.isEmpty ? nil : q,
                    includeAgent: page.audience == .agent ? true : nil,
                    limit: 50
                )
                customQueryTable = try await client.send(KnowledgeAPI.queryPages(body))
            } catch {
                panelError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func restoreVersion(_ version: KnowledgeVersion) {
        panelError = nil
        restoringVersionId = version.id
        Task {
            defer { restoringVersionId = nil }
            do {
                _ = try await context.store.mutate(
                    KnowledgeAPI.restoreVersion(id: page.id, versionId: version.id),
                    invalidating: KnowledgeAPI.invalidation
                )
            } catch {
                panelError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
