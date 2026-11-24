import AppKit
import Foundation
import Observation
import VesperCore

// MARK: - Row, Section & Preview Models

enum PaletteRowTone: Equatable {
    case neutral
    case human
    case run
    case accent
    case purple
}

struct PaletteAttachRef: Equatable {
    var kind: String
    var idOrKey: String
    var label: String
    var project: String?
}

struct PaletteCommandPreview: Equatable {
    var category: String
    var title: String
    var description: String
    var shortcut: String?
    var contextLabel: String?
    var contextValue: String?
}

enum PalettePreview: Equatable {
    case inbox(API.InboxItem)
    case ticket(key: String, title: String)
    case page(id: String, path: String, title: String, isKnowledge: Bool, row: KnowledgePageRow?)
    case chat(CommandPaletteChatMatch)
    case message(chat: CommandPaletteChatMatch, message: CommandPaletteMessageMatch)
    case command(PaletteCommandPreview)
    case item(label: String, title: String, detail: String?, updatedAt: String?)
}

struct PalettePreviewAction: Identifiable {
    let id: String
    let label: String
    let keys: String
    var tone: Tone = .secondary
    let run: () -> Void

    enum Tone {
        case primary
        case approve
        case danger
        case secondary
    }
}

struct PaletteRow: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var subtitleSnippet: [CommandPaletteTextPart]?
    var meta: String?
    var metaTone: String?
    var shortcut: String?
    var sfSymbol: String
    var tone: PaletteRowTone = .neutral
    var href: String?
    var recent: CommandPaletteLink?
    var score: Double = 0
    var highlightTitle: Bool = false
    var type: CommandPaletteType?
    var preview: PalettePreview?
    var attach: PaletteAttachRef?
    var chat: CommandPaletteChatMatch?
    var message: CommandPaletteMessageMatch?
    var moreOf: CommandPaletteType?
    var facet: String?
    var customAppSlug: String?
    var isChildMessage: Bool { message != nil }
    var perform: (() -> Void)?
}

struct PaletteSection: Identifiable {
    let id: String
    var label: String?
    var count: Int?
    var tone: PaletteRowTone = .neutral
    var rows: [PaletteRow]
}

// MARK: - Model

/// View model for the native SwiftUI Command Palette (`⌘K` / `⇧⌘K`).
@MainActor
@Observable
final class CommandPaletteModel {
    enum Mode: Equatable {
        case root
        case commands
        case projects
    }

    // Callbacks wired by CommandPaletteController
    @ObservationIgnored var onClose: ((_ restoreFocus: Bool) -> Void)?
    @ObservationIgnored var onNavigate: ((_ path: String, _ newTab: Bool) -> Void)?
    @ObservationIgnored var onOpenSettings: ((_ destination: SettingsDestination?) -> Void)?
    @ObservationIgnored var onShowShortcuts: (() -> Void)?
    @ObservationIgnored var onNewWindow: (() -> Void)?
    @ObservationIgnored var onOpenCustomAppWindow: ((_ slug: String) -> Void)?
    @ObservationIgnored var onToggleSidebar: (() -> Void)?
    @ObservationIgnored var onToggleInspector: (() -> Void)?
    @ObservationIgnored var onToast: ((_ title: String, _ tone: ToastTone) -> Void)?
    @ObservationIgnored var storeProvider: (() -> QueryStore?)?
    @ObservationIgnored var clientProvider: (() -> APIClient?)?

    // Theme & focus trigger
    var theme: ThemeTokens = ThemeTokens(mode: .dark)
    var focusTick: Int = 0

