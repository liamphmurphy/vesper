import SwiftUI
import VesperCore

struct SettingsRunnersPane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var selectedSnapshotRunId = ""
    @State private var editingRecipeRepo: String?
    @State private var recipeDraft = ""
    @State private var recipeParseError: String?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let runnerEntry = store?.entry(API.getRunnerStatus())
        let modelsEntry = store?.entry(API.listChatModels())
        let envRequest = API.getRunnerEnvironment(runId: navigation.runnerRunId)
        let envEntry = store?.entry(envRequest)
        let testEnvEntry = store?.entry(API.listTestEnvironments())

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Runners",
                subtitle: "Online runner capacity, workspace storage mode, environment snapshots, and inferred test services."
            ) {
                Button("Refresh") {
                    Task {
                        await store?.refetch(API.getRunnerStatus())
                        await store?.refetch(API.listChatModels())
                        await store?.refetch(envRequest)
                        await store?.refetch(API.listTestEnvironments())
                    }
                }
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Runner action failed", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }

            // MARK: Runner status & settings
            if let status = runnerEntry?.data {
                HStack(spacing: 12) {
                    statBox(label: "Runners online", value: "\(status.runners.count)", sub: status.online ? "Online" : (status.starting == true ? "Starting…" : "Offline"))
                    statBox(label: "Busy slots", value: "\(status.busy) / \(status.slots)", sub: "\(status.live) live · \(status.queued) queued")
                    statBox(
                        label: "Workspaces",
                        value: status.hostFolderWorkspaces ? "Host folders" : "Ephemeral",
                        sub: "New runs keep checkouts on host when enabled"
                    )
                }

                SettingsCard("Runner settings & backends") {
                    Toggle(isOn: Binding(
                        get: { status.hostFolderWorkspaces },
                        set: { next in updateHostFolderWorkspaces(next) }
                    )) {
                        Text("Host-folder workspaces")
                        Text("Keep git checkouts in each runner's host_workspaces_dir instead of inside temporary run disks.")
                    }
                    .disabled(busy)

                    if !status.runners.isEmpty {
                        Divider()
                        ForEach(status.runners, id: \.id) { runner in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(runner.id).font(.callout.monospaced().weight(.medium))
                                        SettingsBadge(label: runner.backend.rawValue, tone: .done)
                                        if let version = runner.version, !version.isEmpty {
                                            Text("v\(version)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let dir = runner.hostWorkspacesDir, !dir.isEmpty {
                                        Text("Host dir: \(dir)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Text("Heartbeat \(SettingsDateFormatter.relative(runner.heartbeatAt))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Text("\(runner.running) / \(runner.slotLimit ?? runner.maxConcurrent) running")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    } else {
                        Text("No runner online. Active chats and workflows wait until a runner connects.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                subagentTierRulesCard(status: status, groups: modelsEntry?.data)
            } else if runnerEntry?.isFetching == true {
                SettingsCard { ProgressView("Loading runner status…") }
            } else {
                SettingsUnavailableCard(title: "Couldn't load runner status", error: runnerEntry?.error) {
                    Task { await store?.refetch(API.getRunnerStatus()) }
                }
            }

            // MARK: Runner environment (/settings/runner)
            if navigation.runnerRunId != nil {
                SettingsBanner(tone: .neutral, title: "Showing the environment recorded for run \(navigation.runnerRunId ?? "").") {
                    Button("View latest environments") {
                        navigation.runnerRunId = nil
                        selectedSnapshotRunId = ""
                    }
                }
            }

            if let env = envEntry?.data {
                let snapshot = env.snapshots.first(where: { $0.runId == selectedSnapshotRunId }) ?? env.snapshots.first
                SettingsCard("Runner environment snapshots", subtitle: "Shared tools, caches, and dependencies reported during workspace setup.") {
                    if let snapshot {
                        let report = snapshot.report
                        let live = env.runner.runners.contains(where: { $0.id == snapshot.runnerId })
                        if navigation.runnerRunId == nil && env.snapshots.count > 1 {
                            Picker("Snapshot", selection: $selectedSnapshotRunId) {
                                ForEach(env.snapshots, id: \.runId) { s in
                                    Text("\(s.projectName) · \(s.runnerId.isEmpty ? "Unknown runner" : s.runnerId) · \(reportStatusLabel(s.report.status))")
                                        .tag(s.runId)
                                }
                            }
                        }

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(snapshot.projectName).font(.headline)
                                    Text(snapshot.projectKey).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    SettingsBadge(label: live ? "Runner online" : "Runner offline", tone: live ? .done : .neutral)
                                    SettingsBadge(label: reportStatusLabel(report.status), tone: reportStatusTone(report.status))
                                }
                                Text("\(snapshot.runnerId.isEmpty ? "Unknown runner" : snapshot.runnerId) · \(snapshot.backend)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("Observed \(SettingsDateFormatter.absolute(snapshot.recordedAt))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("\(snapshot.ticketKey) run log") {
                                aux.openInMainWindow("/runs/\(snapshot.runId)")
                            }
                        }

                        if report.status == .failed {
                            SettingsBanner(tone: .blocked, title: "Dependency setup failed", message: report.error ?? "Open the run log for details.")
                        } else if report.status == .unconfigured {
                            SettingsBanner(tone: .neutral, title: "No project dependency manifest", message: "Add \(report.manifest) to prepare project libraries automatically.")
                        }

                        Divider()
                        Text("Shared tools (\(report.tools.count))").font(.subheadline.weight(.medium))
                        if report.tools.isEmpty {
                            Text("Tool inventory not reported.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 6) {
                                ForEach(report.tools, id: \.name) { tool in
                                    HStack(spacing: 6) {
                                        Text(tool.name).font(.caption.monospaced().weight(.medium))
                                        if let ver = tool.version {
                                            Text(ver).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        SettingsBadge(label: tool.available ? "OK" : "Missing", tone: tool.available ? .done : .blocked)
                                    }
                                    .padding(6)
                                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }

                        if !report.caches.isEmpty {
                            Divider()
                            Text("Dependency caches").font(.subheadline.weight(.medium))
                            ForEach(report.caches, id: \.name) { cache in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cache.name).font(.callout.weight(.medium))
                                        Text(cache.path).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    SettingsBadge(
                                        label: !cache.exists ? "Not created" : (cache.writable ? "Writable" : "Read-only"),
                                        tone: cache.exists && !cache.writable ? .human : .neutral
                                    )
                                }
                            }
                        }

                        if !report.packages.isEmpty {
                            Divider()
                            Text("Project dependencies (\(report.packages.count >= 200 ? "First 200" : "\(report.packages.count)"))")
                                .font(.subheadline.weight(.medium))
                            ForEach(Array(report.packages.prefix(40).enumerated()), id: \.offset) { _, pkg in
                                HStack {
                                    Text(pkg.name).font(.caption.monospaced())
                                    Spacer()
                                    Text("\(pkg.version) · \(pkg.ecosystem) · \(pkg.project)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text(navigation.runnerRunId != nil
                             ? "No environment recorded for this run."
                             : "No environment snapshots yet. Start a ticket run to report tools and dependencies here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: Test environments
            SettingsCard("Test environments", subtitle: "Services started alongside turns and Nix tools learned per repository.") {
                if let envs = testEnvEntry?.data?.environments {
                    if envs.isEmpty {
                        Text("None recorded yet. A run records one when its CI declares services or an agent installs Nix packages.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(envs, id: \.repo) { env in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(env.repo).font(.callout.monospaced().weight(.medium))
                                        Text(testEnvProvenance(env))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(editingRecipeRepo == env.repo ? "Cancel" : "Edit JSON") {
                                        if editingRecipeRepo == env.repo {
                                            editingRecipeRepo = nil
                                        } else {
                                            let enc = JSONEncoder()
                                            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                                            recipeDraft = (try? String(data: enc.encode(env.recipe), encoding: .utf8)) ?? "{}"
                                            recipeParseError = nil
                                            editingRecipeRepo = env.repo
                                        }
                                    }
                                    Button("Forget") { forgetTestEnv(env.repo) }
                                        .foregroundStyle(.red)
                                        .disabled(busy)
                                }

                                if editingRecipeRepo == env.repo {
                                    TextEditor(text: $recipeDraft)
                                        .font(.caption.monospaced())
                                        .frame(height: 160)
                                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                                        .onChange(of: recipeDraft) { _, text in
                                            do {
                                                _ = try JSONDecoder().decode(API.TestRecipe.self, from: Data(text.utf8))
                                                recipeParseError = nil
                                            } catch {
                                                recipeParseError = error.localizedDescription
                                            }
                                        }
                                    if let recipeParseError {
                                        Text(recipeParseError).font(.caption).foregroundStyle(.red)
                                    }
                                    HStack {
                                        Spacer()
                                        Button("Save Recipe") { saveTestEnv(repo: env.repo) }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(busy || recipeParseError != nil)
                                    }
                                } else {
                                    let services = env.recipe.services ?? []
                                    let packages = env.recipe.nixPackages ?? []
                                    ForEach(services, id: \.name) { svc in
                                        HStack(spacing: 8) {
                                            SettingsBadge(label: svc.name, tone: .neutral)
                                            Text(svc.image).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                    if !packages.isEmpty {
                                        Text("Nix packages: \(packages.joined(separator: ", "))")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    if services.isEmpty && packages.isEmpty {
                                        Text("Runs start with the base image.").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                } else if testEnvEntry?.isFetching == true {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .task(id: navigation.runnerRunId) {
            store?.load(API.getRunnerStatus())
            store?.load(API.listChatModels())
            store?.load(envRequest)
            store?.load(API.listTestEnvironments())
        }
    }

    @ViewBuilder
    private func subagentTierRulesCard(status: API.RunnerStatus, groups: [API.ChatHarnessModels]?) -> some View {
        let enabled = status.subagentTierRouting ?? true
        let currentRules = status.subagentTierModels ?? [:]

        SettingsCard(
            "Subagent model tiers",
            subtitle: "Route subagents across reasoning effort or per-harness Deep / Standard / Fast model ladders."
        ) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { next in updateRunnerSettings(API.RunnerSettings(subagentTierRouting: next), message: "Updated subagent tier routing.") }
            )) {
                Text("Automatic subagent tier routing")
                Text(
                    enabled
                        ? "Personas pick fast, standard, or deep per subagent. By default each subagent scales reasoning effort on the parent’s model; configure optional per-harness ladders below to step across models, capped at the parent’s tier."
                        : "Subagent tier routing is off: helpers inherit the parent’s model and effort unchanged, and explorers use their default fast model. Chat’s Auto model picker is unaffected."
                )
            }
            .disabled(busy)

            if enabled {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SubagentTierRulesLogic.harnesses) { harness in
                        let entry = currentRules[harness.id]
                        let hasCustom = SubagentTierRulesLogic.hasCustomRules(entry)
                        let group = groups?.first(where: { $0.harness.rawValue == harness.id })
                        let rawModels = group?.models ?? []
                        let options = SubagentTierRulesLogic.selectableModels(rawModels)
                        let anyStale = SubagentTierRulesLogic.TierKey.allCases.contains {
                            SubagentTierRulesLogic.isStaleModel(SubagentTierRulesLogic.model(for: $0, in: entry), catalog: rawModels)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(harness.label).font(.callout.weight(.medium))
                                SettingsBadge(label: hasCustom ? "Custom ladder" : "Effort only", tone: hasCustom ? .done : .neutral)
                                Spacer()
                                if hasCustom {
                                    Button("Reset") {
                                        let next = SubagentTierRulesLogic.clearingHarness(in: currentRules, harness: harness.id)
                                        updateRunnerSettings(API.RunnerSettings(subagentTierModels: next), message: "Reset \(harness.label) subagent tiers.")
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .disabled(busy)
                                }
                            }

                            HStack(spacing: 10) {
                                ForEach(SubagentTierRulesLogic.TierKey.allCases) { tier in
                                    let val = SubagentTierRulesLogic.model(for: tier, in: entry)
                                    let stale = SubagentTierRulesLogic.isStaleModel(val, catalog: rawModels)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(tier.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Picker(tier.label, selection: Binding(
                                            get: { val },
                                            set: { newVal in
                                                let next = SubagentTierRulesLogic.settingModel(
                                                    in: currentRules,
                                                    harness: harness.id,
                                                    tier: tier,
                                                    modelId: newVal
                                                )
                                                updateRunnerSettings(
                                                    API.RunnerSettings(subagentTierModels: next),
                                                    message: "Updated \(harness.label) \(tier.label.lowercased()) tier model."
                                                )
                                            }
                                        )) {
                                            Text("Parent model (effort only)").tag("")
                                            ForEach(options, id: \.id) { m in
                                                Text(m.label.isEmpty ? m.id : m.label).tag(m.id)
                                            }
                                            if stale {
                                                Text("\(val) (not in catalog)").tag(val)
                                            } else if group == nil && !val.isEmpty {
                                                Text(val).tag(val)
                                            }
                                        }
                                        .labelsHidden()
                                        .disabled(busy)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            if anyStale {
                                Text("Retired or unlisted models fall back safely to the parent model with scaled effort until updated.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if group == nil || (group?.available == false && rawModels.isEmpty) {
                                Text(
                                    group?.checking == true
                                        ? "Checking available models…"
                                        : "Connect this harness in Secrets & Credentials to pick from its live model list."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func statBox(label: String, value: String, sub: String) -> some View {
        SettingsCard {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func reportStatusLabel(_ s: API.EnvironmentReport.Status) -> String {
        switch s {
        case .ready: return "Ready"
        case .failed: return "Setup failed"
        default: return "No manifest"
        }
    }

    private func reportStatusTone(_ s: API.EnvironmentReport.Status) -> SettingsBadgeTone {
        switch s {
        case .ready: return .done
        case .failed: return .blocked
        default: return .neutral
        }
    }

    private func testEnvProvenance(_ env: API.TestEnvironment) -> String {
        var base: String
        if let edited = env.editedAt { base = "Edited \(SettingsDateFormatter.absolute(edited))" }
        else if env.learnedFromRunId != nil { base = "Updated \(SettingsDateFormatter.absolute(env.updatedAt))" }
        else { base = "Inferred \(SettingsDateFormatter.absolute(env.createdAt))" }
        if !env.inferredFrom.isEmpty { base += " · read from \(env.inferredFrom.joined(separator: ", "))" }
        return base
    }

    private func updateHostFolderWorkspaces(_ enabled: Bool) {
        updateRunnerSettings(API.RunnerSettings(hostFolderWorkspaces: enabled), message: "Updated runner workspace setting.")
    }

    private func updateRunnerSettings(_ patch: API.RunnerSettings, message: String) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let updated = try await store.mutate(API.updateRunnerSettings(body: patch))
                store.setData(updated, for: API.getRunnerStatus())
                statusMessage = message
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func saveTestEnv(repo: String) {
        guard let store, let recipe = try? JSONDecoder().decode(API.TestRecipe.self, from: Data(recipeDraft.utf8)) else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.putTestEnvironment(body: API.TestEnvironmentInput(recipe: recipe, repo: repo)))
                editingRecipeRepo = nil
                await store.refetch(API.listTestEnvironments())
                statusMessage = "Saved test environment for \(repo)."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func forgetTestEnv(_ repo: String) {
        guard SettingsFilePanels.confirm(
            title: "Forget the test environment for \(repo)?",
            message: "The next run infers services and tools again.",
            confirmLabel: "Forget"
        ) else { return }
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deleteTestEnvironment(repo: repo))
                await store.refetch(API.listTestEnvironments())
                statusMessage = "Forgot test environment for \(repo)."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
