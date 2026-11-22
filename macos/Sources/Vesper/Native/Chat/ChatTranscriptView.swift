import SwiftUI
import VesperCore

/// Lazy-scrolling native chat transcript (`ScrollView` + `LazyVStack`, zero per-message web views).
/// Renders parsed `ChatMessageSegment`s, persona avatars, cards, media, proposals, and the live Work/Thinking card.
struct ChatTranscriptView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let session: API.ChatSession?
    let knownPersonaNames: [String]
    let onSendReply: @MainActor (String) -> Void

    @State private var watched: [QueryKey] = []
    @State private var parseCache = ChatParsedMessageCache()

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: chatId, limit: 200)
    }
    private var ticketRunsRequest: APIRequest<API.ChatTicketRuns> {
        API.listChatTicketRuns(id: chatId)
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

    private var isRunning: Bool {
        session?.state == .running
    }

    var body: some View {
        let store = context.store
        let messagesEntry = store.entry(messagesRequest)
        let messages = messagesEntry.data?.messages ?? []
        let ticketRuns = store.entry(ticketRunsRequest).data?.runs ?? []
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

        return Group {
            if let error = messagesEntry.error, messages.isEmpty {
                QueryErrorView(message: error.userMessage) {
                    Task { await store.refetch(messagesRequest) }
                }
            } else if messagesEntry.isFetching && messages.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SkeletonBar(height: 22)
                    SkeletonBar(height: 64)
                    SkeletonBar(height: 44)
                }
                .padding(24)
                .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if !pushes.leading.isEmpty {
                                ChatPushRequestStackView(requests: pushes.leading)
                            }

                            ForEach(Array(messages.enumerated()), id: \.element.id) { idx, message in
                                let nextBody = idx + 1 < messages.count ? messages[idx + 1].bodyMd : nil
                                let isUser = message.role == .user
                                let parsed = parseCache.parsed(
                                    messageId: message.id,
                                    bodyMd: message.bodyMd,
                                    extractSources: !isUser,
                                    knownPersonaNames: knownPersonaNames
                                )
                                let persona = message.persona ?? session?.persona
                                let speakerName = persona?.name ?? session?.agent.name ?? "Assistant"
                                ChatMessageRowView(
                                    chatId: chatId,
                                    message: message,
                                    parsed: parsed,
                                    nextMessageBody: nextBody,
                                    personaId: persona?.id,
                                    speakerName: speakerName,
                                    isRunning: isRunning,
                                    ticketRuns: parsed.hasDispatchSegment ? ticketRuns : [],
                                    workflowRuns: parsed.hasWorkflowRunSegment ? workflowRuns : [],
                                    canvases: parsed.hasCanvasSegment ? canvases : [],
                                    audios: audiosByMessage[message.id] ?? [],
                                    videos: videosByMessage[message.id] ?? [],
                                    onSendReply: onSendReply
                                )
                                .id(message.id)

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
                                    speaker: session?.speaker ?? session?.persona,
                                    fallbackSpeakerName: session?.agent.name ?? "Assistant"
                                )
                                .id("live-activity")
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
                    .onChange(of: messages.last?.id) { oldId, lastId in
                        // Initial load stays anchored via defaultScrollAnchor(.bottom); calling
                        // scrollTo on nil -> id forces LazyVStack to materialize every row upfront.
                        guard oldId != nil, lastId != nil else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: isRunning) { _, running in
                        if running {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("transcript-bottom", anchor: .bottom)
                            }
                        }
                    }
                    .task(id: context.match.query["message"]) {
                        if let targetMsg = context.match.query["message"], !targetMsg.isEmpty {
                            proxy.scrollTo(targetMsg, anchor: .center)
                        }
                    }
                }
                .id(chatId)
            }
        }
        .onChange(of: chatId) { _, _ in
            parseCache.removeAll()
        }
        .task(id: chatId) { watch() }
        .task(id: pollId) { await pollWhileActive() }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
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
        "\(chatId)|\(isRunning)"
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
        track(ticketRunsRequest)
        track(workflowRunsRequest)
        track(canvasesRequest)
        track(audioRequest)
        track(videosRequest)
        track(pushRequestsRequest)
        watched = keys
    }

    private func pollWhileActive() async {
        guard isRunning else { return }
        while !Task.isCancelled && isRunning {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            _ = await context.store.refetch(API.getChat(id: chatId))
            _ = await context.store.refetch(messagesRequest)
        }
    }
}

// MARK: - Isolated Message Row

