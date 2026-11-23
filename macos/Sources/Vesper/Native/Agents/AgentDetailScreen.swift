import SwiftUI
import VesperCore

/// Native `/agents/:handle` screen: work record for a persona/agent with Overview, Scopes, Skills,
/// Memory, Activity, Settings (definition editor), and Tokens tabs, plus Resolved-for-space card
/// and Space override editor.
struct AgentDetailScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var activeTab: AgentDetailLogic.Tab = .overview
    @State private var selectedProjectKey: String = ""
    @State private var editingOverrideProjectKey: String?
    @State private var showReviewSaveSheet = false
    @State private var saveNote = ""
    @State private var savingDefinition = false
    @State private var saveError: String?

    // Editable definition draft (seeded from loaded AgentDetail)
    @State private var hydratedVersion: Int?
    @State private var draftName = ""
    @State private var draftRole = ""
    @State private var draftSpecialty = ""
    @State private var draftHarness: API.Harness = .claudeCode
    @State private var draftModel = ""
    @State private var draftMaxConcurrency = 1
    @State private var draftReviewRequired = false
    @State private var draftInstructions = ""
    @State private var draftScopes: [String: API.ScopeMode] = [:]
    @State private var draftSkills: [API.AgentSkill] = []
    @State private var draftMemoryEnabled = true
    @State private var draftMemoryInject: API.AgentMemory.Inject = .selective
    @State private var draftMemoryTokens = 8000
    @State private var draftMaxTurns = ""
    @State private var draftMaxRuntime = ""
    @State private var customScopeInput = ""

    // Skills form
    @State private var newSkillName = ""
    @State private var newSkillDesc = ""
    @State private var newSkillBody = ""

    // Tokens form
    @State private var newTokenLabel = ""
    @State private var creatingToken = false
    @State private var mintedToken: API.CreateAgentTokenResponse?
    @State private var tokenError: String?

    @State private var watchedKeys: [QueryKey] = []

    private static let bootRequest = API.getBootstrap()
    private static let overviewsRequest = API.listAgentOverviews()

    private var handle: String {
        context.match.params["handle"] ?? ""
    }

    private var detailRequest: APIRequest<API.AgentDetail> {
        API.getAgent(handle: handle)
    }

    private var runsRequest: APIRequest<API.ListAgentRunsResponse> {
        API.listAgentRuns(handle: handle)
    }

    private var tokensRequest: APIRequest<API.ListAgentTokensResponse> {
        API.listAgentTokens(handle: handle)
    }

    private var resolvedRequest: APIRequest<API.ResolvedDefinition> {
        API.getResolvedDefinition(handle: handle, project: selectedProjectKey.isEmpty ? nil : selectedProjectKey)
    }

    var body: some View {
        let p = theme.palette
        let detailEntry = context.store.entry(detailRequest)
        let detail = detailEntry.data
        let boot = context.store.entry(Self.bootRequest).data
        let projects = (boot?.projects ?? []).filter { !$0.archived }
        let overviews = context.store.entry(Self.overviewsRequest).data?.agents ?? []
        let overview = overviews.first(where: { $0.agent.handle == handle })
        let resolved = context.store.entry(resolvedRequest).data
        let runs = context.store.entry(runsRequest).data?.runs ?? []
        let tokens = context.store.entry(tokensRequest).data?.tokens ?? []

        Group {
            if let error = detailEntry.error, detail == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couldn\u{2019}t load @\(handle)")
                        .vesperText(.heading, theme)
                    Text(error.userMessage)
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                    Button("Back to Work") { context.navigate("/work") }
                        .buttonStyle(.bordered)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let detail {
                let candidateBody = buildSaveBody(from: detail)
                let pendingChanges = AgentDetailLogic.summarizeChanges(original: detail, body: candidateBody)
                let isDirty = !pendingChanges.isEmpty

                VStack(spacing: 0) {
                    if isDirty {
                        HStack(spacing: 10) {
                            Image(systemName: "pencil.circle.fill")
                                .foregroundStyle(p.accent)
                            Text("Unsaved changes: \(pendingChanges.prefix(3).joined(separator: " \u{00B7} "))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            Spacer()
                            Button("Discard") { hydrate(from: detail, force: true) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Review & Save") {
                                saveNote = ""
                                saveError = nil
                                showReviewSaveSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(p.accent.opacity(0.1))
                        Divider()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            headerCard(detail: detail, p: p)
                            tabsBar(p: p)

                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 16) {
                                    tabBody(
                                        detail: detail,
                                        overview: overview,
                                        resolved: resolved,
                                        runs: runs,
                                        tokens: tokens,
                                        projects: projects,
                                        p: p
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                VStack(alignment: .leading, spacing: 16) {
                                    resolvedCard(detail: detail, resolved: resolved, projects: projects, p: p)
                                    overridesCard(detail: detail, projects: projects, p: p)
                                }
                                .frame(width: 280)
                            }
                        }
                        .frame(maxWidth: 1120, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                }
                .sheet(isPresented: $showReviewSaveSheet) {
                    reviewSaveSheet(detail: detail, body: candidateBody, changes: pendingChanges, p: p)
                }
                .sheet(isPresented: Binding(
                    get: { editingOverrideProjectKey != nil },
                    set: { if !$0 { editingOverrideProjectKey = nil } }
                )) {
                    if let key = editingOverrideProjectKey {
                        AgentOverrideSheet(
                            detail: detail,
                            projectKey: key,
                            existing: detail.overrides.first(where: { $0.project.key == key })?.override
                        ) {
                            editingOverrideProjectKey = nil
                            Task {
                                _ = await context.store.refetch(detailRequest)
                                _ = await context.store.refetch(resolvedRequest)
                            }
                        }
                        .environment(context)
                        .environment(\.vesperTheme, theme)
                    }
                }
            } else {
                ProgressView("Loading @\(handle)\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(handle)|\(selectedProjectKey)") {
            syncWatches()
        }
        .onAppear {
            activeTab = AgentDetailLogic.Tab.from(queryParam: context.match.query["tab"])
            if let proj = context.match.query["project"], !proj.isEmpty {
                selectedProjectKey = proj
            }
            if let detail {
                hydrate(from: detail, force: false)
                publishChrome(detail: detail)
            } else {
                context.chrome = NativeChrome(title: "@\(handle)")
            }
        }
        .onChange(of: detail?.definition.version) { _, _ in
            if let detail {
                hydrate(from: detail, force: false)
                publishChrome(detail: detail)
            }
        }
        .onChange(of: detail?.agent.name) { _, _ in
            if let detail { publishChrome(detail: detail) }
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    // MARK: - Header & Tabs

    private func headerCard(detail: API.AgentDetail, p: NativePalette) -> some View {
        HStack(alignment: .center, spacing: 14) {
            WorkPersonaAvatarView(
                id: detail.agent.id,
                handle: detail.agent.handle,
                name: detail.agent.name,
                size: 40,
                active: detail.agent.status == .running
            )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(detail.agent.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text("@\(detail.agent.handle)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                    statusBadge(detail.agent.status)
                    Text("v\(detail.definition.version)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                Text([detail.agent.role, detail.specialty].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.system(size: 13))
                    .foregroundStyle(p.secondaryText)
            }
            Spacer()
            Button("Persona in Settings") {
                context.navigate("/settings?section=personas&persona=\(detail.agent.id)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func tabsBar(p: NativePalette) -> some View {
        HStack(spacing: 4) {
            ForEach(AgentDetailLogic.Tab.allCases) { tab in
                let selected = activeTab == tab
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? p.text : p.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selected ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(p.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabBody(
        detail: API.AgentDetail,
        overview: API.AgentOverview?,
        resolved: API.ResolvedDefinition?,
        runs: [API.AgentRunSummary],
        tokens: [API.AgentToken],
        projects: [API.Project],
        p: NativePalette
    ) -> some View {
        switch activeTab {
        case .overview:
            overviewTab(detail: detail, overview: overview, p: p)
        case .scopes:
            scopesTab(detail: detail, p: p)
        case .skills:
            skillsTab(detail: detail, p: p)
        case .memory:
            memoryTab(p: p)
        case .activity:
            activityTab(runs: runs, p: p)
        case .settings:
            settingsTab(detail: detail, p: p)
        case .tokens:
            tokensTab(tokens: tokens, p: p)
        }
    }

    // MARK: - Overview Tab

    private func overviewTab(detail: API.AgentDetail, overview: API.AgentOverview?, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stats = overview?.stats {
                HStack(spacing: 12) {
                    metricCard(title: "Completed", value: "\(stats.completed)", p: p)
                    metricCard(title: "Merged PRs", value: "\(stats.mergedPrs)", p: p)
                    metricCard(title: "Spend", value: String(format: "$%.2f", stats.spendUsd), p: p)
                    metricCard(title: "Queue", value: "\(overview?.queueCount ?? 0)", p: p)
                }
            }

            if let assignments = overview?.assignments, !assignments.isEmpty {
                sectionCard(title: "Active work", p: p) {
                    ForEach(assignments, id: \.runId) { item in
                        Button {
                            context.navigate("/runs/\(item.runId)")
                        } label: {
                            HStack {
                                Text(item.ticket.key)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(p.accent)
                                Text(item.ticket.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(item.state)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(p.secondaryText)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            sectionCard(title: "Work brief", p: p) {
                if detail.spec.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No instructions configured yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    Text(detail.spec.instructions)
                        .font(.system(size: 13))
                        .foregroundStyle(p.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            sectionCard(title: "Definition history", p: p) {
                ForEach(detail.versions.prefix(8), id: \.id) { ver in
                    HStack {
                        Text("v\(ver.version)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(p.text)
                        Text(ver.note.isEmpty ? "Updated definition" : ver.note)
                            .font(.system(size: 12))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(APIDate.shortAgo(ver.createdAt))
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    // MARK: - Scopes Tab

    private func scopesTab(detail: API.AgentDetail, p: NativePalette) -> some View {
        let overrideScopes = detail.overrides.first(where: { $0.project.key == selectedProjectKey })?.override.scopes
        let rows = AgentDetailLogic.scopeRows(
            catalog: detail.catalog.map(\.scope),
            agent: draftScopes,
            override: overrideScopes
        )
        let catalogByScope = Dictionary(uniqueKeysWithValues: detail.catalog.map { ($0.scope, $0) })

        return VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "Scope permissions", p: p) {
                HStack(spacing: 8) {
                    TextField("Add custom scope (e.g. db:read)", text: $customScopeInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Add") {
                        let s = customScopeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty {
                            draftScopes[s] = .requiresApproval
                            customScopeInput = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(customScopeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom, 6)

                ForEach(rows) { row in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.scope)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(p.text)
                                if row.effective.source == "project" {
                                    Text("space tightened")
                                        .font(.system(size: 10))
                                        .foregroundStyle(p.accent)
                                }
                            }
                            if let info = catalogByScope[row.scope] {
                                Text(info.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { draftScopes[row.scope]?.rawValue ?? "__unset__" },
                            set: { next in
                                if next == "__unset__" {
                                    draftScopes.removeValue(forKey: row.scope)
                                } else {
                                    draftScopes[row.scope] = API.ScopeMode(rawValue: next)
                                }
                            }
                        )) {
                            Text("Not granted").tag("__unset__")
                            Text("Allowed").tag(API.ScopeMode.allowed.rawValue)
                            Text("Approval").tag(API.ScopeMode.requiresApproval.rawValue)
                            Text("Denied").tag(API.ScopeMode.denied.rawValue)
                        }
                        .labelsHidden()
                        .frame(width: 124)
                    }
                    .padding(.vertical, 5)
                    Divider()
                }
            }
        }
    }

    // MARK: - Skills Tab

    private func skillsTab(detail: API.AgentDetail, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "Skills (\(draftSkills.count))", p: p) {
                if draftSkills.isEmpty {
                    Text("No skills attached. Skills are on-demand playbooks loaded when matching tasks arise.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    ForEach(Array(draftSkills.enumerated()), id: \.offset) { idx, skill in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(skill.name)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(p.text)
                                Spacer()
                                Button {
                                    draftSkills.remove(at: idx)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                }
                                .buttonStyle(.plain)
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.secondaryText)
                            }
                            Text(skill.body)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                                .lineLimit(4)
                        }
                        .padding(10)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            sectionCard(title: "Add skill", p: p) {
                TextField("Skill name (lowercase, digits, hyphens)", text: $newSkillName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                TextField("When to use it", text: $newSkillDesc)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newSkillBody)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                HStack {
                    Spacer()
                    Button("Add skill") {
                        let name = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !name.isEmpty, !newSkillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        draftSkills.append(API.AgentSkill(
                            body: newSkillBody,
                            description: newSkillDesc.trimmingCharacters(in: .whitespacesAndNewlines),
                            name: name
                        ))
                        newSkillName = ""
                        newSkillDesc = ""
                        newSkillBody = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newSkillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Memory Tab

    private func memoryTab(p: NativePalette) -> some View {
        sectionCard(title: "Agent memory", p: p) {
            Toggle("Enable agent memory", isOn: $draftMemoryEnabled)
            if draftMemoryEnabled {
                Picker("Injection strategy", selection: $draftMemoryInject) {
                    ForEach(API.AgentMemory.Inject.allKnown, id: \.rawValue) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                HStack {
                    Text("Max injected tokens")
                        .font(.system(size: 13))
                        .foregroundStyle(p.secondaryText)
                    Spacer()
                    Stepper("\(draftMemoryTokens)", value: $draftMemoryTokens, in: 1000...64000, step: 1000)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    // MARK: - Activity Tab

    private func activityTab(runs: [API.AgentRunSummary], p: NativePalette) -> some View {
        sectionCard(title: "Recent runs (\(runs.count))", p: p) {
            if runs.isEmpty {
                Text("No runs recorded for @\(handle) yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(p.tertiaryText)
            } else {
                ForEach(runs, id: \.id) { run in
                    Button {
                        context.navigate("/runs/\(run.id)")
                    } label: {
                        HStack(spacing: 10) {
                            Text(run.ticket.key)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.accent)
                                .frame(width: 96, alignment: .leading)
                            Text(run.ticket.title)
                                .font(.system(size: 13))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            Spacer()
                            Text(run.state)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(p.secondaryText)
                            Text(String(format: "$%.2f", run.costUsd))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                            Text(APIDate.shortAgo(run.startedAt))
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    // MARK: - Settings / Definition Tab

    private func settingsTab(detail: API.AgentDetail, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "Identity & runtime", p: p) {
                HStack(spacing: 12) {
                    labeledField("Name") { TextField("Name", text: $draftName).textFieldStyle(.roundedBorder) }
                    labeledField("Role") { TextField("Role", text: $draftRole).textFieldStyle(.roundedBorder) }
                }
                labeledField("Specialty") { TextField("Specialty", text: $draftSpecialty).textFieldStyle(.roundedBorder) }

                HStack(spacing: 12) {
                    labeledField("Harness") {
                        Picker("Harness", selection: $draftHarness) {
                            ForEach(detail.harnesses, id: \.name.rawValue) { h in
                                Text(h.label).tag(h.name)
                            }
                        }
                        .labelsHidden()
                    }
                    labeledField("Model") {
                        TextField("Model ID", text: $draftModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                HStack(spacing: 12) {
                    Stepper("Max concurrency: \(draftMaxConcurrency)", value: $draftMaxConcurrency, in: 1...8)
                    Spacer()
                    Toggle("Require review before Done", isOn: $draftReviewRequired)
                }

                HStack(spacing: 12) {
                    labeledField("Max turns (optional)") {
                        TextField("e.g. 60", text: $draftMaxTurns)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    labeledField("Max runtime (optional)") {
                        TextField("e.g. 2h", text: $draftMaxRuntime)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }

            sectionCard(title: "Work brief (instructions)", p: p) {
                TextEditor(text: $draftInstructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
        }
    }

    // MARK: - Tokens Tab

    private func tokensTab(tokens: [API.AgentToken], p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionCard(title: "API tokens", p: p) {
                HStack(spacing: 8) {
                    TextField("Token label (optional)", text: $newTokenLabel)
                        .textFieldStyle(.roundedBorder)
                    Button(creatingToken ? "Creating\u{2026}" : "Create token") {
                        createToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(creatingToken)
                }

                if let mintedToken {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copy this token now — it won\u{2019}t be shown again.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                        HStack {
                            Text(mintedToken.token)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                            Spacer()
                            Button("Copy") {
                                context.copyToClipboard(mintedToken.token)
                                context.showToast(ToastItemModel(id: "agent.tok.copy", title: "Copied token", tone: .success))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .background(theme.swiftUIColor("state-done", fallback: .green).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                if let tokenError {
                    Text(tokenError)
                        .font(.caption)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }

                Divider()

                if tokens.isEmpty {
                    Text("No active API tokens for @\(handle).")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    ForEach(tokens, id: \.id) { tok in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tok.label.isEmpty ? "Untitled token" : tok.label)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("\(tok.prefix)\u{2026}")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(p.tertiaryText)
                                }
                                Text("Created \(APIDate.shortAgo(tok.createdAt))\(tok.lastUsedAt.map { " \u{00B7} last used \(APIDate.shortAgo($0))" } ?? "")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                            }
                            Spacer()
                            if tok.revokedAt != nil {
                                Text("Revoked")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                            } else {
                                Button("Revoke", role: .destructive) {
                                    revokeToken(tok.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Right Rail Cards (Resolved & Overrides)

    private func resolvedCard(
        detail: API.AgentDetail,
        resolved: API.ResolvedDefinition?,
        projects: [API.Project],
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Resolved for")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Space", selection: $selectedProjectKey) {
                    Text("Default").tag("")
                    ForEach(projects, id: \.key) { proj in
                        Text(proj.key).tag(proj.key)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            if let resolved {
                factRow("Harness", resolved.harness.rawValue, mono: true, p: p)
                factRow("Model", resolved.model, mono: true, p: p)
                let mcpNames = (["lazyagents"] + resolved.mcpServers.map(\.name)).joined(separator: ", ")
                factRow("MCP", mcpNames, mono: true, p: p)
                let approvalCount = resolved.scopes.filter { $0.mode == .requiresApproval }.count
                let deniedCount = resolved.scopes.filter { $0.mode == .denied }.count
                factRow("Approval", "\(approvalCount) scopes", mono: false, p: p)
                factRow("Denied", "\(deniedCount) scopes", mono: false, p: p)
            } else {
                ProgressView().controlSize(.small)
            }

            Text("Each run stores a snapshot of this, so editing \(detail.agent.name) never changes a run in progress.")
                .font(.system(size: 11))
                .foregroundStyle(p.tertiaryText)
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
    }

    private func overridesCard(detail: API.AgentDetail, projects: [API.Project], p: NativePalette) -> some View {
        let without = projects.filter { proj in !detail.overrides.contains(where: { $0.project.key == proj.key }) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Space overrides")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !without.isEmpty {
                    Menu("Add") {
                        ForEach(without, id: \.key) { proj in
                            Button("\(proj.name) (\(proj.key))") {
                                editingOverrideProjectKey = proj.key
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if detail.overrides.isEmpty {
                Text("No per-space overrides configured.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.tertiaryText)
            } else {
                ForEach(detail.overrides, id: \.project.key) { ov in
                    Button {
                        editingOverrideProjectKey = ov.project.key
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ov.project.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.text)
                                Text(ov.changes.isEmpty ? "Override active" : ov.changes.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .padding(8)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
    }

    // MARK: - Review & Save Sheet

    private func reviewSaveSheet(
        detail: API.AgentDetail,
        body: API.SaveAgentDefinitionBody,
        changes: [String],
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review definition changes")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(changes, id: \.self) { line in
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(p.accent)
                        Text(line).font(.system(size: 13))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 8))

            TextField("Change note (optional)", text: $saveNote)
                .textFieldStyle(.roundedBorder)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { showReviewSaveSheet = false }
                    .disabled(savingDefinition)
                Button(savingDefinition ? "Saving\u{2026}" : "Save v\(detail.definition.version + 1)") {
                    saveDefinition(body: body)
                }
                .buttonStyle(.borderedProminent)
                .disabled(savingDefinition)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Helpers & Mutations

    private func metricCard(title: String, value: String, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(p.tertiaryText)
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(p.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func sectionCard<Content: View>(title: String, p: NativePalette, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.text)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(theme.palette.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factRow(_ label: String, _ value: String, mono: Bool, p: NativePalette) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(p.tertiaryText).frame(width: 72, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(p.text)
                .lineLimit(2)
            Spacer()
        }
    }

    private func statusBadge(_ status: API.Agent.Status) -> some View {
        let color: Color = switch status {
        case .running: theme.swiftUIColor("state-done", fallback: .green)
        case .waiting: theme.swiftUIColor("pill-human-fg", fallback: .orange)
        case .blocked: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        default: theme.palette.secondaryText
        }
        return Text(status.rawValue.capitalized)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func hydrate(from detail: API.AgentDetail, force: Bool) {
        if !force && hydratedVersion == detail.definition.version { return }
        hydratedVersion = detail.definition.version
        draftName = detail.agent.name
        draftRole = detail.agent.role
        draftSpecialty = detail.specialty
        draftHarness = detail.spec.harness
        draftModel = detail.spec.model
        draftMaxConcurrency = detail.spec.maxConcurrency
        draftReviewRequired = detail.spec.reviewRequired ?? false
        draftInstructions = detail.spec.instructions
        draftScopes = detail.spec.scopes
        draftSkills = detail.spec.skills ?? []
        draftMemoryEnabled = detail.spec.memory?.enabled ?? true
        draftMemoryInject = detail.spec.memory?.inject ?? .selective
        draftMemoryTokens = detail.spec.memory?.maxTokens ?? 8000
        draftMaxTurns = detail.spec.budget.maxTurns.map(String.init) ?? ""
        draftMaxRuntime = detail.spec.budget.maxRuntime ?? ""
    }

    private func buildSaveBody(from detail: API.AgentDetail) -> API.SaveAgentDefinitionBody {
        let turns = Int(draftMaxTurns.trimmingCharacters(in: .whitespacesAndNewlines))
        let runtimeTrim = draftMaxRuntime.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = API.AgentSpec(
            budget: API.Budget(maxRuntime: runtimeTrim.isEmpty ? nil : runtimeTrim, maxTurns: turns),
            fallbacks: detail.spec.fallbacks,
            harness: draftHarness,
            harnessOptions: detail.spec.harnessOptions,
            instructions: draftInstructions,
            maxConcurrency: draftMaxConcurrency,
            mcpServers: detail.spec.mcpServers,
            memory: API.AgentMemory(enabled: draftMemoryEnabled, inject: draftMemoryInject, maxTokens: draftMemoryTokens),
            model: draftModel,
            reviewRequired: draftReviewRequired,
            scopes: draftScopes,
            skills: draftSkills
        )
        return API.SaveAgentDefinitionBody(
            colorIndex: detail.agent.colorIndex,
            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? detail.agent.name : draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            note: saveNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : saveNote.trimmingCharacters(in: .whitespacesAndNewlines),
            role: draftRole.trimmingCharacters(in: .whitespacesAndNewlines),
            spec: spec,
            specialty: draftSpecialty.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func saveDefinition(body: API.SaveAgentDefinitionBody) {
        savingDefinition = true
        saveError = nil
        Task {
            defer { savingDefinition = false }
            do {
                var withNote = body
                let n = saveNote.trimmingCharacters(in: .whitespacesAndNewlines)
                withNote.note = n.isEmpty ? nil : n
                let updated = try await context.store.mutate(
                    API.saveAgentDefinition(handle: handle, body: withNote),
                    invalidating: QueryInvalidation(resources: ["agents", "bootstrap"])
                )
                context.store.setData(updated, for: detailRequest)
                hydrate(from: updated, force: true)
                _ = await context.store.refetch(resolvedRequest)
                showReviewSaveSheet = false
                context.showToast(ToastItemModel(id: "agent.saved", title: "Saved v\(updated.definition.version)", tone: .success))
            } catch {
                saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func createToken() {
        creatingToken = true
        tokenError = nil
        let label = newTokenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { creatingToken = false }
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

    private func revokeToken(_ tokenId: String) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.revokeAgentToken(handle: handle, tokenId: tokenId),
                    invalidating: QueryInvalidation(resources: ["agents"])
                )
                _ = await context.store.refetch(tokensRequest)
            } catch {
                tokenError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func publishChrome(detail: API.AgentDetail) {
        context.chrome = NativeChrome(
            title: detail.agent.name,
            subtitle: "@\(detail.agent.handle)"
        )
    }

    private func syncWatches() {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        if !handle.isEmpty {
            watch(detailRequest)
            watch(resolvedRequest)
            watch(runsRequest)
            watch(tokensRequest)
        }
        watch(Self.bootRequest)
        watch(Self.overviewsRequest)
    }
}

private struct AgentOverrideSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let detail: API.AgentDetail
    let projectKey: String
    let existing: API.AgentOverride?
    let onSaved: () -> Void

    @State private var harnessRaw = ""
    @State private var model = ""
    @State private var instructionsAppend = ""
    @State private var scopes: [String: API.ScopeMode] = [:]
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            Text("Space override: \(projectKey)")
                .font(.headline)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Harness override").font(.caption).foregroundStyle(p.secondaryText)
                    Picker("Harness", selection: $harnessRaw) {
                        Text("Inherit (\(detail.spec.harness.rawValue))").tag("")
                        ForEach(detail.harnesses, id: \.name.rawValue) { h in
                            Text(h.label).tag(h.name.rawValue)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model override").font(.caption).foregroundStyle(p.secondaryText)
                    TextField("Inherit (\(detail.spec.model))", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Append to instructions").font(.caption).foregroundStyle(p.secondaryText)
                TextEditor(text: $instructionsAppend)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(saving)
                Button(saving ? "Saving\u{2026}" : "Save override") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            harnessRaw = existing?.harness?.rawValue ?? ""
            model = existing?.model ?? ""
            instructionsAppend = existing?.instructionsAppend ?? ""
            scopes = existing?.scopes ?? [:]
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let trimModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimInst = instructionsAppend.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = API.AgentOverride(
            budget: existing?.budget,
            harness: harnessRaw.isEmpty ? nil : API.Harness(rawValue: harnessRaw),
            instructionsAppend: trimInst.isEmpty ? nil : trimInst,
            mcpServersAdd: existing?.mcpServersAdd,
            model: trimModel.isEmpty ? nil : trimModel,
            scopes: scopes.isEmpty ? nil : scopes,
            services: existing?.services,
            setup: existing?.setup,
            skillsAdd: existing?.skillsAdd,
            skillsRemove: existing?.skillsRemove
        )
        Task {
            defer { saving = false }
            do {
                _ = try await context.store.mutate(
                    API.setAgentOverride(handle: detail.agent.handle, project: projectKey, body: body),
                    invalidating: QueryInvalidation(resources: ["agents"])
                )
                onSaved()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
