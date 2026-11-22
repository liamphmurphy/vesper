import SwiftUI
import VesperCore

/// Per-tab mutable state for `TicketDetailScreen`.
@MainActor
@Observable
final class TicketDetailModel {
    private static let inspectorOpenKey = "VesperNativeTicketInspectorOpen"

    var inspectorOpen: Bool = {
        if UserDefaults.standard.object(forKey: inspectorOpenKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: inspectorOpenKey)
    }() {
        didSet { UserDefaults.standard.set(inspectorOpen, forKey: Self.inspectorOpenKey) }
    }
    var inspectorTabId = "properties"
    var now = Date()
    var copiedLink = false
    var showDispatchSheet = false
    var scrollTarget: String?

    var editingTitle = false
    var titleDraft = ""
    var editingDescription = false
    var descriptionDraft = ""
    var editingDueDate = false
    var dueDateDraft = ""

    var editingCriteria = false
    var criteriaBase: TicketDetailLogic.TicketSnapshot?
    var criteriaDraft: TicketDetailLogic.TicketDraft?
    var criteriaError: String?

    var saving = false
    var saveError: String?
    var saveConflict: TicketDetailLogic.SaveConflict?

    var blockerInput = ""
    var blockerError: String?
    var savingDependencies = false

    var sendingPRFeedback = false
    var decidingApprovalId: String?
    var showAttachArtifact = false
    var attachingArtifact = false
    var openingQuickLookId: String?

    var commentDraft = ""
    var replyingToCommentId: String?
    var sendingComment = false
    var commentError: String?

    func resetForTicket() {
        editingTitle = false
        editingDescription = false
        editingDueDate = false
        editingCriteria = false
        criteriaBase = nil
        criteriaDraft = nil
        criteriaError = nil
        saveError = nil
        saveConflict = nil
        blockerInput = ""
        blockerError = nil
        replyingToCommentId = nil
        commentError = nil
    }
}

