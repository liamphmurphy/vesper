import SwiftUI
import VesperCore

struct SettingsWorkspacePane: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    private var store: QueryStore? { aux.store }

    var body: some View {
        let bootEntry = store?.entry(API.getBootstrap())
        let secretsEntry = store?.entry(API.listSecrets())
        let modelsEntry = store?.entry(API.listChatModels())
        let runnerEntry = store?.entry(API.getRunnerStatus())
        let spacesEntry = store?.entry(API.listChatSpaces())

        ScrollViewReader { proxy in
            SettingsScrollContainer {
                SettingsPaneHeader(
                    "Workspace",
                    subtitle: "Shared by every space. Secret encryption and workspace defaults live here."
                ) {
                    Button("Run setup again") {
                        aux.openInMainWindow("/chat?new&setup")
                    }
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
                    let steps = WorkspaceSetupHelpers.checklist(
                        reposCount: reposCount,
                        firstWorkSpaceId: firstWorkSpaceId,
                        harnessSecretSet: harnessSecretSet,
                        harnessModels: modelsEntry?.data ?? [],
                        runner: runnerEntry?.data
                    )

                    SettingsCard("Setup checklist", subtitle: "Everything needed before running coding chats or building branches.") {
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

                SettingsMediaProvidersSection(aux: aux)
                    .id("media")
            }
            .onAppear {
                if let anchor = navigation.anchor, anchor == "images" || anchor == "media" {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .onChange(of: navigation.anchor) { _, next in
                if let next, next == "images" || next == "media" {
                    withAnimation { proxy.scrollTo(next, anchor: .top) }
                }
            }
        }
        .task {
            store?.load(API.getBootstrap())
            store?.load(API.listSecrets())
            store?.load(API.listChatModels())
            store?.load(API.getRunnerStatus())
            store?.load(API.listChatSpaces())
            store?.load(API.getImageEngine())
            store?.load(API.listMediaProviders())
        }
    }
}
