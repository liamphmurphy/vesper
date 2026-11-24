import SwiftUI
import VesperCore

/// Native SwiftUI inspector panel host for `.panel` tabs that have moved off `/inspector-panel`.
enum NativeInspectorPanelRouter {
    static let nativeKinds: Set<String> = [
        "editor.chat",
        "designs.chat",
        "customApp.chat",
    ]

    static func isNative(_ spec: InspectorPanelSpec?) -> Bool {
        guard let kind = spec?.kind else { return false }
        return nativeKinds.contains(kind)
    }

    static func parseProps(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

struct NativeInspectorPanelHost: View {
    let tabs: TabsModel
    let screenContext: NativeScreenContext
    let onPanelEvent: (String, String, String?) -> Void

    var body: some View {
        let state = tabs.list.active?.state
        let theme = state?.theme ?? ThemeTokens(mode: state?.pageMode ?? .light)
        let colorScheme: ColorScheme = (state?.pageMode ?? theme.mode) == .dark ? .dark : .light
        let activeTab = InspectorLogic.activeTab(in: state?.inspector)

        Group {
            if activeTab?.kind == .panel, let spec = activeTab?.panel, NativeInspectorPanelRouter.isNative(spec) {
                let props = NativeInspectorPanelRouter.parseProps(spec.propsJson)
                let tabId = (props["tabId"] as? String) ?? activeTab?.id ?? ""
                switch spec.kind {
                case "editor.chat":
                    if let chatId = props["chatId"] as? String, !chatId.isEmpty {
                        EditorChatPanelView(chatId: chatId)
                            .id(spec.key)
                    }
                case "designs.chat":
                    if let chatId = props["chatId"] as? String, !chatId.isEmpty,
                       let designId = props["designId"] as? String, !designId.isEmpty {
                        DesignsChatPanelView(
                            chatId: chatId,
                            designId: designId,
                            persona: (props["persona"] as? String) ?? "Assistant",
                            pageId: props["pageId"] as? String,
                            selected: (props["selected"] as? [String]) ?? [],
                            viewport: props["viewport"] as? [String: Any]
                        )
                        .id(spec.key)
                    }
                case "customApp.chat":
                    if let slug = props["slug"] as? String, !slug.isEmpty {
                        CustomAppChatPanelView(
                            tabId: tabId,
                            slug: slug,
                            activeNav: props["activeNav"] as? String,
                            runtimeError: props["runtimeError"] as? String,
                            initialChatId: props["chatId"] as? String,
                            onPanelEvent: onPanelEvent
                        )
                        .id(spec.key)
                    }
                default:
                    EmptyView()
                }
            } else {
                EmptyView()
            }
        }
        .environment(screenContext)
        .environment(\.vesperTheme, theme)
        .environment(\.colorScheme, colorScheme)
        .vesperTrackHostVisibility()
    }
}

// MARK: - editor.chat (Docs & Slides)

private struct EditorChatPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    let chatId: String

    var body: some View {
        DockedChatView(
            chatId: chatId,
            sections: [],
            newChatLabel: "New chat",
            creating: false,
            createError: nil,
            emptyDescription: "Ask a persona to review or edit this document.",
            emptyButtonTitle: "Start a chat",
            welcomeWhere: "Document chat",
            welcomeIntro: "Ask for edits, suggestions, or a review.",
            starters: [],
            onSelectChat: { _ in },
            onNewChat: { context.navigate("/knowledge") },
            onOpenFullChat: { id in context.navigate("/chat/\(id)") },
            prepareBody: { $0 },
            prepareContextRefs: { $0 },
            onTurnCompleted: nil
        ) {
            EmptyView()
        }
    }
}

// MARK: - designs.chat (Designs editor)

private struct DesignsChatPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let designId: String
    let persona: String
    let pageId: String?
    let selected: [String]
    let viewport: [String: Any]?

    @State private var updatingSettings = false

    private var designRequest: APIRequest<API.Design> {
        API.getDesign(canvasId: designId)
    }

