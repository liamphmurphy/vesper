import SwiftUI
import VesperCore

struct DockedChatSection: Identifiable {
    let id: String
    let label: String
    let chats: [API.ChatSession]

    init(label: String, chats: [API.ChatSession]) {
        self.id = label
        self.label = label
        self.chats = chats
    }
}

private enum DockedChatRequests {
    static let personas = API.listPersonas()
    static let models = API.listChatModels()
    static let dock = API.getPersonaDock()
    static let workflows = API.listWorkflows()
    static let repositories = API.searchRepositories()
}

/// Reusable docked native conversation view for inspector panels (Companion Chat, Knowledge Chat)
/// built on `ChatTranscriptView` and `ChatComposerSlot`.
struct DockedChatView<ContextChips: View>: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.vesperWindowVisible) private var windowVisible
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let chatId: String?
    let sections: [DockedChatSection]
    let newChatLabel: String
    let creating: Bool
    let createError: String?
    let emptyDescription: String
    let emptyButtonTitle: String
    let welcomeWhere: String
    let welcomeIntro: String
    let starters: [DockedChatStarter]
    let onSelectChat: (String) -> Void
    let onNewChat: () -> Void
    let onOpenFullChat: (String) -> Void
    let prepareBody: (String) -> String
    let prepareContextRefs: ([API.ChatContextRef]?) -> [API.ChatContextRef]?
    let onTurnCompleted: (() -> Void)?
    /// Drafted into this chat's composer without sending (see `ChatComposerPrefill`).
    var composerPrefill: ChatComposerPrefill? = nil
    var onComposerPrefillApplied: (@MainActor (Int) -> Void)? = nil
    @ViewBuilder let contextChips: () -> ContextChips

    @State private var selectedHarness: API.Harness?
    @State private var selectedModel: String?
    @State private var selectedEffort: API.ChatEffort?
    @State private var selectedRepoUrl: String?
    @State private var watchedKeys: [QueryKey] = []
    @State private var wasRunning = false
    @State private var stoppingChatId: String? = nil
    @State private var lastDockFetch = Date()

    private var sessionRequest: APIRequest<API.ChatSession>? {
        chatId.map { API.getChat(id: $0) }
    }

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse>? {
        chatId.map { API.listChatMessages(id: $0, limit: 200) }
    }

    var body: some View {
        let p = theme.palette
        let store = context.store
        let personas = store.entry(DockedChatRequests.personas).data?.personas ?? []
        let harnessModels = store.entry(DockedChatRequests.models).data ?? []
        let harnesses = store.entry(DockedChatRequests.dock).data?.harnesses ?? []
        let workflows = store.entry(DockedChatRequests.workflows).data?.workflows ?? []
        let repositories = store.entry(DockedChatRequests.repositories).data ?? []
        let session = sessionRequest.flatMap { store.entry($0).data }
        let messages = messagesRequest.flatMap { store.entry($0).data?.messages } ?? []
        let activePersona: API.Persona? = {
            if let pid = session?.persona?.id, let match = personas.first(where: { $0.id == pid }) {
                return match
            }
            return personas.first(where: { $0.isDefault }) ?? personas.first
        }()
        let allKnownChats = sections.flatMap(\.chats)
        let currentSummary = allKnownChats.first(where: { $0.id == chatId }) ?? session
        let liveSince = ChatTurnActivity.runningSince(for: messages)
        let livePlanProgress: ChatPlanProgress? = {
            guard session?.state == .running, let runId = session?.currentRunId, !runId.isEmpty else { return nil }
            let events = store.entry(ChatTurnActivity.liveEventsRequest(runId: runId, since: liveSince)).data?.events ?? []
            guard !events.isEmpty else { return nil }
            let activity = ChatTurnActivity.fold(events: events.map(ChatRunEvent.init), since: liveSince)
            return ChatTurnActivity.planProgress(steps: activity.steps, planned: activity.planned)
        }()
        let longTurnUsageRefreshKey: String = {
            guard session?.state == .running, windowVisible, AppPowerState.shared.isActive else { return "" }
            return "\(chatId ?? "")|\(session?.currentRunId ?? "")|\(liveSince ?? "")"
        }()

        VStack(spacing: 0) {
            if chatId != nil || !allKnownChats.isEmpty {
                switcherBar(current: currentSummary, p: p)
                Divider()
            }

            if let chatId {
                let isEmpty = messages.filter { $0.role != .system }.isEmpty && session?.state != .running
                if isEmpty {
                    welcomeScrollView(p: p, activePersona: activePersona)
                } else {
                    ChatTranscriptView(
                        chatId: chatId,
                        session: session,
                        knownPersonaNames: personas.map(\.name),
                        personas: personas,
                        isStopping: stoppingChatId == chatId,
                        hasPinnedPlanBar: livePlanProgress != nil,
                        onSendReply: { reply in
                            Task {
                                _ = await sendDirectMessage(reply, chatId: chatId)
                            }
                        }
                    )
                    .id(chatId)
                }

                VStack(spacing: 6) {
                    contextChips()
                        .padding(.horizontal, 10)
                    ChatComposerSlot(
                        chatId: chatId,
                        session: session,
                        personas: personas,
                        activePersona: activePersona,
                        harnessModels: harnessModels,
                        harnesses: harnesses,
                        workflows: workflows,
                        repositories: repositories,
                        selectedHarness: $selectedHarness,
                        selectedModel: $selectedModel,
                        selectedEffort: $selectedEffort,
                        selectedRepoUrl: $selectedRepoUrl,
                        onSelectNewChatPersona: { _ in },
                        onSend: { submission in
                            await submit(submission, chatId: chatId)
                        },
                        onCancel: {
                            await cancelTurn(chatId: chatId)
                        },
                        onSetRepository: { repo in
                            await setRepository(repo, chatId: chatId)
                        },
                        onCompact: { focus in
                            await compactChat(focus: focus, chatId: chatId)
                        },
                        onStartWorkflow: { wfId, input in
                            await startWorkflow(wfId, input: input, chatId: chatId)
                        },
                        onStartMusic: { prompt in
                            await startMusic(prompt: prompt, chatId: chatId)
                        },
                        onCompare: { option, question in
                            await startCompare(option: option, question: question, chatId: chatId)
                        },
                        onStartLiveVoice: {
                            onOpenFullChat(chatId)
                        },
                        prefill: composerPrefill,
                        onPrefillApplied: onComposerPrefillApplied,
                        livePlanProgress: livePlanProgress,
                        livePlanTurnKey: "\(chatId)|\(liveSince ?? "")"
                    )
                }
                .padding(.top, 4)
            } else {
                emptyStartState(p: p)
            }
        }
        .task(id: "\(chatId ?? "")|\(session?.currentRunId ?? "")|\(session?.state.rawValue ?? "")|\(session?.state == .running ? (liveSince ?? "") : "")") {
            syncWatches(session: session, liveSince: liveSince)
        }
        .task(id: longTurnUsageRefreshKey) {
            guard !longTurnUsageRefreshKey.isEmpty else { return }
            let intervalMs = ChatTurnActivity.longTurnUsageRefreshIntervalMs
            let sinceMs = liveSince.map { Int((APIDate.epoch($0) * 1000).rounded()) }
            let nowMs = Int((Date().timeIntervalSince1970 * 1000).rounded())
            var initialDelayMs = ChatTurnActivity.longTurnUsageRefreshDelayMs(
                sinceEpochMs: sinceMs,
                nowEpochMs: nowMs,
                intervalMs: intervalMs
            )
            if initialDelayMs == 0 {
                let sinceLastFetchMs = Int((Date().timeIntervalSince(lastDockFetch) * 1000).rounded())
                if sinceLastFetchMs < intervalMs {
                    initialDelayMs = max(0, intervalMs - sinceLastFetchMs)
                }
            }
            if initialDelayMs > 0 {
                try? await Task.sleep(for: .milliseconds(initialDelayMs))
            }
            while !Task.isCancelled {
                lastDockFetch = Date()
                _ = await context.store.refetch(DockedChatRequests.dock)
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
        .onChange(of: session?.state == .running) { _, isRunning in
            if wasRunning && !isRunning {
                if stoppingChatId == chatId { stoppingChatId = nil }
                onTurnCompleted?()
            }
            wasRunning = isRunning
        }
        .onChange(of: session?.revision) { _, _ in
            if let chatId {
                Task { _ = await context.store.refetch(API.listChatMessages(id: chatId, limit: 200)) }
            }
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    private func switcherBar(current: API.ChatSession?, p: NativePalette) -> some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    onNewChat()
                } label: {
                    Label(newChatLabel, systemImage: "plus")
                }
                .disabled(creating)

                ForEach(sections) { section in
                    if !section.chats.isEmpty {
                        Section(section.label) {
                            ForEach(section.chats, id: \.id) { c in
                                Button {
                                    onSelectChat(c.id)
                                } label: {
                                    let label = c.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled chat" : c.title
                                    if c.id == chatId {
                                        Label(label, systemImage: "checkmark")
                                    } else {
                                        Text(label)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 11))
                        .foregroundStyle(p.secondaryText)
                    Text(current.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : $0.title } ?? "Chats")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
                showLiveThinking.toggle()
            } label: {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                    .foregroundStyle(showLiveThinking ? p.accent : p.secondaryText)
                    .frame(width: 24, height: 24)
                    .background(showLiveThinking ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showLiveThinking ? "Hide live thinking (/thinking off)" : "Show live thinking (/thinking on)")

            Button {
                onNewChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(creating)
            .help(newChatLabel)

            if let chatId {
                Button {
                    onOpenFullChat(chatId)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(p.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in full Chat")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func welcomeScrollView(p: NativePalette, activePersona: API.Persona?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    WorkPersonaAvatarView(
                        id: activePersona?.id,
                        handle: nil,
                        name: activePersona?.name ?? "Assistant",
                        size: 28,
                        active: false
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(activePersona?.name ?? "Assistant") \(welcomeWhere)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(p.text)
                        Text(welcomeIntro)
                            .font(.system(size: 12))
                            .foregroundStyle(p.secondaryText)
                    }
                }

                if !starters.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(starters) { starter in
                            Button {
                                guard let chatId else { return }
                                Task { _ = await sendDirectMessage(starter.prompt, chatId: chatId) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: starter.icon)
                                        .font(.system(size: 12))
                                        .foregroundStyle(p.accent)
                                        .frame(width: 18)
                                    Text(starter.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(p.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .modifier(VesperHoverCardModifier(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStartState(p: NativePalette) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(p.tertiaryText)
            contextChips()
            Text(emptyDescription)
                .font(.system(size: 13))
                .foregroundStyle(p.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(emptyButtonTitle) {
                onNewChat()
            }
            .buttonStyle(.borderedProminent)
            .disabled(creating)
            if let createError {
                Text(createError)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncWatches(session: API.ChatSession?, liveSince: String?) {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        watch(DockedChatRequests.personas)
        watch(DockedChatRequests.models)
        watch(DockedChatRequests.dock)
        watch(DockedChatRequests.workflows)
        watch(DockedChatRequests.repositories)
        if let req = sessionRequest { watch(req) }
        if let req = messagesRequest { watch(req) }
        if let chatId { watch(API.listChatAsides(id: chatId)) }
        if session?.state == .running, let runId = session?.currentRunId, !runId.isEmpty {
            watch(ChatTurnActivity.liveEventsRequest(runId: runId, since: liveSince))
        }
    }

    private func submit(_ submission: ChatComposerSubmission, chatId: String) async -> String? {
        let preparedBody = prepareBody(submission.body)
        do {
            switch submission.mode {
            case .steer:
                _ = try await context.store.mutate(
                    API.steerChat(id: chatId, body: API.ChatMessageEdit(body: preparedBody)),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                return nil
            case .queue:
                let queued = try await context.store.mutate(
                    API.queueChatFollowup(id: chatId, body: API.ChatMessageEdit(body: preparedBody))
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
                        body: preparedBody,
                        effort: selectedEffort,
                        harness: selectedHarness,
                        model: selectedModel
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                return nil
            case .send, .interrupt:
                return await sendDirectMessage(
                    submission.body,
                    chatId: chatId,
                    attachmentIds: submission.attachmentIds,
                    contextRefs: submission.contextRefs,
                    research: submission.research
                )
            }
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func sendDirectMessage(
        _ rawBody: String,
        chatId: String,
        attachmentIds: [String] = [],
        contextRefs: [API.ChatContextRef]? = nil,
        research: Bool = false
    ) async -> String? {
        let body = prepareBody(rawBody)
        let mergedRefs = prepareContextRefs(contextRefs)
        let msg = API.NewChatMessage(
            attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
            body: body,
            contextRefs: mergedRefs,
            effort: selectedEffort.map { API.NewChatMessage.Effort(rawValue: $0.rawValue) },
            harness: selectedHarness,
            model: selectedModel,
            research: research ? true : nil
        )
        do {
            let posted = try await context.store.mutate(API.postChatMessage(id: chatId, body: msg))
            context.store.setData(posted.chat, for: API.getChat(id: chatId))
            let listReq = API.listChatMessages(id: chatId, limit: 200)
            if var existing = context.store.entry(listReq).data,
               !existing.messages.contains(where: { $0.id == posted.message.id }) {
                existing.messages.append(posted.message)
                context.store.setData(existing, for: listReq)
            }
            context.store.invalidate(QueryInvalidation(resources: ["chats"]))
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func cancelTurn(chatId: String) async {
        stoppingChatId = chatId
        do {
            _ = try await context.store.mutate(
                API.cancelChatTurn(id: chatId),
                invalidating: QueryInvalidation(resources: ["chats"])
            )
        } catch {
            if stoppingChatId == chatId { stoppingChatId = nil }
        }
    }

    private func setRepository(_ repoUrl: String, chatId: String) async -> String? {
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

    private func compactChat(focus: String?, chatId: String) async -> String? {
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

    private func startWorkflow(_ workflowId: String, input: String, chatId: String) async -> String? {
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

    private func startMusic(prompt: String, chatId: String) async -> String? {
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

    private func startCompare(option: ChatCompareOption, question: String, chatId: String) async -> String? {
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
}