private struct ChatMessageRowView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let message: API.ChatMessage
    let parsed: ParsedChatMessage
    let nextMessageBody: String?
    let personaId: String?
    let speakerName: String
    let isRunning: Bool
    let ticketRuns: [API.ChatTicketRun]
    let workflowRuns: [API.WorkflowRun]
    let canvases: [API.ChatCanvasSummary]
    let audios: [API.ChatAudio]
    let videos: [API.ChatVideo]
    let onSendReply: @MainActor (String) -> Void

    var body: some View {
        let p = theme.palette
        let isUser = message.role == .user
        let citationNumbers = parsed.sources.compactMap(\.number)

        if isUser {
            VStack(alignment: .trailing, spacing: 6) {
                ChatContextChipsView(stripped: parsed.context, refs: message.contextRefs ?? [])
                VStack(alignment: .leading, spacing: 8) {
                    if !parsed.typedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownView(markdown: parsed.typedBody, textStyle: .chat, chat: true)
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
                    Spacer(minLength: 8)
                    Button {
                        context.copyToClipboard(message.bodyMd)
                        context.showToast(ToastItemModel(id: "chat.copy.\(message.id)", title: "Copied message", tone: .success))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Copy markdown")
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(parsed.segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment, citationNumbers: citationNumbers)
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

                    ChatSourcesChipsView(sources: parsed.sources, citations: message.citations ?? [])
                }
                .padding(.leading, 32)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatMessageSegment, citationNumbers: [Int]) -> some View {
        switch segment {
        case .markdown(let text):
            MarkdownView(markdown: text, textStyle: .chat, chat: true, citations: citationNumbers)
        case .embedded(let kind, let source, let info, let index):
            EmbeddedBlockView(kind: kind, source: source, messageID: message.id, info: info, index: index)
        case .chart(let spec):
            ChatChartCardView(spec: spec)
        case .choices(let card):
            ChatChoicesCardView(
                card: card,
                chosenOption: card.chosenOption(nextMessageBody: nextMessageBody),
                disabled: isRunning,
                onSelect: onSendReply
            )
        case .dispatch(let card):
            ChatDispatchCardView(chatId: chatId, messageId: message.id, card: card, runs: ticketRuns)
        case .recommend(let cards):
            ChatRecommendCardsView(messageId: message.id, cards: cards, onSend: onSendReply)
        case .workflowRun(let card):
            ChatWorkflowRunCardView(chatId: chatId, messageId: message.id, card: card, runs: workflowRuns)
        case .canvas(let id):
            ChatCanvasRefCardView(chatId: chatId, canvasId: id, canvases: canvases)
        case .pdf(let id):
            ChatPDFCardView(itemId: id)
        case .researchPlan(let plan):
            ChatResearchPlanCardView(chatId: chatId, messageId: message.id, plan: plan)
        }
    }
}

// MARK: - Isolated Live Work / Thinking Card

/// Owns the live run-event observation and 1.5s timer so polling ticks only re-render this card
/// instead of every message row in the transcript above it.
private struct ChatLiveActivityCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let runId: String?
    let speaker: API.PersonaSummary?
    let fallbackSpeakerName: String

    @State private var watchedKey: QueryKey?
    @State private var now = Date()
    @State private var showAllSteps = false

    private var runEventsRequest: APIRequest<API.RunEventList>? {
        guard let runId, !runId.isEmpty else { return nil }
        return API.listRunEvents(id: runId)
    }

    var body: some View {
        let p = theme.palette
        let events = runEventsRequest.flatMap { context.store.entry($0).data?.events } ?? []
        let activity = ChatTurnActivity.fold(events: events.map(ChatRunEvent.init), now: now)
        let speakerName = speaker?.name ?? fallbackSpeakerName
        let folded = ChatTurnActivity.foldSteps(activity.steps)
        let displaySteps = showAllSteps ? activity.steps : folded.shown
        // Observed by `ChatTranscriptProposalsSlot`; the API lists only pending approvals.
        let awaiting = !(context.store.entry(API.listChatToolApprovals(id: chatId)).data?.approvals.isEmpty ?? true)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                WorkPersonaAvatarView(
                    id: speaker?.id,
                    handle: nil,
                    name: speakerName,
                    size: 32,
                    state: .forActivity(activity.status.kind, awaiting: awaiting),
                    active: true,
                    preferCharacter: true
                )
                ActivitySceneView(kind: activity.status.kind, width: 112, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(speakerName) is \(activity.status.phrase)…")
                            .font(.system(size: theme.pointSize(.body), weight: .semibold))
                            .foregroundStyle(p.text)
                        if let elapsed = activity.elapsedMs {
                            Text(ChatTurnActivity.formatSpan(ms: elapsed))
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
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
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        .task(id: runId ?? "") {
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
    private var ticketChangesRequest: APIRequest<API.TicketChangeRequestList> {
        API.listTicketChangeRequests(id: chatId)
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
                ticketChanges: store.entry(ticketChangesRequest).data?.requests ?? [],
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
        track(ticketChangesRequest)
        watched = keys
    }
}
