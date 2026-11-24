import SwiftUI
import VesperCore

struct SettingsSpacesPane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var busy = false
    @State private var errorMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let spacesEntry = store?.entry(API.listChatSpaces())
        let bootEntry = store?.entry(API.getBootstrap())
        let spaces = spacesEntry?.data?.spaces ?? []
        let selectedSpace = spaces.first(where: { $0.id == navigation.spaceId }) ?? spaces.first

        ScrollViewReader { proxy in
            SettingsScrollContainer {
                SettingsPaneHeader(
                    "Spaces",
                    subtitle: "Per-space memory and agent skill overrides."
                ) {
                    Button("New Space") {
                        aux.openInMainWindow("/spaces/new")
                    }
                }

                if let errorMessage {
                    SettingsBanner(tone: .blocked, title: "Space action failed", message: errorMessage)
                }

                if spacesEntry?.hasData == true {
                    if spaces.isEmpty {
                        SettingsCard("No spaces yet") {
                            Text("Create a space to keep separate memory for a topic or repository and customize agent skills per space.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Create Space") { aux.openInMainWindow("/spaces/new") }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if let space = selectedSpace {
                        SettingsCard("Space memory") {
                            Picker("Space", selection: Binding(
                                get: { space.id },
                                set: { navigation.spaceId = $0 }
                            )) {
                                ForEach(spaces, id: \.id) { sp in
                                    Text(sp.memoryCount > 0 ? "\(sp.name) (\(sp.memoryCount))" : sp.name).tag(sp.id)
                                }
                            }
                            .frame(width: 280)

                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(space.spaceMemory
                                         ? "Chats in \(space.name) store memories isolated to this space."
                                         : "Space memory is off: chats here use your general memory.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open \(space.name)") {
                                    aux.openInMainWindow("/spaces/\(space.id)")
                                }
                            }

                            Divider()

                            SpaceMemoryListView(aux: aux, spaceId: space.id, errorMessage: $errorMessage)
                        }
                    }
                } else if spacesEntry?.isFetching == true {
                    SettingsCard { ProgressView("Loading spaces…") }
                } else {
                    SettingsUnavailableCard(title: "Couldn't load spaces", error: spacesEntry?.error) {
                        Task { await store?.refetch(API.listChatSpaces()) }
                    }
                }

                SettingsCard(
                    "Space overrides",
                    subtitle: "Customize an agent's skills for one space while keeping future agent definition updates."
                ) {
                    if let boot = bootEntry?.data {
                        let workAgents = boot.agents.filter { $0.kind == .main }
                        let activeProjects = boot.projects.filter { !$0.archived }
                        if activeProjects.isEmpty || workAgents.isEmpty {
                            Text("No space overrides available yet. Create a space that tracks work and an agent first.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(workAgents, id: \.id) { agent in
                                HStack {
                                    Text(agent.name).font(.callout.weight(.medium))
                                    Text("@\(agent.handle)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Manage \(agent.name) project skills") {
                                        aux.openInMainWindow("/agents/\(agent.handle)?tab=skills#overrides")
                                    }
                                }
                                Divider()
                            }
                        }
                    } else if bootEntry?.isFetching == true {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingsUnavailableCard(title: "Couldn't load agent overrides", error: bootEntry?.error) {
                            Task { await store?.refetch(API.getBootstrap()) }
                        }
                    }
                }
                .id("overrides")
            }
            .onAppear {
                if navigation.anchor == "overrides" {
                    proxy.scrollTo("overrides", anchor: .top)
                }
            }
            .onChange(of: navigation.anchor) { _, next in
                if next == "overrides" {
                    withAnimation { proxy.scrollTo("overrides", anchor: .top) }
                }
            }
        }
        .task {
            store?.load(API.listChatSpaces())
            store?.load(API.getBootstrap())
        }
    }
}

private struct SpaceMemoryListView: View {
    let aux: AuxWindows
    let spaceId: String
    @Binding var errorMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let req = API.listMemories(spaceId: spaceId)
        let entry = store?.entry(req)

        Group {
            if let list = entry?.data {
                if list.memories.isEmpty {
                    Text("No memories stored in this space yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(list.memories, id: \.id) { m in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(m.title).font(.callout.weight(.medium))
                                    SettingsBadge(label: MemoryUIHelpers.typeLabel(m.type), tone: .neutral)
                                }
                                if !m.summary.isEmpty {
                                    Text(m.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Delete") { deleteMemory(m, req: req) }
                                .foregroundStyle(.red)
                                .buttonStyle(.borderless)
                        }
                        Divider()
                    }
                }
            } else if entry?.isFetching == true {
                ProgressView().controlSize(.small)
            } else {
                Text("Could not load space memory.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: spaceId) {
            store?.load(req)
        }
    }

    private func deleteMemory(_ m: API.Memory, req: APIRequest<API.MemoryList>) {
        guard SettingsFilePanels.confirm(
            title: "Delete “\(m.title)”?",
            message: "Chats in this space will no longer recall this memory.",
            confirmLabel: "Delete"
        ) else { return }
        guard let store else { return }
        Task {
            do {
                _ = try await store.mutate(API.deleteMemory(id: m.id))
                await store.refetch(req)
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
