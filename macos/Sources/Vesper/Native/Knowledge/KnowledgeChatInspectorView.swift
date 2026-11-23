import SwiftUI
import VesperCore

/// A composer draft for one Knowledge page's chat (Ask a Persona to export it as a PDF).
struct KnowledgeChatPrefill: Equatable {
    let pageId: String
    let prefill: ChatComposerPrefill
}

/// Native SwiftUI Knowledge Chat inspector tab replacing `knowledge.chat` (`/inspector-panel`).
struct KnowledgeChatInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let controller: KnowledgeShellController

    @State private var createdChatId: String?
    @State private var creating = false
    @State private var createError: String?
    @State private var attachError: String?
    @State private var preferredPersonaId: String? = UserDefaults.standard.string(forKey: "vesper.dockPersona.app:knowledge")
    @State private var watchedKeys: [QueryKey] = []

    private static let appScope = "app:knowledge"
    private static let appDockRequest = DockChatsAPI.list(scope: appScope)

    private var pageId: String? {
        if case .page(let id) = controller.activeDestination { return id }
        return nil
    }

    private var loadedPage: KnowledgePage? {
        guard let pageId else { return nil }
        return context.store.entry(KnowledgeAPI.getPage(id: pageId)).data
    }

    private var screenLabel: String {
        KnowledgeInspectorLogic.screenLabel(for: controller.activeDestination)
    }

    private var pageDockRequest: APIRequest<DockChatsAPI.ListResponse>? {
        pageId.map { DockChatsAPI.list(scope: "page:\($0)") }
    }

    var body: some View {
        let p = theme.palette
        let page = loadedPage
        let linkedId = pageId != nil ? page?.chatId : controller.generalChatId
        let candidateId = createdChatId ?? linkedId
        let rememberedEntry = candidateId.map { context.store.entry(API.getChat(id: $0)) }
        let isGone: Bool = {
            if case .http(let status, _) = rememberedEntry?.error as? APIError { return status == 404 }
            return false
        }()
        let activeChatId = isGone ? nil : candidateId
        let activeChat = isGone ? nil : rememberedEntry?.data
        let prefill = controller.chatPrefill.flatMap { $0.pageId == pageId && page != nil ? $0.prefill : nil }
        // A drafted prompt needs a chat to land in: start one when the page has none.
        let prefillNeedsChat = prefill != nil && activeChatId == nil

        let pageChats = pageDockRequest.flatMap { context.store.entry($0).data?.chats } ?? []
        let appChats = context.store.entry(Self.appDockRequest).data?.chats ?? []
        let sections: [DockedChatSection] = {
            if page != nil {
                let pageIds = Set(pageChats.map(\.id))
                return [
                    DockedChatSection(label: "This page", chats: pageChats),
                    DockedChatSection(label: "Elsewhere in Knowledge", chats: appChats.filter { !pageIds.contains($0.id) }),
                ]
            }
            return [DockedChatSection(label: "Knowledge", chats: appChats)]
        }()

        let welcome = WorkCompanionLogic.knowledgeWelcome(pageTitle: page?.title, screen: page == nil ? screenLabel : nil)
        let emptyDesc = page != nil
            ? "Talk to a persona about this page. It can read it, link it and edit it with you."
            : "Talk to a persona about your notes. It can search, link and write pages with you."

        VStack(spacing: 0) {
            if let attachError, let activeChatId, let page {
                HStack(spacing: 8) {
                    Text(attachError)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    Spacer()
                    Button("Retry") {
                        attachChat(activeChatId, to: page.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }

            if pageId != nil && page == nil {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading page\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DockedChatView(
                    chatId: activeChatId,
                    sections: sections,
                    newChatLabel: page != nil ? "New chat about this page" : "New chat",
                    creating: creating,
                    createError: createError,
                    emptyDescription: emptyDesc,
                    emptyButtonTitle: page != nil ? "Start a chat about this page" : "Start a chat",
                    welcomeWhere: welcome.whereText,
                    welcomeIntro: welcome.intro,
                    starters: welcome.starters,
                    onSelectChat: { nextId in
                        selectChat(nextId, page: page)
                    },
                    onNewChat: {
                        startNewChat(page: page)
                    },
                    onOpenFullChat: { id in
                        context.navigate("/chat/\(id)")
                    },
                    prepareBody: { body in
                        WorkCompanionLogic.knowledgeContextBody(
                            body,
                            pagePath: page?.path,
                            pageTitle: page?.title,
                            screen: page == nil ? screenLabel : nil
                        )
                    },
                    prepareContextRefs: { existing in
                        var refs = existing ?? []
                        if let page, !refs.contains(where: { $0.kind == .page && $0.id == page.id }) {
                            refs.append(API.ChatContextRef(id: page.id, kind: .page))
                        }
                        return refs.isEmpty ? nil : refs
                    },
                    onTurnCompleted: {
                        // Persona turns may create, move, or suggest edits to pages.
                        Task { _ = await context.store.refetch(controller.treeListRequest) }
                    },
                    composerPrefill: prefill,
                    onComposerPrefillApplied: { token in
                        controller.consumeChatPrefill(token: token)
                    }
                ) {
                    HStack(spacing: 6) {
                        if let page {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
                                    .foregroundStyle(p.tertiaryText)
                                Text("Viewing: \(page.title)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.secondaryText)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(p.surface, in: Capsule())
                            .overlay(Capsule().stroke(p.border))
                        } else {
                            HStack(spacing: 4) {
                                Text("On: \(screenLabel)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.secondaryText)
                                    .lineLimit(1)
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
        }
        .task(id: pageId ?? "general") {
            createdChatId = nil
            attachError = nil
            syncWatches()
        }
        .onChange(of: prefillNeedsChat, initial: true) { _, needsChat in
            if needsChat, let page { startNewChat(page: page) }
        }
        .onChange(of: activeChat?.persona?.id) { _, nextPersonaId in
            if let nextPersonaId {
                preferredPersonaId = nextPersonaId
                UserDefaults.standard.set(nextPersonaId, forKey: "vesper.dockPersona.app:knowledge")
            }
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    private func syncWatches() {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        watch(Self.appDockRequest)
        if let req = pageDockRequest { watch(req) }
        if let pageId { watch(KnowledgeAPI.getPage(id: pageId)) }
    }

    private func selectChat(_ nextId: String, page: KnowledgePage?) {
        createdChatId = nextId
        attachError = nil
        if let page {
            attachChat(nextId, to: page.id)
        } else {
            controller.generalChatId = nextId
            Task {
                _ = try? await context.store.mutate(DockChatsAPI.add(scope: Self.appScope, chatId: nextId))
                _ = await context.store.refetch(Self.appDockRequest)
            }
        }
    }

    private func attachChat(_ chatId: String, to pageId: String) {
        Task {
            do {
                let updated = try await context.store.mutate(
                    KnowledgeAPI.attachChat(id: pageId, chatId: chatId),
                    invalidating: QueryInvalidation(resources: ["knowledge"])
                )
                context.store.setData(updated, for: KnowledgeAPI.getPage(id: pageId))
                if let req = pageDockRequest { _ = await context.store.refetch(req) }
                attachError = nil
            } catch {
                attachError = "Couldn\u{2019}t link this chat to the page."
            }
        }
    }

    private func startNewChat(page: KnowledgePage?) {
        guard !creating else { return }
        creating = true
        createError = nil
        Task {
            defer { creating = false }
            do {
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        hidden: true,
                        personaId: preferredPersonaId,
                        title: page?.title ?? "Knowledge"
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                selectChat(created.id, page: page)
            } catch {
                createError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
