import AppKit
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
    var temporaryMode = false
    var pinnedIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(pinnedIds).sorted(), forKey: Self.pinnedDefaultsKey)
        }
    }

    var renameTargetId: String?
    var renameDraft = ""
    var deleteTargetId: String?
    var forkTarget: API.ChatMessage?
    var saveWikiTarget: API.ChatMessage?
    var saveWikiBodyOverride: String?
    var saveTemplateBody: String?
    var composerPrefill: ChatComposerPrefill?
    @ObservationIgnored var prefillToken = 0

    var inspectorOpen = false
    var inspectorTabId = ChatInspectorLogic.activityTabId
    var activeDesignId: String?
    var activeCanvasId: String?
    var designReviewing = false
    var threadMessageId: String?
    var threadInitialDraft: String?
    var forceShowCode = false
    var startingPlayground = false
    var scrollToMessageRequest: ChatScrollMessageRequest?
    var focusedTurnMessageId: String?
    var contextPopoverToken = 0
    var replyVariants = ChatReplyVariantStore()
    @ObservationIgnored var scrollToken = 0
    var theme: ThemeTokens = ThemeTokens(mode: .light)
    var colorScheme: ColorScheme = .light
    var wizardStep: OnboardingLogic.WizardStep = .greeting
    var wizardDismissed = false

    func resetInspectorForChatSwitch() {
        activeDesignId = nil
        activeCanvasId = nil
        designReviewing = false
        threadMessageId = nil
        threadInitialDraft = nil
        forceShowCode = false
        startingPlayground = false
        scrollToMessageRequest = nil
        focusedTurnMessageId = nil
    }

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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.vesperWindowVisible) private var windowVisible
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    @State private var model = ChatScreenModel()
    @State private var watched: [QueryKey] = []
    /// The persona companion's pop-out: the loop large in the middle with a small composer.
    @State private var companionOpen = false
    /// Live Voice: the persona takes over the chat while the person talks with it out loud.
    @State private var liveVoiceOpen = false
    @State private var messageReader = ChatMessageReader()
    @State private var lastDockFetch = Date()
    @State private var keyMonitor: Any?

    private static let bootRequest = API.getBootstrap()
    private static let personasRequest = API.listPersonas()
    private static let spacesRequest = API.listChatSpaces()
    private static let modelsRequest = API.listChatModels()
    private static let suggestionsRequest = API.listChatSuggestions()
    private static let dockRequest = API.getPersonaDock()
    private static let dockPollInterval: Duration = .seconds(180)
    private static let dockStaleAfter: TimeInterval = 60
    private static let longTurnUsageRefreshIntervalMs = ChatTurnActivity.longTurnUsageRefreshIntervalMs
    private static let workflowsRequest = API.listWorkflows()
    private static let repositoriesRequest = API.searchRepositories()
    private static let promptTemplatesRequest = API.listPromptTemplates()

    private var chatId: String? {
        context.match.params["id"]
    }

    /// The chat's companion state; a chat not created yet shares one until it has an id.
    private var companion: ChatCompanion {
        ChatCompanions.companion(for: chatId ?? "new")
    }

    private var codeReviewRequest: APIRequest<API.CodeReviewList>? {
        chatId.map { API.getChatCodeReview(id: $0) }
    }

    private var playgroundRequest: APIRequest<API.ChatPlaygroundState>? {
        chatId.map { API.getChatPlayground(id: $0) }
    }

    private var canvasesRequest: APIRequest<API.ChatCanvases>? {
        chatId.map { API.listChatCanvases(id: $0) }
    }

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse>? {
        chatId.map { API.listChatMessages(id: $0, limit: 200) }
    }

    private var costsRequest: APIRequest<API.CostReport>? {
        chatId.map { API.getCosts(chat: $0) }
    }

    private var chatsRequest: APIRequest<API.ListChatsResponse> {
        API.listChats(
            archived: model.viewMode == .archived ? true : nil,
            personaId: ChatNav.listPersonaQuery(model.selectedPersonaId),
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
        let boot = store.entry(Self.bootRequest).data
        let personas = store.entry(Self.personasRequest).data?.personas ?? []
        let spaces = store.entry(Self.spacesRequest).data?.spaces ?? []
        let harnessModels = store.entry(Self.modelsRequest).data ?? []
        let suggestions = store.entry(Self.suggestionsRequest).data?.suggestions ?? []
        let harnesses = store.entry(Self.dockRequest).data?.harnesses ?? []
        let workflows = store.entry(Self.workflowsRequest).data?.workflows ?? []
        let repositories = store.entry(Self.repositoriesRequest).data ?? []
        let promptTemplates = store.entry(Self.promptTemplatesRequest).data?.templates ?? []
        let chatsEntry = store.entry(chatsRequest)
        let chats = chatsEntry.data?.chats ?? []
        let session = sessionRequest.flatMap { store.entry($0).data }
        let searchEntry = searchRequest.map { store.entry($0) }
        let activePersona = resolvedPersona(session: session, personas: personas)
        let codeReviews = codeReviewRequest.flatMap { store.entry($0).data?.repositories } ?? []
        let playgroundState = playgroundRequest.flatMap { store.entry($0).data }
        let canvases = canvasesRequest.flatMap { store.entry($0).data?.canvases } ?? []
        let messages = messagesRequest.flatMap { store.entry($0).data?.messages } ?? []
        let costs = costsRequest.flatMap { store.entry($0).data }
        let forceSetup = context.match.query["setup"] != nil
        let wizardMode = OnboardingLogic.wizardMode(me: boot?.me, forceSetup: forceSetup)
        let activeWizardMode: OnboardingLogic.WizardMode? = (chatId == nil && !model.wizardDismissed && boot != nil) ? wizardMode : nil
        let liveSince = ChatTurnActivity.runningSince(for: messages)
        let liveActivity: ChatTurnActivity? = {
            guard session?.state == .running, let runId = session?.currentRunId, !runId.isEmpty else { return nil }
            if messages.isEmpty && (session?.messageCount ?? 0) > 0 { return nil }
            let events = store.entry(ChatTurnActivity.liveEventsRequest(runId: runId, since: liveSince)).data?.events ?? []
            guard !events.isEmpty else { return nil }
            return ChatTurnActivity.fold(events: events.map(ChatRunEvent.init), since: liveSince)
        }()
        let livePlanProgress = liveActivity.flatMap { ChatTurnActivity.planProgress(steps: $0.steps, planned: $0.planned) }
        let livePlanTurnKey = "\(chatId ?? "")|\(liveSince ?? "")"
        let longTurnUsageRefreshKey: String = {
            guard session?.state == .running, windowVisible, AppPowerState.shared.isActive else { return "" }
            return "\(chatId ?? "")|\(session?.currentRunId ?? "")|\(liveSince ?? "")"
        }()

        VStack(spacing: 0) {
            if let activeWizardMode {
                WelcomeWizardView(
                    mode: activeWizardMode,
                    step: $model.wizardStep,
                    onDone: { personaId in
                        model.wizardDismissed = true
                        if let personaId, !personaId.isEmpty {
                            model.newChatPersonaId = personaId
                            let encoded = personaId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? personaId
                            context.navigate("/chat?new&persona=\(encoded)", replace: true)
                        } else {
                            context.navigate("/chat?new", replace: true)
                        }
                    }
                )
            } else {
                headerBar(
                    session: session,
                    personas: personas,
                    activePersona: activePersona,
                    harnessModels: harnessModels,
                    messages: messages,
                    pinnedCount: messages.filter { $0.bookmarked == true }.count
                )
                Divider()

                if messageReader.isActive {
                    ChatReadAloudMiniBarView(reader: messageReader) { msgId in
                        model.scrollToken += 1
                        model.scrollToMessageRequest = ChatScrollMessageRequest(token: model.scrollToken, messageId: msgId)
                    }
                }

                Group {
                    if let chatId {
                        transcriptSection(
                            chatId: chatId,
                            session: session,
                            personas: personas,
                            activePersona: activePersona,
                            harnessModels: harnessModels
                        )
                    } else {
                        emptyChatView(
                            personas: personas,
                            activePersona: activePersona,
                            suggestions: suggestions,
                            spaces: spaces
                        )
                    }
                }
                // The host persona's loop stands bottom-right just above the composer for the whole chat.
                .overlay(alignment: .bottomTrailing) {
                    if let persona = activePersona, let loops = persona.playableLoops {
                        PersonaCompanionDock(companion: companion, persona: persona, loops: loops) { companionOpen = true }
                    }
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
                    promptTemplates: promptTemplates,
                    spaces: spaces,
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
                    },
                    onStartLiveVoice: {
                        companionOpen = false
                        liveVoiceOpen = true
                    },
                    onOpenOutline: {
                        model.inspectorTabId = ChatInspectorLogic.outlineTabId
                        model.inspectorOpen = true
                    },
                    onStartTemporaryChat: {
                        model.temporaryMode = true
                        context.navigate("/chat?temporary=1")
                    },
                    prefill: model.composerPrefill,
                    onPrefillApplied: { token in
                        if model.composerPrefill?.token == token {
                            model.composerPrefill = nil
                        }
                    },
                    livePlanProgress: livePlanProgress,
                    livePlanTurnKey: livePlanTurnKey
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if liveVoiceOpen {
                LiveVoiceView(
                    companion: companion,
                    persona: activePersona,
                    lastReply: messages.last { $0.role == .assistant },
                    turnRunning: session?.state == .running,
                    syncCompanion: {
                        companion.observe(chatId: chatId, messages: messages, personas: personas, hostPersonaId: activePersona?.id)
                    },
                    onSend: { body in await sendMessage(body, activePersona: activePersona, voice: true) },
                    onClose: { liveVoiceOpen = false }
                )
                .transition(.opacity)
            } else if companionOpen, let persona = activePersona, let loops = persona.playableLoops {
                PersonaCompanionPopOut(
                    companion: companion,
                    persona: persona,
                    loops: loops,
                    lastReply: messages.last { $0.role == .assistant },
                    onSend: { body in await sendMessage(body, activePersona: activePersona) },
                    onClose: { companionOpen = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: companionOpen)
        .animation(.easeOut(duration: 0.25), value: liveVoiceOpen)
        // Replies that arrive while the chat is open reveal at the persona's pace.
        .onChange(of: "\(chatId ?? "")|\(messages.last?.id ?? "")|\(personas.count)", initial: true) { _, _ in
            companion.observe(chatId: chatId, messages: messages, personas: personas, hostPersonaId: activePersona?.id)
        }
        .onChange(of: chatId) { oldId, _ in
            companionOpen = false
            messageReader.stop()
            // Live Voice in a new chat carries on into the chat its first message created.
            if oldId != nil { liveVoiceOpen = false }
        }
        .onChange(
            of: buildChrome(
                chats: chats,
                chatsError: chatsEntry.error?.userMessage,
                session: session,
                spaces: spaces,
                personas: personas,
                searchEntry: searchEntry,
                messages: messages,
                harnessModels: harnessModels,
                costs: costs,
                codeReviews: codeReviews,
                playgroundState: playgroundState,
                canvases: canvases,
                liveActivity: liveActivity,
                wizardMode: activeWizardMode,
                wizardStep: model.wizardStep
            ),
            initial: true
        ) { _, next in
            context.chrome = next
        }
        .onChange(of: activeWizardMode, initial: true) { oldMode, newMode in
            if let newMode, (oldMode != newMode || (newMode == .harnessOnly && model.wizardStep != .connectHarness)) {
                model.wizardStep = OnboardingLogic.initialStep(for: newMode)
            }
        }
        .onChange(of: chatId) { oldId, newId in
            if oldId != newId {
                model.resetInspectorForChatSwitch()
                applyInspectorQuery(context.match.query, canvases: canvases)
            }
        }
        .onChange(of: context.match.query, initial: true) { _, query in
            if query["setup"] != nil {
                model.wizardDismissed = false
                model.wizardStep = .greeting
            }
            if let personaQuery = query["persona"], !personaQuery.isEmpty {
                model.newChatPersonaId = personaQuery
            }
            if chatId == nil, query["temporary"] == "1" {
                model.temporaryMode = true
            }
            applyInspectorQuery(query, canvases: canvases)
        }
        .onChange(of: canvases) { _, updatedCanvases in
            if let canvasQuery = context.match.query["canvas"], !canvasQuery.isEmpty, canvasQuery != "none" {
                applyInspectorQuery(context.match.query, canvases: updatedCanvases)
            }
        }
        .task(id: watchKey(session: session, liveSince: liveSince)) { watch(session: session, liveSince: liveSince) }
        .task(id: windowVisible && AppPowerState.shared.isActive) {
            // Usage readings land in the background with no SSE event, so keep the composer's
            // harness usage popover fresh only while Chat is visible and Vesper is active.
            guard windowVisible && AppPowerState.shared.isActive else { return }
            if Date().timeIntervalSince(lastDockFetch) >= Self.dockStaleAfter {
                lastDockFetch = Date()
                _ = await context.store.refetch(Self.dockRequest)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.dockPollInterval)
                guard !Task.isCancelled else { return }
                lastDockFetch = Date()
                _ = await context.store.refetch(Self.dockRequest)
            }
        }
        .task(id: longTurnUsageRefreshKey) {
            // While a turn runs past 60s, refresh harness usage/quota every 60s so popovers stay
            // fresh mid-turn; SwiftUI cancels this task immediately when the turn ends or view leaves.
            guard !longTurnUsageRefreshKey.isEmpty else { return }
            let sinceMs = liveSince.map { Int((APIDate.epoch($0) * 1000).rounded()) }
            let nowMs = Int((Date().timeIntervalSince1970 * 1000).rounded())
            var initialDelayMs = ChatTurnActivity.longTurnUsageRefreshDelayMs(
                sinceEpochMs: sinceMs,
                nowEpochMs: nowMs,
                intervalMs: Self.longTurnUsageRefreshIntervalMs
            )
            if initialDelayMs == 0 {
                let sinceLastFetchMs = Int((Date().timeIntervalSince(lastDockFetch) * 1000).rounded())
                if sinceLastFetchMs < Self.longTurnUsageRefreshIntervalMs {
                    initialDelayMs = max(0, Self.longTurnUsageRefreshIntervalMs - sinceLastFetchMs)
                }
            }
            if initialDelayMs > 0 {
                try? await Task.sleep(for: .milliseconds(initialDelayMs))
            }
            while !Task.isCancelled {
                lastDockFetch = Date()
                _ = await context.store.refetch(Self.dockRequest)
                try? await Task.sleep(for: .milliseconds(Self.longTurnUsageRefreshIntervalMs))
            }
        }
        .task(id: "\(chatId ?? "")|\(session?.unread ?? 0)|\(session?.messageCount ?? 0)") {
            await markReadIfNeeded(session: session)
        }
        .onAppear {
            model.theme = theme
            model.colorScheme = colorScheme
            if context.match.query["view"] == "archived" {
                model.viewMode = .archived
            }
            if chatId == nil, context.match.query["temporary"] == "1" {
                model.temporaryMode = true
            }
            applyInspectorQuery(context.match.query, canvases: canvases)
            installCommandHandler()
            installInspectorView()
            installKeyboardMonitor()
        }
        .onChange(of: theme) { _, next in model.theme = next }
        .onChange(of: colorScheme) { _, next in model.colorScheme = next }
        .onDisappear {
            removeKeyboardMonitor()
            messageReader.stop()
            ChatSelectionPopoverPresenter.shared.dismiss()
            context.inspectorView = nil
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
        .sheet(isPresented: Binding(
            get: { model.renameTargetId != nil },
            set: { if !$0 { model.renameTargetId = nil } }
        )) {
            renameSheet(chats: chats)
        }
        .sheet(item: Binding(
            get: { model.forkTarget.map { MessageSheetTarget(message: $0) } },
            set: { if $0 == nil { model.forkTarget = nil } }
        )) { item in
            forkSheet(session: session, message: item.message)
        }
        .sheet(item: Binding(
            get: { model.saveWikiTarget.map { MessageSheetTarget(message: $0) } },
            set: { if $0 == nil { model.saveWikiTarget = nil } }
        )) { item in
            saveWikiSheet(session: session, message: item.message)
        }
        .sheet(isPresented: Binding(
            get: { model.saveTemplateBody != nil },
            set: { if !$0 { model.saveTemplateBody = nil } }
        )) {
            if let templateBody = model.saveTemplateBody {
                ChatSaveTemplateSheetView(
                    initialBody: templateBody,
                    activePersonaId: activePersona?.id ?? session?.persona?.id,
                    activePersonaName: activePersona?.name ?? session?.persona?.name,
                    activeSpaceId: session?.space?.id,
                    activeSpaceName: session?.space?.name,
                    onClose: { model.saveTemplateBody = nil }
                )
            }
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

    private struct MessageSheetTarget: Identifiable {
        let message: API.ChatMessage
        var id: String { message.id }
    }

    private func transcriptSection(
        chatId: String,
        session: API.ChatSession?,
        personas: [API.Persona],
        activePersona: API.Persona?,
        harnessModels: [API.ChatHarnessModels]
    ) -> some View {
        ChatTranscriptView(
            chatId: chatId,
            session: session,
            knownPersonaNames: personas.map(\.name),
            personas: personas,
            harnessModels: harnessModels,
            scrollToMessageRequest: model.scrollToMessageRequest,
            onSendReply: { body in
                Task { _ = await sendMessage(body, activePersona: activePersona) }
            },
            onQuoteMessage: { body, mention in
                let hostName = activePersona?.name ?? session?.persona?.name
                let tag = (mention != nil && mention != hostName) ? mention : nil
                let text = ChatQuoteLogic.quoteForComposer(body, mention: tag)
                model.prefillToken += 1
                model.composerPrefill = ChatComposerPrefill(token: model.prefillToken, text: text)
            },
            onOpenThread: { messageId in
                model.threadMessageId = messageId
                model.inspectorTabId = ChatInspectorLogic.threadTabId
                model.inspectorOpen = true
            },
            onForkMessage: { msg in
                model.forkTarget = msg
            },
            onSaveWiki: { msg in
                model.saveWikiBodyOverride = nil
                model.saveWikiTarget = msg
            },
            onSecondOpinion: { msg, harness, modelId in
                Task {
                    _ = try? await context.store.mutate(
                        API.startChatAside(id: chatId, body: API.ChatAsideStart(
                            anchorMessageId: msg.id,
                            body: "",
                            harness: harness,
                            model: modelId,
                            secondOpinion: true
                        )),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                }
            },
            replyVariants: model.replyVariants,
            onSelectReplyVariant: { userMessageId, index in
                model.replyVariants.select(chatId: chatId, userMessageId: userMessageId, index: index)
            },
            onEditLastUserMessage: { newBody in
                await editLastMessage(chatId: chatId, body: newBody)
            },
            onRegenerateMessage: { replyMsg, userMsgId, userBody, harness, modelId in
                model.replyVariants.archiveBeforeRegenerate(
                    chatId: chatId,
                    userMessageId: userMsgId,
                    reply: ChatReplyVariant(
                        id: replyMsg.id,
                        bodyMd: replyMsg.bodyMd,
                        model: replyMsg.model,
                        harness: replyMsg.harness?.rawValue,
                        createdAt: replyMsg.createdAt
                    )
                )
                return await editLastMessage(
                    chatId: chatId,
                    body: userBody,
                    harness: harness,
                    modelId: modelId
                )
            },
            readingMessageId: messageReader.activeMessageId,
            onToggleReadAloud: { msg, personaId, speakerName, bodyMd in
                companion.stopVoice()
                messageReader.toggle(
                    chatId: chatId,
                    messageId: msg.id,
                    personaId: personaId,
                    speakerName: speakerName,
                    bodyMd: bodyMd
                )
            },
            onSelectionAction: { msg, speaker, action, excerpt in
                let hostName = activePersona?.name ?? session?.persona?.name
                switch action {
                case .quote:
                    let text = ChatSelectionLogic.quotePrompt(selection: excerpt, speakerName: speaker, hostName: hostName)
                    model.prefillToken += 1
                    model.composerPrefill = ChatComposerPrefill(token: model.prefillToken, text: text)
                case .thread:
                    model.threadMessageId = msg.id
                    model.threadInitialDraft = ChatSelectionLogic.threadPrefill(selection: excerpt)
                    model.inspectorTabId = ChatInspectorLogic.threadTabId
                    model.inspectorOpen = true
                case .explain:
                    let text = ChatSelectionLogic.explainPrompt(selection: excerpt)
                    model.prefillToken += 1
                    model.composerPrefill = ChatComposerPrefill(token: model.prefillToken, text: text)
                case .clipToKnowledge:
                    model.saveWikiBodyOverride = excerpt
                    model.saveWikiTarget = msg
                }
            },
            onSaveAsTemplate: { body in
                model.saveTemplateBody = body
            }
        )
    }

    @ViewBuilder
    private func forkSheet(session: API.ChatSession?, message: API.ChatMessage) -> some View {
        if let chatId {
            ChatForkSheetView(
                chatId: chatId,
                defaultTitle: session?.title ?? "",
                hasRepo: !(session?.repoUrl ?? "").isEmpty,
                message: message,
                onClose: { model.forkTarget = nil }
            )
        }
    }

    @ViewBuilder
    private func saveWikiSheet(session: API.ChatSession?, message: API.ChatMessage) -> some View {
        if let chatId {
            ChatSaveWikiSheetView(
                chatId: chatId,
                chatTitle: session?.title ?? "",
                projectKey: session?.project,
                bodyMd: model.saveWikiBodyOverride ?? message.bodyMd,
                onClose: {
                    model.saveWikiTarget = nil
                    model.saveWikiBodyOverride = nil
                }
            )
        }
    }

    private func headerBar(
        session: API.ChatSession?,
        personas: [API.Persona],
        activePersona: API.Persona?,
        harnessModels: [API.ChatHarnessModels],
        messages: [API.ChatMessage],
        pinnedCount: Int
    ) -> some View {
        let p = theme.palette
        let participants = session?.participants ?? []

        return HStack(spacing: 10) {
            if let session {
                WorkPersonaAvatarView(
                    id: session.persona?.id,
                    handle: nil,
                    name: session.persona?.name ?? session.agent.name,
                    size: 22,
                    state: session.state == .running ? .working : .idle,
                    active: session.state == .running,
                    preferCharacter: true
                )
                Text(ChatNav.chatTitle(session.title))
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .lineLimit(1)

                if session.temporary == true {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.slash")
                            .imageScale(.small)
                        Text("Temporary")
                    }
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(p.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(p.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .help("Temporary chat: no memory reads or writes, excluded from search, auto-deleted after 24h idle.")
                }

                if personas.count > 1 || participants.count > 1 {
                    ChatParticipantsPopoverView(
                        session: session,
                        allPersonas: personas,
                        onSendRoundtable: { prompt in
                            await sendMessage(prompt, activePersona: activePersona)
                        }
                    )
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

                Button {
                    model.temporaryMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.temporaryMode ? "eye.slash.fill" : "eye.slash")
                            .imageScale(.small)
                        Text("Temporary")
                            .lineLimit(1)
                    }
                    .font(.system(size: theme.pointSize(.small), weight: model.temporaryMode ? .semibold : .regular))
                    .foregroundStyle(model.temporaryMode ? p.accent : p.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(model.temporaryMode ? p.selected : p.surface, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            model.temporaryMode ? p.accent.opacity(0.7) : p.border,
                            style: StrokeStyle(lineWidth: 1, dash: model.temporaryMode ? [4, 2] : [])
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("Temporary chat (/temp): no memory reads or writes, excluded from search, auto-deleted after 24h idle.")
                .accessibilityLabel(model.temporaryMode ? "Disable temporary chat" : "Enable temporary chat")
            }

            Spacer(minLength: 8)

            if let session {
                ChatContextMeterView(
                    session: session,
                    messages: messages,
                    pinnedCount: pinnedCount,
                    openRequestToken: model.contextPopoverToken,
                    onCompact: { focus in await compactChat(focus: focus) }
                )
            }

            Button {
                showLiveThinking.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain.head.profile")
                        .imageScale(.small)
                    Text("Thinking")
                        .lineLimit(1)
                }
                .font(.system(size: theme.pointSize(.small), weight: showLiveThinking ? .semibold : .regular))
                .foregroundStyle(showLiveThinking ? p.accent : p.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(showLiveThinking ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(showLiveThinking ? p.accent.opacity(0.6) : p.border))
            }
            .buttonStyle(.plain)
            .help(showLiveThinking ? "Hide live thinking blocks (/thinking off)" : "Stream live thinking blocks inline (/thinking on)")
            .accessibilityLabel(showLiveThinking ? "Hide live thinking" : "Show live thinking")

            modelMenu(session: session, harnessModels: harnessModels)

            if let session, !messages.isEmpty {
                exportChatMenu(session: session, activePersona: activePersona, messages: messages)
            }

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
        suggestions: [API.ChatSuggestion],
        spaces: [API.ChatSpace]
    ) -> some View {
        let p = theme.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        if let persona = activePersona {
                            WorkPersonaAvatarView(id: persona.id, handle: nil, name: persona.name, size: 36, state: .idle, active: true, preferCharacter: true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.temporaryMode ? "Start a temporary conversation" : "Start a conversation")
                                .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                            if let persona = activePersona {
                                Text(model.temporaryMode
                                     ? "Off the record with \(persona.name) — no memory reads or writes, auto-pruned after 24h."
                                     : "Chatting with \(persona.name)")
                                    .font(.system(size: theme.pointSize(.body)))
                                    .foregroundStyle(p.secondaryText)
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

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Spaces")
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.secondaryText)
                        Spacer()
                        Button {
                            context.navigate("/spaces/new")
                        } label: {
                            Label("New Space", systemImage: "plus")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    if spaces.isEmpty {
                        Button {
                            context.navigate("/spaces/new")
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.stack.3d.up")
                                    .foregroundStyle(p.accent)
                                Text("Create your first Space for focused work, repos, and Knowledge")
                                    .font(.system(size: theme.pointSize(.small)))
                                    .foregroundStyle(p.secondaryText)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                        }
                        .buttonStyle(.plain)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(spaces, id: \.id) { space in
                                    Button {
                                        context.navigate("/spaces/\(space.id)")
                                    } label: {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(cssHex: SpacesLogic.colorHex(for: space.color)) ?? .green)
                                                .frame(width: 8, height: 8)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(space.name)
                                                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                                    .foregroundStyle(p.text)
                                                    .lineLimit(1)
                                                let rc = space.repoCount ?? 0
                                                let kc = space.knowledgeCount ?? 0
                                                let tc = space.openTaskCount ?? 0
                                                let meta = [
                                                    rc > 0 ? "\(rc) repo\(rc == 1 ? "" : "s")" : nil,
                                                    kc > 0 ? "\(kc) Knowledge" : nil,
                                                    tc > 0 ? "\(tc) task\(tc == 1 ? "" : "s")" : nil,
                                                ].compactMap { $0 }.joined(separator: " · ")
                                                if !meta.isEmpty {
                                                    Text(meta)
                                                        .font(.system(size: theme.pointSize(.micro)))
                                                        .foregroundStyle(p.tertiaryText)
                                                        .lineLimit(1)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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
        searchEntry: QueryEntry<API.ChatSearchResults>?,
        messages: [API.ChatMessage],
        harnessModels: [API.ChatHarnessModels],
        costs: API.CostReport?,
        codeReviews: [API.CodeReview],
        playgroundState: API.ChatPlaygroundState?,
        canvases: [API.ChatCanvasSummary],
        liveActivity: ChatTurnActivity?,
        wizardMode: OnboardingLogic.WizardMode?,
        wizardStep: OnboardingLogic.WizardStep
    ) -> NativeChrome {
        if let wizardMode {
            return NativeChrome(
                title: wizardMode == .harnessOnly ? "Connect a harness" : "Welcome to Vesper",
                inspector: nil,
                navigator: OnboardingLogic.sidebarNavModel(mode: wizardMode, step: wizardStep),
                areaOverride: nil
            )
        }
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

        let inspector = ChatInspectorLogic.buildInspectorModel(ChatInspectorLogic.Input(
            chatId: chatId,
            session: session,
            messages: messages,
            harnessModels: harnessModels,
            costs: costs,
            codeReviews: codeReviews,
            playgroundState: playgroundState,
            canvases: canvases,
            liveActivity: liveActivity,
            open: model.inspectorOpen,
            activeTabId: model.inspectorTabId,
            activeDesignId: model.activeDesignId,
            activeCanvasId: model.activeCanvasId,
            designReviewing: model.designReviewing,
            threadMessageId: model.threadMessageId,
            forceShowCode: model.forceShowCode,
            startingPlayground: model.startingPlayground
        ))

        let navigator: NavModel
        let areaOverride: AreaId?
        if let spaceId = session?.space?.id {
            let spaceChats = context.store.entry(SpacesLogic.spaceChatsRequest(spaceId: spaceId)).data?.chats ?? []
            navigator = SpacesLogic.navModel(
                spaces: spaces,
                activeSpaceId: spaceId,
                chats: spaceChats,
                viewedChatId: chatId,
                personas: personas,
                origin: context.baseURL()
            )
            areaOverride = .spaces
        } else {
            navigator = ChatNav.model(input)
            areaOverride = nil
        }

        return NativeChrome(
            title: session.map { ChatNav.chatTitle($0.title) } ?? "Chat",
            inspector: inspector,
            navigator: navigator,
            areaOverride: areaOverride
        )
    }

    private func applyInspectorQuery(_ query: [String: String], canvases: [API.ChatCanvasSummary]) {
        guard chatId != nil else { return }
        if let canvasId = query["canvas"], !canvasId.isEmpty, canvasId != "none" {
            let isDesign = canvases.first(where: { $0.id == canvasId })?.kind == .design
            if isDesign {
                model.activeDesignId = canvasId
                model.inspectorTabId = ChatInspectorLogic.designTabId
            } else {
                model.activeCanvasId = canvasId
                model.inspectorTabId = ChatInspectorLogic.canvasTabId
            }
            model.inspectorOpen = true
        }
        if let code = query["code"], code == "open" || code == "full" {
            model.forceShowCode = true
            model.inspectorTabId = ChatInspectorLogic.codeTabId
            model.inspectorOpen = true
        }
        if let pg = query["playground"], pg == "open" || pg == "full" {
            model.inspectorTabId = ChatInspectorLogic.playgroundTabId
            model.inspectorOpen = true
        }
        if let thread = query["thread"], !thread.isEmpty {
            model.threadMessageId = thread
            model.inspectorTabId = ChatInspectorLogic.threadTabId
            model.inspectorOpen = true
        }
        if let panel = query["panel"],
           [
               ChatInspectorLogic.designTabId,
               ChatInspectorLogic.canvasTabId,
               ChatInspectorLogic.playgroundTabId,
               ChatInspectorLogic.codeTabId,
               ChatInspectorLogic.threadTabId,
               ChatInspectorLogic.outlineTabId,
               ChatInspectorLogic.activityTabId,
           ].contains(panel) {
            model.inspectorTabId = panel
            model.inspectorOpen = true
        }
    }

    private func startSavedPlayground(chatId: String) {
        guard !model.startingPlayground else { return }
        model.startingPlayground = true
        Task {
            defer { model.startingPlayground = false }
            do {
                _ = try await context.store.mutate(
                    API.chatPlaygroundAction(id: chatId, action: .start),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
            } catch {
                let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
                context.showToast(ToastItemModel(id: "chat.playground.start", title: msg, tone: .error))
            }
        }
    }

    private func installInspectorView() {
        let model = model
        let context = context
        context.inspectorView = { tabId in
            if tabId == ChatInspectorLogic.codeTabId,
               let currentChatId = context.match.params["id"] {
                return AnyView(
                    ChatCodeInspectorView(chatId: currentChatId)
                        .id("code:\(currentChatId)")
                        .environment(context)
                        .environment(\.vesperTheme, model.theme)
                        .environment(\.colorScheme, model.colorScheme)
                )
            }
            if tabId == ChatInspectorLogic.threadTabId,
               let currentChatId = context.match.params["id"],
               let msgId = model.threadMessageId, !msgId.isEmpty {
                return AnyView(
                    ChatThreadInspectorView(
                        chatId: currentChatId,
                        messageId: msgId,
                        initialDraft: model.threadInitialDraft
                    )
                        .id("\(currentChatId):\(msgId)")
                        .environment(context)
                        .environment(\.vesperTheme, model.theme)
                        .environment(\.colorScheme, model.colorScheme)
                )
            }
            if tabId == ChatInspectorLogic.outlineTabId,
               let currentChatId = context.match.params["id"] {
                return AnyView(
                    ChatOutlineInspectorView(chatId: currentChatId) { messageId in
                        model.scrollToken += 1
                        model.scrollToMessageRequest = ChatScrollMessageRequest(token: model.scrollToken, messageId: messageId)
                    }
                    .id("outline:\(currentChatId)")
                    .environment(context)
                    .environment(\.vesperTheme, model.theme)
                    .environment(\.colorScheme, model.colorScheme)
                )
            }
            if tabId == ChatInspectorLogic.activityTabId,
               let currentChatId = context.match.params["id"] {
                return AnyView(
                    ChatActivityInspectorView(chatId: currentChatId)
                        .id("activity:\(currentChatId)")
                        .environment(context)
                        .environment(\.vesperTheme, model.theme)
                        .environment(\.colorScheme, model.colorScheme)
                )
            }
            return nil
        }
    }

    private func installCommandHandler() {
        let model = model
        let context = context
        context.onCommand = { command in
            switch command {
            case .inspectorVisibility(let open):
                model.inspectorOpen = open
                return
            case .inspectorSelectTab(let tabId):
                model.inspectorTabId = tabId
                model.inspectorOpen = true
                if tabId == ChatInspectorLogic.playgroundTabId,
                   let currentChatId = context.match.params["id"] {
                    let pgState = context.store.entry(API.getChatPlayground(id: currentChatId)).data
                    if pgState?.playground == nil && pgState?.savedSpec == true {
                        startSavedPlayground(chatId: currentChatId)
                    }
                }
                return
            case .inspectorAction(let tabId, let actionId, let itemId, _):
                if tabId == ChatInspectorLogic.activityTabId,
                   actionId == ChatInspectorLogic.jumpTurnActionId,
                   let itemId {
                    model.scrollToken += 1
                    model.scrollToMessageRequest = ChatScrollMessageRequest(token: model.scrollToken, messageId: itemId)
                } else if tabId == ChatInspectorLogic.threadTabId,
                          actionId == ChatInspectorLogic.closeActionId {
                    model.threadMessageId = nil
                    if model.inspectorTabId == ChatInspectorLogic.threadTabId {
                        model.inspectorTabId = ChatInspectorLogic.activityTabId
                        model.inspectorOpen = false
                    }
                } else if tabId == ChatInspectorLogic.designTabId,
                          actionId == ChatInspectorLogic.reviewActionId {
                    model.designReviewing.toggle()
                }
                return
            case .panelEvent(let tabId, let event, let payloadJson):
                if event == "close" {
                    if tabId == ChatInspectorLogic.threadTabId {
                        model.threadMessageId = nil
                        model.inspectorTabId = ChatInspectorLogic.activityTabId
                    }
                    model.inspectorOpen = false
                } else if tabId == ChatInspectorLogic.designTabId, event == "review",
                          let on = ChatInspectorLogic.parseDesignReviewToggle(from: payloadJson) {
                    model.designReviewing = on
                }
                return
            default:
                break
            }
            if let targetStep = OnboardingLogic.stepFromNavCommand(command) {
                if targetStep.rawValue < model.wizardStep.rawValue {
                    model.wizardStep = targetStep
                }
                return
            }
            if let spaceAction = SpacesLogic.navAction(for: command) {
                switch spaceAction {
                case .newSpace:
                    context.navigate("/spaces/new")
                case .openSpace(let id, let newTab):
                    let path = "/spaces/\(id)"
                    if newTab { context.openInNewTab(path) } else { context.navigate(path) }
                case .openChat(let id, let newTab):
                    let path = "/chat/\(id)"
                    if newTab { context.openInNewTab(path) } else { context.navigate(path) }
                }
                return
            }
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
                let chats = context.store.entry(chatsRequest).data?.chats ?? []
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
                    let queued = try await context.store.mutate(
                        API.queueChatFollowup(id: chatId, body: API.ChatMessageEdit(body: submission.body))
                    )
                    if context.store.entry(API.getChat(id: chatId)).data?.state == .running {
                        let followupsReq = API.listChatFollowups(id: chatId)
                        context.store.setData(
                            ChatFollowupLogic.appending(queued, to: context.store.entry(followupsReq).data),
                            for: followupsReq
                        )
                    }
                    context.store.invalidate(QueryInvalidation(resources: ["chats"]))
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
                case .send, .interrupt:
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
        research: Bool = false,
        voice: Bool = false
    ) async -> String? {
        // Sending shows the rest of a reply that's still revealing.
        companion.finishReveal()
        let msg = API.NewChatMessage(
            attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
            body: body,
            contextRefs: contextRefs,
            effort: model.selectedEffort.map { API.NewChatMessage.Effort(rawValue: $0.rawValue) },
            harness: model.selectedHarness,
            model: model.selectedModel,
            research: research ? true : nil,
            voice: voice ? true : nil
        )
        do {
            if let chatId {
                let posted = try await context.store.mutate(
                    API.postChatMessage(id: chatId, body: msg)
                )
                // Seed both session and message list together so the live working card starts
                // scoped to the new user message's timestamp before the background refetch lands.
                context.store.setData(posted.chat, for: API.getChat(id: chatId))
                let listReq = API.listChatMessages(id: chatId, limit: 200)
                if var existing = context.store.entry(listReq).data,
                   !existing.messages.contains(where: { $0.id == posted.message.id }) {
                    existing.messages.append(posted.message)
                    context.store.setData(existing, for: listReq)
                }
                context.store.invalidate(QueryInvalidation(resources: ["chats"]))
            } else {
                let isTemporary = model.temporaryMode
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        effort: model.selectedEffort,
                        harness: model.selectedHarness,
                        message: msg,
                        model: model.selectedModel,
                        personaId: activePersona?.id,
                        repoUrl: model.selectedRepoUrl,
                        spaceId: model.selectedSpaceId.isEmpty ? nil : model.selectedSpaceId,
                        temporary: isTemporary ? true : nil
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                model.temporaryMode = false
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

    private func editLastMessage(
        chatId: String,
        body: String,
        harness: API.Harness? = nil,
        modelId: String? = nil,
        effort: API.ChatEffort? = nil
    ) async -> String? {
        companion.finishReveal()
        do {
            let resp = try await context.store.mutate(
                API.editLastChatMessage(
                    id: chatId,
                    body: API.ChatMessageEdit(
                        body: body,
                        effort: effort,
                        harness: harness,
                        model: modelId
                    )
                )
            )
            context.store.setData(resp.chat, for: API.getChat(id: chatId))
            let listReq = API.listChatMessages(id: chatId, limit: 200)
            if var existing = context.store.entry(listReq).data {
                existing.messages = existing.messages.filter { $0.seq < resp.message.seq } + [resp.message]
                context.store.setData(existing, for: listReq)
            }
            context.store.invalidate(QueryInvalidation(resources: ["chats"]))
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
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

    // MARK: - Full-Chat Export & Keyboard Shortcuts

    private func exportChatMenu(
        session: API.ChatSession,
        activePersona: API.Persona?,
        messages: [API.ChatMessage]
    ) -> some View {
        let p = theme.palette
        return Menu {
            Button("Export Markdown…") {
                runChatExport(session: session, messages: messages, mode: .markdown(includeTraces: false))
            }
            Button("Export Markdown (with tool traces)…") {
                runChatExport(session: session, messages: messages, mode: .markdown(includeTraces: true))
            }
            Button("Export PDF…") {
                runChatExport(session: session, messages: messages, mode: .pdf)
            }
            Divider()
            Button("Save Transcript to Knowledge…") {
                let md = ChatExportLogic.exportMarkdown(session: session, messages: messages, includeToolTraces: false)
                if let anchor = messages.last {
                    model.saveWikiBodyOverride = md
                    model.saveWikiTarget = anchor
                }
            }
            Button("Summarize & Save to Knowledge") {
                let prompt = ChatExportLogic.summarizeToKnowledgePrompt(chatTitle: session.title)
                Task { _ = await sendMessage(prompt, activePersona: activePersona) }
            }
            .disabled(session.state == .running)
            Divider()
            Menu("Keyboard Shortcuts") {
                Text("⌥↑ / ⌥↓ — Jump between turns")
                Text("⌘⇧C — Copy last reply")
                Text("⌘⇧O — Toggle Outline")
                Text("⌘⇧K — Open Context / Compact")
                Text("⌘⇧L — Toggle Live Voice")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .imageScale(.small)
                .foregroundStyle(p.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export chat or save to Knowledge")
    }

    private enum ChatExportMode {
        case markdown(includeTraces: Bool)
        case pdf
    }

    private func runChatExport(session: API.ChatSession, messages: [API.ChatMessage], mode: ChatExportMode) {
        let store = context.store
        Task { @MainActor in
            var eventsByRunId: [String: [API.RunEvent]] = [:]
            if case .markdown(true) = mode {
                let runIds = Set(messages.compactMap(\.runId).filter { !$0.isEmpty })
                for runId in runIds {
                    if let cached = store.entry(API.listRunEvents(id: runId)).data?.events {
                        eventsByRunId[runId] = cached
                    } else if let fetched = (await store.refetch(API.listRunEvents(id: runId))).data?.events {
                        eventsByRunId[runId] = fetched
                    }
                }
            }
            do {
                let url: URL?
                switch mode {
                case .markdown(let includeTraces):
                    url = try ChatExportHelper.exportMarkdown(
                        session: session,
                        messages: messages,
                        eventsByRunId: eventsByRunId,
                        includeToolTraces: includeTraces
                    )
                case .pdf:
                    url = try ChatExportHelper.exportPDF(
                        session: session,
                        messages: messages,
                        eventsByRunId: eventsByRunId
                    )
                }
                if let url {
                    context.showToast(ToastItemModel(id: "chat.export.ok", title: "Exported \(url.lastPathComponent)", tone: .success))
                }
            } catch {
                context.showToast(ToastItemModel(id: "chat.export.err", title: error.localizedDescription, tone: .error))
            }
        }
    }

    private func installKeyboardMonitor() {
        removeKeyboardMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            guard context.isActiveTab,
                  let window = context.window()?.window,
                  event.window === window,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  model.renameTargetId == nil,
                  model.forkTarget == nil,
                  model.saveWikiTarget == nil,
                  model.saveTemplateBody == nil else {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let action = ChatKeyboardNavLogic.resolveAction(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                command: flags.contains(.command),
                shift: flags.contains(.shift),
                option: flags.contains(.option),
                control: flags.contains(.control)
            ) else {
                return event
            }

            let messages = messagesRequest.flatMap { context.store.entry($0).data?.messages } ?? []

            switch action {
            case .jumpPreviousTurn, .jumpNextTurn:
                // Let Option+Up/Down move by paragraph when actively editing non-empty text.
                if let tv = window.firstResponder as? NSTextView, tv.isEditable, !tv.string.isEmpty {
                    return event
                }
                let dir = action == .jumpPreviousTurn ? -1 : 1
                guard let targetId = ChatKeyboardNavLogic.stepTurnMessageId(
                    messages: messages,
                    currentId: model.focusedTurnMessageId,
                    direction: dir
                ) else {
                    return event
                }
                model.focusedTurnMessageId = targetId
                model.scrollToken += 1
                model.scrollToMessageRequest = ChatScrollMessageRequest(token: model.scrollToken, messageId: targetId)
                return nil

            case .copyLastReply:
                guard let reply = ChatKeyboardNavLogic.lastAssistantReplyBody(in: messages) else {
                    return event
                }
                context.copyToClipboard(reply)
                context.showToast(ToastItemModel(id: "chat.shortcut.copy", title: "Copied last reply", tone: .success))
                return nil

            case .toggleOutline:
                guard chatId != nil else { return event }
                if model.inspectorOpen && model.inspectorTabId == ChatInspectorLogic.outlineTabId {
                    model.inspectorOpen = false
                } else {
                    model.inspectorTabId = ChatInspectorLogic.outlineTabId
                    model.inspectorOpen = true
                }
                return nil

            case .openContextCompact:
                guard chatId != nil else { return event }
                model.contextPopoverToken += 1
                return nil

            case .toggleLiveVoice:
                companionOpen = false
                liveVoiceOpen.toggle()
                return nil
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    // MARK: - Observation

    private func watchKey(session: API.ChatSession?, liveSince: String?) -> String {
        let activeRunId = session?.state == .running ? (session?.currentRunId ?? "") : ""
        let activeSince = session?.state == .running ? (liveSince ?? "") : ""
        let spaceId = session?.space?.id ?? ""
        return "\(chatId ?? "")|\(spaceId)|\(model.viewMode.rawValue)|\(model.selectedSpaceId)|\(model.selectedPersonaId)|\(model.searchQuery)|\(activeRunId)|\(activeSince)"
    }

    private func watch(session: API.ChatSession?, liveSince: String?) {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        var keys: [QueryKey] = []

        func track<V: Sendable>(_ req: APIRequest<V>) {
            store.observe(req)
            store.load(req)
            keys.append(req.key)
        }

        track(Self.bootRequest)
        track(Self.personasRequest)
        track(Self.spacesRequest)
        track(Self.modelsRequest)
        track(Self.suggestionsRequest)
        track(Self.dockRequest)
        track(Self.workflowsRequest)
        track(Self.repositoriesRequest)
        track(Self.promptTemplatesRequest)
        track(chatsRequest)
        if let spaceId = session?.space?.id {
            track(SpacesLogic.spaceChatsRequest(spaceId: spaceId))
        }
        if let sessionRequest { track(sessionRequest) }
        if let codeReviewRequest { track(codeReviewRequest) }
        if let playgroundRequest { track(playgroundRequest) }
        if let canvasesRequest { track(canvasesRequest) }
        if let messagesRequest { track(messagesRequest) }
        if let costsRequest { track(costsRequest) }
        if session?.state == .running, let runId = session?.currentRunId, !runId.isEmpty {
            track(ChatTurnActivity.liveEventsRequest(runId: runId, since: liveSince))
        }
        if let searchRequest { track(searchRequest) }
        watched = keys
    }
}
