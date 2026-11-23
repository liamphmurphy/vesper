import SwiftUI
import VesperCore

/// Native SwiftUI implementation of `/plans` (port of `web/app/(app)/plans/plans-screen.tsx`):
/// sidebar list of planning sessions, New Plan form with space/agent/epic/context attachments,
/// live planner run progress & sources read, and full proposal review/edit/accept/dispatch flow.
struct PlansScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    private static let bootstrapReq = API.getBootstrap()
    private static let listReq = API.listPlanningSessions()

    private var selectedPlanId: String? {
        let id = context.match.query["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (id?.isEmpty == false) ? id : nil
    }

    private var queryProject: String? {
        let key = context.match.query["project"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    var body: some View {
        let bootEntry = context.store.entry(Self.bootstrapReq)
        let listEntry = context.store.entry(Self.listReq)
        let detailReq = selectedPlanId.map { API.getPlanningSession(id: $0) }
        let detailEntry = detailReq.map { context.store.entry($0) }
        let projects = bootEntry.data?.projects ?? []
        let activeProjects = projects.filter { !$0.archived }
        let currentProject: API.Project? = {
            if let planProj = detailEntry?.data?.project {
                return projects.first { $0.key == planProj }
            }
            if let queryProject {
                return activeProjects.first { $0.key == queryProject } ?? projects.first { $0.key == queryProject }
            }
            return activeProjects.first
        }()

        HStack(spacing: 0) {
            planListSidebar(plans: listEntry.data, isLoading: listEntry.data == nil && listEntry.error == nil, error: listEntry.error)
                .frame(width: 268)
                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))

            Divider().overlay(theme.palette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let bootErr = bootEntry.error {
                        QueryErrorView(message: bootErr.userMessage) {
                            Task { await context.store.refetch(Self.bootstrapReq) }
                        }
                    } else if let boot = bootEntry.data {
                        if let planId = selectedPlanId {
                            if let err = detailEntry?.error {
                                QueryErrorView(message: err.userMessage) {
                                    Task { await context.store.refetch(API.getPlanningSession(id: planId)) }
                                }
                            } else if let plan = detailEntry?.data {
                                PlanDetailView(plan: plan, bootstrap: boot)
                                    .id(plan.id)
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    SkeletonBar(height: 28).frame(width: 320)
                                    SkeletonBar(height: 120)
                                    SkeletonBar(height: 200)
                                }
                            }
                        } else if let project = currentProject {
                            let planners = boot.agents.filter { $0.kind == .main }
                            if planners.isEmpty {
                                emptyNoAgents
                            } else {
                                NewPlanCard(
                                    bootstrap: boot,
                                    activeProjects: activeProjects,
                                    initialProject: project,
                                    initialGoal: context.match.query["goal"] ?? "",
                                    initialEpicId: context.match.query["epic"] ?? "",
                                    initialArtifactId: context.match.query["artifact"],
                                    initialAttach: context.match.query["attach"],
                                    initialAttachTitle: context.match.query["attach_title"]
                                )
                                .id("\(project.key)|\(context.match.query["artifact"] ?? "")|\(context.match.query["epic"] ?? "")|\(context.match.query["goal"] ?? "")")
                            }
                        } else {
                            emptyNoProjects
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            SkeletonBar(height: 28).frame(width: 260)
                            SkeletonBar(height: 180)
                        }
                    }
                }
                .frame(maxWidth: 960, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.palette.background)
        .onAppear {
            context.store.load(Self.bootstrapReq)
            context.store.load(Self.listReq)
            context.store.observe(Self.bootstrapReq)
            context.store.observe(Self.listReq)
            if let detailReq {
                context.store.load(detailReq)
                context.store.observe(detailReq)
            }
            syncChrome(project: currentProject)
            context.onCommand = { cmd in
                if case .toolbarAction(itemId: "plans.new", _) = cmd {
                    if let key = currentProject?.key {
                        context.navigate("/plans?project=\(key)")
                    } else {
                        context.navigate("/plans")
                    }
                }
            }
        }
        .onDisappear {
            context.store.stopObserving(Self.bootstrapReq.key)
            context.store.stopObserving(Self.listReq.key)
            if let detailReq { context.store.stopObserving(detailReq.key) }
            context.onCommand = nil
        }
        .onChange(of: selectedPlanId) { oldId, newId in
            if let oldId { context.store.stopObserving(API.getPlanningSession(id: oldId).key) }
            if let newId {
                let req = API.getPlanningSession(id: newId)
                context.store.load(req)
                context.store.observe(req)
            }
        }
        .onChange(of: currentProject?.name) { _, _ in
            syncChrome(project: currentProject)
        }
        .task(id: selectedPlanId) {
            // Keep the list and active plan fresh while open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                if let planId = selectedPlanId {
                    let req = API.getPlanningSession(id: planId)
                    let live = context.store.entry(req).data.map(PlansLogic.planLive) ?? true
                    if live {
                        await context.store.refetch(req)
                    }
                }
                await context.store.refetch(Self.listReq)
            }
        }
    }

    private func syncChrome(project: API.Project?) {
        context.chrome = NativeChrome(
            title: "Plans",
            subtitle: project?.name,
            toolbarItems: [
                ShellToolbarItem(id: "plans.new", label: "New plan", icon: "plus", kind: .button, showsLabel: true),
            ]
        )
    }

    private func planListSidebar(plans: [API.PlanningSession]?, isLoading: Bool, error: APIError?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PLANS")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(theme.palette.tertiaryText)
                Spacer()
                if let count = plans?.count {
                    Text("\(count)")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(theme.palette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if isLoading {
                        ForEach(0..<4, id: \.self) { _ in SkeletonBar(height: 58) }
                    } else if let error {
                        Text(error.userMessage)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                            .padding(8)
                    } else if let plans, plans.isEmpty {
                        Text("Your plans will appear here.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(8)
                    } else if let plans {
                        ForEach(plans, id: \.id) { plan in
                            let active = plan.id == selectedPlanId
                            let status = PlansLogic.planStatus(plan)
                            Button {
                                context.navigate("/plans?id=\(plan.id)")
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        TonePill(label: status.label, tone: status.tone.rawValue)
                                        Spacer()
                                        Text(PlansLogic.planCount(plan))
                                            .font(.system(size: theme.pointSize(.micro)))
                                            .foregroundStyle(theme.palette.tertiaryText)
                                    }
                                    Text(PlansLogic.firstLine(plan.goal).isEmpty ? "Untitled plan" : PlansLogic.firstLine(plan.goal))
                                        .font(.system(size: theme.pointSize(.body)))
                                        .foregroundStyle(theme.palette.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text("\(plan.project) \u{00B7} \(APIDate.shortAgo(plan.createdAt))")
                                        .font(.system(size: theme.pointSize(.small)))
                                        .foregroundStyle(theme.palette.tertiaryText)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    active ? theme.palette.selected : theme.palette.surface,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(active ? theme.palette.accent.opacity(0.45) : theme.palette.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Text("Status \u{00B7} first line of the goal \u{00B7} tickets accepted / proposals made")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(.top, 6)
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyNoAgents: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create an agent first").vesperText(.heading, theme)
            Text("Planning needs an active project and at least one persona that takes tickets.")
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
            Button("Go to Work") { context.navigate("/work") }
                .buttonStyle(.vesper(.outline))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    private var emptyNoProjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No active space").vesperText(.heading, theme)
            Text("Create or restore a space with a project to start a planning run.")
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
            Button("Create space") { context.navigate("/spaces/new") }
                .buttonStyle(.vesper(.primary))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }
}

// MARK: - New Plan Composer

private struct NewPlanCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let bootstrap: API.Bootstrap
    let activeProjects: [API.Project]
    let initialProject: API.Project
    let initialGoal: String
    let initialEpicId: String
    let initialArtifactId: String?
    let initialAttach: String?
    let initialAttachTitle: String?

    @State private var projectKey: String = ""
    @State private var agentId: String = ""
    @State private var goal: String = ""
    @State private var epicId: String = ""
    @State private var artifactId: String?
    @State private var contextRefs: [(ref: API.ChatContextRef, label: String)] = []
    @State private var showingContextPicker = false
    @State private var contextQuery = ""
    @State private var submitting = false
    @State private var errorMessage: String?

    private var planners: [API.Agent] {
        bootstrap.agents.filter { $0.kind == .main }
    }

    private var selectedProject: API.Project {
        activeProjects.first { $0.key == projectKey } ?? initialProject
    }

    private var openEpics: [API.Epic] {
        bootstrap.epics.filter { $0.projectId == selectedProject.id && $0.status == .open }
    }

    private var selectedAgent: API.Agent? {
        planners.first { $0.id == agentId }
    }

    private var needsGoal: Bool {
        artifactId == nil && epicId.isEmpty
    }

    private var canSubmit: Bool {
        !agentId.isEmpty
            && (!needsGoal || !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !submitting
    }

    var body: some View {
        let resolvedReq = selectedAgent.map { API.getResolvedDefinition(handle: $0.handle, project: selectedProject.key) }
        let resolved = resolvedReq.flatMap { context.store.entry($0).data }

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New plan").vesperText(.heading, theme)
                    Text("Describe the goal and attach what the planner should read. You review proposals before any tickets exist.")
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
                Spacer()
                if activeProjects.count > 1 {
                    Picker("Space", selection: $projectKey) {
                        ForEach(activeProjects, id: \.key) { proj in
                            Text("\(proj.name) (\(proj.key))").tag(proj.key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                } else {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(cssHex: selectedProject.color) ?? theme.palette.accent)
                            .frame(width: 8, height: 8)
                        Text(selectedProject.name)
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                        Text(selectedProject.key)
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(needsGoal ? "Goal" : "Additional goal (optional)")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.secondaryText)
                TextEditor(text: $goal)
                    .font(.system(size: theme.pointSize(.body)))
                    .frame(minHeight: 150)
                    .padding(6)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))

                if artifactId != nil || !contextRefs.isEmpty {
                    FlowRow(spacing: 6) {
                        if let artId = artifactId {
                            HStack(spacing: 6) {
                                Button("Source document (pinned version)") {
                                    context.navigate("/artifacts/\(artId)")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.palette.accent)
                                Button {
                                    artifactId = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.palette.tertiaryText)
                                .accessibilityLabel("Remove source document")
                            }
                            .font(.system(size: theme.pointSize(.small)))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                        }

                        ForEach(Array(contextRefs.enumerated()), id: \.offset) { idx, item in
                            HStack(spacing: 6) {
                                Text(item.label)
                                    .lineLimit(1)
                                Button {
                                    contextRefs.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.palette.tertiaryText)
                            }
                            .font(.system(size: theme.pointSize(.small)))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                        }
                    }
                    .padding(.top, 2)
                }

                HStack {
                    Button {
                        showingContextPicker.toggle()
                    } label: {
                        Label("Attach context", systemImage: "paperclip")
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(contextRefs.count >= 12)
                    .popover(isPresented: $showingContextPicker, arrowEdge: .bottom) {
                        PlanContextPickerPopover(
                            projectKey: selectedProject.key,
                            onPick: { ref, label in
                                if !contextRefs.contains(where: { $0.ref == ref }) {
                                    contextRefs.append((ref: ref, label: label))
                                }
                                showingContextPicker = false
                            }
                        )
                        .environment(context)
                        .environment(\.vesperTheme, theme)
                    }
                    Text("\(contextRefs.count) of 12 attached")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                    Spacer()
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Planner agent")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(theme.palette.secondaryText)
                    Picker("Planner agent", selection: $agentId) {
                        ForEach(planners, id: \.id) { agent in
                            Text("\(agent.name) \u{00B7} @\(agent.handle)").tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    if let resolved {
                        Text("\(resolved.harness.rawValue) \u{00B7} \(resolved.model)")
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(theme.palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Epic (optional)")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(theme.palette.secondaryText)
                    Picker("Epic", selection: $epicId) {
                        Text("No epic").tag("")
                        ForEach(openEpics, id: \.id) { epic in
                            Text(epic.name).tag(epic.id)
                        }
                    }
                    .labelsHidden()
                    Text(epicId.isEmpty ? "Accepting creates a new epic. Pick one to extend it instead." : "Accepted tickets join this epic.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            PlanNoticeBanner(
                tone: "human",
                title: "Approve a restricted planning run",
                bodyText: "The planner can read context and submit proposals. Repository writes, setup, credentials and extra MCP servers are excluded. Starting a plan may incur model costs; it waits in the queue if no runner is online."
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack(spacing: 12) {
                Button(submitting ? "Starting\u{2026}" : "Approve & start planning") {
                    Task { await startPlan() }
                }
                .buttonStyle(.vesper(.approve))
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: .command)

                Text("The planner gets the attached documents when its run starts.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
        }
        .padding(20)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
        .onAppear {
            projectKey = initialProject.key
            agentId = planners.first?.id ?? ""
            goal = initialGoal
            epicId = openEpics.contains(where: { $0.id == initialEpicId }) ? initialEpicId : ""
            artifactId = initialArtifactId
            if let raw = initialAttach, let parsed = parseAttach(raw, title: initialAttachTitle) {
                contextRefs = [parsed]
            }
            if let req = resolvedReq { context.store.load(req) }
        }
        .onChange(of: agentId) { _, _ in
            if let agent = selectedAgent {
                context.store.load(API.getResolvedDefinition(handle: agent.handle, project: selectedProject.key))
            }
        }
        .onChange(of: projectKey) { _, _ in
            if !openEpics.contains(where: { $0.id == epicId }) { epicId = "" }
            if let agent = selectedAgent {
                context.store.load(API.getResolvedDefinition(handle: agent.handle, project: selectedProject.key))
            }
        }
    }

    private func parseAttach(_ raw: String, title: String?) -> (ref: API.ChatContextRef, label: String)? {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let kind = parts[0]
        let value = parts[1]
        switch kind {
        case "ticket":
            return (API.ChatContextRef(key: value, kind: .ticket), title ?? value)
        case "artifact":
            return (API.ChatContextRef(id: value, kind: .artifact), title ?? "Artifact")
        case "page":
            return (API.ChatContextRef(id: value, kind: .page), title ?? "Wiki page")
        default:
            return nil
        }
    }

    private func startPlan() async {
        guard let client = context.store.client, canSubmit else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        let input = API.PlanningInput(
            agentId: agentId,
            artifactId: artifactId,
            contextRefs: contextRefs.isEmpty ? nil : contextRefs.map(\.ref),
            epicId: epicId.isEmpty ? nil : epicId,
            goal: goal,
            project: selectedProject.key
        )
        do {
            let created = try await client.send(API.startPlanning(body: input))
            context.store.invalidate(QueryInvalidation(resources: ["planning"]))
            await context.store.refetch(API.listPlanningSessions())
            context.navigate("/plans?id=\(created.id)")
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct PlanContextPickerPopover: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let projectKey: String
    let onPick: (API.ChatContextRef, String) -> Void

    @State private var query = ""

    var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let artifactsReq = API.listArtifacts(project: projectKey, q: trimmed.isEmpty ? nil : trimmed)
        let ticketsReq = API.listTickets(project: projectKey, q: trimmed.isEmpty ? nil : trimmed)
        let artifacts = context.store.entry(artifactsReq).data?.artifacts ?? []
        let tickets = context.store.entry(ticketsReq).data?.tickets ?? []

        VStack(alignment: .leading, spacing: 8) {
            TextField("Search artifacts and tickets\u{2026}", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !artifacts.isEmpty {
                        Text("ARTIFACTS & WIKI")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(.top, 4)
                        ForEach(artifacts.prefix(8), id: \.id) { a in
                            Button {
                                let kind: API.ChatContextRef.Kind = a.type == .note ? .page : .artifact
                                onPick(API.ChatContextRef(id: a.id, kind: kind), LibraryLogic.artifactTitle(title: a.title, displayId: a.displayId))
                            } label: {
                                HStack(spacing: 6) {
                                    DocTypeTag(type: a.type.rawValue)
                                    Text(LibraryLogic.artifactTitle(title: a.title, displayId: a.displayId))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !tickets.isEmpty {
                        Text("TICKETS")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(.top, 6)
                        ForEach(tickets.prefix(8), id: \.key) { t in
                            Button {
                                onPick(API.ChatContextRef(key: t.key, kind: .ticket), "\(t.key) \u{00B7} \(t.title)")
                            } label: {
                                HStack(spacing: 6) {
                                    Text(t.key)
                                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                        .foregroundStyle(theme.palette.tertiaryText)
                                    Text(t.title).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if artifacts.isEmpty && tickets.isEmpty {
                        Text("No matching artifacts or tickets.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            context.store.load(artifactsReq)
            context.store.load(ticketsReq)
        }
        .onChange(of: query) { _, _ in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            context.store.load(API.listArtifacts(project: projectKey, q: q.isEmpty ? nil : q))
            context.store.load(API.listTickets(project: projectKey, q: q.isEmpty ? nil : q))
        }
    }
}

// MARK: - Plan Detail & Review

private struct PlanDetailView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let plan: API.PlanningSession
    let bootstrap: API.Bootstrap

    @State private var showSourcesWhenDone = false

    private var isLive: Bool { PlansLogic.planLive(plan) }

    var body: some View {
        let status = PlansLogic.planStatus(plan)
        let epicName = plan.epicId.flatMap { id in bootstrap.epics.first(where: { $0.id == id })?.name }
        let eventsReq = API.listRunEvents(id: plan.runId)
        let events = context.store.entry(eventsReq).data?.events ?? []
        let sources = PlansLogic.readSources(from: events)

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isLive ? "Planning run" : "Plan").vesperText(.heading, theme)
                    Spacer()
                    Button("View run log") {
                        context.navigate("/runs/\(plan.runId)")
                    }
                    .buttonStyle(.vesper(.outline))
                }

                HStack(spacing: 8) {
                    TonePill(label: status.label, tone: status.tone.rawValue)
                    Text("\(plan.project) \u{00B7} \(plan.harness) \u{00B7} \(plan.model)")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }

                Text(plan.goal)
                    .font(.system(size: theme.pointSize(.heading), weight: .medium))
                    .textSelection(.enabled)

                if let epicName {
                    Text("Epic: \(epicName)")
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.secondaryText)
                }

                if plan.artifactId != nil || !plan.contextRefs.isEmpty {
                    FlowRow(spacing: 6) {
                        if let artId = plan.artifactId {
                            Button("Source document") {
                                context.navigate("/artifacts/\(artId)")
                            }
                            .buttonStyle(.vesper(.outline))
                        }
                        ForEach(Array(plan.contextRefs.enumerated()), id: \.offset) { _, ref in
                            contextRefChip(ref)
                        }
                    }
                }

                if plan.state == .planning {
                    Text(isLive
                        ? "The planner will submit draft tickets here. No tickets have been created."
                        : (plan.outcome?.isEmpty == false ? plan.outcome! : "Planning stopped. Start a new plan to retry."))
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.secondaryText)
                }

                if plan.state == .review {
                    PlanNoticeBanner(
                        tone: "human",
                        title: "\(plan.proposals.count) proposals ready for review",
                        bodyText: "Review, edit or uncheck proposals below; no tickets exist until you accept them."
                    )
                }

                sourcesSection(sources: sources)
            }
            .padding(20)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))

            if plan.state != .planning {
                PlanReviewView(plan: plan, bootstrap: bootstrap)
            }
        }
        .onAppear {
            context.store.load(eventsReq)
        }
        .task(id: "\(plan.id)-\(isLive)") {
            guard isLive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                await context.store.refetch(API.listRunEvents(id: plan.runId))
            }
        }
    }

    @ViewBuilder
    private func contextRefChip(_ ref: API.ChatContextRef) -> some View {
        let label: String = {
            if let key = ref.key, !key.isEmpty { return key }
            if let id = ref.id, !id.isEmpty { return "\(ref.kind.rawValue):\(id.prefix(8))" }
            return ref.kind.rawValue
        }()
        Button(label) {
            switch ref.kind {
            case .ticket:
                if let key = ref.key { context.navigate("/tickets/\(key)") }
            case .artifact, .section:
                if let id = ref.id { context.navigate("/artifacts/\(id)") }
            case .page:
                if let id = ref.id { context.navigate("/knowledge/\(id)") }
            default:
                break
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: theme.pointSize(.small), design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
    }

    @ViewBuilder
    private func sourcesSection(sources: [PlansLogic.ReadSource]) -> some View {
        if isLive {
            VStack(alignment: .leading, spacing: 6) {
                Text("SOURCES READ SO FAR")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(theme.palette.tertiaryText)
                if sources.isEmpty {
                    Text(plan.runState == "queued" ? "Waiting for a runner\u{2026}" : "The planner hasn\u{2019}t read anything yet.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                } else {
                    sourcesList(sources)
                }
            }
        } else if !sources.isEmpty {
            DisclosureGroup("Sources read (\(sources.count))", isExpanded: $showSourcesWhenDone) {
                sourcesList(sources).padding(.top, 6)
            }
            .font(.system(size: theme.pointSize(.small)))
            .padding(10)
            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
        }
    }

    private func sourcesList(_ sources: [PlansLogic.ReadSource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(sources) { src in
                HStack(spacing: 8) {
                    if src.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.swiftUIColor("pill-done-fg", fallback: .green))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    Text(src.verb)
                        .foregroundStyle(theme.palette.secondaryText)
                    if let ref = src.ref {
                        Button(src.label) { context.navigate(ref) }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.palette.accent)
                    } else {
                        Text(src.label)
                            .foregroundStyle(theme.palette.text)
                    }
                }
                .font(.system(size: theme.pointSize(.small)))
            }
        }
    }
}

private struct PlanReviewView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let plan: API.PlanningSession
    let bootstrap: API.Bootstrap

    @State private var items: [API.TicketProposal] = []
    @State private var selectedRefs: Set<String> = []
    @State private var activeRef: String?
    @State private var revision: Int = 0
    @State private var blockerDrafts: [String: String] = [:]
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var showingDispatch = false

    private var archivedProject: Bool {
        bootstrap.projects.first(where: { $0.key == plan.project })?.archived ?? false
    }

    private var mainAgents: [API.Agent] {
        bootstrap.agents.filter { $0.kind == .main }
    }

    var body: some View {
        Group {
            if plan.state == .accepted {
                acceptedCard
            } else if plan.state == .dismissed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Plan dismissed").vesperText(.heading, theme)
                    Text("No tickets were created.")
                        .foregroundStyle(theme.palette.secondaryText)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
            } else {
                reviewWorkspace
            }
        }
        .onAppear {
            syncFromPlan()
        }
        .sheet(isPresented: $showingDispatch) {
            WorkDispatchSheet(keys: plan.readyKeys) {
                showingDispatch = false
            }
            .environment(context)
            .environment(\.vesperTheme, theme)
        }
    }

    private func syncFromPlan() {
        let normalized = PlansLogic.normalizedProposals(plan.proposals)
        items = normalized
        selectedRefs = Set(normalized.compactMap(\.ref))
        activeRef = normalized.first?.ref
        revision = plan.revision
        blockerDrafts = Dictionary(uniqueKeysWithValues: normalized.compactMap { p in
            guard let ref = p.ref else { return nil }
            return (ref, (p.blockedBy ?? []).joined(separator: ", "))
        })
    }

    private var acceptedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tickets created \u{00B7} \(PlansLogic.planCount(plan))")
                .vesperText(.heading, theme)
            Text("Assigned tickets whose blockers are Done are ready now. Dependent tickets can be dispatched too: they queue and start once their blockers are Done.")
                .font(.system(size: theme.pointSize(.body)))
                .foregroundStyle(theme.palette.secondaryText)

            if let epicId = plan.epicId {
                Button("View epic") { context.navigate("/epics/\(epicId)") }
                    .buttonStyle(.vesper(.outline))
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.ticketKeys.enumerated()), id: \.element) { idx, key in
                    Button {
                        context.navigate("/tickets/\(key)")
                    } label: {
                        HStack(spacing: 8) {
                            Text(key)
                                .font(.system(size: theme.pointSize(.body), design: .monospaced))
                            if idx < plan.proposals.count {
                                Text("\u{00B7} \(plan.proposals[idx].title)")
                            }
                        }
                        .foregroundStyle(theme.palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button("View ready tickets") {
                    context.navigate("/tickets?project=\(plan.project)&view=all&ready=true")
                }
                .buttonStyle(.vesper(.outline))

                if !plan.readyKeys.isEmpty {
                    Button("Review & dispatch \(plan.readyKeys.count) ready tickets\u{2026}") {
                        showingDispatch = true
                    }
                    .buttonStyle(.vesper(.primary))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    private var reviewWorkspace: some View {
        let problems = PlansLogic.dependencyProblems(items: items, selected: selectedRefs)
        let allProblems = PlansLogic.dependencyProblems(items: items, selected: Set(items.compactMap(\.ref)))
        let chosen = items.filter { $0.ref.map(selectedRefs.contains) ?? false }
        let chosenPoints = chosen.reduce(0) { $0 + ($1.estimatePoints ?? 0) }
        let chosenMockups = chosen.filter { $0.requiresMockup == true }.count
        let chosenEstimateChanges = chosen.filter { PlansLogic.estimateChanged($0, originals: plan.proposals) }.count

        return VStack(alignment: .leading, spacing: 14) {
            if plan.revision != revision {
                PlanNoticeBanner(
                    tone: "human",
                    title: "This draft has changed",
                    bodyText: "Your edits are preserved. Reload to review the latest draft before saving."
                )
            }
            if archivedProject {
                PlanNoticeBanner(
                    tone: "human",
                    title: "This space\u{2019}s work is archived",
                    bodyText: "Restore the project in Settings before accepting these proposals."
                )
            }

            HStack(alignment: .top, spacing: 16) {
                // Left column: drafts + dependencies
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Drafts \u{00B7} \(items.count)")
                            .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, proposal in
                            let ref = proposal.ref ?? "ticket-\(idx + 1)"
                            let isSelected = selectedRefs.contains(ref)
                            let isActive = activeRef == ref
                            let changed = PlansLogic.estimateChanged(proposal, originals: plan.proposals)
                            let deps = (proposal.dependsOn?.count ?? 0) + (proposal.blockedBy?.count ?? 0)
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: Binding(
                                    get: { isSelected },
                                    set: { on in
                                        if on { selectedRefs.insert(ref) } else { selectedRefs.remove(ref) }
                                    }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(saving)

                                Button {
                                    activeRef = ref
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(idx + 1) \u{00B7} \(proposal.title.isEmpty ? "Untitled" : proposal.title)")
                                            .font(.system(size: theme.pointSize(.body), weight: isActive ? .semibold : .regular))
                                            .foregroundStyle(theme.palette.text)
                                            .multilineTextAlignment(.leading)
                                        Text("\(proposal.estimatePoints.map(String.init) ?? "\u{2014}") pts\(changed ? " \u{25CF} changed" : "") \u{00B7} \(proposal.requiresMockup == true ? "needs mockup \u{00B7} " : "")\(deps) dep\(deps == 1 ? "" : "s")")
                                            .font(.system(size: theme.pointSize(.small)))
                                            .foregroundStyle(theme.palette.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                            .background(isActive ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(14)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dependencies")
                            .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        Text("Blocker \u{2192} blocked draft")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                        ForEach(Array(items.enumerated()), id: \.offset) { _, p in
                            let blockers: [String] = (p.dependsOn ?? []).map { depRef in
                                items.first(where: { $0.ref == depRef }).flatMap { $0.title.isEmpty ? nil : $0.title } ?? depRef
                            } + (p.blockedBy ?? [])
                            Text("\(blockers.isEmpty ? "No blockers" : blockers.joined(separator: ", ")) \u{2192} \(p.title.isEmpty ? (p.ref ?? "Untitled") : p.title)")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.secondaryText)
                        }
                        ForEach(problems, id: \.self) { problem in
                            Text(problem)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
                }
                .frame(width: 280)

                // Right column: active proposal editor
                if let activeIndex = items.firstIndex(where: { $0.ref == activeRef }) {
                    proposalEditor(index: activeIndex)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Select a draft to inspect or edit it.")
                        .foregroundStyle(theme.palette.tertiaryText)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            // Action footer
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Add proposal") {
                        let ref = UUID().uuidString
                        items.append(API.TicketProposal(criteria: [], dependsOn: [], description: "", ref: ref, title: ""))
                        selectedRefs.insert(ref)
                        activeRef = ref
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(saving || items.count >= 50)

                    Button("Dismiss plan") {
                        Task { await submit(action: .dismiss, proposals: items) }
                    }
                    .buttonStyle(.vesper(.danger))
                    .disabled(saving)

                    Button("Save draft") {
                        Task { await submit(action: .save, proposals: items) }
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(saving || items.isEmpty)
                }

                Text("\(chosen.count) of \(items.count) selected \u{00B7} \(chosenPoints) points \u{00B7} \(chosenMockups) need mockups \u{00B7} \(chosenEstimateChanges) estimates changed")
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(theme.palette.secondaryText)

                Text("Acceptance finishes this review. Unselected drafts will not create tickets.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)

                HStack(spacing: 10) {
                    Button("Accept selected (\(chosen.count))") {
                        Task { await submit(action: .accept, proposals: chosen) }
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(saving || archivedProject || chosen.isEmpty || !problems.isEmpty)

                    Button("Accept all (\(items.count))") {
                        Task { await submit(action: .accept, proposals: items) }
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(saving || archivedProject || items.isEmpty || !allProblems.isEmpty)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
        }
    }

    private func proposalEditor(index: Int) -> some View {
        let item = items[index]
        let ref = item.ref ?? "ticket-\(index + 1)"
        let baseline = PlansLogic.baselineEstimate(for: item, originals: plan.proposals)
        let estimateChanged = PlansLogic.estimateChanged(item, originals: plan.proposals)
        let dependedOn = items.enumerated().contains { idx, other in
            idx != index && (other.dependsOn?.contains(ref) ?? false)
        }
        let epicName = plan.epicId.flatMap { id in bootstrap.epics.first(where: { $0.id == id })?.name }

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ticket \(index + 1)").vesperText(.heading, theme)
                Spacer()
                Button("\u{2191}") {
                    items.swapAt(index - 1, index)
                }
                .buttonStyle(.vesper(.outline))
                .disabled(index == 0 || saving)
                .help("Move draft up")

                Button("\u{2193}") {
                    items.swapAt(index, index + 1)
                }
                .buttonStyle(.vesper(.outline))
                .disabled(index == items.count - 1 || saving)
                .help("Move draft down")

                Button("Drop") {
                    items.remove(at: index)
                    selectedRefs.remove(ref)
                    activeRef = items.first?.ref
                }
                .buttonStyle(.vesper(.danger))
                .disabled(saving || dependedOn)
                .help(dependedOn ? "Remove dependencies on this proposal before dropping it" : "Drop proposal")
            }

            field("Title") {
                TextField("Ticket title", text: Binding(
                    get: { items[index].title },
                    set: { items[index].title = String($0.prefix(300)) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            field("Description") {
                TextEditor(text: Binding(
                    get: { items[index].description },
                    set: { items[index].description = $0 }
                ))
                .font(.system(size: theme.pointSize(.body)))
                .frame(minHeight: 110)
                .padding(4)
                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
            }

            field("Acceptance criteria") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items[index].criteria.enumerated()), id: \.offset) { cIdx, _ in
                        HStack(spacing: 4) {
                            TextField("Criterion \(cIdx + 1)", text: Binding(
                                get: { items[index].criteria[cIdx] },
                                set: { items[index].criteria[cIdx] = String($0.prefix(2000)) }
                            ))
                            .textFieldStyle(.roundedBorder)

                            Button("\u{2191}") { items[index].criteria.swapAt(cIdx - 1, cIdx) }
                                .buttonStyle(.vesper(.outline))
                                .disabled(cIdx == 0)
                            Button("\u{2193}") { items[index].criteria.swapAt(cIdx, cIdx + 1) }
                                .buttonStyle(.vesper(.outline))
                                .disabled(cIdx == items[index].criteria.count - 1)
                            Button("\u{00D7}") { items[index].criteria.remove(at: cIdx) }
                                .buttonStyle(.vesper(.outline))
                        }
                    }
                    Button("Add criterion") {
                        items[index].criteria.append("")
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(items[index].criteria.count >= 30)
                }
            }

            field("Estimate") {
                VStack(alignment: .leading, spacing: 6) {
                    FlowRow(spacing: 6) {
                        ForEach(Array(PlansLogic.estimateOptions.enumerated()), id: \.offset) { _, pts in
                            let selected = item.estimatePoints == pts
                            Button(pts.map(String.init) ?? "Unestimated") {
                                items[index].estimatePoints = pts
                            }
                            .buttonStyle(.vesper(selected ? .primary : .outline))
                        }
                    }
                    if estimateChanged {
                        HStack(spacing: 6) {
                            Text("Changed from \(baseline.points.map(String.init) ?? "unestimated").")
                                .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                            Button("Reset estimate") {
                                items[index].estimatePoints = baseline.points
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.palette.accent)
                        }
                        .font(.system(size: theme.pointSize(.small)))
                    }
                    Text("Planner\u{2019}s rationale (\(baseline.points.map(String.init) ?? "\u{2014}") pts): \(baseline.rationale?.isEmpty == false ? baseline.rationale! : "No rationale supplied.")")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }

            field("Estimate rationale") {
                TextField("Why this estimate?", text: Binding(
                    get: { items[index].estimateRationale ?? "" },
                    set: { items[index].estimateRationale = String($0.prefix(2000)) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Text("Epic: \(epicName ?? "New epic from this plan\u{2019}s goal")")
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)

            field("Waits for these proposals", hint: "Blockers must be Done before this ticket can be dispatched.") {
                if items.count < 2 {
                    Text("No other proposals.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { otherIdx, other in
                            if otherIdx != index, let otherRef = other.ref {
                                let checked = item.dependsOn?.contains(otherRef) ?? false
                                Toggle("Ticket \(otherIdx + 1) \u{00B7} \(other.title.isEmpty ? "Untitled" : other.title)", isOn: Binding(
                                    get: { checked },
                                    set: { on in
                                        var deps = items[index].dependsOn ?? []
                                        if on {
                                            if !deps.contains(otherRef) { deps.append(otherRef) }
                                        } else {
                                            deps.removeAll { $0 == otherRef }
                                        }
                                        items[index].dependsOn = deps
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }

            field("Existing blocker tickets", hint: "Optional ticket keys separated by commas (e.g. PAY-214, PAY-224).") {
                TextField("PAY-214, PAY-224", text: Binding(
                    get: { blockerDrafts[ref] ?? (items[index].blockedBy ?? []).joined(separator: ", ") },
                    set: { value in
                        blockerDrafts[ref] = value
                        let parsed = PlansLogic.parseBlockerKeys(value)
                        items[index].blockedBy = parsed.isEmpty ? nil : parsed
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 16) {
                field("Assign to") {
                    Picker("Assign to", selection: Binding(
                        get: { items[index].agentId ?? "" },
                        set: { items[index].agentId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Unassigned").tag("")
                        ForEach(mainAgents, id: \.id) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }

                Toggle("Requires mockup", isOn: Binding(
                    get: { items[index].requiresMockup ?? false },
                    set: { items[index].requiresMockup = $0 }
                ))
                .toggleStyle(.checkbox)
                .padding(.top, 16)
            }
        }
        .padding(18)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
        .disabled(saving)
    }

    private func field<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.secondaryText)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
        }
    }

    private func submit(action: API.ReviewPlanningBody.Action, proposals: [API.TicketProposal]) async {
        guard let client = context.store.client, !saving else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        let body = API.ReviewPlanningBody(action: action, proposals: proposals, revision: revision)
        do {
            let updated = try await client.send(API.reviewPlanning(id: plan.id, body: body))
            revision = updated.revision
            items = PlansLogic.normalizedProposals(updated.proposals)
            context.store.invalidate(QueryInvalidation(resources: ["planning", "tickets", "bootstrap"]))
            await context.store.refetch(API.getPlanningSession(id: plan.id))
            await context.store.refetch(API.listPlanningSessions())
            if action == .save {
                context.showToast(ToastItemModel(id: "plan.saved.\(plan.id)", title: "Plan draft saved", tone: .success))
            } else if action == .accept {
                context.showToast(ToastItemModel(id: "plan.accepted.\(plan.id)", title: "Created \(updated.ticketKeys.count) tickets", tone: .success))
            }
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct PlanNoticeBanner: View {
    @Environment(\.vesperTheme) private var theme
    let tone: String
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                .foregroundStyle(theme.swiftUIColor("pill-\(tone)-fg", fallback: theme.palette.text))
            Text(bodyText)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.swiftUIColor("pill-\(tone)-bg", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }
}
