import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

/// Native `/spaces/:id` Space Hub: compact header, inline new-chat composer with live context toggles,
/// conditional In-Flight strip, optional flat Tasks checklist, recent chats, and right Context dock.
struct SpaceScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var editing = false
    @State private var showSourcesSheet = false
    @State private var showDeleteAlert = false
    @State private var chatSort: SpacesLogic.ChatSort = .newest
    @State private var showAllChats = false
    @State private var inspectorOpen = true
    @State private var inspectorTabId = "context"

    // Inline new-chat composer
    @State private var pickedPersonaId: String?
    @State private var pickedHarness: API.Harness?
    @State private var pickedModel: String?
    @State private var pickedEffort: API.ChatEffort?
    @State private var pickedRepoUrl: String?
    @State private var skipReposForChat = false
    @State private var startingChat = false
    @State private var composerError: String?

    // Tasks
    @State private var newTaskTitle = ""
    @State private var addingTask = false
    @State private var showTasksComposer = false

    // Edit header/settings form
    @State private var editName = ""
    @State private var editDescription = ""
    @State private var editInstructions = ""
    @State private var editColor: API.ChatSpaceColor = .green
    @State private var savingEdit = false
    @State private var editError: String?
    @State private var deleting = false
    @State private var syncingBranches = false
    @State private var watchedKeys: [QueryKey] = []

    private static let personasRequest = API.listPersonas()
    private static let modelsRequest = API.listChatModels()
    private static let spacesRequest = API.listChatSpaces()

    private var spaceId: String {
        context.match.params["id"] ?? ""
    }

    private var spaceRequest: APIRequest<API.ChatSpace> {
        API.getChatSpace(spaceId: spaceId)
    }

    private var sourcesRequest: APIRequest<API.ChatSpaceSourceList> {
        API.listChatSpaceSources(spaceId: spaceId)
    }

    private var reposRequest: APIRequest<API.ListChatSpaceRepositoriesResponse> {
        API.listChatSpaceRepositories(spaceId: spaceId)
    }

    private var knowledgeRequest: APIRequest<API.ListChatSpaceKnowledgeLinksResponse> {
        API.listChatSpaceKnowledgeLinks(spaceId: spaceId)
    }

    private var tasksRequest: APIRequest<API.ListChatSpaceTasksResponse> {
        API.listChatSpaceTasks(spaceId: spaceId)
    }

    private var branchesRequest: APIRequest<API.ListChatSpaceBranchesResponse> {
        API.listChatSpaceBranches(spaceId: spaceId)
    }

    private var chatsRequest: APIRequest<API.ListChatsResponse> {
        SpacesLogic.spaceChatsRequest(spaceId: spaceId)
    }

    var body: some View {
        let p = theme.palette
        let spaceEntry = context.store.entry(spaceRequest)
        let space = spaceEntry.data
        let sourcesData = context.store.entry(sourcesRequest).data
        let sources = sourcesData?.sources ?? []
        let repos = context.store.entry(reposRequest).data?.repositories ?? []
        let knowledgeLinks = context.store.entry(knowledgeRequest).data?.links ?? []
        let tasks = context.store.entry(tasksRequest).data?.tasks ?? []
        let branches = context.store.entry(branchesRequest).data?.branches ?? []
        let chatsEntry = context.store.entry(chatsRequest)
        let personasList = context.store.entry(Self.personasRequest).data
        let personas = personasList?.personas ?? []
        let models = context.store.entry(Self.modelsRequest).data ?? []
        let spaces = context.store.entry(Self.spacesRequest).data?.spaces ?? []
        let spaceChats = chatsEntry.data?.chats ?? []

        Group {
            if let error = spaceEntry.error, space == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Couldn\u{2019}t open this space")
                        .vesperText(.heading, theme)
                    Text(error.userMessage)
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                    Button("Back to Chat") { context.navigate("/chat") }
                        .buttonStyle(.bordered)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let space {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        headerSection(space: space, p: p)

                        composerCard(
                            space: space,
                            personas: personas,
                            defaultPersonaId: personasList?.defaultPersonaId,
                            models: models,
                            repos: repos,
                            knowledgeLinks: knowledgeLinks,
                            p: p
                        )

                        let runningChats = SpacesLogic.inFlightChats(spaceChats)
                        let activeBranches = SpacesLogic.activeBranches(branches)
                        if !runningChats.isEmpty || !activeBranches.isEmpty {
                            inFlightSection(runningChats: runningChats, branches: activeBranches, p: p)
                        }

                        tasksSection(space: space, tasks: tasks, p: p)

                        chatsSection(
                            space: space,
                            chatsEntry: chatsEntry,
                            p: p
                        )
                    }
                    .frame(maxWidth: 960, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                .sheet(isPresented: $showSourcesSheet) {
                    SpaceSourcesSheet(spaceId: space.id, spaceName: space.name)
                        .environment(context)
                        .environment(\.vesperTheme, theme)
                }
                .alert("Delete \(space.name)?", isPresented: $showDeleteAlert) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete space", role: .destructive) {
                        deleteSpace(space)
                    }
                } message: {
                    Text("Its instructions, \(space.sourceCount) \(space.sourceCount == 1 ? "source" : "sources") and \(space.memoryCount) \(space.memoryCount == 1 ? "memory" : "memories") are deleted. Its \(space.chatCount) \(space.chatCount == 1 ? "chat moves" : "chats move") to Recent.")
                }
            } else {
                ProgressView("Loading space\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: spaceId) {
            editing = false
            showAllChats = false
            skipReposForChat = false
            syncWatches()
            installInspectorView(space: space)
        }
        .onChange(of: chromeFingerprint(space: space, sources: sources, reposCount: repos.count, linksCount: knowledgeLinks.count, branchesCount: branches.count, activeBranchesCount: SpacesLogic.activeBranches(branches).count, personasCount: personas.count, spacesCount: spaces.count, chatsCount: spaceChats.count)) { _, _ in
            publishChrome(
                space: space,
                repos: repos,
                branches: branches,
                personas: personas,
                spaces: spaces,
                chats: spaceChats
            )
        }
        .onAppear {
            publishChrome(
                space: space,
                repos: repos,
                branches: branches,
                personas: personas,
                spaces: spaces,
                chats: spaceChats
            )
            installCommands(space: space)
            installInspectorView(space: space)
        }
        .onChange(of: space?.id) { _, _ in
            installCommands(space: space)
            installInspectorView(space: space)
        }
        .onDisappear {
            context.onCommand = nil
            context.inspectorView = nil
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    // MARK: - Header & Edit Form

    @ViewBuilder
    private func headerSection(space: API.ChatSpace, p: NativePalette) -> some View {
        if editing {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    spaceTile(name: editName.isEmpty ? space.name : editName, color: editColor, size: 36)
                    TextField("Space name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 16, weight: .semibold))
                }

                HStack(spacing: 6) {
                    ForEach(API.ChatSpaceColor.allKnown, id: \.rawValue) { c in
                        Button {
                            editColor = c
                        } label: {
                            Circle()
                                .fill(Color(cssHex: SpacesLogic.colorHex(for: c)) ?? .green)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: editColor == c ? 2 : 0)
                                        .padding(-2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(SpacesLogic.colorLabel(for: c))
                    }
                }

                TextField("What this space is for", text: $editDescription)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Instructions").font(.caption).foregroundStyle(p.secondaryText)
                        Spacer()
                        Text("\(editInstructions.count) / \(SpacesLogic.maxInstructions)")
                            .font(.caption2)
                            .foregroundStyle(p.tertiaryText)
                    }
                    TextEditor(text: $editInstructions)
                        .font(.system(size: 13))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }

                if let editError {
                    Text(editError)
                        .font(.caption)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }

                HStack(spacing: 8) {
                    Button(savingEdit ? "Saving\u{2026}" : "Save") {
                        saveEdits(space: space)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(savingEdit || editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") { editing = false }
                        .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
        } else {
            HStack(alignment: .top, spacing: 12) {
                spaceTile(name: space.name, color: space.color, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(space.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Text(SpacesLogic.subtitle(for: space))
                        .font(.system(size: 13))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    // MARK: - Inline Composer

    private func composerCard(
        space: API.ChatSpace,
        personas: [API.Persona],
        defaultPersonaId: String?,
        models: [API.ChatHarnessModels],
        repos: [API.ChatSpaceRepository],
        knowledgeLinks: [API.ChatSpaceKnowledgeLink],
        p: NativePalette
    ) -> some View {
        let effectivePersonaId = pickedPersonaId ?? space.personaId ?? defaultPersonaId
        let activePersona = personas.first(where: { $0.id == effectivePersonaId }) ?? personas.first

        return VStack(alignment: .leading, spacing: 8) {
            if !repos.isEmpty || !knowledgeLinks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if !repos.isEmpty {
                            Button {
                                skipReposForChat.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                                        .font(.system(size: 9.5))
                                    Text(skipReposForChat
                                        ? "Repos skipped"
                                        : repos.map { ChatCodeReviewLogic.repoName($0.repoUrl) }.joined(separator: ", "))
                                        .font(.system(size: 11))
                                        .strikethrough(skipReposForChat)
                                }
                                .foregroundStyle(skipReposForChat ? p.tertiaryText : p.secondaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(p.surface, in: Capsule())
                                .overlay(Capsule().stroke(p.border))
                            }
                            .buttonStyle(.plain)
                            .help(skipReposForChat ? "Click to include Space repos" : "Click to skip repos for a brainstorm chat")
                        }
                        ForEach(knowledgeLinks.prefix(3), id: \.id) { link in
                            HStack(spacing: 4) {
                                Image(systemName: link.kind == .folder ? "folder" : "doc.text")
                                    .font(.system(size: 9.5))
                                Text(link.kind == .folder ? "\(link.path)/" : link.path)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(p.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(p.surface, in: Capsule())
                            .overlay(Capsule().stroke(p.border))
                        }
                    }
                }
            }

            ChatComposerSlot(
                chatId: nil,
                session: nil,
                personas: personas,
                activePersona: activePersona,
                harnessModels: models,
                harnesses: [],
                workflows: [],
                repositories: [],
                selectedHarness: $pickedHarness,
                selectedModel: $pickedModel,
                selectedEffort: $pickedEffort,
                selectedRepoUrl: $pickedRepoUrl,
                onSelectNewChatPersona: { id in pickedPersonaId = id },
                onSend: { submission in
                    await sendFromSpaceComposer(space: space, submission: submission)
                },
                onCancel: {},
                onSetRepository: { repoUrl in
                    pickedRepoUrl = repoUrl
                    return nil
                },
                onCompact: { _ in nil },
                onStartWorkflow: { _, _ in nil },
                onStartMusic: { _ in nil },
                onCompare: { _, _ in nil },
                onStartLiveVoice: {
                    context.navigate("/chat")
                },
                inline: true,
                placeholderOverride: "New chat in \(space.name)"
            )

            if let composerError {
                Text(composerError)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            } else {
                Text(SpacesLogic.usesSummary(for: space))
                    .font(.system(size: 12))
                    .foregroundStyle(p.tertiaryText)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - In Flight

    private func inFlightSection(
        runningChats: [API.ChatSession],
        branches: [API.ChatSpaceBranch],
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("In Flight")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
                if !branches.isEmpty {
                    Button {
                        syncBranches()
                    } label: {
                        HStack(spacing: 4) {
                            if syncingBranches {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10.5))
                            }
                            Text(syncingBranches ? "Checking PRs\u{2026}" : "Refresh PRs")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(p.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(syncingBranches)
                    .help("Check GitHub for merged or closed pull requests")
                }
            }

            VStack(spacing: 6) {
                ForEach(runningChats, id: \.id) { chat in
                    Button {
                        context.navigate("/chat/\(chat.id)")
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(chat.state == .running
                                    ? theme.swiftUIColor("state-done", fallback: .green)
                                    : theme.swiftUIColor("state-human", fallback: .purple))
                                .frame(width: 7, height: 7)
                            Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            Spacer()
                            Text(chat.state == .running ? "Running" : "\(chat.unread) unread")
                                .font(.system(size: 11))
                                .foregroundStyle(p.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(branches.prefix(6), id: \.spaceBranchKey) { b in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(p.accent)
                        Text(b.branch)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Text(ChatCodeReviewLogic.repoName(b.repoUrl))
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                        Text(SpacesLogic.branchStatusLabel(for: b))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(p.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(p.background, in: Capsule())
                            .overlay(Capsule().stroke(p.border))
                        Spacer()
                        if let prUrl = b.prUrl, !prUrl.isEmpty {
                            Button(b.prNumber.map { "PR #\($0) \u{2197}" } ?? "PR \u{2197}") {
                                context.openExternal(prUrl)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.accent)
                        }
                        Button("Chat \u{2192}") { context.navigate("/chat/\(b.chatId)") }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
            }
        }
    }

    // MARK: - Optional Flat Tasks

    private func tasksSection(space: API.ChatSpace, tasks: [API.ChatSpaceTask], p: NativePalette) -> some View {
        let openCount = tasks.filter { !$0.done }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                if openCount > 0 {
                    Text("\(openCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer()
                Button {
                    showTasksComposer.toggle()
                } label: {
                    Label(showTasksComposer ? "Done" : "Add task", systemImage: showTasksComposer ? "checkmark" : "plus")
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if showTasksComposer {
                HStack(spacing: 8) {
                    TextField("Add a task for \(space.name)\u{2026}", text: $newTaskTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit { createTask(space: space) }
                    Button(addingTask ? "Adding\u{2026}" : "Add") { createTask(space: space) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(addingTask || newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !tasks.isEmpty {
                VStack(spacing: 0) {
                    ForEach(tasks, id: \.id) { task in
                        HStack(spacing: 10) {
                            Button {
                                toggleTask(space: space, task: task)
                            } label: {
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(task.done ? p.accent : p.tertiaryText)
                            }
                            .buttonStyle(.plain)

                            Text(task.title)
                                .font(.system(size: 13))
                                .foregroundStyle(task.done ? p.tertiaryText : p.text)
                                .strikethrough(task.done)
                                .lineLimit(2)

                            Spacer(minLength: 8)

                            if let cid = task.chatId, !cid.isEmpty {
                                Button("Open chat") { context.navigate("/chat/\(cid)") }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.accent)
                            } else if !task.done {
                                Button("Start chat \u{2192}") {
                                    startTaskChat(space: space, task: task)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(p.secondaryText)
                            }

                            Button {
                                deleteTask(space: space, taskId: task.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - Chat List

    private func chatsSection(
        space: API.ChatSpace,
        chatsEntry: QueryEntry<API.ListChatsResponse>,
        p: NativePalette
    ) -> some View {
        let sorted = SpacesLogic.sortChats(chatsEntry.data?.chats ?? [], sort: chatSort)
        let visible = showAllChats ? sorted : Array(sorted.prefix(SpacesLogic.pageChatsLimit))
        let remaining = sorted.count - visible.count

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
                Picker("Sort", selection: $chatSort) {
                    ForEach(SpacesLogic.ChatSort.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            .padding(.bottom, 10)

            Divider()

            if let error = chatsEntry.error {
                Text("Couldn\u{2019}t load chats: \(error.userMessage)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    .padding(.vertical, 14)
            } else if chatsEntry.data == nil && chatsEntry.isFetching {
                ProgressView().controlSize(.small).padding(.vertical, 16)
            } else if sorted.isEmpty {
                Text("No chats in \(space.name) yet. Start one above.")
                    .font(.system(size: 13))
                    .foregroundStyle(p.secondaryText)
                    .padding(.vertical, 18)
            } else {
                ForEach(visible, id: \.id) { chat in
                    Button {
                        context.navigate("/chat/\(chat.id)")
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if chat.state == .running {
                                        Circle()
                                            .fill(theme.swiftUIColor("state-done", fallback: .green))
                                            .frame(width: 6, height: 6)
                                    }
                                    Text(chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : chat.title)
                                        .font(.system(size: 14))
                                        .foregroundStyle(p.text)
                                        .lineLimit(1)
                                }
                                Text(chat.preview ?? "No replies yet")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(APIDate.shortAgo(chat.lastMessageAt ?? chat.createdAt))
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                            WorkPersonaAvatarView(
                                id: chat.persona?.id,
                                handle: nil,
                                name: chat.persona?.name ?? "Assistant",
                                size: 18,
                                active: false
                            )
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if remaining > 0 {
                    Button("Show \(remaining) more") {
                        showAllChats = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(p.accent)
                    .padding(.top, 12)
                }
            }
        }
    }

    private func spaceTile(name: String, color: API.ChatSpaceColor, size: CGFloat) -> some View {
        let bg = Color(cssHex: SpacesLogic.colorHex(for: color)) ?? .green
        return Text(SpacesLogic.initial(for: name))
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Chrome & Mutations

    private func chromeFingerprint(
        space: API.ChatSpace?,
        sources: [API.ChatSpaceSource],
        reposCount: Int,
        linksCount: Int,
        branchesCount: Int,
        activeBranchesCount: Int,
        personasCount: Int,
        spacesCount: Int,
        chatsCount: Int
    ) -> String {
        "\(space?.id ?? "")|\(space?.name ?? "")|\(space?.instructions.count ?? 0)|\(space?.spaceMemory ?? false)|\(space?.personaId ?? "")|\(space?.sourceCount ?? 0)|\(sources.count)|\(reposCount)|\(linksCount)|\(branchesCount)|\(activeBranchesCount)|\(personasCount)|\(spacesCount)|\(chatsCount)|\(editing)|\(inspectorOpen)|\(inspectorTabId)"
    }

    private func publishChrome(
        space: API.ChatSpace?,
        repos: [API.ChatSpaceRepository],
        branches: [API.ChatSpaceBranch],
        personas: [API.Persona],
        spaces: [API.ChatSpace],
        chats: [API.ChatSession]
    ) {
        let nav = SpacesLogic.navModel(
            spaces: spaces,
            activeSpaceId: spaceId.isEmpty ? nil : spaceId,
            chats: chats,
            personas: personas,
            origin: context.baseURL()
        )
        guard let space else {
            context.chrome = NativeChrome(title: "Space", navigator: nav)
            return
        }

        let toolbar: [ShellToolbarItem] = editing ? [] : [
            ShellToolbarItem(id: "space.settings", label: "Edit", icon: "gear", kind: .button, showsLabel: true),
            ShellToolbarItem(
                id: "space.more",
                label: "More for this space",
                icon: "dots",
                kind: .menu,
                menu: [
                    MenuItem(id: "space.sources", label: "Manage sources", icon: "artifacts"),
                    MenuItem(id: "space.delete", label: "Delete space\u{2026}", icon: "trash", destructive: true),
                ]
            ),
        ]

        var tabs: [InspectorTab] = [
            InspectorTab(id: "context", label: "Context", icon: "sidebar", kind: .native),
        ]
        let activeBranchesCount = SpacesLogic.activeBranches(branches).count
        if !repos.isEmpty || !branches.isEmpty {
            tabs.append(InspectorTab(
                id: "branches",
                label: "Branches",
                icon: "branch",
                kind: .native,
                badge: activeBranchesCount == 0 ? nil : NavBadge(text: "\(activeBranchesCount)")
            ))
        }
        tabs.append(InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion))

        let inspector = InspectorModel(
            id: "space:\(space.id)",
            open: inspectorOpen,
            activeTabId: tabs.contains(where: { $0.id == inspectorTabId }) ? inspectorTabId : "context",
            tabs: tabs,
            companion: CompanionContext(path: "/spaces/\(space.id)")
        )

        context.chrome = NativeChrome(
            title: space.name,
            toolbarItems: toolbar,
            inspector: inspector,
            navigator: nav
        )
    }

    private func installInspectorView(space: API.ChatSpace?) {
        let currentSpaceId = spaceId
        let currentTheme = theme
        let ctx = context
        ctx.inspectorView = { tabId in
            guard tabId == "context" || tabId == "branches", !currentSpaceId.isEmpty else { return nil }
            return AnyView(
                SpaceContextInspectorView(
                    spaceId: currentSpaceId,
                    tabId: tabId,
                    onEditSpace: { if let space { beginEditing(space) } },
                    onManageSources: { showSourcesSheet = true }
                )
                .environment(ctx)
                .environment(\.vesperTheme, currentTheme)
            )
        }
    }

    private func installCommands(space: API.ChatSpace?) {
        context.onCommand = { cmd in
            if let navAction = SpacesLogic.navAction(for: cmd) {
                switch navAction {
                case .newSpace: context.navigate("/spaces/new")
                case .openSpace(let id, let newTab):
                    if newTab { context.openInNewTab("/spaces/\(id)") } else { context.navigate("/spaces/\(id)") }
                case .openChat(let id, let newTab):
                    if newTab { context.openInNewTab("/chat/\(id)") } else { context.navigate("/chat/\(id)") }
                }
                return
            }
            switch cmd {
            case .inspectorVisibility(let open):
                inspectorOpen = open
            case .inspectorSelectTab(let tabId):
                inspectorTabId = tabId
                inspectorOpen = true
            case .toolbarAction(let itemId, let menuItemId):
                if itemId == "space.settings" {
                    if let space { beginEditing(space) }
                } else if menuItemId == "space.sources" {
                    showSourcesSheet = true
                } else if menuItemId == "space.delete" {
                    showDeleteAlert = true
                }
            default:
                break
            }
        }
    }

    private func beginEditing(_ space: API.ChatSpace) {
        editName = space.name
        editDescription = space.description
        editInstructions = space.instructions
        editColor = space.color
        editError = nil
        editing = true
    }

    private func saveEdits(space: API.ChatSpace) {
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        savingEdit = true
        editError = nil
        Task {
            defer { savingEdit = false }
            do {
                let updated = try await context.store.mutate(
                    API.updateChatSpace(
                        spaceId: space.id,
                        body: API.ChatSpacePatch(
                            color: editColor,
                            description: editDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                            instructions: editInstructions.trimmingCharacters(in: .whitespacesAndNewlines),
                            name: name
                        )
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                context.store.setData(updated, for: spaceRequest)
                editing = false
            } catch {
                editError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func deleteSpace(_ space: API.ChatSpace) {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpace(spaceId: space.id),
                    invalidating: QueryInvalidation(resources: ["spaces", "chats"])
                )
                context.navigate("/spaces")
            } catch {
                context.showToast(ToastItemModel(id: "space.del", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    @MainActor
    private func sendFromSpaceComposer(space: API.ChatSpace, submission: ChatComposerSubmission) async -> String? {
        let body = submission.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!body.isEmpty || !submission.attachmentIds.isEmpty), !startingChat else { return nil }
        startingChat = true
        composerError = nil
        defer { startingChat = false }
        do {
            let created = try await context.store.mutate(
                API.createChat(body: API.NewChat(
                    effort: pickedEffort,
                    harness: pickedHarness,
                    model: pickedModel,
                    noRepo: skipReposForChat ? true : nil,
                    personaId: pickedPersonaId,
                    repoUrl: pickedRepoUrl,
                    spaceId: space.id
                )),
                invalidating: QueryInvalidation(resources: ["chats", "spaces"])
            )
            _ = try await context.store.mutate(
                API.postChatMessage(
                    id: created.id,
                    body: API.NewChatMessage(
                        attachmentIds: submission.attachmentIds.isEmpty ? nil : submission.attachmentIds,
                        body: body,
                        contextRefs: submission.contextRefs,
                        research: submission.research ? true : nil
                    )
                ),
                invalidating: QueryInvalidation(resources: ["chats", "spaces"])
            )
            context.navigate("/chat/\(created.id)")
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func startSpaceChat(space: API.ChatSpace, taskId: String? = nil, initialBody: String) {
        let body = initialBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !startingChat else { return }
        startingChat = true
        composerError = nil
        Task {
            defer { startingChat = false }
            do {
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        effort: pickedEffort,
                        harness: pickedHarness,
                        model: pickedModel,
                        noRepo: skipReposForChat ? true : nil,
                        personaId: pickedPersonaId,
                        repoUrl: pickedRepoUrl,
                        spaceId: space.id,
                        taskId: taskId
                    )),
                    invalidating: QueryInvalidation(resources: ["chats", "spaces"])
                )
                _ = try await context.store.mutate(
                    API.postChatMessage(
                        id: created.id,
                        body: API.NewChatMessage(body: body)
                    ),
                    invalidating: QueryInvalidation(resources: ["chats", "spaces"])
                )
                context.navigate("/chat/\(created.id)")
            } catch {
                composerError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func startTaskChat(space: API.ChatSpace, task: API.ChatSpaceTask) {
        startSpaceChat(space: space, taskId: task.id, initialBody: task.title)
    }

    private func createTask(space: API.ChatSpace) {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !addingTask else { return }
        addingTask = true
        Task {
            defer { addingTask = false }
            do {
                _ = try await context.store.mutate(
                    API.createChatSpaceTask(spaceId: space.id, body: API.NewChatSpaceTask(title: title)),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                newTaskTitle = ""
            } catch {
                context.showToast(ToastItemModel(id: "space.task.add", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func toggleTask(space: API.ChatSpace, task: API.ChatSpaceTask) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.updateChatSpaceTask(spaceId: space.id, taskId: task.id, body: API.ChatSpaceTaskPatch(done: !task.done)),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.task.toggle", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func deleteTask(space: API.ChatSpace, taskId: String) {
        Task {
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpaceTask(spaceId: space.id, taskId: taskId),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "space.task.del", title: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func syncBranches() {
        guard !syncingBranches, !spaceId.isEmpty else { return }
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

    private func syncWatches() {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        if !spaceId.isEmpty {
            watch(spaceRequest)
            watch(sourcesRequest)
            watch(reposRequest)
            watch(knowledgeRequest)
            watch(tasksRequest)
            watch(branchesRequest)
            watch(chatsRequest)
        }
        watch(Self.personasRequest)
        watch(Self.modelsRequest)
        watch(Self.spacesRequest)
    }
}

/// Sources management modal for a Space: upload files, paste text, add websites, and remove sources.
private struct SpaceSourcesSheet: View {
    enum AddMode { case list, text, website, library, link, canvas }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let spaceId: String
    let spaceName: String

    @State private var mode: AddMode = .list
    @State private var titleInput = ""
    @State private var textInput = ""
    @State private var urlInput = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private static let libraryRequest = API.listLibraryItems()
    private static let savedLinksRequest = API.listLibraryItems(kind: .link)
    private static let canvasesRequest = API.listMyCanvases()

    private var sourcesRequest: APIRequest<API.ChatSpaceSourceList> {
        API.listChatSpaceSources(spaceId: spaceId)
    }

    var body: some View {
        let p = theme.palette
        let data = context.store.entry(sourcesRequest).data
        let sources = data?.sources ?? []

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(spaceName) sources")
                    .font(.headline)
                Spacer()
                if let data {
                    Text("\(SpacesLogic.formatTokens(data.inlineTokens)) / \(SpacesLogic.formatTokens(data.inlineBudget)) inline")
                        .font(.caption.monospaced())
                        .foregroundStyle(p.tertiaryText)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if mode == .list {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button { uploadFile() } label: {
                            Label("Upload file", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)

                        Button {
                            mode = .text
                            titleInput = ""
                            textInput = ""
                            errorMessage = nil
                        } label: {
                            Label("Paste text", systemImage: "text.alignleft")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)

                        Button {
                            mode = .website
                            urlInput = ""
                            errorMessage = nil
                        } label: {
                            Label("Add website", systemImage: "globe")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    }

                    HStack(spacing: 8) {
                        Button {
                            mode = .library
                            errorMessage = nil
                            context.store.load(Self.libraryRequest)
                        } label: {
                            Label("From Library", systemImage: "books.vertical")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)

                        Button {
                            mode = .link
                            errorMessage = nil
                            context.store.load(Self.savedLinksRequest)
                        } label: {
                            Label("From saved links", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)

                        Button {
                            mode = .canvas
                            errorMessage = nil
                            context.store.load(Self.canvasesRequest)
                        } label: {
                            Label("From a canvas", systemImage: "square.on.square")
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }

                Divider()

                if sources.isEmpty {
                    Text("No sources yet. Upload files, paste notes, or add websites for every chat in this space.")
                        .font(.callout)
                        .foregroundStyle(p.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sources, id: \.id) { s in
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(SpacesLogic.sourceName(s))
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text(SpacesLogic.sourceDetail(s))
                                            .font(.system(size: 11))
                                            .foregroundStyle(p.tertiaryText)
                                    }
                                    Spacer()
                                    Text(s.delivery == .inline ? "Inline" : "Searched")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(s.delivery == .inline ? theme.swiftUIColor("state-done", fallback: .green) : p.accent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(p.surface, in: Capsule())
                                        .overlay(Capsule().stroke(p.border))
                                    if let url = s.url, !url.isEmpty {
                                        Button { context.openExternal(url) } label: {
                                            Image(systemName: "arrow.up.right.square").font(.system(size: 12))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Open URL")
                                    }
                                    Button {
                                        removeSource(s.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(busy)
                                }
                                .padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 200, maxHeight: 340)
                }
            } else if mode == .text {
                TextField("Title", text: $titleInput).textFieldStyle(.roundedBorder)
                TextEditor(text: $textInput)
                    .font(.system(size: 13))
                    .frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                HStack {
                    Button("Back") { mode = .list }
                    Spacer()
                    Button(busy ? "Adding\u{2026}" : "Add text source") {
                        addTextSource()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if mode == .website {
                TextField("https://example.com/guide", text: $urlInput).textFieldStyle(.roundedBorder)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                HStack {
                    Button("Back") { mode = .list }
                    Spacer()
                    Button(busy ? "Fetching\u{2026}" : "Add website") {
                        addWebsiteSource()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if mode == .library || mode == .link {
                let isLinks = mode == .link
                let entry = context.store.entry(isLinks ? Self.savedLinksRequest : Self.libraryRequest)
                let items = (entry.data?.items ?? []).filter { isLinks ? $0.kind == .link : $0.kind != .link }
                pickerListView(
                    title: isLinks ? "From saved links" : "From Library",
                    loading: entry.data == nil && entry.isFetching,
                    isEmpty: items.isEmpty,
                    emptyText: isLinks ? "No saved links yet." : "Nothing in your Library yet.",
                    p: p
                ) {
                    ForEach(items, id: \.id) { item in
                        Button {
                            addLibraryOrLinkSource(itemId: item.id, kind: isLinks ? .link : .library)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isLinks ? "link" : "doc")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.secondaryText)
                                Text(item.title.isEmpty ? item.filename : item.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(isLinks ? (item.site ?? item.url ?? "link") : item.kind.rawValue)
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        Divider()
                    }
                }
            } else if mode == .canvas {
                let entry = context.store.entry(Self.canvasesRequest)
                let canvases = entry.data?.canvases ?? []
                pickerListView(
                    title: "From a canvas",
                    loading: entry.data == nil && entry.isFetching,
                    isEmpty: canvases.isEmpty,
                    emptyText: "No canvases yet.",
                    p: p
                ) {
                    ForEach(canvases, id: \.id) { canvas in
                        Button {
                            addCanvasSource(canvasId: canvas.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.on.square")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.secondaryText)
                                Text(canvas.title.isEmpty ? "Untitled canvas" : canvas.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                Spacer()
                                Text(canvas.kind.rawValue)
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { context.store.load(sourcesRequest) }
    }

    @ViewBuilder
    private func pickerListView<Content: View>(
        title: String,
        loading: Bool,
        isEmpty: Bool,
        emptyText: String,
        p: NativePalette,
        @ViewBuilder rows: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(p.text)
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(p.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        rows()
                    }
                }
                .frame(minHeight: 180, maxHeight: 300)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
            HStack {
                Button("Back") { mode = .list }
                    .disabled(busy)
                Spacer()
                if busy {
                    Text("Adding\u{2026}")
                        .font(.caption)
                        .foregroundStyle(p.tertiaryText)
                }
            }
        }
    }

    private func addTextSource() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceSource(
                        spaceId: spaceId,
                        body: API.NewChatSpaceSource(kind: .text, text: text, title: title.isEmpty ? "Notes" : title)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
                mode = .list
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func addWebsiteSource() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceSource(
                        spaceId: spaceId,
                        body: API.NewChatSpaceSource(kind: .website, url: url)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
                mode = .list
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func addLibraryOrLinkSource(itemId: String, kind: API.NewChatSpaceSource.Kind) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceSource(
                        spaceId: spaceId,
                        body: API.NewChatSpaceSource(itemId: itemId, kind: kind)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
                mode = .list
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func addCanvasSource(canvasId: String) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.addChatSpaceSource(
                        spaceId: spaceId,
                        body: API.NewChatSpaceSource(canvasId: canvasId, kind: .canvas)
                    ),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
                mode = .list
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .plainText, .commaSeparatedText, .json, .png, .jpeg, .gif, .webP]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn\u{2019}t read selected file."
            return
        }
        var form = APIMultipartForm()
        let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        form.addFile("file", filename: url.lastPathComponent, contentType: contentType, data: data)
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.uploadChatSpaceSource(spaceId: spaceId, body: form),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func removeSource(_ sourceId: String) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.deleteChatSpaceSource(spaceId: spaceId, sourceId: sourceId),
                    invalidating: QueryInvalidation(resources: ["spaces"])
                )
                _ = await context.store.refetch(sourcesRequest)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
