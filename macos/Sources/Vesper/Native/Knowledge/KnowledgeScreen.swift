import SwiftUI
import UniformTypeIdentifiers
import VesperCore

// MARK: - Sheet & Target Models

enum KnowledgeMoveTarget: Equatable {
    case page(KnowledgePageRow)
    case folder(path: String, name: String)

    var path: String {
        switch self {
        case .page(let row): row.path
        case .folder(let path, _): path
        }
    }

    var title: String {
        switch self {
        case .page(let row): KnowledgeShellLogic.displayTitle(for: row)
        case .folder(_, let name): name
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

enum KnowledgeDeleteTarget: Equatable {
    case page(KnowledgePageRow)
    case folder(path: String, name: String, pageCount: Int)
}

enum KnowledgeSheetKind: Identifiable, Equatable {
    case capture
    case vaultImport
    case newFolder(parent: String)
    case renamePage(KnowledgePageRow)
    case renameFolder(path: String, name: String)
    case move(target: KnowledgeMoveTarget)
    case delete(target: KnowledgeDeleteTarget)
    case bulkMove(rowIds: [String])
    case bulkDelete(rowIds: [String])

    var id: String {
        switch self {
        case .capture: return "capture"
        case .vaultImport: return "import"
        case .newFolder(let p): return "newFolder:\(p)"
        case .renamePage(let r): return "renamePage:\(r.id)"
        case .renameFolder(let p, _): return "renameFolder:\(p)"
        case .move(let t): return "move:\(t.isFolder ? "f" : "p"):\(t.path)"
        case .delete(let t):
            switch t {
            case .page(let r): return "deletePage:\(r.id)"
            case .folder(let p, _, _): return "deleteFolder:\(p)"
            }
        case .bulkMove(let ids): return "bulkMove:\(ids.joined(separator: ","))"
        case .bulkDelete(let ids): return "bulkDelete:\(ids.joined(separator: ","))"
        }
    }
}

// MARK: - Controller

@MainActor
@Observable
final class KnowledgeShellController {
    private static let pinnedDefaultsKey = "VesperNativeKnowledgePinnedIds"
    private static let expandedDefaultsKey = "VesperNativeKnowledgeExpandedFolders"
    private static let inspectorOpenDefaultsKey = "VesperNativeKnowledgeInspectorOpen"
    private static let generalChatDefaultsKey = "VesperNativeKnowledgeGeneralChatId"

    var viewMode: KnowledgeViewMode = .yours {
        didSet {
            if viewMode != oldValue {
                allPagesCache = []
                selection.clear()
            }
        }
    }
    var treeFilter = ""
    var expandedFolders: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(expandedFolders).sorted(), forKey: Self.expandedDefaultsKey)
        }
    }
    var showAllFolders: Set<String> = []
    var pinnedPageIds: [String] {
        didSet {
            UserDefaults.standard.set(pinnedPageIds, forKey: Self.pinnedDefaultsKey)
        }
    }
    var selection = KnowledgeSelection()
    var selectMode = false
    var inlineRenameRowId: String?
    var inlineRenameText = ""
    var searchFilter = KnowledgeSearchFilter()
    var inspectorOpen: Bool {
        didSet {
            UserDefaults.standard.set(inspectorOpen, forKey: Self.inspectorOpenDefaultsKey)
        }
    }
    var inspectorTabId: String = KnowledgeInspectorLogic.outlineTabId
    var generalChatId: String? {
        didSet {
            UserDefaults.standard.set(generalChatId, forKey: Self.generalChatDefaultsKey)
        }
    }
    var liveHeadingsPageId: String?
    var liveHeadings: [KnowledgeOutlineHeading] = []
    var headingJumpRequest: KnowledgeHeadingJumpRequest?
    var theme = ThemeTokens(mode: .light)
    var colorScheme: ColorScheme = .light
    var isWorking = false
    var sheet: KnowledgeSheetKind?
    var activeDestination: KnowledgeDestination = .home
    var legacyResolutionError: String?
    var allPagesCache: [KnowledgePageRow] = []

    @ObservationIgnored private var syncedAudiencePageId: String?
    @ObservationIgnored private var headingJumpToken = 0

    static let templatesRequest = KnowledgeAPI.getTemplates()
    static let slideStartersRequest = API.listSlideStarters()
    static let bootstrapRequest = API.getBootstrap()

    init() {
        let savedPins = UserDefaults.standard.stringArray(forKey: Self.pinnedDefaultsKey) ?? []
        self.pinnedPageIds = savedPins
        let savedExpanded = UserDefaults.standard.stringArray(forKey: Self.expandedDefaultsKey)
        self.expandedFolders = Set(savedExpanded ?? ["Daily"])
        self.inspectorOpen = UserDefaults.standard.bool(forKey: Self.inspectorOpenDefaultsKey)
        self.generalChatId = UserDefaults.standard.string(forKey: Self.generalChatDefaultsKey)
    }

    var treeListRequest: APIRequest<KnowledgePageTable> {
        let agent = viewMode == .agent
        return KnowledgeAPI.listPages(
            audience: agent ? .agent : nil,
            includeAgent: agent,
            limit: 200,
            offset: 0
        )
    }

    var recentPagesRequest: APIRequest<KnowledgePageTable> {
        let agent = viewMode == .agent
        return KnowledgeAPI.listPages(
            audience: agent ? .agent : nil,
            includeAgent: agent,
            limit: 8,
            offset: 0
        )
    }

    var inboxPagesRequest: APIRequest<KnowledgePageTable> {
        KnowledgeAPI.listPages(folder: "Inbox", limit: 50)
    }

    var proposalsRequest: APIRequest<KnowledgePageTable> {
        KnowledgeAPI.listPages(folder: "Patterns/Proposed", audience: .agent, includeAgent: true, limit: 50)
    }

    var networkRequest: APIRequest<KnowledgeNetwork> {
        KnowledgeAPI.getNetwork(includeAgent: viewMode == .agent)
    }

    func rows(in context: NativeScreenContext) -> [KnowledgePageRow] {
        let entry = context.store.entry(treeListRequest)
        if entry.data?.hasMore == true && !allPagesCache.isEmpty {
            return allPagesCache
        }
        return entry.data?.rows ?? []
    }

    func loadFullTreeIfNeeded(in context: NativeScreenContext) async {
        let entry = context.store.entry(treeListRequest)
        guard entry.data?.hasMore == true, let client = context.store.client else {
            allPagesCache = []
            return
        }
        do {
            let full = try await KnowledgeAPI.fetchAllPages(includeAgent: viewMode == .agent, using: client)
            allPagesCache = full
        } catch {
            // Keep partial tree from the first 200-row page on transient failure.
        }
    }

