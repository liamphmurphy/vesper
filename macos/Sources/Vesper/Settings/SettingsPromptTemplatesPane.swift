import SwiftUI
import VesperCore

struct SettingsPromptTemplatesPane: View {
    let aux: AuxWindows

    @State private var searchText = ""
    @State private var showingEditor = false
    @State private var editingTemplate: API.PromptTemplate?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var busyId: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let templatesEntry = store?.entry(API.listPromptTemplates())
        let personas = store?.entry(API.listPersonas()).data?.personas ?? []
        let spaces = store?.entry(API.listChatSpaces()).data?.spaces ?? []
        let allTemplates = templatesEntry?.data?.templates ?? []
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? allTemplates : allTemplates.filter {
            $0.slug.lowercased().contains(q)
                || $0.title.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.body.lowercased().contains(q)
        }

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Prompt Templates",
                subtitle: "Reusable `/` and `#` chat commands with `{{input}}` and `{{clipboard}}` variables, scoped globally or per persona/space."
            ) {
                Button("New Template") {
                    editingTemplate = nil
                    showingEditor = true
                }
                .buttonStyle(.borderedProminent)
            }

            SettingsCard {
                HStack(spacing: 10) {
                    TextField("Search templates by /slug, title, or body…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Text("\(filtered.count) \(filtered.count == 1 ? "template" : "templates")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Template error", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }

            if templatesEntry?.hasData == true {
                if filtered.isEmpty {
                    SettingsCard("No prompt templates yet") {
                        Text("Create a template to trigger reusable prompts with `/slug` or `#slug` in any chat, or save any message directly from a chat transcript.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Create First Template") {
                            editingTemplate = nil
                            showingEditor = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered, id: \.id) { tpl in
                            templateRow(tpl, personas: personas, spaces: spaces)
                        }
                    }
                }
            } else if templatesEntry?.isFetching == true {
                SettingsCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading prompt templates…").foregroundStyle(.secondary)
                    }
                }
            } else {
                SettingsUnavailableCard(title: "Couldn't load prompt templates", error: templatesEntry?.error) {
                    Task { await store?.refetch(API.listPromptTemplates()) }
                }
            }
        }
        .task {
            store?.load(API.listPromptTemplates())
            store?.load(API.listPersonas())
            store?.load(API.listChatSpaces())
        }
        .sheet(isPresented: $showingEditor) {
            PromptTemplateEditorSheet(
                existing: editingTemplate,
                personas: personas,
                spaces: spaces
            ) {
                showingEditor = false
                editingTemplate = nil
                Task { await store?.refetch(API.listPromptTemplates()) }
            } onSave: { slug, title, description, body, personaId, spaceId in
                try await saveTemplate(
                    existing: editingTemplate,
                    slug: slug,
                    title: title,
                    description: description,
                    body: body,
                    personaId: personaId,
                    spaceId: spaceId
                )
            }
        }
    }

    private func templateRow(_ tpl: API.PromptTemplate, personas: [API.Persona], spaces: [API.ChatSpace]) -> some View {
        let scope = ChatPromptTemplateLogic.scopeLabel(template: tpl, personas: personas, spaces: spaces)
        return SettingsCard {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("/\(tpl.slug)")
                            .font(.headline.monospaced())
                        Text(tpl.title)
                            .font(.headline)
                        SettingsBadge(label: scope, tone: tpl.personaId?.value == nil && tpl.spaceId?.value == nil ? .neutral : .human)
                    }
                    if !tpl.description.isEmpty {
                        Text(tpl.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(tpl.body)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                HStack(spacing: 6) {
                    Button("Edit") {
                        editingTemplate = tpl
                        showingEditor = true
                    }
                    Button("Delete") {
                        deleteTemplate(tpl)
                    }
                    .foregroundStyle(.red)
                    .disabled(busyId == tpl.id)
                }
            }
        }
    }

    private func saveTemplate(
        existing: API.PromptTemplate?,
        slug: String,
        title: String,
        description: String,
        body: String,
        personaId: String?,
        spaceId: String?
    ) async throws {
        guard let store else { return }
        errorMessage = nil
        if let existing {
            _ = try await store.mutate(
                API.updatePromptTemplate(
                    id: existing.id,
                    body: API.PromptTemplatePatch(
                        body: body,
                        description: description,
                        personaId: personaId.map { .value($0) } ?? .null,
                        slug: slug,
                        spaceId: spaceId.map { .value($0) } ?? .null,
                        title: title
                    )
                ),
                invalidating: QueryInvalidation(resources: ["prompt-templates"])
            )
            statusMessage = "Updated /\(slug)"
        } else {
            _ = try await store.mutate(
                API.createPromptTemplate(
                    body: API.NewPromptTemplate(
                        body: body,
                        description: description.isEmpty ? nil : description,
                        personaId: personaId.map { .value($0) },
                        slug: slug,
                        spaceId: spaceId.map { .value($0) },
                        title: title
                    )
                ),
                invalidating: QueryInvalidation(resources: ["prompt-templates"])
            )
            statusMessage = "Created /\(slug)"
        }
    }

    private func deleteTemplate(_ tpl: API.PromptTemplate) {
        guard let store, busyId == nil else { return }
        busyId = tpl.id
        errorMessage = nil
        Task {
            defer { busyId = nil }
            do {
                _ = try await store.mutate(
                    API.deletePromptTemplate(id: tpl.id),
                    invalidating: QueryInvalidation(resources: ["prompt-templates"])
                )
                statusMessage = "Deleted /\(tpl.slug)"
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private struct PromptTemplateEditorSheet: View {
    let existing: API.PromptTemplate?
    let personas: [API.Persona]
    let spaces: [API.ChatSpace]
    let onDismiss: () -> Void
    let onSave: (String, String, String, String, String?, String?) async throws -> Void

    @State private var slug: String
    @State private var title: String
    @State private var description: String
    @State private var bodyText: String
    @State private var personaId: String
    @State private var spaceId: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(
        existing: API.PromptTemplate?,
        personas: [API.Persona],
        spaces: [API.ChatSpace],
        onDismiss: @escaping () -> Void,
        onSave: @escaping (String, String, String, String, String?, String?) async throws -> Void
    ) {
        self.existing = existing
        self.personas = personas
        self.spaces = spaces
        self.onDismiss = onDismiss
        self.onSave = onSave
        _slug = State(initialValue: existing?.slug ?? "")
        _title = State(initialValue: existing?.title ?? "")
        _description = State(initialValue: existing?.description ?? "")
        _bodyText = State(initialValue: existing?.body ?? "")
        _personaId = State(initialValue: existing?.personaId?.value ?? "")
        _spaceId = State(initialValue: existing?.spaceId?.value ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Prompt Template" : "Edit Prompt Template")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Command").font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("/").font(.callout.monospaced()).foregroundStyle(.secondary)
                        TextField("e.g. pr-review", text: $slug)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                }
                GridRow {
                    Text("Title").font(.callout).foregroundStyle(.secondary)
                    TextField("Short label shown in menu", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Hint").font(.callout).foregroundStyle(.secondary)
                    TextField("Optional one-line description", text: $description)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Persona").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: $personaId) {
                        Text("All personas (Personal)").tag("")
                        ForEach(personas, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Space").font(.callout).foregroundStyle(.secondary)
                    Picker("", selection: $spaceId) {
                        Text("All spaces").tag("")
                        ForEach(spaces, id: \.id) { s in
                            Text(s.name).tag(s.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Prompt body")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("+ {{input}}") {
                        bodyText += bodyText.isEmpty || bodyText.hasSuffix(" ") || bodyText.hasSuffix("\n") ? "{{input}}" : " {{input}}"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button("+ {{clipboard}}") {
                        bodyText += bodyText.isEmpty || bodyText.hasSuffix(" ") || bodyText.hasSuffix("\n") ? "{{clipboard}}" : " {{clipboard}}"
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                TextEditor(text: $bodyText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .disabled(saving)
                Button(saving ? "Saving…" : "Save") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || ChatPromptTemplateLogic.normalizeSlug(slug).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func submit() {
        let normSlug = ChatPromptTemplateLogic.normalizeSlug(slug)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normSlug.isEmpty, !cleanTitle.isEmpty, !cleanBody.isEmpty else { return }
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                try await onSave(
                    normSlug,
                    cleanTitle,
                    cleanDesc,
                    cleanBody,
                    personaId.isEmpty ? nil : personaId,
                    spaceId.isEmpty ? nil : spaceId
                )
                onDismiss()
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
