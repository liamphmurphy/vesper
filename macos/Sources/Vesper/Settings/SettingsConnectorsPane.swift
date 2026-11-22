import SwiftUI
import VesperCore

struct SettingsConnectorsPane: View {
    let aux: AuxWindows

    @State private var selectedId: String?
    @State private var showingAddSheet = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let entry = store?.entry(API.listConnectors())
        let personas = store?.entry(API.listPersonas()).data?.personas ?? []
        let connectors = entry?.data?.connectors ?? []
        let presets = entry?.data?.presets ?? []
        let selected = connectors.first(where: { $0.id == selectedId }) ?? connectors.first

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connectors").font(.title2.weight(.semibold))
                    Text("Remote MCP tool servers, per-tool approval policies, and persona access.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Connector…") { showingAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Connector error", message: errorMessage).padding(16)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage).padding(16)
            }

            if entry?.hasData == true {
                if connectors.isEmpty {
                    SettingsScrollContainer {
                        SettingsCard("No connectors yet") {
                            Text("Connect Linear, Notion, Sentry, or any HTTP MCP server so personas can read and act across your tools.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if !presets.isEmpty {
                                Text("Available presets: \(presets.map(\.name).joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Add Connector…") { showingAddSheet = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    HSplitView {
                        List(connectors, id: \.id, selection: Binding(
                            get: { selected?.id },
                            set: { selectedId = $0 }
                        )) { conn in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conn.name).font(.callout.weight(.medium))
                                    Text("\(conn.tools.count) tools · \(conn.slug)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                statusPill(conn.status)
                            }
                            .tag(conn.id)
                        }
                        .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)

                        if let conn = selected {
                            ScrollView {
                                connectorDetail(conn, personas: personas)
                                    .padding(20)
                            }
                        }
                    }
                }
            } else if entry?.isFetching == true {
                ProgressView("Loading connectors…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SettingsUnavailableCard(title: "Couldn't load connectors", error: entry?.error) {
                    Task { await store?.refetch(API.listConnectors()) }
                }
                .padding(24)
            }
        }
        .task {
            store?.load(API.listConnectors())
            store?.load(API.listPersonas())
        }
        .sheet(isPresented: $showingAddSheet) {
            AddConnectorSheet(aux: aux, presets: presets) { authorizeUrl in
                showingAddSheet = false
                Task { await store?.refetch(API.listConnectors()) }
                if let authorizeUrl, let url = URL(string: authorizeUrl) {
                    aux.openExternal(url)
                }
            }
        }
    }

    private func statusPill(_ status: API.Connector.Status) -> some View {
        switch status {
        case .connected: return SettingsBadge(label: "Connected", tone: .done)
        case .needsSignIn: return SettingsBadge(label: "Needs sign-in", tone: .human)
        default: return SettingsBadge(label: "Offline", tone: .blocked)
        }
    }

