import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// /library: the person's keepsakes, or with ?source=projects what agents wrote in their spaces
/// (web app/(app)/library).
struct LibraryScreen: View {
    @Environment(NativeScreenContext.self) private var context

    var body: some View {
        if context.match.query["source"] == LibraryLogic.Source.projects.rawValue {
            ProjectDocsScreen()
        } else {
            KeepsakesScreen()
        }
    }
}

/// The page heading the web's PageHeader draws: display title and what the screen is for.
struct LibraryHeading: View {
    @Environment(\.vesperTheme) private var theme
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library").vesperText(.display, theme)
            Text(description)
                .font(.system(size: theme.pointSize(.reading)))
                .foregroundStyle(theme.palette.secondaryText)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// The empty state the web's <EmptyState> draws: an icon, a title and a line under it.
struct LibraryEmptyState: View {
    @Environment(\.vesperTheme) private var theme
    var icon = "books.vertical"
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(theme.palette.tertiaryText)
            Text(title).vesperText(.heading, theme)
            Text(message)
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// The Keepsakes tab's state: which kind it lists, the pages loaded, the selection and the open item.
@MainActor
@Observable
final class KeepsakesModel {
    var tab = "images"
    /// The offsets of the pages loaded so far ("Show more" adds one).
    var offsets = [0]
    var selection = LibrarySelection()
    /// Explicit multi-select mode toggled from the toolbar or by clicking a tile's checkbox.
    var selecting = false
    /// True while a bulk delete request is in flight.
    var removing = false
    /// The item whose dialog shows; `autoPlay` when a click opened it (not a chat's "Open in Library").
    var open: OpenLibraryItem?
    /// `?item=` from a chat's "Open in Library": opened once its page has loaded.
    var pendingOpen: String?
    var uploading = false
    var uploadError: String?
    var columns = 1
}

struct OpenLibraryItem: Identifiable, Equatable {
    let id: String
    var autoPlay = false
}

/// "Yours": the person's keepsakes from chats, one kind per tab, as a grid (web Keepsakes).
struct KeepsakesScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var model = KeepsakesModel()
    @FocusState private var gridFocused: Bool

    private var kind: API.LibraryItemKind? { LibraryLogic.tab(model.tab).kind }

    private func pageRequest(_ offset: Int) -> APIRequest<API.LibraryList> {
        API.listLibraryItems(kind: kind, offset: offset == 0 ? nil : offset)
    }

