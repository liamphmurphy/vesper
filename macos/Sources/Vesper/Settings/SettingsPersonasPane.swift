import SwiftUI
import VesperCore

private enum PersonaDetailTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case model = "Model"
    case work = "Work"
    case connectors = "Connectors"
    case memory = "Memory"
    var id: String { rawValue }
}

struct SettingsPersonasPane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var detailTab: PersonaDetailTab = .profile
    @State private var showingNewSheet = false
    @State private var newName = ""
    @State private var newInstructions = ""
    @State private var newTone: API.PersonaTone = .neutral
    @State private var creating = false
    @State private var errorMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let entry = store?.entry(API.listPersonas())
        let all = PersonaUIHelpers.sortPersonas(entry?.data?.personas ?? [])
        let filtered = all.filter { p in
            switch navigation.personaFilter {
            case .all: return true
            case .chat: return p.work == .none
            case .tickets: return p.work == .tickets
            }
        }
        let selected = filtered.first(where: { $0.id == navigation.personaId })
            ?? all.first(where: { $0.id == navigation.personaId })
            ?? filtered.first

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personas").font(.title2.weight(.semibold))
                    Text("Custom assistants, models, tools, and ticket-running agents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Filter", selection: $navigation.personaFilter) {
                    Text("All").tag(SettingsPersonaFilter.all)
                    Text("Chat").tag(SettingsPersonaFilter.chat)
                    Text("Takes tickets").tag(SettingsPersonaFilter.tickets)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Button("New Persona") {
                    newName = ""
                    newInstructions = ""
                    newTone = .neutral
                    showingNewSheet = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(all.count >= PersonaUIHelpers.maxPersonas)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Persona action failed", message: errorMessage)
                    .padding(16)
            }

            if entry?.hasData == true {
                HSplitView {
                    List(filtered, id: \.id, selection: Binding(
                        get: { selected?.id },
                        set: { navigation.personaId = $0 }
                    )) { persona in
                        HStack(spacing: 10) {
                            SettingsAvatarView(
                                avatarURL: persona.avatarUrl,
                                initials: PersonaUIHelpers.initial(for: persona.name),
                                colorHex: persona.color,
                                size: 30
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(persona.name).font(.callout.weight(.medium))
                                    if persona.isDefault {
                                        SettingsBadge(label: "Default", tone: .done)
                                    }
                                }
                                HStack(spacing: 6) {
                                    if let handle = persona.handle, !handle.isEmpty {
                                        Text("@\(handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Text(persona.work == .tickets ? "Takes tickets" : "Chat")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .tag(persona.id)
                        .padding(.vertical, 2)
                    }
                    .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)

                    Group {
                        if let persona = selected {
                            PersonaDetailView(
                                aux: aux,
                                navigation: navigation,
                                persona: persona,
                                allCount: all.count,
                                detailTab: $detailTab,
                                onDeleted: {
                                    navigation.personaId = nil
                                    Task { await store?.refetch(API.listPersonas()) }
                                }
                            )
                        } else {
                            VStack(spacing: 8) {
                                Text("No personas match this filter.")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else if entry?.isFetching == true {
                VStack {
                    ProgressView("Loading personas…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsUnavailableCard(title: "Couldn't load personas", error: entry?.error) {
                    Task { await store?.refetch(API.listPersonas()) }
                }
                .padding(24)
            }
        }
        .task {
            store?.load(API.listPersonas())
            store?.load(API.listChatModels())
            store?.load(API.listConnectors())
        }
        .sheet(isPresented: $showingNewSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New Persona").font(.title3.weight(.semibold))
                Form {
                    TextField("Name", text: $newName)
                    Picker("Tone", selection: $newTone) {
                        ForEach(PersonaUIHelpers.tones) { t in
                            Text(t.label).tag(t.value)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom instructions").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $newInstructions)
                            .frame(height: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Cancel") { showingNewSheet = false }
                    Button(creating ? "Creating…" : "Create") {
                        createPersona(existing: all)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(creating || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 460, height: 340)
        }
    }

    private func createPersona(existing: [API.Persona]) {
        guard let store else { return }
        creating = true
        errorMessage = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = PersonaUIHelpers.unusedPreset(in: existing)
        let body = API.NewPersona(
            color: color,
            customInstructions: newInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
            name: String(trimmed.prefix(PersonaUIHelpers.nameMax)),
            tone: newTone
        )
        Task {
            defer { creating = false }
            do {
                let created = try await store.mutate(API.createPersona(body: body))
                await store.refetch(API.listPersonas())
                navigation.personaId = created.id
                showingNewSheet = false
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}

private struct PersonaDetailView: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation
    let persona: API.Persona
    let allCount: Int
    @Binding var detailTab: PersonaDetailTab
    let onDeleted: () -> Void

    @State private var name = ""
    @State private var tone: API.PersonaTone = .neutral
    @State private var colorHex = ""
    @State private var instructions = ""
    @State private var inChatList = true

    @State private var harness: String = ""
    @State private var model: String = ""
    @State private var effort: String = ""

    @State private var work: API.PersonaWork = .none
    @State private var capCode = false
    @State private var capImages = false
    @State private var capImageEngine = ""
    @State private var capSvg = false
    @State private var capPersonas = false
    @State private var capConnectors = false
    @State private var capWorkflows = false
    @State private var capTicketEdits: API.PersonaCapabilities.TicketEdits = .ask
    @State private var repos: [String] = []
    @State private var newRepo = ""

    @State private var loadedRevision: Int?
    @State private var loadedId: String?
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    SettingsAvatarView(
                        avatarURL: persona.avatarUrl,
                        initials: PersonaUIHelpers.initial(for: persona.name),
                        colorHex: persona.color,
                        size: 48
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(persona.name).font(.title3.weight(.semibold))
                            if persona.isDefault {
                                SettingsBadge(label: "Default", tone: .done)
                            }
                        }
                        HStack(spacing: 8) {
                            if let handle = persona.handle {
                                Text("@\(handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text("\(persona.chatCount) chats").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Start Chat") { startChat() }
                        .disabled(busy)
                    if !persona.isDefault {
                        Button("Set Default") { setDefault() }
                            .disabled(busy)
                    }
                    Button("Delete") { deletePersona() }
                        .foregroundStyle(.red)
                        .disabled(busy)
                }

                Picker("Section", selection: $detailTab) {
                    ForEach(PersonaDetailTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                if let errorMessage {
                    SettingsBanner(tone: .blocked, title: "Couldn't save persona", message: errorMessage) {
                        if errorMessage.contains("changed") {
                            Button("Reload") { Task { await store?.refetch(API.listPersonas()) } }
                        }
                    }
                }
                if let statusMessage {
                    SettingsBanner(tone: .done, title: statusMessage)
                }

                switch detailTab {
                case .profile: profileTab
                case .model: modelTab
                case .work: workTab
                case .connectors: connectorsTab
                case .memory: memoryTab
                }
            }
            .padding(20)
        }
        .onAppear { sync(from: persona) }
        .onChange(of: persona) { _, next in
            if loadedId != next.id || loadedRevision != next.revision {
                sync(from: next)
            }
        }
    }

    @ViewBuilder private var profileTab: some View {
        SettingsCard("Avatar & Identity") {
            HStack(spacing: 12) {
                Button("Upload Photo…") { uploadAvatar() }.disabled(busy)
                if persona.avatarUrl != nil {
                    Button("Remove Photo") { removeAvatar() }.disabled(busy)
                }
                Text(PersonaUIHelpers.avatarHint).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            TextField("Name (up to \(PersonaUIHelpers.nameMax) chars)", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Tone", selection: $tone) {
                ForEach(PersonaUIHelpers.tones) { t in
                    Text(t.label).tag(t.value)
                }
            }
            if let toneInfo = PersonaUIHelpers.tones.first(where: { $0.value == tone }) {
                Text(toneInfo.hint).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    ForEach(PersonaUIHelpers.presetColors, id: \.self) { preset in
                        Button {
                            colorHex = preset
                        } label: {
                            Circle()
                                .fill(Color(cssHex: preset) ?? .gray)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white, lineWidth: colorHex.lowercased() == preset ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(cssHex: colorHex) ?? .accentColor },
                        set: { if let h = hexString(from: $0) { colorHex = h } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    TextField("#rrggbb", text: $colorHex)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .frame(width: 96)
                }
                if let warning = PersonaUIHelpers.contrastWarning(hex: colorHex) {
                    Text("Low contrast (\(warning.ratio)). Suggested: \(warning.suggestion)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Toggle("Offer in chat switcher and @ menu", isOn: $inChatList)
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom instructions").font(.subheadline.weight(.medium))
                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(height: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
            HStack {
                Spacer()
                Button(busy ? "Saving…" : "Save Profile") {
                    patchPersona(API.PersonaPatch(
                        color: PersonaUIHelpers.parseHex(colorHex) ?? persona.color,
                        customInstructions: String(instructions.prefix(PersonaUIHelpers.instructionsMax)),
                        inChatList: inChatList,
                        name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PersonaUIHelpers.nameMax)),
                        revision: persona.revision,
                        tone: tone
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        SettingsPersonaStatesCard(aux: aux, persona: persona)
            .id(persona.id)
    }

    @ViewBuilder private var modelTab: some View {
        let harnessGroups = store?.entry(API.listChatModels()).data ?? []
        let activeGroup = harnessGroups.first(where: { $0.harness.rawValue == harness })
        let models = activeGroup?.models ?? []
        let activeModel = models.first(where: { $0.id == model })

        SettingsCard("Model & Reasoning", subtitle: "Default harness, model, and effort for new chats with this persona.") {
            Picker("Default harness", selection: $harness) {
                Text("Auto").tag("")
                ForEach(harnessGroups, id: \.harness.rawValue) { g in
                    Text(g.available ? g.label : "\(g.label) (\(g.unavailableReason ?? "unavailable"))")
                        .tag(g.harness.rawValue)
                }
            }
            .onChange(of: harness) { _, _ in
                model = ""
                effort = ""
            }

            if !harness.isEmpty {
                Picker("Default model", selection: $model) {
                    Text("Auto / harness default").tag("")
                    ForEach(models, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                if let efforts = activeModel?.efforts, !efforts.isEmpty {
                    Picker("Default effort", selection: $effort) {
                        Text("Automatic").tag("")
                        ForEach(efforts, id: \.rawValue) { e in
                            Text(e.rawValue.capitalized).tag(e.rawValue)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(busy ? "Saving…" : "Save Model Settings") {
                    let hPatch: API.PersonaPatch.DefaultHarness = harness.isEmpty ? .empty : API.PersonaPatch.DefaultHarness(rawValue: harness)
                    let mPatch: String = (harness.isEmpty || model.isEmpty) ? "auto" : model
                    let ePatch: API.PersonaPatch.DefaultEffort = (harness.isEmpty || effort.isEmpty) ? .default : API.PersonaPatch.DefaultEffort(rawValue: effort)
                    patchPersona(API.PersonaPatch(
                        defaultEffort: ePatch,
                        defaultHarness: hPatch,
                        defaultModel: mPatch,
                        revision: persona.revision
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
    }

    @ViewBuilder private var workTab: some View {
        SettingsCard("Work & Permissions") {
            Picker("Role", selection: $work) {
                Text("Chat only").tag(API.PersonaWork.none)
                Text("Takes tickets").tag(API.PersonaWork.tickets)
            }
            .pickerStyle(.segmented)

            if let handle = persona.handle, work == .tickets {
                HStack {
                    Text("Work definition, branch prompt, and run permissions live in the agent editor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open @\(handle)") {
                        aux.openInMainWindow("/agents/\(handle)")
                    }
                }
            }

            Divider()
            Text("Capabilities").font(.subheadline.weight(.medium))
            Toggle("Code in repositories (clone, edit, commit branches)", isOn: $capCode)
            Toggle("Generate images", isOn: $capImages)
            if capImages {
                Picker("Image engine", selection: $capImageEngine) {
                    Text("Inherit workspace setting").tag("")
                    Text("Auto").tag("auto")
                    Text("Codex").tag("codex")
                    Text("Antigravity").tag("antigravity")
                }
            }
            Toggle("Render SVG images in chat replies", isOn: $capSvg)
            Toggle("Propose new personas from chats", isOn: $capPersonas)
            Toggle("Propose new connectors from chats", isOn: $capConnectors)
            Toggle("Propose & edit workflows from chats", isOn: $capWorkflows)
            Picker("Ticket edits from chats", selection: $capTicketEdits) {
                Text("Ask before applying").tag(API.PersonaCapabilities.TicketEdits.ask)
                Text("Apply immediately").tag(API.PersonaCapabilities.TicketEdits.allow)
            }

            Divider()
            Text("Repository favorites").font(.subheadline.weight(.medium))
            ForEach(repos, id: \.self) { url in
                HStack {
                    Text(url).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Button("Remove") { repos.removeAll { $0 == url } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                TextField("https://github.com/owner/repo or git@host:owner/repo", text: $newRepo)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button("Add") {
                    switch PersonaUIHelpers.addRepo(to: repos, input: newRepo) {
                    case .success(let updated):
                        repos = updated
                        newRepo = ""
                        errorMessage = nil
                    case .failure(let err):
                        errorMessage = err.message
                    }
                }
            }

            HStack {
                Spacer()
                Button(busy ? "Saving…" : "Save Work & Abilities") {
                    let caps = API.PersonaCapabilities(
                        code: capCode,
                        connectors: capConnectors,
                        imageEngine: capImageEngine,
                        images: capImages,
                        personas: capPersonas,
                        svg: capSvg,
                        ticketEdits: capTicketEdits,
                        workflows: capWorkflows
                    )
                    patchPersona(API.PersonaPatch(
                        capabilities: caps,
                        repos: repos,
                        revision: persona.revision,
                        work: work
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
    }

    @ViewBuilder private var connectorsTab: some View {
        let connectors = store?.entry(API.listConnectors()).data?.connectors ?? []
        SettingsCard("MCP Connectors", subtitle: "Select which workspace connectors \(persona.name) can call.") {
            if connectors.isEmpty {
                Text("No connectors configured yet. Add them in Integrations → Connectors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(connectors, id: \.id) { c in
                    let enabled = c.personaIds.contains(persona.id)
                    HStack {
                        Toggle(isOn: Binding(
                            get: { enabled },
                            set: { on in toggleConnector(c, enabled: on) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.callout.weight(.medium))
                                Text("\(c.tools.count) tools · \(c.url)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder private var memoryTab: some View {
        let req = API.listMemories(about: .persona, personaId: persona.id)
        let entry = store?.entry(req)
        SettingsCard("\(persona.name)'s Memory", subtitle: "Memories private to \(persona.name).") {
            HStack {
                Button("Manage in Memory…") {
                    navigation.selection = .memory
                }
                Spacer()
            }
            if let memories = entry?.data?.memories {
                if memories.isEmpty {
                    Text("No entries yet.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(memories, id: \.id) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.callout.weight(.medium))
                            if !m.summary.isEmpty {
                                Text(m.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
        }
        .task(id: persona.id) {
            store?.load(req)
        }
    }

    private func sync(from p: API.Persona) {
        loadedId = p.id
        loadedRevision = p.revision
        name = p.name
        tone = p.tone
        colorHex = p.color
        instructions = p.customInstructions
        inChatList = p.inChatList
        harness = p.defaultHarness?.rawValue ?? ""
        model = p.defaultModel ?? ""
        effort = p.defaultEffort?.rawValue ?? ""
        work = p.work
        capCode = p.capabilities.code
        capImages = p.capabilities.images
        capImageEngine = p.capabilities.imageEngine ?? ""
        capSvg = p.capabilities.svg ?? false
        capPersonas = p.capabilities.personas ?? false
        capConnectors = p.capabilities.connectors ?? false
        capWorkflows = p.capabilities.workflows ?? false
        capTicketEdits = p.capabilities.ticketEdits ?? .ask
        repos = p.repos
    }

    private func patchPersona(_ patch: API.PersonaPatch) {
        guard let store else { return }
        errorMessage = nil
        statusMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let updated = try await store.mutate(API.updatePersona(id: persona.id, body: patch))
                await store.refetch(API.listPersonas())
                sync(from: updated)
                statusMessage = "Saved."
            } catch {
                errorMessage = settingsErrorText(error)
                if case .http(let status, _) = error as? APIError, status == 409 {
                    await store.refetch(API.listPersonas())
                }
            }
        }
    }

    private func setDefault() {
        guard let store else { return }
        errorMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.setDefaultPersona(id: persona.id))
                await store.refetch(API.listPersonas())
                statusMessage = "\(persona.name) is now your default persona."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func startChat() {
        guard let client = aux.client() else { return }
        errorMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let chat = try await client.send(API.createChat(body: API.NewChat(personaId: persona.id)))
                aux.openInMainWindow("/chat/\(chat.id)")
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func deletePersona() {
        guard SettingsFilePanels.confirm(
            title: "Delete \(persona.name)?",
            message: PersonaUIHelpers.deleteConsequence(chatCount: persona.chatCount),
            confirmLabel: "Delete"
        ) else { return }
        guard let store else { return }
        errorMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deletePersona(id: persona.id, revision: persona.revision))
                onDeleted()
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func uploadAvatar() {
        guard let client = aux.client(), let store else { return }
        guard let picked = SettingsFilePanels.openImageForAvatar() else { return }
        if let err = PersonaUIHelpers.validateAvatarData(picked.data, fileName: picked.fileName, contentType: picked.mimeType) {
            errorMessage = err
            return
        }
        busy = true
        errorMessage = nil
        var form = APIMultipartForm()
        form.addFile("file", filename: picked.fileName, contentType: picked.mimeType.isEmpty ? "application/octet-stream" : picked.mimeType, data: picked.data)
        Task {
            defer { busy = false }
            do {
                _ = try await client.send(API.uploadPersonaAvatar(id: persona.id, body: form))
                await store.refetch(API.listPersonas())
                statusMessage = "Photo updated."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func removeAvatar() {
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deletePersonaAvatar(id: persona.id))
                await store.refetch(API.listPersonas())
                statusMessage = "Photo removed."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func toggleConnector(_ connector: API.Connector, enabled: Bool) {
        guard let store else { return }
        var ids = connector.personaIds
        if enabled {
            if !ids.contains(persona.id) { ids.append(persona.id) }
        } else {
            ids.removeAll { $0 == persona.id }
        }
        Task {
            do {
                _ = try await store.mutate(API.updateConnector(
                    id: connector.id,
                    body: API.ConnectorPatch(personaIds: ids, revision: connector.revision)
                ))
                await store.refetch(API.listConnectors())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
