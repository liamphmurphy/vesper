import SwiftUI
import VesperCore

/// Native Slack-style aside thread inspector for a single chat message.
/// Replaces the web `chat.thread` `/inspector-panel` tab.
struct ChatThreadInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let messageId: String

    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var watchedKeys: [QueryKey] = []

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: chatId, limit: 200)
    }

    private var asidesRequest: APIRequest<API.ChatAsideList> {
        API.listChatAsides(id: chatId)
    }

    private var hostChatRequest: APIRequest<API.ChatSession> {
        API.getChat(id: chatId)
    }

    private static func excerpt(_ text: String) -> String {
        if text.count <= 280 { return text }
        let idx = text.index(text.startIndex, offsetBy: 280)
        return text[..<idx].trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    var body: some View {
        let p = theme.palette
        let parentMessages = context.store.entry(messagesRequest).data?.messages ?? []
        let parent = parentMessages.first(where: { $0.id == messageId })
        let host = context.store.entry(hostChatRequest).data
        let asides = context.store.entry(asidesRequest).data?.asides ?? []
        let thread = asides.last(where: { $0.anchorMessageId == messageId && $0.secondOpinion != true })

        let threadSession = thread.flatMap { context.store.entry(API.getChat(id: $0.id)).data } ?? thread
        let threadMessages = (thread.flatMap { context.store.entry(API.listChatMessages(id: $0.id, limit: 100)).data?.messages } ?? [])
            .filter { $0.role != .system }
        let isRunning = threadSession?.state == .running

        let anchorPersona: API.PersonaSummary? = {
            if let mp = parent?.persona { return mp }
            if parent?.role == .assistant { return host?.speaker ?? host?.persona }
            return nil
        }()
        let threadPersona = threadSession?.speaker ?? threadSession?.persona ?? host?.speaker ?? host?.persona

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Anchor message card
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if let anchorPersona {
                                WorkPersonaAvatarView(
                                    id: anchorPersona.id,
                                    handle: nil,
                                    name: anchorPersona.name,
                                    size: 16,
                                    active: false
                                )
                                Text(anchorPersona.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(p.secondaryText)
                            } else {
                                Text(parent?.role == .user ? "You" : "Message")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(p.tertiaryText)
                            }
                        }
                        Text(parent.map { Self.excerpt($0.bodyMd) } ?? "This message isn\u{2019}t loaded.")
                            .font(.system(size: 13))
                            .foregroundStyle(p.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))

                    if thread != nil {
                        HStack(spacing: 8) {
                            Rectangle().fill(p.border).frame(height: 1)
                            Text("\(threadMessages.count) \(threadMessages.count == 1 ? "message" : "messages")")
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                                .fixedSize()
                            Rectangle().fill(p.border).frame(height: 1)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(threadMessages, id: \.id) { msg in
                                if msg.role == .user {
                                    HStack {
                                        Spacer(minLength: 28)
                                        Text(msg.bodyMd)
                                            .font(.system(size: 13))
                                            .foregroundStyle(p.text)
                                            .textSelection(.enabled)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(p.selected, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            WorkPersonaAvatarView(
                                                id: threadPersona?.id,
                                                handle: nil,
                                                name: threadPersona?.name ?? "Assistant",
                                                size: 16,
                                                active: false
                                            )
                                            Text(threadPersona?.name ?? "Assistant")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(p.tertiaryText)
                                        }
                                        MarkdownView(markdown: msg.bodyMd, textStyle: .chat, chat: true)
                                    }
                                }
                            }

                            if isRunning {
                                HStack(spacing: 8) {
                                    WorkPersonaAvatarView(
                                        id: threadPersona?.id,
                                        handle: nil,
                                        name: threadPersona?.name ?? "Assistant",
                                        size: 16,
                                        active: true
                                    )
                                    Text("\(threadPersona?.name ?? "Assistant") is answering\u{2026}")
                                        .font(.system(size: 12))
                                        .foregroundStyle(p.secondaryText)
                                }
                            }
                        }
                    } else {
                        Text("Ask about this message. The main conversation won\u{2019}t see this thread.")
                            .font(.system(size: 12))
                            .foregroundStyle(p.tertiaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                }
                .padding(12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let sendError {
                    Text(sendError)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        thread == nil ? "Ask about this message\u{2026}" : (isRunning ? "Wait for the answer\u{2026}" : "Reply in thread\u{2026}"),
                        text: $draft,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .disabled(sending || isRunning)
                    .onSubmit {
                        submit(threadId: thread?.id, running: isRunning)
                    }

                    Button {
                        submit(threadId: thread?.id, running: isRunning)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(canSend(running: isRunning) ? p.accent : p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend(running: isRunning))
                    .accessibilityLabel("Send in thread")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            }
            .padding(10)
        }
        .task(id: "\(chatId):\(messageId):\(thread?.id ?? "")") {
            syncWatches(threadId: thread?.id)
        }
        .onChange(of: threadSession?.revision) { _, _ in
            if let tid = thread?.id {
                Task { _ = await context.store.refetch(API.listChatMessages(id: tid, limit: 100)) }
            }
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    private func canSend(running: Bool) -> Bool {
        !sending && !running && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func syncWatches(threadId: String?) {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        watch(messagesRequest)
        watch(asidesRequest)
        watch(hostChatRequest)
        if let threadId {
            watch(API.getChat(id: threadId))
            watch(API.listChatMessages(id: threadId, limit: 100))
        }
    }

    private func submit(threadId: String?, running: Bool) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending, !running else { return }
        draft = ""
        sendError = nil
        sending = true
        Task {
            defer { sending = false }
            do {
                if let threadId {
                    _ = try await context.store.mutate(
                        API.postChatMessage(id: threadId, body: API.NewChatMessage(body: body)),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                    _ = await context.store.refetch(API.listChatMessages(id: threadId, limit: 100))
                    _ = await context.store.refetch(API.getChat(id: threadId))
                } else {
                    let created = try await context.store.mutate(
                        API.startChatAside(id: chatId, body: API.ChatAsideStart(anchorMessageId: messageId, body: body)),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                    _ = await context.store.refetch(asidesRequest)
                    context.store.load(API.listChatMessages(id: created.id, limit: 100))
                }
            } catch {
                draft = body
                sendError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
