import SwiftUI
import VesperCore

/// Per-tab state for `RunDetailScreen` (`/runs/:id`): sidebar filters, view mode/anchor,
/// collapsible Context dock, live clock, and incrementally paged run events.
@MainActor
@Observable
final class RunDetailModel {
    var runId = ""
    var mode: RunsLogic.ViewMode = .thread
    var anchor: RunsLogic.Anchor?

    // Sidebar list filters (mirrored from WorkModel/runs.ts).
    var project = ""
    var agent = ""
    var hideDone = false
    var search = ""
    var pages = 1
    var now = Date()

    // Trace tab lifted state (survives tab switches cleanly).
    var traceFilter: RunThreadLogic.TraceFilter = .all
    var traceSearch = ""

    // Collapsible Context dock & Inspector Chat companion.
    var contextDockOpen: Bool = {
        if UserDefaults.standard.object(forKey: RunDetailModel.contextDockKey) != nil {
            return UserDefaults.standard.bool(forKey: RunDetailModel.contextDockKey)
        }
        return true
    }() {
        didSet { UserDefaults.standard.set(contextDockOpen, forKey: Self.contextDockKey) }
    }
    var inspectorOpen = false
    var inspectorTabId = "chat"

    // Incrementally paged events across runs > 1,000 events.
    var extraEvents: [String: [API.RunEvent]] = [:]

    // Header control state.
    var controlBusy = false
    var controlError: String?
    var confirmCancel = false

    static let contextDockKey = "VesperNativeRunContextDockOpen"
    static let projectKey = "VesperNativeWorkProject"

    func seed(_ match: NativeRouteMatch) {
        let nextId = match.params["id"] ?? ""
        let switchedRun = nextId != runId
        runId = nextId

        if let projectParam = match.query["project"] {
            project = projectParam
            UserDefaults.standard.set(projectParam, forKey: Self.projectKey)
        } else if project.isEmpty {
            project = UserDefaults.standard.string(forKey: Self.projectKey) ?? ""
        }
        if let agentParam = match.query["agent"] {
            agent = agentParam
        }
        if let doneParam = match.query["done"] {
            hideDone = doneParam == "hide"
        }

        let parsedAnchor = RunsLogic.parseAnchor(match.query["anchor"])
        if let parsedAnchor {
            anchor = parsedAnchor
            mode = .trace
        } else if switchedRun || match.query["view"] != nil || match.query["tab"] != nil {
            anchor = nil
            mode = RunsLogic.pickViewMode(view: match.query["view"], tab: match.query["tab"], anchor: nil)
        }

        if switchedRun {
            controlError = nil
        }
    }

    func events(for detail: API.RunDetail) -> [API.RunEvent] {
        guard let extra = extraEvents[detail.run.id], !extra.isEmpty else {
            return detail.events
        }
        return RunsLogic.mergeEvents(existing: detail.events, incoming: extra)
    }
}

