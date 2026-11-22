import AppKit
import SwiftUI
import VesperCore

/// Work's per-tab state: the filters the URL opened it with, the filter box, how many pages of
/// finished runs are loaded, and the clock "today" is measured against.
@MainActor
@Observable
final class WorkModel {
    /// "" is All spaces. A URL's `?project=` wins and is remembered; the web keeps its own in the page's storage.
    var project = ""
    /// Persona handle; "" is All personas.
    var agent = ""
    var filter: WorkLogic.ActivityFilter = .all
    /// The old `?done=hide`: only live runs are loaded until another View is picked.
    var hideDone = false
    var search = ""
    var pages = 1
    var now = Date()
    /// Ready tickets the Start ready sheet dispatches; empty while it's closed.
    var dispatchKeys: [String] = []
    /// The Chat companion beside Work, folded by default as on the web.
    var companionOpen = UserDefaults.standard.bool(forKey: WorkModel.companionKey) {
        didSet { UserDefaults.standard.set(companionOpen, forKey: Self.companionKey) }
    }

    static let projectKey = "VesperNativeWorkProject"
    static let companionKey = "VesperNativeWorkCompanionOpen"

    /// Takes the filters from the URL (web work-screen.tsx reads them from its search params).
    func seed(_ query: [String: String]) {
        if let project = query["project"] {
            setProject(project)
        } else {
            self.project = UserDefaults.standard.string(forKey: Self.projectKey) ?? ""
        }
        agent = query["agent"] ?? ""
        filter = WorkLogic.ActivityFilter(filter: query["filter"], legacyDone: query["done"])
        hideDone = query["done"] == "hide"
        search = query["q"] ?? ""
        pages = 1
    }

    func setProject(_ key: String) {
        project = key
        pages = 1
        UserDefaults.standard.set(key, forKey: Self.projectKey)
    }
}