    /// Every loaded page's items, newest first, each once.
    private var items: [API.LibraryItem] {
        var seen = Set<String>()
        return model.offsets.flatMap { context.store.entry(pageRequest($0)).data?.items ?? [] }.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let items = self.items
        let ids = items.map(\.id)
        Group {
            switch model.tab {
            case "links":
                LibraryLinksView(selecting: $model.selecting, uploadError: model.uploadError)
            case "fridge":
                LibraryFridgeView(selecting: $model.selecting, uploadError: model.uploadError)
            default:
                VStack(spacing: 0) {
                    if model.selection.showsBar(selecting: model.selecting) {
                        LibrarySelectionBar(
                            selectedCount: model.selection.selected.count,
                            totalCount: ids.count,
                            allSelected: model.selection.isAllSelected(in: ids),
                            busy: model.removing,
                            onToggleAll: {
                                model.selection.toggleAll(ids)
                                gridFocused = true
                            },
                            onClear: { model.selection.clear() },
                            onQuickLook: model.selection.selected.isEmpty ? nil : {
                                quickLook(model.selection.ordered(ids), items: items)
                            },
                            onRemove: { removeSelected(from: items) },
                            onDone: exitSelection
                        )
                        Divider().overlay(theme.palette.border)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                LibraryHeading(description: "Private keepsakes from your chats: generated media, saved files, exports, diagrams, references, and links.")
                                if let error = model.uploadError {
                                    Text(error).vesperText(.small, theme).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                }
                                grid(items: items, ids: ids)
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 32)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: model.selection.focused) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        }
                        .onChange(of: context.find.current) { _, index in
                            guard let index, index < ids.count else { return }
                            model.selection.click(ids[index], in: ids)
                        }
                    }
                }
            }
        }
        .sheet(item: $model.open) { open in
            if let item = items.first(where: { $0.id == open.id }) {
                LibraryItemSheet(item: item, autoPlay: open.autoPlay, actions: actions)
            }
        }
        .onChange(of: context.match, initial: true) { _, match in applyRoute(match) }
        .onChange(of: ids, initial: true) { _, newIds in
            model.selection.prune(to: newIds)
            if kind != nil { context.find.texts = items.map(Self.searchText) }
            openPending(in: newIds)
        }
        .onChange(of: model.uploading) { _, _ in publishChrome() }
        .onChange(of: model.selecting) { _, selecting in
            if !selecting { model.selection.clear() }
            publishChrome()
        }
        .onChange(of: pageKeys, initial: true) { old, new in
            for key in old where !new.contains(key) { context.store.stopObserving(key) }
            guard kind != nil else { return }
            for offset in model.offsets {
                let request = pageRequest(offset)
                context.store.load(request)
                if old == new || !old.contains(request.key) { context.store.observe(request) }
            }
        }
        .onAppear {
            publishChrome()
            context.onCommand = { command in handle(command) }
        }
        .onDisappear { for key in pageKeys { context.store.stopObserving(key) } }
    }

    /// The pages the grid shows, observed so a rename, upload or removal elsewhere refetches them.
    private var pageKeys: [QueryKey] { kind == nil ? [] : model.offsets.map { pageRequest($0).key } }

    private static func searchText(_ item: API.LibraryItem) -> String {
        [item.title, item.filename, item.personaName ?? "", item.chatTitle ?? ""].joined(separator: " ")
    }

    // MARK: Route and chrome

    /// `?tab=videos&item=<id>` (a chat's "Open in Library") picks the tab and opens the item.
    private func applyRoute(_ match: NativeRouteMatch) {
        if let tab = match.query["tab"] { switchTab(LibraryLogic.tab(tab).key) }
        if let item = match.query["item"], !item.isEmpty {
            model.pendingOpen = item
            openPending(in: items.map(\.id))
        }
    }

    private func openPending(in ids: [String]) {
        guard let pending = model.pendingOpen, ids.contains(pending) else { return }
        model.pendingOpen = nil
        model.open = OpenLibraryItem(id: pending)
    }

    private func switchTab(_ tab: String) {
        guard tab != model.tab else { return }
        model.tab = tab
        model.offsets = [0]
        model.selection.clear()
        model.selecting = false
        publishChrome()
    }

    private func exitSelection() {
        model.selection.clear()
        model.selecting = false
    }

    private func publishChrome() {
        context.chrome = NativeChrome(
            title: "Library",
            toolbarItems: [
                ShellToolbarItem(id: "library.select", label: model.selecting ? "Done" : "Select", icon: "checklist",
                                 kind: .toggle, on: model.selecting, showsLabel: true),
                ShellToolbarItem(id: "library.upload", label: model.uploading ? "Uploading\u{2026}" : "Upload", icon: "upload",
                                 kind: .button, disabled: model.uploading, showsLabel: true),
            ],
            navigator: LibraryLogic.keepsakesNavigator(tab: model.tab))
    }

    private func handle(_ command: NativeCommand) {
        switch command {
        case .toolbarAction(itemId: "library.select", _):
            model.selecting.toggle()
            if model.selecting { gridFocused = true }
        case .toolbarAction(itemId: "library.upload", _): upload()
        case .navActivate(_, let itemId, let newTab):
            if newTab { context.openInNewTab("/library?tab=\(itemId)") } else { switchTab(itemId) }
        case .navPicker(_, LibraryLogic.sourcePickerId, let value):
            context.navigate(LibraryLogic.sourceHref(LibraryLogic.Source(rawValue: value) ?? .yours))
        default: break
        }
    }

    // MARK: Grid

    private static let gridSpacing: CGFloat = 16
    private static let minTileWidth: CGFloat = 180

    @ViewBuilder
    private func grid(items: [API.LibraryItem], ids: [String]) -> some View {
        let first = context.store.entry(pageRequest(0))
        let last = context.store.entry(pageRequest(model.offsets.last ?? 0))
        let columns = [GridItem(.adaptive(minimum: Self.minTileWidth), spacing: Self.gridSpacing, alignment: .top)]
        if first.data == nil, let error = first.error {
            QueryErrorView(message: "Couldn\u{2019}t load your Library: \(error.userMessage)") {
                Task { await context.store.refetch(pageRequest(0)) }
            }
        } else if first.data == nil {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(0..<5, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBar(height: 180)
                        SkeletonBar(height: 12).frame(width: 110)
                    }
                }
            }
            .accessibilityLabel("Loading your Library")
        } else if items.isEmpty, let kind {
            LibraryEmptyState(title: "Nothing here yet", message: LibraryLogic.emptyText(kind))
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Self.gridSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    tile(item, index: index, items: items, ids: ids).id(item.id)
                }
            }
            .background(GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                    model.columns = max(1, Int((width + Self.gridSpacing) / (Self.minTileWidth + Self.gridSpacing)))
                }
            })
            .focusable()
            .focused($gridFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handleKey(press, items: items, ids: ids) }
            if last.data?.hasMore == true {
                HStack {
                    Spacer()
                    Button {
                        let next = items.count
                        if !model.offsets.contains(next) { model.offsets.append(next) }
                    } label: {
                        HStack(spacing: 6) {
                            if last.isFetching || context.store.entry(pageRequest(items.count)).isFetching { ProgressView().controlSize(.small) }
                            Text("Show more")
                        }
                    }
                    .buttonStyle(.vesper())
                    Spacer()
                }
            }
        }
    }

    private func tile(_ item: API.LibraryItem, index: Int, items: [API.LibraryItem], ids: [String]) -> some View {
        let selected = model.selection.selected.contains(item.id)
        let focused = model.selection.focused == item.id && gridFocused
        let findHit = context.find.matches(Self.searchText(item))
        return SelectableLibraryCard(
            selected: selected,
            focused: focused,
            selecting: model.selecting,
            findHit: findHit,
            onTap: {
                let flags = NSEvent.modifierFlags
                let modifier = LibrarySelection.tapModifier(
                    selecting: model.selecting,
                    command: flags.contains(.command),
                    shift: flags.contains(.shift)
                )
                model.selection.click(item.id, in: ids, modifier: modifier)
                gridFocused = true
            },
            onDoubleTap: {
                if model.selecting {
                    model.selection.click(item.id, in: ids, modifier: .toggle)
                    gridFocused = true
                } else {
                    open(item, autoPlay: true)
                }
            },
            onToggleBadge: {
                let flags = NSEvent.modifierFlags
                model.selecting = true
                model.selection.click(item.id, in: ids, modifier: flags.contains(.shift) ? .extend : .toggle)
                gridFocused = true
            }
        ) {
            LibraryTile(item: item, actions: actions, open: { open(item, autoPlay: true) })
        }
        .onDrag {
            LibraryFiles.dragProvider(path: LibraryLogic.contentPath(item.id), filename: item.filename,
                                      contentType: item.contentType, client: context.store.client)
        }
        .contextMenu { contextMenu(item, items: items, ids: ids) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Quick Look") { quickLook([item.id], items: items) }
    }

    @ViewBuilder
    private func contextMenu(_ item: API.LibraryItem, items: [API.LibraryItem], ids: [String]) -> some View {
        let targets = model.selection.targets(for: item.id, in: ids)
        if targets.count > 1 {
            Button("Quick Look \(targets.count) Items") { quickLook(targets, items: items) }
            Divider()
            Button("Remove \(targets.count) Items from Library", role: .destructive) {
                removeItems(items.filter { targets.contains($0.id) })
            }
        } else {
            Button("Quick Look") { quickLook([item.id], items: items) }
            if item.kind == .document {
                Button("Open") { actions.openDocument(item) }
            } else {
                Button("Open Details") { open(item, autoPlay: false) }
            }
            if let chat = item.chatId { Button("Open Chat") { context.navigate("/chat/\(chat)") } }
            Divider()
            if item.kind != .document { Button("Rename\u{2026}") { actions.rename(item) } }
            Button("Download\u{2026}") { actions.download(item) }
            if LibraryLogic.isKnowledgeEmbeddable(item) {
                Button("Copy Embed") { actions.copyEmbed(item) }
            }
            Button("Copy Link") { actions.copyLink(item) }
            Divider()
            Button("Remove from Library", role: .destructive) { removeItems([item]) }
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress, items: [API.LibraryItem], ids: [String]) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        let extend = press.modifiers.contains(.shift)
        switch press.key {
        case .space where press.modifiers.isEmpty:
            let chosen = model.selection.ordered(ids)
            guard !chosen.isEmpty else { return .ignored }
            quickLook(chosen, items: items)
            return .handled
        case .return:
            guard !model.selecting, let id = model.selection.focused, let item = items.first(where: { $0.id == id }) else { return .ignored }
            if item.kind == .document { actions.openDocument(item) } else { open(item, autoPlay: true) }
            return .handled
        case .leftArrow: model.selection.move(by: -1, in: ids, extend: extend); return .handled
        case .rightArrow: model.selection.move(by: 1, in: ids, extend: extend); return .handled
        case .upArrow: model.selection.move(by: -model.columns, in: ids, extend: extend); return .handled
        case .downArrow: model.selection.move(by: model.columns, in: ids, extend: extend); return .handled
        case .escape:
            exitSelection()
            return .handled
        case .delete where command || press.modifiers.isEmpty,
             .deleteForward where command || press.modifiers.isEmpty:
            let chosen = items.filter { model.selection.selected.contains($0.id) }
            guard !chosen.isEmpty, !model.removing else { return .ignored }
            removeItems(chosen)
            return .handled
        default:
            if command, press.characters == "a" {
                model.selection.selectAll(ids)
                if !ids.isEmpty { model.selecting = true }
                return .handled
            }
            return .ignored
        }
    }

    private func removeSelected(from items: [API.LibraryItem]) {
        let chosen = items.filter { model.selection.selected.contains($0.id) }
        guard !chosen.isEmpty, !model.removing else { return }
        removeItems(chosen)
    }

    private func removeItems(_ chosen: [API.LibraryItem]) {
        let removedIds = Set(chosen.map(\.id))
        actions.remove(
            chosen,
            onBusy: { model.removing = $0 },
            onComplete: { ok in
                guard ok else { return }
                if removedIds.isSuperset(of: model.selection.selected) {
                    exitSelection()
                } else {
                    model.selection.prune(to: items.map(\.id).filter { !removedIds.contains($0) })
                }
            }
        )
    }

    // MARK: Actions

    private func open(_ item: API.LibraryItem, autoPlay: Bool) {
        if item.kind == .document { actions.openDocument(item); return }
        model.open = OpenLibraryItem(id: item.id, autoPlay: autoPlay)
    }

    /// Quick Look over the chosen items; one item previews among all of them so the panel's arrows
    /// walk the grid, as the web's did.
    private func quickLook(_ chosen: [String], items: [API.LibraryItem]) {
        let pool = chosen.count > 1 ? items.filter { chosen.contains($0.id) } : items
        let focus = chosen.count > 1 ? (model.selection.focused ?? chosen[0]) : chosen[0]
        let list = pool.map { QuickLookItem(url: LibraryLogic.contentPath($0.id), title: $0.title, filename: $0.filename, contentType: $0.contentType) }
        context.showQuickLook(list, index: pool.firstIndex { $0.id == focus })
    }

    private var actions: LibraryItemActions {
        LibraryItemActions(context: context, pages: model.offsets.map(pageRequest))
    }

    /// Adds a file of the person's own: an image (e.g. a photo to use as their reference), audio, or any other file.
    private func upload() {
        guard !model.uploading else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let picked: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await upload(url) }
        }
        if let window = context.window()?.window { panel.beginSheetModal(for: window, completionHandler: picked) } else { panel.begin(completionHandler: picked) }
    }

    private func upload(_ url: URL) async {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if let problem = LibraryLogic.checkUpload(name: name, type: type, size: size) {
            model.uploadError = problem
            return
        }
        guard let client = context.store.client else { return }
        model.uploadError = nil
        model.uploading = true
        defer { model.uploading = false }
        do {
            let data = try Data(contentsOf: url)
            var form = APIMultipartForm()
            form.addFile("file", filename: name, contentType: type, data: data)
            _ = try await client.send(API.uploadLibraryItem(body: form), timeout: 120)
            context.store.invalidate(QueryInvalidation(resources: ["library"]))
        } catch {
            model.uploadError = (error as? APIError)?.userMessage ?? "Couldn\u{2019}t upload the file."
        }
    }
}

