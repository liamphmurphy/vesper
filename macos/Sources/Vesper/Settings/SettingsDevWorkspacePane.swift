import SwiftUI
import VesperCore

struct SettingsDevWorkspacePane: View {
    let aux: AuxWindows

    @State private var tmuxPrefix: API.UpdateDevWorkspace.TmuxPrefix = .cB
    @State private var extraPackagesText = ""
    @State private var zshrcText = ""
    @State private var tmuxConfText = ""
    @State private var gitconfigText = ""
    @State private var repoSearch = ""
    @State private var loadedUpdatedAt: String?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let entry = store?.entry(API.getDevWorkspace())

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Dev Workspace",
                subtitle: "Persistent Nix + LazyVim container for inspecting and testing agent branches."
            ) {
                HStack(spacing: 8) {
                    Button("Open Dev Terminal") {
                        aux.openInMainWindow("/dev")
                    }
                    Button("Refresh") {
                        Task { await store?.refetch(API.getDevWorkspace()) }
                    }
                }
            }

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Dev workspace error", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }

            if let ws = entry?.data {
                SettingsCard("Container") {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { ws.enabled },
                            set: { next in update(API.UpdateDevWorkspace(enabled: next)) }
                        )) {
                            Text("Enable Dev Workspace container")
                            Text("No container runs until enabled.")
                        }
                        .disabled(busy)
                        Spacer()
                        SettingsBadge(
                            label: DevWorkspaceHelpers.statusLabel(enabled: ws.enabled, state: ws.state, step: ws.step?.value),
                            tone: DevWorkspaceHelpers.statusTone(ws.state)
                        )
                    }

                    if let err = ws.error?.value, !err.isEmpty {
                        SettingsBanner(tone: .blocked, title: "Last container error", message: err)
                    }

                    HStack(spacing: 8) {
                        Button("Start") { runAction(.start) }.disabled(busy || !ws.enabled)
                        Button("Stop") { runAction(.stop) }.disabled(busy || ws.state == .stopped)
                        Button("Sync Repos") { runAction(.sync) }.disabled(busy || ws.state != .ready)
                        Button("Rebuild") { runAction(.rebuild) }.disabled(busy || !ws.enabled)
                        Spacer()
                        if let port = ws.port?.value {
                            Text("SSH/Terminal port \(port)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .onAppear { syncDraft(ws) }
                .onChange(of: ws) { _, next in
                    if loadedUpdatedAt != next.updatedAt { syncDraft(next) }
                }

                SettingsCard("Environment & Tools") {
                    Picker("tmux prefix", selection: $tmuxPrefix) {
                        Text("Ctrl-b (default)").tag(API.UpdateDevWorkspace.TmuxPrefix.cB)
                        Text("Ctrl-a").tag(API.UpdateDevWorkspace.TmuxPrefix.cA)
                        Text("Ctrl-Space").tag(API.UpdateDevWorkspace.TmuxPrefix.cSpace)
                        Text("Ctrl-s").tag(API.UpdateDevWorkspace.TmuxPrefix.cS)
                    }
                    .frame(width: 260)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra Nix packages (comma or newline separated)").font(.subheadline.weight(.medium))
                        TextEditor(text: $extraPackagesText)
                            .font(.caption.monospaced())
                            .frame(height: 68)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    }

                    HStack {
                        Spacer()
                        Button(busy ? "Saving…" : "Save Tool Settings") {
                            let packages = extraPackagesText
                                .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            update(API.UpdateDevWorkspace(extraPackages: packages, tmuxPrefix: tmuxPrefix))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    }
                }

                SettingsCard("Dotfiles", subtitle: "Optional custom configuration files mounted into the dev container.") {
                    dotfileEditor(title: ".zshrc", text: $zshrcText, hasCustom: ws.customZshrc?.value != nil, resetAction: {
                        update(API.UpdateDevWorkspace(customZshrc: .null))
                    })
                    Divider()
                    dotfileEditor(title: ".tmux.conf", text: $tmuxConfText, hasCustom: ws.customTmuxConf?.value != nil, resetAction: {
                        update(API.UpdateDevWorkspace(customTmuxConf: .null))
                    })
                    Divider()
                    dotfileEditor(title: ".gitconfig", text: $gitconfigText, hasCustom: ws.customGitconfig?.value != nil, resetAction: {
                        update(API.UpdateDevWorkspace(customGitconfig: .null))
                    })
                    HStack {
                        Spacer()
                        Button(busy ? "Saving…" : "Save Custom Dotfiles") {
                            update(API.UpdateDevWorkspace(
                                customGitconfig: gitconfigText.isEmpty ? .null : .value(gitconfigText),
                                customTmuxConf: tmuxConfText.isEmpty ? .null : .value(tmuxConfText),
                                customZshrc: zshrcText.isEmpty ? .null : .value(zshrcText)
                            ))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    }
                }

                SettingsCard("Synced repositories (\(ws.repos.count))") {
                    TextField("Filter repositories…", text: $repoSearch)
                        .textFieldStyle(.roundedBorder)
                    let shown = DevWorkspaceHelpers.filterRepos(ws.repos, query: repoSearch)
                    if shown.isEmpty {
                        Text("No repositories synced yet.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(shown, id: \.directory) { repo in
                            HStack {
                                Text(repo.directory).font(.caption.monospaced().weight(.medium))
                                Spacer()
                                Text(repo.repoUrl).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Divider()
                        }
                    }
                }
            } else if entry?.isFetching == true {
                SettingsCard { ProgressView("Loading dev workspace…") }
            } else {
                SettingsUnavailableCard(title: "Couldn't load dev workspace", error: entry?.error) {
                    Task { await store?.refetch(API.getDevWorkspace()) }
                }
            }
        }
        .task { store?.load(API.getDevWorkspace()) }
    }

    @ViewBuilder
    private func dotfileEditor(title: String, text: Binding<String>, hasCustom: Bool, resetAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.monospaced().weight(.medium))
                if hasCustom { SettingsBadge(label: "Custom", tone: .human) }
                Spacer()
                if hasCustom {
                    Button("Reset to default", action: resetAction)
                        .disabled(busy)
                }
            }
            TextEditor(text: text)
                .font(.caption.monospaced())
                .frame(height: 82)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private func syncDraft(_ ws: API.DevWorkspace) {
        loadedUpdatedAt = ws.updatedAt
        tmuxPrefix = API.UpdateDevWorkspace.TmuxPrefix(rawValue: ws.tmuxPrefix.rawValue)
        extraPackagesText = ws.extraPackages.joined(separator: "\n")
        zshrcText = ws.customZshrc?.value ?? ""
        tmuxConfText = ws.customTmuxConf?.value ?? ""
        gitconfigText = ws.customGitconfig?.value ?? ""
    }

    private func update(_ body: API.UpdateDevWorkspace) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                let updated = try await store.mutate(API.updateDevWorkspace(body: body))
                store.setData(updated, for: API.getDevWorkspace())
                syncDraft(updated)
                statusMessage = "Dev workspace updated."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func runAction(_ action: API.DevWorkspaceActionRequest.Action) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                let updated = try await store.mutate(API.devWorkspaceAction(body: API.DevWorkspaceActionRequest(action: action)))
                store.setData(updated, for: API.getDevWorkspace())
                syncDraft(updated)
                statusMessage = "Action \(action.rawValue) requested."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
