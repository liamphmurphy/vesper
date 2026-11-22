import SwiftUI
import VesperCore

struct HttpAuthEnvView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let bundle: HttpWorkspaceBundle
    let initialFolderId: String?
    let secrets: [API.ApiSecret]
    let onBack: () -> Void

    // Workspace defaults
    @State private var wsName = ""
    @State private var wsDescription = ""
    @State private var wsAuth = HttpAuthConfig.none
    @State private var wsHeaders: [HttpKeyValue] = []
    @State private var wsVars: [HttpEnvVar] = []
    @State private var savingWorkspace = false

    // Folder overrides
    @State private var editingFolderId: String?
    @State private var folderAuth = HttpAuthConfig.inherit
    @State private var folderHeaders: [HttpKeyValue] = []
    @State private var savingFolder = false

    // Environments
    @State private var editingEnvId: String?
    @State private var envName = ""
    @State private var envColor: HttpEnvColor = .green
    @State private var envVars: [HttpEnvVar] = []
    @State private var addingEnv = false
    @State private var newEnvName = ""
    @State private var savingEnv = false
    @State private var creatingEnv = false
    @State private var confirmDeleteEnv: HttpEnvironment?

    private var activeEditingFolder: HttpFolder? {
        bundle.folders.first(where: { $0.id == editingFolderId }) ?? bundle.folders.first
    }

    private var activeEditingEnv: HttpEnvironment? {
        bundle.environments.first(where: { $0.id == editingEnvId })
            ?? bundle.environments.first(where: { $0.id == bundle.workspace.activeEnvironmentId })
            ?? bundle.environments.first
    }

    private var workspaceSyncKey: String {
        "\(bundle.workspace.id)|\(bundle.workspace.updatedAt)"
    }

    private var folderSyncKey: String {
        guard let f = activeEditingFolder else { return "none" }
        return "\(f.id)|\(f.updatedAt)"
    }

    private var envSyncKey: String {
        guard let e = activeEditingEnv else { return "none" }
        return "\(e.id)|\(e.updatedAt)"
    }

    var body: some View {
        GeometryReader { proxy in
            let twoColumn = proxy.size.width >= 880
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if twoColumn {
                        HStack(alignment: .top, spacing: 20) {
                            leftColumn
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            environmentsCard
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            leftColumn
                            environmentsCard
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: workspaceSyncKey, initial: true) { _, _ in
            syncWorkspaceState()
        }
        .onChange(of: initialFolderId, initial: true) { _, next in
            if let next, bundle.folders.contains(where: { $0.id == next }) {
                editingFolderId = next
            } else if editingFolderId == nil {
                editingFolderId = bundle.folders.first?.id
            }
        }
        .onChange(of: folderSyncKey, initial: true) { _, _ in
            syncFolderState()
        }
        .onChange(of: envSyncKey, initial: true) { _, _ in
            syncEnvState()
        }
        .confirmationDialog(
            "Delete environment \"\(confirmDeleteEnv?.name ?? "")\"?",
            isPresented: Binding(
                get: { confirmDeleteEnv != nil },
                set: { if !$0 { confirmDeleteEnv = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = confirmDeleteEnv {
                Button("Delete", role: .destructive) {
                    Task { await deleteEnvironment(target) }
                }
            }
            Button("Cancel", role: .cancel) { confirmDeleteEnv = nil }
        } message: {
            Text("All variables configured in this environment will be removed.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(bundle.workspace.name) \u{2014} Auth Inheritance & Environments")
                    .vesperText(.heading, theme)
                    .foregroundStyle(theme.palette.text)
                Text("Inheritance chain: Workspace \u{2192} Folder \u{2192} Request. Any level can inherit or override.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }
            Spacer(minLength: 12)
            Button("\u{2190} Back to Requests", action: onBack)
                .buttonStyle(.vesper())
        }
    }

    // MARK: - Left Column (Workspace + Folder Defaults)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            workspaceDefaultsCard
            if !bundle.folders.isEmpty {
                folderOverrideCard
            }
        }
    }

    private var workspaceDefaultsCard: some View {
        HttpCard(title: "Workspace Default Auth & Headers") {
            Button {
                Task { await saveWorkspaceDefaults() }
            } label: {
                if savingWorkspace {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save Defaults")
                }
            }
            .buttonStyle(.vesper(.primary))
            .disabled(savingWorkspace || wsName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                HttpField(label: "Workspace name") {
                    TextField("Workspace name", text: $wsName)
                        .httpInputBox(theme)
                }

                AuthEditorView(
                    value: $wsAuth,
                    allowInherit: false,
                    secrets: secrets
                )

                HttpField(label: "Inherited headers") {
                    KVEditorView(
                        items: $wsHeaders,
                        keyPlaceholder: "X-Client-Id",
                        valuePlaceholder: "{{client_id}}",
                        emptyLabel: "No workspace-wide headers."
                    )
                }

                HttpField(
                    label: "Shared workspace variables (base defaults)",
                    hint: "Active environment variables override matching keys."
                ) {
                    EnvVarEditorView(
                        items: $wsVars,
                        secrets: secrets,
                        emptyLabel: "No shared workspace variables. Active environment variables override these."
                    )
                }
            }
        }
    }

    private var folderOverrideCard: some View {
        let folder = activeEditingFolder
        return HttpCard(title: "Folder Override") {
            Button {
                if let folder {
                    Task { await saveFolderDefaults(folder) }
                }
            } label: {
                if savingFolder {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save Folder")
                }
            }
            .buttonStyle(.vesper())
            .disabled(savingFolder || folder == nil)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HttpField(label: "Folder") {
                    Picker(
                        "Folder",
                        selection: Binding(
                            get: { activeEditingFolder?.id ?? "" },
                            set: { next in editingFolderId = next }
                        )
                    ) {
                        ForEach(bundle.folders) { f in
                            Text(f.name).tag(f.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let folder {
                    let parentSummary = HttpClientLogic.resolveInheritedAuth(
                        bundle: bundle,
                        folderId: folder.parentFolderId
                    )
                    AuthEditorView(
                        value: $folderAuth,
                        allowInherit: true,
                        inheritedSummary: "Inheriting from \(parentSummary.label)",
                        secrets: secrets
                    )

                    HttpField(label: "Folder headers") {
                        KVEditorView(
                            items: $folderHeaders,
                            keyPlaceholder: "Header-Name",
                            valuePlaceholder: "value",
                            emptyLabel: "No folder-level header overrides."
                        )
                    }
                }
            }
        }
    }

    // MARK: - Right Column (Environments)

    private var environmentsCard: some View {
        HttpCard(title: "Environments & Variables") {
            HStack(spacing: 8) {
                if let env = activeEditingEnv {
                    Button("Delete") {
                        confirmDeleteEnv = env
                    }
                    .buttonStyle(.vesper(.danger))

                    Button {
                        Task { await saveEnvironment(env) }
                    } label: {
                        if savingEnv {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save Env")
                        }
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(savingEnv || envName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                envSelectorStrip

                if addingEnv {
                    HStack(spacing: 8) {
                        TextField("staging", text: $newEnvName)
                            .httpInputBox(theme)
                            .onSubmit {
                                Task { await createEnvironment() }
                            }
                        Button {
                            Task { await createEnvironment() }
                        } label: {
                            if creatingEnv {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Add")
                            }
                        }
                        .buttonStyle(.vesper(.primary))
                        .disabled(creatingEnv || newEnvName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Cancel") {
                            addingEnv = false
                            newEnvName = ""
                        }
                        .buttonStyle(.vesper())
                    }
                    .padding(10)
                    .background(HttpStyle.sidebarBackground(theme), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                }

                if let env = activeEditingEnv {
                    let isActive = env.id == bundle.workspace.activeEnvironmentId
                    VStack(alignment: .leading, spacing: 14) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .bottom, spacing: 12) {
                                envNameField
                                envColorField
                                envActiveButton(env: env, isActive: isActive)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                envNameField
                                envColorField
                                envActiveButton(env: env, isActive: isActive)
                            }
                        }

                        HttpField(label: "Variables & Vesper Secrets") {
                            EnvVarEditorView(items: $envVars, secrets: secrets)
                        }
                    }
                } else {
                    Text("Create an environment (like nonprod or prod) to manage environment variables.")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
        }
    }

    private var envSelectorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(bundle.environments) { env in
                    let selected = env.id == activeEditingEnv?.id
                    let isActive = env.id == bundle.workspace.activeEnvironmentId
                    Button {
                        selectEnv(env)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(HttpStyle.envColor(env.color, theme: theme))
                                .frame(width: 8, height: 8)
                            Text(env.name)
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                            if isActive {
                                Text("(active)")
                                    .font(.system(size: theme.pointSize(.micro)))
                                    .foregroundStyle(theme.palette.tertiaryText)
                            }
                        }
                        .foregroundStyle(selected ? theme.palette.text : theme.palette.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            selected ? theme.palette.selected : theme.palette.surface,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? theme.palette.accent : theme.palette.border)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    addingEnv.toggle()
                } label: {
                    Label("New Env", systemImage: "plus")
                }
                .buttonStyle(.vesper())
            }
        }
    }

    private var envNameField: some View {
        HttpField(label: "Environment name") {
            TextField("Environment name", text: $envName)
                .httpInputBox(theme)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var envColorField: some View {
        HttpField(label: "Badge color") {
            Picker("Environment color", selection: $envColor) {
                ForEach(HttpEnvColor.allCases) { color in
                    Text(color.label).tag(color)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private func envActiveButton(env: HttpEnvironment, isActive: Bool) -> some View {
        Button {
            Task { await setActiveEnvironment(isActive ? nil : env.id) }
        } label: {
            Text(isActive ? "Active Environment" : "Set Active")
        }
        .buttonStyle(.vesper(isActive ? .primary : .outline))
    }

    // MARK: - Sync Helpers

    private func syncWorkspaceState() {
        let ws = bundle.workspace
        wsName = ws.name
        wsDescription = ws.description
        wsAuth = ws.defaultAuth
        wsHeaders = ws.defaultHeaders
        wsVars = ws.defaultVars
    }

    private func syncFolderState() {
        if let folder = activeEditingFolder {
            if editingFolderId != folder.id {
                editingFolderId = folder.id
            }
            folderAuth = folder.defaultAuth
            folderHeaders = folder.defaultHeaders
        } else {
            folderAuth = .inherit
            folderHeaders = []
        }
    }

    private func syncEnvState() {
        if let env = activeEditingEnv {
            if editingEnvId != env.id {
                editingEnvId = env.id
            }
            envName = env.name
            envColor = env.color
            envVars = env.variables
        } else {
            envName = ""
            envColor = .green
            envVars = []
        }
    }

    private func selectEnv(_ env: HttpEnvironment) {
        editingEnvId = env.id
        envName = env.name
        envColor = env.color
        envVars = env.variables
    }

    // MARK: - Mutations

    private func saveWorkspaceDefaults() async {
        let trimmed = wsName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast(id: "http.ws.save", title: "Workspace name is required", tone: .error)
            return
        }
        savingWorkspace = true
        defer { savingWorkspace = false }

        let ws = bundle.workspace
        let input = HttpWorkspaceInput(
            name: trimmed,
            description: wsDescription,
            activeEnvironmentId: ws.activeEnvironmentId,
            defaultAuth: wsAuth,
            defaultHeaders: wsHeaders,
            defaultVars: wsVars
        )
        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: ws.id)
        let listReq = HttpClientAPI.listWorkspaces()
        do {
            let updated = try await context.store.mutate(
                HttpClientAPI.updateWorkspace(id: ws.id, body: input),
                optimistic: [
                    .update(bundleReq) { $0.workspace = HttpWorkspace(
                        id: ws.id,
                        name: trimmed,
                        description: wsDescription,
                        activeEnvironmentId: ws.activeEnvironmentId,
                        defaultAuth: wsAuth,
                        defaultHeaders: wsHeaders,
                        defaultVars: wsVars,
                        createdAt: ws.createdAt,
                        updatedAt: ws.updatedAt
                    ) },
                    .update(listReq) { list in
                        for i in list.workspaces.indices where list.workspaces[i].id == ws.id {
                            list.workspaces[i].name = trimmed
                            list.workspaces[i].defaultAuth = wsAuth
                            list.workspaces[i].defaultHeaders = wsHeaders
                            list.workspaces[i].defaultVars = wsVars
                        }
                    },
                ],
                invalidating: HttpClientAPI.workspacesInvalidation
            )
            context.store.invalidate(HttpClientAPI.bundleInvalidation(workspaceId: updated.id))
            showToast(id: "http.ws.save", title: "Workspace defaults saved", tone: .success)
        } catch {
            showToast(
                id: "http.ws.save",
                title: "Failed to save workspace defaults",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func saveFolderDefaults(_ folder: HttpFolder) async {
        savingFolder = true
        defer { savingFolder = false }

        let input = HttpFolderInput(
            parentFolderId: folder.parentFolderId,
            name: folder.name,
            defaultAuth: folderAuth,
            defaultHeaders: folderHeaders,
            sortOrder: folder.sortOrder
        )
        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: bundle.workspace.id)
        do {
            _ = try await context.store.mutate(
                HttpClientAPI.updateFolder(id: folder.id, body: input),
                optimistic: [
                    .update(bundleReq) { b in
                        for i in b.folders.indices where b.folders[i].id == folder.id {
                            b.folders[i].defaultAuth = folderAuth
                            b.folders[i].defaultHeaders = folderHeaders
                        }
                    },
                ],
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: bundle.workspace.id)
            )
            showToast(id: "http.folder.save", title: "Folder \"\(folder.name)\" defaults saved", tone: .success)
        } catch {
            showToast(
                id: "http.folder.save",
                title: "Failed to save folder defaults",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func saveEnvironment(_ env: HttpEnvironment) async {
        let trimmed = envName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast(id: "http.env.save", title: "Environment name is required", tone: .error)
            return
        }
        savingEnv = true
        defer { savingEnv = false }

        let input = HttpEnvironmentInput(
            name: trimmed,
            color: envColor,
            variables: envVars,
            sortOrder: env.sortOrder
        )
        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: bundle.workspace.id)
        do {
            _ = try await context.store.mutate(
                HttpClientAPI.updateEnvironment(id: env.id, body: input),
                optimistic: [
                    .update(bundleReq) { b in
                        for i in b.environments.indices where b.environments[i].id == env.id {
                            b.environments[i].name = trimmed
                            b.environments[i].color = envColor
                            b.environments[i].variables = envVars
                        }
                    },
                ],
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: bundle.workspace.id)
            )
            showToast(id: "http.env.save", title: "Environment \"\(trimmed)\" saved", tone: .success)
        } catch {
            showToast(
                id: "http.env.save",
                title: "Failed to save environment",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func createEnvironment() async {
        let trimmed = newEnvName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creatingEnv = true
        defer { creatingEnv = false }

        let color = HttpClientLogic.defaultEnvColor(forName: trimmed)
        let input = HttpEnvironmentInput(
            name: trimmed,
            color: color,
            variables: [HttpEnvVar(key: "base_url", value: "https://api.example.com", enabled: true)],
            sortOrder: bundle.environments.count
        )
        do {
            let created = try await context.store.mutate(
                HttpClientAPI.createEnvironment(workspaceId: bundle.workspace.id, body: input),
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: bundle.workspace.id)
            )
            addingEnv = false
            newEnvName = ""
            selectEnv(created)
            await setActiveEnvironment(created.id)
            showToast(id: "http.env.create", title: "Environment \"\(created.name)\" created", tone: .success)
        } catch {
            showToast(
                id: "http.env.create",
                title: "Failed to create environment",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func deleteEnvironment(_ env: HttpEnvironment) async {
        confirmDeleteEnv = nil
        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: bundle.workspace.id)
        do {
            _ = try await context.store.mutate(
                HttpClientAPI.deleteEnvironment(id: env.id),
                optimistic: [
                    .update(bundleReq) { b in
                        b.environments.removeAll { $0.id == env.id }
                        if b.workspace.activeEnvironmentId == env.id {
                            b.workspace.activeEnvironmentId = nil
                        }
                    },
                ],
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: bundle.workspace.id)
            )
            let next = bundle.environments.first { $0.id != env.id }
            if let next {
                selectEnv(next)
            } else {
                editingEnvId = nil
            }
            showToast(id: "http.env.delete", title: "Environment deleted", tone: .success)
        } catch {
            showToast(
                id: "http.env.delete",
                title: "Failed to delete environment",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func setActiveEnvironment(_ environmentId: String?) async {
        let wsId = bundle.workspace.id
        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: wsId)
        let listReq = HttpClientAPI.listWorkspaces()
        do {
            _ = try await context.store.mutate(
                HttpClientAPI.setActiveEnvironment(workspaceId: wsId, environmentId: environmentId),
                optimistic: [
                    .update(bundleReq) { $0.workspace.activeEnvironmentId = environmentId },
                    .update(listReq) { list in
                        for i in list.workspaces.indices where list.workspaces[i].id == wsId {
                            list.workspaces[i].activeEnvironmentId = environmentId
                        }
                    },
                ],
                invalidating: HttpClientAPI.workspacesInvalidation
            )
            context.store.invalidate(HttpClientAPI.bundleInvalidation(workspaceId: wsId))
        } catch {
            showToast(
                id: "http.env.active",
                title: "Failed to switch environment",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func showToast(id: String, title: String, description: String? = nil, tone: ToastTone) {
        context.showToast(ToastItemModel(id: id, title: title, description: description, tone: tone))
    }
}