/// `/runs/:id`: standalone Runs sidebar via `RunsNav`, shared header with status/controls,
/// Thread / Trace / Graph (`RunGraphTabSlot`) / Files tabs, and collapsible Plan & Usage Context dock.
struct RunDetailScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var model = RunDetailModel()
    @State private var watched: [QueryKey] = []

    static let runsPage = 50
    private static let inboxRequest = API.listInbox()
    private static let runnerRequest = API.getRunnerStatus()
    private static let bootstrapRequest = API.getBootstrap()
    private static let personasRequest = API.listPersonas()
    private static let epicsRequest = API.listEpicOverviews()

    private var runId: String { context.match.params["id"] ?? "" }
    private var projectParam: String? { model.project.isEmpty ? nil : model.project }
    private var agentParam: String? { model.agent.isEmpty ? nil : model.agent }

    private var runRequest: APIRequest<API.RunDetail> { API.getRun(id: runId) }
    private var liveListRequest: APIRequest<API.ListRunsResponse> {
        API.listRuns(state: .live, agent: agentParam, project: projectParam)
    }
    private var listPageCount: Int { model.hideDone ? 0 : model.pages }
    private func listPageRequest(_ index: Int) -> APIRequest<API.ListRunsResponse> {
        API.listRuns(state: .all, agent: agentParam, project: projectParam, offset: index * Self.runsPage)
    }
    private var costsRequest: APIRequest<API.CostReport> {
        let range = WorkLogic.presetRange(days: 7, now: model.now)
        return API.getCosts(from: range.from, to: range.to, project: projectParam)
    }

    var body: some View {
        let store = context.store
        let detailEntry = store.entry(runRequest)
        let detail = detailEntry.data
        let run = detail?.run

        let childEntries = (detail?.childRuns ?? []).map { store.entry(API.getRun(id: $0.id)) }
        let childDetails = childEntries.compactMap(\.data)
        let grandchildren = childDetails.map(\.childRuns)

        let ticketKey = (run?.purpose == .ticket && !(run?.ticketKey ?? "").isEmpty) ? (run?.ticketKey ?? "") : ""
        let ticket = ticketKey.isEmpty ? nil : store.entry(API.getTicket(key: ticketKey)).data
        let epics = store.entry(Self.epicsRequest).data?.epics ?? []
        let epic = ticket?.epic.flatMap { ref in epics.first(where: { $0.epic.id == ref.id }) }

        let allEvents = detail.map { model.events(for: $0) } ?? []
        let childEvents = childDetails.map { model.events(for: $0) }

        // Sidebar queries.
        let liveEntry = store.entry(liveListRequest)
        let listPages = (0..<listPageCount).map { store.entry(listPageRequest($0)) }
        let sidebarRuns = (liveEntry.data?.runs ?? []) + listPages.flatMap { $0.data?.runs ?? [] }
        let inboxItems = store.entry(Self.inboxRequest).data?.items ?? []
        let needs = WorkLogic.needs(inboxItems, project: projectParam, agent: agentParam)
        let runner = store.entry(Self.runnerRequest).data
        let costs = store.entry(costsRequest).data

        let dockModel = detail.map {
            RunsLogic.buildContextDock(
                detail: $0,
                events: allEvents,
                ticket: ticket,
                epic: epic,
                grandchildren: grandchildren,
                now: model.now
            )
        }

        let chrome = buildChrome(
            detail: detail,
            dock: dockModel,
            sidebarRuns: sidebarRuns,
            needs: needs,
            liveEntry: liveEntry,
            listPages: listPages,
            runner: runner,
            costs: costs
        )

        contentBody(
            detailEntry: detailEntry,
            detail: detail,
            allEvents: allEvents,
            childEntries: childEntries,
            childDetails: childDetails,
            childEvents: childEvents,
            dockModel: dockModel,
            allNeeds: WorkLogic.needs(inboxItems, project: nil, agent: nil)
        )
        .onChange(of: chrome, initial: true) { _, nextChrome in
            context.chrome = nextChrome
        }
        .task(id: context.match) {
            model.seed(context.match)
        }
        .task(id: watchSignature(childIds: detail?.childRuns.map(\.id) ?? [], ticketKey: ticketKey, hasEpic: ticket?.epic != nil)) {
            syncWatches(childIds: detail?.childRuns.map(\.id) ?? [], ticketKey: ticketKey, hasEpic: ticket?.epic != nil)
        }
        .task(id: "\(runId):\(run.map { RunsLogic.isLive($0) } ?? true)") {
            await pollActiveRun(detail: detail)
        }
        .task(id: "\(model.project):\(model.agent)") {
            await pollSidebarTick()
        }
        .onAppear {
            let model = model
            let context = context
            context.onCommand = { command in
                Self.handleCommand(command, model: model, context: context)
            }
        }
        .onDisappear {
            for key in watched {
                context.store.stopObserving(key)
            }
            watched = []
        }
        .alert("Cancel \(run?.agent.name ?? "this agent")\u{2019}s run?", isPresented: $model.confirmCancel) {
            Button("Keep running", role: .cancel) {}
            Button("Cancel run", role: .destructive) {
                if let run { sendControl(runId: run.id, action: .cancel) }
            }
        } message: {
            Text("It stops now and can\u{2019}t be resumed.")
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func contentBody(
        detailEntry: QueryEntry<API.RunDetail>,
        detail: API.RunDetail?,
        allEvents: [API.RunEvent],
        childEntries: [QueryEntry<API.RunDetail>],
        childDetails: [API.RunDetail],
        childEvents: [[API.RunEvent]],
        dockModel: RunsLogic.ContextDockModel?,
        allNeeds: [API.InboxItem]
    ) -> some View {
        if detail == nil, let error = detailEntry.error {
            QueryErrorView(message: error.userMessage) {
                Task { _ = await context.store.refetch(runRequest) }
            }
        } else if let detail {
            let run = detail.run
            let files = RunFilesLogic.extractFiles(from: allEvents, childEvents: childEvents)
            let thread = RunThreadLogic.buildThread(detail: detail, events: allEvents)
            let tracePreview = RunThreadLogic.buildTrace(detail: detail, events: allEvents, childDetails: childDetails)
            let tabs = RunsLogic.viewTabs(
                traceCount: tracePreview.counts.all,
                fileCount: files.count,
                childRunCount: max(detail.childRuns.count, run.childCount ?? 0),
                mode: model.mode
            )

            VStack(spacing: 0) {
                if let controlError = model.controlError {
                    Text(controlError)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.14)))
                }

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        headerView(detail: detail, tabs: tabs)
                        Divider()
                        if model.mode != .thread {
                            RunActionBoxView(
                                detail: detail,
                                lastEventSeq: thread.lastEventSeq,
                                inThread: false,
                                onRefresh: refreshRun
                            )
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                            .frame(maxWidth: 820)
                            .frame(maxWidth: .infinity)
                        }
                        tabContent(
                            detail: detail,
                            allEvents: allEvents,
                            thread: thread,
                            childEntries: childEntries,
                            childDetails: childDetails,
                            files: files,
                            allNeeds: allNeeds
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if model.contextDockOpen, let dockModel {
                        Divider()
                        RunContextDockView(
                            dock: dockModel,
                            mode: model.mode,
                            onSelectMode: { next in
                                model.mode = model.mode == next ? .thread : next
                            }
                        )
                        .frame(width: 288)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                SkeletonBar(height: 22).frame(maxWidth: 420)
                SkeletonBar(height: 14).frame(maxWidth: 280)
                SkeletonBar(height: 140)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityLabel("Loading run")
        }
    }

    // MARK: - Header & Segmented Tabs

    private func headerView(detail: API.RunDetail, tabs: [RunsLogic.ViewTab]) -> some View {
        let run = detail.run
        let badge = RunsLogic.statusBadge(for: run)
        let cost = RunsLogic.costSummary(for: detail)
        let controls = RunsLogic.controlState(for: run)
        let workHref = RunsLogic.workHref(for: run)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let proj = run.projectKey, !proj.isEmpty {
                    Button(proj) {
                        context.navigate("/tickets?project=\(MarkdownSource.encodeURIComponent(proj))")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    Text("·").foregroundStyle(theme.palette.tertiaryText)
                }
                if run.purpose == .ticket, !run.ticketKey.isEmpty {
                    Button("\(run.ticketKey) \u{2197}") {
                        context.navigate("/tickets/\(MarkdownSource.encodeURIComponent(run.ticketKey))")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    Text("·").foregroundStyle(theme.palette.tertiaryText)
                } else if let workHref {
                    Button(run.purpose == .planning ? "Plan \u{2197}" : "Chat \u{2197}") {
                        context.navigate(workHref)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: theme.pointSize(.small)))
                    Text("·").foregroundStyle(theme.palette.tertiaryText)
                }
                Button("Run \(String(run.id.prefix(8)))") {
                    context.copyToClipboard(run.id)
                    context.showToast(ToastItemModel(id: "run.copy-id", title: "Copied run ID", tone: .success))
                }
                .buttonStyle(.plain)
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
                .help("Copy full run ID")

                Spacer()

                if controls.canResume {
                    Button(controls.resumeLabel) { sendControl(runId: run.id, action: .resume) }
                        .buttonStyle(.vesper(.approve))
                        .disabled(model.controlBusy)
                }
                if controls.canPause {
                    Button("Pause") { sendControl(runId: run.id, action: .pause) }
                        .buttonStyle(.vesper(.outline))
                        .disabled(model.controlBusy)
                }
                if controls.canRetry {
                    Button("Retry run") { sendControl(runId: run.id, action: .retry) }
                        .buttonStyle(.vesper(.primary))
                        .disabled(model.controlBusy)
                }
                if controls.canCancel {
                    Button("Stop") { model.confirmCancel = true }
                        .buttonStyle(.vesper(.danger))
                        .disabled(model.controlBusy)
                }
                Button {
                    model.contextDockOpen.toggle()
                } label: {
                    Label(model.contextDockOpen ? "Hide Context" : "Context", systemImage: "sidebar.right")
                }
                .buttonStyle(.vesper(.outline))
            }

            Text(WorkLogic.runTitle(run))
                .vesperText(.title, theme)
                .foregroundStyle(theme.palette.text)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    WorkPersonaAvatarView(
                        agent: run.agent,
                        size: 20,
                        state: RunsLogic.characterState(for: run),
                        active: RunsLogic.isLive(run)
                    )
                    Text(run.agent.name)
                        .font(.system(size: theme.pointSize(.body), weight: .medium))
                        .foregroundStyle(theme.palette.text)
                }
                TonePill(label: badge.label, tone: badge.tone)
                Text("·").foregroundStyle(theme.palette.tertiaryText)
                Text(APIDate.duration(since: run.startedAt, until: run.endedAt, now: model.now))
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.secondaryText)
                Text("·").foregroundStyle(theme.palette.tertiaryText)
                Text(cost.combined)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.secondaryText)
                if run.toolCalls > 0 {
                    Text("·").foregroundStyle(theme.palette.tertiaryText)
                    Text("\(run.toolCalls) step\(run.toolCalls == 1 ? "" : "s")")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                Text("·").foregroundStyle(theme.palette.tertiaryText)
                Text(RunsLogic.absoluteTime(run.startedAt))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                if let prUrl = run.prUrl, let prNum = run.prNumber {
                    Text("·").foregroundStyle(theme.palette.tertiaryText)
                    Button("PR #\(prNum) \u{2197}") { context.openExternal(prUrl) }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                }
                if let parentId = run.parentRunId, !parentId.isEmpty {
                    Text("·").foregroundStyle(theme.palette.tertiaryText)
                    Button("Delegated by \u{2197}") { context.navigate("/runs/\(parentId)") }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.small)))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    let active = model.mode == tab.mode
                    Button {
                        model.anchor = nil
                        model.mode = tab.mode
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.label)
                            if let count = tab.count {
                                Text("\(count)")
                                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                    .foregroundStyle(active ? theme.palette.accent : theme.palette.tertiaryText)
                            }
                        }
                        .font(.system(size: theme.pointSize(.body), weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(active ? theme.palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("\(run.harness) · \(run.model)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func tabContent(
        detail: API.RunDetail,
        allEvents: [API.RunEvent],
        thread: RunThreadLogic.ThreadModel,
        childEntries: [QueryEntry<API.RunDetail>],
        childDetails: [API.RunDetail],
        files: [RunFilesLogic.RunFileEntry],
        allNeeds: [API.InboxItem]
    ) -> some View {
        switch model.mode {
        case .thread:
            RunThreadView(
                detail: detail,
                events: allEvents,
                thread: thread,
                needsItems: allNeeds,
                now: model.now,
                onOpenTurn: { turn in
                    model.anchor = RunsLogic.Anchor(kind: .turn, number: turn)
                    model.mode = .trace
                },
                onOpenTrace: {
                    model.anchor = nil
                    model.mode = .trace
                },
                onRefresh: refreshRun
            )

        case .trace:
            RunTraceView(
                detail: detail,
                childDetails: childDetails,
                events: allEvents,
                childLoadError: childEntries.contains(where: { $0.error != nil }),
                childLoading: childEntries.contains(where: { $0.data == nil && $0.error == nil }),
                filter: $model.traceFilter,
                search: $model.traceSearch,
                anchor: $model.anchor
            )

        case .graph:
            RunGraphTabSlot(
                runId: detail.run.id,
                onOpenTurn: { turn in
                    model.anchor = RunsLogic.Anchor(kind: .turn, number: turn)
                    model.mode = .trace
                },
                onOpenEvent: { seq in
                    model.anchor = RunsLogic.Anchor(kind: .event, number: seq)
                    model.mode = .trace
                }
            )

        case .files:
            RunFilesView(run: detail.run, files: files)
        }
    }

    // MARK: - Queries & Polling

    private func watchSignature(childIds: [String], ticketKey: String, hasEpic: Bool) -> String {
        [runId, model.project, model.agent, "\(listPageCount)", ticketKey, hasEpic ? "1" : "0", childIds.joined(separator: ",")].joined(separator: "|")
    }

    private func syncWatches(childIds: [String], ticketKey: String, hasEpic: Bool) {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        func start<V: Sendable>(_ request: APIRequest<V>) -> QueryKey {
            store.observe(request)
            store.load(request)
            return request.key
        }
        var nextKeys: [QueryKey] = [
            start(runRequest),
            start(liveListRequest),
            start(costsRequest),
            start(Self.inboxRequest),
            start(Self.runnerRequest),
            start(Self.bootstrapRequest),
            start(Self.personasRequest),
        ]
        nextKeys += (0..<listPageCount).map { start(listPageRequest($0)) }
        nextKeys += childIds.map { start(API.getRun(id: $0)) }
        if !ticketKey.isEmpty {
            nextKeys.append(start(API.getTicket(key: ticketKey)))
        }
        if hasEpic {
            nextKeys.append(start(Self.epicsRequest))
        }
        watched = nextKeys
    }

    private func pollActiveRun(detail: API.RunDetail?) async {
        guard !runId.isEmpty else { return }
        if let detail, detail.events.count >= RunsLogic.runEventsPage {
            await pageTrailingEvents(detail: detail)
        }
        guard detail.map({ RunsLogic.isLive($0.run) }) ?? true else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            model.now = Date()
            let updated = await context.store.refetch(runRequest)
            if let d = updated.data {
                for child in d.childRuns where RunsLogic.isLive(child) {
                    _ = await context.store.refetch(API.getRun(id: child.id))
                }
                if d.events.count >= RunsLogic.runEventsPage {
                    await pageTrailingEvents(detail: d)
                }
                if !RunsLogic.isLive(d.run) { return }
            }
        }
    }

    private func pageTrailingEvents(detail: API.RunDetail) async {
        guard let client = context.store.client else { return }
        var known = model.events(for: detail)
        var after = RunsLogic.nextEventsCursor(known: known)
        while !Task.isCancelled {
            guard let page = try? await client.send(API.listRunEvents(id: detail.run.id, after: after)) else { return }
            let merged = RunsLogic.mergeEvents(existing: known, incoming: page.events)
            known = merged
            model.extraEvents[detail.run.id] = merged
            guard page.events.count >= RunsLogic.runEventsPage,
                  let newest = page.events.last?.seq,
                  newest > after else {
                return
            }
            after = newest
        }
    }

    private func pollSidebarTick() async {
        var elapsed = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            elapsed += 5
            model.now = Date()
            if elapsed % 10 == 0 {
                _ = await context.store.refetch(liveListRequest)
            }
            if elapsed % 15 == 0 {
                _ = await context.store.refetch(Self.runnerRequest)
            }
            if elapsed % 30 == 0 {
                _ = await context.store.refetch(costsRequest)
            }
        }
    }

    private func refreshRun() {
        Task { _ = await context.store.refetch(runRequest) }
    }

    private func sendControl(runId targetId: String, action: API.ControlRunAction) {
        guard !model.controlBusy else { return }
        model.controlBusy = true
        model.controlError = nil
        Task {
            do {
                let updated = try await context.store.mutate(
                    RunsLogic.controlActionRequest(runId: targetId, action: action),
                    invalidating: RunsLogic.runMutationInvalidation
                )
                model.controlBusy = false
                if action == .retry && updated.id != targetId {
                    context.navigate("/runs/\(updated.id)")
                } else {
                    refreshRun()
                }
            } catch {
                model.controlBusy = false
                model.controlError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    // MARK: - Chrome & Commands

    private func buildChrome(
        detail: API.RunDetail?,
        dock: RunsLogic.ContextDockModel?,
        sidebarRuns: [API.Run],
        needs: [API.InboxItem],
        liveEntry: QueryEntry<API.ListRunsResponse>,
        listPages: [QueryEntry<API.ListRunsResponse>],
        runner: API.RunnerStatus?,
        costs: API.CostReport?
    ) -> NativeChrome {
        let boot = context.store.entry(Self.bootstrapRequest).data
        let personas = context.store.entry(Self.personasRequest).data?.personas ?? []
        let base = context.store.client?.baseURL
        let avatar: (API.AgentRef) -> Avatar = { agent in
            WorkNav.avatar(for: agent, personas: personas, base: base) { theme.colors["agent-\($0)"] }
        }

        let shownNeeds = needs.filter { WorkLogic.matchesItem($0, model.search) }
        let needsRunIds = Set(shownNeeds.compactMap { $0.runId.flatMap { $0.isEmpty ? nil : $0 } })
        let searchedRuns = sidebarRuns.filter { WorkLogic.matchesRun($0, model.search) }
        let grouped = RunsLogic.groupRuns(searchedRuns, skipIds: needsRunIds, now: model.now)

        let firstPage = listPages.first
        let loading = (liveEntry.data == nil && liveEntry.error == nil)
            || (firstPage.map { $0.data == nil && $0.error == nil } ?? false)
        let failure = liveEntry.data == nil ? liveEntry.error : (firstPage?.data == nil ? firstPage?.error : nil)

        var input = RunsNav.Input()
        input.project = projectParam
        input.projects = (boot?.projects ?? []).map { ($0.key, $0.name, $0.archived) }
        input.agents = (boot?.agents ?? []).map { ($0.handle, $0.name) }
        input.agent = model.agent
        input.hideDone = model.hideDone
        input.search = model.search
        input.needs = shownNeeds.map { item in
            let kind = InboxLogic.kind(item.kind.rawValue)
            let sub = [kind.label, item.ticketKey.isEmpty ? item.project : item.ticketKey, item.agent?.name]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return RunsNav.NeedsRow(
                id: item.id,
                title: item.title,
                subtitle: sub,
                avatar: item.agent.map(avatar),
                trailing: APIDate.waited(item.createdAt, now: model.now),
                tone: kind.tone == .blocked ? .blocked : .human
            )
        }
        input.groups = grouped.map { group in
            let count: Int? = (group.key == "running" || group.key == "queued") ? group.runs.count : nil
            return RunsNav.Group(
                key: group.key,
                label: group.label,
                count: count,
                runs: group.runs.map { run in
                    RunsNav.RunRow(
                        id: run.id,
                        title: WorkLogic.runTitle(run),
                        subtitle: RunsLogic.runLine(run),
                        avatar: avatar(run.agent),
                        trailing: RunsLogic.ago(run.startedAt, now: model.now),
                        dot: WorkLogic.runDot(run)
                    )
                }
            )
        }
        input.loading = loading
        input.error = failure?.userMessage
        input.hasMore = !model.hideDone && (listPages.last?.data?.hasMore ?? false)
        input.loadingMore = listPages.last?.isFetching ?? false
        input.statusLine = (WorkLogic.statusText(runner: runner, costs: costs), WorkLogic.reportsHref(project: projectParam))
        input.selectedId = RunsNav.selectedItemId(runId: runId, needs: shownNeeds)

        var toolbar: [ShellToolbarItem] = []
        if let run = detail?.run {
            let controls = RunsLogic.controlState(for: run)
            if controls.canResume {
                toolbar.append(ShellToolbarItem(id: Self.resumeToolbarId, label: controls.resumeLabel, icon: "play", kind: .button, accent: true, showsLabel: true))
            } else if controls.canPause {
                toolbar.append(ShellToolbarItem(id: Self.pauseToolbarId, label: "Pause", icon: "pause", kind: .button, showsLabel: true))
            }
            if controls.canRetry {
                toolbar.append(ShellToolbarItem(id: Self.retryToolbarId, label: "Retry run", icon: "refresh", kind: .button, accent: true, showsLabel: true))
            }
            if controls.canCancel {
                toolbar.append(ShellToolbarItem(id: Self.cancelToolbarId, label: "Cancel run", icon: "x", kind: .button, showsLabel: true))
            }
        }
        toolbar.append(ShellToolbarItem(
            id: Self.contextToolbarId,
            label: "Context",
            icon: "sidebar",
            kind: .toggle,
            on: model.contextDockOpen,
            showsLabel: true
        ))

        let inspector = detail.map { d in
            let r = d.run
            let inspectorSections = dock.map { RunsLogic.buildInspectorSections(dock: $0, mode: model.mode) } ?? []
            return InspectorModel(
                id: "run",
                open: model.inspectorOpen,
                activeTabId: model.inspectorTabId,
                tabs: [
                    InspectorTab(id: "context", label: "Context", icon: "sidebar", kind: .native, sections: inspectorSections),
                    InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion),
                ],
                companion: CompanionContext(
                    subject: CompanionSubject(
                        kind: .run,
                        id: r.id,
                        title: WorkLogic.runTitle(r),
                        agent: r.agent.name,
                        ticketKey: r.ticketKey.isEmpty ? nil : r.ticketKey
                    ),
                    path: context.match.path
                )
            )
        }

        let title = detail.map { WorkLogic.runTitle($0.run) } ?? "Run"
        let subtitle = detail.flatMap { d -> String? in
            let parts = [d.run.projectKey, d.run.ticketKey.isEmpty ? nil : d.run.ticketKey]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        return NativeChrome(
            title: title,
            subtitle: subtitle,
            toolbarItems: toolbar,
            inspector: inspector,
            navigator: RunsNav.model(input)
        )
    }

    static let resumeToolbarId = "run.resume"
    static let pauseToolbarId = "run.pause"
    static let retryToolbarId = "run.retry"
    static let cancelToolbarId = "run.cancel"
    static let contextToolbarId = "run.context"

    @MainActor
    static func handleCommand(_ command: NativeCommand, model: RunDetailModel, context: NativeScreenContext) {
        let currentRunId = context.match.params["id"] ?? ""
        switch command {
        case .toolbarAction(itemId: contextToolbarId, _):
            model.contextDockOpen.toggle()
            return
        case .toolbarAction(itemId: cancelToolbarId, _):
            model.confirmCancel = true
            return
        case .toolbarAction(itemId: pauseToolbarId, _):
            performControl(runId: currentRunId, action: .pause, model: model, context: context)
            return
        case .toolbarAction(itemId: resumeToolbarId, _):
            performControl(runId: currentRunId, action: .resume, model: model, context: context)
            return
        case .toolbarAction(itemId: retryToolbarId, _):
            performControl(runId: currentRunId, action: .retry, model: model, context: context)
            return
        case .inspectorVisibility(let open):
            model.inspectorOpen = open
            return
        case .inspectorSelectTab(let tabId):
            model.inspectorTabId = tabId
            return
        case .inspectorAction(_, let actionId, _, _):
            if actionId == "view:details" { model.mode = model.mode == .trace ? .thread : .trace }
            else if actionId == "view:graph" { model.mode = model.mode == .graph ? .thread : .graph }
            else if actionId == "view:files" { model.mode = model.mode == .files ? .thread : .files }
            return
        default:
            break
        }

        guard let action = RunsNav.action(for: command) else { return }
        switch action {
        case .search(let q):
            model.search = q
        case .toggleHideDone(let checked):
            model.hideDone = checked
            model.pages = 1
        case .project(let key):
            model.project = key
            UserDefaults.standard.set(key, forKey: RunDetailModel.projectKey)
            model.pages = 1
        case .agent(let handle):
            model.agent = handle
            model.pages = 1
        case .loadMore:
            model.pages += 1
        case .retry:
            let project = model.project.isEmpty ? nil : model.project
            let agent = model.agent.isEmpty ? nil : model.agent
            Task {
                _ = await context.store.refetch(API.listRuns(state: .live, agent: agent, project: project))
                _ = await context.store.refetch(API.listRuns(state: .all, agent: agent, project: project, offset: 0))
            }
        case .openRun(let id, let newTab):
            let href = "/runs/\(id)"
            newTab ? context.openInNewTab(href) : context.navigate(href)
        case .openNeeds(let id, let newTab):
            guard let item = context.store.entry(inboxRequest).data?.items.first(where: { $0.id == id }) else { return }
            let href = RunsLogic.itemHref(item)
            if InboxLogic.isExternalHref(href) {
                context.openExternal(href)
            } else {
                newTab ? context.openInNewTab(href) : context.navigate(href)
            }
        case .openStatus(let newTab):
            let href = WorkLogic.reportsHref(project: model.project.isEmpty ? nil : model.project)
            newTab ? context.openInNewTab(href) : context.navigate(href)
        }
    }

    @MainActor
    private static func performControl(
        runId: String,
        action: API.ControlRunAction,
        model: RunDetailModel,
        context: NativeScreenContext
    ) {
        guard !runId.isEmpty, !model.controlBusy else { return }
        model.controlBusy = true
        model.controlError = nil
        Task {
            do {
                let updated = try await context.store.mutate(
                    RunsLogic.controlActionRequest(runId: runId, action: action),
                    invalidating: RunsLogic.runMutationInvalidation
                )
                model.controlBusy = false
                if action == .retry && updated.id != runId {
                    context.navigate("/runs/\(updated.id)")
                } else {
                    _ = await context.store.refetch(API.getRun(id: runId))
                }
            } catch {
                model.controlBusy = false
                model.controlError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Collapsible Context Dock (Plan, Usage, Ticket, Code, Sub-agents, Run Facts)

struct RunContextDockView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let dock: RunsLogic.ContextDockModel
    let mode: RunsLogic.ViewMode
    let onSelectMode: (RunsLogic.ViewMode) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !dock.plan.steps.isEmpty {
                    planSection
                }
                usageSection
                if let ticket = dock.ticket {
                    ticketSection(ticket)
                }
                if let code = dock.code, code.branch != nil || code.prNumber != nil {
                    codeSection(code)
                }
                if !dock.subAgents.isEmpty {
                    subAgentsSection
                }
                runFactsSection
                openLinksSection
            }
            .padding(14)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
    }

    private var planSection: some View {
        section("PLAN", aside: "\(dock.plan.done)/\(dock.plan.total)") {
            ProgressView(value: dock.plan.fraction)
                .progressViewStyle(.linear)
                .tint(theme.swiftUIColor("state-done", fallback: .green))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(dock.plan.steps, id: \.position) { step in
                    HStack(alignment: .top, spacing: 7) {
                        planSymbol(step.state)
                            .frame(width: 14, height: 16)
                        Text(step.text)
                            .vesperText(.small, theme)
                            .foregroundStyle(step.state == .done ? theme.palette.tertiaryText : theme.palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func planSymbol(_ state: API.PlanStep.State) -> some View {
        let (symbol, color): (String, Color) = switch state.rawValue {
        case "done": ("checkmark.circle.fill", theme.swiftUIColor("state-done", fallback: .green))
        case "current": ("circle.inset.filled", theme.palette.accent)
        case "needs_human": ("exclamationmark.circle.fill", theme.swiftUIColor("state-human", fallback: .orange))
        case "failed": ("xmark.circle.fill", theme.swiftUIColor("pill-blocked-fg", fallback: .red))
        default: ("circle", theme.palette.tertiaryText)
        }
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(color)
    }

    private var usageSection: some View {
        section("USAGE") {
            factRow("Total tokens", value: dock.usage.tokensSummary, mono: true)
            factRow("Estimated cost", value: dock.usage.costSummary, mono: true)
            if let pct = dock.usage.cacheSharePct {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Cache share").foregroundStyle(theme.palette.secondaryText)
                        Spacer()
                        Text("\(pct)%")
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    }
                    .font(.system(size: theme.pointSize(.small)))
                    ProgressView(value: Double(max(0, min(100, pct))) / 100.0)
                        .progressViewStyle(.linear)
                        .tint(theme.palette.accent)
                }
            }
            ForEach(dock.usage.turns) { turn in
                factRow("Turn \(turn.seq)", value: turn.summary, mono: true)
            }
            if dock.usage.models.count > 1 {
                ForEach(dock.usage.models) { model in
                    factRow(model.model, value: model.summary, mono: true)
                }
            }
        }
    }

    private func ticketSection(_ ticket: RunsLogic.TicketContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            section("TICKET") {
                factLink("Ticket", value: "\(ticket.key) · \(ticket.title)") {
                    context.navigate("/tickets/\(MarkdownSource.encodeURIComponent(ticket.key))")
                }
                factRow("State", value: "\(ticket.statusLabel) · \(ticket.priorityLabel)")
                if let epicId = ticket.epicId, let epicName = ticket.epicName {
                    factLink("Epic", value: epicName) {
                        context.navigate("/epics/\(MarkdownSource.encodeURIComponent(epicId))")
                    }
                    if let done = ticket.epicDone, let total = ticket.epicTotal, total > 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Epic progress").foregroundStyle(theme.palette.secondaryText)
                                Spacer()
                                Text("\(done)/\(total) done")
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            }
                            .font(.system(size: theme.pointSize(.small)))
                            ProgressView(value: Double(done) / Double(total))
                                .progressViewStyle(.linear)
                                .tint(theme.swiftUIColor("state-done", fallback: .green))
                        }
                    }
                }
            }
            if !ticket.criteria.isEmpty {
                let met = ticket.criteria.filter(\.done).count
                section("ACCEPTANCE CRITERIA", aside: "\(met)/\(ticket.criteria.count)") {
                    ForEach(ticket.criteria, id: \.id) { c in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: c.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(c.done ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.tertiaryText)
                                .frame(width: 14, height: 16)
                            Text(c.text)
                                .vesperText(.small, theme)
                                .foregroundStyle(c.done ? theme.palette.tertiaryText : theme.palette.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func codeSection(_ code: RunsLogic.CodeContext) -> some View {
        section("CODE") {
            if let branch = code.branch {
                factRow("Branch", value: branch, mono: true)
            }
            if code.additions != nil || code.deletions != nil {
                factRow("Diff", value: "+\(code.additions ?? 0) −\(code.deletions ?? 0)", mono: true)
            }
            if let pr = code.prNumber {
                let label = "#\(pr)" + (code.prState.map { " · \($0)" } ?? "")
                if let url = code.prUrl {
                    factLink("Pull request", value: label) { context.openExternal(url) }
                } else {
                    factRow("Pull request", value: label)
                }
            }
        }
    }

    private var subAgentsSection: some View {
        section("SUB-AGENTS", aside: "\(dock.subAgents.count)") {
            ForEach(dock.subAgents) { sub in
                Button {
                    context.navigate("/runs/\(sub.id)")
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sub.stateTone == .done ? theme.swiftUIColor("state-done", fallback: .green)
                                  : sub.stateTone == .human ? theme.swiftUIColor("state-human", fallback: .orange)
                                  : sub.stateTone == .blocked ? theme.swiftUIColor("pill-blocked-fg", fallback: .red)
                                  : theme.palette.tertiaryText)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sub.agentName)
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .foregroundStyle(theme.palette.text)
                            Text(sub.subtitle)
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                .foregroundStyle(theme.palette.tertiaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var runFactsSection: some View {
        section("RUN") {
            ForEach(dock.facts) { fact in
                factRow(fact.label, value: fact.value, mono: fact.mono)
            }
        }
    }

    private var openLinksSection: some View {
        section("OPEN") {
            HStack(spacing: 6) {
                Button("Trace") { onSelectMode(.trace) }
                    .buttonStyle(.vesper(mode == .trace ? .primary : .outline))
                if dock.hasChildren || mode == .graph {
                    Button("Graph") { onSelectMode(.graph) }
                        .buttonStyle(.vesper(mode == .graph ? .primary : .outline))
                }
                Button("Files") { onSelectMode(.files) }
                    .buttonStyle(.vesper(mode == .files ? .primary : .outline))
            }
            factLink("Environment", value: "Open settings") {
                context.navigate(dock.environmentHref)
            }
            if let rawLogPath = dock.rawLogPath {
                factLink("Raw log", value: "Download JSONL") {
                    if let url = context.resolvedURL(rawLogPath) {
                        context.openExternal(url.absoluteString)
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        aside: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.palette.tertiaryText)
                Spacer()
                if let aside {
                    Text(aside)
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            content()
        }
    }

    private func factRow(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                .frame(minWidth: 74, alignment: .leading)
            Spacer(minLength: 4)
            Text(value)
                .font(mono ? .system(size: theme.pointSize(.small), design: .monospaced) : .system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func factLink(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                .frame(minWidth: 74, alignment: .leading)
            Spacer(minLength: 4)
            Button(action: action) {
                Text(value)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.accent)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
        }
    }
}
