import SwiftUI
import VesperCore

/// Right-rail Context dock for `/spaces/:id`: manages live Repositories, live Knowledge links,
/// Space persona/memory/instructions, static sources, and conditional Branches/PRs.
struct SpaceContextInspectorView: View {
    let spaceId: String
    let tabId: String
    let onEditSpace: () -> Void
    let onManageSources: () -> Void

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var addingRepo = false
    @State private var newRepoURL = ""
    @State private var newRepoReadOnly = false
    @State private var savingRepo = false
    @State private var repoError: String?

    @State private var addingKnowledge = false
    @State private var newKnowledgeKind: API.ChatSpaceKnowledgeLinkKind = .folder
    @State private var newKnowledgePath = ""
    @State private var newKnowledgePinned = false
    @State private var savingKnowledge = false
    @State private var knowledgeError: String?
    @State private var knowledgePages: [KnowledgePageRow] = []
    @State private var loadingKnowledgePages = false
    @State private var selectedSuggestionIndex = 0
    @State private var suggestionsDismissed = false
    @State private var suppressNextPathChange = false
    @State private var syncingBranches = false
    @State private var showClosedBranches = false
    @State private var addingConnector = false
    @FocusState private var knowledgePathFocused: Bool

    private static let personasRequest = API.listPersonas()
    private static let connectorsRequest = API.listConnectors()
    private static let knowledgePagesRequest = KnowledgeAPI.listPages(includeAgent: true, limit: 200)

    private var spaceRequest: APIRequest<API.ChatSpace> { API.getChatSpace(spaceId: spaceId) }
    private var reposRequest: APIRequest<API.ListChatSpaceRepositoriesResponse> { API.listChatSpaceRepositories(spaceId: spaceId) }
    private var knowledgeRequest: APIRequest<API.ListChatSpaceKnowledgeLinksResponse> { API.listChatSpaceKnowledgeLinks(spaceId: spaceId) }
    private var sourcesRequest: APIRequest<API.ChatSpaceSourceList> { API.listChatSpaceSources(spaceId: spaceId) }
    private var branchesRequest: APIRequest<API.ListChatSpaceBranchesResponse> { API.listChatSpaceBranches(spaceId: spaceId) }