    // Interactive state
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            handleQueryEdited()
        }
    }
    var mode: Mode = .root
    var scope: CommandPaletteScopeTarget?
    var chip: CommandPaletteType?
    var facet: String?
    var knowledgeKind: KnowledgePageKind?
    var includeAgent: Bool = false
    var scopeToProject: Bool = false
    var expandedChatId: String?
    var moreMenuOpen: Bool = false
    var activeIndex: Int = 0
    var actionError: String?

    // Route & remembered project context
    var hostPath: String = "/"
    var hostSearch: String = ""
    var routeProject: String?
    var rememberedProject: String?

    // Search & Knowledge results
    var isSearching: Bool = false
    var searchError: String?
    var allSearchResponse: API.SearchResponse?
    var singleTypeSearchResponse: API.SearchResponse?
    var knowledgePages: [KnowledgePageRow] = []
    var knowledgeError: String?

    // Persisted recents
    var recent: [CommandPaletteLink] = []

    // Internal debouncing & request tracking
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var lastRequestedQuery: String = ""
    @ObservationIgnored private var lastRequestedKey: String = ""
    @ObservationIgnored private var previewLoadedKeys: Set<String> = []

    private static let recentDefaultsKey = "VesperNativeCommandPaletteRecent"
    private static let rememberedProjectKey = "VesperNativeCommandPaletteProject"
    private static let includeAgentKey = "VesperNativeCommandPaletteIncludeAgent"

    init() {
        self.recent = CommandPaletteLogic.parseRecent(data: UserDefaults.standard.data(forKey: Self.recentDefaultsKey))
        self.rememberedProject = UserDefaults.standard.string(forKey: Self.rememberedProjectKey)
        self.includeAgent = UserDefaults.standard.bool(forKey: Self.includeAgentKey)
    }

    // MARK: - Lifecycle

    func open(request: CommandPaletteRequest, theme: ThemeTokens) {
        self.theme = theme
        self.hostPath = request.path ?? "/"
        self.hostSearch = request.search ?? ""
        self.routeProject = CommandPaletteLogic.projectFromRoute(path: hostPath, search: hostSearch)
        self.scope = CommandPaletteLogic.resolveScope(request: request)
        if let inc = request.includeAgent {
            self.includeAgent = inc
        }
        self.mode = .root
        self.chip = nil
        self.facet = nil
        self.knowledgeKind = nil
        self.expandedChatId = nil
        self.moreMenuOpen = false
        self.activeIndex = 0
        self.actionError = nil
        self.searchError = nil
        self.knowledgeError = nil
        self.allSearchResponse = nil
        self.singleTypeSearchResponse = nil
        self.scopeToProject = false
        self.previewLoadedKeys.removeAll()
        self.recent = CommandPaletteLogic.parseRecent(data: UserDefaults.standard.data(forKey: Self.recentDefaultsKey))

        let initialQuery = request.query ?? ""
        if initialQuery.hasPrefix(">") && scope == nil {
            self.mode = .commands
            self.query = String(initialQuery.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            self.query = initialQuery
        }

        prefetchSupportingData()
        scheduleSearch(immediate: true)
        focusTick &+= 1
    }

    func close(restoreFocus: Bool = true) {
        searchTask?.cancel()
        searchTask = nil
        moreMenuOpen = false
        onClose?(restoreFocus)
    }

    func updateTheme(_ next: ThemeTokens) {
        self.theme = next
    }

    // MARK: - Derived State

    var isKnowledgeMode: Bool {
        if case .knowledge = scope { return true }
        return false
    }

    var scopedType: CommandPaletteType? {
        if case .type(let t, _) = scope { return t }
        return nil
    }

    var isCommandsMode: Bool { mode == .commands }
    var isProjectsMode: Bool { mode == .projects }

    var filters: CommandPaletteFilters {
        guard mode == .root && !isKnowledgeMode else { return CommandPaletteFilters(text: query.trimmingCharacters(in: .whitespaces)) }
        return CommandPaletteLogic.parseFilters(query)
    }

    var shownTypes: [CommandPaletteType]? {
        if let scopedType { return [scopedType] }
        let typed = filters.types
        if !typed.isEmpty { return typed }
        if let chip { return [chip] }
        return nil
    }

    var oneType: CommandPaletteType? {
        guard let shownTypes, shownTypes.count == 1 else { return nil }
        return shownTypes[0]
    }

    var searchText: String {
        guard mode == .root && !isKnowledgeMode else { return "" }
        return filters.text
    }

    var highlightQuery: String {
        if isKnowledgeMode {
            return CommandPaletteLogic.parseKnowledgeQuery(query).text
        }
        return mode == .root ? filters.text : query.trimmingCharacters(in: .whitespaces)
    }

    var activeProject: String? {
        if let routeProject, !routeProject.isEmpty { return routeProject }
        if let rememberedProject, !rememberedProject.isEmpty { return rememberedProject }
        return projects.first?.key
    }

    var scopedProjectFilter: String? {
        scopeToProject ? activeProject : nil
    }

    var projects: [API.Project] {
        (store?.entry(API.getBootstrap()).data?.projects ?? []).filter { !$0.archived }
    }

    var personas: [API.Persona] {
        store?.entry(API.listPersonas()).data?.personas ?? []
    }

    var defaultPersona: API.Persona? {
        personas.first(where: \.isDefault) ?? personas.first
    }

    var customApps: [API.CustomAppSummary] {
        store?.entry(API.listCustomApps()).data?.apps ?? []
    }

    var devEnabled: Bool {
        store?.entry(API.getDevWorkspace()).data?.enabled ?? false
    }

    var pageContext: CommandPalettePageContext? {
        CommandPaletteLogic.pageContext(path: hostPath)
    }

    var currentTicket: API.Ticket? {
        guard case .ticket(let key) = pageContext else { return nil }
        return store?.entry(API.getTicket(key: key)).data
    }

    var currentKnowledgePage: KnowledgePage? {
        guard case .knowledge(let id) = pageContext else { return nil }
        return store?.entry(KnowledgeAPI.getPage(id: id)).data
    }

    var currentWikiPage: API.Artifact? {
        guard case .wiki(let path) = pageContext else { return nil }
        return store?.entry(API.getWikiPage(path: path)).data
    }

    var currentCustomApp: API.CustomAppDetail? {
        guard case .customApp(let slug) = pageContext else { return nil }
        return store?.entry(API.getCustomApp(slug: slug)).data
    }

    var counts: [CommandPaletteType: Int] {
        var out = CommandPaletteLogic.typeCounts(allSearchResponse?.counts)
        let appCount = matchingApps.count
        if appCount > 0 { out[.app] = appCount }
        return out
    }

    var totalSearchCount: Int {
        counts.values.reduce(0, +)
    }

    var moreTypesWithResults: [CommandPaletteType] {
        CommandPaletteType.moreTypes.filter { (counts[$0] ?? 0) > 0 }
    }

    var moreTypesWithoutResults: [CommandPaletteType] {
        CommandPaletteType.moreTypes.filter { (counts[$0] ?? 0) == 0 }
    }

    var activeMoreType: CommandPaletteType? {
        guard let oneType, CommandPaletteType.moreTypes.contains(oneType) else { return nil }
        return oneType
    }

    var inputPlaceholder: String {
        switch mode {
        case .projects:
            return "Switch to space…"
        case .commands:
            return "Type a command…"
        case .root:
            if isKnowledgeMode { return "Search Knowledge pages, #tags…" }
            if let scopedType { return "Search \(scopedType.noun)…" }
            return "Search everything, or type @ people  # tickets  > commands"
        }
    }

    // MARK: - Facets

    var activeFacets: [CommandPaletteFacet] {
        if isKnowledgeMode {
            let values = knowledgePages.map { CommandPaletteLogic.knowledgeFolder($0.path) }
            return CommandPaletteLogic.facets(values)
        }
        guard mode == .root, !searchText.isEmpty, let oneType else { return [] }
        let rows = searchRowsByType[oneType] ?? []
        return CommandPaletteLogic.facets(rows.map(\.facet))
    }

    var showFacets: Bool {
        if isKnowledgeMode {
            let parsed = CommandPaletteLogic.parseKnowledgeQuery(query)
            return activeFacets.count > 1 || ((!parsed.text.isEmpty || !parsed.tag.isEmpty) && !activeFacets.isEmpty)
        }
        return mode == .root && !searchText.isEmpty && oneType != nil && !activeFacets.isEmpty
    }

    var facetAnyLabel: String {
        if isKnowledgeMode || oneType == .page { return "Any folder" }
        if oneType == .ticket || oneType == .run { return "Any status" }
        if oneType == .chat { return "Anyone" }
        return "All"
    }

    // MARK: - Sections & Rows

    var sections: [PaletteSection] {
        switch mode {
        case .projects:
            return buildProjectSections()
        case .commands:
            return buildCommandSections(query: query.trimmingCharacters(in: .whitespaces))
        case .root:
            if isKnowledgeMode {
                return buildKnowledgeSections()
            }
            if searchText.isEmpty && oneType == nil && filters.status == nil && scopedType == nil {
                return buildIdleSections()
            }
            return buildSearchSections()
        }
    }

    var flatRows: [PaletteRow] {
        sections.flatMap(\.rows)
    }

    var clampedActiveIndex: Int {
        let count = flatRows.count
        guard count > 0 else { return 0 }
        return min(max(activeIndex, 0), count - 1)
    }

    var selectedRow: PaletteRow? {
        let rows = flatRows
        guard !rows.isEmpty else { return nil }
        return rows[clampedActiveIndex]
    }

    // MARK: - Store Access

    var store: QueryStore? { storeProvider?() }

    private func prefetchSupportingData() {
        guard let store else { return }
        store.load(API.getBootstrap())
        store.load(API.listPersonas())
        store.load(API.listCustomApps())
        store.load(API.getDevWorkspace())
        store.load(API.listInbox())
        store.load(API.listRuns(state: .live))
        store.load(API.listChats(archived: false))

        switch pageContext {
        case .ticket(let key):
            store.load(API.getTicket(key: key))
        case .knowledge(let id):
            store.load(KnowledgeAPI.getPage(id: id))
        case .wiki(let path):
            store.load(API.getWikiPage(path: path))
        case .customApp(let slug):
            store.load(API.getCustomApp(slug: slug))
        case .artifact, .none:
            break
        }
    }

    func ensurePreviewLoaded(for row: PaletteRow?) {
        guard let store, let preview = row?.preview else { return }
        switch preview {
        case .ticket(let key, _):
            guard !key.isEmpty else { return }
            let token = "ticket:\(key)"
            if previewLoadedKeys.insert(token).inserted {
                store.load(API.getTicket(key: key))
            }
        case .page(let id, let path, _, let isKnowledge, _):
            if isKnowledge, !id.isEmpty {
                let token = "kpage:\(id)"
                if previewLoadedKeys.insert(token).inserted {
                    store.load(KnowledgeAPI.getPage(id: id))
                }
            } else if !path.isEmpty {
                let token = "wiki:\(path)"
                if previewLoadedKeys.insert(token).inserted {
                    store.load(API.getWikiPage(path: path))
                }
            }
            if !id.isEmpty {
                let blToken = "backlinks:\(id)"
                if previewLoadedKeys.insert(blToken).inserted {
                    store.load(API.getBacklinks(kind: .artifact, id: id))
                }
            }
        case .chat(let chat):
            let token = "chat:\(chat.id)"
            if previewLoadedKeys.insert(token).inserted {
                store.load(API.listChatMessages(id: chat.id, limit: 8))
            }
        case .message(let chat, _):
            let token = "chat:\(chat.id)"
            if previewLoadedKeys.insert(token).inserted {
                store.load(API.listChatMessages(id: chat.id, limit: 20))
            }
        case .inbox, .command, .item:
            break
        }
    }

    // MARK: - Query Editing & Debounced Search

    private func handleQueryEdited() {
        activeIndex = 0
        expandedChatId = nil
        actionError = nil

        // Leading ">" in global root mode smoothly converts into the inline Commands pill.
        if mode == .root && scope == nil && query.hasPrefix(">") {
            mode = .commands
            chip = nil
            facet = nil
            moreMenuOpen = false
            query = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            return
        }

        scheduleSearch(immediate: false)
    }

    func scheduleSearch(immediate: Bool) {
        searchTask?.cancel()
        searchTask = nil

        if isKnowledgeMode {
            let parsed = CommandPaletteLogic.parseKnowledgeQuery(query)
            let reqKey = "k|\(parsed.text)|\(parsed.tag)|\(knowledgeKind?.rawValue ?? "")|\(includeAgent)"
            if reqKey == lastRequestedKey && !knowledgePages.isEmpty && !immediate { return }
            isSearching = true
            knowledgeError = nil
            searchTask = Task { @MainActor [weak self] in
                if !immediate {
                    try? await Task.sleep(for: .milliseconds(140))
                }
                guard let self, !Task.isCancelled else { return }
                await self.runKnowledgeQuery(text: parsed.text, tag: parsed.tag, key: reqKey)
            }
            return
        }

        guard mode == .root else {
            isSearching = false
            return
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            isSearching = false
            searchError = nil
            allSearchResponse = nil
            singleTypeSearchResponse = nil
            lastRequestedQuery = ""
            lastRequestedKey = ""
            return
        }

        let kind = oneType?.singleSearchType
        let proj = scopedProjectFilter
        let reqKey = "s|\(q)|\(proj ?? "")|\(kind?.rawValue ?? "")"
        isSearching = true
        searchError = nil
        searchTask = Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard let self, !Task.isCancelled else { return }
            await self.runGlobalSearch(query: q, project: proj, kind: kind, key: reqKey)
        }
    }

    private func runGlobalSearch(query q: String, project: String?, kind: API.SearchType?, key: String) async {
        guard let client = clientProvider?() else {
            isSearching = false
            return
        }
        do {
            async let allReq = client.send(API.search(q: q, project: project))
            if let kind {
                async let oneReq = client.send(API.search(q: q, project: project, kind: kind))
                let (allRes, oneRes) = try await (allReq, oneReq)
                guard !Task.isCancelled else { return }
                allSearchResponse = allRes
                singleTypeSearchResponse = oneRes
            } else {
                let allRes = try await allReq
                guard !Task.isCancelled else { return }
                allSearchResponse = allRes
                singleTypeSearchResponse = nil
            }
            lastRequestedQuery = q
            lastRequestedKey = key
            isSearching = false
            ensurePreviewLoaded(for: selectedRow)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            searchError = "Search failed. Try again."
            isSearching = false
        }
    }

    private func runKnowledgeQuery(text: String, tag: String, key: String) async {
        guard let client = clientProvider?() else {
            isSearching = false
            return
        }
        do {
            let body = KnowledgePageQuery(
                text: text.isEmpty ? nil : text,
                tag: tag.isEmpty ? nil : tag,
                includeAgent: includeAgent ? true : nil,
                kind: knowledgeKind,
                limit: 30
            )
            let table = try await client.send(KnowledgeAPI.queryPages(body))
            guard !Task.isCancelled else { return }
            knowledgePages = table.rows
            lastRequestedKey = key
            isSearching = false
            ensurePreviewLoaded(for: selectedRow)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            knowledgeError = "Couldn’t search Knowledge pages."
            isSearching = false
        }
    }

    // MARK: - Filter & Mode Controls

    func pickType(_ next: CommandPaletteType?) {
        if mode != .root { mode = .root }
        let cleaned = CommandPaletteLogic.stripTypeFilters(from: query)
        if cleaned != query { query = cleaned }
        chip = next
        facet = nil
        expandedChatId = nil
        moreMenuOpen = false
        activeIndex = 0
        scheduleSearch(immediate: true)
        focusTick &+= 1
    }

    func pickKnowledgeKind(_ next: KnowledgePageKind?) {
        knowledgeKind = next
        facet = nil
        activeIndex = 0
        scheduleSearch(immediate: true)
        focusTick &+= 1
    }

    func toggleIncludeAgent() {
        includeAgent.toggle()
        UserDefaults.standard.set(includeAgent, forKey: Self.includeAgentKey)
        activeIndex = 0
        scheduleSearch(immediate: true)
        focusTick &+= 1
    }

    func toggleSpaceScope() {
        scopeToProject.toggle()
        activeIndex = 0
        scheduleSearch(immediate: true)
        focusTick &+= 1
    }

    func switchToGlobal() {
        scope = nil
        mode = .root
        chip = nil
        facet = nil
        knowledgeKind = nil
        activeIndex = 0
        scheduleSearch(immediate: true)
        focusTick &+= 1
    }

    func exitSubmode() {
        if mode != .root {
            mode = .root
            query = ""
            activeIndex = 0
            focusTick &+= 1
        } else if scope != nil {
            switchToGlobal()
        }
    }

    func removeFilterToken(_ token: String) {
        query = CommandPaletteLogic.removeToken(query, token: token)
        activeIndex = 0
        focusTick &+= 1
    }

    func pickFacet(_ next: String?) {
        facet = next
        activeIndex = 0
        focusTick &+= 1
    }

    // MARK: - Keyboard Navigation

    func moveUp() {
        let count = flatRows.count
        guard count > 0 else { return }
        activeIndex = (clampedActiveIndex - 1 + count) % count
        ensurePreviewLoaded(for: selectedRow)
    }

    func moveDown() {
        let count = flatRows.count
        guard count > 0 else { return }
        activeIndex = (clampedActiveIndex + 1) % count
        ensurePreviewLoaded(for: selectedRow)
    }

    func moveHome() {
        guard !flatRows.isEmpty else { return }
        activeIndex = 0
        ensurePreviewLoaded(for: selectedRow)
    }

    func moveEnd() {
        guard !flatRows.isEmpty else { return }
        activeIndex = flatRows.count - 1
        ensurePreviewLoaded(for: selectedRow)
    }

    func stepChip(back: Bool) {
        if isKnowledgeMode {
            pickKnowledgeKind(CommandPaletteLogic.stepKnowledgeKind(knowledgeKind, back: back))
        } else if mode == .root && scopedType == nil {
            pickType(CommandPaletteLogic.stepChip(oneType, back: back))
        }
    }

    func expandSelectedChat() -> Bool {
        guard let row = selectedRow, let chat = row.chat, !row.isChildMessage, !chat.messages.isEmpty else {
            return false
        }
        if expandedChatId != chat.id {
            expandedChatId = chat.id
            return true
        }
        return false
    }

    func collapseSelectedChat() -> Bool {
        guard let row = selectedRow, let chat = row.chat, expandedChatId == chat.id else {
            return false
        }
        let parentId = "chat-\(chat.id)"
        expandedChatId = nil
        if let idx = flatRows.firstIndex(where: { $0.id == parentId }) {
            activeIndex = idx
        }
        return true
    }

    func handleBackspaceOnEmpty() -> Bool {
        guard query.isEmpty else { return false }
        if mode != .root {
            mode = .root
            activeIndex = 0
            return true
        }
        if scope != nil {
            switchToGlobal()
            return true
        }
        if chip != nil {
            pickType(nil)
            return true
        }
        return false
    }

    func handleEscape() {
        if moreMenuOpen {
            moreMenuOpen = false
            return
        }
        close(restoreFocus: true)
    }

    func confirm(newTab: Bool = false, attach: Bool = false, createKnowledge: Bool = false) {
        if createKnowledge && isKnowledgeMode {
            let parsed = CommandPaletteLogic.parseKnowledgeQuery(query)
            let pageTitle = parsed.text.isEmpty ? "Untitled" : parsed.text
            createKnowledgePage(title: pageTitle, tag: parsed.tag)
            return
        }
        guard let row = selectedRow else { return }
        if attach {
            if let attachRef = row.attach {
                attachToChat(attachRef, recent: row.recent)
                return
            }
            if let slug = row.customAppSlug {
                openCustomAppStandalone(slug: slug, recent: row.recent)
                return
            }
        }
        activate(row, newTab: newTab)
    }

    func activate(_ row: PaletteRow, newTab: Bool = false) {
        if let moreType = row.moreOf {
            pickType(moreType)
            return
        }
        if let recentItem = row.recent {
            remember(recentItem)
        }
        if newTab, let href = row.href {
            close(restoreFocus: false)
            onNavigate?(href, true)
            return
        }
        if let perform = row.perform {
            perform()
            return
        }
        if let href = row.href {
            close(restoreFocus: false)
            onNavigate?(href, false)
        }
    }

    func approveSelected() -> Bool {
        guard case .inbox(let item) = selectedRow?.preview, item.kind == .approval else { return false }
        decideApproval(item: item, decision: .approve)
        return true
    }

    func denySelected() -> Bool {
        guard case .inbox(let item) = selectedRow?.preview, item.kind == .approval else { return false }
        decideApproval(item: item, decision: .deny)
        return true
    }

    // MARK: - Preview Actions

    func previewActions(for row: PaletteRow?) -> [PalettePreviewAction] {
        guard let row else { return [] }
        if case .inbox(let item) = row.preview, item.kind == .approval {
            return [
                PalettePreviewAction(id: "approve", label: "Approve", keys: "⌥A", tone: .approve) { [weak self] in
                    self?.decideApproval(item: item, decision: .approve)
                },
                PalettePreviewAction(id: "deny", label: "Deny", keys: "⌥D", tone: .danger) { [weak self] in
                    self?.decideApproval(item: item, decision: .deny)
                },
                PalettePreviewAction(id: "open", label: "Open", keys: "↵", tone: .secondary) { [weak self] in
                    self?.activate(row, newTab: false)
                },
            ]
        }

        var list: [PalettePreviewAction] = []
        let primaryLabel: String
        let primaryTone: PalettePreviewAction.Tone
        switch row.preview {
        case .inbox(let item):
            primaryLabel = item.kind == .dispatch ? "Review dispatch" : "Open item"
            primaryTone = item.needsYou ? .approve : .primary
        case .ticket:
            primaryLabel = "Open ticket"
            primaryTone = .primary
        case .page:
            primaryLabel = "Open page"
            primaryTone = .primary
        case .chat:
            primaryLabel = "Open chat"
            primaryTone = .primary
        case .message:
            primaryLabel = "Jump to message"
            primaryTone = .primary
        case .command:
            primaryLabel = "Run command"
            primaryTone = .primary
        case .item, .none:
            primaryLabel = row.moreOf != nil ? "Show all" : "Open"
            primaryTone = .primary
        }

        list.append(PalettePreviewAction(id: "primary", label: primaryLabel, keys: "↵", tone: primaryTone) { [weak self] in
            self?.activate(row, newTab: false)
        })

        if let attach = row.attach {
            list.append(PalettePreviewAction(id: "attach", label: "Attach to chat", keys: "⌥↵", tone: .secondary) { [weak self] in
                self?.attachToChat(attach, recent: row.recent)
            })
        } else if let slug = row.customAppSlug {
            list.append(PalettePreviewAction(id: "standalone", label: "Standalone window", keys: "⌥↵", tone: .secondary) { [weak self] in
                self?.openCustomAppStandalone(slug: slug, recent: row.recent)
            })
            list.append(PalettePreviewAction(id: "new-tab", label: "New tab", keys: "⌘↵", tone: .secondary) { [weak self] in
                self?.activate(row, newTab: true)
            })
        } else if row.href != nil {
            list.append(PalettePreviewAction(id: "new-tab", label: "New tab", keys: "⌘↵", tone: .secondary) { [weak self] in
                self?.activate(row, newTab: true)
            })
        }

        return list
    }

    // MARK: - Mutations

    private func remember(_ item: CommandPaletteLink) {
        recent = CommandPaletteLogic.pushRecent(recent, item: item)
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: Self.recentDefaultsKey)
        }
    }

    private func rememberProject(_ key: String) {
        rememberedProject = key
        UserDefaults.standard.set(key, forKey: Self.rememberedProjectKey)
    }

    private func openCustomAppStandalone(slug: String, recent recentItem: CommandPaletteLink? = nil) {
        if let recentItem { remember(recentItem) }
        close(restoreFocus: false)
        onOpenCustomAppWindow?(slug)
    }

    private func attachToChat(_ attach: PaletteAttachRef, recent recentItem: CommandPaletteLink?) {
        if let recentItem { remember(recentItem) }
        guard let client = clientProvider?() else { return }
        close(restoreFocus: false)
        Task { @MainActor [weak self] in
            do {
                let chat = try await client.send(API.createChat(body: API.NewChat(project: attach.project)))
                let q = CommandPaletteLogic.attachQuery(project: nil, kind: attach.kind, idOrKey: attach.idOrKey, title: attach.label)
                self?.onNavigate?("/chat/\(chat.id)?\(q)", false)
            } catch {
                self?.onToast?("Couldn’t start a chat with that attached.", .error)
            }
        }
    }

    private func askInNewChat(prompt: String, personaId: String? = nil) {
        guard let client = clientProvider?() else { return }
        close(restoreFocus: false)
        Task { @MainActor [weak self] in
            do {
                let chat = try await client.send(API.createChat(body: API.NewChat(
                    message: API.NewChatMessage(body: prompt),
                    personaId: personaId,
                    project: self?.activeProject
                )))
                self?.onNavigate?("/chat/\(chat.id)", false)
            } catch {
                self?.onToast?("Couldn’t start the chat.", .error)
            }
        }
    }

    private func createKnowledgePage(title: String, tag: String = "") {
        guard let client = clientProvider?() else { return }
        close(restoreFocus: false)
        Task { @MainActor [weak self] in
            do {
                let props: [String: JSONValue]? = tag.isEmpty ? nil : ["tags": .array([.string(tag)])]
                let page = try await client.send(KnowledgeAPI.createPage(KnowledgePageInput(
                    title: title,
                    path: "Inbox/\(title)",
                    properties: props
                )))
                self?.onNavigate?(CommandPaletteLogic.knowledgePageHref(id: page.id), false)
            } catch {
                self?.onToast?("Couldn’t create the page.", .error)
            }
        }
    }

    private func decideApproval(item: API.InboxItem, decision: API.DecideApprovalDecision) {
        guard let client = clientProvider?() else { return }
        let approvalId = item.id.hasPrefix("approval:") ? String(item.id.dropFirst("approval:".count)) : item.id
        close(restoreFocus: true)
        Task { @MainActor [weak self] in
            do {
                _ = try await client.send(API.decideApproval(id: approvalId, decision: decision, body: nil))
                self?.store?.load(API.listInbox())
                self?.onToast?(decision == .approve ? "Approved" : "Denied", .success)
            } catch {
                self?.onToast?("Couldn’t update approval.", .error)
            }
        }
    }

    private func updateCurrentTicketStatus(_ status: API.TicketStatus) {
        guard let ticket = currentTicket, let client = clientProvider?() else { return }
        close(restoreFocus: true)
        Task { @MainActor [weak self] in
            do {
                _ = try await client.send(API.updateTicket(key: ticket.key, body: API.TicketPatch(revision: ticket.revision, status: status)))
                self?.store?.load(API.getTicket(key: ticket.key))
                self?.onToast?("\(ticket.key) → \(Self.statusLabel(status.rawValue))", .success)
            } catch {
                self?.onToast?("Couldn’t update \(ticket.key).", .error)
            }
        }
    }

    private func cancelCurrentTicketRun() {
        guard let run = currentTicket?.run, let client = clientProvider?() else { return }
        close(restoreFocus: true)
        Task { @MainActor [weak self] in
            do {
                _ = try await client.send(API.controlRun(id: run.id, action: .cancel))
                self?.store?.load(API.listRuns(state: .live))
                self?.onToast?("Canceled run", .neutral)
            } catch {
                self?.onToast?("Couldn’t cancel the run.", .error)
            }
        }
    }

    // MARK: - Section Builders

    private func buildIdleSections() -> [PaletteSection] {
        var result: [PaletteSection] = []

        // 1. Needs you (up to 3 unresolved needs_you items from inbox)
        let inboxItems = (store?.entry(API.listInbox()).data?.items ?? [])
            .filter { $0.needsYou && !$0.resolved && !$0.read }
        if !inboxItems.isEmpty {
            let rows = inboxItems.prefix(3).map { item -> PaletteRow in
                let kindText = item.kind.rawValue.replacingOccurrences(of: "_", with: " ")
                let sub = [item.agent?.name, kindText, item.ticketKey.isEmpty ? nil : item.ticketKey]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return PaletteRow(
                    id: "inbox-\(item.id)",
                    title: item.title,
                    subtitle: sub,
                    meta: APIDate.shortAgo(item.createdAt),
                    sfSymbol: item.kind == .approval ? "checkmark.shield" : "exclamationmark.triangle",
                    tone: .human,
                    href: item.href,
                    preview: .inbox(item)
                )
            }
            result.append(PaletteSection(id: "needs-you", label: "Needs you", count: inboxItems.count, tone: .human, rows: rows))
        }

        // 2. Running (live runs)
        let runs = store?.entry(API.listRuns(state: .live)).data?.runs ?? []
        if !runs.isEmpty {
            let rows = runs.prefix(3).map { run -> PaletteRow in
                let href = run.purpose == .chat && run.chatId != nil ? "/chat/\(run.chatId!)" : "/runs/\(run.id)"
                let title = run.workTitle ?? (run.ticketKey.isEmpty ? "Run \(run.id.prefix(8))" : run.ticketKey)
                let sub = [run.agent.name, run.state.rawValue.replacingOccurrences(of: "_", with: " "), run.ticketKey.isEmpty ? nil : run.ticketKey]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return PaletteRow(
                    id: "run-\(run.id)",
                    title: title,
                    subtitle: sub,
                    meta: APIDate.shortAgo(run.startedAt),
                    sfSymbol: "play.circle.fill",
                    tone: .run,
                    href: href,
                    recent: CommandPaletteLink(id: run.id, title: title, meta: "run", href: href, kind: "Runs"),
                    type: .run,
                    preview: .item(label: "Live run", title: title, detail: sub, updatedAt: run.startedAt)
                )
            }
            result.append(PaletteSection(id: "running", label: "Running", count: runs.count, rows: rows))
        }

        // 3. Continue (most recent chat)
        let chats = (store?.entry(API.listChats(archived: false)).data?.chats ?? []).filter { $0.parentChatId == nil }
        if let latest = chats.first {
            let title = latest.title.isEmpty ? "Untitled chat" : latest.title
            let personaName = latest.persona?.name ?? "Assistant"
            let href = "/chat/\(latest.id)"
            let match = CommandPaletteChatMatch(
                id: latest.id,
                title: title,
                href: href,
                persona: personaName,
                at: latest.lastMessageAt ?? latest.updatedAt,
                score: 0,
                titled: true
            )
            let row = PaletteRow(
                id: "continue-\(latest.id)",
                title: title,
                subtitle: "\(personaName) · chat",
                meta: APIDate.shortAgo(latest.lastMessageAt ?? latest.updatedAt),
                sfSymbol: "bubble.left",
                href: href,
                recent: CommandPaletteLink(id: latest.id, title: title, meta: "chat", href: href, kind: "Chats"),
                type: .chat,
                preview: .chat(match),
                chat: match
            )
            result.append(PaletteSection(id: "continue", label: "Continue", rows: [row]))
        }

        // 4. Recent visits
        if !recent.isEmpty {
            let rows = recent.prefix(6).map { item -> PaletteRow in
                let symbol = Self.symbolForKindLabel(item.kind)
                let preview: PalettePreview
                if item.href.hasPrefix("/tickets/"), let key = CommandPaletteLogic.ticketKeyFrom(String(item.href.dropFirst("/tickets/".count))) {
                    preview = .ticket(key: key, title: item.title)
                } else if item.href.hasPrefix("/knowledge/") {
                    let id = String(item.href.dropFirst("/knowledge/".count)).split(separator: "/").first.map(String.init) ?? item.id
                    preview = .page(id: id, path: item.title, title: item.title, isKnowledge: true, row: nil)
                } else {
                    preview = .item(label: item.kind, title: item.title, detail: item.meta, updatedAt: nil)
                }
                let customAppSlug: String?
                if case .customApp(let slug) = CommandPaletteLogic.pageContext(path: item.href) {
                    customAppSlug = slug
                } else {
                    customAppSlug = nil
                }
                return PaletteRow(
                    id: "recent-\(item.href)",
                    title: item.title,
                    subtitle: item.meta,
                    sfSymbol: symbol,
                    href: item.href,
                    recent: item,
                    preview: preview,
                    customAppSlug: customAppSlug
                )
            }
            result.append(PaletteSection(id: "recent", label: "Recent", rows: rows))
        }

        // 5. Fallback quick actions if completely fresh
        if result.isEmpty {
            result.append(contentsOf: buildCommandSections(query: "").prefix(1))
        }

        return result
    }

    private struct AppJump {
        var label: String
        var href: String
        var aliases: String
        var kind: String
        var sfSymbol: String
        var customAppSlug: String? = nil
    }

    private var allAppJumps: [AppJump] {
        var items: [AppJump] = [
            AppJump(label: "Chat", href: "/chat", aliases: "messages assistant", kind: "app", sfSymbol: "bubble.left"),
            AppJump(label: "Inbox", href: "/inbox", aliases: "needs you approvals", kind: "app", sfSymbol: "tray"),
            AppJump(label: "Work", href: "/work", aliases: "tickets runs epics", kind: "app", sfSymbol: "briefcase"),
            AppJump(label: "Knowledge", href: "/knowledge", aliases: "wiki notes pages", kind: "app", sfSymbol: "book"),
            AppJump(label: "Tickets", href: "/tickets", aliases: "board issues", kind: "app", sfSymbol: "checklist"),
            AppJump(label: "Runs", href: "/runs", aliases: "agents activity", kind: "app", sfSymbol: "play.circle"),
            AppJump(label: "Library", href: "/library", aliases: "files images links", kind: "app", sfSymbol: "books.vertical"),
            AppJump(label: "Learn", href: "/learn", aliases: "courses study", kind: "app", sfSymbol: "graduationcap"),
            AppJump(label: "Workflows", href: "/workflows", aliases: "automations", kind: "app", sfSymbol: "point.3.connected.trianglepath.dotted"),
            AppJump(label: "Scheduled", href: "/scheduled", aliases: "cron tasks", kind: "app", sfSymbol: "clock"),
            AppJump(label: "HTTP Client", href: "/http", aliases: "bruno api curl rest requests", kind: "tool", sfSymbol: "network"),
            AppJump(label: "Documents", href: "/knowledge?kind=document", aliases: "docs", kind: "in Knowledge", sfSymbol: "doc.text"),
            AppJump(label: "Slides", href: "/knowledge?kind=deck", aliases: "decks presentations", kind: "in Knowledge", sfSymbol: "rectangle.stack"),
            AppJump(label: "Designs", href: "/knowledge?kind=design", aliases: "mockups wireframes", kind: "in Knowledge", sfSymbol: "square.on.circle"),
        ]
        if devEnabled {
            items.append(AppJump(label: "Dev Workspace", href: "/dev", aliases: "terminal lazyvim nvim tmux", kind: "tool", sfSymbol: "terminal"))
        }
        for app in customApps {
            items.append(AppJump(
                label: app.name,
                href: "/apps/\(app.slug)",
                aliases: "\(app.slug) standalone",
                kind: "custom app",
                sfSymbol: SidebarIcons.symbolName(AppsHomeLogic.resolveIcon(app.icon)),
                customAppSlug: app.slug
            ))
        }
        return items
    }

    private var matchingApps: [AppJump] {
        guard mode == .root && !isKnowledgeMode else { return [] }
        if !searchText.isEmpty {
            return CommandPaletteLogic.appMatches(allAppJumps, searchable: { "\($0.label) \($0.aliases)" }, query: searchText)
        }
        if oneType == .app { return allAppJumps }
        return []
    }

    private var searchRowsByType: [CommandPaletteType: [PaletteRow]] {
        let response = (oneType?.singleSearchType != nil) ? (singleTypeSearchResponse ?? allSearchResponse) : allSearchResponse
        let hits = searchText.isEmpty ? [] : (response?.hits ?? [])
        var byType: [CommandPaletteType: [PaletteRow]] = [:]

        // Chats folded into one row per chat
        if shownTypes == nil || shownTypes?.contains(.chat) == true {
            let chatRows = CommandPaletteLogic.groupChats(hits).map { chatRow($0) }
            if !chatRows.isEmpty { byType[.chat] = chatRows }
        }

        for hit in hits {
            let type = CommandPaletteLogic.typeOf(hit.target)
            if type == .chat { continue }
            if let shownTypes, !shownTypes.contains(type) { continue }
            if let statusFilter = filters.status, type == .ticket,
               (hit.target.status ?? "").lowercased() != statusFilter.lowercased() {
                continue
            }
            if let row = hitRow(hit, type: type) {
                byType[type, default: []].append(row)
            }
        }

        if shownTypes == nil || shownTypes?.contains(.app) == true {
            let apps = matchingApps.map { app -> PaletteRow in
                PaletteRow(
                    id: "app-\(app.href)",
                    title: app.label,
                    subtitle: app.kind,
                    sfSymbol: app.sfSymbol,
                    href: app.href,
                    recent: CommandPaletteLink(id: app.href, title: app.label, meta: app.kind, href: app.href, kind: "Apps"),
                    score: 50,
                    highlightTitle: true,
                    type: .app,
                    preview: .item(label: app.kind.capitalized, title: app.label, detail: app.href, updatedAt: nil),
                    customAppSlug: app.customAppSlug
                )
            }
            if !apps.isEmpty { byType[.app] = apps }
        }

        return byType
    }

    private func buildSearchSections() -> [PaletteSection] {
        var result: [PaletteSection] = []

        // Direct ticket key jump
        if scopedType == nil || oneType == .ticket {
            let cleanedKeyQuery = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^#\\s*", with: "", options: .regularExpression)
            if let key = CommandPaletteLogic.ticketKeyFrom(cleanedKeyQuery, project: activeProject) {
                let row = PaletteRow(
                    id: "jump-\(key)",
                    title: "Open \(key)",
                    subtitle: "/tickets/\(key)",
                    sfSymbol: "checklist",
                    tone: .accent,
                    href: "/tickets/\(key)",
                    recent: CommandPaletteLink(id: "jump-\(key)", title: key, meta: key, href: "/tickets/\(key)", kind: "Tickets"),
                    score: 1000,
                    type: .ticket,
                    preview: .ticket(key: key, title: key),
                    attach: PaletteAttachRef(kind: "ticket", idOrKey: key, label: key, project: CommandPaletteLogic.projectOfKey(key))
                )
                result.append(PaletteSection(id: "jump", label: "Jump to", rows: [row]))
            }
        }

        // Chat with matching persona
        if (shownTypes == nil || shownTypes?.contains(.people) == true) && !searchText.isEmpty {
            let matchedPersonas = CommandPaletteLogic.personaMatches(personas, name: \.name, query: searchText)
            if !matchedPersonas.isEmpty {
                let rows = matchedPersonas.prefix(3).map { p -> PaletteRow in
                    let href = "/chat?new&persona=\(p.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? p.id)"
                    return PaletteRow(
                        id: "chat-with-\(p.id)",
                        title: "Chat with \(p.name)",
                        subtitle: "new chat",
                        sfSymbol: "bubble.left.and.text.bubble.right",
                        tone: .accent,
                        href: href,
                        highlightTitle: true,
                        type: .people,
                        preview: .command(PaletteCommandPreview(
                            category: "Persona",
                            title: "Chat with \(p.name)",
                            description: "Start a fresh conversation with \(p.name).",
                            shortcut: "↵",
                            contextLabel: "Persona",
                            contextValue: p.name
                        ))
                    )
                }
                result.append(PaletteSection(id: "start-chat", label: "Start a chat", rows: rows))
            }
        }

        let byType = searchRowsByType
        if let oneType {
            var rows = byType[oneType] ?? []
            if let facet {
                rows = rows.filter { $0.facet == facet }
            }
            let expanded = expandChatRows(rows)
            if !expanded.isEmpty {
                result.append(PaletteSection(id: "type-\(oneType.rawValue)", label: oneType.label, count: counts[oneType] ?? rows.count, rows: expanded))
            } else if searchText.isEmpty && oneType == .run {
                // Scoped to Runs with empty query shows live runs
                let runs = store?.entry(API.listRuns(state: .live)).data?.runs ?? []
                if !runs.isEmpty {
                    let runRows = runs.map { run -> PaletteRow in
                        let href = "/runs/\(run.id)"
                        let title = run.workTitle ?? (run.ticketKey.isEmpty ? "Run \(run.id.prefix(8))" : run.ticketKey)
                        return PaletteRow(
                            id: "scoped-run-\(run.id)",
                            title: title,
                            subtitle: "\(run.agent.name) · \(run.state.rawValue.replacingOccurrences(of: "_", with: " "))",
                            meta: APIDate.shortAgo(run.startedAt),
                            sfSymbol: "play.circle.fill",
                            tone: .run,
                            href: href,
                            type: .run,
                            preview: .item(label: "Run", title: title, detail: run.agent.name, updatedAt: run.startedAt)
                        )
                    }
                    result.append(PaletteSection(id: "scoped-runs", label: "Live runs", count: runRows.count, rows: runRows))
                }
            } else if searchText.isEmpty && oneType == .chat {
                let chats = (store?.entry(API.listChats(archived: false)).data?.chats ?? []).filter { $0.parentChatId == nil }
                if !chats.isEmpty {
                    let chatRows = chats.prefix(12).map { c -> PaletteRow in
                        let title = c.title.isEmpty ? "Untitled chat" : c.title
                        let personaName = c.persona?.name ?? "Assistant"
                        let href = "/chat/\(c.id)"
                        let match = CommandPaletteChatMatch(id: c.id, title: title, href: href, persona: personaName, at: c.lastMessageAt ?? c.updatedAt, score: 0, titled: true)
                        return PaletteRow(
                            id: "scoped-chat-\(c.id)",
                            title: title,
                            subtitle: "\(personaName) · chat",
                            meta: APIDate.shortAgo(c.lastMessageAt ?? c.updatedAt),
                            sfSymbol: "bubble.left",
                            href: href,
                            type: .chat,
                            preview: .chat(match),
                            chat: match
                        )
                    }
                    result.append(PaletteSection(id: "scoped-chats", label: "Recent chats", count: chatRows.count, rows: chatRows))
                }
            }
        } else if !searchText.isEmpty {
            let pairs = CommandPaletteType.allCases.compactMap { type -> (type: CommandPaletteType, items: [PaletteRow])? in
                guard let items = byType[type], !items.isEmpty else { return nil }
                return (type, items)
            }
            let ranked = CommandPaletteLogic.rankGroups(pairs, score: \.score, cap: CommandPaletteLogic.perGroupCap, counts: counts)
            for group in ranked {
                var rows = expandChatRows(group.items)
                if group.more > 0 {
                    rows.append(PaletteRow(
                        id: "more-\(group.type.rawValue)",
                        title: "+ \(group.more) more \(group.type.noun)",
                        sfSymbol: "arrow.right",
                        tone: .accent,
                        moreOf: group.type
                    ))
                }
                result.append(PaletteSection(id: "group-\(group.type.rawValue)", label: group.type.label, count: group.total, rows: rows))
            }
        }

        // Fallback actions when searching globally
        if !searchText.isEmpty && scopedType == nil {
            let trimmed = searchText
            var fallbacks: [PaletteRow] = [
                PaletteRow(
                    id: "fallback-ask",
                    title: "Ask \(defaultPersona?.name ?? "Assistant"): “\(trimmed)”",
                    subtitle: "Start a new chat with this prompt",
                    sfSymbol: "sparkles",
                    tone: .accent,
                    preview: .command(PaletteCommandPreview(
                        category: "Action",
                        title: "Ask \(defaultPersona?.name ?? "Assistant")",
                        description: "Creates a new chat with \(defaultPersona?.name ?? "Assistant") and immediately sends “\(trimmed)”.",
                        shortcut: "↵",
                        contextLabel: "Prompt",
                        contextValue: trimmed
                    )),
                    perform: { [weak self] in
                        self?.askInNewChat(prompt: trimmed, personaId: self?.defaultPersona?.id)
                    }
                ),
            ]
            if let proj = activeProject {
                let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
                let href = "/tickets?project=\(proj)&new=1&title=\(encoded)"
                fallbacks.append(PaletteRow(
                    id: "fallback-ticket",
                    title: "New ticket: “\(trimmed)”",
                    subtitle: "Create in \(proj)",
                    sfSymbol: "plus.square",
                    href: href,
                    preview: .command(PaletteCommandPreview(
                        category: "Create",
                        title: "New Ticket in \(proj)",
                        description: "Opens a new ticket draft titled “\(trimmed)” in \(proj).",
                        shortcut: "↵",
                        contextLabel: "Project",
                        contextValue: proj
                    ))
                ))
            }
            result.append(PaletteSection(id: "fallbacks", label: "Actions", rows: fallbacks))
        }

        return result
    }

    private func buildKnowledgeSections() -> [PaletteSection] {
        var result: [PaletteSection] = []
        let parsed = CommandPaletteLogic.parseKnowledgeQuery(query)

        var rows = knowledgePages.map { row -> PaletteRow in
            let title = row.title.isEmpty ? "Untitled" : row.title
            let folder = CommandPaletteLogic.knowledgeFolder(row.path)
            let kindLabel: String? = switch row.kind {
            case .deck: "Deck"
            case .design: "Design"
            case .document: nil
            }
            let audLabel: String? = switch row.audience {
            case .agent: "Agent"
            case .shared: "Shared"
            case .private: "Private"
            }
            let tags: [String] = {
                guard case .array(let vals) = row.properties["tags"] else { return [] }
                return vals.compactMap(\.stringValue).prefix(3).map { "#\($0)" }
            }()
            let sub = ([folder, kindLabel, audLabel].compactMap { $0 } + tags).joined(separator: " · ")
            let href = CommandPaletteLogic.knowledgePageHref(id: row.id)
            let symbol: String = switch row.kind {
            case .deck: "rectangle.stack"
            case .design: "square.on.circle"
            case .document: "doc.text"
            }
            return PaletteRow(
                id: "kpage-\(row.id)",
                title: title,
                subtitle: sub,
                meta: APIDate.shortAgo(row.updatedAt),
                sfSymbol: symbol,
                tone: row.kind == .design ? .purple : .neutral,
                href: href,
                recent: CommandPaletteLink(id: row.id, title: row.path.isEmpty ? title : row.path, meta: row.kind.rawValue, href: href, kind: "Pages"),
                highlightTitle: !parsed.text.isEmpty,
                type: .page,
                preview: .page(id: row.id, path: row.path, title: title, isKnowledge: true, row: row),
                attach: PaletteAttachRef(kind: "page", idOrKey: row.id, label: title, project: nil),
                facet: folder
            )
        }

        if let facet {
            rows = rows.filter { $0.facet == facet }
        }
        if !rows.isEmpty {
            result.append(PaletteSection(id: "knowledge-pages", label: nil, rows: rows))
        }

        if !parsed.text.isEmpty || !parsed.tag.isEmpty {
            let pageTitle = parsed.text.isEmpty ? "Untitled" : parsed.text
            let tagSuffix = parsed.tag.isEmpty ? "" : " tagged #\(parsed.tag)"
            let createRow = PaletteRow(
                id: "knowledge-create",
                title: "Create page “\(pageTitle)”\(tagSuffix)",
                subtitle: "New Knowledge note in Inbox",
                shortcut: "⇧↵",
                sfSymbol: "plus",
                tone: .accent,
                preview: .command(PaletteCommandPreview(
                    category: "Create",
                    title: "Create “\(pageTitle)”",
                    description: "Creates a new private Knowledge note in Inbox\(tagSuffix) and opens it immediately.",
                    shortcut: "⇧↵",
                    contextLabel: "Folder",
                    contextValue: "Inbox"
                )),
                perform: { [weak self] in
                    self?.createKnowledgePage(title: pageTitle, tag: parsed.tag)
                }
            )
            result.append(PaletteSection(id: "knowledge-create-sec", label: "Create", rows: [createRow]))
        }

        return result
    }

    private func buildCommandSections(query q: String) -> [PaletteSection] {
        let personaName = defaultPersona?.name ?? "Assistant"
        let projectLabel = activeProject ?? "default space"

        var createRows: [PaletteRow] = [
            PaletteRow(
                id: "cmd-new-chat",
                title: "New Chat with \(personaName)",
                subtitle: "Start a fresh conversation",
                shortcut: "⌘N",
                sfSymbol: "plus.bubble",
                tone: .accent,
                href: "/chat?new",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Create",
                    title: "New Chat with \(personaName)",
                    description: "Opens a new native SwiftUI chat with your active persona (\(personaName)) and focuses the composer.",
                    shortcut: "⌘N",
                    contextLabel: "Default persona",
                    contextValue: personaName
                ))
            ),
            PaletteRow(
                id: "cmd-new-page",
                title: "New Knowledge Page",
                subtitle: "Create a blank note in Knowledge",
                shortcut: "⇧⌘N",
                sfSymbol: "doc.badge.plus",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Create",
                    title: "New Knowledge Page",
                    description: "Creates a new private note in your Knowledge Inbox and opens it in the native editor.",
                    shortcut: "⇧⌘N",
                    contextLabel: "Location",
                    contextValue: "Knowledge / Inbox"
                )),
                perform: { [weak self] in
                    self?.createKnowledgePage(title: "Untitled")
                }
            ),
            PaletteRow(
                id: "cmd-new-ticket",
                title: "New Ticket\(activeProject.map { " in \($0)" } ?? "")",
                subtitle: "Open ticket creation form",
                shortcut: "C",
                sfSymbol: "plus.square",
                href: activeProject.map { "/tickets?project=\($0)&new=1" } ?? "/tickets?new=1",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Create",
                    title: "New Ticket",
                    description: "Opens the ticket creation view in \(projectLabel).",
                    shortcut: "C",
                    contextLabel: "Project",
                    contextValue: projectLabel
                ))
            ),
        ]

        // Contextual page commands
        var contextRows: [PaletteRow] = []
        if let ticket = currentTicket {
            if let run = ticket.run {
                contextRows.append(PaletteRow(
                    id: "cmd-go-run",
                    title: "Go to run for \(ticket.key)",
                    subtitle: "\(run.agent.name) · \(run.state.rawValue.replacingOccurrences(of: "_", with: " "))",
                    sfSymbol: "play.circle",
                    tone: .run,
                    href: "/runs/\(run.id)",
                    highlightTitle: true,
                    preview: .command(PaletteCommandPreview(
                        category: "Current Ticket",
                        title: "Go to run for \(ticket.key)",
                        description: "Jumps directly to the active or most recent run for \(ticket.key).",
                        shortcut: "↵",
                        contextLabel: "Run state",
                        contextValue: run.state.rawValue.replacingOccurrences(of: "_", with: " ")
                    ))
                ))
                if [.queued, .starting, .running, .paused].contains(run.state) {
                    contextRows.append(PaletteRow(
                        id: "cmd-cancel-run",
                        title: "Cancel run for \(ticket.key)",
                        subtitle: "Stop \(run.agent.name)’s active run",
                        sfSymbol: "stop.circle",
                        tone: .human,
                        highlightTitle: true,
                        preview: .command(PaletteCommandPreview(
                            category: "Current Ticket",
                            title: "Cancel run for \(ticket.key)",
                            description: "Sends a cancel request to \(run.agent.name)’s active run.",
                            shortcut: "↵",
                            contextLabel: "Ticket",
                            contextValue: ticket.key
                        )),
                        perform: { [weak self] in self?.cancelCurrentTicketRun() }
                    ))
                }
            }
            let attach = PaletteAttachRef(kind: "ticket", idOrKey: ticket.key, label: ticket.key, project: ticket.project.key)
            contextRows.append(PaletteRow(
                id: "cmd-attach-here",
                title: "New chat with \(ticket.key) attached",
                subtitle: "Start a chat referencing this ticket",
                sfSymbol: "paperclip",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Current Ticket",
                    title: "New chat with \(ticket.key) attached",
                    description: "Starts a fresh conversation with \(ticket.key) attached as context.",
                    shortcut: "↵",
                    contextLabel: "Context",
                    contextValue: ticket.key
                )),
                perform: { [weak self] in self?.attachToChat(attach, recent: nil) }
            ))
            for status in [API.TicketStatus.backlog, .todo, .inProgress, .inReview, .done] where status != ticket.status {
                let label = Self.statusLabel(status.rawValue)
                contextRows.append(PaletteRow(
                    id: "cmd-status-\(status.rawValue)",
                    title: "Set status: \(label)",
                    subtitle: ticket.key,
                    sfSymbol: "arrow.triangle.2.circlepath",
                    highlightTitle: true,
                    preview: .command(PaletteCommandPreview(
                        category: "Current Ticket",
                        title: "Set \(ticket.key) to \(label)",
                        description: "Updates \(ticket.key) status from \(Self.statusLabel(ticket.status.rawValue)) to \(label).",
                        shortcut: "↵",
                        contextLabel: "Ticket",
                        contextValue: ticket.key
                    )),
                    perform: { [weak self] in self?.updateCurrentTicketStatus(status) }
                ))
            }
        } else if let page = currentKnowledgePage {
            let attach = PaletteAttachRef(kind: "page", idOrKey: page.id, label: page.title.isEmpty ? "Untitled" : page.title, project: nil)
            contextRows.append(PaletteRow(
                id: "cmd-attach-page",
                title: "New chat with “\(attach.label)” attached",
                subtitle: "Start a chat referencing this page",
                sfSymbol: "paperclip",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Current Page",
                    title: "Attach “\(attach.label)” to chat",
                    description: "Creates a new chat with this Knowledge page attached as context.",
                    shortcut: "↵",
                    contextLabel: "Page",
                    contextValue: page.path ?? attach.label
                )),
                perform: { [weak self] in self?.attachToChat(attach, recent: nil) }
            ))
        } else if case .customApp(let slug) = pageContext {
            let appName = currentCustomApp?.name
                ?? customApps.first(where: { $0.slug == slug })?.name
                ?? slug
            contextRows.append(PaletteRow(
                id: "cmd-standalone-current-\(slug)",
                title: "Open \(appName) in Standalone Window",
                subtitle: "Chromeless window for /apps/\(slug)",
                sfSymbol: "macwindow.on.rectangle",
                tone: .accent,
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Current App",
                    title: "Open \(appName) in Standalone Window",
                    description: "Opens \(appName) in its own lightweight macOS window with Reload, Permissions, and Open in Vesper controls.",
                    shortcut: "↵",
                    contextLabel: "App",
                    contextValue: "/apps/\(slug)"
                )),
                perform: { [weak self] in self?.openCustomAppStandalone(slug: slug) }
            ))
        }

        var workspaceRows: [PaletteRow] = [
            PaletteRow(
                id: "cmd-switch-space",
                title: "Switch Space…",
                subtitle: "Currently: \(projectLabel)",
                shortcut: "⌘P",
                sfSymbol: "folder",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Workspace",
                    title: "Switch Space",
                    description: "Switch the active project/space filter for tickets, epics, and quick actions.",
                    shortcut: "⌘P",
                    contextLabel: "Current",
                    contextValue: projectLabel
                )),
                perform: { [weak self] in
                    self?.mode = .projects
                    self?.query = ""
                    self?.activeIndex = 0
                    self?.focusTick &+= 1
                }
            ),
            PaletteRow(
                id: "cmd-new-window",
                title: "Open New Window",
                subtitle: "Create an independent Vesper window",
                shortcut: "⌥⌘N",
                sfSymbol: "macwindow.badge.plus",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Window",
                    title: "Open New Window",
                    description: "Opens another native Vesper window side-by-side.",
                    shortcut: "⌥⌘N",
                    contextLabel: "Scope",
                    contextValue: "Global"
                )),
                perform: { [weak self] in
                    self?.close(restoreFocus: false)
                    self?.onNewWindow?()
                }
            ),
            PaletteRow(
                id: "cmd-toggle-sidebar",
                title: "Toggle Sidebar",
                subtitle: "Show or hide the left navigation sidebar",
                shortcut: "⌥⌘S",
                sfSymbol: "sidebar.left",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Window",
                    title: "Toggle Sidebar",
                    description: "Collapses or expands the left sidebar in the active window.",
                    shortcut: "⌥⌘S",
                    contextLabel: "Scope",
                    contextValue: "Active window"
                )),
                perform: { [weak self] in
                    self?.close(restoreFocus: true)
                    self?.onToggleSidebar?()
                }
            ),
            PaletteRow(
                id: "cmd-toggle-inspector",
                title: "Toggle Right Inspector",
                subtitle: "Show or hide the right inspector panel",
                shortcut: "⌘\\",
                sfSymbol: "sidebar.right",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Window",
                    title: "Toggle Right Inspector",
                    description: "Collapses or expands the companion inspector pane on the right.",
                    shortcut: "⌘\\",
                    contextLabel: "Scope",
                    contextValue: "Active window"
                )),
                perform: { [weak self] in
                    self?.close(restoreFocus: true)
                    self?.onToggleInspector?()
                }
            ),
            PaletteRow(
                id: "cmd-appearance",
                title: "Appearance & Theme Settings",
                subtitle: "Palette, text size, dark or light mode",
                shortcut: "⌘,",
                sfSymbol: "paintpalette",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Settings",
                    title: "Appearance & Theme Settings",
                    description: "Open Vesper Settings to switch color palettes, text scale, or dark/light mode.",
                    shortcut: "⌘,",
                    contextLabel: "Window",
                    contextValue: "Settings"
                )),
                perform: { [weak self] in
                    self?.close(restoreFocus: false)
                    self?.onOpenSettings?(.pane(pane: .appearance))
                }
            ),
            PaletteRow(
                id: "cmd-shortcuts",
                title: "Keyboard Shortcuts",
                subtitle: "View all Vesper keyboard shortcuts",
                shortcut: "?",
                sfSymbol: "keyboard",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Help",
                    title: "Keyboard Shortcuts",
                    description: "Opens the keyboard shortcut reference sheet.",
                    shortcut: "?",
                    contextLabel: "Scope",
                    contextValue: "Global"
                )),
                perform: { [weak self] in
                    self?.close(restoreFocus: false)
                    self?.onShowShortcuts?()
                }
            ),
        ]

        var goToRows = allAppJumps.map { app -> PaletteRow in
            PaletteRow(
                id: "cmd-goto-\(app.href)",
                title: "Go to \(app.label)",
                subtitle: app.href,
                sfSymbol: app.sfSymbol,
                href: app.href,
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Go to",
                    title: "Go to \(app.label)",
                    description: "Navigates the active tab to \(app.label) (\(app.href)).",
                    shortcut: "↵",
                    contextLabel: "Route",
                    contextValue: app.href
                )),
                customAppSlug: app.customAppSlug
            )
        }
        for app in customApps {
            goToRows.append(PaletteRow(
                id: "cmd-standalone-\(app.slug)",
                title: "Open \(app.name) in Standalone Window",
                subtitle: "/apps/\(app.slug) · standalone window",
                sfSymbol: "macwindow.on.rectangle",
                highlightTitle: true,
                preview: .command(PaletteCommandPreview(
                    category: "Command · Custom App",
                    title: "Open \(app.name) in Standalone Window",
                    description: "Launches or focuses \(app.name) in its dedicated standalone macOS window.",
                    shortcut: "↵",
                    contextLabel: "Custom App",
                    contextValue: "/apps/\(app.slug)"
                )),
                perform: { [weak self] in self?.openCustomAppStandalone(slug: app.slug) }
            ))
        }

        if !q.isEmpty {
            createRows = createRows.filter { CommandPaletteLogic.matchesWords("\($0.title) \($0.subtitle ?? "")", query: q) }
            contextRows = contextRows.filter { CommandPaletteLogic.matchesWords("\($0.title) \($0.subtitle ?? "")", query: q) }
            workspaceRows = workspaceRows.filter { CommandPaletteLogic.matchesWords("\($0.title) \($0.subtitle ?? "")", query: q) }
            goToRows = goToRows.filter { CommandPaletteLogic.matchesWords("\($0.title) \($0.subtitle ?? "")", query: q) }
        }

        var result: [PaletteSection] = []
        if !createRows.isEmpty { result.append(PaletteSection(id: "cmd-create", label: "Create", rows: createRows)) }
        if !contextRows.isEmpty { result.append(PaletteSection(id: "cmd-context", label: "Current page", rows: contextRows)) }
        if !workspaceRows.isEmpty { result.append(PaletteSection(id: "cmd-workspace", label: "Window & Workspace", rows: workspaceRows)) }
        if !goToRows.isEmpty { result.append(PaletteSection(id: "cmd-goto", label: "Go to", rows: goToRows)) }
        return result
    }

    private func buildProjectSections() -> [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let rows = projects
            .filter { q.isEmpty || CommandPaletteLogic.matchesWords("\($0.key) \($0.name)", query: q) }
            .map { project -> PaletteRow in
                let isCurrent = project.key == activeProject
                return PaletteRow(
                    id: "proj-\(project.key)",
                    title: "\(project.key) · \(project.name)",
                    subtitle: "Space",
                    meta: isCurrent ? "current" : nil,
                    metaTone: isCurrent ? "accent" : nil,
                    sfSymbol: "folder",
                    tone: isCurrent ? .accent : .neutral,
                    highlightTitle: !q.isEmpty,
                    preview: .command(PaletteCommandPreview(
                        category: "Space",
                        title: "\(project.key) · \(project.name)",
                        description: "Switch your active space context to \(project.name).",
                        shortcut: "↵",
                        contextLabel: "Key",
                        contextValue: project.key
                    )),
                    perform: { [weak self] in
                        self?.rememberProject(project.key)
                        self?.close(restoreFocus: false)
                        self?.onNavigate?("/tickets?project=\(project.key)", false)
                    }
                )
            }
        return rows.isEmpty ? [] : [PaletteSection(id: "projects", label: "Switch space", rows: rows)]
    }

    // MARK: - Hit Row Mapping

    private func hitRow(_ hit: API.SearchHit, type: CommandPaletteType) -> PaletteRow? {
        let t = hit.target
        guard let link = CommandPaletteLogic.linkFromTarget(t) else { return nil }
        let at = hit.updatedAt.map { APIDate.shortAgo($0) }
        var attach: PaletteAttachRef?
        if t.kind == .ticket, let key = t.displayId, !key.isEmpty {
            attach = PaletteAttachRef(kind: "ticket", idOrKey: key, label: key, project: CommandPaletteLogic.projectOfKey(key))
        } else if t.kind == .artifact, let id = t.id, !id.isEmpty {
            let kind = t.artifactType == .note ? "page" : "artifact"
            attach = PaletteAttachRef(kind: kind, idOrKey: id, label: t.path ?? t.title, project: nil)
        }

        switch type {
        case .ticket:
            let key = t.displayId ?? ""
            let sub = [key.isEmpty ? nil : key, hit.detail ?? "unassigned"].compactMap { $0 }.joined(separator: " · ")
            return PaletteRow(
                id: "ticket-\(link.id)",
                title: t.title,
                subtitle: sub,
                meta: t.status.map { Self.statusLabel($0) },
                metaTone: t.status,
                sfSymbol: type.sfSymbol,
                href: link.href,
                recent: link,
                score: hit.score,
                highlightTitle: true,
                type: type,
                preview: .ticket(key: key, title: t.title),
                attach: attach,
                facet: t.status
            )
        case .page:
            let folder = hit.detail ?? ""
            let bodyMatch = CommandPaletteLogic.foundInBody(snippet: hit.snippet, title: t.title)
            let snippet = bodyMatch ? CommandPaletteLogic.snippetParts(hit.snippet) : nil
            let sub = bodyMatch ? (folder.isEmpty ? nil : "\(folder) · ") : [folder.isEmpty ? nil : folder, "page"].compactMap { $0 }.joined(separator: " · ")
            let isKnowledge = link.href.hasPrefix("/knowledge/")
            return PaletteRow(
                id: "page-\(link.id)",
                title: t.title,
                subtitle: sub,
                subtitleSnippet: snippet,
                meta: at,
                sfSymbol: type.sfSymbol,
                href: link.href,
                recent: link,
                score: hit.score,
                highlightTitle: true,
                type: type,
                preview: .page(id: t.id ?? "", path: t.path ?? "", title: t.title, isKnowledge: isKnowledge, row: nil),
                attach: attach,
                facet: folder.isEmpty ? nil : folder
            )
        case .run:
            return PaletteRow(
                id: "run-\(link.id)",
                title: t.title,
                subtitle: hit.detail,
                meta: t.status?.replacingOccurrences(of: "_", with: " "),
                metaTone: t.status == "failed" ? "blocked" : t.status,
                sfSymbol: type.sfSymbol,
                href: link.href,
                recent: link,
                score: hit.score,
                highlightTitle: true,
                type: type,
                preview: .item(label: "Run", title: t.title, detail: hit.detail, updatedAt: hit.updatedAt),
                facet: t.status
            )
        case .people:
            let sub = t.kind == .agent ? [hit.detail, "agent"].compactMap { $0 }.joined(separator: " · ") : "persona"
            return PaletteRow(
                id: "people-\(link.id)",
                title: t.title,
                subtitle: sub,
                meta: at,
                sfSymbol: type.sfSymbol,
                href: link.href,
                recent: link,
                score: hit.score,
                highlightTitle: true,
                type: type,
                preview: .item(label: t.kind == .agent ? "Agent" : "Persona", title: t.title, detail: hit.detail, updatedAt: hit.updatedAt)
            )
        default:
            let sub = [hit.detail, type == .artifact ? t.artifactType?.rawValue : t.kind.rawValue]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return PaletteRow(
                id: "\(type.rawValue)-\(link.id)",
                title: t.title,
                subtitle: sub.isEmpty ? nil : sub,
                meta: at,
                sfSymbol: type.sfSymbol,
                href: link.href,
                recent: link,
                score: hit.score,
                highlightTitle: true,
                type: type,
                preview: .item(label: type.singularLabel, title: t.title, detail: hit.detail ?? t.status, updatedAt: hit.updatedAt),
                attach: attach
            )
        }
    }

    private func chatRow(_ chat: CommandPaletteChatMatch) -> PaletteRow {
        let count = chat.messages.count
        let matched = count > 0 ? "\(count) \(count == 1 ? "message matches" : "messages match")" : "chat"
        let arrow = count > 0 ? (expandedChatId == chat.id ? "  ↓" : "  →") : ""
        let sub = [chat.persona, matched].compactMap { $0 }.joined(separator: " · ") + arrow
        return PaletteRow(
            id: "chat-\(chat.id)",
            title: chat.title,
            subtitle: sub,
            meta: chat.at.map { APIDate.shortAgo($0) },
            sfSymbol: "bubble.left",
            href: chat.href,
            recent: CommandPaletteLink(id: chat.id, title: chat.title, meta: "chat", href: chat.href, kind: "Chats"),
            score: chat.score,
            highlightTitle: chat.titled,
            type: .chat,
            preview: .chat(chat),
            chat: chat,
            facet: chat.persona
        )
    }

    private func expandChatRows(_ rows: [PaletteRow]) -> [PaletteRow] {
        rows.flatMap { row -> [PaletteRow] in
            guard let chat = row.chat, !row.isChildMessage, expandedChatId == chat.id else { return [row] }
            let children = chat.messages.map { msg -> PaletteRow in
                let author = msg.author.isEmpty ? "Message" : msg.author
                let time = msg.at.map { APIDate.timeline($0) } ?? ""
                let title = [author, time.isEmpty ? nil : time].compactMap { $0 }.joined(separator: " · ")
                return PaletteRow(
                    id: "msg-\(chat.id)-\(msg.id)",
                    title: title,
                    subtitleSnippet: CommandPaletteLogic.snippetParts(msg.snippet),
                    sfSymbol: "text.bubble",
                    href: msg.href,
                    type: .chat,
                    preview: .message(chat: chat, message: msg),
                    chat: chat,
                    message: msg
                )
            }
            return [row] + children
        }
    }

    // MARK: - Formatting Helpers

    static func statusLabel(_ raw: String) -> String {
        switch raw {
        case "in_progress": "in progress"
        case "in_review": "in review"
        default: raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func symbolForKindLabel(_ kind: String) -> String {
        if let type = CommandPaletteType.allCases.first(where: { $0.label.caseInsensitiveCompare(kind) == .orderedSame }) {
            return type.sfSymbol
        }
        return "doc.text"
    }
}