    func pinnedPages(from allRows: [KnowledgePageRow]) -> [KnowledgePageRow] {
        let byId = Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) })
        return pinnedPageIds.compactMap { byId[$0] }
    }

    func isPinned(_ id: String) -> Bool {
        pinnedPageIds.contains(id)
    }

    func togglePin(_ id: String) {
        if let idx = pinnedPageIds.firstIndex(of: id) {
            pinnedPageIds.remove(at: idx)
        } else {
            pinnedPageIds.append(id)
        }
    }

    func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
        }
    }

    func reveal(folder: String) {
        let clean = KnowledgeShellLogic.normalizeFolderPath(folder)
        guard !clean.isEmpty else { return }
        for ancestor in KnowledgeShellLogic.ancestors(of: "\(clean)/page") {
            expandedFolders.insert(ancestor)
        }
    }

    func collapseAll() {
        expandedFolders = []
        if let activeId = activeDestination.activePageId {
            // Keep the active page's path out of view if user explicitly collapsed all.
            _ = activeId
        }
    }

    func showAllPages(in folder: String) {
        showAllFolders.insert(folder)
    }

    // MARK: Navigation Helpers

    func applyMatch(_ match: NativeRouteMatch, in context: NativeScreenContext) {
        let next = KnowledgeShellLogic.destination(for: match)
        activeDestination = next
        legacyResolutionError = nil

        switch next {
        case .search(let initialQuery):
            if let q = initialQuery, !q.isEmpty, searchFilter.text != q {
                searchFilter.text = q
            }
            if let tag = match.query["tag"], !tag.isEmpty {
                searchFilter.tag = tag
            }
            if let folder = match.query["folder"], !folder.isEmpty {
                searchFilter.folder = folder
            }
        case .page(let id):
            let rows = self.rows(in: context)
            if let matchRow = rows.first(where: { $0.id == id }) {
                reveal(folder: KnowledgeShellLogic.parentOf(matchRow.path))
                syncViewModeIfNeeded(pageId: id, audience: matchRow.audience)
            }
        default:
            syncedAudiencePageId = nil
        }

        publishChrome(for: context)
    }

    func syncLoadedPage(_ page: KnowledgePage, in context: NativeScreenContext) {
        if let path = page.path {
            reveal(folder: KnowledgeShellLogic.parentOf(path))
        }
        syncViewModeIfNeeded(pageId: page.id, audience: page.audience)
        publishChrome(for: context, loadedPage: page)
    }

    private func syncViewModeIfNeeded(pageId: String, audience: KnowledgeAudience) {
        guard syncedAudiencePageId != pageId else { return }
        syncedAudiencePageId = pageId
        let desired: KnowledgeViewMode = audience == .agent ? .agent : .yours
        if viewMode != desired {
            viewMode = desired
        }
    }

    func openHome(in context: NativeScreenContext) {
        if case .home = activeDestination, context.match.path == "/knowledge", context.match.query.isEmpty {
            return
        }
        context.navigate("/knowledge")
    }

    func openSearch(
        query: String? = nil,
        tag: String? = nil,
        folder: String? = nil,
        orphans: Bool = false,
        unresolved: Bool = false,
        in context: NativeScreenContext
    ) {
        var next = KnowledgeSearchFilter()
        next.text = query ?? ""
        next.tag = tag ?? ""
        next.folder = folder ?? ""
        next.orphansOnly = orphans
        next.unresolvedOnly = unresolved
        next.includeAgent = viewMode == .agent
        searchFilter = next
        context.navigate("/knowledge?search=1")
    }

    func openPage(_ row: KnowledgePageRow, in context: NativeScreenContext, newTab: Bool = false) {
        let href = KnowledgeShellLogic.pageHref(id: row.id, title: row.title)
        if newTab {
            context.openInNewTab(href)
        } else {
            context.navigate(href)
        }
    }

    func openToday(in context: NativeScreenContext) {
        guard !isWorking else { return }
        isWorking = true
        let date = KnowledgeShellLogic.isoDay(Date())
        Task {
            defer { isWorking = false }
            do {
                let page = try await context.store.mutate(
                    KnowledgeAPI.dailyNote(date: date),
                    invalidating: KnowledgeAPI.invalidation
                )
                reveal(folder: KnowledgeShellLogic.parentOf(page.path ?? "Daily/"))
                context.navigate(KnowledgeShellLogic.pageHref(id: page.id, title: page.title))
            } catch {
                showErrorToast(id: "knowledge.daily", title: "Couldn\u{2019}t open today\u{2019}s note", error: error, in: context)
            }
        }
    }

    func resolveLegacyWiki(path: String, in context: NativeScreenContext) async {
        guard let client = context.store.client else {
            legacyResolutionError = APIError.unauthorized.userMessage
            return
        }
        legacyResolutionError = nil
        do {
            let resolved = try await client.send(KnowledgeAPI.resolveLegacy(path: path))
            let dest = resolved.url.isEmpty ? KnowledgeShellLogic.pageHref(id: resolved.id) : resolved.url
            context.navigate(dest)
        } catch {
            legacyResolutionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: Create Actions

    func createDocument(
        title: String = "Untitled",
        inFolder folder: String = "",
        template: String? = nil,
        in context: NativeScreenContext
    ) {
        guard !isWorking else { return }
        isWorking = true
        let cleanFolder = KnowledgeShellLogic.normalizeFolderPath(folder)
        let existing = Set(rows(in: context).map(\.path))
        let path = cleanFolder.isEmpty && title == "Untitled"
            ? nil
            : KnowledgeShellLogic.nextUntitledPath(in: cleanFolder, existingPaths: existing, baseName: title)
        let body = KnowledgePageInput(title: title, path: path, bodyMd: "", template: template)

        Task {
            defer { isWorking = false }
            do {
                let page = try await context.store.mutate(
                    KnowledgeAPI.createPage(body),
                    invalidating: KnowledgeAPI.invalidation
                )
                if !cleanFolder.isEmpty { reveal(folder: cleanFolder) }
                context.navigate(KnowledgeShellLogic.pageHref(id: page.id, title: page.title))
            } catch {
                showErrorToast(id: "knowledge.create", title: "Couldn\u{2019}t create page", error: error, in: context)
            }
        }
    }

    func createDeck(
        title: String = "Untitled deck",
        starter: API.CreateDeckBody.Starter? = nil,
        theme: API.CreateDeckBody.Theme = .light,
        brief: String? = nil,
        outline: String? = nil,
        in context: NativeScreenContext
    ) {
        guard !isWorking else { return }
        isWorking = true
        let invalidation = QueryInvalidation(
            resources: ["knowledge", "wiki", "artifacts", "slides", "canvases"],
            prefixes: [["knowledge"], ["wiki"], ["artifacts"], ["slides"]]
        )
        Task {
            defer { isWorking = false }
            do {
                let canvas = try await context.store.mutate(
                    API.createDeck(body: API.CreateDeckBody(starter: starter, theme: theme, title: title)),
                    invalidating: invalidation
                )
                let queryItems: [URLQueryItem] = [
                    brief.map { URLQueryItem(name: "brief", value: $0) },
                    outline.map { URLQueryItem(name: "outline", value: $0) },
                ].compactMap { $0 }
                let qs = APIQuery.encode(queryItems)
                let suffix = qs.isEmpty ? "" : "?\(qs)"

                if let client = context.store.client,
                   let pageRef = try? await client.send(API.getCanvasPage(canvasId: canvas.id)) {
                    context.navigate(KnowledgeShellLogic.pageHref(id: pageRef.id, title: pageRef.title) + suffix)
                } else {
                    context.navigate("/apps/slides/\(canvas.id)\(suffix)")
                }
            } catch {
                showErrorToast(id: "knowledge.deck", title: "Couldn\u{2019}t make the deck", error: error, in: context)
            }
        }
    }

    func createDesign(
        starter: API.CreateDesignBody.Starter = .blank,
        title: String = "",
        brief: String? = nil,
        in context: NativeScreenContext
    ) {
        guard !isWorking else { return }
        isWorking = true
        let invalidation = QueryInvalidation(
            resources: ["knowledge", "wiki", "artifacts", "designs", "canvases"],
            prefixes: [["knowledge"], ["wiki"], ["artifacts"], ["designs"]]
        )
        Task {
            defer { isWorking = false }
            do {
                let canvas = try await context.store.mutate(
                    API.createDesign(body: API.CreateDesignBody(project: nil, starter: starter, title: title)),
                    invalidating: invalidation
                )
                let qs = brief.map { APIQuery.encode([URLQueryItem(name: "brief", value: $0)]) } ?? ""
                let suffix = qs.isEmpty ? "" : "?\(qs)"

                if let client = context.store.client,
                   let pageRef = try? await client.send(API.getCanvasPage(canvasId: canvas.id)) {
                    context.navigate(KnowledgeShellLogic.pageHref(id: pageRef.id, title: pageRef.title) + suffix)
                } else {
                    context.navigate("/apps/designs/\(canvas.id)\(suffix)")
                }
            } catch {
                showErrorToast(id: "knowledge.design", title: "Couldn\u{2019}t make the design", error: error, in: context)
            }
        }
    }

    func createFolder(parent: String, name: String, in context: NativeScreenContext) async throws {
        let folder = KnowledgeShellLogic.joinPath(parent, name)
        let page = try await context.store.mutate(
            KnowledgeAPI.createPage(KnowledgePageInput(title: "Untitled", path: "\(folder)/Untitled", bodyMd: "")),
            invalidating: KnowledgeAPI.invalidation
        )
        reveal(folder: folder)
        context.navigate(KnowledgeShellLogic.pageHref(id: page.id, title: page.title))
    }

    // MARK: Rename, Move, Duplicate, Audience & Delete

    func startInlineRename(rowId: String, initial: String) {
        inlineRenameRowId = rowId
        inlineRenameText = initial
    }

    func cancelInlineRename() {
        inlineRenameRowId = nil
        inlineRenameText = ""
    }

    func commitInlineRename(in context: NativeScreenContext) {
        guard let rowId = inlineRenameRowId else { return }
        let nextName = inlineRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        inlineRenameRowId = nil
        inlineRenameText = ""

        if let err = KnowledgeShellLogic.nameError(nextName) {
            context.showToast(ToastItemModel(id: "knowledge.rename.invalid", title: err, tone: .error))
            return
        }

        if rowId.hasPrefix("p:") {
            let id = String(rowId.dropFirst(2))
            guard let row = rows(in: context).first(where: { $0.id == id }) else { return }
            Task {
                do {
                    try await renamePage(row, to: nextName, in: context)
                } catch {
                    showErrorToast(id: "knowledge.rename", title: "Couldn\u{2019}t rename page", error: error, in: context)
                }
            }
        } else if rowId.hasPrefix("f:") {
            let folderPath = String(rowId.dropFirst(2))
            Task {
                do {
                    try await renameFolder(folderPath, to: nextName, in: context)
                } catch {
                    showErrorToast(id: "knowledge.rename", title: "Couldn\u{2019}t rename folder", error: error, in: context)
                }
            }
        }
    }

    func renamePage(_ row: KnowledgePageRow, to newName: String, in context: NativeScreenContext) async throws {
        guard let plan = KnowledgeShellLogic.planPageRename(page: row, newName: newName) else { return }
        _ = try await context.store.mutate(
            KnowledgeAPI.movePage(id: row.id, title: plan.title, path: plan.path),
            invalidating: KnowledgeAPI.invalidation
        )
    }

    func renameFolder(_ path: String, to newName: String, in context: NativeScreenContext) async throws {
        guard let plan = KnowledgeShellLogic.planFolderRename(folderPath: path, newName: newName, expanded: expandedFolders) else {
            return
        }
        _ = try await context.store.mutate(
            KnowledgeAPI.moveFolder(from: plan.from, to: plan.to, agent: viewMode == .agent),
            invalidating: KnowledgeAPI.invalidation
        )
        expandedFolders = plan.updatedExpanded
    }

    func duplicatePage(_ row: KnowledgePageRow, in context: NativeScreenContext) {
        guard let client = context.store.client else { return }
        let existingPaths = Set(rows(in: context).map(\.path))
        Task {
            do {
                let full = try await client.send(KnowledgeAPI.getPage(id: row.id))
                let input = KnowledgeShellLogic.duplicatePageInput(from: full, existingPaths: existingPaths)
                let created = try await context.store.mutate(
                    KnowledgeAPI.createPage(input),
                    invalidating: KnowledgeAPI.invalidation
                )
                reveal(folder: KnowledgeShellLogic.parentOf(created.path ?? ""))
                context.navigate(KnowledgeShellLogic.pageHref(id: created.id, title: created.title))
            } catch {
                showErrorToast(id: "knowledge.duplicate", title: "Couldn\u{2019}t duplicate page", error: error, in: context)
            }
        }
    }

    func movePage(_ row: KnowledgePageRow, toFolder folder: String, in context: NativeScreenContext) async throws {
        let dest = KnowledgeShellLogic.joinPath(folder, KnowledgeShellLogic.nameOf(row.path.isEmpty ? row.title : row.path))
        _ = try await context.store.mutate(
            KnowledgeAPI.movePage(id: row.id, path: dest),
            invalidating: KnowledgeAPI.invalidation
        )
        reveal(folder: folder)
    }

    func moveFolder(_ path: String, toFolder folder: String, in context: NativeScreenContext) async throws {
        let to = KnowledgeShellLogic.joinPath(folder, KnowledgeShellLogic.nameOf(path))
        _ = try await context.store.mutate(
            KnowledgeAPI.moveFolder(from: path, to: to, agent: viewMode == .agent),
            invalidating: KnowledgeAPI.invalidation
        )
        var next = Set(expandedFolders.map { KnowledgeShellLogic.movedPath($0, from: path, to: to) })
        next.formUnion(KnowledgeShellLogic.ancestors(of: to))
        expandedFolders = next
    }

    func handleDrop(_ payload: String, ontoFolder destinationFolder: String, in context: NativeScreenContext) -> Bool {
        guard let item = KnowledgeDragItem.decodeDragPayload(payload),
              let plan = KnowledgeShellLogic.planDrop(item: item, ontoFolder: destinationFolder, expanded: expandedFolders)
        else { return false }

        Task {
            do {
                switch plan {
                case .movePage(let id, let newPath, let title):
                    _ = try await context.store.mutate(
                        KnowledgeAPI.movePage(id: id, title: title, path: newPath),
                        invalidating: KnowledgeAPI.invalidation
                    )
                    reveal(folder: destinationFolder)
                case .moveFolder(let from, let to, let updatedExpanded):
                    _ = try await context.store.mutate(
                        KnowledgeAPI.moveFolder(from: from, to: to, agent: viewMode == .agent),
                        invalidating: KnowledgeAPI.invalidation
                    )
                    expandedFolders = updatedExpanded
                }
            } catch {
                showErrorToast(id: "knowledge.drop", title: "Couldn\u{2019}t move item", error: error, in: context)
            }
        }
        return true
    }

    func setPageAudience(_ row: KnowledgePageRow, audience: KnowledgeAudience, in context: NativeScreenContext) {
        guard audience == .private || audience == .shared, row.audience != audience, row.audience != .agent else { return }
        Task {
            do {
                _ = try await context.store.mutate(
                    KnowledgeAPI.savePage(id: row.id, body: KnowledgePageInput(audience: audience.rawValue)),
                    invalidating: KnowledgeAPI.invalidation
                )
            } catch {
                showErrorToast(id: "knowledge.audience", title: "Couldn\u{2019}t update audience", error: error, in: context)
            }
        }
    }

    func setPageAudience(page: KnowledgePage, audience: KnowledgeAudience, in context: NativeScreenContext) {
        guard audience == .private || audience == .shared, page.audience != audience, page.audience != .agent else { return }
        Task {
            do {
                let updated = try await context.store.mutate(
                    KnowledgeAPI.savePage(id: page.id, body: KnowledgePageInput(audience: audience.rawValue)),
                    invalidating: KnowledgeAPI.invalidation
                )
                publishChrome(for: context, loadedPage: updated)
            } catch {
                showErrorToast(id: "knowledge.audience", title: "Couldn\u{2019}t update audience", error: error, in: context)
            }
        }
    }

    func deletePage(_ row: KnowledgePageRow, in context: NativeScreenContext) async throws {
        let res = try await context.store.mutate(
            KnowledgeAPI.deletePage(id: row.id),
            invalidating: KnowledgeAPI.invalidation
        )
        cleanupDeletedIds(res.deleted, in: context)
    }

    func deleteFolder(_ path: String, in context: NativeScreenContext) async throws {
        let res = try await context.store.mutate(
            KnowledgeAPI.deleteFolder(folder: path, agent: viewMode == .agent),
            invalidating: KnowledgeAPI.invalidation
        )
        cleanupDeletedIds(res.deleted, in: context)
    }

    func bulkMove(rowIds: [String], toFolder folder: String, in context: NativeScreenContext) async throws {
        let all = rows(in: context)
        let plan = KnowledgeShellLogic.bulkMovePlan(selectedRowIds: Set(rowIds), intoFolder: folder, allPages: all)
        for item in plan.folders {
            _ = try await context.store.mutate(
                KnowledgeAPI.moveFolder(from: item.from, to: item.to, agent: viewMode == .agent),
                invalidating: KnowledgeAPI.invalidation
            )
            expandedFolders = Set(expandedFolders.map { KnowledgeShellLogic.movedPath($0, from: item.from, to: item.to) })
        }
        for item in plan.pages {
            _ = try await context.store.mutate(
                KnowledgeAPI.movePage(id: item.id, path: item.path),
                invalidating: KnowledgeAPI.invalidation
            )
        }
        reveal(folder: folder)
        selection.clear()
        selectMode = false
    }

    func bulkDelete(rowIds: [String], in context: NativeScreenContext) async throws {
        let all = rows(in: context)
        let plan = KnowledgeShellLogic.minimalDeletePlan(selectedRowIds: Set(rowIds), allPages: all)
        var deleted: [String] = []
        for folder in plan.folders {
            let res = try await context.store.mutate(
                KnowledgeAPI.deleteFolder(folder: folder, agent: viewMode == .agent),
                invalidating: KnowledgeAPI.invalidation
            )
            deleted.append(contentsOf: res.deleted)
        }
        for pageId in plan.pageIds {
            let res = try await context.store.mutate(
                KnowledgeAPI.deletePage(id: pageId),
                invalidating: KnowledgeAPI.invalidation
            )
            deleted.append(contentsOf: res.deleted)
        }
        selection.clear()
        selectMode = false
        cleanupDeletedIds(deleted, in: context)
    }

    func bulkSetAudience(rowIds: [String], to audience: KnowledgeAudience, in context: NativeScreenContext) {
        let targets = KnowledgeShellLogic.bulkAudienceTargets(selectedRowIds: Set(rowIds), allPages: rows(in: context), to: audience)
        guard !targets.isEmpty else { return }
        Task {
            do {
                for row in targets {
                    _ = try await context.store.mutate(
                        KnowledgeAPI.savePage(id: row.id, body: KnowledgePageInput(audience: audience.rawValue)),
                        invalidating: KnowledgeAPI.invalidation
                    )
                }
                context.showToast(ToastItemModel(
                    id: "knowledge.bulk.audience",
                    title: "Updated \(targets.count) \(targets.count == 1 ? "page" : "pages") to \(audience.rawValue.capitalized)",
                    tone: .success
                ))
            } catch {
                showErrorToast(id: "knowledge.bulk.audience.err", title: "Couldn\u{2019}t update audience", error: error, in: context)
            }
        }
    }

    private func cleanupDeletedIds(_ deleted: [String], in context: NativeScreenContext) {
        let gone = Set(deleted)
        pinnedPageIds.removeAll { gone.contains($0) }
        if let active = activeDestination.activePageId, gone.contains(active) {
            context.navigate("/knowledge")
        }
    }

    // MARK: Clipboard & Refresh

    func copyPageWikilink(_ row: KnowledgePageRow, in context: NativeScreenContext) {
        let target = row.path.isEmpty ? row.title : row.path
        context.copyToClipboard("[[\(target)]]")
        context.showToast(ToastItemModel(id: "knowledge.copy.\(row.id)", title: "Wikilink copied", tone: .success))
    }

    func copyPageLink(_ row: KnowledgePageRow, in context: NativeScreenContext) {
        let href = KnowledgeShellLogic.pageHref(id: row.id, title: row.title)
        context.copyToClipboard(context.resolvedURL(href)?.absoluteString ?? href)
        context.showToast(ToastItemModel(id: "knowledge.link.\(row.id)", title: "Link copied", tone: .success))
    }

    func copyPageWikilink(page: KnowledgePage, in context: NativeScreenContext) {
        let target = (page.path ?? "").isEmpty ? page.title : (page.path ?? page.title)
        context.copyToClipboard("[[\(target)]]")
        context.showToast(ToastItemModel(id: "knowledge.copy.\(page.id)", title: "Wikilink copied", tone: .success))
    }

    func copyPageLink(page: KnowledgePage, in context: NativeScreenContext) {
        let href = KnowledgeShellLogic.pageHref(id: page.id, title: page.title)
        context.copyToClipboard(context.resolvedURL(href)?.absoluteString ?? href)
        context.showToast(ToastItemModel(id: "knowledge.link.\(page.id)", title: "Link copied", tone: .success))
    }

    func refreshAll(in context: NativeScreenContext) {
        Task {
            _ = await context.store.refetch(treeListRequest)
            await loadFullTreeIfNeeded(in: context)
            if case .page(let id) = activeDestination {
                _ = await context.store.refetch(KnowledgeAPI.getPage(id: id))
            }
        }
    }

    func showErrorToast(id: String, title: String, error: Error, in context: NativeScreenContext) {
        let message = (error as? APIError)?.userMessage ?? error.localizedDescription
        context.showToast(ToastItemModel(id: id, title: title, description: message, tone: .error))
    }

    // MARK: Chrome & Commands

    func currentHeadings(for pageId: String, loadedPage: KnowledgePage?) -> [KnowledgeOutlineHeading] {
        if liveHeadingsPageId == pageId {
            return liveHeadings
        }
        return KnowledgeInspectorLogic.extractHeadings(from: loadedPage?.bodyMd ?? "")
    }

    func updateLiveHeadings(pageId: String, headings: [KnowledgeOutlineHeading], in context: NativeScreenContext) {
        guard liveHeadingsPageId != pageId || liveHeadings != headings else { return }
        liveHeadingsPageId = pageId
        liveHeadings = headings
        if case .page(let activeId) = activeDestination, activeId == pageId {
            publishChrome(for: context, loadedPage: context.store.entry(KnowledgeAPI.getPage(id: pageId)).data)
        }
    }

    private func buildInspector(for context: NativeScreenContext, loadedPage: KnowledgePage?) -> InspectorModel {
        let effectivePage: KnowledgePage?
        let headings: [KnowledgeOutlineHeading]
        if case .page(let pageId) = activeDestination {
            effectivePage = loadedPage ?? context.store.entry(KnowledgeAPI.getPage(id: pageId)).data
            headings = currentHeadings(for: pageId, loadedPage: effectivePage)
        } else {
            effectivePage = nil
            headings = []
        }
        return KnowledgeInspectorLogic.buildInspectorModel(
            destination: activeDestination,
            loadedPage: effectivePage,
            headings: headings,
            query: context.match.query,
            generalChatId: generalChatId,
            open: inspectorOpen,
            activeTabId: inspectorTabId
        )
    }

    func publishChrome(for context: NativeScreenContext, loadedPage: KnowledgePage? = nil) {
        let inspector = buildInspector(for: context, loadedPage: loadedPage)
        switch activeDestination {
        case .home:
            context.chrome = NativeChrome(
                title: "Knowledge",
                subtitle: viewMode == .agent ? "Agent knowledge" : "Your knowledge",
                toolbarItems: [
                    ShellToolbarItem(id: "kn.search", label: "Search", icon: "search", kind: .button),
                    ShellToolbarItem(id: "kn.graph", label: "Graph", icon: "graph", kind: .button),
                    ShellToolbarItem(id: "kn.connect", label: "Connect", icon: "link", kind: .button),
                    ShellToolbarItem(id: "kn.capture", label: "Capture", icon: "inbox", kind: .button),
                    ShellToolbarItem(id: "kn.new", label: "New Page", icon: "plus", kind: .button, accent: true, showsLabel: true),
                ],
                inspector: inspector
            )
        case .start(let kind):
            let title = switch kind {
            case .document: "Documents"
            case .deck: "Decks"
            case .design: "Designs"
            }
            context.chrome = NativeChrome(
                title: title,
                subtitle: "Knowledge",
                toolbarItems: [
                    ShellToolbarItem(id: "kn.home", label: "Home", icon: "home", kind: .button),
                    ShellToolbarItem(id: "kn.search", label: "Search", icon: "search", kind: .button),
                ],
                inspector: inspector
            )
        case .search:
            context.chrome = NativeChrome(
                title: "Search Knowledge",
                toolbarItems: [
                    ShellToolbarItem(id: "kn.home", label: "Home", icon: "home", kind: .button),
                    ShellToolbarItem(id: "kn.graph", label: "Graph", icon: "graph", kind: .button),
                    ShellToolbarItem(id: "kn.capture", label: "Capture", icon: "inbox", kind: .button),
                ],
                inspector: inspector
            )
        case .connect:
            context.chrome = NativeChrome(
                title: "Keep Notes Connected",
                subtitle: "Knowledge",
                toolbarItems: [
                    ShellToolbarItem(id: "kn.home", label: "Home", icon: "home", kind: .button),
                    ShellToolbarItem(id: "kn.graph", label: "Graph", icon: "graph", kind: .button),
                    ShellToolbarItem(id: "kn.search", label: "Search", icon: "search", kind: .button),
                ],
                inspector: inspector
            )
        case .graph:
            context.chrome = NativeChrome(
                title: "Graph View",
                subtitle: "Knowledge",
                toolbarItems: [
                    ShellToolbarItem(id: "kn.home", label: "Home", icon: "home", kind: .button),
                    ShellToolbarItem(id: "kn.connect", label: "Connect", icon: "link", kind: .button),
                    ShellToolbarItem(id: "kn.search", label: "Search", icon: "search", kind: .button),
                ],
                inspector: inspector
            )
        case .legacyWiki(let path):
            context.chrome = NativeChrome(
                title: KnowledgeShellLogic.nameOf(path),
                subtitle: "Wiki",
                inspector: inspector
            )
        case .page(let id):
            let row = rows(in: context).first(where: { $0.id == id })
            let title = loadedPage.flatMap { $0.title.isEmpty ? nil : $0.title } ?? row?.title ?? "Page"
            let path = loadedPage?.path ?? row?.path ?? ""
            let audience = loadedPage?.audience ?? row?.audience ?? .private

            let audienceIcon = switch audience {
            case .private: "lock"
            case .shared: "users"
            case .agent: "agents"
            }
            let audienceMenu: [MenuItem] = KnowledgeAudience.allCases.map { aud in
                MenuItem(
                    id: "audience:\(aud.rawValue)",
                    label: aud.rawValue.capitalized,
                    icon: aud == .private ? "lock" : (aud == .shared ? "users" : "agents"),
                    disabled: aud == .agent,
                    checked: aud == audience
                )
            }
            let moreMenu: [MenuItem] = [
                MenuItem(id: "page.open-new-tab", label: "Open in New Tab", icon: "external"),
                MenuItem(id: "page.pin", label: isPinned(id) ? "Unpin" : "Pin to Top", icon: "bookmark"),
                MenuItem(id: "sep-1", separator: true),
                MenuItem(id: "page.rename", label: "Rename\u{2026}", icon: "edit"),
                MenuItem(id: "page.move", label: "Move to\u{2026}", icon: "folder"),
                MenuItem(id: "page.duplicate", label: "Duplicate", icon: "copy"),
                MenuItem(id: "sep-2", separator: true),
                MenuItem(id: "page.delete", label: "Delete\u{2026}", icon: "trash", destructive: true),
            ]
            context.chrome = NativeChrome(
                title: title,
                subtitle: KnowledgeShellLogic.folderDisplay(of: path),
                toolbarItems: [
                    ShellToolbarItem(
                        id: "kn.page.audience",
                        label: audience.rawValue.capitalized,
                        icon: audienceIcon,
                        kind: .menu,
                        menu: audienceMenu,
                        showsLabel: true
                    ),
                    ShellToolbarItem(id: "kn.page.copy-link", label: "Copy [[link]]", icon: "link", kind: .button),
                    ShellToolbarItem(id: "kn.page.more", label: "More", icon: "dots", kind: .menu, menu: moreMenu),
                ],
                inspector: inspector
            )
        }
    }

    func handleChromeCommand(_ command: NativeCommand, in context: NativeScreenContext) {
        switch command {
        case .inspectorVisibility(let open):
            inspectorOpen = open
            publishChrome(for: context)
            return
        case .inspectorSelectTab(let tabId):
            inspectorTabId = tabId
            inspectorOpen = true
            publishChrome(for: context)
            return
        case .inspectorAction(let tabId, let actionId, let itemId, _):
            if tabId == KnowledgeInspectorLogic.outlineTabId,
               actionId == KnowledgeInspectorLogic.jumpHeadingActionId,
               case .page(let pageId) = activeDestination,
               let itemId,
               let idx = KnowledgeInspectorLogic.parseHeadingIndex(from: itemId) {
                let headings = currentHeadings(
                    for: pageId,
                    loadedPage: context.store.entry(KnowledgeAPI.getPage(id: pageId)).data
                )
                if idx >= 0 && idx < headings.count {
                    headingJumpToken += 1
                    headingJumpRequest = KnowledgeHeadingJumpRequest(
                        token: headingJumpToken,
                        pageId: pageId,
                        heading: headings[idx]
                    )
                }
            }
            return
        case .panelEvent(let tabId, let event, let payloadJson):
            if tabId == KnowledgeInspectorLogic.chatTabId,
               event == "generalChat",
               let chatId = KnowledgeInspectorLogic.parseGeneralChatId(from: payloadJson),
               chatId != generalChatId {
                generalChatId = chatId
                publishChrome(for: context)
            }
            return
        default:
            break
        }
        guard case .toolbarAction(let itemId, let menuItemId) = command else { return }
        switch itemId {
        case "kn.home": openHome(in: context)
        case "kn.search": openSearch(in: context)
        case "kn.graph": context.navigate("/knowledge/graph")
        case "kn.connect": context.navigate("/knowledge/connect")
        case "kn.capture": sheet = .capture
        case "kn.new": createDocument(in: context)
        case "kn.page.copy-link":
            guard case .page(let id) = activeDestination else { return }
            if let page = context.store.entry(KnowledgeAPI.getPage(id: id)).data {
                copyPageWikilink(page: page, in: context)
            } else if let row = rows(in: context).first(where: { $0.id == id }) {
                copyPageWikilink(row, in: context)
            }
        case "kn.page.audience":
            guard case .page(let id) = activeDestination,
                  let menuItemId,
                  menuItemId.hasPrefix("audience:"),
                  let aud = KnowledgeAudience(rawValue: String(menuItemId.dropFirst("audience:".count))),
                  let page = context.store.entry(KnowledgeAPI.getPage(id: id)).data
            else { return }
            setPageAudience(page: page, audience: aud, in: context)
        case "kn.page.more":
            guard case .page(let id) = activeDestination, let menuItemId else { return }
            let row = rows(in: context).first(where: { $0.id == id })
                ?? context.store.entry(KnowledgeAPI.getPage(id: id)).data.map { page in
                    KnowledgePageRow(
                        id: page.id,
                        title: page.title,
                        path: page.path ?? page.title,
                        audience: page.audience,
                        properties: page.properties,
                        versionId: page.versionId,
                        kind: page.kind,
                        canvasId: page.canvasId
                    )
                }
            guard let row else { return }
            switch menuItemId {
            case "page.open-new-tab": openPage(row, in: context, newTab: true)
            case "page.pin":
                togglePin(row.id)
                publishChrome(for: context, loadedPage: context.store.entry(KnowledgeAPI.getPage(id: id)).data)
            case "page.rename": sheet = .renamePage(row)
            case "page.move": sheet = .move(target: .page(row))
            case "page.duplicate": duplicatePage(row, in: context)
            case "page.delete": sheet = .delete(target: .page(row))
            default: break
            }
        default:
            break
        }
    }
}

// MARK: - Top-Level Screen

struct KnowledgeScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var controller = KnowledgeShellController()

    var body: some View {
        let treeEntry = context.store.entry(controller.treeListRequest)

        Group {
            switch controller.activeDestination {
            case .home:
                KnowledgeHomeView(controller: controller, startKind: nil)
            case .start(let kind):
                KnowledgeHomeView(controller: controller, startKind: kind)
            case .search:
                KnowledgeSearchView(controller: controller)
            case .connect:
                KnowledgeConnectView(controller: controller)
            case .graph:
                KnowledgeGraphScreenSlot()
            case .page(let pageId):
                KnowledgePageView(controller: controller, pageId: pageId)
                    .id(pageId)
            case .legacyWiki(let wikiPath):
                legacyResolutionView(path: wikiPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: theme, initial: true) { _, next in
            controller.theme = next
        }
        .onChange(of: colorScheme, initial: true) { _, next in
            controller.colorScheme = next
        }
        .onChange(of: context.match, initial: true) { _, match in
            controller.applyMatch(match, in: context)
        }
        .task(id: controller.treeListRequest.key) {
            context.store.load(controller.treeListRequest)
            context.store.load(KnowledgeShellController.slideStartersRequest)
        }
        .task(id: "\(controller.viewMode.rawValue)|\(treeEntry.updatedAt?.timeIntervalSince1970 ?? 0)") {
            await controller.loadFullTreeIfNeeded(in: context)
        }
        .onChange(of: controller.viewMode) { oldMode, newMode in
            let oldReq = KnowledgeAPI.listPages(
                audience: oldMode == .agent ? .agent : nil,
                includeAgent: oldMode == .agent,
                limit: 200,
                offset: 0
            )
            context.store.stopObserving(oldReq.key)
            context.store.observe(controller.treeListRequest)
            context.store.load(controller.treeListRequest)
            controller.publishChrome(for: context)
        }
        .onAppear {
            controller.theme = theme
            controller.colorScheme = colorScheme
            context.store.observe(controller.treeListRequest)
            context.sidebarView = AnyView(KnowledgeSidebarHost(context: context, controller: controller))
            context.inspectorView = { tabId in
                guard let tab = KnowledgeSidePanelsView.Tab(inspectorTabId: tabId) else { return nil }
                return AnyView(KnowledgeInspectorHost(context: context, controller: controller, tab: tab))
            }
            context.onCommand = { command in
                controller.handleChromeCommand(command, in: context)
            }
            controller.publishChrome(for: context)
        }
        .onDisappear {
            context.store.stopObserving(controller.treeListRequest.key)
            context.sidebarView = nil
            context.inspectorView = nil
            context.onCommand = nil
        }
        .sheet(item: $controller.sheet) { sheetKind in
            sheetView(for: sheetKind)
                .environment(context)
                .environment(\.vesperTheme, theme)
                .environment(\.colorScheme, colorScheme)
        }
    }

    @ViewBuilder
    private func legacyResolutionView(path: String) -> some View {
        Group {
            if let error = controller.legacyResolutionError {
                QueryErrorView(message: error) {
                    Task { await controller.resolveLegacyWiki(path: path, in: context) }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening wiki page\u{2026}")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            await controller.resolveLegacyWiki(path: path, in: context)
        }
    }

    @ViewBuilder
    private func sheetView(for kind: KnowledgeSheetKind) -> some View {
        switch kind {
        case .capture:
            KnowledgeCaptureSheet(controller: controller)
        case .vaultImport:
            KnowledgeImportSheet(controller: controller)
        case .newFolder(let parent):
            KnowledgeNewFolderSheet(controller: controller, parent: parent)
        case .renamePage(let row):
            KnowledgeRenameSheet(
                title: "Rename \u{201C}\(row.title)\u{201D}",
                initialName: row.title
            ) { newName in
                try await controller.renamePage(row, to: newName, in: context)
            }
        case .renameFolder(let path, let name):
            KnowledgeRenameSheet(
                title: "Rename \u{201C}\(name)\u{201D}",
                initialName: name
            ) { newName in
                try await controller.renameFolder(path, to: newName, in: context)
            }
        case .move(let target):
            KnowledgeMoveSheet(
                controller: controller,
                title: "Move \u{201C}\(target.title)\u{201D}",
                sourcePath: target.path,
                isFolder: target.isFolder
            ) { folder in
                switch target {
                case .page(let row): try await controller.movePage(row, toFolder: folder, in: context)
                case .folder(let path, _): try await controller.moveFolder(path, toFolder: folder, in: context)
                }
            }
        case .delete(let target):
            KnowledgeDeleteSheet(target: target) {
                switch target {
                case .page(let row): try await controller.deletePage(row, in: context)
                case .folder(let path, _, _): try await controller.deleteFolder(path, in: context)
                }
            }
        case .bulkMove(let rowIds):
            KnowledgeMoveSheet(
                controller: controller,
                title: "Move \(rowIds.count) items",
                sourcePath: "",
                isFolder: false
            ) { folder in
                try await controller.bulkMove(rowIds: rowIds, toFolder: folder, in: context)
            }
        case .bulkDelete(let rowIds):
            let plan = KnowledgeShellLogic.minimalDeletePlan(selectedRowIds: Set(rowIds), allPages: controller.rows(in: context))
            KnowledgeBulkDeleteSheet(itemCount: rowIds.count, affectedPageCount: plan.affectedPageCount) {
                try await controller.bulkDelete(rowIds: rowIds, in: context)
            }
        }
    }
}

// MARK: - Knowledge Page Host (Seam for LAZYAGENTS-287 & LAZYAGENTS-288)

private struct KnowledgePageView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let controller: KnowledgeShellController
    let pageId: String

    private var request: APIRequest<KnowledgePage> {
        KnowledgeAPI.getPage(id: pageId)
    }

    var body: some View {
        let entry = context.store.entry(request)

        Group {
            if let page = entry.data {
                KnowledgePageEditorSlot(
                    page: page,
                    query: context.match.query,
                    headingJumpRequest: controller.headingJumpRequest,
                    onHeadingsChange: { headings in
                        controller.updateLiveHeadings(pageId: page.id, headings: headings, in: context)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = entry.error {
                QueryErrorView(message: "This page isn\u{2019}t available: \(error.userMessage)") {
                    Task { _ = await context.store.refetch(request) }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    SkeletonBar(height: 28).frame(maxWidth: 320)
                    SkeletonBar(height: 16)
                    SkeletonBar(height: 16).frame(maxWidth: 520)
                    Spacer()
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task(id: pageId) {
            context.store.load(request)
        }
        .onChange(of: entry.data, initial: true) { _, page in
            if let page {
                controller.syncLoadedPage(page, in: context)
            }
        }
        .onAppear {
            context.store.observe(request)
        }
        .onDisappear {
            context.store.stopObserving(request.key)
        }
    }
}

// MARK: - Keep Notes Connected (/knowledge/connect)

struct KnowledgeConnectView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case unresolved = "Unresolved links"
        case orphans = "Orphans"
        var id: String { rawValue }
    }

    private static let librarianName = "Weekly Knowledge librarian"
    private static let librarianPrompt =
        "Call librarian_pass with all: true. It proposes links for unlinked mentions and reports orphans and unresolved links; every change arrives as a suggestion for me to review. Then summarise what it found in a few lines."

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let controller: KnowledgeShellController

    @State private var tab: Tab = .unresolved
    @State private var librarianError: String?
    @State private var creatingTarget: String?

    private static let scheduledTasksRequest = API.listScheduledTasks()
    private static let orphansRequest = KnowledgeAPI.listPages(orphans: true, limit: 100)

    var body: some View {
        let p = theme.palette
        let netEntry = context.store.entry(controller.networkRequest)
        let orphansEntry = context.store.entry(Self.orphansRequest)
        let tasksEntry = context.store.entry(Self.scheduledTasksRequest)
        let unresolved = netEntry.data.map { KnowledgeShellLogic.unresolvedTargets(in: $0) } ?? []
        let orphanRows = orphansEntry.data?.rows ?? []
        let librarianTask = (tasksEntry.data?.tasks ?? []).first(where: { $0.name == Self.librarianName })

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 18))
                            .foregroundStyle(p.accent)
                        Text("Keep notes connected")
                            .vesperText(.display, theme)
                            .foregroundStyle(p.text)
                    }

                    librarianCard(task: librarianTask)

                    Picker("Connect tab", selection: $tab) {
                        Text("Unresolved links (\(unresolved.count))").tag(Tab.unresolved)
                        Text("Orphans (\(orphanRows.count))").tag(Tab.orphans)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)

                    switch tab {
                    case .unresolved:
                        unresolvedList(netEntry: netEntry, unresolved: unresolved)
                    case .orphans:
                        orphansList(orphansEntry: orphansEntry, rows: orphanRows)
                    }
                }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider().overlay(p.border)
            HStack {
                Text("Private pages are only checked against your own pages")
                Spacer()
                Text("\(unresolved.count) unresolved \u{00B7} \(orphanRows.count) orphans")
            }
            .font(.system(size: theme.pointSize(.micro) + 1))
            .foregroundStyle(p.tertiaryText)
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        }
        .task {
            context.store.load(controller.networkRequest)
            context.store.load(Self.orphansRequest)
            context.store.load(Self.scheduledTasksRequest)
        }
        .onAppear {
            context.store.observe(controller.networkRequest)
            context.store.observe(Self.orphansRequest)
            context.store.observe(Self.scheduledTasksRequest)
        }
        .onChange(of: controller.viewMode) { oldMode, newMode in
            context.store.stopObserving(KnowledgeAPI.getNetwork(includeAgent: oldMode == .agent).key)
            let nextNet = KnowledgeAPI.getNetwork(includeAgent: newMode == .agent)
            context.store.observe(nextNet)
            context.store.load(nextNet)
        }
        .onDisappear {
            context.store.stopObserving(controller.networkRequest.key)
            context.store.stopObserving(Self.orphansRequest.key)
            context.store.stopObserving(Self.scheduledTasksRequest.key)
        }
    }

    private func librarianCard(task: API.ScheduledTask?) -> some View {
        let p = theme.palette
        return HStack(spacing: 14) {
            Image(systemName: "lightbulb")
                .font(.system(size: 18))
                .foregroundStyle(p.accent)
                .frame(width: 36, height: 36)
                .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(task.map { "Weekly librarian pass \u{00B7} Mondays \($0.atTime)" } ?? "Weekly librarian pass")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                Text(task != nil
                     ? "A persona proposes links for unlinked mentions and lists orphans. Suggestions wait for you in Needs you."
                     : "Have a persona propose the links you missed once a week. Nothing changes until you accept it.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
                if let librarianError {
                    Text(librarianError)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }

            Spacer()

            if let task {
                Button("Run now") {
                    Task {
                        librarianError = nil
                        do {
                            _ = try await context.store.mutate(
                                API.runScheduledTask(id: task.id),
                                invalidating: QueryInvalidation(resources: ["scheduled-tasks"])
                            )
                            context.showToast(ToastItemModel(id: "knowledge.librarian.run", title: "Librarian started", tone: .success))
                        } catch {
                            librarianError = (error as? APIError)?.userMessage ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.vesper())
            } else {
                Button("Set it up") {
                    Task {
                        librarianError = nil
                        do {
                            let body = API.ScheduledTaskInput(
                                atTime: "09:00",
                                enabled: true,
                                frequency: .weekly,
                                instructions: Self.librarianPrompt,
                                kind: .prompt,
                                name: Self.librarianName,
                                timezone: TimeZone.current.identifier,
                                weekdays: [1]
                            )
                            _ = try await context.store.mutate(
                                API.createScheduledTask(body: body),
                                invalidating: QueryInvalidation(resources: ["scheduled-tasks"])
                            )
                        } catch {
                            librarianError = (error as? APIError)?.userMessage ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.vesper(.primary))
            }
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    @ViewBuilder
    private func unresolvedList(netEntry: QueryEntry<KnowledgeNetwork>, unresolved: [KnowledgeUnresolvedTarget]) -> some View {
        let p = theme.palette
        Text("Links to pages that don\u{2019}t exist yet. Create one and every link to it starts working.")
            .vesperText(.small, theme)
            .foregroundStyle(p.secondaryText)

        if let error = netEntry.error, netEntry.data == nil {
            QueryErrorView(message: error.userMessage) {
                Task { _ = await context.store.refetch(controller.networkRequest) }
            }
        } else if netEntry.data == nil {
            SkeletonBar(height: 44)
        } else if unresolved.isEmpty {
            Text("Every link resolves.")
                .vesperText(.body, theme)
                .foregroundStyle(p.tertiaryText)
                .padding(.vertical, 20)
        } else {
            VStack(spacing: 8) {
                ForEach(unresolved) { target in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.name)
                                .font(.system(size: theme.pointSize(.body), weight: .medium))
                                .foregroundStyle(p.accent)
                            let srcSummary = target.sources.prefix(3).map(\.title).joined(separator: ", ")
                                + (target.sources.count > 3 ? " and \(target.sources.count - 3) more" : "")
                            if !srcSummary.isEmpty {
                                Text("from \(srcSummary)")
                                    .vesperText(.small, theme)
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("\(target.sources.count) \(target.sources.count == 1 ? "page" : "pages")")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.tertiaryText)
                        Button(creatingTarget == target.name ? "Creating\u{2026}" : "Create page") {
                            creatingTarget = target.name
                            let pageTitle = KnowledgeShellLogic.nameOf(target.name)
                            Task {
                                defer { creatingTarget = nil }
                                do {
                                    let page = try await context.store.mutate(
                                        KnowledgeAPI.createPage(KnowledgePageInput(title: pageTitle, path: target.name, bodyMd: "")),
                                        invalidating: KnowledgeAPI.invalidation
                                    )
                                    context.navigate(KnowledgeShellLogic.pageHref(id: page.id, title: page.title))
                                } catch {
                                    controller.showErrorToast(id: "knowledge.connect.create", title: "Couldn\u{2019}t create page", error: error, in: context)
                                }
                            }
                        }
                        .buttonStyle(.vesper())
                        .disabled(creatingTarget != nil)
                    }
                    .padding(12)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                }
            }
        }
    }

    @ViewBuilder
    private func orphansList(orphansEntry: QueryEntry<KnowledgePageTable>, rows: [KnowledgePageRow]) -> some View {
        let p = theme.palette
        Text("Pages with no links in or out. Link them from a structure page, or let the librarian propose links.")
            .vesperText(.small, theme)
            .foregroundStyle(p.secondaryText)

        if let error = orphansEntry.error, orphansEntry.data == nil {
            QueryErrorView(message: error.userMessage) {
                Task { _ = await context.store.refetch(Self.orphansRequest) }
            }
        } else if orphansEntry.data == nil {
            SkeletonBar(height: 44)
        } else if rows.isEmpty {
            Text("No orphans: every page links somewhere.")
                .vesperText(.body, theme)
                .foregroundStyle(p.tertiaryText)
                .padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Button {
                        controller.openPage(row, in: context)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: KnowledgeShellLogic.pageSymbol(for: row))
                                .foregroundStyle(p.tertiaryText)
                            Text(KnowledgeShellLogic.displayTitle(for: row))
                                .vesperText(.body, theme)
                                .foregroundStyle(p.text)
                            Spacer()
                            Text(KnowledgeShellLogic.folderDisplay(of: row.path))
                                .vesperText(.small, theme)
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(p.rowBorder)
                }
            }
        }
    }
}

// MARK: - Explorer Modal Sheets

struct KnowledgeCaptureSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let controller: KnowledgeShellController

    @State private var text = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick capture")
                .vesperText(.heading, theme)
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .foregroundStyle(p.accent)
                Text("Goes to Inbox. File it later, or let a persona file it for you.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
            }

            TextEditor(text: $text)
                .font(.system(size: theme.pointSize(.reading)))
                .focused($focused)
                .frame(minHeight: 110, maxHeight: 200)
                .padding(8)
                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))

            if let errorMessage {
                Text(errorMessage)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.vesper())
                Spacer()
                Button(submitting ? "Capturing\u{2026}" : "Capture") {
                    submit()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.vesper(.primary))
                .disabled(submitting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(p.background)
        .onAppear { focused = true }
    }

    private func submit() {
        guard let body = KnowledgeShellLogic.captureInput(from: text) else { return }
        submitting = true
        errorMessage = nil
        Task {
            defer { submitting = false }
            do {
                let created = try await context.store.mutate(
                    KnowledgeAPI.captureNote(body),
                    invalidating: KnowledgeAPI.invalidation
                )
                controller.reveal(folder: "Inbox")
                context.showToast(ToastItemModel(id: "knowledge.capture.\(created.id)", title: "Captured to Inbox", tone: .success))
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

struct KnowledgeNewFolderSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let controller: KnowledgeShellController
    let parent: String

    @State private var name = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        let liveError = name.isEmpty ? nil : KnowledgeShellLogic.nameError(name)
        VStack(alignment: .leading, spacing: 14) {
            Text("New folder")
                .vesperText(.heading, theme)
            Text((parent.isEmpty ? "" : "In \(parent). ") + "Starts with an empty page, since folders hold pages.")
                .vesperText(.small, theme)
                .foregroundStyle(p.secondaryText)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

            if let msg = liveError ?? errorMessage {
                Text(msg)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.vesper())
                Spacer()
                Button(submitting ? "Creating\u{2026}" : "Create folder") { submit() }
                    .buttonStyle(.vesper(.primary))
                    .disabled(submitting || KnowledgeShellLogic.nameError(name) != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(p.background)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KnowledgeShellLogic.nameError(trimmed) == nil else { return }
        submitting = true
        errorMessage = nil
        Task {
            defer { submitting = false }
            do {
                try await controller.createFolder(parent: parent, name: trimmed, in: context)
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

struct KnowledgeRenameSheet: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialName: String
    let onCommit: (String) async throws -> Void

    @State private var name: String
    @State private var submitting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(title: String, initialName: String, onCommit: @escaping (String) async throws -> Void) {
        self.title = title
        self.initialName = initialName
        self.onCommit = onCommit
        _name = State(initialValue: initialName)
    }

    var body: some View {
        let p = theme.palette
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveError = trimmed != initialName && !name.isEmpty ? KnowledgeShellLogic.nameError(trimmed) : nil
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .vesperText(.heading, theme)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

            if let msg = liveError ?? errorMessage {
                Text(msg)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.vesper())
                Spacer()
                Button(submitting ? "Renaming\u{2026}" : "Rename") { submit() }
                    .buttonStyle(.vesper(.primary))
                    .disabled(submitting || trimmed.isEmpty || KnowledgeShellLogic.nameError(trimmed) != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(p.background)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == initialName {
            dismiss()
            return
        }
        guard KnowledgeShellLogic.nameError(trimmed) == nil else { return }
        submitting = true
        errorMessage = nil
        Task {
            defer { submitting = false }
            do {
                try await onCommit(trimmed)
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

struct KnowledgeMoveSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let controller: KnowledgeShellController
    let title: String
    let sourcePath: String
    let isFolder: Bool
    let onMove: (String) async throws -> Void

    @State private var filter = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        let p = theme.palette
        let tree = KnowledgeShellLogic.buildTree(from: controller.rows(in: context), prioritizeInbox: true)
        let folders = KnowledgeShellLogic.folderPaths(in: tree)
        let options: [String] = sourcePath.isEmpty
            ? ([""] + folders).filter { filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.localizedCaseInsensitiveContains(filter) }
            : KnowledgeShellLogic.moveTargets(folders: folders, path: sourcePath, isFolder: isFolder, filter: filter)

        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .vesperText(.heading, theme)

            TextField("Find a folder\u{2026}", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let first = options.first { performMove(to: first) }
                }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(options, id: \.self) { folder in
                        Button {
                            performMove(to: folder)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(p.secondaryText)
                                Text(folder.isEmpty ? "Knowledge (top level)" : folder)
                                    .vesperText(.body, theme)
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(submitting)
                    }
                    if options.isEmpty {
                        Text("No folder matches.")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.tertiaryText)
                            .padding(.vertical, 16)
                    }
                }
            }
            .frame(height: 220)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))

            if let errorMessage {
                Text(errorMessage)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.vesper())
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(p.background)
        .onAppear { focused = true }
    }

    private func performMove(to folder: String) {
        submitting = true
        errorMessage = nil
        Task {
            defer { submitting = false }
            do {
                try await onMove(folder)
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

struct KnowledgeDeleteSheet: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let target: KnowledgeDeleteTarget
    let onDelete: () async throws -> Void

    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let titleText: String = switch target {
        case .page(let row): "Delete \u{201C}\(row.title)\u{201D}?"
        case .folder(_, let name, _): "Delete the folder \u{201C}\(name)\u{201D}?"
        }
        let bodyText: String = switch target {
        case .page:
            "This deletes the page and its history. It can\u{2019}t be undone. Links to it stay as unresolved links."
        case .folder(_, _, let count):
            "This deletes the \(count == 1 ? "page" : "\(count) pages") in it, with their history. It can\u{2019}t be undone."
        }
        let actionLabel: String = switch target {
        case .page: "Delete page"
        case .folder(_, _, let count): count == 1 ? "Delete folder" : "Delete \(count) pages"
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(titleText).vesperText(.heading, theme)
            Text(bodyText)
                .vesperText(.body, theme)
                .foregroundStyle(p.secondaryText)

            if let errorMessage {
                Text(errorMessage)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.vesper())
                Spacer()
                Button(submitting ? "Deleting\u{2026}" : actionLabel) {
                    submitting = true
                    errorMessage = nil
                    Task {
                        defer { submitting = false }
                        do {
                            try await onDelete()
                            dismiss()
                        } catch {
                            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.vesper(.danger))
                .disabled(submitting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(p.background)
    }
}

struct KnowledgeBulkDeleteSheet: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let itemCount: Int
    let affectedPageCount: Int
    let onDelete: () async throws -> Void

    @State private var submitting = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(itemCount) selected items?")
                .vesperText(.heading, theme)
            Text("This deletes \(affectedPageCount) \(affectedPageCount == 1 ? "page" : "pages") and their history. It can\u{2019}t be undone.")
                .vesperText(.body, theme)
                .foregroundStyle(p.secondaryText)

            if let errorMessage {
                Text(errorMessage)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.vesper())
                Spacer()
                Button(submitting ? "Deleting\u{2026}" : "Delete \(affectedPageCount) pages") {
                    submitting = true
                    errorMessage = nil
                    Task {
                        defer { submitting = false }
                        do {
                            try await onDelete()
                            dismiss()
                        } catch {
                            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.vesper(.danger))
                .disabled(submitting)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(p.background)
    }
}

// MARK: - Obsidian Vault Import Sheet

struct KnowledgeImportSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let controller: KnowledgeShellController

    @State private var jobId: String?
    @State private var job: KnowledgeImportJob?
    @State private var selectedURL: URL?
    @State private var selectedByteCount: Int64 = 0
    @State private var folder = "Imported"
    @State private var pickerOpen = false
    @State private var dropTargeted = false
    @State private var uploadError: String?
    @State private var actionError: String?
    @State private var isUploading = false
    @State private var isActing = false
    @State private var filter: KnowledgeImportFilter = .all
    @State private var policy: KnowledgeImportPolicy = .keepBoth

    var body: some View {
        let p = theme.palette
        let step = KnowledgeShellLogic.importStep(for: job)

        VStack(spacing: 0) {
            HStack {
                Text("Import an Obsidian vault")
                    .vesperText(.heading, theme)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.vesper())
            }
            .padding(16)

            Divider().overlay(p.border)

            stepHeader(step: step)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider().overlay(p.border)

            if let job {
                jobBody(job: job)
            } else {
                uploadBody
            }
        }
        .frame(width: 720, height: 560)
        .background(p.background)
        .fileImporter(isPresented: $pickerOpen, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case .failure(let err):
                uploadError = err.localizedDescription
            case .success(let urls):
                if let url = urls.first {
                    acceptSelectedURL(url)
                }
            }
        }
        .task(id: "\(jobId ?? "")|\(job?.state ?? "")") {
            guard let id = jobId, let client = context.store.client else { return }
            if job == nil {
                job = try? await client.send(KnowledgeAPI.getImport(id: id))
            }
            while KnowledgeShellLogic.isImportPolling(job) && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if let next = try? await client.send(KnowledgeAPI.getImport(id: id)) {
                    job = next
                    if next.state == "done" || next.state == "undone" {
                        context.store.invalidate(KnowledgeAPI.invalidation)
                        controller.refreshAll(in: context)
                    }
                }
            }
        }
    }

    private func stepHeader(step: KnowledgeImportStep) -> some View {
        let p = theme.palette
        let labels = ["Upload", "Review", "Import"]
        return HStack(spacing: 12) {
            ForEach(Array(labels.enumerated()), id: \.offset) { idx, label in
                HStack(spacing: 6) {
                    let done = idx < step.rawValue
                    let current = idx == step.rawValue
                    ZStack {
                        Circle()
                            .fill(done ? theme.swiftUIColor("state-done", fallback: .green) : (current ? p.accent : p.surface))
                            .frame(width: 22, height: 22)
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(current ? theme.swiftUIColor("text-on-accent", fallback: .white) : p.tertiaryText)
                        }
                    }
                    .overlay(Circle().stroke(done || current ? .clear : p.border))

                    Text(label)
                        .font(.system(size: theme.pointSize(.body), weight: current || done ? .semibold : .regular))
                        .foregroundStyle(current || done ? p.text : p.tertiaryText)
                }
                if idx < 2 {
                    Rectangle()
                        .fill(p.border)
                        .frame(height: 1)
                }
            }
        }
    }

    private var uploadBody: some View {
        let p = theme.palette
        let tooBig = selectedByteCount > KnowledgeShellLogic.importMaxBytes
        return VStack(alignment: .leading, spacing: 16) {
            Button {
                pickerOpen = true
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 26))
                        .foregroundStyle(p.accent)
                    Text(selectedURL?.lastPathComponent ?? "Drop a zipped vault here or choose a .zip file")
                        .vesperText(.heading, theme)
                        .foregroundStyle(p.text)
                    Text(selectedURL != nil
                         ? KnowledgeShellLogic.formatByteCount(selectedByteCount)
                         : ".zip up to 2 GB \u{00B7} .obsidian settings and .trash are ignored")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(
                    dropTargeted ? theme.swiftUIColor("accent-soft", fallback: p.selected) : theme.swiftUIColor("surface-sunken", fallback: p.surface),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(dropTargeted ? p.accent : p.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                Task {
                    for provider in providers {
                        if let raw = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                           let url = URL(dataRepresentation: raw, relativeTo: nil) {
                            acceptSelectedURL(url)
                            break
                        }
                    }
                }
                return true
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import into")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                    TextField("Imported", text: $folder)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                Spacer()
                Button(isUploading ? "Uploading\u{2026}" : "Prepare dry run") {
                    startUpload()
                }
                .buttonStyle(.vesper(.primary))
                .disabled(selectedURL == nil || tooBig || isUploading)
            }

            if tooBig {
                Text("That archive is larger than 2 GB.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            } else if let uploadError {
                Text(uploadError)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            Spacer()
            Text("Nothing is written until you review the dry run and confirm.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
        }
        .padding(20)
    }

    @ViewBuilder
    private func jobBody(job: KnowledgeImportJob) -> some View {
        let p = theme.palette
        if job.state == "queued" || job.state == "scanning" {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scanning the archive\u{2026}")
                    .vesperText(.heading, theme)
                ProgressView()
                Text("Checking files and resolving wikilinks. Nothing has been written.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if job.state == "failed" {
            VStack(alignment: .leading, spacing: 14) {
                Text(job.error ?? "The import failed.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                Text("Archives with paths outside the vault or unsafe compression are refused. Nothing was written.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
                HStack {
                    Button("Choose another file") {
                        self.jobId = nil
                        self.job = nil
                    }
                    .buttonStyle(.vesper(.primary))
                    Button("Close") { dismiss() }
                        .buttonStyle(.vesper())
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if job.state == "queued_commit" || job.state == "importing" {
            let total = job.plan?.entries.count ?? 0
            VStack(alignment: .leading, spacing: 12) {
                Text("Importing\u{2026}")
                    .vesperText(.heading, theme)
                if total > 0 {
                    ProgressView(value: Double(job.filesDone), total: Double(total))
                    Text("\(job.filesDone) of \(total) files")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if job.state == "done" || job.state == "undone" {
            let summary = KnowledgeShellLogic.importReportSummary(job: job)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: job.state == "done" ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(job.state == "done" ? theme.swiftUIColor("state-done", fallback: .green) : p.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.state == "done" ? "Imported \(summary.createdOrUpdated) files" : "This import was undone")
                                .vesperText(.heading, theme)
                            Text("Into \(job.folder.isEmpty ? "top level" : job.folder)/")
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                        }
                    }

                    if job.state == "done" {
                        VStack(alignment: .leading, spacing: 4) {
                            if summary.unchanged > 0 {
                                Text("\(summary.unchanged) unchanged since last import")
                            }
                            if summary.conflicts > 0 {
                                Text("\(summary.conflicts) conflicts kept both as suggestions to review")
                            }
                            if summary.skippedOrFailed > 0 {
                                Text("\(summary.skippedOrFailed) skipped or failed")
                            }
                            if let unresolved = job.plan?.unresolved, !unresolved.isEmpty {
                                Button("View \(unresolved.count) unresolved links in Keep notes connected \u{2192}") {
                                    dismiss()
                                    context.navigate("/knowledge/connect")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(p.accent)
                            }
                        }
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                    }

                    if !summary.failures.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.failures, id: \.source) { fail in
                                Text("\(fail.source): \(fail.reason.isEmpty ? "skipped" : fail.reason)")
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                            }
                        }
                        .padding(10)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let actionError {
                        Text(actionError)
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }

                    HStack(spacing: 10) {
                        Button("Done") { dismiss() }
                            .buttonStyle(.vesper(.primary))
                        if job.state == "done" {
                            Button(isActing ? "Undoing\u{2026}" : "Undo this import") {
                                undoJob(id: job.id)
                            }
                            .buttonStyle(.vesper())
                            .disabled(isActing)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            previewBody(job: job)
        }
    }

    private func previewBody(job: KnowledgeImportJob) -> some View {
        let p = theme.palette
        let plan = job.plan
        let counts = KnowledgeShellLogic.importFilterCounts(plan: plan)
        let shown = KnowledgeShellLogic.filteredImportEntries(plan: plan, filter: filter)

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Dry run \u{00B7} nothing has been written yet")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)

                    HStack(spacing: 8) {
                        metricBox(value: plan?.notes ?? 0, label: "notes")
                        metricBox(value: plan?.attachments ?? 0, label: "attachments")
                        metricBox(value: plan?.tags.count ?? 0, label: "tags")
                        metricBox(value: plan?.resolved ?? 0, label: "resolved")
                        metricBox(value: plan?.unresolved.count ?? 0, label: "unresolved")
                    }

                    FlowLayout(spacing: 6) {
                        ForEach(KnowledgeImportFilter.allCases, id: \.self) { f in
                            Button {
                                filter = f
                            } label: {
                                Text("\(f.label) (\(counts[f] ?? 0))")
                                    .font(.system(size: theme.pointSize(.small), weight: filter == f ? .semibold : .regular))
                                    .foregroundStyle(filter == f ? p.accent : p.secondaryText)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(filter == f ? theme.swiftUIColor("accent-soft", fallback: p.selected) : p.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(filter == f ? p.accent : p.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(spacing: 0) {
                        if filter == .unresolved {
                            ForEach((plan?.unresolved ?? []).prefix(200), id: \.self) { name in
                                HStack {
                                    Image(systemName: "link").foregroundStyle(p.accent)
                                    Text(name).vesperText(.small, theme)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                Divider().overlay(p.rowBorder)
                            }
                        } else {
                            ForEach(Array(shown.prefix(200).enumerated()), id: \.offset) { _, entry in
                                let info = KnowledgeShellLogic.classifyImportEntry(entry)
                                HStack(spacing: 10) {
                                    Image(systemName: info.symbol)
                                        .foregroundStyle(p.secondaryText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.source)
                                            .vesperText(.small, theme)
                                            .foregroundStyle(p.text)
                                            .lineLimit(1)
                                        if !info.note.isEmpty {
                                            Text(info.note)
                                                .font(.system(size: theme.pointSize(.micro) + 1))
                                                .foregroundStyle(p.tertiaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(entry.error != nil ? "skipped" : entry.path)
                                        .font(.system(size: theme.pointSize(.micro) + 1))
                                        .foregroundStyle(p.tertiaryText)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                Divider().overlay(p.rowBorder)
                            }
                            if shown.isEmpty {
                                Text("Nothing here.")
                                    .vesperText(.small, theme)
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(16)
                            }
                        }
                    }
                    .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("When a page already exists")
                                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                .foregroundStyle(p.secondaryText)
                            Picker("Policy", selection: $policy) {
                                Text("Skip").tag(KnowledgeImportPolicy.skip)
                                Text("Replace").tag(KnowledgeImportPolicy.replace)
                                Text("Keep both").tag(KnowledgeImportPolicy.keepBoth)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                        }
                        Spacer()
                    }
                }
                .padding(18)
            }

            Divider().overlay(p.border)
            HStack {
                if let actionError {
                    Text(actionError)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                } else {
                    Text("You can undo the whole import afterwards.")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                Button("Cancel") { cancelJob(id: job.id) }
                    .buttonStyle(.vesper())
                    .disabled(isActing)
                Button("Import \(plan?.notes ?? 0) notes") { confirmJob(id: job.id) }
                    .buttonStyle(.vesper(.primary))
                    .disabled(isActing)
            }
            .padding(14)
        }
    }

    private func metricBox(value: Int, label: String) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(p.text)
            Text(label)
                .font(.system(size: theme.pointSize(.micro) + 1))
                .foregroundStyle(p.tertiaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }

    private func acceptSelectedURL(_ url: URL) {
        uploadError = nil
        selectedURL = url
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        selectedByteCount = size
    }

    private func startUpload() {
        guard let url = selectedURL, let client = context.store.client else { return }
        isUploading = true
        uploadError = nil
        let targetFolder = KnowledgeShellLogic.normalizeImportFolder(folder)

        Task {
            defer { isUploading = false }
            do {
                let data: Data = try {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url)
                }()
                let created = try await client.send(KnowledgeAPI.uploadVault(zipData: data, folder: targetFolder), timeout: 120)
                jobId = created.id
                job = created
            } catch {
                uploadError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func confirmJob(id: String) {
        isActing = true
        actionError = nil
        Task {
            defer { isActing = false }
            do {
                job = try await context.store.mutate(
                    KnowledgeAPI.confirmImport(id: id, policy: policy),
                    invalidating: KnowledgeAPI.invalidation
                )
            } catch {
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func cancelJob(id: String) {
        isActing = true
        actionError = nil
        Task {
            defer { isActing = false }
            do {
                _ = try await context.store.mutate(
                    KnowledgeAPI.cancelImport(id: id),
                    invalidating: KnowledgeAPI.invalidation
                )
                dismiss()
            } catch {
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func undoJob(id: String) {
        isActing = true
        actionError = nil
        Task {
            defer { isActing = false }
            do {
                job = try await context.store.mutate(
                    KnowledgeAPI.undoImport(id: id),
                    invalidating: KnowledgeAPI.invalidation
                )
                controller.refreshAll(in: context)
            } catch {
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
