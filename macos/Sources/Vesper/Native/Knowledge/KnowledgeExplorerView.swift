import SwiftUI
import VesperCore

/// Publishes the Knowledge explorer sidebar with reactive theme and context environment.
struct KnowledgeSidebarHost: View {
    let context: NativeScreenContext
    let controller: KnowledgeShellController

    var body: some View {
        KnowledgeExplorerView(controller: controller)
            .environment(context)
            .environment(\.vesperTheme, controller.theme)
            .environment(\.colorScheme, controller.colorScheme)
    }
}

/// Compact Obsidian-style hierarchical explorer published via `context.sidebarView`.
struct KnowledgeExplorerView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Bindable var controller: KnowledgeShellController

    @State private var rootDropTargeted = false
    @State private var targetedFolderDropPath: String?
    @FocusState private var inlineRenameFocused: Bool

    var body: some View {
        let p = theme.palette
        let allRows = controller.rows(in: context)
        let allAttachments = controller.viewMode == .yours ? controller.attachments(in: context) : []
        let filteredRows = KnowledgeShellLogic.filterRows(allRows, matching: controller.treeFilter)
        let filteredAttachments = KnowledgeShellLogic.filterAttachments(allAttachments, matching: controller.treeFilter)
        let isFiltering = !controller.treeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tree = KnowledgeShellLogic.buildTree(
            from: filteredRows,
            attachments: filteredAttachments,
            prioritizeInbox: true,
            includeEmptyAttachmentsFolder: controller.viewMode == .yours && !isFiltering
        )
        let effectiveExpanded = isFiltering
            ? Set(KnowledgeShellLogic.folderPaths(in: tree))
            : controller.expandedFolders
        let flatRows = KnowledgeShellLogic.flattenTree(
            tree,
            expanded: effectiveExpanded,
            showAll: controller.showAllFolders,
            activePageId: controller.activeDestination.activePageId,
            activeAttachmentId: controller.activeDestination.activeAttachmentId
        )
        let selectableRowIds = flatRows.compactMap { row -> String? in
            switch row.kind {
            case .folder, .page: return row.id
            case .attachment, .showMore: return nil
            }
        }
        let pinnedPages = controller.pinnedPages(from: allRows)
        let entry = context.store.entry(controller.treeListRequest)

        VStack(spacing: 0) {
            headerBar
            modePicker
            filterField
            if controller.selectMode || controller.selection.selected.count > 1 {
                bulkActionBar(allRows: allRows)
            }
            Divider().overlay(p.border)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    staticNavRows

                    if !pinnedPages.isEmpty && !isFiltering {
                        sectionHeader("Pinned")
                        ForEach(pinnedPages) { page in
                            pinnedPageRow(page, allRows: allRows, tree: tree)
                        }
                    }

                    if entry.data == nil && entry.error == nil {
                        VStack(spacing: 6) {
                            ForEach(0..<6, id: \.self) { _ in
                                SkeletonBar(height: 18)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    } else if let error = entry.error, allRows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error.userMessage)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                            Button("Retry") {
                                controller.refreshAll(in: context)
                            }
                            .buttonStyle(.vesper())
                        }
                        .padding(10)
                    } else if flatRows.isEmpty {
                        emptyTreeMessage(isFiltering: isFiltering)
                    } else {
                        sectionHeader(pinnedPages.isEmpty ? nil : "Folders", trailingDropHint: true)
                            .padding(.top, 2)
                        ForEach(flatRows) { row in
                            explorerRow(
                                row,
                                allRows: allRows,
                                selectableIds: selectableRowIds,
                                expanded: effectiveExpanded,
                                tree: tree
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                return controller.handleDrop(payload, ontoFolder: "", in: context)
            } isTargeted: { targeted in
                rootDropTargeted = targeted
            }

            Divider().overlay(p.border)
            footerQuickActions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header, Mode & Filter

    private var headerBar: some View {
        let p = theme.palette
        let starters = context.store.entry(KnowledgeShellController.slideStartersRequest).data?.starters ?? []

        return HStack(spacing: 2) {
            headerIconButton(symbol: "point.3.connected.trianglepath.dotted", help: "Graph view") {
                context.navigate("/knowledge/graph")
            }
            headerIconButton(symbol: "link", help: "Keep notes connected") {
                context.navigate("/knowledge/connect")
            }
            headerIconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Collapse all folders") {
                controller.collapseAll()
            }
            headerIconButton(
                symbol: "checklist",
                help: controller.selectMode ? "Done selecting" : "Select multiple",
                active: controller.selectMode
            ) {
                controller.selectMode.toggle()
                if !controller.selectMode {
                    controller.selection.clear()
                }
            }

            Menu {
                Button {
                    controller.createDocument(in: context)
                } label: {
                    Label("New Document", systemImage: "doc.text")
                }

                Menu {
                    Button("Blank") {
                        controller.createDeck(in: context)
                    }
                    if !starters.isEmpty {
                        Divider()
                        ForEach(starters, id: \.key) { starter in
                            Button("\(starter.name) (\(starter.slideCount))") {
                                controller.createDeck(
                                    title: starter.name,
                                    starter: API.CreateDeckBody.Starter(rawValue: starter.key),
                                    in: context
                                )
                            }
                        }
                    }
                } label: {
                    Label("New Deck", systemImage: "play.rectangle")
                }

                Menu {
                    ForEach(KnowledgeDesignStarterOption.all, id: \.starter.rawValue) { option in
                        Button(option.label) {
                            controller.createDesign(starter: option.starter, in: context)
                        }
                    }
                } label: {
                    Label("New Design", systemImage: "pencil.and.ruler")
                }

                Divider()

                Button {
                    controller.sheet = .newFolder(parent: "")
                } label: {
                    Label("New Folder\u{2026}", systemImage: "folder.badge.plus")
                }

                Button {
                    controller.openToday(in: context)
                } label: {
                    Label("Today\u{2019}s Note", systemImage: "clock")
                }

                Button {
                    controller.sheet = .capture
                } label: {
                    Label("Quick Capture\u{2026}", systemImage: "tray.and.arrow.down")
                }

                Divider()

                Button {
                    controller.sheet = .vaultImport
                } label: {
                    Label("Import Obsidian Vault\u{2026}", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.accent)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .hoverTooltip("New page, deck, design or folder")
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func headerIconButton(
        symbol: String,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(active ? p.accent : p.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(active ? theme.swiftUIColor("accent-soft", fallback: p.selected) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(help, highlightHover: !active, cornerRadius: 5)
    }

    private var modePicker: some View {
        Picker("View", selection: $controller.viewMode) {
            Text("Yours").tag(KnowledgeViewMode.yours)
            Text("Personas").tag(KnowledgeViewMode.agent)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var filterField: some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11))
                .foregroundStyle(p.tertiaryText)
            TextField("Filter pages\u{2026}", text: $controller.treeFilter)
                .textFieldStyle(.plain)
                .font(.system(size: theme.pointSize(.small)))
            if !controller.treeFilter.isEmpty {
                Button {
                    controller.treeFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func bulkActionBar(allRows: [KnowledgePageRow]) -> some View {
        let p = theme.palette
        let ids = Array(controller.selection.selected).sorted()
        let count = ids.count
        return HStack(spacing: 6) {
            Text("\(count) selected")
                .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                .foregroundStyle(p.text)
            Spacer(minLength: 2)
            Button("Move\u{2026}") {
                controller.sheet = .bulkMove(rowIds: ids)
            }
            .buttonStyle(.plain)
            .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium))
            .foregroundStyle(p.accent)
            .disabled(count == 0)

            Menu("Audience") {
                Button("Private") {
                    controller.bulkSetAudience(rowIds: ids, to: .private, in: context)
                }
                Button("Shared") {
                    controller.bulkSetAudience(rowIds: ids, to: .shared, in: context)
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium))
            .disabled(count == 0)

            Button("Delete\u{2026}") {
                controller.sheet = .bulkDelete(rowIds: ids)
            }
            .buttonStyle(.plain)
            .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium))
            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            .disabled(count == 0)

            Button {
                controller.selection.clear()
                controller.selectMode = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Clear selection")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.swiftUIColor("accent-soft", fallback: p.selected))
    }

    // MARK: - Static Top Rows & Pinned

    private var staticNavRows: some View {
        let isHome: Bool = {
            if case .home = controller.activeDestination { return true }
            return false
        }()
        let isSearch: Bool = {
            if case .search = controller.activeDestination { return true }
            return false
        }()
        return Group {
            staticRow(title: "Home", symbol: "house", selected: isHome) {
                controller.openHome(in: context)
            }
            staticRow(title: "Search", symbol: "magnifyingglass", selected: isSearch) {
                controller.openSearch(in: context)
            }
        }
    }

    private func staticRow(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? p.accent : p.secondaryText)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: theme.pointSize(.small), weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? p.text : p.secondaryText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(selected ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String?, trailingDropHint: Bool = false) -> some View {
        let p = theme.palette
        return HStack(spacing: 4) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
            }
            Spacer()
            if trailingDropHint && rootDropTargeted {
                Text("Drop for top level")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.accent)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(rootDropTargeted && trailingDropHint ? theme.swiftUIColor("accent-soft", fallback: p.selected) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private func pinnedPageRow(_ page: KnowledgePageRow, allRows: [KnowledgePageRow], tree: KnowledgeTreeFolder) -> some View {
        let p = theme.palette
        let active = controller.activeDestination.activePageId == page.id
        return Button {
            let newTab = context.currentEventModifiers.contains(.command)
            controller.openPage(page, in: context, newTab: newTab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(p.accent)
                    .frame(width: 14)
                Text(KnowledgeShellLogic.displayTitle(for: page))
                    .font(.system(size: theme.pointSize(.small), weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? p.text : p.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if page.pending > 0 {
                    Circle()
                        .fill(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(active ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(KnowledgeDragItem.page(page).encodeDragPayload())
        .contextMenu {
            pageContextMenu(page: page, rowId: "p:\(page.id)", selectableIds: [], allRows: allRows, tree: tree)
        }
    }

    // MARK: - Tree Rows

    @ViewBuilder
    private func explorerRow(
        _ row: KnowledgeExplorerRow,
        allRows: [KnowledgePageRow],
        selectableIds: [String],
        expanded: Set<String>,
        tree: KnowledgeTreeFolder
    ) -> some View {
        switch row.kind {
        case .folder(let folder):
            folderRow(
                folder,
                rowId: row.id,
                depth: row.depth,
                isExpanded: expanded.contains(folder.path),
                allRows: allRows,
                selectableIds: selectableIds,
                tree: tree
            )
        case .page(let page):
            pageRow(
                page,
                rowId: row.id,
                depth: row.depth,
                allRows: allRows,
                selectableIds: selectableIds,
                tree: tree
            )
        case .attachment(let attachment):
            attachmentRow(attachment, depth: row.depth)
        case .showMore(let folderPath, let hiddenCount):
            showMoreRow(folderPath: folderPath, hiddenCount: hiddenCount, depth: row.depth)
        }
    }

    private func folderRow(
        _ folder: KnowledgeTreeFolder,
        rowId: String,
        depth: Int,
        isExpanded: Bool,
        allRows: [KnowledgePageRow],
        selectableIds: [String],
        tree: KnowledgeTreeFolder
    ) -> some View {
        let p = theme.palette
        let isInbox = depth == 0 && folder.name == "Inbox"
        let isAttachments = depth == 0 && folder.name == KnowledgeShellLogic.attachmentsFolderName
        let isSelected = controller.selection.selected.contains(rowId)
        let isDropTarget = targetedFolderDropPath == folder.path
        let isRenaming = controller.inlineRenameRowId == rowId

        let rowContent = HStack(spacing: 4) {
            if !isAttachments && (controller.selectMode || controller.selection.selected.count > 1) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? p.accent : p.tertiaryText)
            }

            Button {
                controller.toggleFolder(folder.path)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                    .frame(width: 12, height: 16)
            }
            .buttonStyle(.plain)

            Image(systemName: isInbox ? "tray" : (isAttachments ? "paperclip" : "folder"))
                .font(.system(size: 12))
                .foregroundStyle((isInbox || isAttachments) ? p.accent : p.secondaryText)
                .frame(width: 14)

            if isRenaming {
                TextField("Folder name", text: $controller.inlineRenameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .focused($inlineRenameFocused)
                    .onAppear { inlineRenameFocused = true }
                    .onSubmit { controller.commitInlineRename(in: context) }
                    .onExitCommand { controller.cancelInlineRename() }
            } else {
                Text(folder.name)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isAttachments && isDropTarget {
                Text("Drop to upload")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.accent)
            } else if !isRenaming && (isInbox || isAttachments || folder.name == "Proposed") {
                Text("\(folder.count)")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Capsule())
            }
        }
        .padding(.leading, CGFloat(6 + depth * 12))
        .padding(.trailing, 6)
        .frame(height: 22)
        .background(
            isDropTarget
                ? theme.swiftUIColor("accent-soft", fallback: p.selected)
                : (isSelected ? p.selected : .clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isDropTarget ? p.accent : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isAttachments {
                controller.toggleFolder(folder.path)
            } else {
                handleRowTap(rowId: rowId, selectableIds: selectableIds) {
                    controller.toggleFolder(folder.path)
                }
            }
        }

        return Group {
            if isAttachments {
                rowContent
                    .dropDestination(for: URL.self) { urls, _ in
                        let fileURLs = urls.filter(\.isFileURL)
                        guard !fileURLs.isEmpty else { return false }
                        controller.uploadDroppedFilesToAttachments(fileURLs, in: context)
                        return true
                    } isTargeted: { targeted in
                        targetedFolderDropPath = targeted ? folder.path : (targetedFolderDropPath == folder.path ? nil : targetedFolderDropPath)
                    }
                    .contextMenu {
                        Button("Upload Files\u{2026}") {
                            controller.pickFilesToUploadToAttachments(in: context)
                        }
                        Button(isExpanded ? "Collapse" : "Expand") {
                            controller.toggleFolder(folder.path)
                        }
                    }
            } else {
                rowContent
                    .draggable(KnowledgeDragItem.folder(folder).encodeDragPayload())
                    .dropDestination(for: String.self) { items, _ in
                        guard let payload = items.first else { return false }
                        return controller.handleDrop(payload, ontoFolder: folder.path, in: context)
                    } isTargeted: { targeted in
                        targetedFolderDropPath = targeted ? folder.path : (targetedFolderDropPath == folder.path ? nil : targetedFolderDropPath)
                    }
                    .contextMenu {
                        folderContextMenu(folder: folder, rowId: rowId, selectableIds: selectableIds, allRows: allRows)
                    }
            }
        }
    }

    private func pageRow(
        _ page: KnowledgePageRow,
        rowId: String,
        depth: Int,
        allRows: [KnowledgePageRow],
        selectableIds: [String],
        tree: KnowledgeTreeFolder
    ) -> some View {
        let p = theme.palette
        let active = controller.activeDestination.activePageId == page.id
        let isSelected = controller.selection.selected.contains(rowId)
        let isRenaming = controller.inlineRenameRowId == rowId
        let parentFolder = KnowledgeShellLogic.parentOf(page.path)

        return HStack(spacing: 5) {
            if controller.selectMode || controller.selection.selected.count > 1 {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? p.accent : p.tertiaryText)
            }

            Image(systemName: KnowledgeShellLogic.pageSymbol(for: page))
                .font(.system(size: 11.5))
                .foregroundStyle(active ? p.accent : p.secondaryText)
                .frame(width: 14)

            if isRenaming {
                TextField("Page title", text: $controller.inlineRenameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .focused($inlineRenameFocused)
                    .onAppear { inlineRenameFocused = true }
                    .onSubmit { controller.commitInlineRename(in: context) }
                    .onExitCommand { controller.cancelInlineRename() }
            } else {
                Text(KnowledgeShellLogic.displayTitle(for: page))
                    .font(.system(size: theme.pointSize(.small), weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? p.text : p.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                if page.pending > 0 {
                    Circle()
                        .fill(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                        .frame(width: 6, height: 6)
                        .help("\(page.pending) pending suggestion(s)")
                }
                if page.audience == .shared {
                    Image(systemName: "person.2")
                        .font(.system(size: 9.5))
                        .foregroundStyle(p.tertiaryText)
                }
            }
        }
        .padding(.leading, CGFloat(18 + depth * 12))
        .padding(.trailing, 6)
        .frame(height: 22)
        .background((active || isSelected) ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            let modifiers = context.currentEventModifiers
            if !controller.selectMode && controller.selection.selected.count <= 1 && modifiers.contains(.command) {
                controller.openPage(page, in: context, newTab: true)
                return
            }
            handleRowTap(rowId: rowId, selectableIds: selectableIds) {
                controller.openPage(page, in: context, newTab: false)
            }
        }
        .draggable(KnowledgeDragItem.page(page).encodeDragPayload())
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            return controller.handleDrop(payload, ontoFolder: parentFolder, in: context)
        }
        .contextMenu {
            pageContextMenu(page: page, rowId: rowId, selectableIds: selectableIds, allRows: allRows, tree: tree)
        }
    }

    private func attachmentRow(_ attachment: KnowledgeAttachment, depth: Int) -> some View {
        let p = theme.palette
        let rowId = "a:\(attachment.id)"
        let active = controller.activeDestination.activeAttachmentId == attachment.id
        let isRenaming = controller.inlineRenameRowId == rowId
        let symbol = KnowledgeAttachmentActions.sfSymbol(for: attachment.contentType, filename: attachment.filename)

        return HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(active ? p.accent : p.secondaryText)
                .frame(width: 14)

            if isRenaming {
                TextField("Filename", text: $controller.inlineRenameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .focused($inlineRenameFocused)
                    .onAppear { inlineRenameFocused = true }
                    .onSubmit { controller.commitInlineRename(in: context) }
                    .onExitCommand { controller.cancelInlineRename() }
            } else {
                Text(attachment.filename)
                    .font(.system(size: theme.pointSize(.small), weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? p.text : p.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !isRenaming {
                if attachment.isOrphaned {
                    Text("unused")
                        .font(.system(size: max(8.5, theme.pointSize(.micro) - 1), weight: .medium))
                        .foregroundStyle(p.tertiaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: Capsule())
                        .help("Orphaned \u{2014} not used in any doc")
                } else {
                    Text("\(attachment.usageCount)")
                        .font(.system(size: theme.pointSize(.micro), weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(p.tertiaryText)
                        .help(attachment.usageSummary)
                }
            }
        }
        .padding(.leading, CGFloat(18 + depth * 12))
        .padding(.trailing, 6)
        .frame(height: 22)
        .background(active ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            let newTab = context.currentEventModifiers.contains(.command)
            controller.openAttachment(attachment, in: context, newTab: newTab)
        }
        .draggable(KnowledgeDragItem.attachment(attachment).encodeDragPayload())
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            controller.uploadDroppedFilesToAttachments(fileURLs, in: context)
            return true
        }
        .contextMenu {
            Text(attachment.usageSummary)
            Divider()
            Button("Quick Look (Space)") {
                controller.previewAttachmentInQuickLook(attachment, in: context)
            }
            Button("Open in Another App") {
                KnowledgeAttachmentActions.openInExternalApp(
                    url: attachment.url,
                    filename: attachment.filename,
                    contentType: attachment.contentType,
                    context: context
                )
            }
            Divider()
            Button("Copy Embed Link") {
                context.copyToClipboard("![[\(attachment.ref)]]")
                context.showToast(ToastItemModel(id: "knowledge.att.copy.\(attachment.id)", title: "Copied embed link", tone: .success))
            }
            Button("Copy File") {
                KnowledgeAttachmentActions.copyFile(
                    url: attachment.url,
                    filename: attachment.filename,
                    contentType: attachment.contentType,
                    context: context
                )
            }
            Button("Download\u{2026}") {
                KnowledgeAttachmentActions.saveCopy(
                    url: attachment.url,
                    filename: attachment.filename,
                    contentType: attachment.contentType,
                    context: context
                )
            }
            if attachment.isOwner {
                Divider()
                Button("Rename") {
                    controller.startInlineRename(rowId: rowId, initial: attachment.filename)
                }
                Button("Rename in Sheet\u{2026}") {
                    controller.sheet = .renameAttachment(attachment)
                }
                Button("Delete\u{2026}", role: .destructive) {
                    controller.sheet = .delete(target: .attachment(attachment))
                }
            }
        }
    }

    private func showMoreRow(folderPath: String, hiddenCount: Int, depth: Int) -> some View {
        let p = theme.palette
        return Button {
            controller.showAllPages(in: folderPath)
        } label: {
            Text("+ \(hiddenCount) more")
                .font(.system(size: theme.pointSize(.micro) + 1))
                .foregroundStyle(p.accent)
                .padding(.leading, CGFloat(18 + depth * 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleRowTap(rowId: String, selectableIds: [String], defaultAction: () -> Void) {
        let modifiers = context.currentEventModifiers
        if modifiers.contains(.shift) {
            controller.selection.click(rowId, in: selectableIds, modifier: .extend)
            return
        }
        if modifiers.contains(.option) || controller.selectMode || controller.selection.selected.count > 1 {
            controller.selection.click(rowId, in: selectableIds, modifier: .toggle)
            return
        }
        controller.selection.click(rowId, in: selectableIds, modifier: .none)
        defaultAction()
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func pageContextMenu(
        page: KnowledgePageRow,
        rowId: String,
        selectableIds: [String],
        allRows: [KnowledgePageRow],
        tree: KnowledgeTreeFolder
    ) -> some View {
        let targets = controller.selection.targets(for: rowId, in: selectableIds)
        if targets.count > 1 {
            bulkContextMenu(rowIds: targets)
        } else {
            Button("Open in New Tab") {
                controller.openPage(page, in: context, newTab: true)
            }
            Button(controller.isPinned(page.id) ? "Unpin" : "Pin to Top") {
                controller.togglePin(page.id)
            }
            Divider()
            Button("Rename") {
                controller.startInlineRename(rowId: rowId, initial: page.title)
            }
            Button("Rename in Sheet\u{2026}") {
                controller.sheet = .renamePage(page)
            }
            Button("Move to\u{2026}") {
                controller.sheet = .move(target: .page(page))
            }
            Button("Duplicate") {
                controller.duplicatePage(page, in: context)
            }
            if page.audience == .agent {
                Button("Move to Personal") {
                    controller.setPageAudience(page, audience: .private, in: context)
                }
            } else {
                Menu("Audience") {
                    Button {
                        controller.setPageAudience(page, audience: .private, in: context)
                    } label: {
                        if page.audience == .private { Label("Private", systemImage: "checkmark") } else { Text("Private") }
                    }
                    Button {
                        controller.setPageAudience(page, audience: .shared, in: context)
                    } label: {
                        if page.audience == .shared { Label("Shared", systemImage: "checkmark") } else { Text("Shared") }
                    }
                }
            }
            Divider()
            Button("Copy [[wikilink]]") {
                controller.copyPageWikilink(page, in: context)
            }
            Button("Copy Link") {
                controller.copyPageLink(page, in: context)
            }
            Button("New Page Beside It") {
                controller.createDocument(inFolder: KnowledgeShellLogic.parentOf(page.path), in: context)
            }
            Divider()
            Button("Select for Multi-Action") {
                controller.selectMode = true
                controller.selection.click(rowId, in: selectableIds, modifier: .toggle)
            }
            Divider()
            Button("Delete\u{2026}", role: .destructive) {
                controller.sheet = .delete(target: .page(page))
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(
        folder: KnowledgeTreeFolder,
        rowId: String,
        selectableIds: [String],
        allRows: [KnowledgePageRow]
    ) -> some View {
        let targets = controller.selection.targets(for: rowId, in: selectableIds)
        if targets.count > 1 {
            bulkContextMenu(rowIds: targets)
        } else {
            Button("New Page") {
                controller.createDocument(inFolder: folder.path, in: context)
            }
            Button("New Folder\u{2026}") {
                controller.sheet = .newFolder(parent: folder.path)
            }
            Divider()
            Button("Rename") {
                controller.startInlineRename(rowId: rowId, initial: folder.name)
            }
            Button("Rename in Sheet\u{2026}") {
                controller.sheet = .renameFolder(path: folder.path, name: folder.name)
            }
            Button("Move to\u{2026}") {
                controller.sheet = .move(target: .folder(path: folder.path, name: folder.name))
            }
            if controller.viewMode != .agent {
                Menu("Set Pages Audience") {
                    Button("Private") {
                        controller.bulkSetAudience(rowIds: [rowId], to: .private, in: context)
                    }
                    Button("Shared") {
                        controller.bulkSetAudience(rowIds: [rowId], to: .shared, in: context)
                    }
                }
            }
            Divider()
            Button("Select for Multi-Action") {
                controller.selectMode = true
                controller.selection.click(rowId, in: selectableIds, modifier: .toggle)
            }
            Divider()
            Button("Delete Folder\u{2026}", role: .destructive) {
                controller.sheet = .delete(target: .folder(path: folder.path, name: folder.name, pageCount: folder.count))
            }
        }
    }

    @ViewBuilder
    private func bulkContextMenu(rowIds: [String]) -> some View {
        Text("\(rowIds.count) items selected")
        Button("Move \(rowIds.count) items\u{2026}") {
            controller.sheet = .bulkMove(rowIds: rowIds)
        }
        Menu("Set Audience") {
            Button("Private") {
                controller.bulkSetAudience(rowIds: rowIds, to: .private, in: context)
            }
            Button("Shared") {
                controller.bulkSetAudience(rowIds: rowIds, to: .shared, in: context)
            }
        }
        Divider()
        Button("Delete \(rowIds.count) items\u{2026}", role: .destructive) {
            controller.sheet = .bulkDelete(rowIds: rowIds)
        }
        Button("Clear Selection") {
            controller.selection.clear()
            controller.selectMode = false
        }
    }

    // MARK: - Empty State & Footer

    private func emptyTreeMessage(isFiltering: Bool) -> some View {
        let p = theme.palette
        let text: String = {
            if isFiltering { return "No pages match \u{201C}\(controller.treeFilter)\u{201D}." }
            if controller.viewMode == .agent {
                return "No agent knowledge yet. Runs write memory and proposed patterns here."
            }
            return "No pages yet. Create one, capture a thought, or import an Obsidian vault."
        }()
        return Text(text)
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(p.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerQuickActions: some View {
        let todayLabel = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return VStack(alignment: .leading, spacing: 1) {
            footerButton(title: "Today", symbol: "clock", trailing: todayLabel) {
                controller.openToday(in: context)
            }
            footerButton(title: "Quick capture", symbol: "tray", trailing: "\u{2325}\u{2318}N") {
                controller.sheet = .capture
            }
            footerButton(title: "Import Obsidian vault", symbol: "square.and.arrow.up", trailing: nil) {
                controller.sheet = .vaultImport
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func footerButton(title: String, symbol: String, trailing: String?, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.secondaryText)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct KnowledgeDesignStarterOption: Sendable {
    let starter: API.CreateDesignBody.Starter
    let label: String

    static let all: [KnowledgeDesignStarterOption] = [
        KnowledgeDesignStarterOption(starter: .blank, label: "Blank"),
        KnowledgeDesignStarterOption(starter: .mobileFlow, label: "Mobile flow"),
        KnowledgeDesignStarterOption(starter: .webFlow, label: "Web flow"),
        KnowledgeDesignStarterOption(starter: .diagram, label: "Diagram"),
        KnowledgeDesignStarterOption(starter: .wireframe, label: "Wireframe"),
    ]
}
