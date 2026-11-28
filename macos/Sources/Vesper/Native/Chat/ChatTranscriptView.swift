import SwiftUI
import VesperCore

struct ChatScrollMessageRequest: Equatable {
    let token: Int
    let messageId: String
}

/// Tail-windowed native chat transcript (`ScrollView` + `LazyVStack`, zero per-message web views).
/// Renders parsed `ChatMessageSegment`s, persona avatars, cards, media, proposals, and the live Work/Thinking card.
struct ChatTranscriptView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let chatId: String
    let session: API.ChatSession?
    let knownPersonaNames: [String]
    var personas: [API.Persona] = []
    var harnessModels: [API.ChatHarnessModels] = []
    var scrollToMessageRequest: ChatScrollMessageRequest?
    var editLastUserMessageToken: Int = 0
    var isStopping: Bool = false
    var hasPinnedPlanBar: Bool = false
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
    var onSaveAsTemplate: (@MainActor (String) -> Void)? = nil

    @Namespace private var activityMorphNamespace
    @State private var watched: [QueryKey] = []
    @State private var parseCache = ChatParsedMessageCache()
    @State private var windowState = (chatId: "", limit: ChatTranscriptWindow.initialLimit)
    @State private var pendingPrependAnchor: String?
    @State private var isNearBottom = true
    @State private var unreadWhileScrolledUp = 0

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
                        LazyVStack(alignment: .leading, spacing: 18) {
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
                                let isLastMessage = idx == messages.count - 1
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
                                    morphNamespace: isLastMessage ? activityMorphNamespace : nil,
                                    onSendReply: onSendReply,
                                    onQuoteMessage: onQuoteMessage,
                                    onOpenThread: onOpenThread,
                                    onForkMessage: onForkMessage,
                                    onSaveWiki: onSaveWiki,
                                    onSecondOpinion: onSecondOpinion,
                                    onSelectReplyVariant: onSelectReplyVariant,
                                    onEditLastUserMessage: onEditLastUserMessage,
                                    editRequestToken: isLastUser ? editLastUserMessageToken : 0,
                                    onRegenerateMessage: onRegenerateMessage,
                                    isReadingAloud: readingMessageId == message.id,
                                    onToggleReadAloud: onToggleReadAloud,
                                    onSelectionAction: onSelectionAction,
                                    onSaveAsTemplate: onSaveAsTemplate,
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

                            VStack(alignment: .leading, spacing: 18) {
                                if isRunning {
                                    ChatLiveActivityCardView(
                                        chatId: chatId,
                                        runId: session?.currentRunId,
                                        since: liveSince,
                                        waitingForMessages: waitingForMessages,
                                        speaker: session?.speaker ?? session?.persona,
                                        personas: personas,
                                        fallbackSpeakerName: session?.agent.name ?? "Assistant",
                                        isStopping: isStopping,
                                        hasPinnedPlanBar: hasPinnedPlanBar,
                                        morphId: liveSince.map { "turn-card-\($0)" },
                                        morphNamespace: activityMorphNamespace
                                    )
                                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                                    .id("live-activity")
                                    ChatLiveAsidesView(parentChatId: chatId, asides: liveAsides)
                                }
                            }
                            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: isRunning)
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
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        let distance = ChatScrollLockLogic.distanceFromBottom(
                            contentHeight: geo.contentSize.height,
                            containerHeight: geo.containerSize.height,
                            contentOffsetY: geo.contentOffset.y,
                            contentInsetBottom: geo.contentInsets.bottom
                        )
                        return ChatScrollLockLogic.isNearBottom(distanceFromBottom: distance)
                    } action: { _, near in
                        if isNearBottom != near {
                            isNearBottom = near
                        }
                        if near && unreadWhileScrolledUp > 0 {
                            unreadWhileScrolledUp = 0
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !isNearBottom && !messages.isEmpty {
                            ChatJumpToBottomPill(
                                label: ChatScrollLockLogic.jumpPillLabel(
                                    unreadReplies: unreadWhileScrolledUp,
                                    isRunning: isRunning
                                ),
                                hasUnread: unreadWhileScrolledUp > 0,
                                isRunning: isRunning
                            ) {
                                unreadWhileScrolledUp = 0
                                isNearBottom = true
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                                }
                            }
                            .padding(.bottom, 12)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isNearBottom)
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
                        let lastRole = messages.last?.role
                        let isUser = lastRole == .user
                        if ChatScrollLockLogic.shouldAutoScrollOnNewMessage(
                            isNearBottom: isNearBottom,
                            isUserMessage: isUser
                        ) {
                            unreadWhileScrolledUp = 0
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("transcript-bottom", anchor: .bottom)
                            }
                        } else if lastRole == .assistant {
                            unreadWhileScrolledUp += 1
                        }
                    }
                    .onChange(of: isRunning) { wasRunning, running in
                        if running {
                            let lastIsUser = messages.last?.role == .user
                            if ChatScrollLockLogic.shouldAutoScrollOnRunningStart(
                                isNearBottom: isNearBottom,
                                lastMessageIsUser: lastIsUser
                            ) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                                }
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
            isNearBottom = true
            unreadWhileScrolledUp = 0
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
    var morphNamespace: Namespace.ID? = nil
    let onSendReply: @MainActor (String) -> Void
    let onQuoteMessage: (@MainActor (String, String?) -> Void)?
    let onOpenThread: (@MainActor (String) -> Void)?
    let onForkMessage: (@MainActor (API.ChatMessage) -> Void)?
    let onSaveWiki: (@MainActor (API.ChatMessage) -> Void)?
    let onSecondOpinion: (@MainActor (API.ChatMessage, API.Harness, String) -> Void)?
    let onSelectReplyVariant: (@MainActor (String, Int) -> Void)?
    let onEditLastUserMessage: (@MainActor (String) async -> String?)?
    var editRequestToken: Int = 0
    let onRegenerateMessage: (@MainActor (API.ChatMessage, String, String, API.Harness?, String?) async -> String?)?
    let isReadingAloud: Bool
    let onToggleReadAloud: (@MainActor (API.ChatMessage, String?, String, String) -> Void)?
    let onSelectionAction: (@MainActor (API.ChatMessage, String?, ChatSelectionAction, String) -> Void)?
    let onSaveAsTemplate: (@MainActor (String) -> Void)?
    let onScrollToSelf: @MainActor () -> Void

    @State private var togglingBookmark = false
    @State private var isReplyCollapsed = false
    @State private var isEditingUserMessage = false
    @State private var editDraft = ""
    @State private var editSubmitting = false
    @State private var editError: String?
    @State private var regenerating = false
    @State private var hoverState = ChatRowHoverState()
    @FocusState private var editFieldFocused: Bool

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
                        ChatHoverRevealSlot(hoverState: hoverState, alwaysVisible: isEditingUserMessage) {
                            HStack(spacing: 2) {
                                Button {
                                    toggleBookmark()
                                } label: {
                                    Image(systemName: message.bookmarked == true ? "bookmark.fill" : "bookmark")
                                        .imageScale(.small)
                                        .modifier(ChatActionIconPill(active: message.bookmarked == true))
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
                                            .modifier(ChatActionIconPill())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Quote in composer")
                                }

                                if isLastUserMessage, onEditLastUserMessage != nil, !isEditingUserMessage {
                                    Button {
                                        beginInlineUserEdit()
                                    } label: {
                                        Image(systemName: "pencil")
                                            .imageScale(.small)
                                            .modifier(ChatActionIconPill())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Edit message and re-send (↑ in empty composer)")
                                }

                                if let onSaveAsTemplate, !parsed.typedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        onSaveAsTemplate(parsed.typedBody)
                                    } label: {
                                        Image(systemName: "text.badge.star")
                                            .imageScale(.small)
                                            .modifier(ChatActionIconPill())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Save as reusable prompt template")
                                }

                                if let onForkMessage {
                                    Button {
                                        onForkMessage(message)
                                    } label: {
                                        Image(systemName: "arrow.triangle.branch")
                                            .imageScale(.small)
                                            .modifier(ChatActionIconPill())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Fork conversation from here")
                                }
                            }
                        }
                    }
                    ChatContextChipsView(stripped: parsed.context, refs: message.contextRefs ?? [])
                    VStack(alignment: .leading, spacing: 8) {
                        if isEditingUserMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                TextEditor(text: $editDraft)
                                    .font(.system(size: theme.pointSize(.body)))
                                    .scrollContentBackground(.hidden)
                                    .focused($editFieldFocused)
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
                            MarkdownView(markdown: parsed.typedBody, textStyle: .chat, chat: true, hugWidth: true, findRow: findRow)
                        }
                        if let attachments = message.attachments, !attachments.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(attachments, id: \.id) { att in
                                    ChatAttachmentCardView(attachment: att)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(theme.swiftUIColor("surface-raised", fallback: p.surface))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(p.accent.opacity(theme.mode == .dark ? 0.10 : 0.07))
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(p.accent.opacity(theme.mode == .dark ? 0.22 : 0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: 640, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { hoverState.isHovered = $0 }

                if let endedTurn, let runId = message.runId, !runId.isEmpty {
                    ChatEndedTurnSectionView(
                        runId: runId,
                        ended: endedTurn,
                        personaId: personaId,
                        speakerName: speakerName
                    )
                }
            }
            .onChange(of: editRequestToken) { _, token in
                guard token > 0, isLastUserMessage, onEditLastUserMessage != nil, !isEditingUserMessage else { return }
                beginInlineUserEdit()
                onScrollToSelf()
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
                    ChatHoverRevealSlot(
                        hoverState: hoverState,
                        alwaysVisible: isLastAssistantMessage || isReadingAloud
                    ) {
                        assistantActionBar
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let turnWindow, let runId = message.runId, !runId.isEmpty {
                        ChatTurnStepsCardView(
                            runId: runId,
                            outcome: .done,
                            since: turnWindow.since,
                            until: message.createdAt,
                            end: APIDate.epoch(message.createdAt),
                            personaId: personaId,
                            morphId: turnWindow.since.map { "turn-card-\($0)" },
                            morphNamespace: morphNamespace
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
            .contentShape(Rectangle())
            .onHover { hoverState.isHovered = $0 }
        }
    }

    @ViewBuilder
    private var assistantActionBar: some View {
        let otherPersonas = personas.filter { $0.id != personaId }
        let availableModels = harnessModels.filter { $0.available && !$0.models.isEmpty }

        HStack(spacing: 2) {
            if isFoldableReply {
                Button {
                    isReplyCollapsed.toggle()
                } label: {
                    Image(systemName: isReplyCollapsed ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        .imageScale(.small)
                        .modifier(ChatActionIconPill())
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
                        .modifier(ChatActionIconPill())
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
                        .modifier(ChatActionIconPill())
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
                        .modifier(ChatActionIconPill(active: isReadingAloud))
                }
                .buttonStyle(.plain)
                .help(isReadingAloud ? "Stop reading aloud" : "Read message aloud")
            }

            Button {
                toggleBookmark()
            } label: {
                Image(systemName: message.bookmarked == true ? "bookmark.fill" : "bookmark")
                    .imageScale(.small)
                    .modifier(ChatActionIconPill(active: message.bookmarked == true))
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
                        .modifier(ChatActionIconPill())
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
                        .modifier(ChatActionIconPill())
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
                    .modifier(ChatActionIconPill())
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
                    .modifier(ChatActionIconPill())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    private func beginInlineUserEdit() {
        editDraft = parsed.typedBody
        editError = nil
        isEditingUserMessage = true
        DispatchQueue.main.async {
            editFieldFocused = true
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
        case .map(let spec):
            ChatMapCardView(spec: spec)
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

// MARK: - Floating Jump-to-Bottom Pill

/// Opaque elevated pill floating above the composer when the person scrolls up in a conversation.
/// Keeps scrolling silky at 120 Hz (no live backdrop blur) while flagging arriving replies.
private struct ChatJumpToBottomPill: View {
    @Environment(\.vesperTheme) private var theme

    let label: String
    let hasUnread: Bool
    let isRunning: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 6) {
                if hasUnread || isRunning {
                    Circle()
                        .fill(p.accent)
                        .frame(width: 6, height: 6)
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hasUnread ? p.accent : p.secondaryText)
                Text(label)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.text)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(
                        isHovered
                            ? theme.swiftUIColor("surface-raised", fallback: p.hover)
                            : theme.swiftUIColor("surface-raised", fallback: p.surface)
                    )
                    .shadow(
                        color: Color.black.opacity(theme.mode == .dark ? 0.34 : 0.14),
                        radius: isHovered ? 10 : 8,
                        y: 3
                    )
            }
            .overlay(
                Capsule()
                    .stroke(
                        hasUnread
                            ? p.accent.opacity(isHovered ? 0.8 : 0.55)
                            : (isHovered ? p.accent.opacity(0.45) : p.border),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel("Jump to bottom: \(label)")
    }
}

/// Leaf hover-pill modifier for transcript message action buttons so pointer targeting feels
/// tactile without re-evaluating `ChatMessageRowView.body`.
private struct ChatActionIconPill: ViewModifier {
    @Environment(\.vesperTheme) private var theme
    var active: Bool = false
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let p = theme.palette
        content
            .foregroundStyle(active ? p.accent : (isHovered ? p.text : p.tertiaryText))
            .frame(width: 24, height: 22)
            .background(
                isHovered ? p.hover : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

// MARK: - Isolated Row Hover Reveal

/// Per-row observable hover flag kept out of `ChatMessageRowView.body` so pointer sweeps while
/// scrolling never re-evaluate the message row, `MarkdownView`, or action bar menus.
@MainActor
@Observable
final class ChatRowHoverState {
    var isHovered = false
}

/// Leaf wrapper that observes `ChatRowHoverState.isHovered` only when `alwaysVisible` is false,
/// isolating hover opacity transitions from the surrounding transcript row and markdown subtree.
struct ChatHoverRevealSlot<Content: View>: View {
    let hoverState: ChatRowHoverState
    let alwaysVisible: Bool
    let content: Content

    init(
        hoverState: ChatRowHoverState,
        alwaysVisible: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.hoverState = hoverState
        self.alwaysVisible = alwaysVisible
        self.content = content()
    }

    var body: some View {
        let visible = alwaysVisible || hoverState.isHovered
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .animation(.easeOut(duration: 0.14), value: visible)
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