/// What tiles, menus and the item dialog do to an item, through the shared store.
@MainActor
struct LibraryItemActions {
    let context: NativeScreenContext
    /// The loaded list pages, updated optimistically.
    let pages: [APIRequest<API.LibraryList>]

    private static let invalidation = QueryInvalidation(resources: ["library"])

    func rename(_ item: API.LibraryItem) {
        Task {
            let entered = await NativeDialogs.promptSheet(
                title: "Rename \u{201C}\(item.title)\u{201D}", body: nil, label: "Title", value: item.title, placeholder: nil,
                confirmLabel: "Save", cancelLabel: nil, maxLength: 300, window: context.window()?.window)
            guard let title = entered?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != item.title else { return }
            _ = await setTitle(item, title)
        }
    }

    /// Renames in place; returns the error message when it fails.
    func setTitle(_ item: API.LibraryItem, _ title: String) async -> String? {
        do {
            _ = try await context.store.mutate(
                API.renameLibraryItem(itemId: item.id, body: .init(title: title)),
                optimistic: pages.map { page in .update(page) { list in
                    for i in list.items.indices where list.items[i].id == item.id { list.items[i].title = title }
                } },
                invalidating: Self.invalidation)
            return nil
        } catch {
            let message = (error as? APIError)?.userMessage ?? error.localizedDescription
            context.showToast(ToastItemModel(id: "library.rename.\(item.id)", title: "Couldn\u{2019}t rename it", description: message, tone: .error))
            return message
        }
    }

