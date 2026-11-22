import SwiftUI
import VesperCore

struct SettingsWorkspacePane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    @State private var busy = false
    @State private var errorMessage: String?

    private var store: QueryStore? { aux.store }

    var body: some View {
        let bootEntry = store?.entry(API.getBootstrap())
        let secretsEntry = store?.entry(API.listSecrets())
        let modelsEntry = store?.entry(API.listChatModels())
        let runnerEntry = store?.entry(API.getRunnerStatus())
        let plansEntry = store?.entry(API.listPlanningSessions())
        let spacesEntry = store?.entry(API.listChatSpaces())
        let imageEntry = store?.entry(API.getImageEngine())

        ScrollViewReader { proxy in
            SettingsScrollContainer {
                SettingsPaneHeader(
                    "Workspace",
                    subtitle: "Shared by every space. Secret encryption and workspace defaults live here."
                ) {
                    Button("Run setup again") {
                        aux.openInMainWindow("/setup")
                    }
                }

                if let errorMessage {
                    SettingsBanner(tone: .blocked, title: "Workspace action failed", message: errorMessage)
                }

                if let boot = bootEntry?.data {
                    SettingsCard("Workspace info") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow {
                                Text("Name").foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                                Text(boot.workspace.name).font(.body.weight(.medium))
                            }
                            GridRow {
                                Text("Slug").foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                                Text(boot.workspace.slug).font(.callout.monospaced())
                            }
                            GridRow {
                                Text("Secret encryption").foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                                if let secrets = secretsEntry?.data {
                                    SettingsBadge(
                                        label: secrets.keyConfigured ? "SECRETS_KEY configured" : "SECRETS_KEY missing",
                                        tone: secrets.keyConfigured ? .done : .blocked
                                    )
                                } else {
                                    Text("Checking…").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    let activeProjects = boot.projects.filter { !$0.archived }
                    let reposCount = activeProjects.filter { $0.repoUrl?.isEmpty == false }.count
                    let firstWorkSpaceId = activeProjects.first?.spaceId ?? spacesEntry?.data?.spaces.first(where: { $0.work != nil && !($0.work?.archived ?? true) })?.id
                    let harnessSecretSet = (secretsEntry?.data?.secrets ?? []).contains { $0.name.hasPrefix("harness:") && $0.project == nil }
                    let ticketAgents = boot.agents.filter { $0.kind == .main }.count
                    let steps = WorkspaceSetupHelpers.checklist(
                        reposCount: reposCount,
                        firstWorkSpaceId: firstWorkSpaceId,
                        harnessSecretSet: harnessSecretSet,
                        harnessModels: modelsEntry?.data ?? [],
                        runner: runnerEntry?.data,
                        ticketAgentsCount: ticketAgents,
                        plansCount: plansEntry?.data?.count ?? 0
                    )

                    SettingsCard("Setup checklist", subtitle: "Everything needed before dispatching runs or building branches.") {
                        ForEach(steps) { step in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(step.done ? .green : .secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.label).font(.callout.weight(.medium))
                                    Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(step.linkLabel) {
                                    if let dest = SettingsRouteResolver.resolve(step.href) {
                                        navigation.apply(dest)
                                    } else {
                                        aux.openInMainWindow(step.href)
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                } else if bootEntry?.isFetching == true {
                    SettingsCard { ProgressView("Loading workspace…") }
                } else {
                    SettingsUnavailableCard(title: "Couldn't load workspace", error: bootEntry?.error) {
                        Task { await store?.refetch(API.getBootstrap()) }
                    }
                }

                SettingsCard("Image engine", subtitle: "Which harness generates images requested by personas and workflows.") {
                    if let img = imageEntry?.data {
                        let choices = WorkspaceSetupHelpers.imageEngineChoices(img.options)
                        ForEach(choices) { choice in
                            let selected = img.engine == choice.value
                            Button {
                                saveImageEngine(choice.value)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice.label).font(.callout.weight(.medium))
                                        Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            Divider()
                        }
                    } else if imageEntry?.isFetching == true {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingsUnavailableCard(title: "Couldn't load image engine", error: imageEntry?.error) {
                            Task { await store?.refetch(API.getImageEngine()) }
                        }
                    }
                }
                .id("images")
            }
            .onAppear {
                if navigation.anchor == "images" {
                    proxy.scrollTo("images", anchor: .top)
                }
            }
            .onChange(of: navigation.anchor) { _, next in
                if next == "images" {
                    withAnimation { proxy.scrollTo("images", anchor: .top) }
                }
            }
        }
        .task {
            store?.load(API.getBootstrap())
            store?.load(API.listSecrets())
            store?.load(API.listChatModels())
            store?.load(API.getRunnerStatus())
            store?.load(API.listPlanningSessions())
            store?.load(API.listChatSpaces())
            store?.load(API.getImageEngine())
        }
    }

    private func saveImageEngine(_ raw: API.ImageEngineSettings.Engine) {
        guard let store else { return }
        busy = true
        errorMessage = nil
        let target = API.UpdateImageEngineBody.Engine(rawValue: raw.rawValue)
        Task {
            defer { busy = false }
            do {
                let updated = try await store.mutate(API.updateImageEngine(body: API.UpdateImageEngineBody(engine: target)))
                store.setData(updated, for: API.getImageEngine())
            } catch {
                errorMessage = settingsErrorText(error)
            }
        }
    }
}