/// `/tickets/:key`: native ticket detail screen (pure SwiftUI + VesperCore; zero AppKit).
struct TicketDetailScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var model = TicketDetailModel()
    @State private var watchedKeys: [QueryKey] = []

    private static let ticketInvalidation = QueryInvalidation(
        resources: ["tickets", "board", "boards", "epics", "planning", "inbox", "bootstrap", "knowledge"]
    )
    private static let bootstrapReq = API.getBootstrap()
    private static let personasReq = API.listPersonas()

    private var ticketKey: String { context.match.params["key"] ?? "" }
    private var queryProject: String? {
        let p = context.match.query["project"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (p?.isEmpty == false) ? p : nil
    }
    private var ticketReq: APIRequest<API.Ticket> { API.getTicket(key: ticketKey) }
    private var activityReq: APIRequest<API.ListTicketActivityResponse> { API.listTicketActivity(key: ticketKey) }
    private var runsReq: APIRequest<API.ListRunsResponse> { API.listRuns(state: .all, ticket: ticketKey) }

    var body: some View {
        let store = context.store
        let ticketEntry = store.entry(ticketReq)
        let ticket = ticketEntry.data
        let siblingProject = queryProject ?? ticket?.project.key
        let siblingsReq = API.listTickets(project: siblingProject, view: .all)
        let siblings = store.entry(siblingsReq).data?.tickets ?? []
        let events = store.entry(activityReq).data?.events ?? []
        let runsData = store.entry(runsReq).data
        let runs = runsData?.runs ?? []
        let runsHasMore = runsData?.hasMore ?? false
        let bootstrap = store.entry(Self.bootstrapReq).data
        let backlinks = ticket.flatMap { store.entry(API.getBacklinks(kind: .ticket, id: $0.id)).data }

        let chrome = buildChrome(
            ticket: ticket, siblingProject: siblingProject, siblings: siblings,
            runs: runs, runsHasMore: runsHasMore, bootstrap: bootstrap, backlinks: backlinks
        )

        Group {
            if let ticket {
                contentBody(
                    ticket: ticket, events: events, runs: runs,
                    runsHasMore: runsHasMore, siblings: siblings, bootstrap: bootstrap
                )
            } else if let error = ticketEntry.error {
                QueryErrorView(message: "Couldn\u{2019}t load \(ticketKey): \(error.userMessage)") {
                    Task { await store.refetch(ticketReq) }
                }
            } else {
                loadingSkeleton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.background)
        .onChange(of: chrome, initial: true) { _, next in context.chrome = next }
        .task(id: ticketKey) { model.resetForTicket() }
        .task(id: watchSignature(project: siblingProject, ticketId: ticket?.id)) {
            syncWatches(project: siblingProject, ticketId: ticket?.id)
        }
        .task(id: model.showAttachArtifact) {
            if model.showAttachArtifact, let key = ticket?.project.key {
                store.load(API.listArtifacts(project: key))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                model.now = Date()
            }
        }
        .onAppear {
            let model = model
            let context = context
            context.onCommand = { command in Self.handleCommand(command, model: model, context: context) }
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
        .sheet(isPresented: $model.showDispatchSheet) {
            WorkDispatchSheet(keys: [ticketKey]) { model.showDispatchSheet = false }
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
    }

    // MARK: Data Observation & Chrome

    private func watchSignature(project: String?, ticketId: String?) -> String {
        "\(ticketKey)|\(project ?? "")|\(ticketId ?? "")"
    }

    private func syncWatches(project: String?, ticketId: String?) {
        guard !ticketKey.isEmpty else { return }
        let store = context.store
        for key in watchedKeys { store.stopObserving(key) }
        func start<V: Sendable>(_ request: APIRequest<V>) -> QueryKey {
            store.observe(request)
            store.load(request)
            return request.key
        }
        var next = [
            start(ticketReq), start(activityReq), start(runsReq),
            start(API.listTickets(project: project, view: .all)),
            start(Self.bootstrapReq), start(Self.personasReq),
        ]
        if let ticketId, !ticketId.isEmpty {
            next.append(start(API.getBacklinks(kind: .ticket, id: ticketId)))
        }
        watchedKeys = next
    }

    private func buildChrome(
        ticket: API.Ticket?, siblingProject: String?, siblings: [API.TicketSummary],
        runs: [API.Run], runsHasMore: Bool, bootstrap: API.Bootstrap?, backlinks: API.Backlinks?
    ) -> NativeChrome {
        let pager = TicketDetailLogic.pager(for: ticketKey, in: siblings)
        let cost = TicketDetailLogic.runsCostSummary(runs, hasMore: runsHasMore)
        let inspector = ticket.map {
            TicketDetailLogic.buildInspectorModel(
                ticket: $0, bootstrap: bootstrap, runs: runs, runsHasMore: runsHasMore,
                backlinks: backlinks, canEditBlockedBy: !TicketDetailLogic.hasLiveRun($0),
                saveError: model.saveError, open: model.inspectorOpen,
                activeTabId: model.inspectorTabId, now: model.now
            )
        }
        let nav = TicketsNav.detailModel(
            TicketsNav.DetailInput(project: siblingProject, siblings: siblings, ticketKey: ticketKey)
        )
        return NativeChrome(
            title: ticket.map { "\($0.key) \u{00B7} \($0.title)" } ?? ticketKey,
            subtitle: ticket.map { TicketsLogic.statusLabel($0.status) },
            toolbarItems: TicketDetailLogic.buildToolbar(cost: cost, pager: pager, copied: model.copiedLink),
            inspector: inspector,
            navigator: nav
        )
    }

    // MARK: Commands

    @MainActor
    private static func handleCommand(_ command: NativeCommand, model: TicketDetailModel, context: NativeScreenContext) {
        let key = context.match.params["key"] ?? ""
        let ticket = context.store.entry(API.getTicket(key: key)).data
        let project = context.match.query["project"] ?? ticket?.project.key

        if let navAction = TicketsNav.action(for: command, navigatorId: TicketsNav.detailNavId, project: project) {
            if case .open(let href, let newTab) = navAction {
                newTab ? context.openInNewTab(href) : context.navigate(href)
            }
            return
        }

        switch command {
        case .inspectorVisibility(let open):
            model.inspectorOpen = open
        case .inspectorSelectTab(let tabId):
            model.inspectorTabId = tabId
        case .toolbarAction(let itemId, _):
            guard let action = TicketDetailLogic.toolbarAction(for: itemId) else { return }
            let siblings = context.store.entry(API.listTickets(project: project, view: .all)).data?.tickets ?? []
            let pager = TicketDetailLogic.pager(for: key, in: siblings)
            switch action {
            case .cost:
                model.scrollTarget = "runs"
            case .prev:
                if let prev = pager.prevKey { context.navigate(TicketsLogic.ticketHref(prev)) }
            case .next:
                if let next = pager.nextKey { context.navigate(TicketsLogic.ticketHref(next)) }
            case .copy:
                let href = TicketsLogic.ticketHref(key)
                context.copyToClipboard(context.resolvedURL(href)?.absoluteString ?? href)
                model.copiedLink = true
                context.showToast(ToastItemModel(id: "ticket.copy.\(key)", title: "Copied link to \(key)", tone: .success))
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    model.copiedLink = false
                }
            }
        case .inspectorChange(_, let fieldId, let value):
            guard let ticket else { return }
            handleInspectorChange(fieldId: fieldId, value: value, ticket: ticket, model: model, context: context)
        case .inspectorToggle(_, fieldId: "requires_mockup", let checked):
            guard let ticket else { return }
            var patch = API.TicketPatch(revision: ticket.revision)
            patch.requiresMockup = checked
            Task { await applyPatch(ticketKey: ticket.key, patch: patch, description: "Mockup requirement", model: model, context: context) }
        case .inspectorAction(_, let actionId, let itemId, let menuItemId):
            guard let ticket else { return }
            handleInspectorAction(actionId: actionId, itemId: itemId, menuItemId: menuItemId, ticket: ticket, model: model, context: context)
        default:
            break
        }
    }

    @MainActor
    private static func handleInspectorChange(
        fieldId: String, value: String, ticket: API.Ticket, model: TicketDetailModel, context: NativeScreenContext
    ) {
        var patch = API.TicketPatch(revision: ticket.revision)
        switch fieldId {
        case "status": patch.status = API.TicketStatus(rawValue: value)
        case "priority": patch.priority = API.Priority(rawValue: value)
        case "assignee_agent_id": patch.assigneeAgentId = value.isEmpty ? .null : .value(value)
        case "reviewer_user_id": patch.reviewerUserId = value.isEmpty ? .null : .value(value)
        case "epic_id": patch.epicId = value.isEmpty ? .null : .value(value)
        case "estimate_points": patch.estimatePoints = Int(value).map(APINullable.value) ?? .null
        case "due_date":
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            patch.dueDate = trimmed.isEmpty ? .null : .value(trimmed)
        default: return
        }
        Task { await applyPatch(ticketKey: ticket.key, patch: patch, description: fieldId, model: model, context: context) }
    }

    @MainActor
    private static func handleInspectorAction(
        actionId: String, itemId: String?, menuItemId: String?, ticket: API.Ticket, model: TicketDetailModel, context: NativeScreenContext
    ) {
        switch actionId {
        case "labels":
            var ids = ticket.labels.map(\.id)
            if let itemId {
                ids.removeAll { $0 == itemId }
            } else if let menuItemId {
                if ids.contains(menuItemId) { ids.removeAll { $0 == menuItemId } } else { ids.append(menuItemId) }
            } else {
                return
            }
            var patch = API.TicketPatch(revision: ticket.revision)
            patch.labelIds = ids
            Task { await applyPatch(ticketKey: ticket.key, patch: patch, description: "Labels", model: model, context: context) }
        case "remove_blocked_by":
            guard let key = itemId, menuItemId == "remove" || menuItemId == nil else { return }
            let next = TicketDetailLogic.updatedBlockerKeys(current: ticket.blockedBy, removing: key)
            Task { await saveDependencies(key: ticket.key, blockedBy: next, revision: ticket.dependencyRevision, model: model, context: context) }
        case "remove_blocks":
            guard let otherKey = itemId, menuItemId == "remove" || menuItemId == nil else { return }
            Task { await removeBlocksLink(otherKey: otherKey, currentKey: ticket.key, model: model, context: context) }
        case "link_mention":
            guard let itemId, let sep = itemId.firstIndex(of: ":") else { return }
            let rawKind = String(itemId[..<sep])
            let sourceId = String(itemId[itemId.index(after: sep)...])
            let sourceKind = API.LinkMentionBody.SourceKind(rawValue: rawKind)
            guard API.LinkMentionBody.SourceKind.allKnown.contains(sourceKind) else { return }
            Task { await linkMention(ticket: ticket, sourceId: sourceId, sourceKind: sourceKind, context: context) }
        default:
            break
        }
    }

    // MARK: Main Content

    private func contentBody(
        ticket: API.Ticket, events: [API.ActivityEvent], runs: [API.Run],
        runsHasMore: Bool, siblings: [API.TicketSummary], bootstrap: API.Bootstrap?
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let conflict = model.saveConflict {
                        conflictBanner(conflict, ticket: ticket)
                    }
                    if let saveError = model.saveError {
                        errorBanner(saveError) { model.saveError = nil }
                    }
                    headerCard(ticket: ticket, bootstrap: bootstrap)
                    gatesSection(ticket: ticket, proxy: proxy)
                    descriptionCard(ticket: ticket)
                    criteriaSection(ticket: ticket, events: events)
                    dependenciesCard(ticket: ticket, siblings: siblings).id("blocked-by")
                    if ticket.pr != nil || !(ticket.branch ?? "").isEmpty {
                        codeCard(ticket: ticket).id("code")
                    }
                    runsCard(runs: runs, hasMore: runsHasMore).id("runs")
                    artifactsCard(ticket: ticket).id("mockups")
                    timelineCard(ticket: ticket, events: events)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                model.scrollTarget = nil
            }
        }
    }

    private func conflictBanner(_ conflict: TicketDetailLogic.SaveConflict, ticket: API.Ticket) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This ticket changed while you were editing (\(conflict.description))")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                Text("Reloaded the latest version. Overwrite with your changes or discard them.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.secondaryText)
            }
            Spacer()
            Button("Discard") { model.saveConflict = nil }.buttonStyle(.vesper())
            Button("Overwrite") {
                var retry = conflict.patch
                retry.revision = ticket.revision
                if let c = retry.criteria {
                    retry.criteria = API.TicketCriteriaDraft(expected: ticket.criteria, items: c.items)
                }
                model.saveConflict = nil
                Task { await Self.applyPatch(ticketKey: ticket.key, patch: retry, description: conflict.description, model: model, context: context) }
            }
            .buttonStyle(.vesper(.approve))
        }
        .padding(14)
        .background(theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: theme.pointSize(.body)))
                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            Spacer()
            Button("Dismiss", action: onDismiss).buttonStyle(.vesper())
        }
        .padding(12)
        .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Header & Properties

    private func headerCard(ticket: API.Ticket, bootstrap: API.Bootstrap?) -> some View {
        let closed = ticket.status == .done || ticket.status == .canceled
        let agents = (bootstrap?.agents ?? []).filter { $0.kind == .main }
        let epics = (bootstrap?.epics ?? []).filter { $0.projectId == ticket.project.id }
        let labels = bootstrap?.labels ?? []

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    context.copyToClipboard(ticket.key)
                    context.showToast(ToastItemModel(id: "key.\(ticket.key)", title: "Copied \(ticket.key)", tone: .success))
                } label: {
                    Text(ticket.key)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Copy ticket key")

                Text(ticket.project.name)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)

                Spacer()

                if TicketDetailLogic.hasLiveRun(ticket), let run = ticket.run {
                    let badge = TicketDetailLogic.runStateBadge(run.state)
                    Button {
                        context.navigate("/runs/\(Self.encodePathSegment(run.id))")
                    } label: {
                        HStack(spacing: 6) {
                            TonePill(label: badge.label, tone: badge.tone)
                            Text("View run")
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                        }
                    }
                    .buttonStyle(.vesper())
                } else if ticket.assignee != nil && !closed {
                    Button {
                        model.showDispatchSheet = true
                    } label: {
                        Label("Start run", systemImage: "play.fill")
                    }
                    .buttonStyle(.vesper(.primary))
                }
            }

            if model.editingTitle {
                HStack(spacing: 8) {
                    TextField("Ticket title", text: $model.titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: theme.pointSize(.title), weight: .semibold))
                        .onSubmit { saveTitle(ticket) }
                    Button("Save") { saveTitle(ticket) }
                        .buttonStyle(.vesper(.primary))
                        .disabled(model.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving)
                    Button("Cancel") { model.editingTitle = false }.buttonStyle(.vesper())
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Text(ticket.title)
                        .vesperText(.title, theme)
                        .foregroundStyle(theme.palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        model.titleDraft = ticket.title
                        model.editingTitle = true
                    } label: {
                        Image(systemName: SidebarIcons.symbolName("edit"))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(5)
                    }
                    .buttonStyle(.plain)
                    .help("Edit title")
                }
            }

            if TicketDetailLogic.needsDispatch(ticket) {
                HStack(spacing: 12) {
                    Text(TicketDetailLogic.dispatchHint(for: ticket))
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                    Spacer()
                    Button("Dispatch") { model.showDispatchSheet = true }
                        .buttonStyle(.vesper(.approve))
                        .controlSize(.small)
                }
                .padding(10)
                .background(theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.1)), in: RoundedRectangle(cornerRadius: 8))
            }

            FlowLayout(spacing: 8) {
                Menu {
                    ForEach(TicketsLogic.statusOrder, id: \.rawValue) { status in
                        Button {
                            patchField(ticket, description: "Status") { $0.status = status }
                        } label: {
                            status == ticket.status
                                ? Label(TicketsLogic.statusLabel(status), systemImage: "checkmark")
                                : Label(TicketsLogic.statusLabel(status), systemImage: "circle")
                        }
                    }
                } label: {
                    propertyPill { TicketStatusBadge(status: ticket.status, showsLabel: true) }
                }
                .menuStyle(.borderlessButton)

                Menu {
                    ForEach(TicketsLogic.priorityOrder, id: \.rawValue) { priority in
                        Button {
                            patchField(ticket, description: "Priority") { $0.priority = priority }
                        } label: {
                            priority == ticket.priority
                                ? Label(TicketsLogic.priorityLabel(priority), systemImage: "checkmark")
                                : Label(TicketsLogic.priorityLabel(priority), systemImage: "minus")
                        }
                    }
                } label: {
                    propertyPill { TicketPriorityBadge(priority: ticket.priority, showsLabel: true) }
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button("Unassigned") { patchField(ticket, description: "Assignee") { $0.assigneeAgentId = .null } }
                    if !agents.isEmpty { Divider() }
                    ForEach(agents, id: \.id) { agent in
                        Button(agent.name) { patchField(ticket, description: "Assignee") { $0.assigneeAgentId = .value(agent.id) } }
                    }
                } label: {
                    propertyPill {
                        HStack(spacing: 6) {
                            if let assignee = ticket.assignee {
                                WorkPersonaAvatarView(agent: assignee, size: 16)
                                Text(assignee.name).font(.system(size: theme.pointSize(.small)))
                            } else {
                                UnassignedAvatarCircle(size: 16)
                                Text("Unassigned")
                                    .font(.system(size: theme.pointSize(.small)))
                                    .foregroundStyle(theme.palette.tertiaryText)
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button("Unestimated") { patchField(ticket, description: "Estimate") { $0.estimatePoints = .null } }
                    Divider()
                    ForEach(TicketsLogic.estimateScale, id: \.self) { pts in
                        Button("\(pts) pts") { patchField(ticket, description: "Estimate") { $0.estimatePoints = .value(pts) } }
                    }
                } label: {
                    propertyPill {
                        if let pts = ticket.estimatePoints {
                            TicketEstimateBadge(points: pts, compact: true, showUnit: true)
                        } else {
                            Text("Unestimated")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .disabled(closed)

                Menu {
                    Button("No epic") { patchField(ticket, description: "Epic") { $0.epicId = .null } }
                    if !epics.isEmpty { Divider() }
                    ForEach(epics, id: \.id) { epic in
                        Button(epic.name) { patchField(ticket, description: "Epic") { $0.epicId = .value(epic.id) } }
                    }
                } label: {
                    propertyPill {
                        if let epic = ticket.epic {
                            TicketEpicChip(epic: epic)
                        } else {
                            Text("No epic")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                    }
                }
                .menuStyle(.borderlessButton)

                Button {
                    model.dueDateDraft = ticket.dueDate ?? ""
                    model.editingDueDate = true
                } label: {
                    propertyPill {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.palette.tertiaryText)
                            Text(ticket.dueDate.map { TicketDetailLogic.formatDueDate($0) } ?? "Due date")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(ticket.dueDate == nil ? theme.palette.tertiaryText : theme.palette.secondaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .popover(isPresented: $model.editingDueDate) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Due date (YYYY-MM-DD)").font(.system(size: theme.pointSize(.small), weight: .semibold))
                        TextField("2026-12-31", text: $model.dueDateDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                            .onSubmit { saveDueDate(ticket) }
                        HStack {
                            if ticket.dueDate != nil {
                                Button("Clear") {
                                    model.editingDueDate = false
                                    patchField(ticket, description: "Due date") { $0.dueDate = .null }
                                }
                                .buttonStyle(.vesper())
                            }
                            Spacer()
                            Button("Save") { saveDueDate(ticket) }.buttonStyle(.vesper(.primary))
                        }
                    }
                    .padding(12)
                }

                ForEach(ticket.labels, id: \.id) { label in
                    TicketLabelChip(label: label)
                }

                if !labels.isEmpty {
                    let activeIds = Set(ticket.labels.map(\.id))
                    Menu {
                        ForEach(labels, id: \.id) { label in
                            Button {
                                var next = ticket.labels.map(\.id)
                                if activeIds.contains(label.id) { next.removeAll { $0 == label.id } } else { next.append(label.id) }
                                patchField(ticket, description: "Labels") { $0.labelIds = next }
                            } label: {
                                if activeIds.contains(label.id) {
                                    Label(label.name, systemImage: "checkmark")
                                } else {
                                    Text(label.name)
                                }
                            }
                        }
                    } label: {
                        propertyPill {
                            Label("Labels", systemImage: "plus")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.secondaryText)
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
        .padding(18)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border.opacity(0.75)))
    }

    private func propertyPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border.opacity(0.6)))
    }

    // MARK: Gates & Approvals

    @ViewBuilder
    private func gatesSection(ticket: API.Ticket, proxy: ScrollViewProxy) -> some View {
        let gates = TicketDetailLogic.unmetGates(for: ticket, now: model.now)
        let pendingApprovals = ticket.approvals.filter { $0.state == .pending }

        if !gates.isEmpty || !pendingApprovals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(gates) { gate in
                    HStack(spacing: 12) {
                        Image(systemName: SidebarIcons.symbolName(gate.icon))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gate.title)
                                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                            Text(gate.detail)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.secondaryText)
                        }
                        Spacer()
                        Button(gate.actionLabel) {
                            switch gate.destination {
                            case .section(let id):
                                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                            case .route(let path):
                                context.navigate(path)
                            case .externalURL(let url):
                                context.openExternal(url)
                            }
                        }
                        .buttonStyle(.vesper())
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.1)), in: RoundedRectangle(cornerRadius: 10))
                }

                ForEach(pendingApprovals, id: \.id) { approval in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            WorkPersonaAvatarView(agent: approval.agent, size: 20)
                            Text("@\(approval.agent.handle) requests approval for \(approval.scope)")
                                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                            Spacer()
                            Text(APIDate.shortAgo(approval.createdAt, now: model.now))
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                        Text(approval.actionSummary)
                            .font(.system(size: theme.pointSize(.body)))
                            .foregroundStyle(theme.palette.secondaryText)
                        if !approval.riskSummary.isEmpty {
                            Text(approval.riskSummary)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                        HStack(spacing: 8) {
                            Button("Approve") {
                                Task { await decideApproval(approval, decision: .approve) }
                            }
                            .buttonStyle(.vesper(.approve))
                            .disabled(model.decidingApprovalId == approval.id)
                            Button("Deny") {
                                Task { await decideApproval(approval, decision: .deny) }
                            }
                            .buttonStyle(.vesper(.danger))
                            .disabled(model.decidingApprovalId == approval.id)
                        }
                    }
                    .padding(14)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.swiftUIColor("state-human", fallback: .orange).opacity(0.5)))
                    .id("approval-\(approval.id)")
                }
            }
        }
    }

    // MARK: Description

    private func descriptionCard(ticket: API.Ticket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Description")
                Spacer()
                if !model.editingDescription {
                    Button("Edit") {
                        model.descriptionDraft = ticket.descriptionMd
                        model.editingDescription = true
                    }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                }
            }

            if model.editingDescription {
                TextEditor(text: $model.descriptionDraft)
                    .font(.system(size: theme.pointSize(.body), design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                HStack {
                    Spacer()
                    Button("Cancel") { model.editingDescription = false }.buttonStyle(.vesper())
                    Button("Save") {
                        let base = TicketDetailLogic.snapshot(from: ticket)
                        var draft = TicketDetailLogic.draft(from: base)
                        draft.descriptionMd = model.descriptionDraft
                        model.editingDescription = false
                        guard TicketDetailLogic.isValidDescriptionChange(original: ticket.descriptionMd, draft: model.descriptionDraft),
                              let patch = TicketDetailLogic.buildPatch(base: base, draft: draft)
                        else { return }
                        Task { await Self.applyPatch(ticketKey: ticket.key, patch: patch, description: "Description", model: model, context: context) }
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(model.saving)
                }
            } else if ticket.descriptionMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description yet.")
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                MarkdownView(markdown: ticket.descriptionMd, textStyle: .reading, textColor: "text-secondary")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle(theme)
    }

    // MARK: Acceptance Criteria

    @ViewBuilder
    private func criteriaSection(ticket: API.Ticket, events: [API.ActivityEvent]) -> some View {
        if model.editingCriteria, let base = model.criteriaBase, let draft = model.criteriaDraft {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionHeader("Edit acceptance criteria")
                    Spacer()
                    Button("Cancel") { model.editingCriteria = false }.buttonStyle(.vesper()).controlSize(.small)
                    Button("Save") {
                        model.editingCriteria = false
                        guard let patch = TicketDetailLogic.buildPatch(base: base, draft: draft) else { return }
                        Task { await Self.applyPatch(ticketKey: ticket.key, patch: patch, description: "Acceptance criteria", model: model, context: context) }
                    }
                    .buttonStyle(.vesper(.primary))
                    .controlSize(.small)
                    .disabled(!TicketDetailLogic.criteriaChanged(base: base, draft: draft) || model.saving)
                }

                ForEach(Array(draft.criteria.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 8) {
                        Button {
                            model.criteriaDraft?.criteria[idx].done.toggle()
                        } label: {
                            Image(systemName: item.done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(item.done ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.tertiaryText)
                        }
                        .buttonStyle(.plain)

                        TextField("Criterion", text: Binding(
                            get: { model.criteriaDraft?.criteria[safe: idx]?.text ?? "" },
                            set: { model.criteriaDraft?.criteria[safe: idx]?.text = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button {
                            if let cur = model.criteriaDraft?.criteria {
                                model.criteriaDraft?.criteria = TicketDetailLogic.moveCriterion(cur, at: idx, delta: -1)
                            }
                        } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.plain).disabled(idx == 0)

                        Button {
                            if let cur = model.criteriaDraft?.criteria {
                                model.criteriaDraft?.criteria = TicketDetailLogic.moveCriterion(cur, at: idx, delta: 1)
                            }
                        } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.plain).disabled(idx == draft.criteria.count - 1)

                        Button {
                            model.criteriaDraft?.criteria.remove(at: idx)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(theme.palette.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    model.criteriaDraft?.criteria.append(TicketDetailLogic.DraftCriterion())
                } label: {
                    Label("Add criterion", systemImage: "plus")
                }
                .buttonStyle(.vesper())
                .controlSize(.small)
            }
            .cardStyle(theme)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                TicketCriteriaListView(
                    criteria: ticket.criteria,
                    checkedBy: TicketDetailLogic.checkedByMap(from: events),
                    readOnly: model.saving,
                    errorMessage: model.criteriaError,
                    onToggle: { criterion, done in
                        Task { await toggleCriterion(ticket: ticket, criterion: criterion, done: done) }
                    },
                    onDelete: { id in
                        let base = TicketDetailLogic.snapshot(from: ticket)
                        var draft = TicketDetailLogic.draft(from: base)
                        draft.criteria.removeAll { $0.criterionId == id }
                        guard let patch = TicketDetailLogic.buildPatch(base: base, draft: draft) else { return }
                        Task { await Self.applyPatch(ticketKey: ticket.key, patch: patch, description: "Remove criterion", model: model, context: context) }
                    },
                    onAdd: { text in
                        let base = TicketDetailLogic.snapshot(from: ticket)
                        var draft = TicketDetailLogic.draft(from: base)
                        draft.criteria.append(TicketDetailLogic.DraftCriterion(text: text, done: false))
                        guard let patch = TicketDetailLogic.buildPatch(base: base, draft: draft) else { return }
                        Task { await Self.applyPatch(ticketKey: ticket.key, patch: patch, description: "Add criterion", model: model, context: context) }
                    }
                )
                Button("Reorder / edit all") {
                    let base = TicketDetailLogic.snapshot(from: ticket)
                    model.criteriaBase = base
                    model.criteriaDraft = TicketDetailLogic.draft(from: base)
                    model.editingCriteria = true
                }
                .buttonStyle(.plain)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.tertiaryText)
            }
        }
    }

    // MARK: Dependencies

    private func dependenciesCard(ticket: API.Ticket, siblings: [API.TicketSummary]) -> some View {
        let locked = TicketDetailLogic.hasLiveRun(ticket) || model.savingDependencies
        let excluded = Set([ticket.key] + ticket.blockedBy.map(\.key) + ticket.blocks.map(\.key))
        let candidates = TicketDetailLogic.blockerCandidates(from: siblings, excluding: excluded)

        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Dependencies")

            VStack(alignment: .leading, spacing: 6) {
                Text("Blocked by")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.secondaryText)
                if ticket.blockedBy.isEmpty {
                    Text("No blockers.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(ticket.blockedBy, id: \.key) { dep in
                            dependencyChip(dep, removable: !locked) {
                                let next = TicketDetailLogic.updatedBlockerKeys(current: ticket.blockedBy, removing: dep.key)
                                Task { await Self.saveDependencies(key: ticket.key, blockedBy: next, revision: ticket.dependencyRevision, model: model, context: context) }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Add blocker key (e.g. LAZYAGENTS-42)", text: $model.blockerInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(locked)
                    .onSubmit { addBlocker(ticket, raw: model.blockerInput) }
                Button("Add") { addBlocker(ticket, raw: model.blockerInput) }
                    .buttonStyle(.vesper())
                    .disabled(locked || model.blockerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !candidates.isEmpty && !locked {
                FlowLayout(spacing: 6) {
                    ForEach(candidates, id: \.key) { cand in
                        Button("+ \(cand.key)") { addBlocker(ticket, raw: cand.key) }
                            .buttonStyle(.vesper())
                            .controlSize(.small)
                            .help(cand.title)
                    }
                }
            }

            if let err = model.blockerError {
                Text(err).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            if !ticket.blocks.isEmpty {
                Divider()
                Text("Blocks")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.secondaryText)
                FlowLayout(spacing: 6) {
                    ForEach(ticket.blocks, id: \.key) { dep in
                        dependencyChip(dep, removable: !model.savingDependencies) {
                            Task { await Self.removeBlocksLink(otherKey: dep.key, currentKey: ticket.key, model: model, context: context) }
                        }
                    }
                }
            }
        }
        .cardStyle(theme)
    }

    private func dependencyChip(_ dep: API.TicketDependency, removable: Bool, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button {
                context.navigate(TicketsLogic.ticketHref(dep.key))
            } label: {
                HStack(spacing: 5) {
                    TicketStatusBadge(status: dep.status, size: 11)
                    Text(dep.key).font(.system(size: theme.pointSize(.small), weight: .medium, design: .monospaced))
                    Text(dep.title).font(.system(size: theme.pointSize(.small))).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border.opacity(0.6)))
    }

    // MARK: Code, Runs & Artifacts

    private func codeCard(ticket: API.Ticket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Code & pull request")
            if let branch = ticket.branch, !branch.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: SidebarIcons.symbolName("branch")).foregroundStyle(theme.palette.tertiaryText)
                    Button {
                        context.copyToClipboard(branch)
                        context.showToast(ToastItemModel(id: "branch.\(branch)", title: "Copied branch \(branch)", tone: .success))
                    } label: {
                        Text(branch).font(.system(size: theme.pointSize(.small), design: .monospaced)).textSelection(.enabled)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let pr = ticket.pr {
                let prTone = pr.state == .merged ? "done" : (pr.closedUnmerged == true ? "blocked" : (pr.state == .draft ? "neutral" : "review"))
                HStack(spacing: 10) {
                    Image(systemName: SidebarIcons.symbolName("pr")).foregroundStyle(theme.palette.secondaryText)
                    Text("#\(pr.number)").font(.system(size: theme.pointSize(.body), weight: .semibold, design: .monospaced))
                    TonePill(label: pr.state.rawValue.capitalized, tone: prTone)
                    if let add = pr.additions {
                        Text("+\(add) \u{2212}\(pr.deletions ?? 0)")
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(theme.palette.secondaryText)
                    }
                    Spacer()
                    if let url = pr.url {
                        Button("Open PR") { context.openExternal(url) }.buttonStyle(.vesper()).controlSize(.small)
                    }
                }
                if pr.closedUnmerged == true {
                    Text("PR closed without merging.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                if let fb = pr.feedback, fb.failedChecksCount > 0 || fb.unresolvedThreads > 0 {
                    HStack(spacing: 10) {
                        Text("\(fb.failedChecksCount) failed checks \u{00B7} \(fb.unresolvedThreads) unresolved threads")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.secondaryText)
                        Spacer()
                        if fb.failedChecksCount > 0 {
                            Button("Fix CI") { Task { await addressPRFeedback(ticket: ticket, mode: .ci) } }
                                .buttonStyle(.vesper()).controlSize(.small).disabled(model.sendingPRFeedback)
                        }
                        if fb.unresolvedThreads > 0 {
                            Button("Address review") { Task { await addressPRFeedback(ticket: ticket, mode: .review) } }
                                .buttonStyle(.vesper()).controlSize(.small).disabled(model.sendingPRFeedback)
                        }
                        if fb.failedChecksCount > 0 && fb.unresolvedThreads > 0 {
                            Button("Address all") { Task { await addressPRFeedback(ticket: ticket, mode: .all) } }
                                .buttonStyle(.vesper(.primary)).controlSize(.small).disabled(model.sendingPRFeedback)
                        }
                    }
                    .padding(10)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .cardStyle(theme)
    }

    private func runsCard(runs: [API.Run], hasMore: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Runs")
                Spacer()
                if let summary = TicketDetailLogic.runsCostSummary(runs, hasMore: hasMore) {
                    Text(summary)
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            if runs.isEmpty {
                Text("No runs yet.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                ForEach(runs, id: \.id) { run in
                    let badge = TicketDetailLogic.runStateBadge(run.state)
                    let path = "/runs/\(Self.encodePathSegment(run.id))"
                    let when = run.endedAt != nil
                        ? "\(APIDate.timeline(run.startedAt, now: model.now)) \u{00B7} \(APIDate.duration(since: run.startedAt, until: run.endedAt, now: model.now))"
                        : "Started \(APIDate.shortAgo(run.startedAt, now: model.now))"
                    Button { context.navigate(path) } label: {
                        HStack(spacing: 10) {
                            WorkPersonaAvatarView(agent: run.agent, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("@\(run.agent.handle)").font(.system(size: theme.pointSize(.body), weight: .medium))
                                    TonePill(label: badge.label, tone: badge.tone)
                                }
                                Text("\(when) \u{00B7} \(run.model) \u{00B7} \(TicketDetailLogic.formatCompactNumber(run.inputTokens + run.outputTokens)) tok")
                                    .font(.system(size: theme.pointSize(.small)))
                                    .foregroundStyle(theme.palette.tertiaryText)
                            }
                            Spacer()
                            Text(WorkLogic.runCost(run.costUsd, source: run.costSource))
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(theme.palette.secondaryText)
                        }
                        .padding(8)
                        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open run") { context.navigate(path) }
                        Button("Open in new tab") { context.openInNewTab(path) }
                    }
                }
            }
        }
        .cardStyle(theme)
    }

    private func artifactsCard(ticket: API.Ticket) -> some View {
        let attachedIds = Set(ticket.artifacts.map(\.id))
        let available = (context.store.entry(API.listArtifacts(project: ticket.project.key)).data?.artifacts ?? [])
            .filter { !attachedIds.contains($0.id) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Artifacts")
                Spacer()
                Button("Attach") { model.showAttachArtifact = true }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                    .popover(isPresented: $model.showAttachArtifact) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Attach artifact").font(.system(size: theme.pointSize(.body), weight: .semibold))
                            if available.isEmpty {
                                Text("No available artifacts in \(ticket.project.key).")
                                    .font(.system(size: theme.pointSize(.small)))
                                    .foregroundStyle(theme.palette.tertiaryText)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(available.prefix(30), id: \.id) { item in
                                            Button {
                                                model.showAttachArtifact = false
                                                Task { await attachArtifact(ticket: ticket, artifactId: item.id) }
                                            } label: {
                                                HStack {
                                                    Text(item.displayId ?? item.type.rawValue.uppercased())
                                                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                                        .foregroundStyle(theme.palette.tertiaryText)
                                                    Text(item.title).lineLimit(1)
                                                    Spacer()
                                                }
                                                .padding(.vertical, 4)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .frame(maxHeight: 240)
                            }
                        }
                        .padding(12)
                        .frame(width: 300)
                    }
            }

            if ticket.artifacts.isEmpty {
                Text("No artifacts attached.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                ForEach(ticket.artifacts, id: \.id) { doc in
                    let route = (doc.type == .mockup && ticket.mockupGate.required)
                        ? "/artifacts/\(Self.encodePathSegment(doc.id))/review?ticket=\(Self.encodePathSegment(ticket.key))"
                        : "/artifacts/\(Self.encodePathSegment(doc.id))"
                    HStack(spacing: 10) {
                        Button { context.navigate(route) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: SidebarIcons.symbolName("artifacts")).foregroundStyle(theme.palette.tertiaryText)
                                if let did = doc.displayId {
                                    Text(did).font(.system(size: theme.pointSize(.small), design: .monospaced)).foregroundStyle(theme.palette.tertiaryText)
                                }
                                Text(doc.title).font(.system(size: theme.pointSize(.body), weight: .medium)).lineLimit(1)
                                if let ver = doc.versionLabel {
                                    Text(ver).font(.system(size: theme.pointSize(.small), design: .monospaced)).foregroundStyle(theme.palette.tertiaryText)
                                }
                                if let rev = doc.reviewState {
                                    TonePill(
                                        label: rev.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                                        tone: rev == .approved ? "done" : "human"
                                    )
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await openQuickLook(doc) }
                        } label: {
                            Image(systemName: "eye").foregroundStyle(theme.palette.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.openingQuickLookId == doc.id)
                        .help("Quick Look")

                        Button {
                            Task { await detachArtifact(ticket: ticket, artifactId: doc.id) }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(theme.palette.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Detach")
                    }
                    .padding(8)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .cardStyle(theme)
    }

    // MARK: Timeline & Comments

    private func timelineCard(ticket: API.Ticket, events: [API.ActivityEvent]) -> some View {
        let entries = TicketDetailLogic.buildTimeline(events: events, liveRunId: ticket.run?.id)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Activity & comments")

            if entries.isEmpty {
                Text("No activity yet.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                ForEach(entries) { entry in
                    if entry.isComment {
                        commentView(entry, ticket: ticket)
                    } else {
                        activityRow(entry.event)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let parentId = model.replyingToCommentId {
                    HStack {
                        Text("Replying to comment \(parentId.prefix(8))")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.secondaryText)
                        Spacer()
                        Button("Cancel reply") { model.replyingToCommentId = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small)))
                    }
                }
                TextEditor(text: $model.commentDraft)
                    .font(.system(size: theme.pointSize(.body)))
                    .frame(minHeight: 72)
                    .padding(6)
                    .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                HStack {
                    if let err = model.commentError {
                        Text(err).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }
                    Spacer()
                    Button("Post comment") {
                        Task { await submitComment(ticket: ticket) }
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(model.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.sendingComment)
                }
            }
        }
        .cardStyle(theme)
    }

    private func commentView(_ entry: TicketDetailLogic.TimelineEntry, ticket: API.Ticket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            commentBlock(entry.event)
            if !entry.replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entry.replies, id: \.id) { reply in commentBlock(reply) }
                }
                .padding(.leading, 26)
            }
            if let cid = entry.commentId, !cid.isEmpty {
                Button("Reply") { model.replyingToCommentId = cid }
                    .buttonStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 10))
    }

    private func commentBlock(_ event: API.ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                actorAvatar(event.actor)
                Text(event.actor.name).font(.system(size: theme.pointSize(.body), weight: .semibold))
                if let chatId = event.payload["via"]?["chat_id"]?.stringValue, !chatId.isEmpty {
                    Button("from a chat") { context.navigate("/chat/\(Self.encodePathSegment(chatId))") }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                Spacer()
                Text(APIDate.timeline(event.createdAt, now: model.now))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
            MarkdownView(markdown: event.payload["body_md"]?.stringValue ?? "", textStyle: .reading, textColor: "text-secondary")
        }
    }

    private func activityRow(_ event: API.ActivityEvent) -> some View {
        let formatted = TicketDetailLogic.formatActivity(event)
        let dotColor: Color = switch formatted.tone {
        case .done: theme.swiftUIColor("state-done", fallback: .green)
        case .human: theme.swiftUIColor("state-human", fallback: .orange)
        case .blocked: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .normal: theme.palette.tertiaryText
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text("\(event.actor.name) \(formatted.text)")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.secondaryText)
                if let link = formatted.linkPath {
                    Button("Open") { context.navigate(link) }.buttonStyle(.plain).font(.system(size: theme.pointSize(.small)))
                } else if let ext = formatted.externalURL {
                    Button("Open") { context.openExternal(ext) }.buttonStyle(.plain).font(.system(size: theme.pointSize(.small)))
                }
                Spacer()
                Text(APIDate.timeline(event.createdAt, now: model.now))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
            if let quote = formatted.quote, !quote.isEmpty {
                Text(quote)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actorAvatar(_ actor: API.Actor) -> some View {
        if actor.type == .agent {
            WorkPersonaAvatarView(id: actor.id, handle: nil, name: actor.name, colorIndex: actor.colorIndex ?? 0, size: 20)
        } else {
            ZStack {
                Circle().fill(Color(cssHex: actor.avatarColor) ?? theme.palette.selected)
                Text(String((actor.initials ?? String(actor.name.prefix(1))).prefix(2)).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.text)
            }
            .frame(width: 20, height: 20)
        }
    }

    // MARK: Actions

    private func patchField(_ ticket: API.Ticket, description: String, _ mutate: (inout API.TicketPatch) -> Void) {
        var patch = API.TicketPatch(revision: ticket.revision)
        mutate(&patch)
        Task { await Self.applyPatch(ticketKey: ticket.key, patch: patch, description: description, model: model, context: context) }
    }

    private func saveTitle(_ ticket: API.Ticket) {
        let trimmed = model.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.editingTitle = false
        guard trimmed != ticket.title else { return }
        patchField(ticket, description: "Title") { $0.title = trimmed }
    }

    private func saveDueDate(_ ticket: API.Ticket) {
        let trimmed = model.dueDateDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.editingDueDate = false
        patchField(ticket, description: "Due date") { $0.dueDate = trimmed.isEmpty ? .null : .value(trimmed) }
    }

    private func addBlocker(_ ticket: API.Ticket, raw: String) {
        model.blockerError = nil
        guard let next = TicketDetailLogic.updatedBlockerKeys(current: ticket.blockedBy, adding: raw) else {
            model.blockerError = "Enter a valid, non-duplicate ticket key."
            return
        }
        model.blockerInput = ""
        Task { await Self.saveDependencies(key: ticket.key, blockedBy: next, revision: ticket.dependencyRevision, model: model, context: context) }
    }

    @MainActor
    private static func applyPatch(
        ticketKey: String, patch: API.TicketPatch, description: String, model: TicketDetailModel, context: NativeScreenContext
    ) async {
        model.saving = true
        model.saveError = nil
        defer { model.saving = false }
        do {
            let updated = try await context.store.mutate(
                API.updateTicket(key: ticketKey, body: patch),
                invalidating: ticketInvalidation
            )
            context.store.setData(updated, for: API.getTicket(key: ticketKey))
        } catch let error as APIError where TicketDetailLogic.isConflict(error) {
            if let existing = model.saveConflict {
                model.saveConflict = TicketDetailLogic.SaveConflict(
                    patch: TicketDetailLogic.mergePatches(existing.patch, patch),
                    description: "\(existing.description), \(description)"
                )
            } else {
                model.saveConflict = TicketDetailLogic.SaveConflict(patch: patch, description: description)
            }
            _ = await context.store.refetch(API.getTicket(key: ticketKey))
        } catch {
            model.saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func toggleCriterion(ticket: API.Ticket, criterion: API.Criterion, done: Bool) async {
        model.criteriaError = nil
        let optimistic = TicketDetailLogic.toggleCriterionOptimisticUpdate(
            ticketRequest: ticketReq, criterionId: criterion.id, done: done
        )
        do {
            _ = try await context.store.mutate(
                API.updateCriterion(id: criterion.id, body: .init(done: done)),
                optimistic: [optimistic],
                invalidating: Self.ticketInvalidation
            )
        } catch {
            model.criteriaError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private static func saveDependencies(
        key: String, blockedBy: [String], revision: Int, model: TicketDetailModel, context: NativeScreenContext
    ) async {
        model.savingDependencies = true
        model.blockerError = nil
        defer { model.savingDependencies = false }
        do {
            let updated = try await context.store.mutate(
                API.setTicketDependencies(key: key, body: .init(blockedBy: blockedBy, revision: revision)),
                invalidating: ticketInvalidation
            )
            context.store.setData(updated, for: API.getTicket(key: key))
        } catch {
            model.blockerError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private static func removeBlocksLink(
        otherKey: String, currentKey: String, model: TicketDetailModel, context: NativeScreenContext
    ) async {
        model.savingDependencies = true
        model.blockerError = nil
        defer { model.savingDependencies = false }
        do {
            guard let client = context.store.client else { throw APIError.unauthorized }
            let other = try await client.send(API.getTicket(key: otherKey))
            let next = TicketDetailLogic.updatedBlockerKeys(current: other.blockedBy, removing: currentKey)
            let updatedOther = try await context.store.mutate(
                API.setTicketDependencies(key: other.key, body: .init(blockedBy: next, revision: other.dependencyRevision)),
                invalidating: ticketInvalidation
            )
            context.store.setData(updatedOther, for: API.getTicket(key: other.key))
        } catch {
            model.blockerError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func addressPRFeedback(ticket: API.Ticket, mode: API.AddressPRFeedbackRequest.Mode) async {
        model.sendingPRFeedback = true
        defer { model.sendingPRFeedback = false }
        do {
            let run = try await context.store.mutate(
                API.addressTicketPRFeedback(key: ticket.key, body: .init(mode: mode)),
                invalidating: Self.ticketInvalidation
            )
            context.showToast(ToastItemModel(id: "prfb.\(run.id)", title: "Dispatched PR feedback run", tone: .success))
        } catch {
            model.saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func decideApproval(_ approval: API.Approval, decision: API.DecideApprovalDecision) async {
        model.decidingApprovalId = approval.id
        defer { model.decidingApprovalId = nil }
        do {
            _ = try await context.store.mutate(
                API.decideApproval(id: approval.id, decision: decision, body: .init(note: nil)),
                invalidating: Self.ticketInvalidation
            )
        } catch {
            model.saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func attachArtifact(ticket: API.Ticket, artifactId: String) async {
        model.attachingArtifact = true
        defer { model.attachingArtifact = false }
        do {
            let updated = try await context.store.mutate(
                API.attachArtifact(key: ticket.key, body: .init(artifactId: artifactId, relation: .context)),
                invalidating: Self.ticketInvalidation
            )
            context.store.setData(updated, for: ticketReq)
        } catch {
            model.saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func detachArtifact(ticket: API.Ticket, artifactId: String) async {
        do {
            let updated = try await context.store.mutate(
                API.detachArtifact(key: ticket.key, artifactId: artifactId),
                invalidating: Self.ticketInvalidation
            )
            context.store.setData(updated, for: ticketReq)
        } catch {
            model.saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func openQuickLook(_ doc: API.DocCard) async {
        model.openingQuickLookId = doc.id
        defer { model.openingQuickLookId = nil }
        do {
            guard let client = context.store.client else { throw APIError.unauthorized }
            let artifact = try await client.send(API.getArtifact(id: doc.id))
            let url = "/api/v1/artifacts/\(Self.encodePathSegment(doc.id))/versions/\(Self.encodePathSegment(artifact.currentVersion.id))/content"
            let item = QuickLookItem(
                url: url,
                title: artifact.title,
                filename: artifact.currentVersion.content.filename,
                contentType: artifact.currentVersion.content.contentType
            )
            context.showQuickLook([item], index: 0)
        } catch {
            context.showToast(ToastItemModel(id: "ql.\(doc.id)", title: "Couldn\u{2019}t preview artifact", description: (error as? APIError)?.userMessage, tone: .error))
        }
    }

    private func submitComment(ticket: API.Ticket) async {
        let body = model.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        model.sendingComment = true
        model.commentError = nil
        defer { model.sendingComment = false }
        do {
            _ = try await context.store.mutate(
                API.createComment(key: ticket.key, body: .init(bodyMd: body, parentCommentId: model.replyingToCommentId)),
                invalidating: Self.ticketInvalidation
            )
            model.commentDraft = ""
            model.replyingToCommentId = nil
        } catch {
            model.commentError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private static func linkMention(
        ticket: API.Ticket, sourceId: String, sourceKind: API.LinkMentionBody.SourceKind, context: NativeScreenContext
    ) async {
        do {
            _ = try await context.store.mutate(
                API.linkMention(body: .init(sourceId: sourceId, sourceKind: sourceKind, targetId: ticket.id, targetKind: .ticket)),
                invalidating: ticketInvalidation
            )
        } catch {
            context.showToast(ToastItemModel(id: "mention.\(sourceId)", title: "Couldn\u{2019}t link mention", description: (error as? APIError)?.userMessage, tone: .error))
        }
    }

    // MARK: Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.palette.tertiaryText)
    }

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBar(height: 28)
            SkeletonBar(height: 18).frame(maxWidth: 320)
            SkeletonBar(height: 120)
            SkeletonBar(height: 90)
        }
        .padding(28)
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private static func encodePathSegment(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}

private extension View {
    func cardStyle(_ theme: ThemeTokens) -> some View {
        self
            .padding(16)
            .background(theme.palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border.opacity(0.7)))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let newValue else { return }
            self[index] = newValue
        }
    }
}
