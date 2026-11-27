import SwiftUI
import VesperCore

struct ChatScrollMessageRequest: Equatable {
    let token: Int
    let messageId: String
}

/// Tail-windowed native chat transcript (`ScrollView` + `VStack`, zero per-message web views).
/// Renders parsed `ChatMessageSegment`s, persona avatars, cards, media, proposals, and the live Work/Thinking card.
struct ChatTranscriptView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let session: API.ChatSession?
    let knownPersonaNames: [String]
    var personas: [API.Persona] = []
    var harnessModels: [API.ChatHarnessModels] = []
    var scrollToMessageRequest: ChatScrollMessageRequest?
    let onSendReply: @MainActor (String) -> Void
    var onQuoteMessage: (@MainActor (String, String?) -> Void)? = nil
    var onOpenThread: (@MainActor (String) -> Void)? = nil
    var onForkMessage: (@MainActor (API.ChatMessage) -> Void)? = nil
    var onSaveWiki: (@MainActor (API.ChatMessage) -> Void)? = nil
    var onSecondOpinion: (@MainActor (API.ChatMessage, API.Harness, String) -> Void)? = nil
    var replyVariants: ChatReplyVariantStore = ChatReplyVariantStore()
    var onSelectReplyVariant: (@MainActor (String, Int) -> Void)? = nil
    var onEditLastUserMessage: (@MainActor (String) async -> String?)? = nil
    var onRegenerateMessage: (@MainActor (API.ChatMessage, String, String, API.Harness?, String?) async -> String?)? = nil
    var readingMessageId: String? = nil
    var onToggleReadAloud: (@MainActor (API.ChatMessage, String?, String, String) -> Void)? = nil
    var onSelectionAction: (@MainActor (API.ChatMessage, String?, ChatSelectionAction, String) -> Void)? = nil

    @State private var watched: [QueryKey] = []
    @State private var parseCache = ChatParsedMessageCache()
    @State private var windowState = (chatId: "", limit: ChatTranscriptWindow.initialLimit)
    @State private var pendingPrependAnchor: String?

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: chatId, limit: 200)
    }
    private var workflowRunsRequest: APIRequest<API.WorkflowRuns> {
        API.listChatWorkflowRuns(id: chatId)
    }
    private var canvasesRequest: APIRequest<API.ChatCanvases> {
        API.listChatCanvases(id: chatId)
    }
    private var audioRequest: APIRequest<API.ChatAudios> {
        API.listChatAudio(id: chatId)
    }
    private var videosRequest: APIRequest<API.ChatVideos> {
        API.listChatVideos(id: chatId)
    }
    private var pushRequestsRequest: APIRequest<API.PushRequestList> {
        API.listPushRequests(id: chatId)
    }
    private var asidesRequest: APIRequest<API.ChatAsideList> {
        API.listChatAsides(id: chatId)
    }

    private var isRunning: Bool {
        session?.state == .running
    }

    var body: some View {
        let store = context.store
        let messagesEntry = store.entry(messagesRequest)
        let messages = messagesEntry.data?.messages ?? []
        let workflowRuns = store.entry(workflowRunsRequest).data?.runs ?? []
        let canvases = store.entry(canvasesRequest).data?.canvases ?? []
        let audios = store.entry(audioRequest).data?.audio ?? []
        let videos = store.entry(videosRequest).data?.videos ?? []
        let pushes = ChatPushPlacement.place(
            store.entry(pushRequestsRequest).data?.requests ?? [],
            messages: messages,
            running: isRunning,
            currentRunId: session?.currentRunId,
            hasMore: messagesEntry.data?.hasMore ?? false
        )
        let turnWindows = ChatTurnActivity.turnWindows(for: messages)
        let endedTurns = ChatTurnActivity.endedTurns(for: messages, running: isRunning)
        let liveSince = ChatTurnActivity.runningSince(for: messages)
        let historicalRunIds = ChatTurnActivity.historicalRunIds(
            for: messages,
            turnWindows: turnWindows,
            endedTurns: endedTurns
        )
        let waitingForMessages = messages.isEmpty && (session?.messageCount ?? 0) > 0
        let asides = store.entry(asidesRequest).data?.asides ?? []
        let asidesByReply = ChatAsideLogic.asidesByReply(
            asides,
            turnWindows: turnWindows,
            running: isRunning,
            runningSince: liveSince
        )
        let liveAsides = isRunning ? ChatAsideLogic.asidesInWindow(asides, since: liveSince, until: nil) : []

        // Pre-index media by messageId once in O(M) instead of filtering per message row.
        var audiosByMessage: [String: [API.ChatAudio]] = [:]
        var orphanAudios: [API.ChatAudio] = []
        for audio in audios {
            if let messageId = audio.messageId {
                audiosByMessage[messageId, default: []].append(audio)
            } else {
                orphanAudios.append(audio)
            }
        }
        var videosByMessage: [String: [API.ChatVideo]] = [:]
        var orphanVideos: [API.ChatVideo] = []
        for video in videos {
            if let messageId = video.messageId {
                videosByMessage[messageId, default: []].append(video)
            } else {
                orphanVideos.append(video)
            }
        }

        let loadState = ChatTranscriptWindow.loadState(
            hasData: messagesEntry.hasData,
            hasError: messagesEntry.error != nil,
            isEmpty: messages.isEmpty
        )
        let baseLimit = windowState.chatId == chatId ? windowState.limit : ChatTranscriptWindow.initialLimit
        let queryMessageId = context.match.query["message"]
        let requestedTargetId = scrollToMessageRequest?.messageId ?? queryMessageId
        let effectiveLimit = ChatTranscriptWindow.effectiveLimit(
            messageIds: messages.map(\.id),
            visibleLimit: baseLimit,
            targetMessageId: requestedTargetId
        )
        let visibleRange = ChatTranscriptWindow.visibleRange(totalCount: messages.count, visibleLimit: effectiveLimit)
        let hiddenCount = visibleRange.lowerBound
        let visibleMessages = visibleRange.map { idx in (index: idx, message: messages[idx]) }
        let lastUserMessage = messages.last(where: { $0.role == .user })
        let lastAssistantMessage = messages.last(where: { $0.role == .assistant })
        let canEditOrRegenerate = !isRunning && session?.archived != true
        let lastAssistantFollowsLastUser = lastUserMessage != nil
            && lastAssistantMessage != nil
            && (lastAssistantMessage?.seq ?? 0) > (lastUserMessage?.seq ?? 0)

        return Group {
            switch loadState {
            case .error:
                QueryErrorView(message: messagesEntry.error?.userMessage ?? "Couldn\u{2019}t load messages.") {
                    Task { await store.refetch(messagesRequest) }
                }
            case .loading:
                VStack(alignment: .leading, spacing: 14) {
                    SkeletonBar(height: 22)
                    SkeletonBar(height: 64)
                    SkeletonBar(height: 44)
                }
                .padding(24)
                .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
            case .ready:
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if hiddenCount > 0 {
                                earlierMessagesButton(hiddenCount: hiddenCount) {
                                    let anchorId = visibleMessages.first?.message.id
                                    let nextLimit = ChatTranscriptWindow.expandedLimit(
                                        currentLimit: effectiveLimit,
                                        totalCount: messages.count
                                    )
                                    windowState = (chatId: chatId, limit: nextLimit)
                                    pendingPrependAnchor = anchorId
                                }
                            }

                            if hiddenCount == 0 && !pushes.leading.isEmpty {
                                ChatPushRequestStackView(requests: pushes.leading)
                            }

                            ForEach(Array(visibleMessages.enumerated()), id: \.element.message.id) { rowOffset, item in
                                let idx = item.index
                                let message = item.message
                                let nextBody = idx + 1 < messages.count ? messages[idx + 1].bodyMd : nil
                                let isUser = message.role == .user
                                let isLastUser = canEditOrRegenerate && message.id == lastUserMessage?.id
                                let isLastAssistant = canEditOrRegenerate && lastAssistantFollowsLastUser && message.id == lastAssistantMessage?.id
                                let variantState: (items: [ChatReplyVariant], activeIndex: Int)? = {
                                    guard message.role == .assistant,
                                          message.id == lastAssistantMessage?.id,
                                          lastAssistantFollowsLastUser,
                                          let uId = lastUserMessage?.id else { return nil }
                                    let live = ChatReplyVariant(
                                        id: message.id,
                                        bodyMd: message.bodyMd,
                                        model: message.model,
                                        harness: message.harness?.rawValue,
                                        createdAt: message.createdAt
                                    )
                                    let resolved = replyVariants.variants(chatId: chatId, userMessageId: uId, liveReply: live)
                                    return resolved.items.count > 1 ? resolved : nil
                                }()
                                let activeVariant = variantState.map { $0.items[$0.activeIndex] }
                                let effectiveBodyMd = activeVariant?.bodyMd ?? message.bodyMd
                                let parsed = parseCache.parsed(
                                    messageId: activeVariant?.id ?? message.id,
                                    bodyMd: effectiveBodyMd,
                                    extractSources: !isUser,
                                    knownPersonaNames: knownPersonaNames
                                )
                                let persona = message.persona ?? session?.persona
                                let speakerName = persona?.name ?? session?.agent.name ?? "Assistant"
                                let isFindCurrent = !context.find.query.isEmpty && context.find.current == rowOffset
                                ChatMessageRowView(
                                    chatId: chatId,
                                    message: message,
                                    displayedBodyMd: effectiveBodyMd,
                                    parsed: parsed,
                                    nextMessageBody: nextBody,
                                    personaId: persona?.id,
                                    speakerName: speakerName,
                                    isRunning: isRunning,
                                    isLastUserMessage: isLastUser,
                                    isLastAssistantMessage: isLastAssistant,
                                    lastUserMessageId: lastUserMessage?.id,
                                    lastUserMessageBody: lastUserMessage?.bodyMd,
                                    variants: variantState?.items ?? [],
                                    activeVariantIndex: variantState?.activeIndex ?? 0,
                                    turnWindow: turnWindows[message.id],
                                    endedTurn: endedTurns[message.id],
                                    workflowRuns: parsed.hasWorkflowRunSegment ? workflowRuns : [],
                                    canvases: parsed.hasCanvasSegment ? canvases : [],
                                    audios: audiosByMessage[message.id] ?? [],
                                    videos: videosByMessage[message.id] ?? [],
                                    personas: personas,
                                    harnessModels: harnessModels,
                                    findRow: rowOffset,
                                    onSendReply: onSendReply,
                                    onQuoteMessage: onQuoteMessage,
                                    onOpenThread: onOpenThread,
                                    onForkMessage: onForkMessage,
                                    onSaveWiki: onSaveWiki,
                                    onSecondOpinion: onSecondOpinion,
                                    onSelectReplyVariant: onSelectReplyVariant,
                                    onEditLastUserMessage: onEditLastUserMessage,
                                    onRegenerateMessage: onRegenerateMessage,
                                    isReadingAloud: readingMessageId == message.id,
                                    onToggleReadAloud: onToggleReadAloud,
                                    onSelectionAction: onSelectionAction,
                                    onScrollToSelf: {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            proxy.scrollTo(message.id, anchor: .top)
                                        }
                                    }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isFindCurrent ? theme.palette.accent : .clear, lineWidth: 1.5)
                                        .padding(-4)
                                )
                                .id(message.id)

                                if let asked = asidesByReply[message.id] {
                                    ChatReplyAsidesView(parentChatId: chatId, asides: asked, speakerName: speakerName)
                                }
                                if let placed = pushes.byMessage[message.id] {
                                    ChatPushRequestStackView(requests: placed)
                                }
                                if let placed = pushes.afterMessage[message.id] {
                                    ChatPushRequestStackView(requests: placed)
                                }
                            }

                            // Unattached generated media (not linked to a specific message)
                            ForEach(orphanAudios, id: \.id) { audio in
                                ChatAudioCardView(chatId: chatId, audio: audio)
                            }
                            ForEach(orphanVideos, id: \.id) { video in
                                ChatVideoCardView(chatId: chatId, video: video)
                            }

                            if !pushes.trailing.isEmpty {
                                ChatPushRequestStackView(requests: pushes.trailing)
                            }

                            if isRunning {
                                ChatLiveActivityCardView(
                                    chatId: chatId,
                                    runId: session?.currentRunId,
                                    since: liveSince,
                                    waitingForMessages: waitingForMessages,
                                    speaker: session?.speaker ?? session?.persona,
                                    fallbackSpeakerName: session?.agent.name ?? "Assistant"
                                )
                                .id("live-activity")
                                ChatLiveAsidesView(parentChatId: chatId, asides: liveAsides)
                            }
                            if !pushes.live.isEmpty {
                                ChatPushRequestStackView(requests: pushes.live)
                            }

                            if let sessionError = session?.error, !sessionError.isEmpty, session?.state == .failed {
                                failedBanner(sessionError)
                            }

                            ChatTranscriptProposalsSlot(chatId: chatId, canvases: canvases)

                            Color.clear
                                .frame(height: 1)
                                .id("transcript-bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 860, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: effectiveLimit) { _, _ in
                        guard let anchorId = pendingPrependAnchor else { return }
                        pendingPrependAnchor = nil
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                    }
                    .onChange(of: messages.count) { oldCount, newCount in
                        guard windowState.chatId == chatId else { return }
                        let adjusted = ChatTranscriptWindow.adjustedLimitForAppend(
                            currentLimit: windowState.limit,
                            previousCount: oldCount,
                            newCount: newCount
                        )
                        if adjusted != windowState.limit {
                            windowState = (chatId: chatId, limit: adjusted)
                        }
                    }
                    .onChange(of: messages.last?.id) { oldId, lastId in
                        guard oldId != nil, lastId != nil else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: isRunning) { wasRunning, running in
                        if running {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("transcript-bottom", anchor: .bottom)
                            }
                        } else if wasRunning {
                            let finishedRunId = session?.currentRunId ?? messages.last(where: { $0.runId != nil })?.runId
                            if let finishedRunId, !finishedRunId.isEmpty {
                                Task { _ = await context.store.refetch(API.listRunEvents(id: finishedRunId)) }
                            }
                        }
                    }
                    .task(id: historicalRunIds) {
                        for runId in historicalRunIds {
                            context.store.load(API.listRunEvents(id: runId))
                        }
                    }
                    .task(id: queryMessageId) {
                        guard let targetMsg = queryMessageId, !targetMsg.isEmpty else { return }
                        if effectiveLimit > baseLimit {
                            windowState = (chatId: chatId, limit: effectiveLimit)
                        }
                        proxy.scrollTo(targetMsg, anchor: .center)
                    }
                    .onChange(of: scrollToMessageRequest) { _, request in
                        guard let request, !request.messageId.isEmpty else { return }
                        if effectiveLimit > baseLimit {
                            windowState = (chatId: chatId, limit: effectiveLimit)
                        }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(request.messageId, anchor: .center)
                        }
                    }
                    .onChange(of: visibleMessages.map { "\($0.message.id):\($0.message.bodyMd.count)" }, initial: true) { _, _ in
                        context.find.texts = visibleMessages.map { $0.message.bodyMd }
                    }
                    .onChange(of: context.find.current) { _, idx in
                        guard let idx, visibleMessages.indices.contains(idx) else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(visibleMessages[idx].message.id, anchor: .center)
                        }
                    }
                }
                .id(chatId)
            }
        }
        .onChange(of: chatId) { _, _ in
            parseCache.removeAll()
            pendingPrependAnchor = nil
        }
        .task(id: chatId) { watch() }
        .task(id: pollId) { await pollWhileActive() }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
    }

    private func earlierMessagesButton(hiddenCount: Int, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .imageScale(.small)
                    Text(ChatTranscriptWindow.earlierButtonLabel(hiddenCount: hiddenCount))
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                }
                .foregroundStyle(p.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(p.surface, in: Capsule())
                .overlay(Capsule().stroke(p.border))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    private func failedBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            Text(message)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            Spacer(minLength: 8)
        }
        .padding(12)
        .background(
            theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    // MARK: - Observation & Polling

    private var pollId: String {
        "\(chatId)|\(isRunning)|\(hasAnsweringAside)"
    }

    /// An aside can still be answering after the reply it asked about has finished.
    private var hasAnsweringAside: Bool {
        context.store.entry(asidesRequest).data?.asides.contains { $0.state == .running } ?? false
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

        track(messagesRequest)
        track(workflowRunsRequest)
        track(canvasesRequest)
        track(audioRequest)
        track(videosRequest)
        track(pushRequestsRequest)
        track(asidesRequest)
        watched = keys
    }

    private func pollWhileActive() async {
        guard isRunning || hasAnsweringAside else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            if isRunning {
                _ = await context.store.refetch(API.getChat(id: chatId))
                _ = await context.store.refetch(messagesRequest)
                _ = await context.store.refetch(API.listChatFollowups(id: chatId))
            }
            _ = await context.store.refetch(asidesRequest)
        }
    }
}

