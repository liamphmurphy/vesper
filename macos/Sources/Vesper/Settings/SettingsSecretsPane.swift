import SwiftUI
import VesperCore

struct SettingsSecretsPane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var editingSecretName: String?
    @State private var secretValueInput = ""
    @State private var customSecretName = ""
    @State private var showingCustomSecretSheet = false
    @State private var activeSignIn: API.SignIn?
    @State private var signInCodeInput = ""
    @State private var pollTask: Task<Void, Never>?

    @State private var showingNewApiSecret = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        SettingsScrollContainer {
            SettingsPaneHeader(
                "Credentials & API Secrets",
                subtitle: "Encrypted provider keys for AI harnesses and scoped HTTP secrets for external APIs."
            ) {
                Picker("Section", selection: $navigation.secretsTab) {
                    Text("Provider Credentials").tag(SettingsSecretsTab.provider)
                    Text("API Secrets").tag(SettingsSecretsTab.api)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Secret action failed", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }

            switch navigation.secretsTab {
            case .provider:
                providerCredentialsSection
            case .api:
                apiSecretsSection
            }
        }
        .task {
            store?.load(API.listSecrets())
            store?.load(API.listApiSecrets())
            store?.load(API.listPersonas())
        }
        .onDisappear { pollTask?.cancel() }
        .sheet(isPresented: Binding(get: { editingSecretName != nil }, set: { if !$0 { editingSecretName = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save \(editingSecretName ?? "secret")").font(.title3.weight(.semibold))
                Text("Write-only: values are encrypted at rest and never read back to clients.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SecureField("Secret value", text: $secretValueInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { editingSecretName = nil; secretValueInput = "" }
                    Button("Save") {
                        if let name = editingSecretName {
                            saveProviderSecret(name: name, value: secretValueInput)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || secretValueInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .sheet(isPresented: $showingCustomSecretSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add Provider Secret").font(.title3.weight(.semibold))
                TextField("Secret name (e.g. git:deploy)", text: $customSecretName)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret value", text: $secretValueInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { showingCustomSecretSheet = false }
                    Button("Save") {
                        let cleanName = customSecretName.trimmingCharacters(in: .whitespacesAndNewlines)
                        saveProviderSecret(name: cleanName, value: secretValueInput)
                        showingCustomSecretSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || customSecretName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretValueInput.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .sheet(isPresented: $showingNewApiSecret) {
            NewAPISecretSheet(
                aux: aux,
                personas: store?.entry(API.listPersonas()).data?.personas ?? []
            ) {
                showingNewApiSecret = false
                Task { await store?.refetch(API.listApiSecrets()) }
            }
        }
    }

    // MARK: Provider Credentials

    @ViewBuilder private var providerCredentialsSection: some View {
        let entry = store?.entry(API.listSecrets())
        if let list = entry?.data {
            if !list.keyConfigured {
                SettingsBanner(
                    tone: .blocked,
                    title: "SECRETS_KEY is not configured",
                    message: "Secrets cannot be encrypted or stored until SECRETS_KEY is set on the server."
                )
            }

            if let signIn = activeSignIn {
                signInCard(signIn)
            }

            SettingsCard("Harness & Git Credentials", subtitle: "Credentials used when Vesper starts runs on microVMs or opens pull requests.") {
                ForEach(ProviderSecretsHelpers.connections) { conn in
                    let state = ProviderSecretsHelpers.connectionState(list.secrets, name: conn.name)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: conn.symbolName)
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(conn.label).font(.headline)
                                    Text(conn.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    switch state {
                                    case .set:
                                        SettingsBadge(label: "Set", tone: .done)
                                    case .projects(let names):
                                        SettingsBadge(label: "Spaces: \(names.joined(separator: ", "))", tone: .human)
                                    case .unset:
                                        SettingsBadge(label: conn.required ? "Missing" : "Optional", tone: conn.required ? .human : .neutral)
                                    }
                                }
                                Text("Unlocks: \(conn.unlocks.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                                if case .unset = state {
                                    Text(conn.without).font(.caption).foregroundStyle(.secondary)
                                }
                                if case .set(let meta) = state, let used = meta.lastUsedAt {
                                    Text("Last used \(SettingsDateFormatter.relative(used))").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                if let provider = conn.signIn, list.signInAvailable {
                                    Button("Sign in") { startSignIn(provider) }
                                        .disabled(busy)
                                }
                                Button(state == .unset ? "Paste Key…" : "Update…") {
                                    secretValueInput = ""
                                    editingSecretName = conn.name
                                }
                                .disabled(!list.keyConfigured || busy)
                                if case .set(let meta) = state {
                                    Button("Remove") { deleteProviderSecret(meta) }
                                        .foregroundStyle(.red)
                                        .disabled(busy)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }

            let others = ProviderSecretsHelpers.otherSecrets(list.secrets)
            SettingsCard("Other Secrets") {
                HStack {
                    Text("Space overrides or custom secrets pasted manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Secret…") {
                        customSecretName = ""
                        secretValueInput = ""
                        showingCustomSecretSheet = true
                    }
                    .disabled(!list.keyConfigured)
                }
                if others.isEmpty {
                    Text("No other secrets stored.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(others, id: \.id) { s in
                        HStack {
                            Text(s.name).font(.callout.monospaced())
                            if let p = s.project {
                                SettingsBadge(label: p.key, tone: .neutral)
                            }
                            Spacer()
                            Text("Updated \(SettingsDateFormatter.relative(s.updatedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Delete") { deleteProviderSecret(s) }
                                .foregroundStyle(.red)
                                .disabled(busy)
                        }
                        Divider()
                    }
                }
            }
        } else if entry?.isFetching == true {
            SettingsCard { ProgressView("Loading provider credentials…") }
        } else {
            SettingsUnavailableCard(title: "Couldn't load provider credentials", error: entry?.error) {
                Task { await store?.refetch(API.listSecrets()) }
            }
        }
    }

    private func signInCard(_ signIn: API.SignIn) -> some View {
        let viewState = ProviderSecretsHelpers.signInView(signIn)
        return SettingsCard("Signing in to \(signIn.provider.rawValue.capitalized)") {
            if let step = ProviderSecretsHelpers.signInSteps[signIn.provider] {
                Text(step).font(.callout).foregroundStyle(.secondary)
            }
            switch viewState {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting sign-in session…")
                }
            case .open(let urlStr, let code, let pasteBack):
                HStack(spacing: 10) {
                    if let url = URL(string: urlStr) {
                        Button("Open Sign-In Page") { aux.openExternal(url) }
                            .buttonStyle(.borderedProminent)
                    }
                    if !code.isEmpty {
                        Text(code).font(.headline.monospaced())
                        Button("Copy Code") { SettingsFilePanels.copyToPasteboard(code) }
                    }
                }
                if pasteBack {
                    HStack {
                        TextField("Paste authorization code or callback URL", text: $signInCodeInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Submit") { submitSignInCode(signIn.id) }
                            .disabled(signInCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying authorization…")
                }
            case .done:
                SettingsBanner(tone: .done, title: "Signed in to \(signIn.provider.rawValue)")
            case .failed(let message):
                SettingsBanner(tone: .blocked, title: "Sign-in failed", message: message)
            }
            HStack {
                Spacer()
                Button("Close / Cancel") {
                    pollTask?.cancel()
                    Task {
                        _ = try? await aux.client()?.send(API.cancelSignIn(id: signIn.id))
                        activeSignIn = nil
                    }
                }
            }
        }
    }

    // MARK: API Secrets

    @ViewBuilder private var apiSecretsSection: some View {
        let entry = store?.entry(API.listApiSecrets())
        let personas = store?.entry(API.listPersonas()).data?.personas ?? []

        if let list = entry?.data {
            if !list.keyConfigured {
                SettingsBanner(
                    tone: .blocked,
                    title: "SECRETS_KEY is not configured",
                    message: "API secrets require SECRETS_KEY on the server."
                )
            }
            HStack {
                Text("\(list.secrets.count) API secret\(list.secrets.count == 1 ? "" : "s") configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add API Secret…") { showingNewApiSecret = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!list.keyConfigured)
            }
            if list.secrets.isEmpty {
                SettingsCard {
                    Text("No API secrets configured yet. API secrets inject tokens into outbound HTTP requests to approved hosts without exposing the secret value to agents.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(list.secrets, id: \.id) { secret in
                    APISecretCard(
                        aux: aux,
                        secret: secret,
                        personas: personas,
                        isHighlighted: navigation.secretId == secret.id,
                        onUpdated: { Task { await store?.refetch(API.listApiSecrets()) } },
                        onStatus: { statusMessage = $0 },
                        onError: { errorMessage = $0 }
                    )
                }
            }
        } else if entry?.isFetching == true {
            SettingsCard { ProgressView("Loading API secrets…") }
        } else {
            SettingsUnavailableCard(title: "Couldn't load API secrets", error: entry?.error) {
                Task { await store?.refetch(API.listApiSecrets()) }
            }
        }
    }

    // MARK: Provider Actions

    private func saveProviderSecret(name: String, value: String) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.setSecret(body: API.SetSecretBody(name: name, value: value)))
                await store.refetch(API.listSecrets())
                editingSecretName = nil
                secretValueInput = ""
                statusMessage = ProviderSecretsHelpers.savedMessage(name: name)
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func deleteProviderSecret(_ secret: API.SecretInfo) {
        guard SettingsFilePanels.confirm(
            title: "Remove \(secret.name)?",
            message: "Agents will lose access to this credential immediately.",
            confirmLabel: "Remove"
        ) else { return }
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deleteSecret(id: secret.id))
                await store.refetch(API.listSecrets())
                statusMessage = "\(secret.name) removed."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func startSignIn(_ provider: API.SignInProvider) {
        guard let client = aux.client() else { return }
        pollTask?.cancel()
        signInCodeInput = ""
        errorMessage = nil
        Task {
            do {
                let s = try await client.send(API.startSignIn(body: API.StartSignInBody(provider: provider)))
                activeSignIn = s
                pollSignIn(id: s.id)
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func pollSignIn(id: String) {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let client = aux.client() else { return }
                if let next = try? await client.send(API.getSignIn(id: id)) {
                    activeSignIn = next
                    if next.status == .done {
                        await store?.refetch(API.listSecrets())
                        statusMessage = "Signed in."
                        return
                    }
                    if next.status == .failed || next.status == .cancelled {
                        return
                    }
                }
            }
        }
    }

    private func submitSignInCode(_ id: String) {
        guard let client = aux.client() else { return }
        let code = signInCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                activeSignIn = try await client.send(API.submitSignInCode(id: id, body: API.SubmitSignInCodeBody(code: code)))
                signInCodeInput = ""
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}

private struct APISecretCard: View {
    let aux: AuxWindows
    let secret: API.ApiSecret
    let personas: [API.Persona]
    let isHighlighted: Bool
    let onUpdated: () -> Void
    let onStatus: (String) -> Void
    let onError: (String) -> Void

    @State private var calls: [API.ApiSecretCall] = []
    @State private var showCalls = false
    @State private var loadingCalls = false

    private var store: QueryStore? { aux.store }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(secret.name).font(.headline)
                            Text(secret.handle).font(.caption.monospaced()).foregroundStyle(.secondary)
                            SettingsBadge(label: secret.kind.rawValue.uppercased(), tone: .neutral)
                            if let pill = APISecretsHelpers.expiryPill(secret.expiresAt) {
                                SettingsBadge(label: pill.label, tone: pill.tone)
                            }
                            if let oauth = APISecretsHelpers.oauthStatus(secret.oauth) {
                                SettingsBadge(label: oauth.label, tone: oauth.tone)
                            }
                        }
                        Text(APISecretsHelpers.sentAs(placement: secret.placement, key: secret.placementKey, handle: secret.handle))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text("Hosts: \(secret.allowedHosts.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        if secret.kind == .oauth, let oauth = APISecretsHelpers.oauthStatus(secret.oauth) {
                            Button(oauth.action) { signInOAuth() }
                        }
                        Button(showCalls ? "Hide Activity" : "Activity") {
                            showCalls.toggle()
                            if showCalls { loadCalls() }
                        }
                        Button("Delete") { deleteSecret() }
                            .foregroundStyle(.red)
                    }
                }

                Divider()

                HStack(spacing: 16) {
                    Picker("Read (\(APISecretsHelpers.readMethods))", selection: Binding(
                        get: { secret.readPolicy },
                        set: { patch(API.ApiSecretPatch(readPolicy: $0, revision: secret.revision)) }
                    )) {
                        ForEach(APISecretsHelpers.policies, id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }
                    .frame(width: 240)

                    Picker("Write (\(APISecretsHelpers.writeMethods))", selection: Binding(
                        get: { secret.writePolicy },
                        set: { patch(API.ApiSecretPatch(revision: secret.revision, writePolicy: $0)) }
                    )) {
                        ForEach(APISecretsHelpers.policies, id: \.value) { item in
                            Text(item.label).tag(item.value)
                        }
                    }
                    .frame(width: 260)
                }

                if !personas.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allowed personas").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 4) {
                            ForEach(personas, id: \.id) { p in
                                let has = secret.personaIds.contains(p.id)
                                Toggle(p.name, isOn: Binding(
                                    get: { has },
                                    set: { on in
                                        var next = secret.personaIds
                                        if on {
                                            if !next.contains(p.id) { next.append(p.id) }
                                        } else {
                                            next.removeAll { $0 == p.id }
                                        }
                                        patch(API.ApiSecretPatch(personaIds: next, revision: secret.revision))
                                    }
                                ))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }

                if showCalls {
                    Divider()
                    if loadingCalls {
                        ProgressView().controlSize(.small)
                    } else if calls.isEmpty {
                        Text("No outbound calls recorded for this secret yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(calls.prefix(12), id: \.id) { call in
                            HStack(spacing: 8) {
                                Text(call.method).font(.caption.monospaced().bold())
                                Text("\(call.host)\(call.path)").font(.caption.monospaced()).lineLimit(1)
                                Spacer()
                                Text(call.personaName).font(.caption).foregroundStyle(.secondary)
                                SettingsBadge(label: call.decision.rawValue, tone: call.decision == .blocked || call.decision == .denied ? .blocked : .done)
                                if let status = call.status {
                                    Text("\(status)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isHighlighted ? Color.accentColor : Color.clear, lineWidth: isHighlighted ? 2 : 0)
        )
    }

    private func patch(_ body: API.ApiSecretPatch) {
        guard let store else { return }
        Task {
            do {
                _ = try await store.mutate(API.updateApiSecret(id: secret.id, body: body))
                onUpdated()
            } catch {
                onError(settingsErrorText(error))
            }
        }
    }

    private func deleteSecret() {
        guard SettingsFilePanels.confirm(
            title: "Delete \(secret.name)?",
            message: "Personas using ‹\(secret.handle)› will no longer be able to call it.",
            confirmLabel: "Delete"
        ) else { return }
        guard let store else { return }
        Task {
            do {
                _ = try await store.mutate(API.deleteApiSecret(id: secret.id))
                onStatus("Deleted \(secret.name).")
                onUpdated()
            } catch {
                onError(settingsErrorText(error))
            }
        }
    }

    private func signInOAuth() {
        guard let client = aux.client() else { return }
        Task {
            do {
                let res = try await client.send(API.signInApiSecret(id: secret.id))
                if let url = URL(string: res.authorizeUrl) {
                    aux.openExternal(url)
                }
                onUpdated()
            } catch {
                onError(settingsErrorText(error))
            }
        }
    }

    private func loadCalls() {
        guard let client = aux.client() else { return }
        loadingCalls = true
        Task {
            defer { loadingCalls = false }
            if let list = try? await client.send(API.listApiSecretCalls(id: secret.id)) {
                calls = list.calls
            }
        }
    }
}

private struct NewAPISecretSheet: View {
    let aux: AuxWindows
    let personas: [API.Persona]
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var kind: API.ApiSecretKind = .static
    @State private var placement: API.ApiSecretPlacement = .bearer
    @State private var placementKey = ""
    @State private var valueText = ""
    @State private var hostsText = ""
    @State private var readPolicy: API.ApiSecretPolicy = .allow
    @State private var writePolicy: API.ApiSecretPolicy = .ask
    @State private var selectedPersonas: Set<String> = []

    @State private var oauthPreset = "google"
    @State private var authorizeUrl = APISecretsHelpers.oauthPresets[0].authorizeUrl
    @State private var tokenUrl = APISecretsHelpers.oauthPresets[0].tokenUrl
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var scopesText = ""

    @State private var saving = false
    @State private var error: String?

    var body: some View {
        let handle = APISecretsHelpers.handleFor(name: name)
        let expiry = kind == .static ? APISecretsHelpers.jwtExpiry(valueText) : nil

        VStack(alignment: .leading, spacing: 14) {
            Text("Add API Secret").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                if !handle.isEmpty {
                    Text("Handle: \(handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Picker("Kind", selection: $kind) {
                    Text("Token or key").tag(API.ApiSecretKind.static)
                    Text("OAuth sign-in").tag(API.ApiSecretKind.oauth)
                }
                .pickerStyle(.segmented)

                if kind == .static {
                    SecureField("Secret value", text: $valueText)
                    if let expiry {
                        Text(APISecretsHelpers.expiryText(expiry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("OAuth provider", selection: $oauthPreset) {
                        ForEach(APISecretsHelpers.oauthPresets) { p in
                            Text(p.label).tag(p.value)
                        }
                    }
                    .onChange(of: oauthPreset) { _, val in
                        if let p = APISecretsHelpers.oauthPresets.first(where: { $0.value == val }) {
                            authorizeUrl = p.authorizeUrl
                            tokenUrl = p.tokenUrl
                            if !p.hosts.isEmpty && hostsText.isEmpty {
                                hostsText = p.hosts.joined(separator: ", ")
                            }
                        }
                    }
                    TextField("Authorize URL", text: $authorizeUrl)
                    TextField("Token URL", text: $tokenUrl)
                    TextField("Client ID", text: $clientId)
                    SecureField("Client secret (optional)", text: $clientSecret)
                    TextField("Scopes", text: $scopesText)
                }

                Picker("Placement", selection: $placement) {
                    ForEach(APISecretsHelpers.placements, id: \.value) { p in
                        Text(p.label).tag(p.value)
                    }
                }
                if placement == .header || placement == .query {
                    TextField(placement == .header ? "Header name (e.g. X-Api-Key)" : "Query param name", text: $placementKey)
                }
                TextField("Allowed hosts (comma-separated domains or URLs)", text: $hostsText)

                Picker("Read (\(APISecretsHelpers.readMethods))", selection: $readPolicy) {
                    ForEach(APISecretsHelpers.policies, id: \.value) { p in Text(p.label).tag(p.value) }
                }
                Picker("Write (\(APISecretsHelpers.writeMethods))", selection: $writePolicy) {
                    ForEach(APISecretsHelpers.policies, id: \.value) { p in Text(p.label).tag(p.value) }
                }
                if !personas.isEmpty {
                    Section("Personas") {
                        ForEach(personas, id: \.id) { p in
                            Toggle(p.name, isOn: Binding(
                                get: { selectedPersonas.contains(p.id) },
                                set: { if $0 { selectedPersonas.insert(p.id) } else { selectedPersonas.remove(p.id) } }
                            ))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                Button(saving ? "Saving…" : "Save Secret") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 600)
    }

    private func submit() {
        guard let store = aux.store else { return }
        let hosts = hostsText
            .split(separator: ",")
            .compactMap { APISecretsHelpers.hostOf(String($0)) }
        guard !hosts.isEmpty else {
            error = "Enter at least one valid hostname (e.g. api.example.com)."
            return
        }
        error = nil
        saving = true
        let oauth: API.NewApiSecretOAuth? = kind == .oauth
            ? API.NewApiSecretOAuth(
                authorizeUrl: authorizeUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                clientId: clientId.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: clientSecret.isEmpty ? nil : clientSecret,
                scopes: APISecretsHelpers.splitScopes(scopesText),
                tokenUrl: tokenUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            : nil

        let body = API.NewApiSecret(
            allowedHosts: hosts,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            oauth: oauth,
            personaIds: Array(selectedPersonas),
            placement: placement,
            placementKey: placementKey.trimmingCharacters(in: .whitespacesAndNewlines),
            readPolicy: readPolicy,
            value: kind == .static ? valueText : nil,
            writePolicy: writePolicy
        )
        Task {
            defer { saving = false }
            do {
                _ = try await store.mutate(API.createApiSecret(body: body))
                onDismiss()
            } catch {
                self.error = settingsErrorText(error)
            }
        }
    }
}
