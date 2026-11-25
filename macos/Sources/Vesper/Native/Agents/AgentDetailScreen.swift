import SwiftUI
import VesperCore

/// Native `/agents/:handle` persona work definition, scopes, skills, memory, activity, settings, and tokens screen.
struct AgentDetailScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var activeTab: AgentDetailLogic.Tab = .overview
    @State private var selectedProjectKey: String?
    @State private var draft: API.SaveAgentDefinitionBody?
    @State private var showReviewSheet = false
    @State private var reviewNote = ""
    @State private var savingDefinition = false
    @State private var saveError: String?
    private struct OverrideSheetTarget: Identifiable {
        let project: API.Project
        var id: String { project.key }
    }

    @State private var editingOverrideTarget: OverrideSheetTarget?
    @State private var instructionsEditMode = false
    @State private var customScopeInput = ""
    @State private var expandedSkillName: String?
    @State private var newSkillName = ""
    @State private var runsOffset = 0
    @State private var newServerName = ""
    @State private var newServerURL = ""
    @State private var newOptionKey = ""
    @State private var newOptionValue = ""
    @State private var newTokenLabel = ""
    @State private var mintedToken: API.CreateAgentTokenResponse?
    @State private var tokenBusy = false
    @State private var tokenError: String?

    private static let scopeNameRegex = /^[a-z][a-z0-9-]*:([a-z0-9][a-z0-9-]*|\*)$/
    private static let skillNameRegex = /^[a-z0-9][a-z0-9-]{0,63}$/
    private static let runsPageSize = 50
    private static let hueColors: [Color] = [
        Color(red: 0.44, green: 0.49, blue: 0.96),
        Color(red: 0.25, green: 0.72, blue: 0.57),
        Color(red: 0.89, green: 0.56, blue: 0.28),
        Color(red: 0.84, green: 0.39, blue: 0.54),
        Color(red: 0.60, green: 0.44, blue: 0.88),
        Color(red: 0.24, green: 0.67, blue: 0.82),
        Color(red: 0.78, green: 0.67, blue: 0.24),
        Color(red: 0.82, green: 0.40, blue: 0.36),
    ]

    private var handle: String {
        context.match.params["handle"] ?? ""
    }

    private var agentRequest: APIRequest<API.AgentDetail> { API.getAgent(handle: handle) }
    private var bootstrapRequest: APIRequest<API.Bootstrap> { API.getBootstrap() }
    private var overviewsRequest: APIRequest<API.AgentOverviewList> { API.listAgentOverviews() }
    private var wikiRequest: APIRequest<API.WikiTree> { API.listWikiPages(includeAgent: true) }
    private var runsRequest: APIRequest<API.ListAgentRunsResponse> { API.listAgentRuns(handle: handle, offset: runsOffset) }
    private var tokensRequest: APIRequest<API.ListAgentTokensResponse> { API.listAgentTokens(handle: handle) }

    var body: some View {
        let p = theme.palette
        let detailEntry = context.store.entry(agentRequest)
        let bootEntry = context.store.entry(bootstrapRequest)
        let overviewsEntry = context.store.entry(overviewsRequest)
        let detail = detailEntry.data
        let projects = (bootEntry.data?.projects ?? []).filter { !$0.archived }
        let effectiveProjectKey = selectedProjectKey
            ?? detail?.overrides.first?.project.key
            ?? projects.first?.key
        let activeProject = projects.first { $0.key == effectiveProjectKey }
        let resolvedRequest = API.getResolvedDefinition(handle: handle, project: effectiveProjectKey)
        let resolvedEntry = context.store.entry(resolvedRequest)

        let baseBody = detail.map(Self.bodyFrom)
        let current = draft ?? baseBody
        let changesSummary: [String] = {
            guard let detail, let current else { return [] }
            return AgentDetailLogic.summarizeChanges(original: detail, body: current)
        }()
        let isDirty = !changesSummary.isEmpty

        let navModel = AgentDetailLogic.navModel(
            agents: bootEntry.data?.agents ?? [],
            overviews: overviewsEntry.data?.agents ?? [],
            activeHandle: handle,
            activeTab: activeTab
        )
        let toolbarItems: [ShellToolbarItem] = detail != nil ? [
            isDirty ? ShellToolbarItem(id: "agent.discard", label: "Discard", kind: .button, showsLabel: true) : nil,
            ShellToolbarItem(id: "agent.review", label: "Review & Save", kind: .button, disabled: !isDirty, accent: true, showsLabel: true),
        ].compactMap { $0 } : []

        let currentChrome = NativeChrome(
            title: detail.map { "\($0.agent.name) \u{00B7} Work" } ?? "@\(handle)",
            subtitle: isDirty ? "\(changesSummary.count) unsaved \(changesSummary.count == 1 ? "change" : "changes")" : nil,
            toolbarItems: toolbarItems,
            navigator: navModel
        )

        Group {
            if let error = detailEntry.error, detail == nil {
                errorState(error, p: p)
            } else if let detail, let current {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection(detail: detail, current: current, p: p)
                        tabStrip(p: p)

                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 16) {
                                switch activeTab {
                                case .overview:
                                    overviewTab(detail: detail, current: current, overview: overviewsEntry.data?.agents.first { $0.agent.handle == handle }, activeProject: activeProject, p: p)
                                case .scopes:
                                    scopesTab(detail: detail, current: current, projects: projects, activeProject: activeProject, p: p)
                                case .skills:
                                    skillsTab(detail: detail, current: current, projects: projects, activeProject: activeProject, resolved: resolvedEntry.data, p: p)
                                case .memory:
                                    memoryTab(detail: detail, current: current, p: p)
                                case .activity:
                                    activityTab(p: p)
                                case .settings:
                                    settingsTab(detail: detail, current: current, p: p)
                                case .tokens:
                                    tokensTab(detail: detail, p: p)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .leading, spacing: 14) {
                                resolvedPanel(detail: detail, projects: projects, selectedKey: effectiveProjectKey, resolved: resolvedEntry.data, p: p)
                                overridesPanel(detail: detail, projects: projects, p: p)
                            }
                            .frame(width: 300)
                        }
                    }
                    .padding(24)
                }
            } else {
                ProgressView("Loading @\(handle)\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            activeTab = AgentDetailLogic.Tab.from(queryParam: context.match.query["tab"])
            context.chrome = currentChrome
            wireCommands(isDirty: isDirty)
        }
        .onChange(of: currentChrome) { _, next in
            context.chrome = next
        }
        .onChange(of: isDirty) { _, dirty in
            wireCommands(isDirty: dirty)
        }
        .onChange(of: handle) { _, _ in
            draft = nil
            mintedToken = nil
            runsOffset = 0
            activeTab = AgentDetailLogic.Tab.from(queryParam: context.match.query["tab"])
        }
        .task(id: handle) {
            await loadPrimaryData()
        }
        .task(id: "\(handle)|\(effectiveProjectKey ?? "")") {
            _ = await context.store.refetch(API.getResolvedDefinition(handle: handle, project: effectiveProjectKey))
        }
        .task(id: "\(handle)|\(activeTab.rawValue)|\(runsOffset)") {
            await loadTabData()
        }
        .sheet(isPresented: $showReviewSheet) {
            if let detail, let current {
                reviewSheet(detail: detail, body: current, changes: changesSummary, p: p)
            }
        }
        .sheet(item: $editingOverrideTarget) { target in
            if let detail {
                AgentOverrideSheet(detail: detail, project: target.project) { _ in
                    Task {
                        _ = await context.store.refetch(agentRequest)
                        _ = await context.store.refetch(API.getResolvedDefinition(handle: handle, project: effectiveProjectKey))
                    }
                }
            }
        }
    }

    // MARK: - Data loading & commands

    private func loadPrimaryData() async {
        async let a = context.store.refetch(agentRequest)
        async let b = context.store.refetch(bootstrapRequest)
        async let o = context.store.refetch(overviewsRequest)
        _ = await (a, b, o)
    }

    private func loadTabData() async {
        switch activeTab {
        case .memory:
            _ = await context.store.refetch(wikiRequest)
        case .activity:
            _ = await context.store.refetch(runsRequest)
        case .tokens:
            _ = await context.store.refetch(tokensRequest)
        default:
            break
        }
    }

    private func wireCommands(isDirty: Bool) {
        context.onCommand = { cmd in
            if case .toolbarAction(let id, _) = cmd {
                if id == "agent.discard" {
                    draft = nil
                    return
                }
                if id == "agent.review", isDirty {
                    saveError = nil
                    showReviewSheet = true
                    return
                }
            }
            if let action = AgentDetailLogic.navAction(for: cmd) {
                switch action {
                case .backToWork:
                    context.navigate("/spaces")
                case .openAgent(let target, let newTab):
                    let href = "/agents/\(target)"
                    if newTab { context.openInNewTab(href) } else { context.navigate(href) }
                case .selectTab(let tab):
                    activeTab = tab
                }
            }
        }
    }

    private static func bodyFrom(_ d: API.AgentDetail) -> API.SaveAgentDefinitionBody {
        API.SaveAgentDefinitionBody(
            colorIndex: d.agent.colorIndex,
            name: d.agent.name,
            note: nil,
            role: d.agent.role,
            spec: d.spec,
            specialty: d.specialty
        )
    }

    private func updateDraft(from base: API.SaveAgentDefinitionBody, _ mutate: (inout API.SaveAgentDefinitionBody) -> Void) {
        var next = draft ?? base
        mutate(&next)
        draft = next
    }

    // MARK: - Header & Tabs

    private func headerSection(detail: API.AgentDetail, current: API.SaveAgentDefinitionBody, p: NativePalette) -> some View {
        let hue = Self.hueColors[abs(current.colorIndex) % Self.hueColors.count]
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(hue.opacity(0.18))
                Text(String(detail.agent.name.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(hue)
            }
            .frame(width: 44, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hue.opacity(0.35)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(detail.agent.name)
                        .vesperText(.display, theme)
                    statusPill(detail.agent.status)
                    Text("v\(detail.definition.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.border))
                }
                HStack(spacing: 6) {
                    Text("@\(detail.agent.handle)")
                        .font(.system(size: 12, design: .monospaced))
                    if !current.role.isEmpty {
                        Text("\u{00B7}")
                        Text(current.role)
                    }
                    if !current.specialty.isEmpty {
                        Text("\u{00B7}")
                        Text(current.specialty)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(p.secondaryText)
            }

            Spacer()

            Button("Persona Profile") {
                context.navigate("/settings?section=personas&persona=\(detail.agent.id)")
            }
            .buttonStyle(.bordered)
        }
    }

    private func tabStrip(p: NativePalette) -> some View {
        HStack(spacing: 4) {
            ForEach(AgentDetailLogic.Tab.allCases) { tab in
                let selected = tab == activeTab
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? p.text : p.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? p.border : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func statusPill(_ status: API.Agent.Status) -> some View {
        let (label, bgKey, fgKey, fallback): (String, String, String, Color) = switch status {
        case .running: ("Running", "pill-done-bg", "pill-done-fg", .green)
        case .waiting: ("Waiting", "pill-human-bg", "pill-human-fg", .orange)
        case .blocked: ("Blocked", "pill-blocked-bg", "pill-blocked-fg", .red)
        default: ("Idle", "surface-sunken", "fg-secondary", .secondary)
        }
        return Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.swiftUIColor(fgKey, fallback: fallback))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.swiftUIColor(bgKey, fallback: fallback.opacity(0.15)), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Overview Tab

    private func overviewTab(
        detail: API.AgentDetail,
        current: API.SaveAgentDefinitionBody,
        overview: API.AgentOverview?,
        activeProject: API.Project?,
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let overview {
                let liveCount = overview.assignments.count + overview.planningRuns.count
                let mergedRatio = overview.stats.closedPrs > 0
                    ? "\(Int((Double(overview.stats.mergedPrs) / Double(overview.stats.closedPrs) * 100).rounded()))%"
                    : "\u{2014}"
                let spendStr = String(format: "$%.2f", overview.stats.spendUsd)

                HStack(spacing: 12) {
                    kpiTile("Live runs", value: "\(liveCount)", subtitle: nil, p: p)
                    kpiTile("Merged PRs \u{00B7} 7d", value: mergedRatio, subtitle: "\(overview.stats.mergedPrs) of \(overview.stats.closedPrs) closed", p: p)
                    kpiTile("Done \u{00B7} 7d", value: "\(overview.stats.completed)", subtitle: nil, p: p)
                    kpiTile("Spend \u{00B7} 7d", value: spendStr, subtitle: "runs in window", p: p)
                }

                if !overview.planningRuns.isEmpty {
                    card("Planning runs", p: p) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(overview.planningRuns, id: \.id) { pr in
                                Button {
                                    context.navigate("/runs/\(pr.runId)")
                                } label: {
                                    HStack {
                                        Text(pr.goal).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        Text(pr.state).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.secondaryText)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                card("Current assignments", p: p) {
                    if overview.assignments.isEmpty {
                        Text("No active runs.").font(.system(size: 13)).foregroundStyle(p.tertiaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(overview.assignments, id: \.runId) { work in
                                Button {
                                    context.navigate("/runs/\(work.runId)")
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(work.ticket.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondaryText)
                                        Text(work.ticket.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        Text("\(work.state) \u{00B7} \(APIDate.shortAgo(work.startedAt))")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(p.tertiaryText)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if detail.agent.kind == .main {
                    card("Awaiting dispatch \u{00B7} \(overview.queueCount)", p: p) {
                        if overview.queue.isEmpty {
                            Text("No assigned tickets are waiting for dispatch.").font(.system(size: 13)).foregroundStyle(p.tertiaryText)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(overview.queue, id: \.id) { ticket in
                                    Button {
                                        context.navigate("/tickets/\(ticket.key)")
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(ticket.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondaryText)
                                            Text(ticket.title).font(.system(size: 13)).lineLimit(1)
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            let edited = current.spec.instructions != detail.spec.instructions
            card("Instructions", p: p, trailing: {
                HStack(spacing: 8) {
                    if edited {
                        Text("edited")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.swiftUIColor("pill-human-bg", fallback: .orange.opacity(0.15)), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Picker("Mode", selection: $instructionsEditMode) {
                        Text("Rendered").tag(false)
                        Text("Edit").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }) {
                VStack(alignment: .leading, spacing: 10) {
                    if instructionsEditMode {
                        TextEditor(text: Binding(
                            get: { current.spec.instructions },
                            set: { val in updateDraft(from: current) { $0.spec.instructions = val } }
                        ))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    } else if current.spec.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No instructions yet. Switch to Edit to write them.")
                            .font(.system(size: 13))
                            .foregroundStyle(p.tertiaryText)
                    } else {
                        Text(current.spec.instructions)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    let appendLines = detail.overrides
                        .first(where: { $0.project.key == activeProject?.key })?
                        .override.instructionsAppend?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .newlines)
                        .filter { !$0.isEmpty }.count ?? 0
                    Text("Written to AGENTS.md in each run\u{2019}s workspace; a repo\u{2019}s own AGENTS.md is kept." + (activeProject != nil && appendLines > 0 ? " In \(activeProject!.name), the space override appends \(appendLines) \(appendLines == 1 ? "line" : "lines")." : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                }
            }
        }
    }

    // MARK: - Scopes Tab

    private func scopesTab(
        detail: API.AgentDetail,
        current: API.SaveAgentDefinitionBody,
        projects: [API.Project],
        activeProject: API.Project?,
        p: NativePalette
    ) -> some View {
        let overrideScopes = detail.overrides.first(where: { $0.project.key == activeProject?.key })?.override.scopes
        let rows = AgentDetailLogic.scopeRows(
            catalog: detail.catalog.map(\.scope),
            agent: current.spec.scopes,
            override: overrideScopes
        )
        let trimmedCustom = customScopeInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let customOK = trimmedCustom.wholeMatch(of: Self.scopeNameRegex) != nil && current.spec.scopes[trimmedCustom] == nil

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Effective in").font(.system(size: 12)).foregroundStyle(p.secondaryText)
                projectPicker(projects: projects, selectedKey: activeProject?.key)
                Spacer()
                TextField("custom:scope", text: $customScopeInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 160)
                Button("Add custom scope") {
                    guard customOK else { return }
                    updateDraft(from: current) { $0.spec.scopes[trimmedCustom] = .requiresApproval }
                    customScopeInput = ""
                }
                .buttonStyle(.bordered)
                .disabled(!customOK)
            }

            Text("Pick a level to change the work definition. Spaces can only tighten it, and a scope the definition doesn\u{2019}t grant is denied.")
                .font(.system(size: 12))
                .foregroundStyle(p.tertiaryText)

            card("Scopes (\(rows.count))", p: p) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        if idx > 0 { Divider() }
                        scopeRowView(row: row, detail: detail, current: current, projectName: activeProject?.name, p: p)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func scopeRowView(
        row: AgentDetailLogic.ScopeRow,
        detail: API.AgentDetail,
        current: API.SaveAgentDefinitionBody,
        projectName: String?,
        p: NativePalette
    ) -> some View {
        let savedMode = detail.spec.scopes[row.scope]
        let changed = row.definition != savedMode
        let note = detail.catalog.first(where: { $0.scope == row.scope })?.description
            ?? (row.scope.hasSuffix(":*") ? "Custom wildcard scope" : "Custom scope")

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.scope)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    if changed {
                        Text("was \(AgentDetailLogic.scopeModeLabel(savedMode))")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                    }
                }
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if row.projectOnly {
                Text("not in definition")
                    .font(.system(size: 11))
                    .foregroundStyle(p.tertiaryText)
            } else {
                HStack(spacing: 4) {
                    Picker(row.scope, selection: Binding(
                        get: { row.definition?.rawValue ?? "" },
                        set: { raw in
                            updateDraft(from: current) {
                                if raw.isEmpty { $0.spec.scopes.removeValue(forKey: row.scope) }
                                else { $0.spec.scopes[row.scope] = API.ScopeMode(rawValue: raw) }
                            }
                        }
                    )) {
                        Text("Allowed").tag(API.ScopeMode.allowed.rawValue)
                        Text("Approval").tag(API.ScopeMode.requiresApproval.rawValue)
                        Text("Denied").tag(API.ScopeMode.denied.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)

                    if row.definition != nil {
                        Button {
                            updateDraft(from: current) { $0.spec.scopes.removeValue(forKey: row.scope) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from definition")
                    }
                }
            }

            HStack(spacing: 4) {
                scopeModeBadge(row.effective.mode)
                if row.effective.source == "project", let projectName {
                    Text(projectName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .background(changed ? theme.swiftUIColor("pill-human-bg", fallback: .orange.opacity(0.1)).opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func scopeModeBadge(_ mode: API.ScopeMode) -> some View {
        let (label, bgKey, fgKey, fallback): (String, String, String, Color) = switch mode {
        case .allowed: ("Allowed", "pill-done-bg", "pill-done-fg", .green)
        case .requiresApproval: ("Approval", "pill-human-bg", "pill-human-fg", .orange)
        default: ("Denied", "pill-blocked-bg", "pill-blocked-fg", .red)
        }
        return Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.swiftUIColor(fgKey, fallback: fallback))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.swiftUIColor(bgKey, fallback: fallback.opacity(0.15)), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Skills Tab

    private func skillsTab(
        detail: API.AgentDetail,
        current: API.SaveAgentDefinitionBody,
        projects: [API.Project],
        activeProject: API.Project?,
        resolved: API.ResolvedDefinition?,
        p: NativePalette
    ) -> some View {
        let skills = current.spec.skills ?? []
        let agentNames = Set(skills.map(\.name))
        let resolvedSkills = resolved?.skills ?? []
        let resolvedNames = Set(resolvedSkills.map(\.name))
        let addedByProject = resolvedSkills.filter { !agentNames.contains($0.name) }
        let trimmedNew = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nameOK = trimmedNew.wholeMatch(of: Self.skillNameRegex) != nil && !agentNames.contains(trimmedNew)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Showing for").font(.system(size: 12)).foregroundStyle(p.secondaryText)
                projectPicker(projects: projects, selectedKey: activeProject?.key)
                Text("\(skills.count) from definition")
                    .font(.system(size: 12))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
            }

            card("Skills", p: p) {
                VStack(alignment: .leading, spacing: 10) {
                    if skills.isEmpty && addedByProject.isEmpty {
                        Text("No skills yet. Add one below.").font(.system(size: 13)).foregroundStyle(p.tertiaryText)
                    }

                    ForEach(Array(skills.enumerated()), id: \.element.name) { idx, skill in
                        let removedInProject = resolved != nil && !resolvedNames.contains(skill.name)
                        let isOpen = expandedSkillName == skill.name
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    expandedSkillName = isOpen ? nil : skill.name
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10))
                                            .foregroundStyle(p.tertiaryText)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name)
                                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                                .strikethrough(removedInProject)
                                            Text(skill.description.isEmpty ? "No description yet" : skill.description)
                                                .font(.system(size: 12))
                                                .foregroundStyle(p.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                if removedInProject, let activeProject {
                                    Text("removed in \(activeProject.name)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(theme.swiftUIColor("pill-blocked-bg", fallback: .red.opacity(0.15)), in: RoundedRectangle(cornerRadius: 4))
                                } else {
                                    Text("agent")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(p.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
                                }
                                Button {
                                    updateDraft(from: current) {
                                        var next = $0.spec.skills ?? []
                                        if idx < next.count { next.remove(at: idx) }
                                        $0.spec.skills = next
                                    }
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }

                            if isOpen {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Use when\u{2026}").font(.system(size: 11, weight: .medium)).foregroundStyle(p.secondaryText)
                                    TextField("One line the persona matches tasks against", text: Binding(
                                        get: { skill.description },
                                        set: { val in
                                            updateDraft(from: current) {
                                                var next = $0.spec.skills ?? []
                                                if idx < next.count { next[idx].description = val }
                                                $0.spec.skills = next
                                            }
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))

                                    Text("Instructions (Markdown)").font(.system(size: 11, weight: .medium)).foregroundStyle(p.secondaryText)
                                    TextEditor(text: Binding(
                                        get: { skill.body },
                                        set: { val in
                                            updateDraft(from: current) {
                                                var next = $0.spec.skills ?? []
                                                if idx < next.count { next[idx].body = val }
                                                $0.spec.skills = next
                                            }
                                        }
                                    ))
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(minHeight: 160)
                                    .padding(6)
                                    .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                                }
                                .padding(.leading, 18)
                            }
                        }
                        Divider()
                    }

                    ForEach(addedByProject, id: \.name) { sk in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sk.name).font(.system(size: 13, weight: .medium, design: .monospaced))
                                Text(sk.description).font(.system(size: 12)).foregroundStyle(p.secondaryText).lineLimit(1)
                            }
                            Spacer()
                            if let activeProject {
                                Text("added by \(activeProject.name)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.swiftUIColor("pill-done-fg", fallback: .green))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.swiftUIColor("pill-done-bg", fallback: .green.opacity(0.15)), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Divider()
                    }

                    HStack(spacing: 8) {
                        TextField("skill-name", text: $newSkillName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 200)
                        Button("Add skill") {
                            guard nameOK else { return }
                            updateDraft(from: current) {
                                var next = $0.spec.skills ?? []
                                next.append(API.AgentSkill(body: "", description: "", name: trimmedNew))
                                $0.spec.skills = next
                            }
                            expandedSkillName = trimmedNew
                            newSkillName = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(!nameOK)
                        if !newSkillName.isEmpty && !nameOK {
                            Text("Lowercase letters, digits, and hyphens; must be unique.")
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Memory Tab

    private func memoryTab(detail: API.AgentDetail, current: API.SaveAgentDefinitionBody, p: NativePalette) -> some View {
        let prefix = "agents/\(handle)/"
        let indexPath = "\(prefix)Memory"
        let treeEntry = context.store.entry(wikiRequest)
        let pages = (treeEntry.data?.pages ?? [])
            .filter { $0.path.hasPrefix(prefix) }
            .sorted { a, b in
                if a.path == indexPath { return true }
                if b.path == indexPath { return false }
                return a.updatedAt > b.updatedAt
            }
        let mem = current.spec.memory ?? API.AgentMemory(enabled: true, inject: .selective, maxTokens: 1500)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(prefix).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("\(pages.count) \(pages.count == 1 ? "page" : "pages")")
                    .font(.system(size: 12))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button("Open in Knowledge \u{2192}") {
                    context.navigate("/wiki/\(indexPath)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(p.accent)
            }

            HStack(spacing: 6) {
                Text(mem.enabled
                     ? "Each run starts with \(mem.inject.rawValue) wiki context, up to \(mem.maxTokens) tokens."
                     : "Runs don\u{2019}t start with wiki context.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)
                Button("Change in Settings") { activeTab = .settings }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.accent)
            }

            card("Memory pages", p: p) {
                if treeEntry.isFetching && treeEntry.data == nil {
                    ProgressView().padding(.vertical, 12)
                } else if pages.isEmpty {
                    Text("No memory pages yet. Pages runs write under \(prefix) appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                            if idx > 0 { Divider() }
                            Button {
                                context.navigate("/wiki/\(page.path)")
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text").foregroundStyle(p.tertiaryText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(page.title).font(.system(size: 13, weight: .medium))
                                        Text(page.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(p.tertiaryText)
                                    }
                                    Spacer()
                                    Text(APIDate.shortAgo(page.updatedAt))
                                        .font(.system(size: 11))
                                        .foregroundStyle(p.tertiaryText)
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Activity Tab

    private func activityTab(p: NativePalette) -> some View {
        let entry = context.store.entry(runsRequest)
        let runs = entry.data?.runs ?? []

        return card("Recent runs", p: p) {
            VStack(alignment: .leading, spacing: 10) {
                if entry.isFetching && entry.data == nil {
                    ProgressView().padding(.vertical, 12)
                } else if runs.isEmpty {
                    Text("No runs yet. Start an assigned ticket to put this persona to work.")
                        .font(.system(size: 13))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { idx, run in
                            if idx > 0 { Divider() }
                            Button {
                                context.navigate("/runs/\(run.id)")
                            } label: {
                                HStack(spacing: 12) {
                                    Text(run.state.capitalized)
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(width: 78, alignment: .leading)
                                        .foregroundStyle(p.secondaryText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(run.ticket.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondaryText)
                                            Text(run.ticket.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        }
                                        Text("\(run.model) \u{00B7} \(run.toolCalls) \(run.toolCalls == 1 ? "tool" : "tools")")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(p.tertiaryText)
                                    }
                                    Spacer()
                                    Text(APIDate.shortAgo(run.startedAt))
                                        .font(.system(size: 11))
                                        .foregroundStyle(p.secondaryText)
                                    Text(run.costSource != nil && run.costSource != "unknown" ? String(format: "$%.2f", run.costUsd) : "\u{2014}")
                                        .font(.system(size: 12, design: .monospaced))
                                        .frame(width: 60, alignment: .trailing)
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Divider()

                    HStack {
                        Button("Previous") { runsOffset = max(0, runsOffset - Self.runsPageSize) }
                            .buttonStyle(.bordered)
                            .disabled(runsOffset == 0)
                        Spacer()
                        Text("\(runsOffset + 1)\u{2013}\(runsOffset + runs.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                        Spacer()
                        Button("Next") { runsOffset += Self.runsPageSize }
                            .buttonStyle(.bordered)
                            .disabled(!(entry.data?.hasMore ?? false))
                    }
                }
            }
        }
    }

    // MARK: - Settings Tab

    private func settingsTab(detail: API.AgentDetail, current: API.SaveAgentDefinitionBody, p: NativePalette) -> some View {
        let harness = detail.harnesses.first { $0.name == current.spec.harness }
        let mem = current.spec.memory ?? API.AgentMemory(enabled: true, inject: .selective, maxTokens: 1500)

        return VStack(alignment: .leading, spacing: 16) {
            card("Identity", p: p) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                            Text(current.name).font(.system(size: 13)).foregroundStyle(p.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Handle").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                            Text("@\(detail.agent.handle)").font(.system(size: 13, design: .monospaced)).foregroundStyle(p.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Role").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        TextField("e.g. Backend · migrations & data models", text: Binding(
                            get: { current.role },
                            set: { v in updateDraft(from: current) { $0.role = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Specialty").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        TextField("Shown in the assignee picker next to the model", text: Binding(
                            get: { current.specialty },
                            set: { v in updateDraft(from: current) { $0.specialty = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Identity color").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        HStack(spacing: 8) {
                            ForEach(0..<Self.hueColors.count, id: \.self) { i in
                                let c = Self.hueColors[i]
                                Button {
                                    updateDraft(from: current) { $0.colorIndex = i }
                                } label: {
                                    Circle()
                                        .fill(c)
                                        .frame(width: 22, height: 22)
                                        .overlay(Circle().stroke(p.text, lineWidth: current.colorIndex == i ? 2 : 0).padding(-2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            card("Runtime", p: p, trailing: {
                Button("Change model on persona page") {
                    context.navigate("/settings?section=personas&persona=\(detail.agent.id)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(p.accent)
            }) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Require independent review before Done", isOn: Binding(
                        get: { current.spec.reviewRequired ?? false },
                        set: { v in updateDraft(from: current) { $0.spec.reviewRequired = v } }
                    ))
                    .font(.system(size: 13))

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Harness").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                            Text(harness?.label ?? current.spec.harness.rawValue).font(.system(size: 13, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                            Text(current.spec.model).font(.system(size: 13, design: .monospaced))
                        }
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Concurrent runs").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                            Stepper("\(current.spec.maxConcurrency)", value: Binding(
                                get: { current.spec.maxConcurrency },
                                set: { v in updateDraft(from: current) { $0.spec.maxConcurrency = v } }
                            ), in: 1...16)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max runtime").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                            TextField("2h", text: Binding(
                                get: { current.spec.budget.maxRuntime ?? "" },
                                set: { v in updateDraft(from: current) { $0.spec.budget.maxRuntime = v.isEmpty ? nil : v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max turns").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                            TextField("turns", text: Binding(
                                get: { current.spec.budget.maxTurns.map(String.init) ?? "" },
                                set: { v in updateDraft(from: current) { $0.spec.budget.maxTurns = Int(v) } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }

            card("Memory", p: p) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Start each run with wiki context", isOn: Binding(
                        get: { mem.enabled },
                        set: { enabled in
                            updateDraft(from: current) {
                                var m = $0.spec.memory ?? mem
                                m.enabled = enabled
                                $0.spec.memory = m
                            }
                        }
                    ))
                    .font(.system(size: 13))

                    if mem.enabled {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Inject").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                                Picker("Inject", selection: Binding(
                                    get: { mem.inject },
                                    set: { inject in
                                        updateDraft(from: current) {
                                            var m = $0.spec.memory ?? mem
                                            m.inject = inject
                                            $0.spec.memory = m
                                        }
                                    }
                                )) {
                                    Text("Selective").tag(API.AgentMemory.Inject.selective)
                                    Text("Index").tag(API.AgentMemory.Inject.index)
                                    Text("Linked").tag(API.AgentMemory.Inject.linked)
                                    Text("Search").tag(API.AgentMemory.Inject.search)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Token budget").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                                TextField("1500", text: Binding(
                                    get: { "\(mem.maxTokens)" },
                                    set: { v in
                                        if let n = Int(v), n >= 500 {
                                            updateDraft(from: current) {
                                                var m = $0.spec.memory ?? mem
                                                m.maxTokens = n
                                                $0.spec.memory = m
                                            }
                                        }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 110)
                            }
                        }
                    }
                }
            }

            card("MCP servers", p: p) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(current.spec.mcpServers.enumerated()), id: \.offset) { idx, srv in
                        HStack(spacing: 8) {
                            Text(srv.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text(srv.url).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondaryText).lineLimit(1)
                            Spacer()
                            Button {
                                updateDraft(from: current) {
                                    if idx < $0.spec.mcpServers.count { $0.spec.mcpServers.remove(at: idx) }
                                }
                            } label: {
                                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("name", text: $newServerName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 120)
                        TextField("https://\u{2026}/mcp", text: $newServerURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Add") {
                            let n = newServerName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let u = newServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !n.isEmpty, !u.isEmpty else { return }
                            updateDraft(from: current) { $0.spec.mcpServers.append(API.McpServer(name: n, url: u)) }
                            newServerName = ""
                            newServerURL = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(newServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            let hKey = current.spec.harness.rawValue
            let hOpts = current.spec.harnessOptions[hKey] ?? [:]
            card("Harness options (\(hKey))", p: p) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hOpts.keys.sorted(), id: \.self) { k in
                        HStack {
                            Text(k).font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text("=").foregroundStyle(p.tertiaryText)
                            Text(hOpts[k] ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondaryText)
                            Spacer()
                            Button {
                                updateDraft(from: current) {
                                    $0.spec.harnessOptions[hKey]?.removeValue(forKey: k)
                                }
                            } label: {
                                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("key", text: $newOptionKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 140)
                        TextField("value", text: $newOptionValue)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Add") {
                            let k = newOptionKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            let v = newOptionValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !k.isEmpty else { return }
                            updateDraft(from: current) {
                                var map = $0.spec.harnessOptions[hKey] ?? [:]
                                map[k] = v
                                $0.spec.harnessOptions[hKey] = map
                            }
                            newOptionKey = ""
                            newOptionValue = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(newOptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Tokens Tab

    private func tokensTab(detail: API.AgentDetail, p: NativePalette) -> some View {
        let entry = context.store.entry(tokensRequest)
        let tokens = entry.data?.tokens ?? []

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                Text("A token lets a local Claude Code, Codex, or Antigravity session act as \(detail.agent.name): same instructions, same Agent API. Vesper only enforces brokered scopes on unmanaged sessions.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)
            }
            .padding(12)
            .background(theme.swiftUIColor("pill-human-bg", fallback: .orange.opacity(0.1)).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if let minted = mintedToken {
                card("Copy this token now (shown once)", p: p) {
                    VStack(alignment: .leading, spacing: 10) {
                        copyableCommand("Token", text: minted.token, p: p)
                        copyableCommand("Claude Code", text: "claude mcp add --transport http lazyagents \(minted.mcpUrl) --header \"Authorization: Bearer \(minted.token)\"", p: p)
                        copyableCommand("Codex", text: "export LAZYAGENTS_TOKEN=\(minted.token)\ncodex mcp add lazyagents --url \(minted.mcpUrl) --bearer-token-env-var LAZYAGENTS_TOKEN", p: p)
                    }
                }
            }

            card("Tokens", p: p) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Label, e.g. Work laptop", text: $newTokenLabel)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        Button("Create token") {
                            createToken()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tokenBusy)
                        if let tokenError {
                            Text(tokenError)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                    }

                    if entry.isFetching && entry.data == nil {
                        ProgressView().padding(.vertical, 8)
                    } else if tokens.isEmpty {
                        Text("No tokens yet.").font(.system(size: 13)).foregroundStyle(p.tertiaryText)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(tokens.enumerated()), id: \.element.id) { idx, tok in
                                if idx > 0 { Divider() }
                                HStack(spacing: 12) {
                                    Text(tok.label.isEmpty ? "Untitled" : tok.label)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(tok.revokedAt != nil ? p.tertiaryText : p.text)
                                    Text("\(tok.prefix)\u{2026}")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(p.secondaryText)
                                    Spacer()
                                    Text(APIDate.shortAgo(tok.createdAt))
                                        .font(.system(size: 11))
                                        .foregroundStyle(p.tertiaryText)
                                    if tok.revokedAt != nil {
                                        Text("Revoked").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                                    } else {
                                        Button("Revoke", role: .destructive) {
                                            revokeToken(tok.id)
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }
    }

    private func createToken() {
        tokenBusy = true
        tokenError = nil
        let label = newTokenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { tokenBusy = false }
            do {
                let res = try await context.store.mutate(
                    API.createAgentToken(handle: handle, body: API.CreateAgentTokenBody(label: label.isEmpty ? nil : label)),
                    invalidating: QueryInvalidation(resources: ["agents"])
                )
                mintedToken = res
                newTokenLabel = ""
                _ = await context.store.refetch(tokensRequest)
            } catch {
                tokenError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func revokeToken(_ id: String) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.revokeAgentToken(handle: handle, tokenId: id),
                    invalidating: QueryInvalidation(resources: ["agents"])
                )
                _ = await context.store.refetch(tokensRequest)
            } catch {
                tokenError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func copyableCommand(_ label: String, text: String, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(p.tertiaryText)
            HStack(alignment: .top, spacing: 8) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    context.copyToClipboard(text)
                    context.showToast(ToastItemModel(id: "agent.tok.copy", title: "Copied \(label)", tone: .success))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        }
    }

    // MARK: - Right-hand Resolved & Overrides Panels

    private func resolvedPanel(
        detail: API.AgentDetail,
        projects: [API.Project],
        selectedKey: String?,
        resolved: API.ResolvedDefinition?,
        p: NativePalette
    ) -> some View {
        card("Resolved for", p: p, trailing: {
            projectPicker(projects: projects, selectedKey: selectedKey)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                if let resolved {
                    resolvedRow("Harness", value: resolved.harness.rawValue, fromSpace: resolved.provenance["harness"] == .project, p: p)
                    resolvedRow("Model", value: resolved.model, fromSpace: resolved.provenance["model"] == .project, p: p)
                    resolvedRow("MCP", value: (["lazyagents"] + resolved.mcpServers.map(\.name)).joined(separator: ", "), fromSpace: resolved.provenance["mcp_servers"] == .project, p: p)

                    let approvalScopes = resolved.scopes.filter { $0.mode == .requiresApproval }
                    if !approvalScopes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Approval").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                            Text(approvalScopes.map(\.scope).joined(separator: ", "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                        }
                    }

                    let deniedScopes = resolved.scopes.filter { $0.mode == .denied }
                    if !deniedScopes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Denied").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                            Text(deniedScopes.map(\.scope).joined(separator: ", "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                    }
                } else {
                    ProgressView().padding(.vertical, 8)
                }

                Text("Each run snapshots this, so editing \(detail.agent.name) never changes a run in progress.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.tertiaryText)
            }
        }
    }

    private func resolvedRow(_ label: String, value: String, fromSpace: Bool, p: NativePalette) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(p.tertiaryText).frame(width: 66, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            if fromSpace {
                Text("space")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(p.secondaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
            }
        }
    }

    private func overridesPanel(detail: API.AgentDetail, projects: [API.Project], p: NativePalette) -> some View {
        let without = projects.filter { proj in !detail.overrides.contains { $0.project.key == proj.key } }
        return card("Space overrides", p: p, trailing: {
            if !without.isEmpty {
                Menu("Add") {
                    ForEach(without, id: \.key) { proj in
                        Button(proj.name) { editingOverrideTarget = OverrideSheetTarget(project: proj) }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 12))
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(detail.overrides, id: \.project.key) { ov in
                    Button {
                        editingOverrideTarget = OverrideSheetTarget(project: ov.project)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(hex: ov.project.color) ?? p.accent)
                                    .frame(width: 8, height: 8)
                                Text(ov.project.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("\(ov.changes.count) \(ov.changes.count == 1 ? "change" : "changes")")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(p.tertiaryText)
                            }
                            ForEach(ov.changes, id: \.self) { line in
                                Text(line).font(.system(size: 11)).foregroundStyle(p.secondaryText).lineLimit(1).padding(.leading, 14)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }

                if detail.overrides.isEmpty {
                    Text("No space overrides yet. Every space uses the work definition as is.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                }
            }
        }
    }

    // MARK: - Review & Save Sheet

    private func reviewSheet(
        detail: API.AgentDetail,
        body: API.SaveAgentDefinitionBody,
        changes: [String],
        p: NativePalette
    ) -> some View {
        let scopeDiffs = AgentDetailLogic.scopeChanges(before: detail.spec.scopes, after: body.spec.scopes)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Review changes to \(detail.agent.name)")
                .vesperText(.heading, theme)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(changes, id: \.self) { line in
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(p.accent)
                            Text(line).font(.system(size: 13))
                        }
                    }

                    if !scopeDiffs.isEmpty {
                        Divider()
                        Text("Permission changes").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.secondaryText)
                        ForEach(scopeDiffs) { sc in
                            HStack(spacing: 8) {
                                Text(sc.scope).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text("\(AgentDetailLogic.scopeModeLabel(sc.effectiveFrom)) \u{2192} \(AgentDetailLogic.scopeModeLabel(sc.effectiveTo))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(sc.kind == .widens ? theme.swiftUIColor("pill-blocked-fg", fallback: .red) : p.secondaryText)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            VStack(alignment: .leading, spacing: 4) {
                Text("Version note (optional)").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                TextField(changes.joined(separator: "; "), text: $reviewNote)
                    .textFieldStyle(.roundedBorder)
            }

            if let saveError {
                Text(saveError)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { showReviewSheet = false }
                    .buttonStyle(.bordered)
                Button(savingDefinition ? "Saving\u{2026}" : "Save v\(detail.definition.version + 1)") {
                    saveDefinition(body: body, defaultNote: changes.joined(separator: "; "))
                }
                .buttonStyle(.borderedProminent)
                .disabled(savingDefinition)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(p.background)
    }

    private func saveDefinition(body: API.SaveAgentDefinitionBody, defaultNote: String) {
        savingDefinition = true
        saveError = nil
        var payload = body
        let trimmedNote = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.note = trimmedNote.isEmpty ? defaultNote : trimmedNote

        Task {
            defer { savingDefinition = false }
            do {
                _ = try await context.store.mutate(
                    API.saveAgentDefinition(handle: handle, body: payload),
                    invalidating: QueryInvalidation(resources: ["agents"])
                )
                draft = nil
                reviewNote = ""
                showReviewSheet = false
                _ = await context.store.refetch(agentRequest)
                context.showToast(ToastItemModel(id: "agent.saved", title: "Saved \(body.name)", tone: .success))
            } catch {
                saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    // MARK: - Shared UI Helpers

    private func projectPicker(projects: [API.Project], selectedKey: String?) -> some View {
        Picker("Space", selection: Binding(
            get: { selectedKey ?? "" },
            set: { selectedProjectKey = $0.isEmpty ? nil : $0 }
        )) {
            if projects.isEmpty {
                Text("No spaces").tag("")
            } else {
                ForEach(projects, id: \.key) { proj in
                    Text(proj.name).tag(proj.key)
                }
            }
        }
        .labelsHidden()
        .frame(maxWidth: 160)
    }

    private func kpiTile(_ label: String, value: String, subtitle: String?, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(p.tertiaryText)
            Text(value).font(.system(size: 20, weight: .semibold, design: .monospaced))
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(p.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func card<Content: View>(
        _ title: String,
        p: NativePalette,
        @ViewBuilder trailing: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func errorState(_ error: APIError, p: NativePalette) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(p.tertiaryText)
            Text("Couldn\u{2019}t load @\(handle)")
                .vesperText(.heading, theme)
            Text(error.userMessage)
                .font(.system(size: 13))
                .foregroundStyle(p.secondaryText)
            HStack(spacing: 10) {
                Button("Retry") {
                    Task { _ = await context.store.refetch(agentRequest) }
                }
                .buttonStyle(.bordered)
                Button("All Personas") {
                    context.navigate("/settings?section=personas")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