/// /work (and the old bare /runs): Work's Runs view. The sidebar lists runs by View (All, Needs you,
/// Running & queued, Failed today) under the Work header; the page is the Overview: telemetry
/// strip, Needs you, Running now, Ready to start and Finished today (web app/(app)/work). A run
/// opens its own page (/runs/:id), which is still the web's.
struct WorkScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var model = WorkModel()
    @State private var watched: [QueryKey] = []

    static let runsPage = 50
    private static let inbox = API.listInbox()
    private static let runner = API.getRunnerStatus()
    private static let bootstrap = API.getBootstrap()
    private static let personas = API.listPersonas()

    private var projectParam: String? { model.project.isEmpty ? nil : model.project }
    private var agentParam: String? { model.agent.isEmpty ? nil : model.agent }
    private var live: APIRequest<API.ListRunsResponse> { API.listRuns(state: .live, agent: agentParam, project: projectParam) }
    private var pageCount: Int { model.hideDone ? 0 : model.pages }
    private func page(_ index: Int) -> APIRequest<API.ListRunsResponse> {
        API.listRuns(state: .all, agent: agentParam, project: projectParam, offset: index * Self.runsPage)
    }
    private var costs: APIRequest<API.CostReport> {
        let range = WorkLogic.presetRange(days: 7, now: model.now)
        return API.getCosts(from: range.from, to: range.to, project: projectParam)
    }
    private var tickets: APIRequest<API.TicketList> { API.listTickets(project: projectParam, view: .all) }

    var body: some View {
        let store = context.store
        let liveEntry = store.entry(live)
        let pages = (0..<pageCount).map { store.entry(page($0)) }
        let runs = (liveEntry.data?.runs ?? []) + pages.flatMap { $0.data?.runs ?? [] }
        let needs = WorkLogic.needs(store.entry(Self.inbox).data?.items ?? [], project: projectParam, agent: agentParam)
        let runner = store.entry(Self.runner).data
        let costReport = store.entry(costs).data
        let ticketsEntry = store.entry(tickets)
        let data = WorkOverviewData(
            runs: runs, needs: needs, runner: runner, costs: costReport, tickets: ticketsEntry.data?.tickets,
            project: projectParam, filter: model.filter, now: model.now
        )

        WorkOverview(data: data, model: model)
            .onChange(of: chrome(runs: runs, needs: needs, liveEntry: liveEntry, pages: pages, runner: runner, costs: costReport),
                      initial: true) { _, chrome in context.chrome = chrome }
            .task(id: context.match) {
                if let target = WorkLogic.redirect(query: context.match.query) {
                    context.navigate(target)
                    return
                }
                model.seed(context.match.query)
            }
            .task(id: watchKeys) { watch() }
            .task { await tick() }
            .onAppear {
                let model = model, context = context
                context.onCommand = { command in Self.handle(command, model: model, context: context) }
            }
            .onDisappear {
                for key in watched { context.store.stopObserving(key) }
                watched = []
            }
            .sheet(isPresented: Binding(get: { !model.dispatchKeys.isEmpty }, set: { if !$0 { model.dispatchKeys = [] } })) {
                WorkDispatchSheet(keys: model.dispatchKeys) { model.dispatchKeys = [] }
                    .environment(context)
                    .environment(\.vesperTheme, theme)
            }
    }

    // MARK: Data

    /// Everything the screen shows, so a filter change observes the new queries and drops the old.
    private var watchKeys: [QueryKey] {
        [live.key, costs.key, tickets.key] + (0..<pageCount).map { page($0).key }
    }

    private func watch() {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        func start<V: Sendable>(_ request: APIRequest<V>) -> QueryKey {
            store.observe(request)
            store.load(request)
            return request.key
        }
        watched = [
            start(live), start(costs), start(tickets), start(Self.inbox), start(Self.runner),
            start(Self.bootstrap), start(Self.personas),
        ] + (0..<pageCount).map { start(page($0)) }
    }

    /// The web polls live runs every 10s, the runner every 15s (2s while it's offline) and spend every
    /// 30s on top of the /events hints; "today" moves with the same clock.
    private func tick() async {
        var elapsed = 0
        while !Task.isCancelled {
            let offline = context.store.entry(Self.runner).data.map { !$0.online } ?? false
            let step = offline ? 2 : 5
            try? await Task.sleep(for: .seconds(step))
            guard !Task.isCancelled else { return }
            elapsed += step
            model.now = Date()
            if offline || elapsed % 15 == 0 { _ = context.store.refetchInBackground(Self.runner) }
            if elapsed % 10 == 0 { _ = context.store.refetchInBackground(live) }
            if elapsed % 30 == 0 { _ = context.store.refetchInBackground(costs) }
        }
    }

    // MARK: Chrome

    private func chrome(runs: [API.Run], needs: [API.InboxItem], liveEntry: QueryEntry<API.ListRunsResponse>,
                        pages: [QueryEntry<API.ListRunsResponse>], runner: API.RunnerStatus?, costs: API.CostReport?) -> NativeChrome {
        let shownNeeds = needs.filter { WorkLogic.matchesItem($0, model.search) }
        let lists = WorkLogic.activityLists(runs: runs, shownNeeds: shownNeeds, search: model.search, filter: model.filter, now: model.now)
        let boot = context.store.entry(Self.bootstrap).data
        let personas = context.store.entry(Self.personas).data?.personas ?? []
        let base = context.store.client?.baseURL
        let avatar = { (agent: API.AgentRef) in
            WorkNav.avatar(for: agent, personas: personas, base: base) { theme.colors["agent-\($0)"] }
        }
        let firstPage = pages.first
        let loading = (liveEntry.data == nil && liveEntry.error == nil)
            || (firstPage.map { $0.data == nil && $0.error == nil } ?? false)
        let failure = liveEntry.data == nil ? liveEntry.error : firstPage?.data == nil ? firstPage?.error : nil

        var input = WorkNav.Input()
        input.project = projectParam
        input.projects = (boot?.projects ?? []).map { ($0.key, $0.name, $0.archived) }
        input.agents = (boot?.agents ?? []).map { ($0.handle, $0.name) }
        input.agent = model.agent
        input.activityCount = needs.count + runs.filter { ["running", "queued"].contains($0.state.rawValue) }.count
        input.search = model.search
        input.filter = model.filter
        input.counts = lists.counts
        input.needs = lists.nonRunNeeds.map { WorkNav.NeedsRow(id: $0.id, title: $0.title, trailing: APIDate.waited($0.createdAt, now: model.now)) }
        input.groups = lists.groups.map { group in
            WorkNav.Group(label: group.label, runs: group.runs.map { run in
                let dot = WorkLogic.runDot(run, needsYou: WorkLogic.isRunNeedsYou(run, needsRunIds: lists.needsRunIds))
                return WorkNav.RunRow(id: run.id, title: WorkLogic.runTitle(run), avatar: avatar(run.agent),
                                      trailing: WorkLogic.compactRunTime(run, dot: dot, now: model.now), dot: dot)
            })
        }
        input.loading = loading
        input.error = failure?.userMessage
        input.hasMore = model.filter == .all && (pages.last?.data?.hasMore ?? false)
        input.loadingMore = pages.last?.isFetching ?? false
        input.statusLine = (WorkLogic.statusText(runner: runner, costs: costs), WorkLogic.reportsHref(project: projectParam))

        return NativeChrome(
            title: "Runs",
            toolbarItems: needs.isEmpty ? [] : [
                ShellToolbarItem(id: Self.needsToolbarItem, label: "Needs you · \(needs.count)", icon: "inbox", kind: .button,
                                 accent: true, showsLabel: true),
            ],
            inspector: InspectorModel(
                id: "work", open: model.companionOpen, activeTabId: "chat",
                tabs: [InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion)],
                companion: CompanionContext(path: context.match.path)
            ),
            navigator: WorkNav.model(input)
        )
    }

    static let needsToolbarItem = "work.needs"

    // MARK: Commands

    @MainActor
    static func handle(_ command: NativeCommand, model: WorkModel, context: NativeScreenContext) {
        switch command {
        case .toolbarAction(itemId: needsToolbarItem, _):
            model.filter = .needsYou
            model.hideDone = false
            return
        case .inspectorVisibility(let open):
            model.companionOpen = open
            return
        case .inspectorSelectTab:
            model.companionOpen = true
            return
        default:
            break
        }
        guard let action = WorkNav.action(for: command, project: model.project) else { return }
        switch action {
        case .open(let href, let newTab):
            newTab ? context.openInNewTab(href) : context.navigate(href)
        case .project(let key):
            model.setProject(key)
        case .agent(let handle):
            model.agent = handle
            model.pages = 1
        case .search(let query):
            model.search = query
        case .filter(let filter):
            model.filter = filter
            model.hideDone = false
        case .overview:
            break
        case .loadMore:
            model.pages += 1
        case .retry:
            let store = context.store
            let project = model.project.isEmpty ? nil : model.project, agent = model.agent.isEmpty ? nil : model.agent
            _ = store.refetchInBackground(API.listRuns(state: .live, agent: agent, project: project))
            _ = store.refetchInBackground(API.listRuns(state: .all, agent: agent, project: project, offset: 0))
        case .openRun(let id, let newTab):
            let href = "/runs/\(id)"
            newTab ? context.openInNewTab(href) : context.navigate(href)
        case .openNeeds(let id, let newTab):
            guard let item = context.store.entry(inbox).data?.items.first(where: { $0.id == id }) else { return }
            let href = WorkLogic.itemHref(item)
            if InboxLogic.isExternalHref(href) {
                context.openExternal(href)
            } else {
                newTab ? context.openInNewTab(href) : context.navigate(href)
            }
        }
    }
}

private extension QueryStore {
    /// Starts a refetch without waiting for it (timers and the Retry row).
    @discardableResult
    func refetchInBackground<V: Sendable>(_ request: APIRequest<V>) -> Task<Void, Never> {
        Task { _ = await refetch(request) }
    }
}