    /// Asks first, as the web did: a persona's item stays in its chat.
    func remove(
        _ items: [API.LibraryItem],
        invalidation: QueryInvalidation = LibraryItemActions.invalidation,
        then: @escaping @MainActor () -> Void = {},
        onBusy: (@MainActor (Bool) -> Void)? = nil,
        onComplete: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard let prompt = LibraryLogic.removeConfirmation(items) else { return }
        Task {
            guard await NativeDialogs.confirmSheet(title: prompt.title, body: prompt.body, confirmLabel: "Remove", cancelLabel: nil, destructive: true,
                                                   window: context.window()?.window) else { return }
            then()
            onBusy?(true)
            let ok = await deleteMany(items, invalidation: invalidation)
            onBusy?(false)
            onComplete?(ok)
        }
    }

    /// Deletes one or many items; batches of 2+ use POST /library/bulk-delete so all rows drop in one request.
    @discardableResult
    func deleteMany(_ items: [API.LibraryItem], invalidation: QueryInvalidation = LibraryItemActions.invalidation) async -> Bool {
        guard !items.isEmpty else { return true }
        if items.count == 1, let only = items.first {
            return await delete(only, invalidation: invalidation)
        }
        let batches = LibraryLogic.bulkDeleteBatches(items.map(\.id))
        do {
            for (index, batch) in batches.enumerated() {
                let batchSet = Set(batch)
                let inv = index == batches.count - 1 ? invalidation : QueryInvalidation()
                _ = try await context.store.mutate(
                    API.bulkDeleteLibraryItems(body: .init(ids: batch)),
                    optimistic: pages.map { page in .update(page) { $0.items.removeAll { batchSet.contains($0.id) } } },
                    invalidating: inv)
            }
            return true
        } catch {
            context.store.invalidate(invalidation)
            context.showToast(ToastItemModel(id: "library.remove.bulk", title: "Couldn\u{2019}t remove \(items.count) items",
                                             description: (error as? APIError)?.userMessage, tone: .error))
            return false
        }
    }

