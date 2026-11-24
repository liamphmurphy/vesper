import AppKit
import SwiftUI
import VesperCore
import WebKit

/// Native SwiftUI inspector panel host for all `.panel` tabs (zero web `/inspector-panel` dependency).
enum NativeInspectorPanelRouter {
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
    let onOpenPlayground: (URL) -> Void
    let onPanelEvent: (String, String, String?) -> Void

    var body: some View {
        let state = tabs.list.active?.state
        let theme = state?.theme ?? ThemeTokens(mode: state?.pageMode ?? .light)
        let colorScheme: ColorScheme = (state?.pageMode ?? theme.mode) == .dark ? .dark : .light
        let activeTab = InspectorLogic.activeTab(in: state?.inspector)

        Group {
            if activeTab?.kind == .panel, let spec = activeTab?.panel {
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
                case "customApp.code":
                    if let slug = props["slug"] as? String, !slug.isEmpty {
                        CustomAppCodePanelView(slug: slug)
                            .id(spec.key)
                    }
                case "slides.review":
                    if let chatId = props["chatId"] as? String, !chatId.isEmpty,
                       let docId = props["docId"] as? String, !docId.isEmpty {
                        SlidesReviewPanelView(
                            tabId: tabId,
                            chatId: chatId,
                            docId: docId,
                            baseSeq: (props["baseSeq"] as? Int) ?? 0,
                            headSeq: (props["headSeq"] as? Int) ?? 0,
                            persona: (props["persona"] as? String) ?? "Assistant",
                            archived: (props["archived"] as? Bool) ?? false,
                            onPanelEvent: onPanelEvent
                        )
                        .id(spec.key)
                    }
                case "chat.design":
                    if let designId = props["designId"] as? String, !designId.isEmpty {
                        let reviewing = (props["reviewing"] as? Bool) ?? false
                        let path = reviewing ? "/apps/designs/\(designId)?review=1" : "/apps/designs/\(designId)"
                        HostedWebPageView(path: path)
                            .id(path)
                    }
                case "chat.canvas":
                    if let chatId = props["chatId"] as? String, !chatId.isEmpty {
                        ChatCanvasPanelView(
                            chatId: chatId,
                            canvasId: props["canvasId"] as? String
                        )
                        .id(spec.key)
                    }
                case "chat.playground":
                    if let chatId = props["chatId"] as? String, !chatId.isEmpty {
                        ChatPlaygroundPanelView(
                            chatId: chatId,
                            onOpenPlayground: onOpenPlayground
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


// MARK: - customApp.code

private struct CustomAppCodePanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let slug: String
    @State private var selectedFile: String?

    private var appRequest: APIRequest<API.CustomAppDetail> {
        API.getCustomApp(slug: slug)
    }

    var body: some View {
        let p = theme.palette
        let entry = context.store.entry(appRequest)
        let app = entry.data
        let files = app?.current.files ?? [:]
        let sortedKeys = files.keys.sorted()
        let activeFile = selectedFile.flatMap { files[$0] != nil ? $0 : nil } ?? sortedKeys.first

        VStack(spacing: 0) {
            if let app {
                HStack(spacing: 8) {
                    if !sortedKeys.isEmpty {
                        Picker("File", selection: Binding(
                            get: { activeFile ?? "" },
                            set: { selectedFile = $0 }
                        )) {
                            ForEach(sortedKeys, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                    Text("v\(app.currentSeq)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                    Spacer(minLength: 0)
                    if let activeFile, let content = files[activeFile] {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(content, forType: .string)
                        }
                        .buttonStyle(.vesper())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider().overlay(p.border)

                if let activeFile, let content = files[activeFile] {
                    ScrollView([.vertical, .horizontal]) {
                        Text(content)
                            .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                            .foregroundStyle(p.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else {
                    Text("No source files in this version.")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if entry.error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Couldn't load custom app code.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: slug) {
            context.store.observe(appRequest)
            context.store.load(appRequest)
        }
        .onDisappear {
            context.store.stopObserving(appRequest.key)
        }
    }
}

// MARK: - slides.review

private struct SlidesReviewPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let tabId: String
    let chatId: String
    let docId: String
    let baseSeq: Int
    let headSeq: Int
    let persona: String
    let archived: Bool
    let onPanelEvent: (String, String, String?) -> Void

    @State private var busy = false
    @State private var errorMessage: String?

    private var headRequest: APIRequest<API.ChatCanvas> {
        API.getChatCanvas(id: chatId, canvasId: docId)
    }

    private var baseRequest: APIRequest<API.ChatCanvas> {
        API.getChatCanvas(id: chatId, canvasId: docId, seq: baseSeq)
    }

    var body: some View {
        let p = theme.palette
        let head = context.store.entry(headRequest).data
        let base = context.store.entry(baseRequest).data

        VStack(alignment: .leading, spacing: 12) {
            Text("Deck changes")
                .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                .foregroundStyle(p.text)

            Text("\(persona) updated this deck from v\(baseSeq) to v\(head?.seq ?? headSeq).")
                .font(.system(size: theme.pointSize(.body)))
                .foregroundStyle(p.secondaryText)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(Color.red)
            }

            HStack(spacing: 8) {
                Button("Accept changes") {
                    guard let head else { return }
                    acceptAll(seq: head.seq)
                }
                .buttonStyle(.vesper(.primary))
                .disabled(archived || busy || head == nil)

                Button("Revert to v\(baseSeq)") {
                    guard let head, let base else { return }
                    revert(headSeq: head.seq, baseBody: base.body)
                }
                .buttonStyle(.vesper(.outline))
                .disabled(archived || busy || head == nil || base == nil)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(chatId):\(docId):\(baseSeq)") {
            context.store.observe(headRequest)
            context.store.load(headRequest)
            context.store.load(baseRequest)
        }
        .onDisappear {
            context.store.stopObserving(headRequest.key)
        }
    }

    private func acceptAll(seq: Int) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                _ = try await context.store.mutate(
                    API.markDocReviewed(canvasId: docId, body: API.MarkDocReviewedBody(seq: seq))
                )
                onPanelEvent(tabId, "reviewed", nil)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func revert(headSeq: Int, baseBody: String) {
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                let saved = try await context.store.mutate(
                    API.saveChatCanvas(
                        id: chatId,
                        canvasId: docId,
                        body: API.ChatCanvasSave(baseSeq: headSeq, body: baseBody, note: "Reverted changes")
                    )
                )
                _ = try await context.store.mutate(
                    API.markDocReviewed(canvasId: docId, body: API.MarkDocReviewedBody(seq: saved.seq))
                )
                onPanelEvent(tabId, "reviewed", nil)
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

// MARK: - chat.canvas

private struct ChatCanvasPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let canvasId: String?

    private var listRequest: APIRequest<API.ChatCanvases> {
        API.listChatCanvases(id: chatId)
    }

    var body: some View {
        let canvases = context.store.entry(listRequest).data?.canvases ?? []
        let resolvedId = canvasId ?? canvases.first?.id

        Group {
            if let resolvedId {
                ChatCanvasDetailPanelView(chatId: chatId, canvasId: resolvedId)
                    .id(resolvedId)
            } else {
                Text("No canvas in this chat yet.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: chatId) {
            if canvasId == nil {
                context.store.observe(listRequest)
                context.store.load(listRequest)
            }
        }
        .onDisappear {
            if canvasId == nil {
                context.store.stopObserving(listRequest.key)
            }
        }
    }
}

private struct ChatCanvasDetailPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let canvasId: String

    private var canvasRequest: APIRequest<API.ChatCanvas> {
        API.getChatCanvas(id: chatId, canvasId: canvasId)
    }

    var body: some View {
        let p = theme.palette
        let entry = context.store.entry(canvasRequest)
        let canvas = entry.data

        Group {
            if let canvas {
                switch canvas.kind {
                case .deck:
                    HostedWebPageView(path: "/apps/slides/\(canvas.id)")
                        .id(canvas.id)
                case .design:
                    HostedWebPageView(path: "/apps/designs/\(canvas.id)")
                        .id(canvas.id)
                default:
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Text(canvas.title)
                                .font(.system(size: theme.pointSize(.body), weight: .medium))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            Text("v\(canvas.seq)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                            Spacer(minLength: 0)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(canvas.body, forType: .string)
                            }
                            .buttonStyle(.vesper())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider().overlay(p.border)

                        ScrollView {
                            MarkdownView(markdown: canvas.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }
            } else if entry.error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Couldn't load canvas.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(chatId):\(canvasId)") {
            context.store.observe(canvasRequest)
            context.store.load(canvasRequest)
        }
        .onDisappear {
            context.store.stopObserving(canvasRequest.key)
        }
    }
}

// MARK: - chat.playground

private struct ChatPlaygroundPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let onOpenPlayground: (URL) -> Void

    @State private var tab: PlaygroundPanelTab = .preview
    @State private var acting = false
    @State private var reloadToken = 0

    enum PlaygroundPanelTab: String, CaseIterable {
        case preview = "Preview"
        case logs = "Logs"
    }

    private var stateRequest: APIRequest<API.ChatPlaygroundState> {
        API.getChatPlayground(id: chatId)
    }

    var body: some View {
        let p = theme.palette
        let state = context.store.entry(stateRequest).data
        let pg = state?.playground
        let port = pg?.port?.value
        let previewURL: URL? = port.flatMap { URL(string: "http://127.0.0.1:\($0)/") }

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(PlaygroundPanelTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                if let pg {
                    Text(pg.state.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(pg.state == .running ? p.accent : p.secondaryText)
                }

                Spacer(minLength: 0)

                if let previewURL {
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.vesper())
                    .help("Reload preview")

                    Button {
                        onOpenPlayground(previewURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.vesper())
                    .help("Open in tab")
                }

                if let pg, pg.state == .running || pg.state == .starting {
                    Button("Stop") {
                        runAction(.stop)
                    }
                    .buttonStyle(.vesper())
                    .disabled(acting)
                } else if pg != nil || state?.savedSpec == true {
                    Button("Restart") {
                        runAction(API.ChatPlaygroundActionAction(rawValue: "restart"))
                    }
                    .buttonStyle(.vesper())
                    .disabled(acting)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(p.border)

            if tab == .preview {
                if let previewURL, pg?.state == .running {
                    PlaygroundPreviewWebView(url: previewURL, reloadToken: reloadToken)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        if pg?.state == .starting {
                            ProgressView()
                            Text(pg?.step.isEmpty == false ? pg!.step : "Starting playground…")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.secondaryText)
                        } else if let err = pg?.error?.value, !err.isEmpty {
                            Text(err)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(Color.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        } else {
                            Text("Playground is not running.")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.tertiaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    Text(pg?.errorLog.isEmpty == false ? pg!.errorLog : "No playground logs yet.")
                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                        .foregroundStyle(p.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .task(id: chatId) {
            context.store.observe(stateRequest)
            context.store.load(stateRequest)
        }
        .onDisappear {
            context.store.stopObserving(stateRequest.key)
        }
    }

    private func runAction(_ action: API.ChatPlaygroundActionAction) {
        acting = true
        Task {
            defer { acting = false }
            _ = try? await context.store.mutate(API.chatPlaygroundAction(id: chatId, action: action))
            _ = await context.store.refetch(stateRequest)
        }
    }
}

private struct PlaygroundPreviewWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    final class Coordinator {
        var lastURL: URL?
        var lastReloadToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WebViewFactory.makeWebView(kind: .playground, bridge: nil)
        context.coordinator.lastURL = url
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastURL != url || context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastURL = url
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
        }
    }
}
