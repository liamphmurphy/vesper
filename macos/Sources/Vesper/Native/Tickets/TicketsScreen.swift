import SwiftUI
import VesperCore

/// Per-tab state for `/tickets` and `/board` (filters, layout, grouping, selection, and sheets).
@MainActor
@Observable
final class TicketsModel {
    static let projectKey = "VesperNativeWorkProject"
    static let densityKey = "VesperNativeTicketsDensity"
    static let companionKey = "VesperNativeWorkCompanionOpen"

    enum SavedViewSheet: Identifiable {
        case create(initialName: String, query: String)
        case rename(API.SavedView)

        var id: String {
            switch self {
            case .create(_, let query): "create:\(query)"
            case .rename(let view): "rename:\(view.id)"
            }
        }
    }

    var layout: TicketsLogic.Layout = .list
    var project = ""
    var viewParam = "all"
    var statusFilter: API.TicketStatus?
    var epicId = ""
    var agent = ""
    var searchText = ""
    var readyOnly = false
    var blockedOnly = false
    var unestimatedOnly = false
    var savedViewId: String?
    var groupBy: TicketsLogic.GroupBy = .status
    var sortBy: TicketsLogic.SortBy = .defaultOrder
    var density: TicketsLogic.Density = TicketsLogic.Density(
        rawValue: UserDefaults.standard.string(forKey: TicketsModel.densityKey) ?? ""
    ) ?? .comfortable
    var showCanceled = false
    var boardBlockedOnly = false
    var collapsedGroups: Set<String> = []
    var selectedKeys: Set<String> = []
    var selectionAnchor: String?
    var focusedKey: String?
    var activeModifiers: EventModifiers = []
    var dispatchKeys: [String] = []
    var bulkBusy = false
    var bulkLabelPickerOpen = false
    var bulkLabelDraft: Set<String> = []
    var companionOpen = UserDefaults.standard.bool(forKey: TicketsModel.companionKey) {
        didSet { UserDefaults.standard.set(companionOpen, forKey: Self.companionKey) }
    }
    var savedViewSheet: SavedViewSheet?
    var pendingDeleteView: API.SavedView?

    func seed(from match: NativeRouteMatch) {
        layout = TicketsLogic.parseLayout(match.query["layout"], path: match.path)
        if let queryProject = match.query["project"] {
            setProject(queryProject)
        } else {
            project = UserDefaults.standard.string(forKey: Self.projectKey) ?? ""
        }
        applyQueryDict(match.query, svId: match.query["sv"].flatMap { $0.isEmpty ? nil : $0 })
        selectedKeys = []
        selectionAnchor = nil
        focusedKey = nil
    }

    func setProject(_ key: String) {
        project = key
        UserDefaults.standard.set(key, forKey: Self.projectKey)
        clearSelection()
    }

    func setDensity(_ value: TicketsLogic.Density) {
        density = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.densityKey)
    }

    func selectQueue(_ queue: TicketsLogic.Queue) {
        savedViewId = nil
        epicId = ""
        statusFilter = nil
        unestimatedOnly = false
        switch queue {
        case .needsYou: (viewParam, readyOnly, blockedOnly) = ("needs_human", false, false)
        case .inProgress: (viewParam, readyOnly, blockedOnly) = ("active", false, false)
        case .ready: (viewParam, readyOnly, blockedOnly) = ("all", true, false)
        case .blocked: (viewParam, readyOnly, blockedOnly) = ("all", false, true)
        case .all: (viewParam, readyOnly, blockedOnly) = ("all", false, false)
        }
        clearSelection()
    }

    func applyQueryDict(_ params: [String: String], svId: String?) {
        savedViewId = svId
        viewParam = params["view"].flatMap { $0.isEmpty ? nil : $0 } ?? "all"
        statusFilter = params["status"].flatMap { $0.isEmpty ? nil : API.TicketStatus(rawValue: $0) }
        epicId = params["epic"] ?? ""
        agent = params["assignee"] ?? params["agent"] ?? ""
        searchText = params["q"] ?? ""
        readyOnly = params["ready"] == "true"
        blockedOnly = params["blocked"] == "true"
        unestimatedOnly = params["unestimated"] == "true"
        groupBy = TicketsLogic.GroupBy.parse(params["group"])
        sortBy = params["sort"].flatMap(TicketsLogic.SortBy.init(rawValue:)) ?? .defaultOrder
    }

    func clearFilters() {
        savedViewId = nil
        viewParam = "all"
        statusFilter = nil
        epicId = ""
        agent = ""
        searchText = ""
        readyOnly = false
        blockedOnly = false
        unestimatedOnly = false
        clearSelection()
    }

    func currentViewParams(
        epic: String?, assignee: String?, status: API.TicketStatus?, freeQuery: String?
    ) -> [String: String] {
        var params: [String: String] = ["view": viewParam, "group": groupBy.rawValue]
        if let status { params["status"] = status.rawValue }
        if let assignee, !assignee.isEmpty { params["assignee"] = assignee }
        if let epic, !epic.isEmpty { params["epic"] = epic }
        if let freeQuery, !freeQuery.isEmpty { params["q"] = freeQuery }
        if readyOnly { params["ready"] = "true" }
        if blockedOnly { params["blocked"] = "true" }
        if unestimatedOnly { params["unestimated"] = "true" }
        return params
    }

    func currentLayoutQuery(project: String?, epic: String?, assignee: String?) -> [String: String] {
        var out: [String: String] = [:]
        if let project, !project.isEmpty { out["project"] = project }
        if let epic, !epic.isEmpty { out["epic"] = epic }
        if let assignee, !assignee.isEmpty { out["assignee"] = assignee }
        return out
    }

    func toggleSelection(key: String, visibleKeys: [String]) {
        if activeModifiers.contains(.shift) {
            selectedKeys.formUnion(TicketsLogic.rangeKeys(in: visibleKeys, from: selectionAnchor, to: key))
        } else if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
        selectionAnchor = key
        focusedKey = key
    }

    func toggleGroupSelection(_ keys: [String]) {
        if !keys.isEmpty && keys.allSatisfy({ selectedKeys.contains($0) }) {
            selectedKeys.subtract(keys)
        } else {
            selectedKeys.formUnion(keys)
        }
        if let first = keys.first { selectionAnchor = first }
    }

    func clearSelection() {
        selectedKeys = []
        selectionAnchor = nil
    }
}