    /// Deletes without asking (links and moments ask through an Undo toast instead). Already gone counts as removed.
    @discardableResult
    func delete(_ item: API.LibraryItem, invalidation: QueryInvalidation = LibraryItemActions.invalidation) async -> Bool {
        do {
            _ = try await context.store.mutate(
                API.deleteLibraryItem(itemId: item.id),
                optimistic: pages.map { page in .update(page) { $0.items.removeAll { $0.id == item.id } } },
                invalidating: invalidation)
            return true
        } catch APIError.http(status: 404, _) {
            context.store.invalidate(invalidation)
            return true
        } catch {
            context.showToast(ToastItemModel(id: "library.remove.\(item.id)", title: "Couldn\u{2019}t remove \(item.title)",
                                             description: (error as? APIError)?.userMessage, tone: .error))
            return false
        }
    }

    func download(_ item: API.LibraryItem) {
        LibraryFiles.saveCopy(path: LibraryLogic.contentPath(item.id, download: true), filename: item.filename,
                              contentType: item.contentType, client: context.store.client, context: context)
    }

    /// The item's address, as the web's Copy link gave it.
    func copyLink(_ item: API.LibraryItem) {
        guard let base = context.store.client?.baseURL,
              let url = URL(string: LibraryLogic.contentPath(item.id), relativeTo: base)?.absoluteURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        context.showToast(ToastItemModel(id: "library.link.\(item.id)", title: "Link copied", tone: .success))
    }

