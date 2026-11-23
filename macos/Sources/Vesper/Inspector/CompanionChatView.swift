import SwiftUI
import VesperCore

@MainActor
@Observable
final class CompanionChatStore {
    static let scope = "app:work"
    private static let currentChatKey = "vesper.work.chat"
    private static let pinnedSubjectKey = "vesper.work.pinned"
    private static let personaKey = "vesper.dockPersona.app:work"

    var subject: CompanionSubject?
    var currentChatId: String? {
        didSet {
            if let currentChatId {
                UserDefaults.standard.set(currentChatId, forKey: Self.currentChatKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.currentChatKey)
            }
        }
    }
    var pinned: CompanionSubject? {
        didSet {
            if let pinned, let data = try? JSONEncoder().encode(pinned) {
                UserDefaults.standard.set(data, forKey: Self.pinnedSubjectKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pinnedSubjectKey)
            }
        }
    }
    var preferredPersonaId: String? {
        didSet {
            if let preferredPersonaId {
                UserDefaults.standard.set(preferredPersonaId, forKey: Self.personaKey)
            }
        }
    }
    var creating = false
    var createError: String?

    init() {
        self.currentChatId = UserDefaults.standard.string(forKey: Self.currentChatKey)
        if let data = UserDefaults.standard.data(forKey: Self.pinnedSubjectKey),
           let decoded = try? JSONDecoder().decode(CompanionSubject.self, from: data) {
            self.pinned = decoded
        }
        self.preferredPersonaId = UserDefaults.standard.string(forKey: Self.personaKey)
    }
}

/// Window-level native SwiftUI Companion Chat replacing `CompanionWebController` (`/companion` WKWebView).
/// Stays mounted across tab and route switches while its `subject` follows the active tab's inspector model.
struct CompanionChatHost: View {
    let tabs: TabsModel
    let companionStore: CompanionChatStore
    let screenContext: NativeScreenContext

    var body: some View {
        let state = tabs.list.active?.state
        let theme = state?.theme ?? ThemeTokens(mode: state?.pageMode ?? .light)
        let colorScheme: ColorScheme = (state?.pageMode ?? theme.mode) == .dark ? .dark : .light
        CompanionChatView(companionStore: companionStore)
            .environment(screenContext)
            .environment(\.vesperTheme, theme)
            .environment(\.colorScheme, colorScheme)
            .vesperTrackHostVisibility()
    }
}

private struct CompanionChatView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let companionStore: CompanionChatStore

    private static let dockListRequest = DockChatsAPI.list(scope: CompanionChatStore.scope)

    var body: some View {
        let p = theme.palette
        let chats = context.store.entry(Self.dockListRequest).data?.chats ?? []
        let rememberedEntry = companionStore.currentChatId.map { context.store.entry(API.getChat(id: $0)) }
        let isGone: Bool = {
            if case .http(let status, _) = rememberedEntry?.error as? APIError { return status == 404 }
            return false
        }()
        let activeChatId = isGone ? nil : companionStore.currentChatId
        let activeChat = isGone ? nil : rememberedEntry?.data
        let subject = companionStore.subject
        let pinned = companionStore.pinned
        let welcome = WorkCompanionLogic.workWelcome(for: subject)

        let emptyText = subject.map {
            "Talk it through with a persona. It can read the \($0.kind.rawValue) and its ticket; replies to the agent stay in the main pane."
        } ?? "Talk your work through with a persona: runs, tickets, what's waiting on you. The same chat follows you to every page."

        DockedChatView(
            chatId: activeChatId,
            sections: [DockedChatSection(label: "Work chats", chats: chats)],
            newChatLabel: "New chat",
            creating: companionStore.creating,
            createError: companionStore.createError,
            emptyDescription: emptyText,
            emptyButtonTitle: "Start a chat",
            welcomeWhere: welcome.whereText,
            welcomeIntro: welcome.intro,
            starters: welcome.starters,
            onSelectChat: { nextId in
                selectChat(nextId)
            },
            onNewChat: {
                startNewChat()
            },
            onOpenFullChat: { id in
                context.navigate("/chat/\(id)")
            },
            prepareBody: { body in
                WorkCompanionLogic.withWorkContext(body, viewing: subject, pinned: pinned)
            },
            prepareContextRefs: { refs in
                WorkCompanionLogic.mergeWorkContextRefs(existing: refs, viewing: subject, pinned: pinned)
            },
            onTurnCompleted: nil
        ) {
            contextChipsView(subject: subject, pinned: pinned, p: p)
        }
        .task {
            context.store.observe(Self.dockListRequest)
            context.store.load(Self.dockListRequest)
            if let id = companionStore.currentChatId {
                context.store.load(API.getChat(id: id))
            }
        }
        .onChange(of: activeChat?.persona?.id) { _, nextPersonaId in
            if let nextPersonaId {
                companionStore.preferredPersonaId = nextPersonaId
            }
        }
        .onDisappear {
            context.store.stopObserving(Self.dockListRequest.key)
        }
    }

    @ViewBuilder
    private func contextChipsView(subject: CompanionSubject?, pinned: CompanionSubject?, p: NativePalette) -> some View {
        let viewingIsPinned = pinned != nil && subject != nil && WorkCompanionLogic.sameSubject(pinned!, subject!)
        if pinned != nil || (subject != nil && !viewingIsPinned) {
            HStack(spacing: 6) {
                if let pinned {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(p.accent)
                        Text("Pinned: \(WorkCompanionLogic.workSubjectLabel(pinned))")
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        Button {
                            companionStore.pinned = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Unpin")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(p.surface, in: Capsule())
                    .overlay(Capsule().stroke(p.border))
                }

                if let subject, !viewingIsPinned {
                    HStack(spacing: 4) {
                        Image(systemName: subject.kind == .run ? "play.fill" : "checklist")
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                        Text("Viewing: \(WorkCompanionLogic.workSubjectLabel(subject))")
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        Button {
                            companionStore.pinned = subject
                        } label: {
                            Image(systemName: "bookmark")
                                .font(.system(size: 10))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Pin: keep it attached as you move to other runs and tickets")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(p.surface, in: Capsule())
                    .overlay(Capsule().stroke(p.border))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func selectChat(_ id: String) {
        companionStore.currentChatId = id
        Task {
            _ = try? await context.store.mutate(DockChatsAPI.add(scope: CompanionChatStore.scope, chatId: id))
            _ = await context.store.refetch(Self.dockListRequest)
        }
    }

    private func startNewChat() {
        guard !companionStore.creating else { return }
        companionStore.creating = true
        companionStore.createError = nil
        Task {
            defer { companionStore.creating = false }
            do {
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        hidden: true,
                        personaId: companionStore.preferredPersonaId,
                        title: "Work"
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                selectChat(created.id)
            } catch {
                companionStore.createError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
