import Charts
import SwiftUI
import VesperCore

/// Pure-SwiftUI Epic detail screen (`/epics/:id`): header, progress + spend, Needs You inline
/// approvals, criteria ticking/CRUD via `TicketCriteriaListView`, wave-grouped tickets reusing
/// `TicketRowView`, Start Ready dispatcher, and Swift Charts burn-up. Zero AppKit imports.
struct EpicDetailScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    private enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case progress = "Burn-up & Links"
    }

    @State private var tab: DetailTab = .overview
    @State private var selectedAgentId = ""
    @State private var busyAction: String? = nil
    @State private var actionError: String? = nil
    @State private var startSuccessMessage: String? = nil
    @State private var approvedTicketKeys: Set<String> = []
    @State private var selectedTickets: Set<String> = []
    @State private var watched: [QueryKey] = []

    private var epicId: String { context.match.params["id"] ?? "" }
    private static let epicsRequest = API.listEpicOverviews()
    private static let bootstrapRequest = API.getBootstrap()

    var body: some View {
        let epicsEntry = context.store.entry(Self.epicsRequest)
        let bootEntry = context.store.entry(Self.bootstrapRequest)
        let allEpics = epicsEntry.data?.epics ?? []
        let overview = allEpics.first { $0.epic.id == epicId }

        Group {
            if let error = epicsEntry.error, epicsEntry.data == nil {
                QueryErrorView(message: "Couldn\u{2019}t load the epic: \(error.userMessage)") {
                    Task { await context.store.refetch(Self.epicsRequest) }
                }
            } else if epicsEntry.data == nil && epicsEntry.isFetching {
                VStack(spacing: 16) {
                    SkeletonBar(height: 100)
                    SkeletonBar(height: 220)
                }
                .padding(24)
            } else if let overview {
                detailContent(
                    overview: overview,
                    siblings: allEpics.filter { $0.project.key == overview.project.key },
                    agents: (bootEntry.data?.agents ?? []).filter { $0.kind == .main }
                )
            } else {
                VStack(spacing: 12) {
                    Text("Epic not found").vesperText(.title, theme)
                    Text("It may have been deleted, or the link is wrong.")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                    Button("All epics") { context.navigate("/epics") }
                        .buttonStyle(.vesper(.primary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: epicId) {
            selectedTickets = []
            actionError = nil
            startSuccessMessage = nil
            observeBaseQueries()
        }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private func detailContent(
        overview: API.EpicOverview,
        siblings: [API.EpicOverview],
        agents: [API.Agent]
    ) -> some View {
        let ticketsReq = API.listTickets(view: .all, epic: overview.epic.id)
        let boardReq = API.getProjectBoard(key: overview.project.key, epic: overview.epic.id, includeCanceled: false)
        let inboxReq = API.listInbox(project: overview.project.key)
        let costsReq = API.getCosts(epic: overview.epic.id)

        let tickets = context.store.entry(ticketsReq).data?.tickets ?? []
        let boardEpic = context.store.entry(boardReq).data?.epic
        let inboxItems = context.store.entry(inboxReq).data?.items ?? []
        let costReport = context.store.entry(costsReq).data
        let needsByKey = TicketsLogic.needsYouByTicket(inboxItems)
        let waitingTickets = tickets.filter { needsByKey[$0.key] != nil }
        let criteria = (boardEpic?.criteria ?? []).sorted { $0.position < $1.position }
        let burnUp = EpicsLogic.burnUp(tickets: tickets, startDate: overview.startDate, today: EpicsLogic.todayYMD())
        let waves = EpicsLogic.groupByWave(tickets: tickets, needsByKey: needsByKey)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection(overview: overview)
                progressSection(tickets: tickets, needsByKey: needsByKey, costReport: costReport)

                if !waitingTickets.isEmpty {
                    needsYouSection(tickets: waitingTickets, needsByKey: needsByKey)
                }

                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if tab == .overview {
                    criteriaSection(overview: overview, criteria: criteria, blockers: boardEpic?.doneBlockers)
                    wavesSection(waves: waves, needsByKey: needsByKey, overview: overview)
                    startReadySection(overview: overview, tickets: tickets, agents: agents)
                } else {
                    burnUpSection(burnUp: burnUp, overview: overview, boardEpic: boardEpic)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task(id: "\(overview.epic.id):\(overview.project.key)") {
            observeDetailQueries(ticketsReq: ticketsReq, boardReq: boardReq, inboxReq: inboxReq, costsReq: costsReq)
            publishChrome(overview: overview, siblings: siblings, criteria: criteria, blockers: boardEpic?.doneBlockers, burnUp: burnUp)
        }
        .onChange(of: criteria) { _, _ in
            publishChrome(overview: overview, siblings: siblings, criteria: criteria, blockers: boardEpic?.doneBlockers, burnUp: burnUp)
        }
        .onChange(of: overview.epic) { _, _ in
            publishChrome(overview: overview, siblings: siblings, criteria: criteria, blockers: boardEpic?.doneBlockers, burnUp: burnUp)
        }
    }

    private func headerSection(overview: API.EpicOverview) -> some View {
        let p = theme.palette
        let overdue = EpicsLogic.isOverdue(overview, today: EpicsLogic.todayYMD())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(overview.project.name) {
                    context.navigate("/tickets?project=\(APIPath.escape(overview.project.key))")
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.secondaryText)
                Text("/").foregroundStyle(p.tertiaryText)
                Button("Epics") {
                    context.navigate(EpicsLogic.epicsHref(project: overview.project.key))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.secondaryText)
            }
            .font(.system(size: theme.pointSize(.small)))

            Text(overview.epic.name)
                .vesperText(.title, theme)
                .foregroundStyle(p.text)

            HStack(spacing: 8) {
                TonePill(label: EpicsLogic.healthLabel(overview.epic.health), tone: EpicsLogic.healthPillTone(overview.epic.health))
                TonePill(label: EpicsLogic.statusLabel(overview.epic.status), tone: overview.epic.status == .done ? "done" : "neutral")
                Text("·").foregroundStyle(p.tertiaryText)
                Text(overview.targetDate.map { "\(overdue ? "Overdue · " : "Target ")\(EpicsLogic.formatDueDate($0))" } ?? "No target date")
                    .foregroundStyle(overdue ? theme.swiftUIColor("pill-blocked-fg", fallback: .red) : p.secondaryText)
                Text("·").foregroundStyle(p.tertiaryText)
                Text(overview.owner.map { "Owner \($0.name)" } ?? "No owner")
                    .foregroundStyle(p.secondaryText)
            }
            .font(.system(size: theme.pointSize(.small)))

            Text(overview.objective.isEmpty ? "No objective has been written yet." : overview.objective)
                .vesperText(.body, theme)
                .foregroundStyle(p.secondaryText)
                .padding(.top, 2)

            HStack(spacing: 16) {
                Button("Board filtered to this epic") {
                    context.navigate(EpicsLogic.boardHref(projectKey: overview.project.key, epicId: overview.epic.id))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.accent)

                Button("Ticket list ↗") {
                    context.navigate(EpicsLogic.ticketListHref(projectKey: overview.project.key, epicId: overview.epic.id))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.secondaryText)

                Button("Plan with an agent ↗") {
                    context.navigate(EpicsLogic.planHref(projectKey: overview.project.key, epicId: overview.epic.id, sourceArtifactId: overview.source?.id))
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.secondaryText)
            }
            .font(.system(size: theme.pointSize(.small)))
            .padding(.top, 2)
        }
    }

    private func progressSection(
        tickets: [API.TicketSummary],
        needsByKey: [String: TicketsLogic.NeedsYou],
        costReport: API.CostReport?
    ) -> some View {
        let p = theme.palette
        let prog = EpicsLogic.progress(tickets: tickets, needsByKey: needsByKey)
        let parts: [(label: String, value: Int, color: Color)] = [
            ("done", prog.done, theme.swiftUIColor("state-done", fallback: .green)),
            ("running", prog.running, theme.swiftUIColor("state-progress", fallback: p.accent)),
            ("need you", prog.needs, theme.swiftUIColor("state-human", fallback: .orange)),
            ("open", prog.open, theme.swiftUIColor("track", fallback: p.border)),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            EpicStackedBar(segments: parts.map { ($0.value, $0.color) }, height: 8)
            HStack(spacing: 14) {
                ForEach(parts, id: \.label) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text("\(part.value)")
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(part.label == "need you" && part.value > 0 ? theme.swiftUIColor("pill-human-fg", fallback: .orange) : p.text)
                        Text(part.label)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                    }
                }
                Spacer()
                if let costReport {
                    Text("\(ReportsLogic.spendLabel(micros: costReport.total.costMicros, unpricedRuns: costReport.unpricedRuns)) spent so far")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                }
            }
        }
    }

    private func needsYouSection(tickets: [API.TicketSummary], needsByKey: [String: TicketsLogic.NeedsYou]) -> some View {
        let p = theme.palette
        let humanFg = theme.swiftUIColor("pill-human-fg", fallback: .orange)
        return VStack(alignment: .leading, spacing: 8) {
            Text("NEEDS YOU \(tickets.count)")
                .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(humanFg)
            ForEach(tickets, id: \.id) { ticket in
                if let needs = needsByKey[ticket.key] {
                    HStack(spacing: 10) {
                        Text(ticket.key)
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ticket.title).font(.system(size: theme.pointSize(.body), weight: .medium))
                            TicketStateTextView(ticket: ticket, needs: needs)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if approvedTicketKeys.contains(ticket.key) {
                            Text("Approved").font(.system(size: theme.pointSize(.small))).foregroundStyle(p.secondaryText)
                        } else if needs.kind == "approval" {
                            Button("Approve") {
                                Task { await approve(approvalId: needs.id, ticketKey: ticket.key) }
                            }
                            .buttonStyle(.vesper(.approve))
                            .disabled(busyAction == "approve:\(ticket.key)")
                        }
                        Button("Open") { context.navigate(needs.href) }
                            .buttonStyle(.vesper(.approveOutline))
                    }
                }
            }
        }
        .padding(14)
        .background(theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(humanFg.opacity(0.35)))
    }

    private func criteriaSection(
        overview: API.EpicOverview,
        criteria: [API.EpicCriterion],
        blockers: API.BoardEpic.DoneBlockers?
    ) -> some View {
        let closed = overview.epic.status == .done
        let canDone = EpicsLogic.canMarkDone(status: overview.epic.status, criteriaCount: criteria.count, blockers: blockers)
        let adapted = criteria.map { API.Criterion(done: $0.done, id: $0.id, position: $0.position, text: $0.text) }
        return VStack(alignment: .leading, spacing: 10) {
            TicketCriteriaListView(
                title: "Epic acceptance criteria",
                criteria: adapted,
                readOnly: closed,
                errorMessage: actionError,
                onToggle: { criterion, done in
                    Task { await toggleCriterion(id: criterion.id, done: done) }
                },
                onDelete: { id in
                    Task { await deleteCriterion(id: id) }
                },
                onAdd: { text in
                    Task { await addCriterion(epicId: overview.epic.id, text: text) }
                }
            )

            HStack(spacing: 12) {
                Toggle("Requires UI mockup", isOn: Binding(
                    get: { overview.epic.requiresMockup },
                    set: { value in Task { await updateEpic(id: overview.epic.id, body: API.UpdateEpicBody(requiresMockup: value)) } }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: theme.pointSize(.small)))

                Spacer()

                if !closed, let note = EpicsLogic.blockerSummary(blockers) {
                    Text(note)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                }

                if closed {
                    Button("Reopen epic") {
                        Task { await updateEpic(id: overview.epic.id, body: API.UpdateEpicBody(status: .open)) }
                    }
                    .buttonStyle(.vesper())
                } else {
                    Button("Mark epic done") {
                        Task { await updateEpic(id: overview.epic.id, body: API.UpdateEpicBody(status: .done)) }
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(!canDone || busyAction != nil)
                }
            }
        }
    }

    private func wavesSection(
        waves: [EpicsLogic.WaveGroup],
        needsByKey: [String: TicketsLogic.NeedsYou],
        overview: API.EpicOverview
    ) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TICKETS BY WAVE")
                    .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(p.tertiaryText)
                Text("\(overview.epic.ticketsOpen) open of \(overview.epic.ticketsTotal)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
            }

            if waves.isEmpty {
                Text("No tickets in this epic yet.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(waves) { wave in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(wave.label)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                .foregroundStyle(p.secondaryText)
                            Text("\(wave.tickets.count)")
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(.horizontal, 4)

                        VStack(spacing: 0) {
                            ForEach(wave.tickets, id: \.id) { ticket in
                                TicketRowView(
                                    ticket: ticket,
                                    needs: needsByKey[ticket.key],
                                    selected: selectedTickets.contains(ticket.key),
                                    focused: false,
                                    compact: false,
                                    showEpic: false,
                                    onToggleSelect: {
                                        if selectedTickets.contains(ticket.key) { selectedTickets.remove(ticket.key) }
                                        else { selectedTickets.insert(ticket.key) }
                                    },
                                    onOpen: { newTab in
                                        let href = TicketsLogic.ticketHref(ticket.key)
                                        newTab ? context.openInNewTab(href) : context.navigate(href)
                                    },
                                    onOpenNeeds: { href in context.navigate(href) },
                                    onStart: { Task { await dispatchKeys([ticket.key]) } },
                                    onCopyKey: { context.copyToClipboard(ticket.key) },
                                    onCopyLink: { context.copyToClipboard(TicketsLogic.ticketHref(ticket.key)) }
                                )
                            }
                        }
                        .padding(4)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border.opacity(0.7)))
                    }
                }
            }
        }
    }

    private func startReadySection(overview: API.EpicOverview, tickets: [API.TicketSummary], agents: [API.Agent]) -> some View {
        let p = theme.palette
        let split = EpicsLogic.startReady(tickets: tickets)
        let activeAgent = agents.first { $0.id == selectedAgentId } ?? agents.first
        let dispatchable = split.ready.map(\.key)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(split.ready.isEmpty ? "Nothing is ready to start" : "\(split.ready.count) \(split.ready.count == 1 ? "ticket is" : "tickets are") ready to start")
                        .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                    Text("Starts only tickets whose blockers are done. Existing persona assignments are kept.")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                }
                Spacer()
                Button(busyAction == "startReady" ? "Starting…" : (split.unassignedKeys.isEmpty ? "Start ready (\(dispatchable.count))" : "Assign & start (\(dispatchable.count))")) {
                    Task { await startReadyTickets(keys: dispatchable, unassignedKeys: split.unassignedKeys, agentId: activeAgent?.id) }
                }
                .buttonStyle(.vesper(.approve))
                .disabled(overview.epic.status == .done || dispatchable.isEmpty || busyAction != nil || (!split.unassignedKeys.isEmpty && activeAgent == nil))
            }

            if !split.unassignedKeys.isEmpty && !agents.isEmpty {
                HStack(spacing: 8) {
                    Text("Persona for unassigned tickets:")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                    Picker("Persona", selection: Binding(
                        get: { activeAgent?.id ?? "" },
                        set: { selectedAgentId = $0 }
                    )) {
                        ForEach(agents, id: \.id) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if !split.blocked.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Still blocked (\(split.blocked.count)):")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                    ForEach(split.blocked.prefix(6), id: \.id) { t in
                        HStack(spacing: 6) {
                            Text(t.key).font(.system(size: theme.pointSize(.small), design: .monospaced)).foregroundStyle(p.tertiaryText)
                            Text(t.title).vesperText(.small, theme).lineLimit(1)
                            Text("· blocked by \(t.unmetDependencies)")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                    }
                }
            }

            if let msg = startSuccessMessage {
                Text(msg).vesperText(.small, theme).foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
            }
        }
        .padding(16)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
    }

    private func burnUpSection(burnUp: EpicsLogic.BurnUp, overview: API.EpicOverview, boardEpic: API.BoardEpic?) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Points burn-up")
                        .vesperText(.heading, theme)
                    Spacer()
                    Text("\(burnUp.done) / \(burnUp.scope) pts")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                }
                if burnUp.scope > 0 {
                    Chart {
                        RuleMark(y: .value("Scope", burnUp.scope))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(p.tertiaryText)
                        ForEach(burnUp.points) { pt in
                            AreaMark(
                                x: .value("Date", EpicsLogic.formatDueDate(pt.date)),
                                y: .value("Done", pt.done)
                            )
                            .foregroundStyle(p.accent.opacity(0.14))
                            LineMark(
                                x: .value("Date", EpicsLogic.formatDueDate(pt.date)),
                                y: .value("Done", pt.done)
                            )
                            .foregroundStyle(p.accent)
                            PointMark(
                                x: .value("Date", EpicsLogic.formatDueDate(pt.date)),
                                y: .value("Done", pt.done)
                            )
                            .foregroundStyle(p.accent)
                        }
                    }
                    .chartYScale(domain: 0...max(1, burnUp.scope))
                    .frame(height: 220)
                } else {
                    Text("Add point estimates to tickets to see burn-up progress.")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))

            VStack(alignment: .leading, spacing: 10) {
                Text("Linked artifacts & review").vesperText(.heading, theme)
                if let source = overview.source {
                    HStack {
                        Text("Source document:").vesperText(.small, theme).foregroundStyle(p.secondaryText)
                        Button(source.title) { context.navigate(source.href) }
                            .buttonStyle(.plain)
                            .foregroundStyle(p.accent)
                    }
                }
                if let review = boardEpic?.review {
                    HStack {
                        Text("Final review ticket:").vesperText(.small, theme).foregroundStyle(p.secondaryText)
                        Button("\(review.key) · \(review.title)") { context.navigate(TicketsLogic.ticketHref(review.key)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(p.accent)
                    }
                } else if overview.epic.status == .open {
                    Button("Create final review ticket") {
                        Task { await createReviewTicket(epicId: overview.epic.id) }
                    }
                    .buttonStyle(.vesper())
                    .disabled(busyAction != nil)
                }
            }
            .padding(16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
        }
    }

    // MARK: - Mutations & Wiring

    private func observeBaseQueries() {
        context.store.observe(Self.epicsRequest)
        context.store.observe(Self.bootstrapRequest)
        context.store.load(Self.epicsRequest)
        context.store.load(Self.bootstrapRequest)
        watched = [Self.epicsRequest.key, Self.bootstrapRequest.key]
    }

    private func observeDetailQueries(
        ticketsReq: APIRequest<API.TicketList>,
        boardReq: APIRequest<API.Board>,
        inboxReq: APIRequest<API.ListInboxResponse>,
        costsReq: APIRequest<API.CostReport>
    ) {
        let nextKeys = [Self.epicsRequest.key, Self.bootstrapRequest.key, ticketsReq.key, boardReq.key, inboxReq.key, costsReq.key]
        if watched != nextKeys {
            for key in watched { context.store.stopObserving(key) }
            context.store.observe(Self.epicsRequest)
            context.store.observe(Self.bootstrapRequest)
            context.store.observe(ticketsReq)
            context.store.observe(boardReq)
            context.store.observe(inboxReq)
            context.store.observe(costsReq)
            watched = nextKeys
        }
        context.store.load(ticketsReq)
        context.store.load(boardReq)
        context.store.load(inboxReq)
        context.store.load(costsReq)
    }

    private func publishChrome(
        overview: API.EpicOverview,
        siblings: [API.EpicOverview],
        criteria: [API.EpicCriterion],
        blockers: API.BoardEpic.DoneBlockers?,
        burnUp: EpicsLogic.BurnUp
    ) {
        let nav = EpicsLogic.epicDetailNavModel(
            project: overview.project.key,
            projectName: overview.project.name,
            epics: siblings,
            epicId: overview.epic.id
        )
        let sections = EpicsLogic.epicDetailInspectorSections(
            overview: overview,
            criteria: criteria,
            blockers: blockers,
            burnUp: burnUp
        )
        context.chrome = NativeChrome(
            title: overview.epic.name,
            subtitle: overview.project.name,
            toolbarItems: [
                ShellToolbarItem(id: "epic.board", label: "Board", icon: "board", kind: .button, showsLabel: true),
            ],
            inspector: InspectorModel(
                id: "epic",
                open: true,
                activeTabId: "context",
                tabs: [
                    InspectorTab(id: "context", label: "Context", icon: "sidebar", kind: .native, sections: sections),
                    InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion),
                ],
                companion: CompanionContext(path: context.match.path)
            ),
            navigator: nav
        )
        context.onCommand = { command in
            switch command {
            case .toolbarAction("epic.board", _):
                context.navigate(EpicsLogic.boardHref(projectKey: overview.project.key, epicId: overview.epic.id))
            case .inspectorToggle(_, EpicsLogic.requiresMockupFieldId, let checked):
                Task { await updateEpic(id: overview.epic.id, body: API.UpdateEpicBody(requiresMockup: checked)) }
            case .inspectorToggle(_, let fieldId, let checked) where fieldId.hasPrefix("criterion:"):
                let id = String(fieldId.dropFirst("criterion:".count))
                Task { await toggleCriterion(id: id, done: checked) }
            case .inspectorAction(_, EpicsLogic.markDoneActionId, _, _):
                Task { await updateEpic(id: overview.epic.id, body: API.UpdateEpicBody(status: .done)) }
            case .inspectorAction(_, EpicsLogic.reopenEpicActionId, _, _):
                Task { await updateEpic(id: overview.epic.id, body: API.UpdateEpicBody(status: .open)) }
            case .navPicker(EpicsLogic.epicDetailNavId, WorkNav.viewPicker, let value):
                if value == "activity" { context.navigate("/work") }
            case .navActivate(EpicsLogic.epicDetailNavId, let itemId, let newTab):
                let href = EpicsLogic.epicDetailHref(itemId)
                newTab ? context.openInNewTab(href) : context.navigate(href)
            default:
                break
            }
        }
    }

    private func toggleCriterion(id: String, done: Bool) async {
        actionError = nil
        do {
            _ = try await context.store.mutate(
                API.updateEpicCriterion(id: id, body: API.UpdateEpicCriterionBody(done: done)),
                invalidating: QueryInvalidation(resources: ["epics", "board"])
            )
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func addCriterion(epicId: String, text: String) async {
        actionError = nil
        do {
            _ = try await context.store.mutate(
                API.createEpicCriterion(id: epicId, body: API.CreateEpicCriterionBody(text: text)),
                invalidating: QueryInvalidation(resources: ["epics", "board"])
            )
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func deleteCriterion(id: String) async {
        actionError = nil
        do {
            _ = try await context.store.mutate(
                API.deleteEpicCriterion(id: id),
                invalidating: QueryInvalidation(resources: ["epics", "board"])
            )
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func updateEpic(id: String, body: API.UpdateEpicBody) async {
        busyAction = "updateEpic"
        actionError = nil
        defer { busyAction = nil }
        do {
            _ = try await context.store.mutate(
                API.updateEpic(id: id, body: body),
                invalidating: QueryInvalidation(resources: ["epics", "board"])
            )
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func approve(approvalId: String, ticketKey: String) async {
        busyAction = "approve:\(ticketKey)"
        defer { busyAction = nil }
        do {
            _ = try await context.store.mutate(
                API.decideApproval(id: approvalId, decision: .approve),
                invalidating: QueryInvalidation(resources: ["inbox", "tickets", "runs", "epics"])
            )
            approvedTicketKeys.insert(ticketKey)
        } catch {
            context.showToast(ToastItemModel(id: "epic.approve.err", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
        }
    }

    private func dispatchKeys(_ keys: [String]) async {
        do {
            _ = try await context.store.mutate(
                API.dispatchTickets(body: API.DispatchTicketsBody(keys: keys)),
                invalidating: QueryInvalidation(resources: ["tickets", "runs", "epics", "board"])
            )
            context.showToast(ToastItemModel(id: "epic.dispatch", title: "Queued \(keys.count) \(keys.count == 1 ? "ticket" : "tickets")", tone: .success))
        } catch {
            context.showToast(ToastItemModel(id: "epic.dispatch.err", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
        }
    }

    private func startReadyTickets(keys: [String], unassignedKeys: [String], agentId: String?) async {
        busyAction = "startReady"
        actionError = nil
        startSuccessMessage = nil
        defer { busyAction = nil }
        do {
            if !unassignedKeys.isEmpty, let agentId {
                _ = try await context.store.mutate(
                    API.bulkUpdateTickets(body: API.BulkUpdate(
                        keys: unassignedKeys,
                        patch: API.TicketPatch(assigneeAgentId: .value(agentId))
                    )),
                    invalidating: QueryInvalidation(resources: ["tickets", "epics"])
                )
            }
            let res = try await context.store.mutate(
                API.dispatchTickets(body: API.DispatchTicketsBody(keys: keys)),
                invalidating: QueryInvalidation(resources: ["tickets", "runs", "epics", "board"])
            )
            startSuccessMessage = "\(res.dispatched) epic tickets queued."
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func createReviewTicket(epicId: String) async {
        busyAction = "review"
        defer { busyAction = nil }
        do {
            let ticket = try await context.store.mutate(
                API.createEpicReview(id: epicId),
                invalidating: QueryInvalidation(resources: ["epics", "board", "tickets"])
            )
            context.showToast(ToastItemModel(id: "epic.review", title: "Created review ticket \(ticket.key)", tone: .success))
        } catch {
            context.showToast(ToastItemModel(id: "epic.review.err", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
        }
    }
}
