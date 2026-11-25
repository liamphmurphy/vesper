import SwiftUI
import VesperCore

struct ChatListView: View {
    let connection: CompanionConnectionManager
    let sseTick: Int

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
                    initialTitle: chats.first(where: { $0.id == chatId })?.title ?? "Chat",
                    sseTick: sseTick
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
            .onChange(of: sseTick) { _, _ in
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
                    initialTitle: chats.first(where: { $0.id == chatId })?.title ?? "Chat",
                    sseTick: sseTick
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

private struct ChatRow: View {
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

struct ChatDetailView: View {
    let connection: CompanionConnectionManager
    let chatId: String
    let initialTitle: String
    let sseTick: Int

    @State private var title: String
    @State private var chatState: API.ChatState = .idle
    @State private var messages: [API.ChatMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var errorMessage: String?

    init(connection: CompanionConnectionManager, chatId: String, initialTitle: String, sseTick: Int) {
        self.connection = connection
        self.chatId = chatId
        self.initialTitle = initialTitle
        self.sseTick = sseTick
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages, id: \.id) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if chatState == .running {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .id("thinking-indicator")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.apiClient == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: sseTick) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard let client = connection.apiClient else { return }
        do {
            async let chatReq: API.ChatSession = client.get("/api/v1/chats/\(chatId)", as: API.ChatSession.self)
            async let msgReq: API.ListChatMessagesResponse = client.get("/api/v1/chats/\(chatId)/messages?limit=100", as: API.ListChatMessagesResponse.self)
            let (chat, msgResp) = try await (chatReq, msgReq)
            title = chat.title.isEmpty ? initialTitle : chat.title
            chatState = chat.state
            messages = msgResp.messages
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func sendMessage() async {
        guard let client = connection.apiClient else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        draft = ""
        defer { sending = false }
        do {
            let body = try JSONEncoder().encode(API.NewChatMessage(body: text))
            _ = try await client.request("POST", "/api/v1/chats/\(chatId)/messages", body: body)
            await refresh()
        } catch {
            draft = text
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct MessageBubble: View {
    let message: API.ChatMessage

    private var isUser: Bool { message.role.rawValue == "user" }
    private var isSystem: Bool { message.role.rawValue == "system" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser && !isSystem, let persona = message.persona?.name, !persona.isEmpty {
                    Text(persona)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                markdownText(message.bodyMd)
                    .font(isSystem ? .caption : .body)
                    .foregroundStyle(isUser ? .white : (isSystem ? .secondary : .primary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        isUser ? Color.accentColor : (isSystem ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.14)),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .textSelection(.enabled)
            }
            if !isUser { Spacer(minLength: 24) }
        }
    }

    @ViewBuilder
    private func markdownText(_ md: String) -> some View {
        if let attr = try? AttributedString(
            markdown: md,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
        } else {
            Text(md)
        }
    }
}

private struct NewChatSheet: View {
    let connection: CompanionConnectionManager
    let onCreated: (API.ChatSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var personas: [API.Persona] = []
    @State private var selectedPersonaId: String = ""
    @State private var messageText = ""
    @State private var creating = false
    @State private var errorMessage: String?

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
                personaId: selectedPersonaId.isEmpty ? nil : selectedPersonaId
            )
            let data = try await client.request("POST", "/api/v1/chats", body: try JSONEncoder().encode(payload))
            let created = try JSONDecoder().decode(API.ChatSession.self, from: data)
            onCreated(created)
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