    /// Knowledge markdown embed (`![[library:<id>/<title>]]`) for pasting straight into a page.
    func copyEmbed(_ item: API.LibraryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LibraryLogic.embedMarkdown(for: item), forType: .string)
        context.showToast(ToastItemModel(id: "library.embed.\(item.id)", title: "Embed copied", tone: .success))
    }

    /// A workflow's document opens in its default app (the web opened it in a new tab).
    func openDocument(_ item: API.LibraryItem) {
        guard let client = context.store.client else { return }
        Task {
            do {
                let url = try await LibraryFiles.localFile(path: LibraryLogic.contentPath(item.id), filename: item.filename,
                                                           contentType: item.contentType, client: client)
                NSWorkspace.shared.open(url)
            } catch {
                context.showToast(ToastItemModel(id: "library.open.\(item.id)", title: "Couldn\u{2019}t open \(item.title)",
                                                 description: (error as? APIError)?.userMessage, tone: .error))
            }
        }
    }

    func setReference(_ item: API.LibraryItem, _ choice: LibraryLogic.ReferenceChoice) async -> String? {
        await referenceCall(API.setLibraryReference(itemId: item.id, body: .init(personaId: choice.personaId, role: choice.role)))
    }

    func clearReference(_ item: API.LibraryItem) async -> String? {
        await referenceCall(API.clearLibraryReference(itemId: item.id))
    }

    private func referenceCall(_ request: APIRequest<APIEmpty>) async -> String? {
        do {
            _ = try await context.store.mutate(request, invalidating: Self.invalidation)
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

/// Pinned action bar shown while selecting Library items across grid tabs, Links, and Fridge.
struct LibrarySelectionBar: View {
    @Environment(\.vesperTheme) private var theme
    let selectedCount: Int
    let totalCount: Int
    let allSelected: Bool
    let busy: Bool
    var removeLabel = "Remove"
    var busyLabel = "Removing\u{2026}"
    let onToggleAll: () -> Void
    let onClear: () -> Void
    var onQuickLook: (() -> Void)? = nil
    let onRemove: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(selectedCount == 0 ? "Select items" : "\(selectedCount) selected")
                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                .foregroundStyle(selectedCount == 0 ? theme.palette.secondaryText : theme.palette.accent)

            if totalCount > 0 {
                Button(allSelected ? "Deselect all" : "Select all (\(totalCount))", action: onToggleAll)
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.secondaryText)
                    .disabled(busy)
            }

            if selectedCount > 0 && !allSelected {
                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.secondaryText)
                    .disabled(busy)
            }

            Spacer(minLength: 8)

            if let onQuickLook, selectedCount > 0 {
                Button(action: onQuickLook) {
                    Label("Quick Look", systemImage: "eye")
                }
                .buttonStyle(.vesper())
                .disabled(busy)
            }

            Button(action: onRemove) {
                HStack(spacing: 5) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(busy ? busyLabel : selectedCount > 0 ? "\(removeLabel) (\(selectedCount))" : removeLabel)
                }
            }
            .buttonStyle(.vesper(.danger))
            .disabled(selectedCount == 0 || busy)

            Button("Done", action: onDone)
                .buttonStyle(.vesper())
                .disabled(busy)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(theme.swiftUIColor("accent-soft", fallback: theme.palette.selected))
    }
}

