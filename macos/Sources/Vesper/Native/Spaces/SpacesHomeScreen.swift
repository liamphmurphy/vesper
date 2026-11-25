import SwiftUI
import VesperCore

/// Native `/spaces` homepage: cross-space In-Flight strip (running/unread chats and open PRs)
/// plus a grid of all Spaces sorted by most recent activity.
struct SpacesHomeScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var watchedKeys: [QueryKey] = []

    private static let spacesRequest = API.listChatSpaces()
    private static let allChatsRequest = SpacesLogic.allSpaceChatsRequest
    private static let allBranchesRequest = API.listAllChatSpaceBranches()
    private static let personasRequest = API.listPersonas()

    var body: some View {
        let p = theme.palette
        let spacesEntry = context.store.entry(Self.spacesRequest)
        let rawSpaces = spacesEntry.data?.spaces ?? []
        let spaces = SpacesLogic.sortSpacesByActivity(rawSpaces)
        let allChats = context.store.entry(Self.allChatsRequest).data?.chats ?? []
        let spaceChats = allChats.filter { $0.space != nil }
        let inFlightChats = SpacesLogic.inFlightChats(spaceChats)
        let activeBranches = SpacesLogic.activeBranches(
            context.store.entry(Self.allBranchesRequest).data?.branches ?? []
        )
        let personas = context.store.entry(Self.personasRequest).data?.personas ?? []
        let spaceById = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        let runningSpaceIds = Set(inFlightChats.filter { $0.state == .running }.compactMap { $0.space?.id })
        let unreadSpaceIds = Set(inFlightChats.filter { $0.unread > 0 }.compactMap { $0.space?.id })
        let activeBranchCounts = Dictionary(grouping: activeBranches.compactMap(\.spaceId), by: { $0 }).mapValues(\.count)

        let currentChrome = NativeChrome(
            title: "Spaces",
            toolbarItems: [
                ShellToolbarItem(id: "spaces.new", label: "New space", icon: "plus", kind: .button, accent: true, showsLabel: true),
            ],
            navigator: SpacesLogic.navModel(
                spaces: rawSpaces,
                activeSpaceId: nil,
                personas: personas,
                origin: context.baseURL()
            )
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spaces")
                        .vesperText(.display, theme)
                    Text("Focused workbenches with shared instructions, live repos, Knowledge links, and isolated memory.")
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                }

                if let error = spacesEntry.error, spaces.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Couldn\u{2019}t load spaces")
                                .font(.system(size: 13, weight: .semibold))
                            Text(error.userMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(p.secondaryText)
                        }
                        Spacer()
                        Button("Retry") {
                            Task { _ = await context.store.refetch(Self.spacesRequest) }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                } else if spacesEntry.data == nil && spacesEntry.isFetching {
                    ProgressView("Loading spaces\u{2026}")
                        .padding(.vertical, 24)
                } else if spaces.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 26))
                            .foregroundStyle(p.tertiaryText)
                        Text("Create your first Space")
                            .vesperText(.heading, theme)
                        Text("Group chats around a repo, a Knowledge folder, or a long-running project with shared instructions and memory.")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                        Button {
                            context.navigate("/spaces/new")
                        } label: {
                            Label("New space", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
                } else {
                    if !inFlightChats.isEmpty || !activeBranches.isEmpty {
                        inFlightSection(
                            chats: inFlightChats,
                            branches: activeBranches,
                            spaceById: spaceById,
                            p: p
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("ALL SPACES")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(p.tertiaryText)
                            Text("\(spaces.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(p.tertiaryText)
                            Spacer()
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 14)], spacing: 14) {
                            ForEach(spaces, id: \.id) { space in
                                spaceCard(
                                    space: space,
                                    isRunning: runningSpaceIds.contains(space.id),
                                    hasUnread: unreadSpaceIds.contains(space.id),
                                    openPRCount: activeBranchCounts[space.id] ?? 0,
                                    p: p
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            syncWatches()
            context.chrome = currentChrome
            installCommands()
        }
        .onChange(of: currentChrome) { _, next in
            context.chrome = next
        }
        .onDisappear {
            context.onCommand = nil
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    // MARK: - Cross-Space In Flight

    private func inFlightSection(
        chats: [API.ChatSession],
        branches: [API.ChatSpaceBranch],
        spaceById: [String: API.ChatSpace],
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IN FLIGHT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(p.tertiaryText)

            VStack(spacing: 6) {
                ForEach(chats.prefix(6), id: \.id) { chat in
                    Button {
                        context.navigate("/chat/\(chat.id)")
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(chat.state == .running
                                    ? theme.swiftUIColor("state-done", fallback: .green)
                                    : theme.swiftUIColor("state-human", fallback: .purple))
                                .frame(width: 7, height: 7)
                            if let sp = chat.space {
                                spacePill(name: sp.name, color: sp.color, p: p)
                            }
                            Text(chat.title.isEmpty ? "Untitled chat" : chat.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            Spacer()
                            Text(chat.state == .running ? "Running" : "\(chat.unread) unread")
                                .font(.system(size: 11))
                                .foregroundStyle(p.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(branches.prefix(6), id: \.spaceBranchKey) { b in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                            .foregroundStyle(p.accent)
                        if let sid = b.spaceId, let sp = spaceById[sid] {
                            Button {
                                context.navigate("/spaces/\(sp.id)")
                            } label: {
                                spacePill(name: sp.name, color: sp.color, p: p)
                            }
                            .buttonStyle(.plain)
                        } else if let name = b.spaceName, !name.isEmpty {
                            spacePill(name: name, color: .green, p: p)
                        }
                        Text(b.branch)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Text(ChatCodeReviewLogic.repoName(b.repoUrl))
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                        Text(SpacesLogic.branchStatusLabel(for: b))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(p.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(p.background, in: Capsule())
                            .overlay(Capsule().stroke(p.border))
                        Spacer()
                        if let prUrl = b.prUrl, !prUrl.isEmpty {
                            Button(b.prNumber.map { "PR #\($0) \u{2197}" } ?? "PR \u{2197}") {
                                context.openExternal(prUrl)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.accent)
                        }
                        Button("Chat \u{2192}") { context.navigate("/chat/\(b.chatId)") }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
            }
        }
    }

    // MARK: - Space Card

    private func spaceCard(
        space: API.ChatSpace,
        isRunning: Bool,
        hasUnread: Bool,
        openPRCount: Int,
        p: NativePalette
    ) -> some View {
        Button {
            context.navigate("/spaces/\(space.id)")
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    spaceTile(name: space.name, color: space.color, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(space.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            if isRunning {
                                Circle()
                                    .fill(theme.swiftUIColor("state-done", fallback: .green))
                                    .frame(width: 6, height: 6)
                            } else if hasUnread {
                                Circle()
                                    .fill(theme.swiftUIColor("state-human", fallback: .purple))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        Text(APIDate.shortAgo(space.lastActivityAt ?? space.updatedAt))
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                    }
                    Spacer(minLength: 4)
                    if let persona = space.persona {
                        WorkPersonaAvatarView(
                            id: persona.id,
                            handle: nil,
                            name: persona.name,
                            size: 20,
                            active: false
                        )
                    }
                }

                let desc = space.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 6) {
                    if let rc = space.repoCount, rc > 0 {
                        metaBadge(icon: "chevron.left.forwardslash.chevron.right", text: "\(rc)", p: p)
                    }
                    if let kc = space.knowledgeCount, kc > 0 {
                        metaBadge(icon: "book.closed", text: "\(kc)", p: p)
                    }
                    if let tc = space.openTaskCount, tc > 0 {
                        metaBadge(icon: "checklist", text: "\(tc)", p: p)
                    }
                    if openPRCount > 0 {
                        metaBadge(icon: "arrow.triangle.branch", text: "\(openPRCount)", accent: true, p: p)
                    }
                    Spacer()
                    Text("\(space.chatCount) chat\(space.chatCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func spaceTile(name: String, color: API.ChatSpaceColor, size: CGFloat) -> some View {
        let bg = Color(cssHex: SpacesLogic.colorHex(for: color)) ?? .green
        return Text(SpacesLogic.initial(for: name))
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.75))
            .frame(width: size, height: size)
            .background(bg, in: RoundedRectangle(cornerRadius: 8))
    }

    private func spacePill(name: String, color: API.ChatSpaceColor, p: NativePalette) -> some View {
        let dot = Color(cssHex: SpacesLogic.colorHex(for: color)) ?? .green
        return HStack(spacing: 4) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(p.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(p.background, in: Capsule())
        .overlay(Capsule().stroke(p.border))
    }

    private func metaBadge(icon: String, text: String, accent: Bool = false, p: NativePalette) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(accent ? p.accent : p.secondaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(p.background, in: Capsule())
        .overlay(Capsule().stroke(p.border))
    }

    // MARK: - Watches & Commands

    private func syncWatches() {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        watch(Self.spacesRequest)
        watch(Self.allChatsRequest)
        watch(Self.allBranchesRequest)
        watch(Self.personasRequest)
    }

    private func installCommands() {
        context.onCommand = { cmd in
            if let navAction = SpacesLogic.navAction(for: cmd) {
                switch navAction {
                case .newSpace: context.navigate("/spaces/new")
                case .openSpace(let id, let newTab):
                    if newTab { context.openInNewTab("/spaces/\(id)") } else { context.navigate("/spaces/\(id)") }
                case .openChat(let id, let newTab):
                    if newTab { context.openInNewTab("/chat/\(id)") } else { context.navigate("/chat/\(id)") }
                }
                return
            }
            if case .toolbarAction(let itemId, _) = cmd, itemId == "spaces.new" {
                context.navigate("/spaces/new")
            }
        }
    }
}
