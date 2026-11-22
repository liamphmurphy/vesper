import SwiftUI
import VesperCore

@MainActor
@Observable
final class ChatScreenModel {
    private static let pinnedDefaultsKey = "VesperNativeChatPinnedIds"

    var viewMode: ChatNav.ViewMode = .active
    var searchQuery = ""
    var selectedSpaceId = ""
    var selectedPersonaId = ""
    var newChatPersonaId: String?
    var selectedHarness: API.Harness?
    var selectedModel: String?
    var selectedEffort: API.ChatEffort?
    var selectedRepoUrl: String?
    var pinnedIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(pinnedIds).sorted(), forKey: Self.pinnedDefaultsKey)
        }
    }

    var renameTargetId: String?
    var renameDraft = ""
    var deleteTargetId: String?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.pinnedDefaultsKey) ?? []
        self.pinnedIds = Set(saved)
    }

    func togglePin(_ id: String, pinned: Bool) {
        if pinned { pinnedIds.insert(id) } else { pinnedIds.remove(id) }
    }
}

/// Native `/chat` and `/chat/:id` screen.
/// Publishes `ChatNav` to the shell sidebar, hosts the conversation header, `ChatTranscriptView`,
/// and `ChatComposerSlot` (full native glass composer).
struct ChatScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var model = ChatScreenModel()
    @State private var watched: [QueryKey] = []

    private static let personasRequest = API.listPersonas()
    private static let spacesRequest = API.listChatSpaces()
    private static let modelsRequest = API.listChatModels()
    private static let suggestionsRequest = API.listChatSuggestions()
    private static let dockRequest = API.getPersonaDock()
    private static let workflowsRequest = API.listWorkflows()
    private static let repositoriesRequest = API.searchRepositories()

    private var chatId: String? {
        context.match.params["id"]
    }

    private var ticketRunsRequest: APIRequest<API.ChatTicketRuns>? {
        chatId.map { API.listChatTicketRuns(id: $0) }
    }

    private var chatsRequest: APIRequest<API.ListChatsResponse> {
        API.listChats(
            archived: model.viewMode == .archived ? true : nil,
            personaId: model.selectedPersonaId.isEmpty ? nil : model.selectedPersonaId,
            space: model.selectedSpaceId.isEmpty ? nil : model.selectedSpaceId
        )
    }

    private var sessionRequest: APIRequest<API.ChatSession>? {
        chatId.map { API.getChat(id: $0) }
    }

    private var searchRequest: APIRequest<API.ChatSearchResults>? {
        let trimmed = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        return API.searchChats(q: trimmed)
    }

    var body: some View {
        let store = context.store
        let personas = store.entry(Self.personasRequest).data?.personas ?? []
        let spaces = store.entry(Self.spacesRequest).data?.spaces ?? []
        let harnessModels = store.entry(Self.modelsRequest).data ?? []
        let suggestions = store.entry(Self.suggestionsRequest).data?.suggestions ?? []
        let harnesses = store.entry(Self.dockRequest).data?.harnesses ?? []
        let workflows = store.entry(Self.workflowsRequest).data?.workflows ?? []
        let repositories = store.entry(Self.repositoriesRequest).data ?? []
        let ticketRuns = (ticketRunsRequest.flatMap { store.entry($0).data?.runs } ?? []).filter {
            ["queued", "starting", "running", "waiting"].contains($0.state)
        }
        let chatsEntry = store.entry(chatsRequest)
        let chats = chatsEntry.data?.chats ?? []
        let session = sessionRequest.flatMap { store.entry($0).data }
        let searchEntry = searchRequest.map { store.entry($0) }
        let activePersona = resolvedPersona(session: session, personas: personas)

        VStack(spacing: 0) {
            headerBar(
                session: session,
                personas: personas,
                activePersona: activePersona,
                harnessModels: harnessModels
            )
            Divider()

            if let chatId {
                ChatTranscriptView(
                    chatId: chatId,
                    session: session,
                    knownPersonaNames: personas.map(\.name),
                    onSendReply: { body in
                        Task { _ = await sendMessage(body, activePersona: activePersona) }
                    }
                )
            } else {
                emptyChatView(
                    personas: personas,
                    activePersona: activePersona,
                    suggestions: suggestions
                )
            }

            ChatComposerSlot(
                chatId: chatId,
                session: session,
                personas: personas,
                activePersona: activePersona,
                harnessModels: harnessModels,
                harnesses: harnesses,
                workflows: workflows,
                repositories: repositories,
                activeTicketRuns: ticketRuns,
                selectedHarness: $model.selectedHarness,
                selectedModel: $model.selectedModel,
                selectedEffort: $model.selectedEffort,
                selectedRepoUrl: $model.selectedRepoUrl,
                onSelectNewChatPersona: { id in model.newChatPersonaId = id },
                onSend: { submission in
                    await submitFromComposer(submission, activePersona: activePersona)
                },
                onCancel: {
                    await cancelActiveTurn()
                },
                onSetRepository: { repoUrl in
                    await setChatRepository(repoUrl)
                },
                onCompact: { focus in
                    await compactChat(focus: focus)
                },
                onStartWorkflow: { workflowId, input in
                    await startChatWorkflow(workflowId: workflowId, input: input)
                },
                onStartMusic: { prompt in
                    await startChatMusic(prompt: prompt)
                },
                onCompare: { option, question in
                    await startCompareAside(option: option, question: question)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(
            of: buildChrome(
                chats: chats,
                chatsError: chatsEntry.error?.userMessage,
                session: session,
                spaces: spaces,
                personas: personas,
                searchEntry: searchEntry
            ),
            initial: true
        ) { _, next in
            context.chrome = next
        }
        .task(id: watchKey) { watch() }
        .task(id: "\(chatId ?? "")|\(session?.unread ?? 0)|\(session?.messageCount ?? 0)") {
            await markReadIfNeeded(session: session)
        }
        .onAppear {
            if context.match.query["view"] == "archived" {
                model.viewMode = .archived
            }
            installCommandHandler()
        }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
        .sheet(isPresented: Binding(
            get: { model.renameTargetId != nil },
            set: { if !$0 { model.renameTargetId = nil } }
        )) {
            renameSheet(chats: chats)
        }
        .alert(
            "Delete conversation?",
            isPresented: Binding(
                get: { model.deleteTargetId != nil },
                set: { if !$0 { model.deleteTargetId = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let id = model.deleteTargetId {
                    model.deleteTargetId = nil
                    deleteChat(id: id)
                }
            }
            Button("Cancel", role: .cancel) { model.deleteTargetId = nil }
        } message: {
            Text("This permanently deletes the conversation and its messages.")
        }
    }

    // MARK: - Header Bar

    private func headerBar(
        session: API.ChatSession?,
        personas: [API.Persona],
        activePersona: API.Persona?,
        harnessModels: [API.ChatHarnessModels]
    ) -> some View {
        let p = theme.palette
        let participants = session?.participants ?? []

        return HStack(spacing: 10) {
            if let session {
                WorkPersonaAvatarView(
                    id: session.persona?.id,
                    handle: nil,
                    name: session.persona?.name ?? session.agent.name,
                    size: 22
                )
                Text(ChatNav.chatTitle(session.title))
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .lineLimit(1)

                if participants.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(participants, id: \.id) { participant in
                            TonePill(label: "@\(participant.name)", tone: "neutral")
                        }
                    }
                }
            } else {
                Text("New conversation")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                if !personas.isEmpty {
                    Picker("Persona", selection: Binding(
                        get: { model.newChatPersonaId ?? activePersona?.id ?? "" },
                        set: { model.newChatPersonaId = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(personas, id: \.id) { persona in
                            Text(persona.name).tag(persona.id)
                        }
                    }
                    .frame(maxWidth: 170)
                }
            }

            Spacer(minLength: 8)

            modelMenu(session: session, harnessModels: harnessModels)

            Button {
                context.navigate("/chat")
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.vesper())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(p.background)
    }

    @ViewBuilder
    private func modelMenu(session: API.ChatSession?, harnessModels: [API.ChatHarnessModels]) -> some View {
        let available = harnessModels.filter { $0.available && !$0.models.isEmpty }
        if !available.isEmpty {
            let currentLabel = model.selectedModel ?? session?.model ?? "Default model"
            Menu {
                Button("Default model") {
                    model.selectedHarness = nil
                    model.selectedModel = nil
                }
                Divider()
                ForEach(available, id: \.harness.rawValue) { group in
                    Section(group.label) {
                        ForEach(group.models, id: \.id) { item in
                            Button(item.label) {
                                model.selectedHarness = group.harness
                                model.selectedModel = item.id
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .imageScale(.small)
                    Text(currentLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - Empty / Start State

    private func emptyChatView(
        personas: [API.Persona],
        activePersona: API.Persona?,
        suggestions: [API.ChatSuggestion]
    ) -> some View {
        let p = theme.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        if let persona = activePersona {
                            WorkPersonaAvatarView(id: persona.id, handle: nil, name: persona.name, size: 36)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start a conversation")
                                .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                            if let persona = activePersona {
                                Text("Chatting with \(persona.name)")
                                    .font(.system(size: theme.pointSize(.body)))
                                    .foregroundStyle(p.secondaryText)
                            }
                        }
                    }
                }

                if personas.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(personas, id: \.id) { persona in
                                let selected = activePersona?.id == persona.id
                                Button {
                                    model.newChatPersonaId = persona.id
                                } label: {
                                    HStack(spacing: 6) {
                                        WorkPersonaAvatarView(id: persona.id, handle: nil, name: persona.name, size: 20)
                                        Text(persona.name)
                                            .font(.system(size: theme.pointSize(.small), weight: selected ? .semibold : .regular))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selected ? p.selected : p.surface, in: Capsule())
                                    .overlay(Capsule().stroke(selected ? p.accent : p.border))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggestions")
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.secondaryText)
                        ForEach(Array(suggestions.prefix(6).enumerated()), id: \.offset) { _, item in
                            Button {
                                Task { _ = await sendMessage(item.prompt, activePersona: activePersona) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(p.accent)
                                    Text(item.title)
                                        .font(.system(size: theme.pointSize(.body)))
                                        .foregroundStyle(p.text)
                                        .lineLimit(2)
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Chrome & Sidebar

    private func buildChrome(
        chats: [API.ChatSession],
        chatsError: String?,
        session: API.ChatSession?,
        spaces: [API.ChatSpace],
        personas: [API.Persona],
        searchEntry: QueryEntry<API.ChatSearchResults>?
    ) -> NativeChrome {
        var input = ChatNav.Input()
        input.chats = chats.map { ChatNav.ChatRow($0, pinned: model.pinnedIds.contains($0.id)) }
        input.viewedChatId = chatId
        input.spaces = spaces.map(ChatNav.SpaceRow.init)
        input.selectedSpaceId = model.selectedSpaceId
        input.personas = personas.map { ChatNav.FilterOption(value: $0.id, label: $0.name) }
        input.selectedPersonaId = model.selectedPersonaId
        input.view = model.viewMode
        input.query = model.searchQuery
        input.error = chatsError
        input.origin = context.baseURL()

        if !model.selectedPersonaId.isEmpty,
           let matched = personas.first(where: { $0.id == model.selectedPersonaId }) {
            input.filteredToPersona = (matched.id, matched.name)
        }

        let trimmed = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if trimmed.count < 2 {
                input.searchState = .short
            } else if let searchEntry {
                if let err = searchEntry.error {
                    input.searchState = .error(err.userMessage)
                } else if let data = searchEntry.data {
                    input.searchState = .ready(data.hits.map(ChatNav.SearchHit.init))
                } else {
                    input.searchState = .pending
                }
            }
        }

        return NativeChrome(
            title: session.map { ChatNav.chatTitle($0.title) } ?? "Chat",
            navigator: ChatNav.model(input)
        )
    }

    private func installCommandHandler() {
        let model = model
        let context = context
        context.onCommand = { command in
            guard let action = ChatNav.action(for: command) else { return }
            switch action {
            case .newChat(let personaId):
                model.newChatPersonaId = personaId
                context.navigate("/chat")
            case .newSpace:
                context.navigate("/spaces")
            case .selectChat(let id, let newTab):
                let suffix = model.viewMode == .archived ? "?view=archived" : ""
                let path = "/chat/\(id)\(suffix)"
                if newTab { context.openInNewTab(path) } else { context.navigate(path) }
            case .selectSearchHit(let messageId, let newTab):
                let trimmed = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count >= 2,
                   let hit = context.store.entry(API.searchChats(q: trimmed)).data?.hits.first(where: { $0.messageId == messageId }) {
                    let path = "/chat/\(hit.chatId)?message=\(hit.messageId)"
                    if newTab { context.openInNewTab(path) } else { context.navigate(path) }
                }
            case .selectSpace(let id, let newTab):
                let path = "/spaces/\(id)"
                if newTab { context.openInNewTab(path) } else { context.navigate(path) }
            case .selectView(let mode):
                model.viewMode = mode
            case .filterSpace(let spaceId):
                model.selectedSpaceId = spaceId
            case .filterPersona(let personaId), .pickPersona(let personaId):
                model.selectedPersonaId = personaId
            case .search(let query):
                model.searchQuery = query
            case .renameChat(let id):
                let chats = context.store.entry(
                    API.listChats(
                        archived: model.viewMode == .archived ? true : nil,
                        personaId: model.selectedPersonaId.isEmpty ? nil : model.selectedPersonaId,
                        space: model.selectedSpaceId.isEmpty ? nil : model.selectedSpaceId
                    )
                ).data?.chats ?? []
                model.renameDraft = chats.first(where: { $0.id == id })?.title ?? ""
                model.renameTargetId = id
            case .pinChat(let id, let pinned):
                model.togglePin(id, pinned: pinned)
            case .archiveChat(let id):
                archiveChat(id: id, archived: true)
            case .restoreChat(let id):
                archiveChat(id: id, archived: false)
            case .deleteChat(let id):
                model.deleteTargetId = id
            }
        }
    }

    // MARK: - Actions & Mutations

    private func resolvedPersona(session: API.ChatSession?, personas: [API.Persona]) -> API.Persona? {
        if let id = session?.persona?.id, let match = personas.first(where: { $0.id == id }) {
            return match
        }
        if let picked = model.newChatPersonaId, let match = personas.first(where: { $0.id == picked }) {
            return match
        }
        return personas.first(where: { $0.isDefault }) ?? personas.first
    }

    private func submitFromComposer(_ submission: ChatComposerSubmission, activePersona: API.Persona?) async -> String? {
        if let chatId {
            do {
                switch submission.mode {
                case .steer:
                    _ = try await context.store.mutate(
                        API.steerChat(id: chatId, body: API.ChatMessageEdit(body: submission.body)),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                    return nil
                case .queue:
                    _ = try await context.store.mutate(
                        API.queueChatFollowup(id: chatId, body: API.ChatMessageEdit(body: submission.body)),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                    return nil
                case .aside:
                    _ = try await context.store.mutate(
                        API.startChatAside(id: chatId, body: API.ChatAsideStart(
                            body: submission.body,
                            effort: model.selectedEffort,
                            harness: model.selectedHarness,
                            model: model.selectedModel
                        )),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                    return nil
                case .send:
                    break
                }
            } catch {
                return (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
        return await sendMessage(
            submission.body,
            activePersona: activePersona,
            attachmentIds: submission.attachmentIds,
            contextRefs: submission.contextRefs,
            research: submission.research
        )
    }

    private func sendMessage(
        _ body: String,
        activePersona: API.Persona?,
        attachmentIds: [String] = [],
        contextRefs: [API.ChatContextRef]? = nil,
        research: Bool = false
    ) async -> String? {
        let msg = API.NewChatMessage(
            attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
            body: body,
            contextRefs: contextRefs,
            effort: model.selectedEffort.map { API.NewChatMessage.Effort(rawValue: $0.rawValue) },
            harness: model.selectedHarness,
            model: model.selectedModel,
            research: research ? true : nil
        )
        do {
            if let chatId {
                _ = try await context.store.mutate(
                    API.postChatMessage(id: chatId, body: msg),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
            } else {
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        effort: model.selectedEffort,
                        harness: model.selectedHarness,
                        message: msg,
                        model: model.selectedModel,
                        personaId: activePersona?.id,
                        repoUrl: model.selectedRepoUrl,
                        spaceId: model.selectedSpaceId.isEmpty ? nil : model.selectedSpaceId
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                context.navigate("/chat/\(created.id)")
            }
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func setChatRepository(_ repoUrl: String) async -> String? {
        guard let chatId else {
            model.selectedRepoUrl = repoUrl
            return nil
        }
        do {
            _ = try await context.store.mutate(
                API.setChatRepository(id: chatId, body: API.SetChatRepositoryBody(repository: repoUrl)),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func compactChat(focus: String?) async -> String? {
        guard let chatId else { return "Start a conversation before compacting." }
        do {
            _ = try await context.store.mutate(
                API.compactChat(id: chatId, body: API.CompactChatRequest(focus: focus)),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func startChatWorkflow(workflowId: String, input: String) async -> String? {
        guard let chatId else { return "Open a conversation to run a workflow." }
        do {
            _ = try await context.store.mutate(
                API.startChatWorkflow(id: chatId, body: API.WorkflowRunStart(input: input, workflowId: workflowId)),
                invalidating: QueryInvalidation(resources: ["chats", "workflows"])
            )
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func startChatMusic(prompt: String) async -> String? {
        guard let chatId else { return "Open a conversation to generate music." }
        do {
            _ = try await context.store.mutate(
                API.startChatMusic(id: chatId, body: API.StartChatMusicRequest(prompt: prompt)),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func startCompareAside(option: ChatCompareOption, question: String) async -> String? {
        guard let chatId else { return "Open a conversation to compare with another model." }
        do {
            _ = try await context.store.mutate(
                API.startChatAside(id: chatId, body: API.ChatAsideStart(
                    body: question,
                    harness: API.Harness(rawValue: option.harness),
                    model: option.model,
                    secondOpinion: true
                )),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func cancelActiveTurn() async {
        guard let chatId else { return }
        _ = try? await context.store.mutate(
            API.cancelChatTurn(id: chatId),
            invalidating: QueryInvalidation(resources: ["chats"])
        )
    }

    private func archiveChat(id: String, archived: Bool) {
        Task {
            let revision = context.store.entry(API.getChat(id: id)).data?.revision ?? 1
            _ = try? await context.store.mutate(
                API.updateChat(id: id, body: API.ChatPatch(archived: archived, revision: revision)),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
        }
    }

    private func deleteChat(id: String) {
        Task {
            _ = try? await context.store.mutate(
                API.deleteChat(id: id),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
            if chatId == id {
                context.navigate("/chat")
            }
        }
    }

    private func renameSheet(chats: [API.ChatSession]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename conversation")
                .font(.headline)
            TextField("Conversation title", text: $model.renameDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { model.renameTargetId = nil }
                    .buttonStyle(.vesper())
                Button("Save") {
                    guard let id = model.renameTargetId else { return }
                    let title = model.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rev = chats.first(where: { $0.id == id })?.revision ?? 1
                    model.renameTargetId = nil
                    guard !title.isEmpty else { return }
                    Task {
                        _ = try? await context.store.mutate(
                            API.updateChat(id: id, body: API.ChatPatch(revision: rev, title: title)),
                            invalidating: QueryInvalidation(resources: ["chats"])
                        )
                    }
                }
                .buttonStyle(.vesper(.primary))
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func markReadIfNeeded(session: API.ChatSession?) async {
        guard let chatId, let session, session.unread > 0, session.messageCount > 0 else { return }
        _ = try? await context.store.mutate(
            API.markChatRead(id: chatId, body: API.MarkChatReadBody(seq: session.messageCount)),
            invalidating: QueryInvalidation(resources: ["chats"])
        )
    }

    // MARK: - Observation

    private var watchKey: String {
        "\(chatId ?? "")|\(model.viewMode.rawValue)|\(model.selectedSpaceId)|\(model.selectedPersonaId)|\(model.searchQuery)"
    }

    private func watch() {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        var keys: [QueryKey] = []

        func track<V: Sendable>(_ req: APIRequest<V>) {
            store.observe(req)
            store.load(req)
            keys.append(req.key)
        }

        track(Self.personasRequest)
        track(Self.spacesRequest)
        track(Self.modelsRequest)
        track(Self.suggestionsRequest)
        track(Self.dockRequest)
        track(Self.workflowsRequest)
        track(Self.repositoriesRequest)
        track(chatsRequest)
        if let sessionRequest { track(sessionRequest) }
        if let ticketRunsRequest { track(ticketRunsRequest) }
        if let searchRequest { track(searchRequest) }
        watched = keys
    }
}