    var body: some View {
        let p = theme.palette
        let design = context.store.entry(designRequest).data
        let direct = design?.settings.directEdit ?? false

        DockedChatView(
            chatId: chatId,
            sections: [],
            newChatLabel: "New chat",
            creating: false,
            createError: nil,
            emptyDescription: "Ask \(persona) to iterate on this design.",
            emptyButtonTitle: "Start a chat",
            welcomeWhere: "Design chat",
            welcomeIntro: "Select nodes on the canvas or describe what to change.",
            starters: [],
            onSelectChat: { _ in },
            onNewChat: { context.navigate("/knowledge") },
            onOpenFullChat: { id in context.navigate("/chat/\(id)") },
            prepareBody: { $0 },
            prepareContextRefs: { existing in
                var refs = existing ?? []
                if let pageId, !pageId.isEmpty {
                    let vp = API.ChatDesignSelection.Viewport(
                        h: (viewport?["h"] as? Double) ?? 800,
                        w: (viewport?["w"] as? Double) ?? 1200,
                        x: (viewport?["x"] as? Double) ?? 0,
                        y: (viewport?["y"] as? Double) ?? 0,
                        zoom: (viewport?["zoom"] as? Double) ?? 1
                    )
                    let sel = API.ChatDesignSelection(
                        nodes: Array(selected.prefix(100)),
                        page: pageId,
                        viewport: vp
                    )
                    refs.append(API.ChatContextRef(id: designId, kind: .canvas, selection: sel))
                }
                return refs.isEmpty ? nil : refs
            },
            onTurnCompleted: nil
        ) {
            HStack(spacing: 6) {
                Menu {
                    Button {
                        setDirectEdit(false)
                    } label: {
                        Label("Suggests changes", systemImage: direct ? "" : "checkmark")
                    }
                    Button {
                        setDirectEdit(true)
                    } label: {
                        Label("Edits directly", systemImage: direct ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(direct ? "Direct" : "Suggests")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(p.surface, in: Capsule())
                    .overlay(Capsule().stroke(p.border, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(design == nil || updatingSettings)
                .help("Suggests: \(persona)'s edits wait as suggestions you review. Direct: edits apply at once.")

                if !selected.isEmpty {
                    Text("\(selected.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .task(id: designId) {
            context.store.observe(designRequest)
            context.store.load(designRequest)
        }
        .onDisappear {
            context.store.stopObserving(designRequest.key)
        }
    }

    private func setDirectEdit(_ value: Bool) {
        guard !updatingSettings else { return }
        updatingSettings = true
        Task {
            defer { updatingSettings = false }
            let req = API.updateDesignSettings(canvasId: designId, body: API.UpdateDesignSettingsBody(directEdit: value))
            _ = try? await context.store.mutate(req)
            _ = await context.store.refetch(designRequest)
        }
    }
}

// MARK: - customApp.chat (Custom Apps)

private struct CustomAppChatPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let tabId: String
    let slug: String
    let activeNav: String?
    let runtimeError: String?
    let initialChatId: String?
    let onPanelEvent: (String, String, String?) -> Void

    @State private var selectedChatId: String?
    @State private var creating = false
    @State private var createError: String?

    private var appRequest: APIRequest<API.CustomAppDetail> {
        API.getCustomApp(slug: slug)
    }

    private var effectiveChatId: String? {
        selectedChatId ?? initialChatId
    }

    private func dockListRequest(slug: String) -> APIRequest<DockChatsAPI.ListResponse> {
        DockChatsAPI.list(scope: "app:custom:\(slug)")
    }

    var body: some View {
        let p = theme.palette
        let app = context.store.entry(appRequest).data
        let chats = context.store.entry(dockListRequest(slug: slug)).data?.chats ?? []
        let activeId = effectiveChatId ?? chats.first?.id

        DockedChatView(
            chatId: activeId,
            sections: chats.isEmpty ? [] : [DockedChatSection(label: "App chats", chats: chats)],
            newChatLabel: "New chat",
            creating: creating,
            createError: createError,
            emptyDescription: "Ask a persona to build or iterate on this Custom App.",
            emptyButtonTitle: "Start a chat",
            welcomeWhere: app?.name ?? slug,
            welcomeIntro: "Describe features, UI tweaks, or bug fixes for this app.",
            starters: [],
            onSelectChat: { nextId in
                selectedChatId = nextId
                notifySelectChat(nextId)
            },
            onNewChat: {
                if let app { startNewChat(for: app) }
            },
            onOpenFullChat: { id in
                context.navigate("/chat/\(id)")
            },
            prepareBody: { body in
                guard let app else { return body }
                return Self.withCustomAppContext(
                    body,
                    slug: app.slug,
                    name: app.name,
                    seq: app.currentSeq,
                    activeNav: activeNav,
                    error: runtimeError
                )
            },
            prepareContextRefs: { $0 },
            onTurnCompleted: nil
        ) {
            if let app {
                HStack(spacing: 5) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(p.tertiaryText)
                    Text("Viewing: \(app.name) · v\(app.currentSeq)")
                        .font(.system(size: 11))
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: slug) {
            context.store.observe(appRequest)
            context.store.load(appRequest)
            let req = dockListRequest(slug: slug)
            context.store.observe(req)
            context.store.load(req)
        }
        .onDisappear {
            context.store.stopObserving(appRequest.key)
            context.store.stopObserving(dockListRequest(slug: slug).key)
        }
    }

    private func notifySelectChat(_ chatId: String) {
        if let data = try? JSONSerialization.data(withJSONObject: ["chatId": chatId]),
           let json = String(data: data, encoding: .utf8) {
            onPanelEvent(tabId, "selectChat", json)
        }
    }

    private func startNewChat(for app: API.CustomAppDetail) {
        guard !creating else { return }
        creating = true
        createError = nil
        Task {
            defer { creating = false }
            do {
                let personas = context.store.entry(API.listPersonas()).data?.personas ?? []
                let personaId = personas.first(where: { $0.isDefault })?.id ?? personas.first?.id
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        hidden: true,
                        personaId: personaId,
                        title: app.name
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                let scope = "app:custom:\(app.slug)"
                _ = try? await context.store.mutate(DockChatsAPI.add(scope: scope, chatId: created.id))
                selectedChatId = created.id
                notifySelectChat(created.id)
                _ = await context.store.refetch(dockListRequest(slug: app.slug))
            } catch {
                createError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private static func withCustomAppContext(
        _ body: String,
        slug: String,
        name: String,
        seq: Int,
        activeNav: String?,
        error: String?
    ) -> String {
        var parts = ["Viewing Custom App \"\(name)\" (/apps/\(slug), version v\(seq))."]
        if let activeNav, !activeNav.isEmpty {
            parts.append("Active nav view: \(activeNav).")
        }
        if let error, !error.isEmpty {
            parts.append("Latest runtime error in sandbox: \(error)")
        }
        let suffix = "\n\n<!-- vesper:custom-app-context -->\n" + parts.joined(separator: "\n")
        return body.hasSuffix(suffix) ? body : body + suffix
    }
}
