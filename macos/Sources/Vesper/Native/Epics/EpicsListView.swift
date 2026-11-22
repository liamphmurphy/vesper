import SwiftUI
import VesperCore

/// Pure-SwiftUI Epics list screen (standalone `/epics` or embedded in `EpicsLayoutSlot`).
/// Zero AppKit imports.
struct EpicsListView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    var embeddedProject: String? = nil
    var embedded: Bool = false

    @State private var filters = EpicsLogic.Filters()
    @State private var projectFilter: String? = nil
    @State private var search = ""
    @State private var selectedEpicId: String? = nil
    @State private var showCreateSheet = false
    @State private var planProjectKey = ""
    @State private var planGoal = ""
    @State private var watched: [QueryKey] = []

    private static let epicsRequest = API.listEpicOverviews()
    private static let bootstrapRequest = API.getBootstrap()

    var body: some View {
        let epicsEntry = context.store.entry(Self.epicsRequest)
        let bootEntry = context.store.entry(Self.bootstrapRequest)
        let allEpics = epicsEntry.data?.epics ?? []
        let projects = bootEntry.data?.projects ?? []
        let effectiveProject = embedded ? embeddedProject : projectFilter
        let inProject = EpicsLogic.filter(allEpics, status: .all, health: .any, project: effectiveProject)
        let counts = EpicsLogic.statusCounts(inProject)
        let filtered = EpicsLogic.sort(
            EpicsLogic.filter(inProject, status: filters.status, health: filters.health, search: search),
            by: filters.sort
        )
        let groups = EpicsLogic.groupByProject(filtered)
        let today = EpicsLogic.todayYMD()

        VStack(alignment: .leading, spacing: 0) {
            filterBar(counts: counts, shownCount: filtered.count, projects: projects, effectiveProject: effectiveProject)
            Divider().overlay(theme.palette.border)

            if let error = epicsEntry.error, epicsEntry.data == nil {
                QueryErrorView(message: "Couldn\u{2019}t load epics: \(error.userMessage)") {
                    Task { await context.store.refetch(Self.epicsRequest) }
                }
            } else if epicsEntry.data == nil && epicsEntry.isFetching {
                VStack(spacing: 10) {
                    SkeletonBar(height: 56)
                    SkeletonBar(height: 56)
                    SkeletonBar(height: 56)
                }
                .padding(20)
            } else if inProject.isEmpty {
                emptyView(
                    title: "No epics here yet",
                    subtitle: "Epics and their objectives appear here once planned in a space.",
                    actionTitle: "Plan an epic"
                ) {
                    openCreateSheet(projects: projects, effectiveProject: effectiveProject)
                }
            } else if filtered.isEmpty {
                emptyView(
                    title: "No epics match",
                    subtitle: "Try clearing the status, health, or search filters.",
                    actionTitle: "Clear filters"
                ) {
                    filters = EpicsLogic.Filters(status: .all, health: .any, sort: filters.sort)
                    search = ""
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("EPICS")
                                .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(theme.palette.tertiaryText)
                            Text("\(filtered.count)")
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                .foregroundStyle(theme.palette.tertiaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        ForEach(filtered, id: \.epic.id) { item in
                            EpicSummaryRowView(
                                overview: item,
                                today: today,
                                selected: selectedEpicId == item.epic.id,
                                onOpen: { newTab in
                                    let href = EpicsLogic.epicDetailHref(item.epic.id)
                                    newTab ? context.openInNewTab(href) : context.navigate(href)
                                },
                                onSelect: { selectedEpicId = item.epic.id },
                                onCopyLink: {
                                    context.copyToClipboard(EpicsLogic.epicDetailHref(item.epic.id))
                                    context.showToast(ToastItemModel(id: "epic.copy", title: "Epic link copied", tone: .success))
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showCreateSheet) {
            createEpicSheet(projects: projects)
        }
        .task(id: context.match) {
            syncFromRoute()
            observeQueries()
            if !embedded {
                if let legacy = context.match.query["epic"], !legacy.isEmpty {
                    context.navigate(EpicsLogic.epicDetailHref(legacy))
                }
            }
        }
        .onChange(of: allEpics) { _, _ in
            publishChromeIfStandalone(
                projects: projects,
                inProject: inProject,
                counts: counts,
                groups: groups,
                loading: epicsEntry.isFetching
            )
        }
        .onChange(of: filters) { _, _ in
            publishChromeIfStandalone(
                projects: projects,
                inProject: inProject,
                counts: counts,
                groups: groups,
                loading: epicsEntry.isFetching
            )
        }
        .onChange(of: search) { _, _ in
            publishChromeIfStandalone(
                projects: projects,
                inProject: inProject,
                counts: counts,
                groups: groups,
                loading: epicsEntry.isFetching
            )
        }
        .onChange(of: selectedEpicId) { _, _ in
            publishChromeIfStandalone(
                projects: projects,
                inProject: inProject,
                counts: counts,
                groups: groups,
                loading: epicsEntry.isFetching
            )
        }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
    }

    // MARK: - Subviews

    private func filterBar(
        counts: EpicsLogic.StatusCounts,
        shownCount: Int,
        projects: [API.Project],
        effectiveProject: String?
    ) -> some View {
        let p = theme.palette
        return HStack(spacing: 10) {
            Picker("Status", selection: $filters.status) {
                ForEach(EpicsLogic.StatusFilter.allCases, id: \.self) { status in
                    Text("\(status.label) \(counts[status])").tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Health", selection: $filters.health) {
                ForEach(EpicsLogic.HealthFilter.allCases, id: \.self) { health in
                    Text(health.label).tag(health)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            if !embedded {
                Picker("Space", selection: Binding(
                    get: { projectFilter ?? "" },
                    set: { projectFilter = $0.isEmpty ? nil : $0 }
                )) {
                    Text("All spaces").tag("")
                    ForEach(projects.filter { !$0.archived }, id: \.key) { proj in
                        Text(proj.name).tag(proj.key)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            TextField("Filter epics…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Spacer()

            Text("\(shownCount) \(shownCount == 1 ? "epic" : "epics")")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(p.tertiaryText)

            Picker("Sort", selection: $filters.sort) {
                ForEach(EpicsLogic.Sort.allCases, id: \.self) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Button {
                openCreateSheet(projects: projects, effectiveProject: effectiveProject)
            } label: {
                Label("New epic", systemImage: "plus")
            }
            .buttonStyle(.vesper(.primary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func emptyView(title: String, subtitle: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: SidebarIcons.symbolName("epics"))
                .font(.system(size: 26))
                .foregroundStyle(theme.palette.tertiaryText)
            Text(title)
                .vesperText(.heading, theme)
                .foregroundStyle(theme.palette.text)
            Text(subtitle)
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.secondaryText)
            Button(actionTitle, action: action)
                .buttonStyle(.vesper(.primary))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func createEpicSheet(projects: [API.Project]) -> some View {
        let activeProjects = projects.filter { !$0.archived }
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 14) {
            Text("Plan a new epic")
                .vesperText(.title, theme)
                .foregroundStyle(p.text)
            Text("Epics are created through a planning session with your agent so objectives, criteria, and tickets stay linked.")
                .vesperText(.small, theme)
                .foregroundStyle(p.secondaryText)

            VStack(alignment: .leading, spacing: 6) {
                Text("Space")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                Picker("Space", selection: $planProjectKey) {
                    ForEach(activeProjects, id: \.key) { proj in
                        Text(proj.name).tag(proj.key)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Working title or goal (optional)")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                TextField("e.g. Native Epics & Reports", text: $planGoal)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { showCreateSheet = false }
                    .buttonStyle(.vesper())
                Button("Open planning session") {
                    showCreateSheet = false
                    var items: [URLQueryItem] = []
                    if !planProjectKey.isEmpty { items.append(URLQueryItem(name: "project", value: planProjectKey)) }
                    let trimmed = planGoal.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { items.append(URLQueryItem(name: "goal", value: trimmed)) }
                    let query = APIQuery.encode(items)
                    context.navigate(query.isEmpty ? "/plans" : "/plans?\(query)")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(planProjectKey.isEmpty && !activeProjects.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Wiring

    private func openCreateSheet(projects: [API.Project], effectiveProject: String?) {
        planProjectKey = effectiveProject ?? projects.first(where: { !$0.archived })?.key ?? ""
        planGoal = ""
        showCreateSheet = true
    }

    private func syncFromRoute() {
        guard !embedded else { return }
        filters = EpicsLogic.parseFilters(query: context.match.query)
        let proj = context.match.query["project"]
        projectFilter = (proj?.isEmpty == false) ? proj : nil
    }

    private func observeQueries() {
        let requests: [QueryKey] = [Self.epicsRequest.key, Self.bootstrapRequest.key]
        if watched != requests {
            for key in watched { context.store.stopObserving(key) }
            context.store.observe(Self.epicsRequest)
            context.store.observe(Self.bootstrapRequest)
            watched = requests
        }
        context.store.load(Self.epicsRequest)
        context.store.load(Self.bootstrapRequest)
    }

    private func publishChromeIfStandalone(
        projects: [API.Project],
        inProject: [API.EpicOverview],
        counts: EpicsLogic.StatusCounts,
        groups: [EpicsLogic.ProjectGroup],
        loading: Bool
    ) {
        guard !embedded else { return }
        let nav = EpicsLogic.epicsNavModel(
            project: projectFilter,
            projects: projects,
            filters: filters,
            counts: counts,
            atRiskCount: EpicsLogic.atRiskCount(inProject),
            groups: groups,
            selectedEpicId: selectedEpicId ?? groups.first?.epics.first?.epic.id,
            search: search,
            loading: loading
        )
        let selected = inProject.first { $0.epic.id == selectedEpicId }
        let inspector: InspectorModel? = selected.map { item in
            let section = InspectorSection(
                id: "overview",
                title: item.epic.name,
                items: [
                    InspectorItem(id: "space", kind: .fact, label: "Space", value: item.project.name),
                    InspectorItem(id: "health", kind: .fact, label: "Health", value: EpicsLogic.healthLabel(item.epic.health), tone: EpicsLogic.healthTone(item.epic.health)),
                    InspectorItem(id: "progress", kind: .progress, label: "Tickets", value: "\(item.counts.done)/\(item.counts.total)", fraction: EpicsLogic.ratio(done: item.counts.done, total: item.counts.total)),
                    InspectorItem(id: "owner", kind: .fact, label: "Owner", value: item.owner?.name ?? "Unassigned"),
                    InspectorItem(id: "target", kind: .fact, label: "Target", value: item.targetDate.map(EpicsLogic.formatDueDate) ?? "No target date"),
                    InspectorItem(id: "open_action", kind: .actions, actions: [
                        InspectorAction(id: EpicsLogic.openEpicActionId, label: "Open epic"),
                    ]),
                ]
            )
            return InspectorModel(
                id: "epics-list",
                open: false,
                activeTabId: "context",
                tabs: [
                    InspectorTab(id: "context", label: "Context", icon: "sidebar", kind: .native, sections: [section]),
                    InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion),
                ],
                companion: CompanionContext(path: context.match.path)
            )
        }
        context.chrome = NativeChrome(
            title: "Epics",
            subtitle: projectFilter.flatMap { key in projects.first { $0.key == key }?.name },
            toolbarItems: [
                ShellToolbarItem(id: "epics.new", label: "New epic", icon: "plus", kind: .button, accent: true, showsLabel: true),
            ],
            inspector: inspector,
            navigator: nav
        )
        context.onCommand = { command in
            switch command {
            case .toolbarAction("epics.new", _):
                openCreateSheet(projects: projects, effectiveProject: projectFilter)
            case .inspectorAction(_, EpicsLogic.openEpicActionId, _, _):
                if let id = selectedEpicId { context.navigate(EpicsLogic.epicDetailHref(id)) }
            case .navFilter(EpicsLogic.epicsNavId, EpicsLogic.statusFilterId, let value, _):
                if let s = EpicsLogic.StatusFilter(rawValue: value) { filters.status = s }
            case .navFilter(EpicsLogic.epicsNavId, EpicsLogic.healthFilterId, let value, _):
                if let h = EpicsLogic.HealthFilter(rawValue: value) { filters.health = h }
            case .navFilter(EpicsLogic.epicsNavId, WorkNav.spaceFilter, let value, _):
                projectFilter = value.isEmpty ? nil : value
            case .navSearch(EpicsLogic.epicsNavId, WorkNav.searchId, let value):
                search = value
            case .navPicker(EpicsLogic.epicsNavId, WorkNav.viewPicker, let value):
                if value == "activity" { context.navigate("/work") }
            case .navActivate(EpicsLogic.epicsNavId, let itemId, let newTab):
                selectedEpicId = itemId
                if newTab { context.openInNewTab(EpicsLogic.epicDetailHref(itemId)) }
                else { context.navigate(EpicsLogic.epicDetailHref(itemId)) }
            default:
                break
            }
        }
    }
}

/// One epic row: health dot, name & objective, stacked progress bar, points/criteria, owner, target.
private struct EpicSummaryRowView: View {
    @Environment(\.vesperTheme) private var theme
    let overview: API.EpicOverview
    let today: String
    let selected: Bool
    let onOpen: (_ newTab: Bool) -> Void
    let onSelect: () -> Void
    let onCopyLink: () -> Void

    @State private var hovered = false

    var body: some View {
        let p = theme.palette
        let epic = overview.epic
        let counts = overview.counts
        let pct = Int((EpicsLogic.ratio(done: epic.pointsDone, total: epic.pointsTotal) * 100).rounded())
        let overdue = EpicsLogic.isOverdue(overview, today: today)
        let running = counts.inProgress + counts.inReview
        let open = counts.todo + counts.backlog

        HStack(spacing: 14) {
            Circle()
                .fill(healthColor(epic.health))
                .frame(width: 8, height: 8)
                .help(EpicsLogic.healthLabel(epic.health))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(epic.name)
                        .font(.system(size: theme.pointSize(.body) + 1, weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    if epic.status == .done {
                        TonePill(label: "Done", tone: "done")
                    }
                    TonePill(label: EpicsLogic.healthLabel(epic.health), tone: EpicsLogic.healthPillTone(epic.health))
                }
                Text("\(overview.project.name) · \(overview.objective.isEmpty ? "No objective yet." : overview.objective)")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                EpicStackedBar(segments: [
                    (counts.done, theme.swiftUIColor("state-done", fallback: .green)),
                    (running, theme.swiftUIColor("state-progress", fallback: p.accent)),
                    (open, theme.swiftUIColor("track", fallback: p.border)),
                ], height: 6)

                HStack {
                    Text(epic.pointsTotal > 0 ? "\(epic.pointsDone)/\(epic.pointsTotal) pts · \(pct)%" : "No estimates")
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                    Spacer()
                    if epic.criteriaTotal > 0 {
                        Text("\(epic.criteriaDone)/\(epic.criteriaTotal) met")
                            .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                    } else if epic.status == .open {
                        Text("No criteria")
                            .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                            .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                    }
                }
            }
            .frame(width: 210)

            Text("\(epic.ticketsOpen) open")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(p.secondaryText)
                .frame(width: 66, alignment: .trailing)

            Text(overview.owner?.name ?? "No owner")
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(overview.owner != nil ? p.secondaryText : p.tertiaryText)
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            Text(overview.targetDate.map { "\(overdue ? "Overdue · " : "Target ")\(EpicsLogic.formatDueDate($0))" } ?? "No target")
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(overdue ? theme.swiftUIColor("pill-blocked-fg", fallback: .red) : p.tertiaryText)
                .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            (selected ? p.selected : (hovered ? p.hover : Color.clear)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            onSelect()
            onOpen(false)
        }
        .contextMenu {
            Button("Open epic") { onOpen(false) }
            Button("Open in new tab") { onOpen(true) }
            Divider()
            Button("Copy link", action: onCopyLink)
        }
    }

    private func healthColor(_ health: API.Epic.HealthValue) -> Color {
        switch health {
        case .onTrack: theme.swiftUIColor("state-done", fallback: .green)
        case .atRisk: theme.swiftUIColor("state-human", fallback: .orange)
        case .offTrack: theme.swiftUIColor("state-blocked", fallback: .red)
        default: theme.palette.tertiaryText
        }
    }
}

/// Reusable horizontal stacked progress bar for epics.
struct EpicStackedBar: View {
    @Environment(\.vesperTheme) private var theme
    let segments: [(value: Int, color: Color)]
    var height: CGFloat = 6

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + max(0, $1.value) })
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.value > 0 {
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: max(2, geo.size.width * (CGFloat(seg.value) / CGFloat(total))))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.swiftUIColor("track", fallback: theme.palette.border))
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}