/// Native `/tickets` and `/board` workspace: List (grouped + multi-select + bulk actions),
/// Board (`TicketsBoardView`), and Epics (`EpicsLayoutSlot`), with `TicketsNav` sidebar & commands.
struct TicketsScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var model = TicketsModel()
    @State private var watched: [QueryKey] = []
    @FocusState private var searchFocused: Bool

    static let bootstrap = API.getBootstrap()
    static let inbox = API.listInbox()
    static let savedViews = API.listSavedViews()
    static let epicOverviews = API.listEpicOverviews()
    static let personas = API.listPersonas()

    private struct ScreenData {
        let boot: API.Bootstrap?
        let resolved: TicketsLogic.ResolvedFilter
        let effectiveProject: String?
        let effectiveEpic: String?
        let effectiveAssignee: String?
        let effectiveStatus: API.TicketStatus?
        let freeQuery: String?
        let boardProjectKey: String?
        let allTicketsRequest: APIRequest<API.TicketList>
        let listRequest: APIRequest<API.TicketList>
        let boardRequest: APIRequest<API.Board>?
    }

    private func computeScreenData() -> ScreenData {
        let boot = context.store.entry(Self.bootstrap).data
        let lookups = TicketsLogic.FilterLookups(
            projects: boot?.projects ?? [],
            epics: boot?.epics ?? [],
            agents: boot?.agents ?? [],
            currentEpic: model.epicId.isEmpty ? nil : model.epicId
        )
        let resolved = TicketsLogic.resolveFilter(model.searchText, lookups: lookups)
        let effectiveProject = resolved.project ?? (model.project.isEmpty ? nil : model.project)
        let effectiveEpic = resolved.epic ?? (model.epicId.isEmpty ? nil : model.epicId)
        let effectiveAssignee = resolved.assignee ?? (model.agent.isEmpty ? nil : model.agent)
        let effectiveStatus = resolved.status ?? model.statusFilter
        let freeQuery = resolved.q
        let boardProjectKey = effectiveProject
            ?? boot?.projects.first(where: { !$0.archived })?.key
            ?? boot?.projects.first?.key
        let allReq = API.listTickets(project: effectiveProject, view: .all)
        let listReq = API.listTickets(
            project: effectiveProject,
            view: API.ListTicketsView(rawValue: model.viewParam),
            status: effectiveStatus,
            ready: model.readyOnly ? true : nil,
            assignee: effectiveAssignee,
            q: freeQuery,
            epic: effectiveEpic
        )
        let boardReq = boardProjectKey.map {
            API.getProjectBoard(
                key: $0,
                epic: effectiveEpic,
                assignee: effectiveAssignee,
                includeCanceled: model.showCanceled ? true : nil
            )
        }
        return ScreenData(
            boot: boot, resolved: resolved, effectiveProject: effectiveProject,
            effectiveEpic: effectiveEpic, effectiveAssignee: effectiveAssignee,
            effectiveStatus: effectiveStatus, freeQuery: freeQuery,
            boardProjectKey: boardProjectKey, allTicketsRequest: allReq,
            listRequest: listReq, boardRequest: boardReq
        )
    }

    var body: some View {
        let data = computeScreenData()
        let store = context.store
        let inboxItems = store.entry(Self.inbox).data?.items ?? []
        let needsByKey = TicketsLogic.needsYouByTicket(inboxItems)
        let views = store.entry(Self.savedViews).data?.views ?? []
        let overviews = store.entry(Self.epicOverviews).data?.epics ?? []
        let allTickets = store.entry(data.allTicketsRequest).data?.tickets ?? []
        let listEntry = store.entry(data.listRequest)
        let filteredTickets = TicketsLogic.applyLocalFilters(
            listEntry.data?.tickets ?? [],
            blockedOnly: model.blockedOnly,
            unestimatedOnly: model.unestimatedOnly
        )
        let groups = TicketsLogic.workGroups(filteredTickets, needs: needsByKey, by: model.groupBy, sort: model.sortBy)
        let visibleTickets = groups.flatMap { model.collapsedGroups.contains($0.id) ? [] : $0.tickets }
        let visibleKeys = visibleTickets.map(\.key)
        let readyKeys = TicketsLogic.readyDispatchKeys(in: allTickets)
        let findTexts = visibleTickets.map {
            "\($0.key) \($0.title) \($0.epic?.name ?? "") \($0.assignee?.name ?? "")"
        }
        let watchKeys = [
            data.allTicketsRequest.key,
            data.listRequest.key,
            model.layout == .board ? data.boardRequest?.key : nil,
        ].compactMap { $0 }

        VStack(spacing: 0) {
            topControls(data: data, views: views, readyKeys: readyKeys)
            Divider()
            if model.layout == .list && !model.selectedKeys.isEmpty {
                bulkBar(data: data, visibleKeys: visibleKeys, visibleTickets: visibleTickets)
                Divider()
            }
            mainContent(
                data: data, listEntry: listEntry, groups: groups,
                visibleKeys: visibleKeys, needsByKey: needsByKey
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: buildChrome(data: data, allTickets: allTickets, inboxItems: inboxItems, views: views, overviews: overviews, readyCount: readyKeys.count), initial: true) { _, chrome in
            context.chrome = chrome
        }
        .onChange(of: findTexts, initial: true) { _, texts in context.find.texts = texts }
        .task(id: context.match) { model.seed(from: context.match) }
        .task(id: watchKeys) { watch(data: data) }
        .onAppear {
            let model = model, context = context
            context.onCommand = { command in Self.handle(command, model: model, context: context) }
        }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
            context.find.texts = []
        }
        .modifier(ModifierKeyTracker(modifiers: $model.activeModifiers))
        .sheet(isPresented: Binding(get: { !model.dispatchKeys.isEmpty }, set: { if !$0 { model.dispatchKeys = [] } })) {
            WorkDispatchSheet(keys: model.dispatchKeys) { model.dispatchKeys = [] }
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
        .sheet(item: $model.savedViewSheet) { sheet in
            SavedViewEditorSheet(sheet: sheet, epics: data.boot?.epics ?? []) { model.savedViewSheet = nil }
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
        .alert(
            "Delete saved view?",
            isPresented: Binding(get: { model.pendingDeleteView != nil }, set: { if !$0 { model.pendingDeleteView = nil } }),
            presenting: model.pendingDeleteView
        ) { view in
            Button("Delete", role: .destructive) { Task { await deleteSavedView(view) } }
            Button("Cancel", role: .cancel) { model.pendingDeleteView = nil }
        } message: { view in
            Text("Delete \u{201C}\(view.name)\u{201D}? Your tickets won\u{2019}t be touched.")
        }
    }

    // MARK: - Top Toolbar & Layout Bar

    private func topControls(data: ScreenData, views: [API.SavedView], readyKeys: [String]) -> some View {
        let projects = (data.boot?.projects ?? []).filter { !$0.archived }
        let currentProject = projects.first { $0.key == (model.layout == .board ? data.boardProjectKey : data.effectiveProject) }
        let activeView = model.savedViewId.flatMap { id in views.first { $0.id == id } }
        let hasActiveFilter = model.viewParam != "all" || data.effectiveStatus != nil || data.effectiveEpic != nil
            || data.effectiveAssignee != nil || !model.searchText.isEmpty || model.readyOnly || model.blockedOnly || model.unestimatedOnly

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    if model.layout != .board {
                        Button {
                            model.setProject("")
                        } label: {
                            menuOptionLabel("All spaces", checked: (data.effectiveProject ?? "").isEmpty)
                        }
                        Divider()
                    }
                    ForEach(projects, id: \.key) { proj in
                        Button {
                            model.setProject(proj.key)
                        } label: {
                            menuOptionLabel(proj.name, checked: currentProject?.key == proj.key)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(cssHex: currentProject?.color) ?? theme.palette.tertiaryText)
                            .frame(width: 7, height: 7)
                        Text(currentProject?.name ?? "All spaces")
                            .font(.system(size: theme.pointSize(.body), weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                HStack(spacing: 2) {
                    ForEach(TicketsLogic.Layout.allCases, id: \.rawValue) { item in
                        let active = model.layout == item
                        Button {
                            switchLayout(item, data: data)
                        } label: {
                            Label(item.label, systemImage: SidebarIcons.symbolName(item.icon))
                                .font(.system(size: theme.pointSize(.small), weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(active ? theme.palette.background : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border.opacity(0.7)))

                if model.layout == .list {
                    savedViewsMenu(data: data, views: views, activeView: activeView)
                }

                Spacer(minLength: 8)

                if model.layout == .list && !readyKeys.isEmpty {
                    Button {
                        model.dispatchKeys = readyKeys
                    } label: {
                        Label("Start ready (\(readyKeys.count))", systemImage: "play.fill")
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                    }
                    .buttonStyle(.vesper())
                }

                Button {
                    context.navigate(TicketsLogic.newTicketHref(project: data.effectiveProject, epic: data.effectiveEpic))
                } label: {
                    Label("New Ticket", systemImage: "plus")
                }
                .buttonStyle(.vesper(.primary))
            }

            if model.layout == .list {
                listFilterBar(data: data, hasActiveFilter: hasActiveFilter)
            } else if model.layout == .board {
                boardFilterBar(data: data)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.palette.background)
    }

    private func savedViewsMenu(data: ScreenData, views: [API.SavedView], activeView: API.SavedView?) -> some View {
        Menu {
            if !views.isEmpty {
                Section("Saved views") {
                    ForEach(views, id: \.id) { view in
                        Button {
                            model.layout = .list
                            model.applyQueryDict(TicketsLogic.parseQueryString(view.query), svId: view.id)
                        } label: {
                            menuOptionLabel(view.name, checked: activeView?.id == view.id)
                        }
                    }
                }
            }
            Section("Suggested") {
                ForEach(TicketsLogic.suggestedViews) { suggested in
                    Button {
                        model.layout = .list
                        model.applyQueryDict(TicketsLogic.parseQueryString(suggested.query), svId: nil)
                    } label: {
                        Text(suggested.name)
                    }
                }
            }
            Divider()
            let currentQuery = TicketsLogic.normalizedViewQuery(model.currentViewParams(
                epic: data.effectiveEpic, assignee: data.effectiveAssignee,
                status: data.effectiveStatus, freeQuery: data.freeQuery
            ))
            Button("Save current view\u{2026}") {
                model.savedViewSheet = .create(initialName: "", query: currentQuery)
            }
            if let activeView {
                Button("Rename \u{201C}\(activeView.name)\u{201D}\u{2026}") {
                    model.savedViewSheet = .rename(activeView)
                }
                Button("Copy view link") { copyViewLink(activeView, project: data.effectiveProject) }
                Button("Delete view", role: .destructive) { model.pendingDeleteView = activeView }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bookmark").font(.system(size: 11))
                Text(activeView?.name ?? "Views")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(activeView != nil ? theme.palette.accent : theme.palette.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func listFilterBar(data: ScreenData, hasActiveFilter: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.tertiaryText)
                TextField("Filter\u{2026} project: epic: persona: status:", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.body)))
                    .focused($searchFocused)
                if !data.resolved.unknown.isEmpty {
                    Text(data.resolved.unknown.joined(separator: " "))
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border))

            filterChip("Ready", active: model.readyOnly) { model.readyOnly.toggle(); model.savedViewId = nil }
            filterChip("Blocked", active: model.blockedOnly) { model.blockedOnly.toggle(); model.savedViewId = nil }
            filterChip("Unestimated", active: model.unestimatedOnly) { model.unestimatedOnly.toggle(); model.savedViewId = nil }

            if hasActiveFilter {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.accent)
            }

            Menu {
                ForEach(TicketsLogic.GroupBy.allCases, id: \.rawValue) { g in
                    Button { model.groupBy = g } label: { menuOptionLabel(g.label, checked: model.groupBy == g) }
                }
            } label: {
                toolbarChipLabel("Group: \(model.groupBy.label)", icon: "rectangle.3.group")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(TicketsLogic.SortBy.allCases, id: \.rawValue) { s in
                    Button { model.sortBy = s } label: { menuOptionLabel(s.label, checked: model.sortBy == s) }
                }
            } label: {
                toolbarChipLabel("Sort: \(model.sortBy.label)", icon: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.setDensity(model.density == .comfortable ? .compact : .comfortable)
            } label: {
                Image(systemName: model.density == .compact ? "list.dash" : "list.bullet")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border))
            }
            .buttonStyle(.plain)
            .help(model.density.label)
        }
    }

    private func boardFilterBar(data: ScreenData) -> some View {
        let boardProjId = data.boot?.projects.first(where: { $0.key == data.boardProjectKey })?.id
        let epics = (data.boot?.epics ?? []).filter { (boardProjId == nil || $0.projectId == boardProjId) && $0.status == .open }
        let agents = data.boot?.agents ?? []
        let activeEpic = epics.first { $0.id == data.effectiveEpic }
        let activeAgent = agents.first { $0.handle == data.effectiveAssignee }

        return HStack(spacing: 8) {
            Menu {
                Button { model.epicId = "" } label: { menuOptionLabel("All epics", checked: (data.effectiveEpic ?? "").isEmpty) }
                Divider()
                ForEach(epics, id: \.id) { epic in
                    Button { model.epicId = epic.id } label: { menuOptionLabel(epic.name, checked: data.effectiveEpic == epic.id) }
                }
            } label: {
                toolbarChipLabel(activeEpic?.name ?? "All epics", icon: SidebarIcons.symbolName("epics"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button { model.agent = "" } label: { menuOptionLabel("All personas", checked: (data.effectiveAssignee ?? "").isEmpty) }
                Divider()
                ForEach(agents, id: \.id) { person in
                    Button { model.agent = person.handle } label: { menuOptionLabel(person.name, checked: data.effectiveAssignee == person.handle) }
                }
            } label: {
                toolbarChipLabel(activeAgent?.name ?? "All personas", icon: "person")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            filterChip("Show canceled", active: model.showCanceled) { model.showCanceled.toggle() }
            filterChip("Blocked only", active: model.boardBlockedOnly) { model.boardBlockedOnly.toggle() }
            Spacer()
        }
    }

    // MARK: - Bulk Action Bar

    private func bulkBar(data: ScreenData, visibleKeys: [String], visibleTickets: [API.TicketSummary]) -> some View {
        let selectedTickets = visibleTickets.filter { model.selectedKeys.contains($0.key) }
        let selectedProjectKeys = Set(selectedTickets.map(\.projectKey))
        let commonProjectId = selectedProjectKeys.count == 1
            ? data.boot?.projects.first(where: { $0.key == selectedProjectKeys.first })?.id
            : nil
        let epics = (data.boot?.epics ?? []).filter { commonProjectId != nil && $0.projectId == commonProjectId && $0.status == .open }
        let assignableAgents = (data.boot?.agents ?? []).filter { $0.kind == .main }
        let readySelected = TicketsLogic.readyDispatchKeys(in: selectedTickets)
        let labels = data.boot?.labels ?? []

        return HStack(spacing: 8) {
            Text("\(model.selectedKeys.count) selected")
                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                .foregroundStyle(theme.palette.accent)

            if visibleKeys.contains(where: { !model.selectedKeys.contains($0) }) {
                Button("Select all (\(visibleKeys.count))") { model.selectedKeys.formUnion(visibleKeys) }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.secondaryText)
            }

            Divider().frame(height: 16)

            Menu("Status") {
                ForEach(TicketsLogic.statusOrder, id: \.rawValue) { status in
                    Button(TicketsLogic.statusLabel(status)) {
                        Task { await performBulkUpdate(API.TicketPatch(status: status), label: "status \u{2192} \(TicketsLogic.statusLabel(status))") }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.bulkBusy)

            Menu("Priority") {
                ForEach(TicketsLogic.priorityOrder, id: \.rawValue) { priority in
                    Button(TicketsLogic.priorityLabel(priority)) {
                        Task { await performBulkUpdate(API.TicketPatch(priority: priority), label: "priority \u{2192} \(TicketsLogic.priorityLabel(priority))") }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.bulkBusy)

            Menu("Agent") {
                Button("Unassigned") {
                    Task { await performBulkUpdate(API.TicketPatch(assigneeAgentId: .null), label: "unassigned") }
                }
                Divider()
                ForEach(assignableAgents, id: \.id) { person in
                    Button("\(person.name) (@\(person.handle))") {
                        Task { await performBulkUpdate(API.TicketPatch(assigneeAgentId: .value(person.id)), label: "assigned to \(person.name)") }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.bulkBusy)

            Menu("Epic") {
                Button("No epic") {
                    Task { await performBulkUpdate(API.TicketPatch(epicId: .null), label: "cleared epic") }
                }
                if !epics.isEmpty {
                    Divider()
                    ForEach(epics, id: \.id) { epic in
                        Button(epic.name) {
                            Task { await performBulkUpdate(API.TicketPatch(epicId: .value(epic.id)), label: "epic \u{2192} \(epic.name)") }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.bulkBusy || (selectedProjectKeys.count > 1))
            .help(selectedProjectKeys.count > 1 ? "Select tickets from one space to assign an epic" : "Set epic")

            Button("Labels") {
                model.bulkLabelDraft = Set(selectedTickets.first?.labels.map(\.id) ?? [])
                model.bulkLabelPickerOpen.toggle()
            }
            .buttonStyle(.vesper())
            .disabled(model.bulkBusy || labels.isEmpty)
            .popover(isPresented: $model.bulkLabelPickerOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replace labels on \(model.selectedKeys.count) ticket(s)")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    ForEach(labels, id: \.id) { label in
                        let checked = model.bulkLabelDraft.contains(label.id)
                        Button {
                            if checked { model.bulkLabelDraft.remove(label.id) } else { model.bulkLabelDraft.insert(label.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                Circle().fill(Color(cssHex: label.color) ?? theme.palette.secondaryText).frame(width: 7, height: 7)
                                Text(label.name).font(.system(size: theme.pointSize(.small)))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Button("Clear") {
                            model.bulkLabelPickerOpen = false
                            Task { await performBulkUpdate(API.TicketPatch(labelIds: []), label: "cleared labels") }
                        }
                        .buttonStyle(.vesper())
                        Spacer()
                        Button("Apply") {
                            let ids = Array(model.bulkLabelDraft)
                            model.bulkLabelPickerOpen = false
                            Task { await performBulkUpdate(API.TicketPatch(labelIds: ids), label: "updated labels") }
                        }
                        .buttonStyle(.vesper(.primary))
                    }
                }
                .padding(12)
                .frame(width: 240)
            }

            if !readySelected.isEmpty {
                Button("Start (\(readySelected.count))") { model.dispatchKeys = readySelected }
                    .buttonStyle(.vesper(.approve))
                    .disabled(model.bulkBusy)
            }

            Spacer()
            if model.bulkBusy { ProgressView().controlSize(.small) }
            Button("Clear") { model.clearSelection() }.buttonStyle(.vesper())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.palette.accent.opacity(0.08))
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(
        data: ScreenData,
        listEntry: QueryEntry<API.TicketList>,
        groups: [TicketsLogic.TicketGroup],
        visibleKeys: [String],
        needsByKey: [String: TicketsLogic.NeedsYou]
    ) -> some View {
        switch model.layout {
        case .epics:
            let query = data.effectiveProject.map { ["project": $0] } ?? [:]
            EpicsLayoutSlot(query: query)
        case .board:
            if let boardReq = data.boardRequest {
                TicketsBoardView(
                    boardRequest: boardReq,
                    selectedProject: data.boardProjectKey,
                    selectedEpicId: data.effectiveEpic,
                    includeCanceled: model.showCanceled,
                    blockedOnly: model.boardBlockedOnly,
                    needsByKey: needsByKey,
                    onOpenTicket: { key, newTab in
                        let href = TicketsLogic.ticketHref(key)
                        newTab ? context.openInNewTab(href) : context.navigate(href)
                    },
                    onNewTicket: { status in
                        context.navigate(TicketsLogic.newTicketHref(
                            project: data.boardProjectKey, status: status, epic: data.effectiveEpic
                        ))
                    },
                    onStartTicket: { key in model.dispatchKeys = [key] },
                    onOpenListWithStatus: { status in
                        model.layout = .list
                        model.statusFilter = status
                        context.navigate(TicketsLogic.ticketsHref(layout: .list, query: [
                            "project": data.boardProjectKey, "epic": data.effectiveEpic, "status": status.rawValue,
                        ]))
                    }
                )
                .padding(.top, 10)
            } else {
                emptyState(title: "No spaces yet", subtitle: "Create a space before using the board.") {
                    Button("New space") { context.navigate("/spaces/new?work=1") }.buttonStyle(.vesper(.primary))
                }
            }
        case .list:
            if let error = listEntry.error, listEntry.data == nil {
                QueryErrorView(message: "Couldn\u{2019}t load tickets: \(error.userMessage)") {
                    Task { await context.store.refetch(data.listRequest) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listEntry.data == nil {
                VStack(spacing: 10) {
                    ForEach(0..<8, id: \.self) { _ in SkeletonBar(height: 36) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if groups.isEmpty {
                emptyState(title: "No matching tickets", subtitle: "Try clearing a filter or creating a new ticket.") {
                    HStack(spacing: 8) {
                        Button("Clear filters") { model.clearFilters() }.buttonStyle(.vesper())
                        Button("New Ticket") {
                            context.navigate(TicketsLogic.newTicketHref(project: data.effectiveProject, epic: data.effectiveEpic))
                        }
                        .buttonStyle(.vesper(.primary))
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(groups) { group in
                                groupSection(group, data: data, visibleKeys: visibleKeys, needsByKey: needsByKey)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: context.find.current) { _, idx in
                        guard let idx, idx >= 0, idx < visibleKeys.count else { return }
                        let key = visibleKeys[idx]
                        model.focusedKey = key
                        withAnimation { proxy.scrollTo(key, anchor: .center) }
                    }
                    .onKeyPress(phases: .down) { press in
                        handleKeyPress(press, visibleKeys: visibleKeys)
                    }
                }
            }
        }
    }

    private func groupSection(
        _ group: TicketsLogic.TicketGroup,
        data: ScreenData,
        visibleKeys: [String],
        needsByKey: [String: TicketsLogic.NeedsYou]
    ) -> some View {
        let collapsed = model.collapsedGroups.contains(group.id)
        let groupKeys = group.tickets.map(\.key)
        let allSelected = !groupKeys.isEmpty && groupKeys.allSatisfy { model.selectedKeys.contains($0) }

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if collapsed { model.collapsedGroups.remove(group.id) } else { model.collapsedGroups.insert(group.id) }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)

                Button {
                    model.toggleGroupSelection(groupKeys)
                } label: {
                    Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(allSelected ? theme.palette.accent : theme.palette.tertiaryText)
                }
                .buttonStyle(.plain)

                Text(group.title)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(group.isNeedsYou ? theme.swiftUIColor("pill-human-fg", fallback: .orange) : theme.palette.text)

                Text("\(group.tickets.count)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)

                Spacer()
                if group.criteriaTotal > 0 {
                    Text("\(group.criteriaDone)/\(group.criteriaTotal) criteria")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                if group.points > 0 {
                    Text("\(group.points) pts")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            if !collapsed {
                ForEach(group.tickets, id: \.key) { ticket in
                    let needs = TicketsLogic.ticketNeedsYou(status: ticket.status, item: needsByKey[ticket.key])
                    let findRow = "\(ticket.key) \(ticket.title) \(ticket.epic?.name ?? "") \(ticket.assignee?.name ?? "")"
                    TicketRowView(
                        ticket: ticket,
                        needs: needs,
                        selected: model.selectedKeys.contains(ticket.key),
                        focused: model.focusedKey == ticket.key,
                        compact: model.density == .compact,
                        showEpic: model.groupBy != .epic && data.effectiveEpic == nil,
                        highlighted: context.find.matches(findRow),
                        onToggleSelect: { model.toggleSelection(key: ticket.key, visibleKeys: visibleKeys) },
                        onOpen: { newTab in
                            if newTab {
                                context.openInNewTab(TicketsLogic.ticketHref(ticket.key))
                            } else if model.activeModifiers.contains(.shift) {
                                model.toggleSelection(key: ticket.key, visibleKeys: visibleKeys)
                            } else if model.activeModifiers.contains(.command) {
                                if !model.selectedKeys.isEmpty {
                                    model.toggleSelection(key: ticket.key, visibleKeys: visibleKeys)
                                } else {
                                    context.openInNewTab(TicketsLogic.ticketHref(ticket.key))
                                }
                            } else {
                                context.navigate(TicketsLogic.ticketHref(ticket.key))
                            }
                        },
                        onOpenNeeds: { href in openNeeds(href) },
                        onStart: { model.dispatchKeys = [ticket.key] },
                        onChangeStatus: { status in
                            Task { await updateRowStatus(ticket: ticket, to: status, listRequest: data.listRequest) }
                        },
                        onCopyKey: {
                            context.copyToClipboard(ticket.key)
                            context.showToast(ToastItemModel(id: "copy.\(ticket.key)", title: "\(ticket.key) copied", tone: .success))
                        },
                        onCopyLink: { copyTicketLink(ticket.key) }
                    )
                    .id(ticket.key)
                }
            }
        }
    }

    // MARK: - Actions & Commands

    private func watch(data: ScreenData) {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        var seen: Set<QueryKey> = []
        var next: [QueryKey] = []
        func start<V: Sendable>(_ request: APIRequest<V>) {
            guard seen.insert(request.key).inserted else { return }
            store.observe(request)
            store.load(request)
            next.append(request.key)
        }
        start(Self.bootstrap)
        start(Self.inbox)
        start(Self.savedViews)
        start(Self.epicOverviews)
        start(Self.personas)
        start(data.allTicketsRequest)
        start(data.listRequest)
        if model.layout == .board, let boardReq = data.boardRequest { start(boardReq) }
        watched = next
    }

    private func switchLayout(_ target: TicketsLogic.Layout, data: ScreenData) {
        guard target != model.layout else { return }
        let href = TicketsLogic.layoutSwitchHref(
            to: target,
            current: model.currentLayoutQuery(project: data.effectiveProject, epic: data.effectiveEpic, assignee: data.effectiveAssignee)
        )
        model.layout = target
        context.navigate(href)
    }

    @MainActor
    private func updateRowStatus(ticket: API.TicketSummary, to targetStatus: API.TicketStatus, listRequest: APIRequest<API.TicketList>) async {
        guard let client = context.store.client else { return }
        do {
            let detail = try await client.send(API.getTicket(key: ticket.key))
            let optimistic = TicketsBoardLogic.listStatusOptimisticUpdate(listRequest: listRequest, key: ticket.key, to: targetStatus)
            _ = try await context.store.mutate(
                API.updateTicket(key: ticket.key, body: API.TicketPatch(revision: detail.revision, status: targetStatus)),
                optimistic: [optimistic],
                invalidating: QueryInvalidation(resources: ["tickets", "board", "boards", "epics", "inbox", "planning"])
            )
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            context.showToast(ToastItemModel(id: "ticket.status.\(ticket.key)", title: "Couldn\u{2019}t update \(ticket.key)", description: msg, tone: .error))
        }
    }

    @MainActor
    private func performBulkUpdate(_ patch: API.TicketPatch, label: String) async {
        let keys = Array(model.selectedKeys)
        guard !keys.isEmpty else { return }
        model.bulkBusy = true
        defer { model.bulkBusy = false }
        do {
            let res = try await context.store.mutate(
                API.bulkUpdateTickets(body: API.BulkUpdate(keys: keys, patch: patch)),
                invalidating: QueryInvalidation(resources: ["tickets", "board", "boards", "epics", "inbox", "planning"])
            )
            model.clearSelection()
            context.showToast(ToastItemModel(
                id: "bulk.ok",
                title: "Updated \(res.updated) ticket\(res.updated == 1 ? "" : "s")",
                description: label,
                tone: .success
            ))
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            context.showToast(ToastItemModel(id: "bulk.err", title: "Bulk update failed", description: msg, tone: .error))
        }
    }

    @MainActor
    private func deleteSavedView(_ view: API.SavedView) async {
        do {
            _ = try await context.store.mutate(
                API.deleteSavedView(id: view.id),
                invalidating: QueryInvalidation(resources: ["saved-views"])
            )
            if model.savedViewId == view.id { model.savedViewId = nil }
            model.pendingDeleteView = nil
            context.showToast(ToastItemModel(id: "sv.del.\(view.id)", title: "Deleted view \u{201C}\(view.name)\u{201D}", tone: .success))
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            context.showToast(ToastItemModel(id: "sv.del.err", title: "Couldn\u{2019}t delete view", description: msg, tone: .error))
        }
    }

    private func openNeeds(_ href: String) {
        if InboxLogic.isExternalHref(href) { context.openExternal(href) } else { context.navigate(href) }
    }

    private func copyTicketLink(_ key: String) {
        let path = TicketsLogic.ticketHref(key)
        context.copyToClipboard(context.resolvedURL(path)?.absoluteString ?? path)
        context.showToast(ToastItemModel(id: "link.\(key)", title: "Link copied", tone: .success))
    }

    private func copyViewLink(_ view: API.SavedView, project: String?) {
        let path = TicketsLogic.savedViewHref(id: view.id, query: view.query, project: project)
        context.copyToClipboard(context.resolvedURL(path)?.absoluteString ?? path)
        context.showToast(ToastItemModel(id: "sv.link.\(view.id)", title: "View link copied", tone: .success))
    }

    private func handleKeyPress(_ press: KeyPress, visibleKeys: [String]) -> KeyPress.Result {
        guard !searchFocused, !visibleKeys.isEmpty else { return .ignored }
        if press.key == .downArrow || press.characters == "j" {
            model.focusedKey = TicketsLogic.moveFocus(in: visibleKeys, current: model.focusedKey, delta: 1)
            return .handled
        }
        if press.key == .upArrow || press.characters == "k" {
            model.focusedKey = TicketsLogic.moveFocus(in: visibleKeys, current: model.focusedKey, delta: -1)
            return .handled
        }
        if press.characters == "x", let key = model.focusedKey ?? visibleKeys.first {
            model.toggleSelection(key: key, visibleKeys: visibleKeys)
            return .handled
        }
        if press.key == .return, let key = model.focusedKey {
            context.navigate(TicketsLogic.ticketHref(key))
            return .handled
        }
        if press.key == .escape {
            if !model.selectedKeys.isEmpty { model.clearSelection(); return .handled }
            if model.focusedKey != nil { model.focusedKey = nil; return .handled }
        }
        return .ignored
    }

    private func buildChrome(
        data: ScreenData, allTickets: [API.TicketSummary], inboxItems: [API.InboxItem],
        views: [API.SavedView], overviews: [API.EpicOverview], readyCount: Int
    ) -> NativeChrome {
        let projects = (data.boot?.projects ?? []).map { ($0.key, $0.name, $0.archived) }
        let agents = (data.boot?.agents ?? []).map { ($0.handle, $0.name) }
        let activeProjKey = model.layout == .board ? data.boardProjectKey : data.effectiveProject
        let activeProjName = projects.first { $0.0 == activeProjKey }?.1
        let spaceMenu = TicketsNav.spaceMenu(
            projects: projects, currentKey: activeProjKey, currentName: activeProjName, allowAll: model.layout != .board
        )
        let extra = model.layout == .board
            ? TicketsNav.boardToolbarExtras(showCanceled: model.showCanceled, blockedOnly: model.boardBlockedOnly)
            : TicketsNav.listToolbarExtras(readyCount: readyCount, group: model.groupBy, density: model.density)
        let toolbar = TicketsNav.ticketsToolbar(
            spaceName: activeProjName ?? "All spaces",
            spaceMenu: spaceMenu,
            layout: model.layout,
            action: (label: model.layout == .epics ? "New Epic" : "New Ticket", primary: true),
            extra: extra
        )
        let navigator: NavModel
        if model.layout == .board {
            var b = TicketsNav.BoardInput()
            b.project = data.boardProjectKey
            b.projects = projects
            b.agents = agents
            b.agent = data.effectiveAssignee ?? ""
            let projId = data.boot?.projects.first(where: { $0.key == data.boardProjectKey })?.id
            b.epics = (data.boot?.epics ?? []).filter { projId == nil || $0.projectId == projId }.filter { $0.status == .open }.map { ($0.id, $0.name) }
            b.epic = data.effectiveEpic
            navigator = TicketsNav.boardModel(b)
        } else {
            var l = TicketsNav.ListInput()
            l.project = data.effectiveProject
            l.projects = projects
            l.agents = agents
            l.agent = data.effectiveAssignee ?? ""
            l.search = model.searchText
            l.counts = TicketsLogic.queueCounts(tickets: allTickets, inbox: inboxItems)
            l.queue = TicketsLogic.activeQueue(svId: model.savedViewId, view: model.viewParam, ready: model.readyOnly, blocked: model.blockedOnly, epic: data.effectiveEpic)
            l.epics = TicketsLogic.sidebarEpics(from: overviews, projectKey: data.effectiveProject)
            l.epic = data.effectiveEpic
            l.views = views
            l.viewId = model.savedViewId
            navigator = TicketsNav.listModel(l)
        }
        let activeView = model.savedViewId.flatMap { id in views.first { $0.id == id } }
        return NativeChrome(
            title: activeView?.name ?? (model.layout == .board ? "Board" : model.layout == .epics ? "Epics" : "Tasks"),
            subtitle: activeProjName,
            titleMenu: activeView != nil ? TicketsNav.savedViewTitleMenu() : nil,
            toolbarItems: toolbar,
            inspector: InspectorModel(
                id: "tickets", open: model.companionOpen, activeTabId: "chat",
                tabs: [InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion)],
                companion: CompanionContext(path: context.match.path)
            ),
            navigator: navigator
        )
    }

    @MainActor
    static func handle(_ command: NativeCommand, model: TicketsModel, context: NativeScreenContext) {
        if case .inspectorVisibility(let open) = command { model.companionOpen = open; return }
        let views = context.store.entry(Self.savedViews).data?.views ?? []
        let boot = context.store.entry(Self.bootstrap).data
        let currentProject = model.project.isEmpty ? nil : model.project
        if case .titleAction(let menuId) = command, let viewId = model.savedViewId,
           let view = views.first(where: { $0.id == viewId }) {
            switch menuId {
            case TicketsNav.svRename: model.savedViewSheet = .rename(view)
            case TicketsNav.svSaveAs: model.savedViewSheet = .create(initialName: "Copy of \(view.name)", query: view.query)
            case TicketsNav.svCopyLink:
                let path = TicketsLogic.savedViewHref(id: view.id, query: view.query, project: currentProject)
                context.copyToClipboard(context.resolvedURL(path)?.absoluteString ?? path)
                context.showToast(ToastItemModel(id: "sv.link.\(view.id)", title: "View link copied", tone: .success))
            case TicketsNav.svDelete: model.pendingDeleteView = view
            default: break
            }
            return
        }
        let navId = model.layout == .board ? TicketsNav.boardNavId : TicketsNav.listNavId
        guard let action = TicketsNav.action(for: command, navigatorId: navId, project: currentProject) else { return }
        switch action {
        case .open(let href, let newTab): newTab ? context.openInNewTab(href) : context.navigate(href)
        case .project(let key): model.setProject(key)
        case .agent(let handle): model.agent = handle
        case .search(let q): model.searchText = q
        case .selectQueue(let q): model.layout = .list; model.selectQueue(q)
        case .selectEpic(let id): model.epicId = id ?? ""; model.savedViewId = nil
        case .openEpicDetail(let id):
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            context.navigate("/epics/\(escaped)")
        case .openEpics:
            model.layout = .epics
            context.navigate(TicketsLogic.layoutSwitchHref(to: .epics, current: model.currentLayoutQuery(project: currentProject, epic: nil, assignee: nil)))
        case .openSavedView(let id, let newTab):
            guard let view = views.first(where: { $0.id == id }) else { return }
            if newTab {
                context.openInNewTab(TicketsLogic.savedViewHref(id: view.id, query: view.query, project: currentProject))
            } else {
                model.layout = .list
                model.applyQueryDict(TicketsLogic.parseQueryString(view.query), svId: view.id)
            }
        case .saveSavedView:
            let query = TicketsLogic.normalizedViewQuery(model.currentViewParams(
                epic: model.epicId.isEmpty ? nil : model.epicId,
                assignee: model.agent.isEmpty ? nil : model.agent,
                status: model.statusFilter,
                freeQuery: nil
            ))
            model.savedViewSheet = .create(initialName: "", query: query)
        case .renameSavedView(let id):
            if let view = views.first(where: { $0.id == id }) { model.savedViewSheet = .rename(view) }
        case .saveAsSavedView(let id):
            if let view = views.first(where: { $0.id == id }) { model.savedViewSheet = .create(initialName: "Copy of \(view.name)", query: view.query) }
        case .copySavedViewLink(let id):
            if let view = views.first(where: { $0.id == id }) {
                let path = TicketsLogic.savedViewHref(id: view.id, query: view.query, project: currentProject)
                context.copyToClipboard(context.resolvedURL(path)?.absoluteString ?? path)
                context.showToast(ToastItemModel(id: "sv.link.\(view.id)", title: "View link copied", tone: .success))
            }
        case .deleteSavedView(let id): model.pendingDeleteView = views.first { $0.id == id }
        case .switchLayout(let target):
            let href = TicketsLogic.layoutSwitchHref(to: target, current: model.currentLayoutQuery(project: currentProject, epic: model.epicId.isEmpty ? nil : model.epicId, assignee: model.agent.isEmpty ? nil : model.agent))
            model.layout = target
            context.navigate(href)
        case .primaryAction:
            context.navigate(model.layout == .epics ? "/epics/new" : TicketsLogic.newTicketHref(project: currentProject, epic: model.epicId.isEmpty ? nil : model.epicId))
        case .startReady:
            let tickets = context.store.entry(API.listTickets(project: currentProject, view: .all)).data?.tickets ?? []
            model.dispatchKeys = TicketsLogic.readyDispatchKeys(in: tickets)
        case .groupBy(let g): model.groupBy = g
        case .density(let d): model.setDensity(d)
        case .toggleShowCanceled: model.showCanceled.toggle()
        case .toggleBlockedOnly: model.boardBlockedOnly.toggle()
        case .openSpaceSettings(let projKey):
            let proj = boot?.projects.first { $0.key == projKey }
            context.navigate(proj?.spaceId.map { "/spaces/\($0)" } ?? "/spaces/new?work=1")
        }
    }

    // MARK: - Small UI Helpers

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: theme.pointSize(.small), weight: active ? .semibold : .regular))
                .foregroundStyle(active ? theme.palette.accent : theme.palette.secondaryText)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(active ? theme.palette.accent.opacity(0.12) : theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? theme.palette.accent.opacity(0.5) : theme.palette.border))
        }
        .buttonStyle(.plain)
    }

    private func toolbarChipLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: theme.pointSize(.small)))
        }
        .foregroundStyle(theme.palette.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border))
    }

    @ViewBuilder
    private func menuOptionLabel(_ title: String, checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func emptyState<Actions: View>(title: String, subtitle: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: theme.pointSize(.title), weight: .semibold)).foregroundStyle(theme.palette.text)
            Text(subtitle).font(.system(size: theme.pointSize(.body))).foregroundStyle(theme.palette.secondaryText)
            actions().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct ModifierKeyTracker: ViewModifier {
    @Binding var modifiers: EventModifiers
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onModifierKeysChanged(mask: [.shift, .command]) { _, new in modifiers = new }
        #else
        content
        #endif
    }
}

private struct SavedViewEditorSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let sheet: TicketsModel.SavedViewSheet
    let epics: [API.Epic]
    let close: () -> Void

    @State private var name = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        let isRename: Bool = if case .rename = sheet { true } else { false }
        let query: String = switch sheet {
        case .create(_, let q): q
        case .rename(let view): view.query
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(isRename ? "Rename saved view" : "Save view")
                .vesperText(.heading, theme)

            TextField("View name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: theme.pointSize(.body)))
                .onSubmit { Task { await save() } }

            Text(TicketsLogic.describeViewQuery(query) { id in epics.first { $0.id == id }?.name })
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).buttonStyle(.vesper())
                Button(isRename ? "Save name" : "Save view") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.vesper(.primary))
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(theme.palette.surface)
        .onAppear {
            switch sheet {
            case .create(let initialName, _): name = initialName
            case .rename(let view): name = view.name
            }
        }
    }

    @MainActor
    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            switch sheet {
            case .create(_, let query):
                _ = try await context.store.mutate(
                    API.createSavedView(body: API.SavedViewInput(name: trimmed, query: query)),
                    invalidating: QueryInvalidation(resources: ["saved-views"])
                )
            case .rename(let view):
                _ = try await context.store.mutate(
                    API.updateSavedView(id: view.id, body: API.SavedViewPatch(name: trimmed)),
                    invalidating: QueryInvalidation(resources: ["saved-views"])
                )
            }
            close()
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
