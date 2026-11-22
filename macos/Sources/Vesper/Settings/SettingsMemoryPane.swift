import SwiftUI
import UniformTypeIdentifiers
import VesperCore

private enum MemoryScopeFilter: Hashable {
    case all
    case person
    case persona(String)
}

struct SettingsMemoryPane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var scope: MemoryScopeFilter = .all
    @State private var searchText = ""
    @State private var typeFilter = ""
    @State private var includeRetired = false
    @State private var showingEditor = false
    @State private var editingMemory: API.Memory?
    @State private var showingImport = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var store: QueryStore? { aux.store }

    private var currentRequest: APIRequest<API.MemoryList> {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let about: API.MemoryAbout?
        let personaId: String?
        switch scope {
        case .all:
            about = .all
            personaId = nil
        case .person:
            about = .person
            personaId = nil
        case .persona(let id):
            about = .persona
            personaId = id
        }
        return API.listMemories(
            q: q.isEmpty ? nil : q,
            type: typeFilter.isEmpty ? nil : typeFilter,
            includeRetired: includeRetired ? true : nil,
            about: about,
            personaId: personaId
        )
    }

    var body: some View {
        let personas = store?.entry(API.listPersonas()).data?.personas ?? []
        let entry = store?.entry(currentRequest)

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Memory",
                subtitle: "What Vesper remembers about you across chats, plus each persona's own memories."
            ) {
                HStack(spacing: 8) {
                    Menu("Export") {
                        Button("Export JSON…") { exportJSON() }
                        Button("Export Markdown…") { exportMarkdown() }
                    }
                    Button("Import…") { showingImport = true }
                    Button("Add Memory") {
                        editingMemory = nil
                        showingEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            SettingsCard {
                HStack(spacing: 10) {
                    Picker("Scope", selection: $scope) {
                        Text("All memories").tag(MemoryScopeFilter.all)
                        Text("About you").tag(MemoryScopeFilter.person)
                        ForEach(personas, id: \.id) { persona in
                            Text("\(persona.name)'s memory").tag(MemoryScopeFilter.persona(persona.id))
                        }
                    }
                    .frame(width: 200)

                    Picker("Type", selection: $typeFilter) {
                        Text("All types").tag("")
                        ForEach(MemoryUIHelpers.personaMemoryTypes, id: \.self) { t in
                            Text(MemoryUIHelpers.typeLabel(t)).tag(t)
                        }
                    }
                    .frame(width: 140)

                    TextField("Search memories…", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Retired", isOn: $includeRetired)
                        .toggleStyle(.checkbox)
                }
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Memory action failed", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }

            if let list = entry?.data {
                if list.memories.isEmpty {
                    SettingsCard {
                        Text("No memories match these filters.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ScrollViewReader { proxy in
                        LazyVStack(spacing: 10) {
                            ForEach(list.memories, id: \.id) { memory in
                                memoryRow(memory, personas: personas)
                                    .id(memory.id)
                            }
                        }
                        .onChange(of: navigation.memoryFocusId) { _, focusId in
                            if let focusId {
                                withAnimation { proxy.scrollTo(focusId, anchor: .center) }
                            }
                        }
                        .onAppear {
                            if let focusId = navigation.memoryFocusId {
                                proxy.scrollTo(focusId, anchor: .center)
                            }
                        }
                    }
                }

                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Danger zone").font(.subheadline.weight(.medium))
                            Text("Permanently remove every entry in the selected scope.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget Everything…") { forgetAll(listTotal: list.total) }
                            .foregroundStyle(.red)
                            .disabled(busy || list.memories.isEmpty)
                    }
                }
            } else if entry?.isFetching == true {
                SettingsCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading memories…").foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingsUnavailableCard(title: "Couldn't load memories", error: entry?.error) {
                    Task { await store?.refetch(currentRequest) }
                }
            }
        }
        .task {
            store?.load(API.listPersonas())
            store?.load(currentRequest)
        }
        .onChange(of: scope) { _, _ in store?.load(currentRequest) }
        .onChange(of: searchText) { _, _ in store?.load(currentRequest) }
        .onChange(of: typeFilter) { _, _ in store?.load(currentRequest) }
        .onChange(of: includeRetired) { _, _ in store?.load(currentRequest) }
        .sheet(isPresented: $showingEditor) {
            MemoryEditorSheet(
                existing: editingMemory,
                personas: personas,
                defaultPersonaId: { if case .persona(let id) = scope { return id }; return nil }()
            ) {
                showingEditor = false
                editingMemory = nil
                Task { await store?.refetch(currentRequest) }
            } onSave: { title, summary, body, type, tags, personaId in
                try await saveMemory(
                    existing: editingMemory,
                    title: title,
                    summary: summary,
                    body: body,
                    type: type,
                    tags: tags,
                    personaId: personaId
                )
            }
        }
        .sheet(isPresented: $showingImport) {
            MemoryImportSheet {
                showingImport = false
                Task { await store?.refetch(currentRequest) }
            } onImport: { entries in
                try await performImport(entries: entries)
            }
        }
    }

    private func memoryRow(_ m: API.Memory, personas: [API.Persona]) -> some View {
        let focused = navigation.memoryFocusId == m.id
        let personaName = m.personaId.flatMap { pid in personas.first(where: { $0.id == pid })?.name }
        return SettingsCard {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(m.title).font(.headline)
                        SettingsBadge(label: MemoryUIHelpers.typeLabel(m.type), tone: .neutral)
                        if let personaName {
                            SettingsBadge(label: personaName, tone: .human)
                        }
                        if let spaceName = m.spaceName, !spaceName.isEmpty {
                            SettingsBadge(label: "Space: \(spaceName)", tone: .neutral)
                        }
                        if m.supersededBy != nil {
                            SettingsBadge(label: "Retired", tone: .blocked)
                        }
                    }
                    if !m.summary.isEmpty {
                        Text(m.summary).font(.callout)
                    }
                    if !m.body.isEmpty && m.body != m.summary {
                        Text(m.body).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    HStack(spacing: 8) {
                        if !m.tags.isEmpty {
                            Text(m.tags.map { "#\($0)" }.joined(separator: " "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text("Updated \(SettingsDateFormatter.relative(m.updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    if m.supersededBy != nil {
                        Button("Restore") { restoreMemory(m) }
                    }
                    Button("Edit") {
                        editingMemory = m
                        showingEditor = true
                    }
                    Button("Delete") { deleteMemory(m) }
                        .foregroundStyle(.red)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : Color.clear, lineWidth: focused ? 2 : 0)
        )
    }

    private func saveMemory(
        existing: API.Memory?,
        title: String,
        summary: String,
        body: String,
        type: String,
        tags: [String],
        personaId: String?
    ) async throws {
        guard let store else { throw APIError.unreachable }
        if let existing {
            _ = try await store.mutate(API.updateMemory(
                id: existing.id,
                body: API.MemoryPatch(body: body, summary: summary, tags: tags, title: title, type: type)
            ))
            statusMessage = "Memory updated."
        } else {
            _ = try await store.mutate(API.createMemory(body: API.MemoryCreate(
                body: body,
                personaId: personaId,
                summary: summary,
                tags: tags,
                title: title,
                type: type
            )))
            statusMessage = "Memory saved."
        }
    }

    private func restoreMemory(_ m: API.Memory) {
        guard let store else { return }
        errorMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.updateMemory(id: m.id, body: API.MemoryPatch(restore: true)))
                await store.refetch(currentRequest)
                statusMessage = "Memory restored."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func deleteMemory(_ m: API.Memory) {
        guard SettingsFilePanels.confirm(
            title: "Delete “\(m.title)”?",
            message: "Personas will no longer recall this memory.",
            confirmLabel: "Delete"
        ) else { return }
        guard let store else { return }
        errorMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deleteMemory(id: m.id))
                await store.refetch(currentRequest)
                statusMessage = "Deleted “\(m.title)”."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func forgetAll(listTotal: Int) {
        guard SettingsFilePanels.confirm(
            title: "Forget all memories in this scope?",
            message: "This deletes \(listTotal) memories and cannot be undone.",
            confirmLabel: "Forget All"
        ) else { return }
        guard let store else { return }
        let about: API.MemoryAbout?
        let personaId: String?
        switch scope {
        case .all: about = .all; personaId = nil
        case .person: about = .person; personaId = nil
        case .persona(let id): about = .persona; personaId = id
        }
        errorMessage = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deleteAllMemories(confirm: true, about: about, personaId: personaId))
                await store.refetch(currentRequest)
                statusMessage = "Cleared memories."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func performImport(entries: [API.MemoryImportEntry]) async throws -> API.MemoryImportResult {
        guard let store else { throw APIError.unreachable }
        let res = try await store.mutate(API.importMemories(body: API.MemoryImport(memories: entries)))
        statusMessage = "Imported \(res.created) new, updated \(res.updated)\(res.failed.isEmpty ? "" : ", \(res.failed.count) failed")."
        return res
    }

    private func exportJSON() {
        guard let client = aux.client() else { return }
        Task {
            do {
                let exp = try await client.send(API.exportMemories())
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(exp)
                if let url = try SettingsFilePanels.saveData(data, defaultName: "vesper-memories.json", contentType: .json, title: "Export Memories JSON") {
                    statusMessage = "Exported \(url.lastPathComponent)."
                }
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func exportMarkdown() {
        guard let client = aux.client() else { return }
        Task {
            do {
                let exp = try await client.send(API.exportMemories())
                let md = MemoryUIHelpers.exportMarkdown(memories: exp.memories, exportedAt: exp.exportedAt)
                if let url = try SettingsFilePanels.saveText(md, defaultName: "vesper-memories.md", contentType: .plainText, title: "Export Memories Markdown") {
                    statusMessage = "Exported \(url.lastPathComponent)."
                }
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}

private struct MemoryEditorSheet: View {
    let existing: API.Memory?
    let personas: [API.Persona]
    let defaultPersonaId: String?
    let onDismiss: () -> Void
    let onSave: (String, String, String, String, [String], String?) async throws -> Void

    @State private var title = ""
    @State private var summary = ""
    @State private var bodyText = ""
    @State private var type = "preference"
    @State private var tagsText = ""
    @State private var selectedPersonaId: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add Memory" : "Edit Memory")
                .font(.title3.weight(.semibold))

            Form {
                if existing == nil {
                    Picker("Owner", selection: $selectedPersonaId) {
                        Text("About you (Person)").tag("")
                        ForEach(personas, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                }
                TextField("Title", text: $title)
                TextField("Summary (one line)", text: $summary)
                Picker("Type", selection: $type) {
                    let choices = selectedPersonaId.isEmpty ? MemoryUIHelpers.memoryTypes : MemoryUIHelpers.personaMemoryTypes
                    ForEach(choices, id: \.self) { t in
                        Text(MemoryUIHelpers.typeLabel(t)).tag(t)
                    }
                }
                TextField("Tags (comma separated)", text: $tagsText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Body (optional)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $bodyText)
                        .font(.body)
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 470)
        .onAppear {
            if let existing {
                title = existing.title
                summary = existing.summary
                bodyText = existing.body
                type = existing.type
                tagsText = existing.tags.joined(separator: ", ")
                selectedPersonaId = existing.personaId ?? ""
            } else {
                selectedPersonaId = defaultPersonaId ?? ""
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = MemoryUIHelpers.parseTags(tagsText)
        let pid = selectedPersonaId.isEmpty ? nil : selectedPersonaId
        Task {
            defer { saving = false }
            do {
                try await onSave(cleanTitle, cleanSummary, cleanBody, type, tags, pid)
                onDismiss()
            } catch {
                self.error = settingsErrorText(error)
            }
        }
    }
}

private struct MemoryImportSheet: View {
    let onDone: () -> Void
    let onImport: ([API.MemoryImportEntry]) async throws -> API.MemoryImportResult

    @State private var rawInput = ""
    @State private var copiedPrompt = false
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        let parsed = MemoryUIHelpers.parseImport(rawInput)
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Memory")
                .font(.title3.weight(.semibold))
            Text("Copy the export prompt into another assistant, then paste its JSON reply below.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button(copiedPrompt ? "Copied Prompt" : "Copy Export Prompt") {
                    SettingsFilePanels.copyToPasteboard(MemoryUIHelpers.importPrompt)
                    copiedPrompt = true
                }
                Spacer()
                if !rawInput.isEmpty {
                    Text("\(parsed.entries.count) ready · \(parsed.skipped) skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $rawInput)
                .font(.caption.monospaced())
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))

            if let parseErr = parsed.error {
                Text(parseErr).font(.callout).foregroundStyle(.red)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button(importing ? "Importing…" : "Import \(parsed.entries.count)") {
                    importing = true
                    error = nil
                    Task {
                        defer { importing = false }
                        do {
                            _ = try await onImport(parsed.entries)
                            onDone()
                        } catch {
                            self.error = settingsErrorText(error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importing || parsed.entries.isEmpty || parsed.error != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}
