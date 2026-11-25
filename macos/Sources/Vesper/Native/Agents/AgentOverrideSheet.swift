import SwiftUI
import VesperCore

/// Modal sheet for editing one space's override on a persona's work definition.
/// Permissions only allow modes stricter than the agent definition (matching server `agentdef.Resolve`).
struct AgentOverrideSheet: View {
    let detail: API.AgentDetail
    let project: API.Project
    let onSaved: (API.AgentDetail) -> Void

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var harnessChoice: String
    @State private var model: String
    @State private var maxRuntime: String
    @State private var maxTurns: String
    @State private var instructionsAppend: String
    @State private var scopes: [String: String]
    @State private var newDenyScope = ""
    @State private var mcpServers: [API.McpServer]
    @State private var newServerName = ""
    @State private var newServerURL = ""
    @State private var skillsRemoveText: String
    @State private var skillsAdd: [API.AgentSkill]
    @State private var newSkillName = ""
    @State private var newSkillDescription = ""
    @State private var newSkillBody = ""
    @State private var setupText: String
    @State private var servicesText: String
    @State private var saving = false
    @State private var errorMessage: String?

    private static let scopeNameRegex = /^[a-z][a-z0-9-]*:([a-z0-9][a-z0-9-]*|\*)$/
    private static let skillNameRegex = /^[a-z0-9][a-z0-9-]{0,63}$/