    var body: some View {
        let p = theme.palette
        let space = context.store.entry(spaceRequest).data
        let repos = context.store.entry(reposRequest).data?.repositories ?? []
        let links = context.store.entry(knowledgeRequest).data?.links ?? []
        let sourcesData = context.store.entry(sourcesRequest).data
        let branches = context.store.entry(branchesRequest).data?.branches ?? []
        let personas = context.store.entry(Self.personasRequest).data?.personas ?? []
        let connectors = context.store.entry(Self.connectorsRequest).data?.connectors ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if tabId == "branches" {
                    branchesSection(branches: branches, p: p)
                } else {
                    if let space {
                        personaAndMemorySection(space: space, personas: personas, p: p)
                        Divider()
                    }
                    repositoriesSection(repos: repos, p: p)
                    Divider()
                    knowledgeSection(links: links, p: p)
                    Divider()
                    if let space {
                        browserTabsSection(space: space, p: p)
                        Divider()
                        connectorsSection(space: space, connectors: connectors, p: p)
                        Divider()
                        sourcesSection(space: space, sourcesData: sourcesData, p: p)
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            context.store.load(Self.connectorsRequest)
        }
        .task(id: addingKnowledge) {
            guard addingKnowledge else { return }
            await loadKnowledgePages()
        }
    }

    // MARK: - Persona, Memory & Instructions

    private func personaAndMemorySection(space: API.ChatSpace, personas: [API.Persona], p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SPACE SETTINGS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button("Edit") { onEditSpace() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(p.accent)
            }

            HStack {
                Text("Persona")
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)
                Spacer()
                Picker("Persona", selection: Binding(
                    get: { space.personaId ?? "" },
                    set: { next in patchSpace(API.ChatSpacePatch(personaId: next)) }
                )) {
                    Text("Default persona").tag("")
                    ForEach(personas, id: \.id) { persona in
                        Text(persona.name).tag(persona.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            Toggle(isOn: Binding(
                get: { space.spaceMemory },
                set: { checked in patchSpace(API.ChatSpacePatch(spaceMemory: checked)) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Isolated memory").font(.system(size: 12)).foregroundStyle(p.text)
                    Text(space.spaceMemory ? "Memories stay in \(space.name)" : "Shares general memory")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if let memLabel = SpacesLogic.memoryCountLabel(space.memoryCount) {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.tertiaryText)
                    Text(memLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(p.secondaryText)
                }
            }

            let instr = space.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !instr.isEmpty {
                Text(instr)
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
        }
    }

    // MARK: - Linked Browser Tabs

    @ViewBuilder
    private func browserTabsSection(space: API.ChatSpace, p: NativePalette) -> some View {
        if let browser = context.window()?.app.browser {
            let linked = browser.linkedTabGroups(forSpaceId: space.id)
            let totalTabs = linked.reduce(0) { $0 + $1.tabs.count }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BROWSER TABS")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                    if totalTabs > 0 {
                        Text("\(totalTabs)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.tertiaryText)
                    }
                    Spacer()
                    Button {
                        _ = browser.createLinkedTabGroup(forSpace: space, openBrowser: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Create Browser tab group linked to \(space.name)")
                }

                if linked.isEmpty {
                    Text("No Browser tab groups linked yet. Link one to auto-route web clippings and highlights into this Space.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    ForEach(linked) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                if let group = entry.group {
                                    Circle()
                                        .fill(group.color.swiftUIColor)
                                        .frame(width: 7, height: 7)
                                    Text(group.name)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(p.text)
                                        .lineLimit(1)
                                } else {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(p.secondaryText)
                                    Text("\(entry.profileName) profile")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(p.text)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let group = entry.group, !entry.tabs.isEmpty {
                                    Button("Share Group") {
                                        Task { await browser.shareTabGroup(group, openInCompanion: true) }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(p.accent)
                                }
                            }

                            if entry.tabs.isEmpty {
                                Text("No open tabs in this group.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                            } else {
                                ForEach(entry.tabs.prefix(8)) { tab in
                                    Button {
                                        browser.openTabFromSpace(profileId: entry.profileId, tabId: tab.id)
                                    } label: {
                                        HStack(spacing: 6) {
                                            if let favicon = tab.favicon {
                                                Image(nsImage: favicon)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fit)
                                                    .frame(width: 12, height: 12)
                                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                                            } else {
                                                Image(systemName: "globe")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(p.tertiaryText)
                                                    .frame(width: 12)
                                            }
                                            Text(tab.displayTitle)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(p.text)
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            if !tab.displayHost.isEmpty {
                                                Text(tab.displayHost)
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(p.tertiaryText)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3.5)
                                        .background(p.surface, in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Repositories

    private func repositoriesSection(repos: [API.ChatSpaceRepository], p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REPOSITORIES")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                if !repos.isEmpty {
                    Text("\(repos.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                Button {
                    addingRepo.toggle()
                    repoError = nil
                } label: {
                    Image(systemName: addingRepo ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.accent)
                }
                .buttonStyle(.plain)
                .help("Attach a Git repository")
            }

            if repos.isEmpty && !addingRepo {
                Text("No repositories attached. Coding chats auto-attach repos listed here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.tertiaryText)
            }

            ForEach(repos, id: \.id) { repo in
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.secondaryText)
                    Text(ChatCodeReviewLogic.repoName(repo.repoUrl))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        toggleRepoReadOnly(repo)
                    } label: {
                        Text(repo.readOnly ? "Read-only" : "Read/Write")
                            .font(.system(size: 10))
                            .foregroundStyle(repo.readOnly ? p.secondaryText : p.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(p.surface, in: Capsule())
                            .overlay(Capsule().stroke(p.border))
                    }
                    .buttonStyle(.plain)
                    .help("Toggle read-only access")

                    Button {
                        deleteRepo(repo.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Remove repository")
                }
                .padding(.vertical, 3)
            }

            if addingRepo {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("owner/repo or https://github.com/...", text: $newRepoURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { addRepo() }
                    HStack {
                        Toggle("Read-only", isOn: $newRepoReadOnly)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                        Spacer()
                        Button(savingRepo ? "Adding\u{2026}" : "Add") { addRepo() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(savingRepo || newRepoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let repoError {
                        Text(repoError)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }
                }
                .padding(8)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }
        }
    }

    // MARK: - Knowledge Links

    private func knowledgeSection(links: [API.ChatSpaceKnowledgeLink], p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("KNOWLEDGE")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                if !links.isEmpty {
                    Text("\(links.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                Button {
                    addingKnowledge.toggle()
                    knowledgeError = nil
                    if addingKnowledge {
                        suggestionsDismissed = false
                        selectedSuggestionIndex = 0
                        knowledgePathFocused = true
                    }
                } label: {
                    Image(systemName: addingKnowledge ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.accent)
                }
                .buttonStyle(.plain)
                .help("Link a Knowledge folder or page")
            }

            if links.isEmpty && !addingKnowledge {
                Text("Link a Knowledge folder or pin key pages so Space chats know where notes live.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.tertiaryText)
            }

            ForEach(links, id: \.id) { link in
                HStack(spacing: 6) {
                    Image(systemName: link.kind == .folder ? "folder" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(p.secondaryText)
                    Button {
                        let encoded = link.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? link.path
                        if link.kind == .page {
                            context.navigate("/knowledge/\(encoded)")
                        } else {
                            context.navigate("/knowledge")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(link.kind == .folder ? "\(link.path)/" : link.path)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            HStack(spacing: 5) {
                                if link.kind == .folder {
                                    Text("\(link.pageCount) page\(link.pageCount == 1 ? "" : "s")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(p.tertiaryText)
                                }
                                if link.isDefaultTarget {
                                    Text("Default folder")
                                        .font(.system(size: 10))
                                        .foregroundStyle(p.accent)
                                }
                                if link.pinned {
                                    Text("Pinned")
                                        .font(.system(size: 10))
                                        .foregroundStyle(p.accent)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 4)
                    if link.kind == .page {
                        Button {
                            toggleKnowledgePin(link)
                        } label: {
                            Image(systemName: link.pinned ? "pin.fill" : "pin")
                                .font(.system(size: 10))
                                .foregroundStyle(link.pinned ? p.accent : p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help(link.pinned ? "Unpin from inline context" : "Pin to inline context")
                    }
                    Button {
                        deleteKnowledgeLink(link.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Unlink from Space")
                }
                .padding(.vertical, 3)
            }

            if addingKnowledge {
                let catalogPages = knowledgePages.isEmpty
                    ? (context.store.entry(Self.knowledgePagesRequest).data?.rows ?? [])
                    : knowledgePages
                let suggestions = SpacesLogic.knowledgeLinkSuggestions(
                    query: newKnowledgePath,
                    kind: newKnowledgeKind,
                    pages: catalogPages,
                    existingLinks: links
                )
                let trimmedPath = KnowledgeShellLogic.normalizeFolderPath(
                    newKnowledgePath.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let showSuggestions = !suggestionsDismissed && !suggestions.isEmpty
                let activeIdx = suggestions.isEmpty ? 0 : min(max(0, selectedSuggestionIndex), suggestions.count - 1)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Kind", selection: $newKnowledgeKind) {
                        Text("Folder").tag(API.ChatSpaceKnowledgeLinkKind.folder)
                        Text("Page").tag(API.ChatSpaceKnowledgeLinkKind.page)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .onChange(of: newKnowledgeKind) { _, _ in
                        selectedSuggestionIndex = 0
                        suggestionsDismissed = false
                        knowledgeError = nil
                    }

                    TextField(
                        newKnowledgeKind == .folder ? "Search folders (e.g. Umbra)" : "Search pages (e.g. Umbra/Campaign Bible)",
                        text: $newKnowledgePath
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .focused($knowledgePathFocused)
                    .onChange(of: newKnowledgePath) { _, _ in
                        if suppressNextPathChange {
                            suppressNextPathChange = false
                            return
                        }
                        selectedSuggestionIndex = 0
                        suggestionsDismissed = false
                        knowledgeError = nil
                    }
                    .onKeyPress(.downArrow) {
                        guard showSuggestions else { return .ignored }
                        selectedSuggestionIndex = (activeIdx + 1) % suggestions.count
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard showSuggestions else { return .ignored }
                        selectedSuggestionIndex = (activeIdx - 1 + suggestions.count) % suggestions.count
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        guard showSuggestions else { return .ignored }
                        applyKnowledgeSuggestion(suggestions[activeIdx])
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if showSuggestions {
                            suggestionsDismissed = true
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit {
                        if showSuggestions, !trimmedPath.isEmpty,
                           suggestions[activeIdx].path != trimmedPath {
                            applyKnowledgeSuggestion(suggestions[activeIdx])
                        } else {
                            addKnowledgeLink()
                        }
                    }

                    if showSuggestions {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, item in
                                    Button {
                                        applyKnowledgeSuggestion(item)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: item.kind == .folder ? "folder" : "doc.text")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(idx == activeIdx ? p.accent : p.secondaryText)
                                                .frame(width: 13)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.title)
                                                    .font(.system(size: 11.5, weight: .medium))
                                                    .foregroundStyle(p.text)
                                                    .lineLimit(1)
                                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                                    Text(subtitle)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(p.tertiaryText)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer(minLength: 4)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                        .background(
                                            idx == activeIdx ? p.accent.opacity(0.14) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(3)
                        }
                        .frame(maxHeight: 176)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    } else if loadingKnowledgePages && catalogPages.isEmpty {
                        Text("Loading Knowledge\u{2026}")
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.tertiaryText)
                    } else if !trimmedPath.isEmpty && suggestions.isEmpty && !suggestionsDismissed {
                        Text("No matching \(newKnowledgeKind == .folder ? "folders" : "pages") — you can still link this path.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.tertiaryText)
                    }

                    HStack {
                        if newKnowledgeKind == .page {
                            Toggle("Pin inline", isOn: $newKnowledgePinned)
                                .toggleStyle(.checkbox)
                                .font(.system(size: 11))
                        }
                        Spacer()
                        Button(savingKnowledge ? "Linking\u{2026}" : "Link") { addKnowledgeLink() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(savingKnowledge || newKnowledgePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let knowledgeError {
                        Text(knowledgeError)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    }
                }
                .padding(8)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }
        }
    }

    // MARK: - Connectors

    private func connectorsSection(space: API.ChatSpace, connectors: [API.Connector], p: NativePalette) -> some View {
        let attachedSet = Set(space.connectorIds)
        let attached = connectors.filter { attachedSet.contains($0.id) }
        let available = connectors.filter { !attachedSet.contains($0.id) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CONNECTORS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                if !attached.isEmpty {
                    Text("\(attached.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                if !available.isEmpty {
                    Button {
                        addingConnector.toggle()
                    } label: {
                        Image(systemName: addingConnector ? "xmark" : "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Add a connector to this space")
                }
            }

            if connectors.isEmpty {
                Text("No connectors configured yet. Add one in Settings \u{2192} Connectors.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.tertiaryText)
            } else if attached.isEmpty && !addingConnector {
                Text("No connectors attached. Chats in this space won\u{2019}t inherit any connectors.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.tertiaryText)
            }

            ForEach(attached, id: \.id) { connector in
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.secondaryText)
                    Text(connector.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        let next = SpacesLogic.toggledConnectorIds(space.connectorIds, toggling: connector.id)
                        patchSpace(API.ChatSpacePatch(connectorIds: next))
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Remove connector")
                }
                .padding(.vertical, 3)
            }

            if addingConnector && !available.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(available, id: \.id) { connector in
                        Button {
                            let next = SpacesLogic.toggledConnectorIds(space.connectorIds, toggling: connector.id)
                            patchSpace(API.ChatSpacePatch(connectorIds: next))
                            if available.count == 1 {
                                addingConnector = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.accent)
                                Text(connector.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }
        }
    }

    // MARK: - Sources

    private func sourcesSection(space: API.ChatSpace, sourcesData: API.ChatSpaceSourceList?, p: NativePalette) -> some View {
        let sources = sourcesData?.sources ?? []
        let inlineTokens = sourcesData?.inlineTokens ?? space.inlineTokens
        let inlineBudget = sourcesData?.inlineBudget ?? 40_000
        let fraction = inlineBudget > 0 ? min(1.0, Double(inlineTokens) / Double(inlineBudget)) : 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SOURCES")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                if !sources.isEmpty {
                    Text("\(sources.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                Button("Manage") { onManageSources() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(p.accent)
            }

            if sources.isEmpty {
                Text("Static files, snippets, and links attached to this Space.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.tertiaryText)
            } else {
                ForEach(sources.prefix(5), id: \.id) { source in
                    HStack(spacing: 6) {
                        Text(SpacesLogic.sourceName(source))
                            .font(.system(size: 12))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Spacer()
                        Text(SpacesLogic.sourceKindLabel(source.kind))
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.tertiaryText)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                    .tint(p.accent)
                Text("\(SpacesLogic.formatTokens(inlineTokens)) of \(SpacesLogic.formatTokens(inlineBudget)) inline tokens")
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.tertiaryText)
            }
        }
    }

    // MARK: - Branches & PRs

    private func branchesSection(branches: [API.ChatSpaceBranch], p: NativePalette) -> some View {
        let active = SpacesLogic.activeBranches(branches)
        let closed = SpacesLogic.closedBranches(branches)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BRANCHES & PULL REQUESTS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button {
                    syncBranches()
                } label: {
                    if syncingBranches {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5))
                            .foregroundStyle(p.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(syncingBranches)
                .help("Check GitHub for merged or closed pull requests")
            }

            if branches.isEmpty {
                Text("No branches or pull requests in this Space yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.tertiaryText)
            } else {
                if active.isEmpty {
                    Text("No branches or pull requests in flight.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                } else {
                    ForEach(active, id: \.spaceBranchKey) { b in
                        branchRow(b, dimmed: false, p: p)
                    }
                }

                if !closed.isEmpty {
                    DisclosureGroup(isExpanded: $showClosedBranches) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(closed, id: \.spaceBranchKey) { b in
                                branchRow(b, dimmed: true, p: p)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Merged & Closed (\(closed.count))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.secondaryText)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func branchRow(_ b: API.ChatSpaceBranch, dimmed: Bool, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: b.prState == .merged ? "arrow.triangle.merge" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(dimmed ? p.tertiaryText : p.accent)
                Text(b.branch)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(dimmed ? p.secondaryText : p.text)
                    .lineLimit(1)
                Spacer()
                if let prUrl = b.prUrl, !prUrl.isEmpty {
                    Button(b.prNumber.map { "PR #\($0) \u{2197}" } ?? "PR \u{2197}") {
                        context.openExternal(prUrl)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(p.accent)
                }
            }
            HStack(spacing: 6) {
                Text(ChatCodeReviewLogic.repoName(b.repoUrl))
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.tertiaryText)
                Text("\u{00B7} \(SpacesLogic.branchStatusLabel(for: b))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.secondaryText)
                Spacer()
                Button(b.chatTitle.isEmpty ? "Open chat" : b.chatTitle) {
                    context.navigate("/chat/\(b.chatId)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(p.accent)
                .lineLimit(1)
            }
        }
        .padding(8)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }

    private func syncBranches() {
        guard !syncingBranches else { return }
        syncingBranches = true
        Task {
            defer { syncingBranches = false }
            do {
                let refreshed = try await context.store.mutate(
                    API.syncChatSpaceBranches(spaceId: spaceId),
                    invalidating: QueryInvalidation(resources: ["chat-spaces", "spaces"])
                )
                context.store.setData(
                    API.ListChatSpaceBranchesResponse(branches: refreshed.branches),
                    for: branchesRequest
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.branches.sync", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    // MARK: - Mutations

    private func patchSpace(_ patch: API.ChatSpacePatch) {
        Task {
            do {
                let updated = try await context.store.mutate(
                    API.updateChatSpace(spaceId: spaceId, body: patch),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                context.store.setData(updated, for: spaceRequest)
            } catch {
                context.showToast(ToastItemModel(id: "space.patch", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func addRepo() {
        let trimmed = newRepoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !savingRepo else { return }
        savingRepo = true
        repoError = nil
        Task {
            defer { savingRepo = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceRepository(
                        spaceId: spaceId,
                        body: API.NewChatSpaceRepository(readOnly: newRepoReadOnly, repoUrl: trimmed)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                newRepoURL = ""
                newRepoReadOnly = false
                addingRepo = false
            } catch {
                repoError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func toggleRepoReadOnly(_ repo: API.ChatSpaceRepository) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.updateChatSpaceRepository(
                        spaceId: spaceId,
                        repoId: repo.id,
                        body: API.ChatSpaceRepositoryPatch(readOnly: !repo.readOnly)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.repo", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func deleteRepo(_ repoId: String) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpaceRepository(spaceId: spaceId, repoId: repoId),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.repo.del", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func applyKnowledgeSuggestion(_ suggestion: SpacesLogic.KnowledgeLinkSuggestion) {
        suppressNextPathChange = true
        newKnowledgePath = suggestion.path
        suggestionsDismissed = true
        selectedSuggestionIndex = 0
        knowledgeError = nil
        knowledgePathFocused = true
    }

    private func loadKnowledgePages() async {
        guard let client = context.store.client else { return }
        loadingKnowledgePages = true
        defer { loadingKnowledgePages = false }
        var loaded: [KnowledgePageRow] = []
        var offset = 0
        while offset <= 20_000 {
            guard !Task.isCancelled else { return }
            do {
                let table = try await client.send(
                    KnowledgeAPI.listPages(includeAgent: true, limit: 200, offset: offset)
                )
                if offset == 0 {
                    context.store.setData(table, for: Self.knowledgePagesRequest)
                }
                loaded.append(contentsOf: table.rows)
                if !table.hasMore || table.rows.isEmpty { break }
                offset += 200
            } catch {
                break
            }
        }
        guard !Task.isCancelled else { return }
        if !loaded.isEmpty || knowledgePages.isEmpty {
            knowledgePages = loaded
        }
    }

    private func addKnowledgeLink() {
        let trimmed = newKnowledgePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !savingKnowledge else { return }
        savingKnowledge = true
        knowledgeError = nil
        Task {
            defer { savingKnowledge = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceKnowledgeLink(
                        spaceId: spaceId,
                        body: API.NewChatSpaceKnowledgeLink(
                            kind: newKnowledgeKind,
                            path: trimmed,
                            pinned: newKnowledgeKind == .page ? newKnowledgePinned : false
                        )
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                newKnowledgePath = ""
                newKnowledgePinned = false
                addingKnowledge = false
            } catch {
                knowledgeError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func toggleKnowledgePin(_ link: API.ChatSpaceKnowledgeLink) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.updateChatSpaceKnowledgeLink(
                        spaceId: spaceId,
                        linkId: link.id,
                        body: API.ChatSpaceKnowledgeLinkPatch(pinned: !link.pinned)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.know.pin", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func deleteKnowledgeLink(_ linkId: String) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpaceKnowledgeLink(spaceId: spaceId, linkId: linkId),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.know.del", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }
}
