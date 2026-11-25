import SwiftUI
import VesperCore

@MainActor
@Observable
final class CompanionChatStore {
    static let scope = "app:work"
    private static let currentChatKey = "vesper.work.chat"
    private static let personaKey = "vesper.dockPersona.app:work"

    var currentChatId: String? {
        didSet {
            if let currentChatId {
                UserDefaults.standard.set(currentChatId, forKey: Self.currentChatKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.currentChatKey)
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
        self.preferredPersonaId = UserDefaults.standard.string(forKey: Self.personaKey)
    }
}

/// Window-level native SwiftUI Companion Chat replacing `CompanionWebController` (`/companion` WKWebView).
/// Stays mounted across tab and route switches.
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
        let chats = context.store.entry(Self.dockListRequest).data?.chats ?? []
        let rememberedEntry = companionStore.currentChatId.map { context.store.entry(API.getChat(id: $0)) }
        let isGone: Bool = {
            if case .http(let status, _) = rememberedEntry?.error as? APIError { return status == 404 }
            return false
        }()
        let activeChatId = isGone ? nil : companionStore.currentChatId
        let activeChat = isGone ? nil : rememberedEntry?.data
        let welcome = WorkCompanionLogic.companionWelcome()

        DockedChatView(
            chatId: activeChatId,
            sections: [DockedChatSection(label: "Companion chats", chats: chats)],
            newChatLabel: "New chat",
            creating: companionStore.creating,
            createError: companionStore.createError,
            emptyDescription: "Talk things through with a persona. The same chat follows you to every page.",
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
            prepareBody: { $0 },
            prepareContextRefs: { $0 },
            onTurnCompleted: nil
        ) {
            EmptyView()
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
                        title: "Companion"
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
