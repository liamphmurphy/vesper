import SwiftUI
import VesperCore

struct SettingsRepositoriesPane: View {
    let aux: AuxWindows

    @State private var kind: API.RepositorySource.Kind = .repository
    @State private var sourceName = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let sourcesEntry = store?.entry(API.listRepositorySources())
        let presetsEntry = store?.entry(API.getRepositoryPresets())
        let sources = sourcesEntry?.data ?? []
        let owners = sources.filter { $0.kind == .organization }
        let repos = sources.filter { $0.kind == .repository }
        let savedOwnerNames = Set(owners.map { $0.name.lowercased() })

        SettingsScrollContainer {
            SettingsPaneHeader(
                "Repositories",
                subtitle: "GitHub owners and repositories surfaced in chat and workspace discovery. Saved lists aid discovery and never restrict access."
            )

            if let errorMessage {
                SettingsBanner(tone: .blocked, title: "Repository update failed", message: errorMessage)
            }
            if let statusMessage {
                SettingsBanner(tone: .done, title: statusMessage)
            }

            SettingsCard("Add repository source") {
                HStack(spacing: 10) {
                    Picker("Type", selection: $kind) {
                        Text("Repository (owner/name)").tag(API.RepositorySource.Kind.repository)
                        Text("GitHub owner / org").tag(API.RepositorySource.Kind.organization)
                    }
                    .frame(width: 210)

                    TextField(kind == .repository ? "e.g. octocat/hello-world" : "e.g. octocat or my-org", text: $sourceName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addSource(kind: kind, name: sourceName) }

                    Button("Add") {
                        addSource(kind: kind, name: sourceName)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let warning = presetsEntry?.data?.warning, !warning.isEmpty {
                SettingsBanner(tone: .human, title: "Partial GitHub discovery warning", message: warning)
            }

            if let ownerPresets = presetsEntry?.data?.owners, !ownerPresets.isEmpty {
                let unsaved = ownerPresets.filter { !savedOwnerNames.contains($0.login.lowercased()) }
                if !unsaved.isEmpty {
                    SettingsCard("Connected GitHub account & organizations", subtitle: "Quickly add discovered GitHub owners so their repositories appear in pickers.") {
                        ForEach(unsaved, id: \.login) { owner in
                            HStack {
                                Text(owner.login).font(.callout.monospaced())
                                SettingsBadge(label: owner.organization ? "Organization" : "Personal", tone: .neutral)
                                Spacer()
                                Button("Add") {
                                    addSource(kind: .organization, name: owner.login)
                                }
                                .disabled(busy)
                            }
                            Divider()
                        }
                    }
                }
            }

            if sourcesEntry?.hasData == true {
                SettingsCard("Saved GitHub owners (\(owners.count))") {
                    if owners.isEmpty {
                        Text("No GitHub owners saved.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(owners, id: \.name) { src in
                            HStack {
                                Text(src.name).font(.callout.monospaced())
                                Spacer()
                                Button("Remove") { removeSource(src) }
                                    .foregroundStyle(.red)
                                    .disabled(busy)
                            }
                            Divider()
                        }
                    }
                }

                SettingsCard("Saved repositories (\(repos.count))") {
                    if repos.isEmpty {
                        Text("No individual repositories saved.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(repos, id: \.name) { src in
                            HStack {
                                Text(src.name).font(.callout.monospaced())
                                Spacer()
                                Button("Remove") { removeSource(src) }
                                    .foregroundStyle(.red)
                                    .disabled(busy)
                            }
                            Divider()
                        }
                    }
                }
            } else if sourcesEntry?.isFetching == true {
                SettingsCard { ProgressView("Loading repository sources…") }
            } else {
                SettingsUnavailableCard(title: "Couldn't load repository sources", error: sourcesEntry?.error) {
                    Task { await store?.refetch(API.listRepositorySources()) }
                }
            }
        }
        .task {
            store?.load(API.listRepositorySources())
            store?.load(API.getRepositoryPresets())
        }
    }

    private func addSource(kind: API.RepositorySource.Kind, name: String) {
        guard let store else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.saveRepositorySource(body: API.RepositorySource(kind: kind, name: clean)))
                await store.refetch(API.listRepositorySources())
                if clean == sourceName.trimmingCharacters(in: .whitespacesAndNewlines) {
                    sourceName = ""
                }
                statusMessage = "Saved \(clean)."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }

    private func removeSource(_ src: API.RepositorySource) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.mutate(API.deleteRepositorySource(body: src))
                await store.refetch(API.listRepositorySources())
                statusMessage = "Removed \(src.name)."
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