// MARK: - Isolated Message Row

private struct ChatMessageRowView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let message: API.ChatMessage
    let displayedBodyMd: String
    let parsed: ParsedChatMessage
    let nextMessageBody: String?
    let personaId: String?
    let speakerName: String
    let isRunning: Bool
    let isLastUserMessage: Bool
    let isLastAssistantMessage: Bool
    let lastUserMessageId: String?
    let lastUserMessageBody: String?
    let variants: [ChatReplyVariant]
    let activeVariantIndex: Int
    let turnWindow: ChatTurnWindow?
    let endedTurn: ChatEndedTurn?
    let workflowRuns: [API.WorkflowRun]
    let canvases: [API.ChatCanvasSummary]
    let audios: [API.ChatAudio]
    let videos: [API.ChatVideo]
    let personas: [API.Persona]
    let harnessModels: [API.ChatHarnessModels]
    let findRow: Int
    let onSendReply: @MainActor (String) -> Void
    let onQuoteMessage: (@MainActor (String, String?) -> Void)?
    let onOpenThread: (@MainActor (String) -> Void)?
    let onForkMessage: (@MainActor (API.ChatMessage) -> Void)?
    let onSaveWiki: (@MainActor (API.ChatMessage) -> Void)?
    let onSecondOpinion: (@MainActor (API.ChatMessage, API.Harness, String) -> Void)?
    let onSelectReplyVariant: (@MainActor (String, Int) -> Void)?
    let onEditLastUserMessage: (@MainActor (String) async -> String?)?
    let onRegenerateMessage: (@MainActor (API.ChatMessage, String, String, API.Harness?, String?) async -> String?)?
    let isReadingAloud: Bool
    let onToggleReadAloud: (@MainActor (API.ChatMessage, String?, String, String) -> Void)?
    let onSelectionAction: (@MainActor (API.ChatMessage, String?, ChatSelectionAction, String) -> Void)?
    let onScrollToSelf: @MainActor () -> Void

    @State private var togglingBookmark = false
    @State private var isReplyCollapsed = false
    @State private var isEditingUserMessage = false
    @State private var editDraft = ""
    @State private var editSubmitting = false
    @State private var editError: String?
    @State private var regenerating = false

    private var isFoldableReply: Bool {
        message.role == .assistant && ChatReplyFoldingLogic.isFoldableReply(displayedBodyMd)
    }

    private var previewRequest: APIRequest<API.LinkPreviews>? {
        guard message.role == .assistant, parsed.sources.contains(where: { !$0.url.isEmpty }) else { return nil }
        return API.listLinkPreviews(messageId: message.id)
    }

    private func handleMarkdownLink(_ target: MarkdownLinkTarget, anchor: MarkdownLinkAnchor?) -> Bool {
        if case .citation(let n) = target,
           let source = parsed.sources.first(where: { $0.number == n }) {
            if let req = previewRequest { context.store.load(req) }
            ChatCitationBubblePresenter.shared.toggle(
                messageId: message.id,
                source: source,
                previewRequest: previewRequest,
                anchor: anchor,
                context: context,
                theme: theme
            )
            return true
        }
        return false
    }

    private func toggleBookmark() {
        guard !togglingBookmark else { return }
        togglingBookmark = true
        let next = !(message.bookmarked == true)
        Task {
            defer { togglingBookmark = false }
            do {
                _ = try await context.store.mutate(
                    API.updateChatMessageBookmark(
                        id: chatId,
                        messageId: message.id,
                        body: API.ChatBookmarkUpdate(bookmarked: next)
                    ),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
            } catch {
                context.showToast(ToastItemModel(id: "chat.bookmark.err", title: "Couldn’t update bookmark", tone: .error))
            }
        }
    }

    var body: some View {
        let p = theme.palette
        let citationNumbers = parsed.sources.compactMap(\.number)

        if message.role == .user {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if message.bookmarked == true {
                            TonePill(label: "Pinned", tone: "review")
                        }
                        Button {
                            toggleBookmark()
                        } label: {
                            Image(systemName: message.bookmarked == true ? "bookmark.fill" : "bookmark")
                                .imageScale(.small)
                                .foregroundStyle(message.bookmarked == true ? p.accent : p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .disabled(togglingBookmark)
                        .help(message.bookmarked == true ? "Remove bookmark" : "Bookmark message")

                        if let onQuoteMessage {
                            Button {
                                onQuoteMessage(parsed.typedBody, nil)
                            } label: {
                                Image(systemName: "arrowshape.turn.up.left")
                                    .imageScale(.small)
                                    .foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Quote in composer")
                        }

                        if isLastUserMessage, onEditLastUserMessage != nil, !isEditingUserMessage {
                            Button {
                                editDraft = parsed.typedBody
                                editError = nil
                                isEditingUserMessage = true
                            } label: {
                                Image(systemName: "pencil")
                                    .imageScale(.small)
                                    .foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Edit message and re-send")
                        }

                        if let onForkMessage {
                            Button {
                                onForkMessage(message)
                            } label: {
                                Image(systemName: "arrow.triangle.branch")
                                    .imageScale(.small)
                                    .foregroundStyle(p.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Fork conversation from here")
                        }
                    }
                    ChatContextChipsView(stripped: parsed.context, refs: message.contextRefs ?? [])
                    VStack(alignment: .leading, spacing: 8) {
                        if isEditingUserMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $editDraft)
                                    .font(.system(size: theme.pointSize(.body)))
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 64, maxHeight: 220)
                                    .padding(6)
                                    .background(p.background, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.accent.opacity(0.6)))
                                if let editError {
                                    Text(editError)
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                }
                                HStack(spacing: 8) {
                                    Spacer()
                                    Button("Cancel") {
                                        isEditingUserMessage = false
                                        editError = nil
                                    }
                                    .buttonStyle(.vesper())
                                    .keyboardShortcut(.cancelAction)
                                    .disabled(editSubmitting)

                                    Button(editSubmitting ? "Sending…" : "Save & Re-send") {
                                        submitUserEdit()
                                    }
                                    .buttonStyle(.vesper(.primary))
                                    .keyboardShortcut(.return, modifiers: [.command])
                                    .disabled(editSubmitting || editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .frame(minWidth: 340, maxWidth: 620)
                        } else if !parsed.typedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownView(markdown: parsed.typedBody, textStyle: .chat, chat: true, findRow: findRow)
                        }
                        if let attachments = message.attachments, !attachments.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(attachments, id: \.id) { att in
                                    ChatAttachmentCardView(attachment: att)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
                    .frame(maxWidth: 640, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                if let endedTurn, let runId = message.runId, !runId.isEmpty {
                    ChatEndedTurnSectionView(
                        runId: runId,
                        ended: endedTurn,
                        personaId: personaId,
                        speakerName: speakerName
                    )
                }
            }
        } else if message.role == .system {
            VStack(alignment: .leading, spacing: 10) {
                if let endedTurn, let runId = message.runId, !runId.isEmpty {
                    ChatEndedTurnSectionView(
                        runId: runId,
                        ended: endedTurn,
                        personaId: personaId,
                        speakerName: speakerName
                    )
                }
                ForEach(audios, id: \.id) { audio in
                    ChatAudioCardView(chatId: chatId, audio: audio)
                }
                ForEach(videos, id: \.id) { video in
                    ChatVideoCardView(chatId: chatId, video: video)
                }
                HStack(spacing: 10) {
                    Rectangle().fill(p.border).frame(height: 1)
                    Text(message.bodyMd)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(p.border).frame(height: 1)
                }
                .padding(.vertical, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WorkPersonaAvatarView(
                        id: personaId,
                        handle: nil,
                        name: speakerName,
                        size: 24,
                        preferCharacter: true
                    )
                    Text(speakerName)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(APIDate.shortAgo(message.createdAt))
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                    if let cost = ChatTurnActivity.replyCost(message.costUsd) {
                        Text("· \(cost)")
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                    }
                    if message.bookmarked == true {
                        TonePill(label: "Pinned", tone: "review")
                    }
                    if variants.count > 1, let uId = lastUserMessageId, let onSelectReplyVariant {
                        HStack(spacing: 4) {
                            Button {
                                onSelectReplyVariant(uId, max(0, activeVariantIndex - 1))
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(activeVariantIndex <= 0)

                            Text("\(activeVariantIndex + 1)/\(variants.count)")
                                .font(.system(size: theme.pointSize(.micro), weight: .medium, design: .monospaced))

                            Button {
                                onSelectReplyVariant(uId, min(variants.count - 1, activeVariantIndex + 1))
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(activeVariantIndex >= variants.count - 1)
                        }
                        .foregroundStyle(p.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.border))
                        .help("Switch between regenerated reply variants")
                    }
                    Spacer(minLength: 8)
                    assistantActionBar
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let turnWindow, let runId = message.runId, !runId.isEmpty {
                        ChatTurnStepsCardView(
                            runId: runId,
                            outcome: .done,
                            since: turnWindow.since,
                            until: message.createdAt,
                            end: APIDate.epoch(message.createdAt),
                            personaId: personaId
                        )
                    }

                    // A reply that just arrived reveals word by word while the persona talks; a click
                    // shows the rest. Once revealed it renders its cards and fences as usual.
                    let companion = ChatCompanions.companion(for: chatId)
                    if companion.revealingId == message.id {
                        MarkdownView(markdown: companion.shown, textStyle: .chat, chat: true, citations: citationNumbers, findRow: findRow, onLinkWithAnchor: handleMarkdownLink)
                            .contentShape(Rectangle())
                            .onTapGesture { companion.finishReveal() }
                    } else if isReplyCollapsed && isFoldableReply {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ChatReplyFoldingLogic.collapsedPreview(message.bodyMd))
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(5)
                            Button {
                                isReplyCollapsed = false
                            } label: {
                                Label("Expand full reply (\(ChatReplyFoldingLogic.lineCount(message.bodyMd)) lines)", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.vesper())
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                    } else {
                        ForEach(Array(parsed.segments.enumerated()), id: \.offset) { _, segment in
                            segmentView(segment, citationNumbers: citationNumbers)
                        }
                        if !parsed.entityRefs.isEmpty {
                            ChatEntityCardsStripView(refs: parsed.entityRefs)
                        }
                        if isFoldableReply {
                            HStack(spacing: 10) {
                                Button {
                                    isReplyCollapsed = true
                                    onScrollToSelf()
                                } label: {
                                    Label("Collapse reply", systemImage: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(p.tertiaryText)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    onScrollToSelf()
                                } label: {
                                    Label("Jump to top", systemImage: "arrow.up")
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(p.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 2)
                        }
                    }

                    if let attachments = message.attachments, !attachments.isEmpty {
                        ForEach(attachments, id: \.id) { att in
                            ChatAttachmentCardView(attachment: att)
                        }
                    }
                    ForEach(audios, id: \.id) { audio in
                        ChatAudioCardView(chatId: chatId, audio: audio)
                    }
                    ForEach(videos, id: \.id) { video in
                        ChatVideoCardView(chatId: chatId, video: video)
                    }

                    ChatSourcesChipsView(sources: parsed.sources, citations: message.citations ?? [], messageId: message.id)
                }
                .padding(.leading, 32)
            }
        }
    }

    @ViewBuilder
    private var assistantActionBar: some View {
        let p = theme.palette
        let otherPersonas = personas.filter { $0.id != personaId }
        let availableModels = harnessModels.filter { $0.available && !$0.models.isEmpty }

        HStack(spacing: 8) {
            if isFoldableReply {
                Button {
                    isReplyCollapsed.toggle()
                } label: {
                    Image(systemName: isReplyCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help(isReplyCollapsed ? "Expand reply" : "Collapse reply")
            }

            if let onQuoteMessage {
                Button {
                    onQuoteMessage(message.bodyMd, speakerName)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Quote in composer")
            }

            if let onOpenThread {
                Button {
                    onOpenThread(message.id)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Start thread on this message")
            }

            if let onToggleReadAloud {
                Button {
                    onToggleReadAloud(message, personaId, speakerName, displayedBodyMd)
                } label: {
                    Image(systemName: isReadingAloud ? "stop.circle.fill" : "speaker.wave.2")
                        .imageScale(.small)
                        .foregroundStyle(isReadingAloud ? p.accent : p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help(isReadingAloud ? "Stop reading aloud" : "Read message aloud")
            }

            Button {
                toggleBookmark()
            } label: {
                Image(systemName: message.bookmarked == true ? "bookmark.fill" : "bookmark")
                    .imageScale(.small)
                    .foregroundStyle(message.bookmarked == true ? p.accent : p.tertiaryText)
            }
            .buttonStyle(.plain)
            .disabled(togglingBookmark)
            .help(message.bookmarked == true ? "Remove bookmark" : "Bookmark message")

            if isLastAssistantMessage,
               let userId = lastUserMessageId,
               let userBody = lastUserMessageBody,
               let onRegenerateMessage {
                Button {
                    triggerRegenerate(userId: userId, userBody: userBody, harness: nil, modelId: nil, handler: onRegenerateMessage)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .disabled(regenerating)
                .help("Regenerate reply")
            }

            if let onSecondOpinion, !availableModels.isEmpty {
                Menu {
                    ForEach(availableModels, id: \.harness.rawValue) { group in
                        Section(group.label) {
                            ForEach(group.models, id: \.id) { item in
                                Button(item.label) {
                                    onSecondOpinion(message, group.harness, item.id)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Second opinion from another model")
            }

            Button {
                context.copyToClipboard(displayedBodyMd)
                context.showToast(ToastItemModel(id: "chat.copy.\(message.id)", title: "Copied message", tone: .success))
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Copy markdown")

            Menu {
                if isLastAssistantMessage,
                   let userId = lastUserMessageId,
                   let userBody = lastUserMessageBody,
                   let onRegenerateMessage,
                   !availableModels.isEmpty {
                    Menu("Regenerate with…") {
                        ForEach(availableModels, id: \.harness.rawValue) { group in
                            Section(group.label) {
                                ForEach(group.models, id: \.id) { item in
                                    Button(item.label) {
                                        triggerRegenerate(
                                            userId: userId,
                                            userBody: userBody,
                                            harness: group.harness,
                                            modelId: item.id,
                                            handler: onRegenerateMessage
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                if let onQuoteMessage, !otherPersonas.isEmpty {
                    Menu("Ask another persona") {
                        ForEach(otherPersonas, id: \.id) { other in
                            Button("@\(other.name)") {
                                onQuoteMessage(message.bodyMd, other.name)
                            }
                        }
                    }
                }
                if let onForkMessage {
                    Button("Fork conversation from here…") {
                        onForkMessage(message)
                    }
                }
                if let onSaveWiki {
                    Button("Save to Knowledge…") {
                        onSaveWiki(message)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    private func submitUserEdit() {
        guard !editSubmitting, let onEditLastUserMessage else { return }
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editSubmitting = true
        editError = nil
        Task {
            defer { editSubmitting = false }
            if let err = await onEditLastUserMessage(trimmed) {
                editError = err
            } else {
                isEditingUserMessage = false
            }
        }
    }

    private func triggerRegenerate(
        userId: String,
        userBody: String,
        harness: API.Harness?,
        modelId: String?,
        handler: @escaping @MainActor (API.ChatMessage, String, String, API.Harness?, String?) async -> String?
    ) {
        guard !regenerating else { return }
        regenerating = true
        Task {
            defer { regenerating = false }
            if let err = await handler(message, userId, userBody, harness, modelId) {
                context.showToast(ToastItemModel(id: "chat.regen.err", title: err, tone: .error))
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatMessageSegment, citationNumbers: [Int]) -> some View {
        switch segment {
        case .markdown(let text):
            MarkdownView(
                markdown: text,
                textStyle: .chat,
                chat: true,
                citations: citationNumbers,
                findRow: findRow,
                onLinkWithAnchor: handleMarkdownLink,
                onSelectionAction: onSelectionAction.map { handler in
                    { @MainActor action, excerpt in
                        handler(message, message.role == .assistant ? speakerName : nil, action, excerpt)
                    }
                }
            )
        case .embedded(let kind, let source, let info, let index):
            EmbeddedBlockView(kind: kind, source: source, messageID: message.id, info: info, index: index)
        case .chart(let spec):
            ChatChartCardView(spec: spec)
        case .stats(let spec):
            ChatStatsCardView(spec: spec)
        case .diff(let spec):
            ChatDiffCardView(spec: spec)
        case .compare(let spec):
            ChatCompareCardView(spec: spec)
        case .timeline(let spec):
            ChatTimelineCardView(spec: spec)
        case .tree(let spec):
            ChatTreeCardView(spec: spec)
        case .compareImages(let spec):
            ChatCompareImagesCardView(spec: spec)
        case .graph(let spec):
            ChatGraphCardView(spec: spec)
        case .plot(let spec):
            ChatPlotCardView(spec: spec)
        case .dataTable(let spec):
            ChatDataTableCardView(spec: spec)
        case .codeGroup(let spec):
            ChatCodeGroupCardView(spec: spec)
        case .kv(let spec):
            ChatKVCardView(spec: spec)
        case .jsonTree(let spec):
            ChatJSONTreeCardView(spec: spec)
        case .http(let spec):
            ChatHTTPCardView(spec: spec)
        case .tabs(let spec):
            ChatTabsCardView(spec: spec, citations: citationNumbers, onLinkWithAnchor: handleMarkdownLink)
        case .details(let spec):
            ChatDetailsCardView(spec: spec, citations: citationNumbers, onLinkWithAnchor: handleMarkdownLink)
        case .choices(let card):
            ChatChoicesCardView(
                card: card,
                chosenOption: card.chosenOption(nextMessageBody: nextMessageBody),
                disabled: isRunning,
                onSelect: onSendReply
            )
        case .recommend(let cards):
            ChatRecommendCardsView(messageId: message.id, cards: cards, onSend: onSendReply)
        case .gallery(let spec):
            ChatGalleryCardView(messageId: message.id, spec: spec)
        case .product(let spec):
            ChatProductCardView(messageId: message.id, spec: spec)
        case .workflowRun(let card):
            ChatWorkflowRunCardView(chatId: chatId, messageId: message.id, card: card, runs: workflowRuns)
        case .canvas(let id):
            ChatCanvasRefCardView(chatId: chatId, canvasId: id, canvases: canvases)
        case .pdf(let id):
            ChatPDFCardView(itemId: id)
        case .researchPlan(let plan):
            ChatResearchPlanCardView(chatId: chatId, messageId: message.id, plan: plan)
        case .callout(let callout):
            ChatCalloutView(callout: callout, citations: citationNumbers, onLinkWithAnchor: handleMarkdownLink)
        case .checklist(let checklist):
            ChatChecklistCardView(
                chatId: chatId,
                messageId: message.id,
                checklist: checklist,
                persistedState: message.checklistState
            )
        case .invalidBlock(let kind, let error, let source):
            ChatInvalidBlockView(kind: kind, error: error, source: source)
        }
    }
}

// MARK: - Finished Working Card in History

/// What the live working card leaves behind in chat history once a turn finishes (or stops/fails):
/// a compact one-line strip ("Worked for 2m 14s · Thought for 32s · 7 steps") that expands in place to show the
/// turn's steps, plus an inline collapsible thinking disclosure block when `showLiveThinking` is enabled.
/// Plain replies with no tool work render no working strip (though they still show finished thinking blocks
/// when `showLiveThinking` is on).
private struct ChatTurnStepsCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let runId: String
    let outcome: ChatTurnOutcome
    let since: String?
    let until: String?
    let end: TimeInterval?
    var personaId: String? = nil

    var body: some View {
        let events = context.store.entry(API.listRunEvents(id: runId)).data?.events ?? []
        let turn = ChatTurnActivity.finishedTurn(
            events: events.map(ChatRunEvent.init),
            outcome: outcome,
            since: since,
            until: until,
            end: end
        )
        let showThinking = showLiveThinking && !turn.thinkingBlocks.isEmpty
        if showThinking || !turn.steps.isEmpty || !turn.memoryDiffs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if showThinking {
                    ChatFinishedThinkingDisclosureView(
                        blocks: turn.thinkingBlocks,
                        thinkingDurationMs: turn.thinkingDurationMs
                    )
                }
                if !turn.steps.isEmpty {
                    ChatFinishedTurnCardView(turn: turn, outcome: outcome)
                }
                if !turn.memoryDiffs.isEmpty {
                    ChatMemoryDiffPillsView(diffs: turn.memoryDiffs, personaId: personaId)
                }
            }
        }
    }
}

/// Renders a finished working card with persona identity for turns that ended without a reply
/// (failed or stopped/interrupted). Renders nothing if the turn did no tool work and has no visible thinking.
private struct ChatEndedTurnSectionView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let runId: String
    let ended: ChatEndedTurn
    let personaId: String?
    let speakerName: String

    var body: some View {
        let events = context.store.entry(API.listRunEvents(id: runId)).data?.events ?? []
        let turn = ChatTurnActivity.finishedTurn(
            events: events.map(ChatRunEvent.init),
            outcome: ended.outcome,
            since: ended.since,
            until: ended.until,
            end: ended.end
        )
        let showThinking = showLiveThinking && !turn.thinkingBlocks.isEmpty

        if showThinking || !turn.steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WorkPersonaAvatarView(
                        id: personaId,
                        handle: nil,
                        name: speakerName,
                        size: 24,
                        preferCharacter: true
                    )
                    Text(speakerName)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(theme.palette.text)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if showThinking {
                        ChatFinishedThinkingDisclosureView(
                            blocks: turn.thinkingBlocks,
                            thinkingDurationMs: turn.thinkingDurationMs
                        )
                    }
                    if !turn.steps.isEmpty {
                        ChatFinishedTurnCardView(turn: turn, outcome: ended.outcome)
                    }
                }
                .padding(.leading, 32)
            }
        }
    }
}

/// Clean collapsible disclosure block for a finished turn's reasoning blocks when `showLiveThinking` is on.
private struct ChatFinishedThinkingDisclosureView: View {
    @Environment(\.vesperTheme) private var theme

    let blocks: [ChatThinkingBlock]
    let thinkingDurationMs: Int?

    @State private var isExpanded = false

    var body: some View {
        let p = theme.palette
        let title: String = {
            if let ms = thinkingDurationMs, ms >= 1000 {
                return "Thought for \(ChatTurnActivity.formatSpan(ms: ms))"
            }
            return "Thinking"
        }()

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                    Text(title)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(1)
                    if blocks.count > 1 {
                        Text("· \(blocks.count) blocks")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide" : "Show")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                            if idx > 0 {
                                Divider()
                            }
                            Text(block.text)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

/// Live inline reasoning panel shown inside the running turn when `showLiveThinking` is enabled.
private struct ChatLiveThinkingStreamView: View {
    @Environment(\.vesperTheme) private var theme

    let blocks: [ChatThinkingBlock]
    let activeDetail: String?
    let isActivelyThinking: Bool
    let thinkingDurationMs: Int

    @State private var isExpanded = true

    var body: some View {
        let p = theme.palette
        let headerTitle = isActivelyThinking ? "Thinking…" : "Thought"

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .imageScale(.small)
                        .foregroundStyle(isActivelyThinking ? p.accent : p.tertiaryText)
                    Text(headerTitle)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(isActivelyThinking ? p.text : p.secondaryText)
                    if thinkingDurationMs >= 1000 {
                        Text(ChatTurnActivity.formatSpan(ms: thinkingDurationMs))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                    }
                    if !isExpanded, let activeDetail, !activeDetail.isEmpty {
                        Text("· \(activeDetail)")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                                if idx > 0 {
                                    Divider()
                                }
                                Text(block.text)
                                    .font(.system(size: theme.pointSize(.small)))
                                    .foregroundStyle(p.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if isActivelyThinking {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(p.accent)
                                        .frame(width: 5, height: 5)
                                    Text(activeDetail?.isEmpty == false ? activeDetail! : "Reasoning…")
                                        .font(.system(size: theme.pointSize(.small)))
                                        .italic()
                                        .foregroundStyle(p.tertiaryText)
                                        .lineLimit(2)
                                }
                                .id("live-thinking-tail")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 220)
                    .onChange(of: blocks.count) { _, _ in
                        if let last = blocks.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActivelyThinking ? p.accent.opacity(0.35) : p.border)
        )
    }
}

private struct ChatFinishedTurnCardView: View {
    @Environment(\.vesperTheme) private var theme

    let turn: ChatFinishedTurn
    let outcome: ChatTurnOutcome

    @State private var isExpanded: Bool
    @State private var showAllEarlier = false

    init(turn: ChatFinishedTurn, outcome: ChatTurnOutcome) {
        self.turn = turn
        self.outcome = outcome
        self._isExpanded = State(initialValue: outcome == .failed)
    }

    var body: some View {
        let p = theme.palette
        let failureFold = outcome == .failed && !showAllEarlier
            ? ChatTurnActivity.foldStepsFromFailure(turn.steps)
            : (earlier: 0, shown: turn.steps)
        let summary = ChatTurnActivity.finishedSummary(
            outcome: outcome,
            stepCount: turn.steps.count,
            durationMs: turn.durationMs,
            thinkingDurationMs: turn.thinkingDurationMs
        )

        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: outcomeIcon)
                            .imageScale(.small)
                            .foregroundStyle(outcomeColor(palette: p))
                        Text(summary)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Hide steps" : "Show steps")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        if failureFold.earlier > 0 {
                            Button("Show \(failureFold.earlier) earlier step\(failureFold.earlier == 1 ? "" : "s")") {
                                showAllEarlier = true
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.accent)
                        }
                        ForEach(failureFold.shown, id: \.key) { step in
                            ChatTurnStepRowView(step: step)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(outcome == .failed ? theme.swiftUIColor("pill-blocked-fg", fallback: .red).opacity(0.4) : p.border)
            )

            if outcome == .stopped {
                Text("Stopped before it replied.")
                    .font(.system(size: theme.pointSize(.micro)))
                    .italic()
                    .foregroundStyle(p.tertiaryText)
            }
        }
    }

    private var outcomeIcon: String {
        switch outcome {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "pause.circle.fill"
        }
    }

    private func outcomeColor(palette p: NativePalette) -> Color {
        switch outcome {
        case .done: .green
        case .failed: .red
        case .stopped: p.tertiaryText
        }
    }
}

private struct ChatTurnStepRowView: View {
    @Environment(\.vesperTheme) private var theme

    let step: ChatTurnStep

    var body: some View {
        let p = theme.palette
        HStack(spacing: 6) {
            Image(systemName: stepIcon(step.state))
                .imageScale(.small)
                .foregroundStyle(stepColor(step.state, palette: p))
            Text(step.title)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(step.state == .planned ? p.tertiaryText : p.secondaryText)
            if let detail = step.detail, !detail.isEmpty {
                Text("· \(detail)")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
            }
            if step.state != .active, let started = step.startedAt, let ended = step.endedAt {
                let ms = Int((ended - started) * 1000)
                if ms >= 1000 {
                    Spacer(minLength: 6)
                    Text(ChatTurnActivity.formatSpan(ms: ms))
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
            }
        }
    }

    private func stepIcon(_ state: ChatStepState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .active: "circle.dotted"
        case .failed: "xmark.circle.fill"
        case .planned: "circle"
        }
    }

    private func stepColor(_ state: ChatStepState, palette p: NativePalette) -> Color {
        switch state {
        case .done: .green
        case .active: p.accent
        case .failed: .red
        case .planned: p.tertiaryText
        }
    }
}

// MARK: - Isolated Live Work / Thinking Card

/// Owns the live run-event observation and 1.5s timer so polling ticks only re-render this card
/// instead of every message row in the transcript above it.
private struct ChatLiveActivityCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let chatId: String
    let runId: String?
    let since: String?
    let waitingForMessages: Bool
    let speaker: API.PersonaSummary?
    let fallbackSpeakerName: String

    @State private var watchedKey: QueryKey?
    @State private var now = Date()
    @State private var showAllSteps = false

    private var runEventsRequest: APIRequest<API.RunEventList>? {
        guard let runId, !runId.isEmpty else { return nil }
        return ChatTurnActivity.liveEventsRequest(runId: runId, since: since)
    }

    var body: some View {
        let p = theme.palette
        let events = waitingForMessages ? [] : (runEventsRequest.flatMap { context.store.entry($0).data?.events } ?? [])
        let activity = ChatTurnActivity.fold(events: events.map(ChatRunEvent.init), since: since, now: now)
        let speakerName = speaker?.name ?? fallbackSpeakerName
        let folded = ChatTurnActivity.foldSteps(activity.steps)
        let displaySteps = showAllSteps ? activity.steps : folded.shown
        // Observed by `ChatTranscriptProposalsSlot`; the API lists only pending approvals.
        let awaiting = !(context.store.entry(API.listChatToolApprovals(id: chatId)).data?.approvals.isEmpty ?? true)
        let characterState = CharacterState.forActivity(activity.status.kind, awaiting: awaiting)
        let liveTimerMs = activity.phaseElapsedMs ?? activity.elapsedMs
        let secondaryTimingLine: String? = {
            var parts: [String] = []
            if let total = activity.elapsedMs, let phase = activity.phaseElapsedMs, total - phase >= 1000 {
                parts.append("Total \(ChatTurnActivity.formatSpan(ms: total))")
            }
            if activity.thinkingDurationMs >= 1000 {
                let isSameAsLiveTimer = activity.timingPhase == .thinking
                    && activity.phaseElapsedMs.map { abs(activity.thinkingDurationMs - $0) < 1000 } == true
                if !isSameAsLiveTimer {
                    parts.append("Thought for \(ChatTurnActivity.formatSpan(ms: activity.thinkingDurationMs))")
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        let activeThinkingDetail: String? = {
            if case .thinking(let detail) = activity.activePhase { return detail }
            return nil
        }()
        let shouldShowLiveThinking = showLiveThinking && (!activity.thinkingBlocks.isEmpty || activity.timingPhase == .thinking)

        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    WorkPersonaAvatarView(
                        id: speaker?.id,
                        handle: nil,
                        name: speakerName,
                        size: 32,
                        state: characterState,
                        active: true,
                        preferCharacter: true
                    )
                    ActivitySceneView(kind: activity.status.kind, width: 112, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(speakerName) is \(activity.status.phrase)…")
                                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                                .foregroundStyle(p.text)
                            if let liveTimerMs {
                                Text(ChatTurnActivity.formatSpan(ms: liveTimerMs))
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                    .foregroundStyle(p.tertiaryText)
                            }
                        }
                        if let secondaryTimingLine {
                            Text(secondaryTimingLine)
                                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                                .lineLimit(1)
                        }
                        if let opening = activity.openingLine, !opening.isEmpty {
                            Text(opening)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(2)
                        }
                        if activity.quiet {
                            Text("Still working — no new events for a bit.")
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
                        }
                    }
                    Spacer(minLength: 8)
                }

                if !displaySteps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if !showAllSteps && folded.earlier > 0 {
                            Button("Show \(folded.earlier) earlier step\(folded.earlier == 1 ? "" : "s")") {
                                showAllSteps = true
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.accent)
                        }
                        ForEach(displaySteps, id: \.key) { step in
                            ChatTurnStepRowView(step: step)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(12)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))

            if shouldShowLiveThinking {
                ChatLiveThinkingStreamView(
                    blocks: activity.thinkingBlocks,
                    activeDetail: activeThinkingDetail,
                    isActivelyThinking: activity.timingPhase == .thinking,
                    thinkingDurationMs: activity.thinkingDurationMs
                )
            }
        }
        // The chat's persona companion acts out what this card shows, and idles once it's gone.
        .onChange(of: characterState, initial: true) { _, next in
            ChatCompanions.companion(for: chatId).work = next
        }
        .onDisappear { ChatCompanions.companion(for: chatId).work = nil }
        .onChange(of: since) { _, _ in
            showAllSteps = false
            now = Date()
        }
        .task(id: "\(runId ?? "")|\(since ?? "")") {
            watchRunEvents()
            await pollRunEvents()
        }
        .onDisappear {
            if let watchedKey {
                context.store.stopObserving(watchedKey)
                self.watchedKey = nil
            }
        }
    }

    private func watchRunEvents() {
        if let watchedKey {
            context.store.stopObserving(watchedKey)
            self.watchedKey = nil
        }
        guard let req = runEventsRequest else { return }
        context.store.observe(req)
        context.store.load(req)
        watchedKey = req.key
    }

    private func pollRunEvents() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            now = Date()
            if let req = runEventsRequest {
                _ = await context.store.refetch(req)
            }
        }
    }
}

// MARK: - Isolated Proposals Slot

/// Observes chat-level approval and proposal queries separately from `ChatTranscriptView`
/// so updates to proposals do not re-evaluate historical message rows.
private struct ChatTranscriptProposalsSlot: View {
    @Environment(NativeScreenContext.self) private var context

    let chatId: String
    let canvases: [API.ChatCanvasSummary]

    @State private var watched: [QueryKey] = []

    private var approvalsRequest: APIRequest<API.ChatToolApprovalList> {
        API.listChatToolApprovals(id: chatId)
    }
    private var secretProposalsRequest: APIRequest<API.ApiSecretProposalList> {
        API.listApiSecretProposals(id: chatId)
    }
    private var personaProposalsRequest: APIRequest<API.ListPersonaProposalsResponse> {
        API.listPersonaProposals(id: chatId)
    }
    private var characterProposalsRequest: APIRequest<API.ListPersonaCharacterProposalsResponse> {
        API.listPersonaCharacterProposals(id: chatId)
    }

    var body: some View {
        let store = context.store
        // The section renders nothing until a query answers, and a view with no content never
        // appears, so `.task` would never start the queries that fill it. The stack always appears.
        VStack(alignment: .leading, spacing: 0) {
            ChatProposalsSectionView(
                chatId: chatId,
                approvals: store.entry(approvalsRequest).data?.approvals ?? [],
                    secretProposals: store.entry(secretProposalsRequest).data?.proposals ?? [],
                personaProposals: store.entry(personaProposalsRequest).data?.proposals ?? [],
                characterProposals: store.entry(characterProposalsRequest).data?.proposals ?? [],
                canvases: canvases
            )
        }
        .task(id: chatId) { watch() }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
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

        track(approvalsRequest)
        track(secretProposalsRequest)
        track(personaProposalsRequest)
        track(characterProposalsRequest)
        watched = keys
    }
}