    init(detail: API.AgentDetail, project: API.Project, onSaved: @escaping (API.AgentDetail) -> Void) {
        self.detail = detail
        self.project = project
        self.onSaved = onSaved

        let existing = detail.overrides.first(where: { $0.project.key == project.key })?.override
        _harnessChoice = State(initialValue: existing?.harness?.rawValue ?? "inherit")
        _model = State(initialValue: existing?.model ?? "")
        _maxRuntime = State(initialValue: existing?.budget?.maxRuntime ?? "")
        _maxTurns = State(initialValue: existing?.budget?.maxTurns.map(String.init) ?? "")
        _instructionsAppend = State(initialValue: existing?.instructionsAppend ?? "")

        var initialScopes: [String: String] = [:]
        for key in detail.spec.scopes.keys {
            initialScopes[key] = existing?.scopes?[key]?.rawValue ?? "inherit"
        }
        for (key, mode) in existing?.scopes ?? [:] {
            initialScopes[key] = mode.rawValue
        }
        _scopes = State(initialValue: initialScopes)

        _mcpServers = State(initialValue: existing?.mcpServersAdd ?? [])
        _skillsRemoveText = State(initialValue: (existing?.skillsRemove ?? []).joined(separator: "\n"))
        _skillsAdd = State(initialValue: existing?.skillsAdd ?? [])
        _setupText = State(initialValue: (existing?.setup ?? []).joined(separator: "\n"))

        if let services = existing?.services, !services.isEmpty,
           let data = try? JSONEncoder().encode(services),
           let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            _servicesText = State(initialValue: text)
        } else {
            _servicesText = State(initialValue: "")
        }
    }

    private var hasExistingOverride: Bool {
        detail.overrides.contains { $0.project.key == project.key }
    }

    private var parsedRemovals: [String] {
        skillsRemoveText
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .filter { !$0.isEmpty }
    }

    private var removalsValid: Bool {
        let list = parsedRemovals
        return list.allSatisfy { $0.wholeMatch(of: Self.skillNameRegex) != nil }
            && Set(list).count == list.count
    }

    private var parsedServices: Result<[API.AgentService], Error> {
        let trimmed = servicesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success([]) }
        guard let data = trimmed.data(using: .utf8) else {
            return .failure(NSError(domain: "AgentOverride", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8"]))
        }
        do {
            return .success(try JSONDecoder().decode([API.AgentService].self, from: data))
        } catch {
            return .failure(NSError(domain: "AgentOverride", code: 2, userInfo: [NSLocalizedDescriptionKey: "Test services must be a valid JSON array of service objects with name and image."]))
        }
    }

    private var servicesError: String? {
        if case .failure(let err) = parsedServices { return err.localizedDescription }
        return nil
    }

    private var canAddSkill: Bool {
        let name = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = newSkillBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.wholeMatch(of: Self.skillNameRegex) != nil
            && !desc.isEmpty
            && !body.isEmpty
            && body.utf8.count <= 65_536
            && !skillsAdd.contains { $0.name == name }
            && skillsAdd.count < 30
    }

    private var skillDraftPending: Bool {
        !newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !newSkillBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: project.color) ?? p.accent)
                    .frame(width: 10, height: 10)
                Text("\(detail.agent.name) in \(project.name)")
                    .vesperText(.heading, theme)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Overrides merge over the work definition for runs in this space. Permissions can only get stricter.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.secondaryText)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Harness").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        Picker("Harness", selection: $harnessChoice) {
                            Text("Definition\u{2019}s (\(detail.spec.harness.rawValue))").tag("inherit")
                            ForEach(detail.harnesses, id: \.name.rawValue) { h in
                                Text(h.label).tag(h.name.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack(spacing: 12) {
                        labeledField("Model", placeholder: detail.spec.model, text: $model)
                        labeledField("Max runtime", placeholder: detail.spec.budget.maxRuntime ?? "none", text: $maxRuntime)
                        labeledField("Max turns", placeholder: detail.spec.budget.maxTurns.map(String.init) ?? "none", text: $maxTurns)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Append to instructions").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        TextEditor(text: $instructionsAppend)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 72)
                            .padding(6)
                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }

                    // Permissions tightening
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permissions").font(.system(size: 13, weight: .semibold))
                        ForEach(scopes.keys.sorted(), id: \.self) { scopeKey in
                            let agentMode = detail.spec.scopes[scopeKey]
                            HStack(spacing: 10) {
                                Text(scopeKey)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 150, alignment: .leading)
                                Picker(scopeKey, selection: Binding(
                                    get: { scopes[scopeKey] ?? "inherit" },
                                    set: { scopes[scopeKey] = $0 }
                                )) {
                                    Text("Inherit (\(AgentDetailLogic.scopeModeLabel(agentMode)))").tag("inherit")
                                    if agentMode == .allowed {
                                        Text("Approval").tag(API.ScopeMode.requiresApproval.rawValue)
                                    }
                                    if agentMode != .denied {
                                        Text("Denied").tag(API.ScopeMode.denied.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("Deny a scope, e.g. prod:*", text: $newDenyScope)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: 240)
                            Button("Deny") {
                                let w = newDenyScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                if w.wholeMatch(of: Self.scopeNameRegex) != nil {
                                    scopes[w] = API.ScopeMode.denied.rawValue
                                    newDenyScope = ""
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(newDenyScope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().wholeMatch(of: Self.scopeNameRegex) == nil)
                        }
                    }

                    // Extra MCP servers
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Extra MCP servers").font(.system(size: 13, weight: .semibold))
                        ForEach(Array(mcpServers.enumerated()), id: \.offset) { idx, srv in
                            HStack(spacing: 8) {
                                Text(srv.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(srv.url).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.secondaryText).lineLimit(1)
                                Spacer()
                                Button {
                                    mcpServers.remove(at: idx)
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
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
                                mcpServers.append(API.McpServer(name: n, url: u))
                                newServerName = ""
                                newServerURL = ""
                            }
                            .buttonStyle(.bordered)
                            .disabled(newServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    // Space skills
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Space skills").font(.system(size: 13, weight: .semibold))
                        Text("Removals apply first, then additions. Leave empty to keep all agent defaults.")
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                        labeledField("Remove agent skills (names separated by space, comma, or newline)", placeholder: "skill-name", text: $skillsRemoveText)
                        if !removalsValid {
                            Text("Use unique lowercase skill names (letters, digits, hyphens, up to 64 chars).")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                        ForEach(Array(skillsAdd.enumerated()), id: \.offset) { idx, sk in
                            HStack(spacing: 8) {
                                Text(sk.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(sk.description).font(.system(size: 12)).foregroundStyle(p.secondaryText).lineLimit(1)
                                Spacer()
                                Button {
                                    skillsAdd.remove(at: idx)
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("skill-name", text: $newSkillName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 150)
                                TextField("When to use this skill", text: $newSkillDescription)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            }
                            TextEditor(text: $newSkillBody)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 64)
                                .padding(6)
                                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                            HStack(spacing: 8) {
                                Button("Add space skill") {
                                    skillsAdd.append(API.AgentSkill(
                                        body: newSkillBody.trimmingCharacters(in: .whitespacesAndNewlines),
                                        description: newSkillDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                                        name: newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    ))
                                    newSkillName = ""
                                    newSkillDescription = ""
                                    newSkillBody = ""
                                }
                                .buttonStyle(.bordered)
                                .disabled(!canAddSkill)
                                if skillDraftPending {
                                    Button("Clear draft") {
                                        newSkillName = ""
                                        newSkillDescription = ""
                                        newSkillBody = ""
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.secondaryText)
                                }
                            }
                        }
                    }

                    // Setup commands & Test services
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Setup commands (one per line)").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        TextEditor(text: $setupText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 54)
                            .padding(6)
                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Test services (JSON array)").font(.system(size: 12, weight: .medium)).foregroundStyle(p.secondaryText)
                        TextEditor(text: $servicesText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 72)
                            .padding(6)
                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                        if let err = servicesError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                    }
                }
                .padding(18)
            }

            Divider()

            HStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .lineLimit(2)
                }
                if hasExistingOverride {
                    Button("Remove override", role: .destructive) {
                        submit(API.AgentOverride())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    .disabled(saving)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button(saving ? "Saving\u{2026}" : "Save override") {
                    submit(buildOverride())
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || !removalsValid || servicesError != nil || skillDraftPending)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 680, height: 640)
        .background(p.background)
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.palette.secondaryText)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func buildOverride() -> API.AgentOverride {
        var sc: [String: API.ScopeMode] = [:]
        for (k, v) in scopes where v != "inherit" {
            sc[k] = API.ScopeMode(rawValue: v)
        }
        let setupLines = setupText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let services: [API.AgentService]? = {
            if case .success(let list) = parsedServices, !list.isEmpty { return list }
            return nil
        }()
        let rt = maxRuntime.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnsInt = Int(maxTurns.trimmingCharacters(in: .whitespacesAndNewlines))
        let budget: API.Budget? = (!rt.isEmpty || turnsInt != nil)
            ? API.Budget(maxRuntime: rt.isEmpty ? nil : rt, maxTurns: turnsInt)
            : nil

        return API.AgentOverride(
            budget: budget,
            harness: harnessChoice == "inherit" ? nil : API.Harness(rawValue: harnessChoice),
            instructionsAppend: instructionsAppend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : instructionsAppend.trimmingCharacters(in: .whitespacesAndNewlines),
            mcpServersAdd: mcpServers.isEmpty ? nil : mcpServers,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: sc.isEmpty ? nil : sc,
            services: services,
            setup: setupLines.isEmpty ? nil : setupLines,
            skillsAdd: skillsAdd.isEmpty ? nil : skillsAdd,
            skillsRemove: parsedRemovals.isEmpty ? nil : parsedRemovals
        )
    }

    private func submit(_ body: API.AgentOverride) {
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                let updated = try await context.store.mutate(
                    API.setAgentOverride(handle: detail.agent.handle, project: project.key, body: body),
                    invalidating: QueryInvalidation(resources: ["agents"])
                )
                onSaved(updated)
                dismiss()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