    private func connectorDetail(_ conn: API.Connector, personas: [API.Persona]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(conn.name).font(.title3.weight(.semibold))
                            statusPill(conn.status)
                        }
                        Text(conn.url).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !conn.lastError.isEmpty {
                            Text(conn.lastError).font(.callout).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if conn.authKind == .oauth {
                            Button(conn.status == .needsSignIn ? "Sign in" : "Re-authorize") {
                                authorize(conn)
                            }
                            .disabled(busy)
                        }
                        Button("Test") { testConnector(conn) }
                            .disabled(busy)
                        Button("Delete") { deleteConnector(conn) }
                            .foregroundStyle(.red)
                            .disabled(busy)
                    }
                }
            }

            SettingsCard("Persona Access", subtitle: "Personas allowed to invoke tools from this connector.") {
                if personas.isEmpty {
                    Text("No personas found.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 6) {
                        ForEach(personas, id: \.id) { p in
                            let allowed = conn.personaIds.contains(p.id)
                            Toggle(p.name, isOn: Binding(
                                get: { allowed },
                                set: { on in
                                    var next = conn.personaIds
                                    if on { if !next.contains(p.id) { next.append(p.id) } }
                                    else { next.removeAll { $0 == p.id } }
                                    patch(conn, API.ConnectorPatch(personaIds: next, revision: conn.revision))
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }

            SettingsCard("Tool Policies (\(conn.tools.count))", subtitle: "Allow tools automatically, ask first, or disable them.") {
                if conn.tools.isEmpty {
                    Text("No tools discovered yet. Run Test to refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(conn.tools, id: \.name) { tool in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tool.name).font(.callout.monospaced().weight(.medium))
                                    if tool.write {
                                        SettingsBadge(label: "Write", tone: .human)
                                    }
                                }
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Picker("Policy", selection: Binding(
                                get: { API.ConnectorPatch.PoliciesValue(rawValue: tool.policy.rawValue) },
                                set: { nextPolicy in
                                    patch(conn, API.ConnectorPatch(policies: [tool.name: nextPolicy], revision: conn.revision))
                                }
                            )) {
                                Text("Allow").tag(API.ConnectorPatch.PoliciesValue.allow)
                                Text("Ask").tag(API.ConnectorPatch.PoliciesValue.ask)
                                Text("Off").tag(API.ConnectorPatch.PoliciesValue.off)
                            }
                            .frame(width: 110)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private func patch(_ conn: API.Connector, _ body: API.ConnectorPatch) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.updateConnector(id: conn.id, body: body))
                await store.refetch(API.listConnectors())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func testConnector(_ conn: API.Connector) {
        guard let client = aux.client() else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                let tested = try await client.send(API.testConnector(id: conn.id))
                await store?.refetch(API.listConnectors())
                statusMessage = tested.status == .connected ? "\(tested.name) is connected (\(tested.tools.count) tools)." : tested.lastError
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func authorize(_ conn: API.Connector) {
        guard let client = aux.client() else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let res = try await client.send(API.authorizeConnector(id: conn.id))
                if let urlStr = res.authorizeUrl, let url = URL(string: urlStr) {
                    aux.openExternal(url)
                }
                await store?.refetch(API.listConnectors())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func deleteConnector(_ conn: API.Connector) {
        guard SettingsFilePanels.confirm(
            title: "Remove \(conn.name)?",
            message: "Personas will no longer have access to tools from \(conn.url).",
            confirmLabel: "Delete"
        ) else { return }
        guard let store else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deleteConnector(id: conn.id))
                selectedId = nil
                await store.refetch(API.listConnectors())
                statusMessage = "Removed \(conn.name)."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}

private struct AddConnectorSheet: View {
    let aux: AuxWindows
    let presets: [API.ConnectorPreset]
    let onDone: (String?) -> Void

    @State private var selectedPresetId = ""
    @State private var name = ""
    @State private var url = ""
    @State private var authKind: API.NewConnector.AuthKind = .none
    @State private var token = ""
    @State private var oauthClientId = ""
    @State private var oauthClientSecret = ""
    @State private var oauthScopes = ""
    @State private var probeResult: API.ConnectorProbe?
    @State private var probing = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Connector").font(.title3.weight(.semibold))
            Form {
                if !presets.isEmpty {
                    Picker("Preset", selection: $selectedPresetId) {
                        Text("Custom URL").tag("")
                        ForEach(presets, id: \.id) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .onChange(of: selectedPresetId) { _, id in
                        if let p = presets.first(where: { $0.id == id }) {
                            name = p.name
                            url = p.url
                            authKind = API.NewConnector.AuthKind(rawValue: p.authKind.rawValue)
                            oauthScopes = p.defaultScopes.joined(separator: " ")
                        }
                    }
                }

                TextField("Name", text: $name)
                HStack {
                    TextField("MCP Server URL (https://...)", text: $url)
                    Button(probing ? "Checking…" : "Probe") { probe() }
                        .disabled(probing || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let probeResult {
                    Text(probeResult.reachable
                         ? "Reachable · \(probeResult.tools) tools · \(probeResult.needsAuth ? "auth required" : "open")"
                         : (probeResult.error ?? "Not reachable"))
                        .font(.caption)
                        .foregroundStyle(probeResult.reachable ? Color.secondary : Color.red)
                }

                Picker("Authentication", selection: $authKind) {
                    Text("None").tag(API.NewConnector.AuthKind.none)
                    Text("Bearer Token").tag(API.NewConnector.AuthKind.token)
                    Text("OAuth").tag(API.NewConnector.AuthKind.oauth)
                }

                if authKind == .token {
                    SecureField("API Token", text: $token)
                } else if authKind == .oauth {
                    TextField("OAuth Client ID (optional for DCR)", text: $oauthClientId)
                    SecureField("OAuth Client Secret (optional)", text: $oauthClientSecret)
                    TextField("Scopes (space or comma separated)", text: $oauthScopes)
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }
                Button(saving ? "Adding…" : "Add Connector") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 470)
    }

    private func probe() {
        guard let client = aux.client() else { return }
        probing = true
        error = nil
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { probing = false }
            do {
                let res = try await client.send(API.probeConnector(body: API.ConnectorProbeRequest(token: token.isEmpty ? nil : token, url: target)))
                probeResult = res
                if res.needsAuth && authKind == .none {
                    authKind = .oauth
                }
            } catch {
                self.error = settingsErrorText(error)
            }
        }
    }

    private func create() {
        guard let store = aux.store else { return }
        saving = true
        error = nil
        let scopes = APISecretsHelpers.splitScopes(oauthScopes)
        let body = API.NewConnector(
            authKind: authKind,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            oauthClientId: oauthClientId.isEmpty ? nil : oauthClientId,
            oauthClientSecret: oauthClientSecret.isEmpty ? nil : oauthClientSecret,
            oauthScopes: scopes.isEmpty ? nil : scopes,
            token: authKind == .token ? token : nil,
            url: url.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        Task {
            defer { saving = false }
            do {
                let created = try await store.mutate(API.createConnector(body: body))
                onDone(created.authorizeUrl)
            } catch {
                self.error = settingsErrorText(error)
            }
        }
    }
}