/// Circular checkmark toggle drawn on Library tiles and cards when hovered, selected, or in Select mode.
struct LibrarySelectionBadge: View {
    @Environment(\.vesperTheme) private var theme
    let selected: Bool
    let visible: Bool
    var overlayStyle = true
    let toggle: () -> Void

    var body: some View {
        if visible {
            Button(action: toggle) {
                ZStack {
                    if overlayStyle {
                        Circle()
                            .fill(selected ? theme.palette.accent : Color.black.opacity(0.45))
                            .frame(width: 22, height: 22)
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    } else {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(selected ? theme.palette.accent : theme.palette.tertiaryText)
                    }
                }
                .shadow(color: overlayStyle ? .black.opacity(0.25) : .clear, radius: overlayStyle ? 2 : 0, y: overlayStyle ? 1 : 0)
                .frame(width: overlayStyle ? 28 : 22, height: overlayStyle ? 28 : 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Deselect item" : "Select item")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Wraps a Library tile or card with hover/select checkbox badge, selection outline, and hit-testing
/// isolation while Select mode is active.
struct SelectableLibraryCard<Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    let selected: Bool
    let focused: Bool
    let selecting: Bool
    var findHit = false
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 6
    var badgePadding: CGFloat = 10
    var showOverlayBadge = true
    let onTap: () -> Void
    var onDoubleTap: (() -> Void)? = nil
    let onToggleBadge: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        let base = content()
            .allowsHitTesting(!selecting)
            .padding(padding)
            .background(selected ? theme.palette.selected : findHit ? theme.palette.hover : .clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(theme.palette.accent, lineWidth: focused ? 2 : selected ? 1.5 : 0))
            .contentShape(Rectangle())

        Group {
            if let onDoubleTap {
                base
                    .onTapGesture(count: 2) { onDoubleTap() }
                    .onTapGesture { onTap() }
            } else {
                base.onTapGesture { onTap() }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showOverlayBadge {
                LibrarySelectionBadge(selected: selected, visible: selecting || selected || hovered, toggle: onToggleBadge)
                    .padding(badgePadding)
            }
        }
        .onHover { hovered = $0 }
    }
}
