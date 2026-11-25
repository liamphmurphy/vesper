import SwiftUI
import VesperCore

struct SpacesView: View {
    let connection: CompanionConnectionManager

    @State private var spaces: [API.ChatSpace] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if spaces.isEmpty && !loading {
                    ContentUnavailableView(
                        "No Spaces Yet",
                        systemImage: "square.stack.3d.up",
                        description: Text("Spaces you create on your Mac will appear here with their chats, tasks, and context.")
                    )
                } else {
                    ForEach(spaces, id: \.id) { space in
                        NavigationLink(value: space.id) {
                            SpaceRow(space: space)
                        }
                    }
                }
            }
            .navigationTitle("Spaces")
            .navigationDestination(for: String.self) { spaceId in
                SpaceDetailView(
                    connection: connection,
                    spaceId: spaceId,
                    initialSpace: spaces.first(where: { $0.id == spaceId })
                )
            }
            .refreshable { await load() }
            .task(id: connection.state) { await load() }
            .onChange(of: connection.eventVersion) { _, _ in
                Task { await load(silent: true) }
            }
        }
    }

    private func load(silent: Bool = false) async {
        guard let client = connection.apiClient else { return }
        if !silent { loading = true }
        defer { loading = false }
        do {
            let resp = try await client.send(API.listChatSpaces())
            spaces = SpacesLogic.sortSpacesByActivity(resp.spaces)
            errorMessage = nil
        } catch {
            if !silent {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private struct SpaceRow: View {
    let space: API.ChatSpace

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(spaceAccentColor(space.color).opacity(0.18))
                    .frame(width: 34, height: 34)
                Text(SpacesLogic.initial(for: space.name))
                    .font(.subheadline.bold())
                    .foregroundStyle(spaceAccentColor(space.color))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(space.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if let persona = space.persona?.name, !persona.isEmpty {
                        Text(persona)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if !space.description.isEmpty {
                    Text(space.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Label("\(space.chatCount)", systemImage: "bubble.left.and.bubble.right")
                    if let openTasks = space.openTaskCount, openTasks > 0 {
                        Label("\(openTasks)", systemImage: "checklist")
                    }
                    if let repoCount = space.repoCount, repoCount > 0 {
                        Label("\(repoCount)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    if space.sourceCount > 0 {
                        Label("\(space.sourceCount)", systemImage: "doc.text")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct SpaceDetailView: View {
    let connection: CompanionConnectionManager
    let spaceId: String
    let initialSpace: API.ChatSpace?

    @State private var space: API.ChatSpace?
    @State private var chats: [API.ChatSession] = []
    @State private var tasks: [API.ChatSpaceTask] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showNewChat = false
    @State private var createdChatId: String?

    init(connection: CompanionConnectionManager, spaceId: String, initialSpace: API.ChatSpace?) {
        self.connection = connection
        self.spaceId = spaceId
        self.initialSpace = initialSpace
        _space = State(initialValue: initialSpace)
    }

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let space {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(spaceAccentColor(space.color))
                                .frame(width: 10, height: 10)
                            Text(space.name)
                                .font(.headline)
                            Spacer()
                            if let persona = space.persona?.name, !persona.isEmpty {
                                Text(persona)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.14), in: Capsule())
                            }
                        }
                        if !space.description.isEmpty {
                            Text(space.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !space.instructions.isEmpty {
                            Text(space.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !tasks.isEmpty {
                let openTasks = tasks.filter { !$0.done }
                let doneTasks = tasks.filter { $0.done }
                Section("Tasks (\(openTasks.count) open)") {
                    ForEach(openTasks + doneTasks.prefix(5), id: \.id) { task in
                        Button {
                            Task { await toggleTask(task) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.done ? .green : .secondary)
                                Text(task.title)
                                    .strikethrough(task.done)
                                    .foregroundStyle(task.done ? .secondary : .primary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Chats (\(chats.count))") {
                if chats.isEmpty && !loading {
                    Text("No chats in this Space yet. Tap the compose button to start one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chats, id: \.id) { chat in
                        NavigationLink {
                            ChatDetailView(
                                connection: connection,
                                chatId: chat.id,
                                initialTitle: chat.title.isEmpty ? "Chat" : chat.title
                            )
                        } label: {
                            ChatRow(chat: chat)
                        }
                    }
                }
            }

            if let space {
                let repos = space.repositories ?? []
                let links = space.knowledgeLinks ?? []
                if !repos.isEmpty || !links.isEmpty || space.sourceCount > 0 || space.memoryCount > 0 {
                    Section("Context") {
                        if !repos.isEmpty {
                            ForEach(repos, id: \.repoUrl) { repo in
                                Label(repo.repoUrl, systemImage: "chevron.left.forwardslash.chevron.right")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        if !links.isEmpty {
                            Label("\(links.count) Knowledge link\(links.count == 1 ? "" : "s")", systemImage: "book.closed")
                                .font(.caption)
                        }
                        if space.sourceCount > 0 {
                            Label("\(space.sourceCount) source\(space.sourceCount == 1 ? "" : "s")", systemImage: "doc.text")
                                .font(.caption)
                        }
                        if space.memoryCount > 0 {
                            Label("\(space.memoryCount) space memor\(space.memoryCount == 1 ? "y" : "ies")", systemImage: "brain")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(space?.name ?? "Space")
        .navigationBarTitleDisplayMode(.inline)
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
        .task(id: spaceId) { await load() }
        .onChange(of: connection.eventVersion) { _, _ in
            Task { await load(silent: true) }
        }
        .sheet(isPresented: $showNewChat) {
            NewChatSheet(
                connection: connection,
                spaceId: spaceId,
                defaultPersonaId: space?.personaId
            ) { chat in
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

    private func load(silent: Bool = false) async {
        guard let client = connection.apiClient else { return }
        if !silent { loading = true }
        defer { loading = false }
        do {
            async let spaceReq = client.send(API.getChatSpace(spaceId: spaceId))
            async let chatsReq = client.send(SpacesLogic.spaceChatsRequest(spaceId: spaceId))
            async let tasksReq = client.send(API.listChatSpaceTasks(spaceId: spaceId))
            let (s, c, t) = try await (spaceReq, chatsReq, tasksReq)
            space = s
            chats = SpacesLogic.sortChats(c.chats, sort: .newest)
            tasks = t.tasks
            errorMessage = nil
        } catch {
            if !silent {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func toggleTask(_ task: API.ChatSpaceTask) async {
        guard let client = connection.apiClient else { return }
        do {
            _ = try await client.send(
                API.updateChatSpaceTask(
                    spaceId: spaceId,
                    taskId: task.id,
                    body: API.ChatSpaceTaskPatch(done: !task.done)
                )
            )
            await load(silent: true)
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

func spaceAccentColor(_ color: API.ChatSpaceColor) -> Color {
    switch color {
    case .green: return .green
    case .amber: return .yellow
    case .red: return .red
    case .blue: return .blue
    case .violet: return .purple
    case .pink: return .pink
    case .teal: return .teal
    case .orange: return .orange
    default: return .accentColor
    }
}
