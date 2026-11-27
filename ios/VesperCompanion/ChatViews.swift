import PhotosUI
import SwiftUI
import UIKit
import VesperCore

// MARK: - Chat List

struct ChatListView: View {
    let connection: CompanionConnectionManager

    @State private var chats: [API.ChatSession] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showNewChat = false
    @State private var createdChatId: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if chats.isEmpty && !loading {
                    ContentUnavailableView(
                        "No Chats Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Tap + to start a conversation with one of your personas.")
                    )
                } else {
                    ForEach(chats, id: \.id) { chat in
                        NavigationLink(value: chat.id) {
                            ChatRow(chat: chat)
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { chatId in
                ChatDetailView(
                    connection: connection,
                    chatId: chatId,
                    initialTitle: chats.first(where: { $0.id == chatId })?.title ?? "Chat"
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(connection.apiClient == nil)
                }
            }
            .refreshable { await load() }
            .task(id: connection.state) { await load() }
            .onChange(of: connection.eventVersion) { _, _ in
                Task { await load(silent: true) }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet(connection: connection) { chat in
                    showNewChat = false
                    createdChatId = chat.id
                    Task { await load(silent: true) }
                }
            }
            .navigationDestination(item: $createdChatId) { chatId in
                ChatDetailView(
                    connection: connection,
                    chatId: chatId,
                    initialTitle: chats.first(where: { $0.id == chatId })?.title ?? "Chat"
                )
            }
        }
    }

    private func load(silent: Bool = false) async {
        guard let client = connection.apiClient else { return }
        if !silent { loading = true }
        defer { loading = false }
        do {
            let resp = try await client.get("/api/v1/chats?archived=false", as: API.ListChatsResponse.self)
            chats = resp.chats
            errorMessage = nil
        } catch {
            if !silent {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

struct ChatRow: View {
    let chat: API.ChatSession

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                        .font(.body.weight(chat.unread > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if chat.state == .running {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                HStack(spacing: 6) {
                    Text(chat.persona?.name ?? chat.agent.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let project = chat.project, !project.isEmpty {
                        Text("· \(project)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if chat.unread > 0 {
                Text("\(chat.unread)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Chat Detail (Full Desktop Parity: Live Steps, Visualizations, Cards, Photo Uploads)

struct ChatDetailView: View {
    let connection: CompanionConnectionManager
    let chatId: String
    let initialTitle: String

    @State private var title: String
    @State private var session: API.ChatSession?
    @State private var messages: [API.ChatMessage] = []
    @State private var runEventsByRunId: [String: [API.RunEvent]] = [:]
    @State private var liveRunEvents: [API.RunEvent] = []
    @State private var pushRequests: [API.PushRequest] = []
    @State private var toolApprovals: [API.Approval] = []
    @State private var parseCache = ChatParsedMessageCache()

    @State private var draft = ""
    @State private var pendingPhotos: [ImageUploadHelper.PreparedPhoto] = []
    @State private var showCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var sending = false
    @State private var errorMessage: String?

    init(connection: CompanionConnectionManager, chatId: String, initialTitle: String) {
        self.connection = connection
        self.chatId = chatId
        self.initialTitle = initialTitle
        _title = State(initialValue: initialTitle)
    }

    private var isRunning: Bool { session?.state == .running }

    var body: some View {
        let turnWindows = ChatTurnActivity.turnWindows(for: messages)
        let endedTurns = ChatTurnActivity.endedTurns(for: messages, running: isRunning)
        let liveSince = ChatTurnActivity.runningSince(for: messages)
        let placedPushes = ChatPushPlacement.place(
            pushRequests,
            messages: messages,
            running: isRunning,
            currentRunId: session?.currentRunId,
            hasMore: false
        )

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(placedPushes.leading, id: \.id) { req in
                            ChatPushRequestCardView(request: req, client: connection.apiClient) {
                                Task { await refresh() }
                            }
                        }

                        ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                            messageItemView(
                                msg: msg,
                                nextBody: idx + 1 < messages.count ? messages[idx + 1].bodyMd : nil,
                                turnWindows: turnWindows,
                                endedTurns: endedTurns,
                                placedPushes: placedPushes
                            )
                            .id(msg.id)
                        }

                        ForEach(placedPushes.trailing, id: \.id) { req in
                            ChatPushRequestCardView(request: req, client: connection.apiClient) {
                                Task { await refresh() }
                            }
                        }

                        // Pending tool approvals
                        ForEach(toolApprovals, id: \.id) { approval in
                            ChatToolApprovalCardView(approval: approval, client: connection.apiClient) {
                                Task { await refresh() }
                            }
                        }

                        // Live working / steps card while persona is working
                        if isRunning {
                            let liveEvents = liveRunEvents.isEmpty
                                ? ((session?.currentRunId).flatMap { runEventsByRunId[$0] } ?? [])
                                : liveRunEvents
                            ChatLiveActivityCardView(
                                speakerName: session?.persona?.name ?? session?.agent.name ?? "Persona",
                                events: liveEvents,
                                since: liveSince,
                                awaitingApproval: !toolApprovals.isEmpty,
                                onStop: { Task { await stopTurn() } }
                            )
                            .id("live-activity-card")

                            ForEach(placedPushes.live, id: \.id) { req in
                                ChatPushRequestCardView(request: req, client: connection.apiClient) {
                                    Task { await refresh() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: isRunning) { _, running in
                    if running { scrollToBottom(proxy) }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            composerBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: chatId) {
            await refresh()
        }
        .onChange(of: connection.eventVersion) { _, _ in
            Task { await refresh(silent: true) }
        }
        // Fallback poll while running so live steps & final reply always arrive even if SSE reconnects on cellular
        .task(id: isRunning) {
            guard isRunning else { return }
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await refresh(silent: true)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureSheet { image in
                if let prepared = ImageUploadHelper.prepare(image) {
                    pendingPhotos.append(prepared)
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickedPhoto(newItem) }
        }
    }

    // MARK: - Message Item Builder

    @ViewBuilder
    private func messageItemView(
        msg: API.ChatMessage,
        nextBody: String?,
        turnWindows: [String: ChatTurnWindow],
        endedTurns: [String: ChatEndedTurn],
        placedPushes: ChatPlacedPushRequests<API.PushRequest>
    ) -> some View {
        let isUser = msg.role.rawValue == "user"
        let parsed = parseCache.parsed(
            messageId: msg.id,
            bodyMd: msg.bodyMd,
            extractSources: !isUser,
            knownPersonaNames: []
        )

        VStack(alignment: .leading, spacing: 8) {
            if !isUser, let runId = msg.runId, let events = runEventsByRunId[runId] {
                let win = turnWindows[msg.id]
                ChatTurnStepsCardView(
                    events: events,
                    outcome: .done,
                    since: win?.since,
                    until: win?.until,
                    end: nil
                )
            }

            MessageRowView(
                chatId: chatId,
                message: msg,
                parsed: parsed,
                nextMessageBody: nextBody,
                isRunning: isRunning,
                client: connection.apiClient,
                onSendReply: { reply in
                    Task { await sendMessage(overrideText: reply) }
                }
            )

            if let ended = endedTurns[msg.id],
               let runId = msg.runId ?? session?.currentRunId,
               let events = runEventsByRunId[runId] {
                ChatTurnStepsCardView(
                    events: events,
                    outcome: ended.outcome,
                    since: ended.since,
                    until: ended.until,
                    end: ended.end
                )
            }

            if let changes = msg.codeChanges, !changes.isEmpty {
                ChatCodeChangesCardView(changes: changes, branch: msg.gitBranch)
            }

            ForEach(placedPushes.byMessage[msg.id] ?? [], id: \.id) { req in
                ChatPushRequestCardView(request: req, client: connection.apiClient) {
                    Task { await refresh() }
                }
            }
            ForEach(placedPushes.afterMessage[msg.id] ?? [], id: \.id) { req in
                ChatPushRequestCardView(request: req, client: connection.apiClient) {
                    Task { await refresh() }
                }
            }
        }
    }

    // MARK: - Composer

    private var composerBar: some View {
        VStack(spacing: 0) {
            Divider()

            if !pendingPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingPhotos) { photo in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: photo.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Button {
                                    pendingPhotos.removeAll { $0.id == photo.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    if CameraCaptureSheet.isCameraAvailable {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .disabled(sending || connection.apiClient == nil)

                TextField("Message…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    Task { await sendMessage() }
                } label: {
                    if sending {
                        ProgressView()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                    }
                }
                .disabled(sending || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingPhotos.isEmpty) || connection.apiClient == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if isRunning {
            withAnimation { proxy.scrollTo("live-activity-card", anchor: .bottom) }
        } else if let last = messages.last {
            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    // MARK: - Networking

    private func refresh(silent: Bool = false) async {
        guard let client = connection.apiClient else { return }
        do {
            async let chatReq: API.ChatSession = client.get("/api/v1/chats/\(chatId)", as: API.ChatSession.self)
            async let msgReq: API.ListChatMessagesResponse = client.get("/api/v1/chats/\(chatId)/messages?limit=100", as: API.ListChatMessagesResponse.self)
            async let pushReq: API.PushRequestList? = try? await client.send(API.listPushRequests(id: chatId))
            async let approvalReq: API.ChatToolApprovalList? = try? await client.send(API.listChatToolApprovals(id: chatId))

            let (chat, msgResp, pushes, approvals) = try await (chatReq, msgReq, pushReq, approvalReq)
            session = chat
            title = chat.title.isEmpty ? initialTitle : chat.title
            messages = msgResp.messages
            pushRequests = pushes?.requests ?? []
            toolApprovals = approvals?.approvals.filter { $0.state == .pending } ?? []
            errorMessage = nil

            await refreshRunEvents(client: client, chat: chat, messages: msgResp.messages)
        } catch {
            if !silent {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func refreshRunEvents(client: APIClient, chat: API.ChatSession, messages: [API.ChatMessage]) async {
        var idsToFetch: Set<String> = []
        let liveSince = ChatTurnActivity.runningSince(for: messages)
        if chat.state == .running, let activeRunId = chat.currentRunId, !activeRunId.isEmpty {
            if let list = try? await client.send(ChatTurnActivity.liveEventsRequest(runId: activeRunId, since: liveSince)) {
                liveRunEvents = list.events
            }
            if runEventsByRunId[activeRunId] == nil {
                idsToFetch.insert(activeRunId)
            }
        } else {
            liveRunEvents = []
            if let activeRunId = chat.currentRunId, !activeRunId.isEmpty {
                idsToFetch.insert(activeRunId)
            }
        }
        let turnWindows = ChatTurnActivity.turnWindows(for: messages)
        let endedTurns = ChatTurnActivity.endedTurns(for: messages, running: chat.state == .running)
        let historical = ChatTurnActivity.historicalRunIds(
            for: messages,
            turnWindows: turnWindows,
            endedTurns: endedTurns
        )
        for id in historical where runEventsByRunId[id] == nil {
            idsToFetch.insert(id)
        }
        for runId in idsToFetch {
            if let list = try? await client.send(API.listRunEvents(id: runId)) {
                runEventsByRunId[runId] = list.events
            }
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let prepared = ImageUploadHelper.prepare(image) else {
                errorMessage = "Could not load selected photo."
                return
            }
            pendingPhotos.append(prepared)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendMessage(overrideText: String? = nil) async {
        guard let client = connection.apiClient else { return }
        let rawText = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let photosToUpload = overrideText == nil ? pendingPhotos : []
        guard !rawText.isEmpty || !photosToUpload.isEmpty else { return }

        sending = true
        if overrideText == nil {
            draft = ""
            pendingPhotos = []
        }
        errorMessage = nil
        defer { sending = false }

        do {
            var attachmentIds: [String] = []
            for photo in photosToUpload {
                let id = try await client.uploadAttachment(
                    fileName: photo.fileName,
                    mime: photo.mime,
                    data: photo.data
                )
                attachmentIds.append(id)
            }
            let bodyText = rawText.isEmpty ? "Attached photo." : rawText
            let payload = API.NewChatMessage(
                attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
                body: bodyText
            )
            let body = try JSONEncoder().encode(payload)
            _ = try await client.request("POST", "/api/v1/chats/\(chatId)/messages", body: body)
            await refresh()
        } catch {
            if overrideText == nil {
                draft = rawText
                pendingPhotos = photosToUpload
            }
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func stopTurn() async {
        guard let client = connection.apiClient else { return }
        _ = try? await client.request("POST", "/api/v1/chats/\(chatId)/stop")
        await refresh(silent: true)
    }
}

// MARK: - Message Row (All 30 ChatMessageSegment Cases + Attachments + Sources)

private struct MessageRowView: View {
    let chatId: String
    let message: API.ChatMessage
    let parsed: ParsedChatMessage
    let nextMessageBody: String?
    let isRunning: Bool
    let client: APIClient?
    let onSendReply: (String) -> Void

    private var isUser: Bool { message.role.rawValue == "user" }
    private var isSystem: Bool { message.role.rawValue == "system" }

    var body: some View {
        if isUser {
            userBubble
        } else if isSystem {
            Text(parsed.typedBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else {
            assistantMessage
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    attachmentsView(attachments)
                }
                if !parsed.typedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ChatRichMarkdownView(markdown: parsed.typedBody, foreground: .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let persona = message.persona?.name, !persona.isEmpty {
                    Text(persona)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let cost = ChatTurnActivity.replyCost(message.costUsd) {
                    Text(cost)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            if let attachments = message.attachments, !attachments.isEmpty {
                attachmentsView(attachments)
            }

            ForEach(Array(parsed.segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }

            if !parsed.entityRefs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(parsed.entityRefs) { ref in
                            Label(ref.displayLabel, systemImage: entityIcon(ref))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if !parsed.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(parsed.sources.enumerated()), id: \.offset) { idx, src in
                        let label = src.number.map { "[\($0)] \(src.title)" } ?? "\(idx + 1). \(src.title)"
                        if let url = URL(string: src.url), src.url.hasPrefix("http") {
                            Link(label, destination: url)
                                .font(.caption)
                                .lineLimit(1)
                        } else {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func attachmentsView(_ attachments: [API.ChatAttachment]) -> some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            ForEach(attachments, id: \.id) { att in
                if ChatCardDisplay.isImageAttachment(contentType: att.contentType) {
                    AuthenticatedRemoteImage(
                        client: client,
                        path: "/api/v1/chat-attachments/\(att.id)/content",
                        maxHeight: 220
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(att.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Text(ChatCardDisplay.formattedFileSize(att.sizeBytes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatMessageSegment) -> some View {
        switch segment {
        case .markdown(let text):
            ChatRichMarkdownView(markdown: text)
        case .embedded(let kind, let source, let info, _):
            ChatEmbeddedBlockView(kind: kind, source: source, info: info)
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
            ChatCompareImagesCardView(spec: spec, client: client)
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
            ChatTabsCardView(spec: spec)
        case .details(let spec):
            ChatDetailsCardView(spec: spec)
        case .choices(let card):
            ChatChoicesCardView(
                card: card,
                chosenOption: card.chosenOption(nextMessageBody: nextMessageBody),
                disabled: isRunning,
                onSelect: onSendReply
            )
        case .recommend(let cards):
            ChatRecommendCardsView(cards: cards)
        case .gallery(let spec):
            ChatGalleryCardView(spec: spec)
        case .product(let spec):
            ChatProductCardView(spec: spec)
        case .workflowRun(let card):
            ChatSimpleActionCardView(
                icon: "flowchart.fill",
                tint: .purple,
                title: "Workflow",
                subtitle: card.input
            )
        case .canvas(let id):
            ChatSimpleActionCardView(
                icon: "rectangle.and.pencil.and.ellipsis",
                tint: .indigo,
                title: "Canvas",
                subtitle: "Open on Mac (\(id.prefix(8))…)"
            )
        case .pdf(let id):
            ChatSimpleActionCardView(
                icon: "doc.richtext.fill",
                tint: .red,
                title: "PDF Document",
                subtitle: "Saved in Library (\(id.prefix(8))…)"
            )
        case .researchPlan(let plan):
            ChatSimpleActionCardView(
                icon: "doc.text.magnifyingglass",
                tint: .teal,
                title: plan.title.isEmpty ? "Research Plan" : plan.title,
                subtitle: plan.questions.map(\.question).joined(separator: " · ")
            )
        case .callout(let callout):
            ChatCalloutCardView(callout: callout)
        case .checklist(let checklist):
            ChatChecklistCardView(
                chatId: chatId,
                messageId: message.id,
                checklist: checklist,
                persistedState: message.checklistState,
                client: client
            )
        case .invalidBlock(let kind, let error, let source):
            ChatInvalidBlockCardView(kind: kind, error: error, source: source)
        }
    }

    private func entityIcon(_ ref: ChatEntityRef) -> String {
        switch ref {
        case .page: "doc.text"
        }
    }
}

// MARK: - New Chat Sheet

struct NewChatSheet: View {
    let connection: CompanionConnectionManager
    var spaceId: String? = nil
    var defaultPersonaId: String? = nil
    let onCreated: (API.ChatSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var personas: [API.Persona] = []
    @State private var selectedPersonaId: String = ""
    @State private var messageText = ""
    @State private var creating = false
    @State private var errorMessage: String?

    init(
        connection: CompanionConnectionManager,
        spaceId: String? = nil,
        defaultPersonaId: String? = nil,
        onCreated: @escaping (API.ChatSession) -> Void
    ) {
        self.connection = connection
        self.spaceId = spaceId
        self.defaultPersonaId = defaultPersonaId
        self.onCreated = onCreated
        _selectedPersonaId = State(initialValue: defaultPersonaId ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if !personas.isEmpty {
                    Section("Persona") {
                        Picker("Persona", selection: $selectedPersonaId) {
                            Text("Default").tag("")
                            ForEach(personas, id: \.id) { p in
                                Text(p.name).tag(p.id)
                            }
                        }
                    }
                }
                Section("First Message") {
                    TextEditor(text: $messageText)
                        .frame(minHeight: 120)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Sending…" : "Send") {
                        Task { await create() }
                    }
                    .disabled(creating || messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { await loadPersonas() }
        }
    }

    private func loadPersonas() async {
        guard let client = connection.apiClient else { return }
        if let list = try? await client.get("/api/v1/personas", as: API.PersonaList.self) {
            personas = list.personas
        }
    }

    private func create() async {
        guard let client = connection.apiClient else { return }
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        creating = true
        defer { creating = false }
        do {
            let payload = API.NewChat(
                message: API.NewChatMessage(body: text),
                personaId: selectedPersonaId.isEmpty ? nil : selectedPersonaId,
                spaceId: spaceId
            )
            let data = try await client.request("POST", "/api/v1/chats", body: try JSONEncoder().encode(payload))
            let created = try JSONDecoder().decode(API.ChatSession.self, from: data)
            onCreated(created)
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
