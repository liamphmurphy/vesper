import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore
import WebKit

// MARK: - Full-Page Custom App Screen (/apps/:slug)

struct CustomAppScreen: View {
    @Environment(NativeScreenContext.self) private var context

    var overrideSlug: String? = nil
    var standalone: Bool = false
    var reloadNonce: Int = 0
    var onOpenInWorkbench: (() -> Void)? = nil

    private var slug: String {
        overrideSlug ?? context.match.params["slug"] ?? ""
    }

    private var isStandalone: Bool {
        standalone || context.match.query["standalone"] == "1"
    }

    var body: some View {
        CustomAppRuntimeView(
            slug: slug,
            standalone: isStandalone,
            externalReloadNonce: reloadNonce,
            onOpenInWorkbench: onOpenInWorkbench
        )
        .id("\(slug):\(isStandalone)")
    }
}

// MARK: - Custom App Runtime Host

@MainActor
struct CustomAppRuntimeView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let slug: String
    let standalone: Bool
    var externalReloadNonce: Int = 0
    var onOpenInWorkbench: (() -> Void)? = nil

    @State private var reloadKey = 0
    @State private var runtimeErrorState: (seq: Int, reload: Int, message: String)?
    @State private var dynamicNavState: (seq: Int, items: [CustomAppBridgeLogic.NavSpec])?
    @State private var activeNav: String?
    @State private var pendingApprovals: [PendingApproval] = []
    @State private var decidingApproval = false
    @State private var activeHlsStreamId: String?
    @State private var activeLocalRelayId: String?
    @State private var hlsRequestSeq = 0
    @State private var selectedInspectorTab = "chat"
    @State private var inspectorOpen = true
    @State private var selectedChatId: String?

    @State private var hostController = CustomAppWebHostController()

    private var appRequest: APIRequest<API.CustomAppDetail> {
        API.getCustomApp(slug: slug)
    }

    private var appEntry: QueryEntry<API.CustomAppDetail> {
        context.store.entry(appRequest)
    }

    private var app: API.CustomAppDetail? {
        appEntry.data
    }

    private var navItems: [CustomAppBridgeLogic.NavSpec] {
        guard let app else { return [] }
        if let dyn = dynamicNavState, dyn.seq == app.currentSeq {
            return dyn.items
        }
        return (app.manifest.nav ?? []).map {
            CustomAppBridgeLogic.NavSpec(id: $0.id, label: $0.label, icon: $0.icon)
        }
    }

    private var currentNav: String? {
        let items = navItems
        if let activeNav, items.contains(where: { $0.id == activeNav }) {
            return activeNav
        }
        return items.first?.id
    }

    private var runtimeError: String? {
        guard let app, let err = runtimeErrorState,
              err.seq == app.currentSeq, err.reload == reloadKey else { return nil }
        return err.message
    }

    private var headApproval: PendingApproval? {
        guard let app else { return nil }
        return pendingApprovals.first { $0.seq == app.currentSeq && $0.reload == reloadKey }
    }

    var body: some View {
        let p = theme.palette
        Group {
            if let error = appEntry.error {
                if isNotFoundError(error) {
                    notFoundView(p: p)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.orange)
                        Text("Couldn\u{2019}t load custom app")
                            .vesperText(.heading, theme)
                        Text(error.userMessage)
                            .vesperText(.body, theme)
                            .foregroundStyle(p.secondaryText)
                        Button("Retry") { context.store.load(appRequest) }
                            .buttonStyle(.vesper(.primary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }
            } else if let app {
                mainAppContent(app: app, p: p)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(slug)…")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .task(id: slug) {
            context.store.observe(appRequest)
            context.store.load(appRequest)
            if !standalone {
                let dockReq = DockChatsAPI.list(scope: "app:custom:\(slug)")
                context.store.observe(dockReq)
                context.store.load(dockReq)
            }
        }
        .onDisappear {
            stopActiveMediaRelays()
            hostController.teardown()
            context.store.stopObserving(appRequest.key)
            if !standalone {
                context.store.stopObserving(DockChatsAPI.list(scope: "app:custom:\(slug)").key)
                context.sidebarView = nil
                context.inspectorView = nil
            }
        }
        .onChange(of: externalReloadNonce) { _, _ in
            reloadApp()
        }
        .onChange(of: theme) { _, nextTheme in
            hostController.sendTheme(CustomAppBridgeLogic.themeVars(from: nextTheme))
        }
        .onChange(of: app?.currentSeq) { _, _ in
            syncWorkbenchChrome()
        }
        .onChange(of: navItems) { _, _ in
            syncWorkbenchChrome()
        }
        .onChange(of: currentNav) { _, _ in
            syncWorkbenchChrome()
        }
        .onChange(of: runtimeError) { _, _ in
            syncWorkbenchChrome()
        }
        .onChange(of: selectedInspectorTab) { _, _ in
            syncWorkbenchChrome()
        }
        .onChange(of: inspectorOpen) { _, _ in
            syncWorkbenchChrome()
        }
        .onAppear {
            syncWorkbenchChrome()
        }
    }

    private func isNotFoundError(_ error: Error) -> Bool {
        if case APIError.http(status: 404, _) = error { return true }
        return false
    }

    @ViewBuilder
    private func notFoundView(p: NativePalette) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 30))
                .foregroundStyle(p.tertiaryText)
            Text("Custom app not found")
                .vesperText(.heading, theme)
            Text("No custom app exists at /apps/\(slug). Create it from Custom Apps or ask a persona to build it.")
                .vesperText(.body, theme)
                .foregroundStyle(p.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(standalone ? "Open Vesper Custom Apps" : "Back to Custom Apps") {
                if standalone {
                    onOpenInWorkbench?()
                } else {
                    context.navigate("/apps")
                }
            }
            .buttonStyle(.vesper(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func mainAppContent(app: API.CustomAppDetail, p: NativePalette) -> some View {
        VStack(spacing: 0) {
            if standalone && navItems.count > 1 {
                standaloneNavBar(items: navItems, p: p)
                Divider().overlay(p.border)
            }

            if let approval = headApproval {
                approvalBanner(approval: approval, app: app, p: p)
                Divider().overlay(p.border)
            }

            if let err = runtimeError {
                runtimeErrorBanner(error: err, app: app, p: p)
                Divider().overlay(p.border)
            }

            CustomAppWebHostRepresentable(
                controller: hostController,
                slug: app.slug,
                name: app.name,
                seq: app.currentSeq,
                reloadKey: reloadKey,
                bundleJS: app.current.bundleJs,
                bundleCSS: app.current.bundleCss,
                themeVars: CustomAppBridgeLogic.themeVars(from: theme),
                baseURL: context.baseURL() ?? URL(string: "http://127.0.0.1:8000")!,
                onMessage: { msg in
                    handleBridgeMessage(msg, app: app)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func standaloneNavBar(items: [CustomAppBridgeLogic.NavSpec], p: NativePalette) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    let active = item.id == currentNav
                    Button {
                        selectNav(item.id)
                    } label: {
                        HStack(spacing: 5) {
                            if let icon = item.icon, !icon.isEmpty {
                                Image(systemName: sfSymbolForAppIcon(icon))
                                    .font(.system(size: 11))
                            }
                            Text(item.label)
                                .font(.system(size: 12, weight: active ? .semibold : .regular))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(active ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(active ? p.text : p.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(p.surface)
    }

    @ViewBuilder
    private func approvalBanner(approval: PendingApproval, app: API.CustomAppDetail, p: NativePalette) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 14))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permission needed · \(approval.capability)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.text)
                Text(approval.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Approve once") {
                Task { await decideApproval(.once, approval: approval, app: app) }
            }
            .buttonStyle(.vesper(.primary))
            .keyboardShortcut("a", modifiers: [.option])
            .disabled(decidingApproval)

            Button("Always allow") {
                Task { await decideApproval(.always, approval: approval, app: app) }
            }
            .buttonStyle(.vesper(.outline))
            .disabled(decidingApproval)

            Button("Decline") {
                Task { await decideApproval(.decline, approval: approval, app: app) }
            }
            .buttonStyle(.vesper(.outline))
            .keyboardShortcut("d", modifiers: [.option])
            .disabled(decidingApproval)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(p.surface)
    }

    @ViewBuilder
    private func runtimeErrorBanner(error: String, app: API.CustomAppDetail, p: NativePalette) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Runtime error in sandbox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.text)
                Text(error)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Button(standalone ? "Open in Vesper to fix" : "Ask persona to fix") {
                if standalone {
                    onOpenInWorkbench?()
                } else {
                    Task {
                        await askDock(
                            prompt: "Please fix this runtime error in custom app \"\(app.name)\" (/apps/\(app.slug)):\n\n\(error)",
                            app: app
                        )
                    }
                }
            }
            .buttonStyle(.vesper(.outline))

            Button("Dismiss") {
                runtimeErrorState = nil
            }
            .buttonStyle(.vesper(.outline))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(p.surface)
    }

    // MARK: - Chrome & Inspector Wiring (Workbench Mode)

    private func syncWorkbenchChrome() {
        guard !standalone, let app else { return }

        var chatProps: [String: Any] = ["tabId": "chat", "slug": app.slug]
        if let currentNav { chatProps["activeNav"] = currentNav }
        if let runtimeError { chatProps["runtimeError"] = runtimeError }
        if let selectedChatId { chatProps["chatId"] = selectedChatId }
        let chatPropsJSON = encodeJSON(chatProps)
        let codePropsJSON = encodeJSON(["tabId": "code", "slug": app.slug])

        let pendingCount = CustomAppStandaloneLogic.buildPermissions(from: app).pendingRequestCount

        let tabs: [InspectorTab] = [
            InspectorTab(
                id: "chat",
                label: "Chat",
                icon: "msg",
                kind: .panel,
                panel: InspectorPanelSpec(kind: "customApp.chat", key: "customApp.chat:\(app.slug)", propsJson: chatPropsJSON)
            ),
            InspectorTab(
                id: "code",
                label: "Code",
                icon: "code",
                kind: .panel,
                width: .wide,
                panel: InspectorPanelSpec(kind: "customApp.code", key: "customApp.code:\(app.slug)", propsJson: codePropsJSON)
            ),
            InspectorTab(
                id: "permissions",
                label: "Permissions",
                icon: "shield",
                kind: .native,
                badge: pendingCount > 0 ? NavBadge(text: "\(pendingCount)") : nil
            ),
        ]

        let actions: [ShellToolbarItem] = [
            ShellToolbarItem(id: "reload", label: "Reload", icon: "refresh", kind: .button),
            ShellToolbarItem(id: "permissions", label: "Permissions", icon: "shield", kind: .button),
            ShellToolbarItem(id: "standalone", label: "Open Window", icon: "arrow-up-right", kind: .button),
        ]

        var chrome = NativeChrome()
        chrome.title = app.name
        chrome.subtitle = "v\(app.currentSeq)"
        chrome.toolbarItems = actions
        chrome.inspector = InspectorModel(
            id: "customApp:\(app.slug)",
            open: inspectorOpen,
            activeTabId: selectedInspectorTab,
            tabs: tabs
        )
        context.chrome = chrome

        if !navItems.isEmpty {
            let items = navItems
            let active = currentNav
            context.sidebarView = AnyView(
                CustomAppSidebarNavView(
                    appName: app.name,
                    items: items,
                    activeId: active,
                    onSelect: { id in selectNav(id) }
                )
            )
        } else {
            context.sidebarView = nil
        }

        context.inspectorView = { tabId in
            guard tabId == "permissions" else { return nil }
            return AnyView(
                CustomAppPermissionsInspectorView(slug: app.slug)
                    .environment(context)
            )
        }

        context.onCommand = { cmd in
            switch cmd {
            case .toolbarAction(let id, _):
                switch id {
                case "reload": reloadApp()
                case "permissions":
                    selectedInspectorTab = "permissions"
                    inspectorOpen = true
                case "standalone":
                    context.openStandaloneCustomApp(slug: app.slug)
                default: break
                }
            case .inspectorSelectTab(let tabId):
                selectedInspectorTab = tabId
                inspectorOpen = true
            case .inspectorVisibility(let open):
                inspectorOpen = open
            case .panelEvent(_, let event, let payloadJson):
                if event == "selectChat", let payloadJson,
                   let data = payloadJson.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let chatId = obj["chatId"] as? String, !chatId.isEmpty {
                    selectedChatId = chatId
                }
            default:
                break
            }
        }
    }

    // MARK: - Actions & Bridge Dispatch

    private func reloadApp() {
        runtimeErrorState = nil
        pendingApprovals.removeAll()
        hostController.closeAllWS()
        reloadKey += 1
    }

    private func selectNav(_ id: String) {
        activeNav = id
        hostController.sendNavActive(id)
    }

    private func handleBridgeMessage(_ msg: CustomAppBridgeLogic.BridgeMessage, app: API.CustomAppDetail) {
        switch msg {
        case .setNav(let items, let activeId):
            dynamicNavState = (seq: app.currentSeq, items: items)
            if let activeId { activeNav = activeId }

        case .askDock(let prompt):
            if standalone {
                onOpenInWorkbench?()
            } else {
                Task { await askDock(prompt: prompt, app: app) }
            }

        case .openURL(let url):
            context.openExternal(url)

        case .appError(let message):
            runtimeErrorState = (seq: app.currentSeq, reload: reloadKey, message: message)

        case .playerClosed:
            stopActiveMediaRelays()

        case .playerTheaterChanged:
            break

        case .playVideo(let rawURL, let title, let theater, let sidePanel, let extURL):
            handlePlayVideo(rawURL: rawURL, title: title, theater: theater, sidePanel: sidePanel, externalURL: extURL, app: app)

        case .wsSend(let connId, let data):
            hostController.sendProxyWS(connId: connId, data: data)

        case .wsClose(let connId, let code, let reason):
            hostController.closeProxyWS(connId: connId, code: code, reason: reason)

        case .wsOpen(let connId, let url, let protocols):
            let mode = app.capabilities["app.ws:outbound"] ?? .denied
            if mode == .allowed {
                hostController.openProxyWS(connId: connId, slug: app.slug, url: url, protocols: protocols, approved: false)
            } else if mode == .denied {
                let err = "capability app.ws:outbound is denied for custom app \"\(app.slug)\""
                hostController.postWSFailure(connId: connId, code: 1008, message: err)
            } else {
                enqueueApproval(.ws(seq: app.currentSeq, reload: reloadKey, connId: connId, url: url, protocols: protocols))
            }

        case .image(let reqId, let url):
            let mode = app.capabilities["app.http:outbound"] ?? .denied
            if mode == .allowed {
                hostController.fetchProxyImage(reqId: reqId, slug: app.slug, url: url, approved: false)
            } else if mode == .denied {
                hostController.postResponse(id: reqId, ok: false, error: "capability app.http:outbound is denied for custom app \"\(app.slug)\"")
            } else {
                enqueueApproval(.image(seq: app.currentSeq, reload: reloadKey, reqId: reqId, url: url))
            }

        case .osNotify(let reqId, _, _, _, _),
             .osClipboardRead(let reqId),
             .osClipboardWrite(let reqId, _),
             .osFilePick(let reqId, _, _, _):
            guard let cap = msg.osCapability else { return }
            let mode = app.capabilities[cap.rawValue] ?? .denied
            if mode == .denied {
                hostController.postResponse(id: reqId, ok: false, error: "capability \(cap.rawValue) is denied for custom app \"\(app.slug)\"")
            } else if mode == .requiresApproval {
                enqueueApproval(.os(seq: app.currentSeq, reload: reloadKey, reqId: reqId, msg: msg, capability: cap.rawValue, summary: msg.osApprovalSummary ?? "Allow \(cap.rawValue)"))
            } else {
                Task { await executeOSAction(msg, app: app) }
            }

        case .sql(let reqId, let query, let params):
            let body = API.CustomAppInvokeRequest(kind: .sql, params: params, query: query)
            Task { await executeInvoke(reqId: reqId, body: body, app: app) }

        case .api(let reqId, let method, let path, let reqBody):
            let body = API.CustomAppInvokeRequest(body: reqBody, kind: .api, method: method, path: path)
            Task { await executeInvoke(reqId: reqId, body: body, app: app) }

        case .mcp(let reqId, let connector, let tool, let arguments):
            let body = API.CustomAppInvokeRequest(arguments: arguments, connector: connector, kind: .mcp, tool: tool)
            Task { await executeInvoke(reqId: reqId, body: body, app: app) }
        }
    }

    private func enqueueApproval(_ item: PendingApproval) {
        pendingApprovals.append(item)
    }

    private func executeInvoke(reqId: String, body: API.CustomAppInvokeRequest, app: API.CustomAppDetail) async {
        do {
            let res = try await context.store.mutate(API.invokeCustomApp(slug: app.slug, body: body))
            if res.status == .approvalRequired {
                enqueueApproval(.invoke(
                    seq: app.currentSeq,
                    reload: reloadKey,
                    reqId: reqId,
                    body: body,
                    capability: res.capability,
                    summary: res.summary ?? "Allow \(res.capability)"
                ))
                return
            }
            if body.kind == .sql, let q = body.query, q.range(of: #"\b(create|alter|drop)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                _ = await context.store.refetch(appRequest)
            }
            hostController.postResponse(id: reqId, ok: true, data: res.result)
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            hostController.postResponse(id: reqId, ok: false, error: msg)
        }
    }

    private func executeOSAction(_ msg: CustomAppBridgeLogic.BridgeMessage, app: API.CustomAppDetail) async {
        switch msg {
        case .osNotify(let reqId, let title, let subtitle, let body, let silent):
            let delivered = context.window()?.app.system.sendCustomAppNotification(
                slug: app.slug,
                title: title,
                subtitle: subtitle ?? app.name,
                body: body ?? "",
                silent: silent
            ) ?? false
            if delivered {
                hostController.postResponse(id: reqId, ok: true, data: .object(["delivered": .bool(true)]))
            } else {
                hostController.postResponse(id: reqId, ok: false, error: "macOS notifications require the packaged Vesper.app")
            }

        case .osClipboardRead(let reqId):
            guard NSApp.isActive else {
                hostController.postResponse(id: reqId, ok: false, error: "Clipboard read requires the app window to be active")
                return
            }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            guard text.utf8.count <= CustomAppOSLimits.maxClipboardBytes else {
                hostController.postResponse(id: reqId, ok: false, error: "Clipboard text exceeds 1 MB limit")
                return
            }
            hostController.postResponse(id: reqId, ok: true, data: .object(["text": .string(text)]))

        case .osClipboardWrite(let reqId, let text):
            guard NSApp.isActive else {
                hostController.postResponse(id: reqId, ok: false, error: "Clipboard write requires the app window to be active")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hostController.postResponse(id: reqId, ok: true, data: .object(["ok": .bool(true)]))

        case .osFilePick(let reqId, let multiple, let extensions, let title):
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = multiple
            panel.prompt = "Choose"
            panel.message = title ?? "Choose \(multiple ? "files" : "a file") for \(app.name)"
            if !extensions.isEmpty {
                let types = extensions.compactMap { UTType(filenameExtension: $0) }
                if !types.isEmpty { panel.allowedContentTypes = types }
            }
            let response: NSApplication.ModalResponse
            if let win = NSApp.keyWindow, win.isVisible, win.attachedSheet == nil {
                response = await panel.beginSheetModal(for: win)
            } else {
                response = panel.runModal()
            }
            guard response == .OK else {
                hostController.postResponse(id: reqId, ok: true, data: .object(["canceled": .bool(true), "files": .array([])]))
                return
            }
            let urls = Array(panel.urls.prefix(CustomAppOSLimits.maxPickedFiles))
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[JSONValue], SimpleError> in
                var encoded: [JSONValue] = []
                var totalBytes = 0
                for url in urls {
                    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                        return .failure(SimpleError("Couldn\u{2019}t read \"\(url.lastPathComponent)\""))
                    }
                    guard data.count <= CustomAppOSLimits.maxPickedFileBytes else {
                        return .failure(SimpleError("File \"\(url.lastPathComponent)\" exceeds 2 MB limit"))
                    }
                    totalBytes += data.count
                    guard totalBytes <= CustomAppOSLimits.maxPickedTotalBytes else {
                        return .failure(SimpleError("Selected files exceed 5 MB total limit"))
                    }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    encoded.append(CustomAppOSPolicy.encodePickedFile(name: url.lastPathComponent, data: data, contentType: mime))
                }
                return .success(encoded)
            }.value
            switch result {
            case .success(let files):
                hostController.postResponse(id: reqId, ok: true, data: .object(["canceled": .bool(false), "files": .array(files)]))
            case .failure(let err):
                hostController.postResponse(id: reqId, ok: false, error: err.message)
            }

        default:
            break
        }
    }

    private enum ApprovalDecision { case once, always, decline }

    private func decideApproval(_ decision: ApprovalDecision, approval: PendingApproval, app: API.CustomAppDetail) async {
        guard !decidingApproval else { return }
        decidingApproval = true
        defer {
            pendingApprovals.removeAll { $0.id == approval.id }
            decidingApproval = false
        }

        if decision == .decline {
            switch approval {
            case .ws(_, _, let connId, _, _):
                hostController.postWSFailure(connId: connId, code: 1008, message: "Capability request declined")
            case .image(_, _, let reqId, _), .os(_, _, let reqId, _, _, _), .invoke(_, _, let reqId, _, _, _):
                hostController.postResponse(id: reqId, ok: false, error: "Capability request declined")
            }
            return
        }

        do {
            if decision == .always {
                var caps = app.capabilities
                caps[approval.capability] = .allowed
                _ = try await context.store.mutate(
                    API.updateCustomApp(slug: app.slug, body: API.UpdateCustomApp(capabilities: caps)),
                    invalidating: QueryInvalidation(resources: ["custom-apps"])
                )
            }

            switch approval {
            case .ws(_, _, let connId, let url, let protocols):
                hostController.openProxyWS(connId: connId, slug: app.slug, url: url, protocols: protocols, approved: decision == .once)
            case .image(_, _, let reqId, let url):
                hostController.fetchProxyImage(reqId: reqId, slug: app.slug, url: url, approved: decision == .once)
            case .os(_, _, _, let msg, _, _):
                await executeOSAction(msg, app: app)
            case .invoke(_, _, let reqId, var body, _, _):
                body.approved = true
                body.alwaysAllow = (decision == .always) ? true : nil
                let res = try await context.store.mutate(API.invokeCustomApp(slug: app.slug, body: body))
                if body.kind == .sql, let q = body.query, q.range(of: #"\b(create|alter|drop)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    _ = await context.store.refetch(appRequest)
                }
                hostController.postResponse(id: reqId, ok: true, data: res.result)
            }
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            switch approval {
            case .ws(_, _, let connId, _, _):
                hostController.postWSFailure(connId: connId, code: 1006, message: msg)
            case .image(_, _, let reqId, _), .os(_, _, let reqId, _, _, _), .invoke(_, _, let reqId, _, _, _):
                hostController.postResponse(id: reqId, ok: false, error: msg)
            }
        }
    }

    private func handlePlayVideo(
        rawURL: String,
        title: String?,
        theater: Bool?,
        sidePanel: Bool,
        externalURL: String?,
        app: API.CustomAppDetail
    ) {
        stopActiveMediaRelays()
        hlsRequestSeq += 1
        let reqSeq = hlsRequestSeq

        if let streamId = CustomAppBridgeLogic.hlsRelayStreamId(rawURL) {
            Task {
                do {
                    let stream = try await context.store.mutate(API.getCustomAppHlsStream(slug: app.slug, streamId: streamId))
                    guard hlsRequestSeq == reqSeq else {
                        _ = try? await context.store.mutate(API.stopCustomAppHlsStream(slug: app.slug, streamId: streamId))
                        return
                    }
                    activeHlsStreamId = stream.id
                    let url = stream.lanUrl.isEmpty ? stream.loopbackUrl : stream.lanUrl
                    hostController.playVideo(
                        provider: .hls,
                        embedURL: url,
                        title: title ?? "Live stream",
                        externalURL: externalURL ?? "",
                        theater: theater,
                        sidePanel: sidePanel
                    )
                } catch {}
            }
            return
        }

        if let mediaId = CustomAppBridgeLogic.localMediaId(rawURL) {
            let fallback = CustomAppBridgeLogic.localMediaEmbed(rawURL: rawURL, slug: app.slug)
            Task {
                do {
                    let relay = try await context.store.mutate(API.startCustomAppMediaRelay(slug: app.slug, mediaId: mediaId))
                    guard hlsRequestSeq == reqSeq else {
                        _ = try? await context.store.mutate(API.stopCustomAppMediaRelay(slug: app.slug, relayId: relay.id))
                        return
                    }
                    activeLocalRelayId = relay.id
                    let url = relay.lanUrl.isEmpty ? relay.loopbackUrl : relay.lanUrl
                    hostController.playVideo(
                        provider: .local,
                        embedURL: url,
                        title: title ?? "Downloaded video",
                        externalURL: externalURL ?? "",
                        theater: theater,
                        sidePanel: sidePanel
                    )
                } catch {
                    guard hlsRequestSeq == reqSeq, let fallback else { return }
                    hostController.playVideo(
                        provider: .local,
                        embedURL: fallback.embedURL,
                        title: title ?? fallback.titleFallback,
                        externalURL: externalURL ?? "",
                        theater: theater,
                        sidePanel: sidePanel
                    )
                }
            }
            return
        }

        let parentHost = context.baseURL()?.host ?? "localhost"
        if let embed = CustomAppBridgeLogic.resolveVideoEmbed(rawURL: rawURL, parentHost: parentHost) {
            hostController.playVideo(
                provider: embed.provider,
                embedURL: embed.embedURL,
                title: title ?? embed.titleFallback,
                externalURL: externalURL ?? embed.externalURL,
                theater: theater,
                sidePanel: sidePanel
            )
        } else if CustomAppBridgeLogic.localMediaId(rawURL) == nil,
                  let safe = CustomAppBridgeLogic.parseSafeExternalURL(rawURL) {
            context.openExternal(safe)
        }
    }

    private func stopActiveMediaRelays() {
        hlsRequestSeq += 1
        if let streamId = activeHlsStreamId {
            activeHlsStreamId = nil
            let s = slug
            Task { _ = try? await context.store.mutate(API.stopCustomAppHlsStream(slug: s, streamId: streamId)) }
        }
        if let relayId = activeLocalRelayId {
            activeLocalRelayId = nil
            let s = slug
            Task { _ = try? await context.store.mutate(API.stopCustomAppMediaRelay(slug: s, relayId: relayId)) }
        }
    }

    private func askDock(prompt: String, app: API.CustomAppDetail) async {
        selectedInspectorTab = "chat"
        inspectorOpen = true
        let formatted = CustomAppBridgeLogic.withCustomAppContext(
            prompt,
            slug: app.slug,
            name: app.name,
            seq: app.currentSeq,
            activeNav: currentNav,
            error: runtimeError
        )
        let dockReq = DockChatsAPI.list(scope: "app:custom:\(app.slug)")
        let existingChatId = selectedChatId ?? context.store.entry(dockReq).data?.chats.first?.id
        do {
            if let chatId = existingChatId {
                _ = try await context.store.mutate(
                    API.postChatMessage(id: chatId, body: API.NewChatMessage(body: formatted)),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
            } else {
                let personas = context.store.entry(API.listPersonas()).data?.personas ?? []
                let personaId = personas.first(where: { $0.isDefault })?.id ?? personas.first?.id
                let created = try await context.store.mutate(
                    API.createChat(body: API.NewChat(
                        hidden: true,
                        message: API.NewChatMessage(body: formatted),
                        personaId: personaId,
                        title: app.name
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                _ = try? await context.store.mutate(DockChatsAPI.add(scope: "app:custom:\(app.slug)", chatId: created.id))
                selectedChatId = created.id
                _ = await context.store.refetch(dockReq)
            }
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            context.showToast(ToastItemModel(id: "ask-\(app.slug)", title: "Couldn\u{2019}t send to chat", description: msg, tone: .error))
        }
    }

    private func encodeJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func sfSymbolForAppIcon(_ icon: String) -> String {
        switch icon {
        case "dollar": "dollarsign.circle"
        case "board": "rectangle.3.group"
        case "graph": "point.3.connected.trianglepath.dotted"
        case "bolt": "bolt"
        case "compass": "compass.drawing"
        case "briefcase": "briefcase"
        case "server": "server.rack"
        case "clock": "clock"
        case "tickets": "ticket"
        case "gamepad": "gamecontroller"
        case "dice": "dice"
        default: "square.grid.2x2"
        }
    }
}

// MARK: - Pending Approval Model

private enum PendingApproval: Identifiable {
    case invoke(seq: Int, reload: Int, reqId: String, body: API.CustomAppInvokeRequest, capability: String, summary: String)
    case image(seq: Int, reload: Int, reqId: String, url: String)
    case ws(seq: Int, reload: Int, connId: String, url: String, protocols: [String])
    case os(seq: Int, reload: Int, reqId: String, msg: CustomAppBridgeLogic.BridgeMessage, capability: String, summary: String)

    var id: String {
        switch self {
        case .invoke(_, _, let reqId, _, _, _): "inv:\(reqId)"
        case .image(_, _, let reqId, _): "img:\(reqId)"
        case .ws(_, _, let connId, _, _): "ws:\(connId)"
        case .os(_, _, let reqId, _, _, _): "os:\(reqId)"
        }
    }

    var seq: Int {
        switch self {
        case .invoke(let s, _, _, _, _, _), .image(let s, _, _, _), .ws(let s, _, _, _, _), .os(let s, _, _, _, _, _): s
        }
    }

    var reload: Int {
        switch self {
        case .invoke(_, let r, _, _, _, _), .image(_, let r, _, _), .ws(_, let r, _, _, _), .os(_, let r, _, _, _, _): r
        }
    }

    var capability: String {
        switch self {
        case .invoke(_, _, _, _, let c, _): c
        case .image: "app.http:outbound"
        case .ws: "app.ws:outbound"
        case .os(_, _, _, _, let c, _): c
        }
    }

    var summary: String {
        switch self {
        case .invoke(_, _, _, _, _, let s): s
        case .image: "Load remote images via HTTPS proxy"
        case .ws: "Open outbound WebSocket connection via proxy"
        case .os(_, _, _, _, _, let s): s
        }
    }
}

private struct SimpleError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Sidebar Nav View

private struct CustomAppSidebarNavView: View {
    @Environment(\.vesperTheme) private var theme
    let appName: String
    let items: [CustomAppBridgeLogic.NavSpec]
    let activeId: String?
    let onSelect: (String) -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 4) {
            Text(appName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(items) { item in
                let active = item.id == activeId
                Button { onSelect(item.id) } label: {
                    HStack(spacing: 8) {
                        Text(item.label)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? p.text : p.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(active ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Native Permissions Inspector Panel

private struct CustomAppPermissionsInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let slug: String
    @State private var nixInput = ""
    @State private var mountInput = ""
    @State private var updating = false
    @State private var errorText: String?

    private var appRequest: APIRequest<API.CustomAppDetail> {
        API.getCustomApp(slug: slug)
    }

    var body: some View {
        let p = theme.palette
        let app = context.store.entry(appRequest).data

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                }

                if let app {
                    let snapshot = CustomAppStandaloneLogic.buildPermissions(from: app)

                    // Capabilities
                    capSection(title: CustomAppStandaloneLogic.CapabilityGroup.os.title, entries: snapshot.osCapabilities, app: app, p: p)
                    capSection(title: CustomAppStandaloneLogic.CapabilityGroup.bridge.title, entries: snapshot.bridgeCapabilities, app: app, p: p)
                    if !snapshot.externalCapabilities.isEmpty {
                        capSection(title: CustomAppStandaloneLogic.CapabilityGroup.external.title, entries: snapshot.externalCapabilities, app: app, p: p)
                    }

                    // Nix packages
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add Nix package")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                        HStack(spacing: 6) {
                            TextField("e.g. yt-dlp, ffmpeg", text: $nixInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button("Add") { addNixPackages(app: app) }
                                .buttonStyle(.vesper(.outline))
                                .disabled(updating || nixInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    // Host mounts
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Host Mounts")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                        ForEach(snapshot.mounts) { m in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.name)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    Text(m.hostPath ?? "Not configured")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(m.isConfigured ? p.secondaryText : Color.orange)
                                }
                                Spacer(minLength: 0)
                                if m.isConfigured {
                                    Button("Remove") { setMount(name: m.name, path: "", app: app) }
                                        .buttonStyle(.vesper(.outline))
                                        .disabled(updating)
                                }
                            }
                        }
                        HStack(spacing: 6) {
                            TextField("name=/path/to/dir", text: $mountInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button("Add") { addMount(app: app) }
                                .buttonStyle(.vesper(.outline))
                                .disabled(updating || mountInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    // SQLite & MCP info
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Database & Server")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                        Text("SQLite: \(CustomAppBridgeLogic.formatBytes(app.dbSizeBytes)) · \(app.schema.count) schema objects")
                            .font(.system(size: 12))
                            .foregroundStyle(p.secondaryText)
                        if app.hasMcpServer {
                            Text("MCP server: \(app.manifest.mcpEntry ?? "server.ts") · \((app.mcpTools ?? []).count) tools")
                                .font(.system(size: 12))
                                .foregroundStyle(p.secondaryText)
                        }
                    }

                    // Versions
                    if !app.versions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Versions")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                            ForEach(app.versions.sorted(by: { $0.seq > $1.seq }), id: \.seq) { v in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("v\(v.seq)\(v.seq == app.currentSeq ? " (current)" : "")")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        if !v.note.isEmpty {
                                            Text(v.note)
                                                .font(.system(size: 11))
                                                .foregroundStyle(p.secondaryText)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if v.seq != app.currentSeq {
                                        Button("Restore") { restoreVersion(v.seq, app: app) }
                                            .buttonStyle(.vesper(.outline))
                                            .disabled(updating)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func capSection(title: String, entries: [CustomAppStandaloneLogic.CapabilityEntry], app: API.CustomAppDetail, p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.tertiaryText)
            ForEach(entries) { cap in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cap.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(p.text)
                        Text(cap.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Picker("", selection: Binding(
                        get: { cap.mode },
                        set: { setCapability(key: cap.key, mode: $0, app: app) }
                    )) {
                        Text("Allow").tag(API.CustomAppCapabilityMode.allowed)
                        Text("Ask").tag(API.CustomAppCapabilityMode.requiresApproval)
                        Text("Deny").tag(API.CustomAppCapabilityMode.denied)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 84)
                    .disabled(updating)
                }
            }
        }
    }

    private func setCapability(key: String, mode: API.CustomAppCapabilityMode, app: API.CustomAppDetail) {
        let next = CustomAppStandaloneLogic.updatedCapabilities(app.capabilities, key: key, mode: mode)
        mutate(API.UpdateCustomApp(capabilities: next))
    }

    private func addNixPackages(app: API.CustomAppDetail) {
        let names = nixInput.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        for pkg in names where !CustomAppBridgeLogic.isValidNixPackage(pkg) {
            errorText = "Invalid Nix package name: \"\(pkg)\""
            return
        }
        var next = app.capabilities
        for pkg in names { next["nix:\(pkg)"] = .allowed }
        nixInput = ""
        errorText = nil
        mutate(API.UpdateCustomApp(capabilities: next))
    }

    private func addMount(app: API.CustomAppDetail) {
        let parts = mountInput.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, CustomAppBridgeLogic.isValidMountName(parts[0]),
              !parts[1].isEmpty, CustomAppBridgeLogic.isValidHostMountPath(parts[1]) else {
            errorText = "Enter name=/absolute/path or name=~/path"
            return
        }
        mountInput = ""
        errorText = nil
        setMount(name: parts[0], path: parts[1], app: app)
    }

    private func setMount(name: String, path: String, app: API.CustomAppDetail) {
        var next = app.mounts ?? [:]
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { next.removeValue(forKey: name) } else { next[name] = trimmed }
        mutate(API.UpdateCustomApp(mounts: next))
    }

    private func restoreVersion(_ seq: Int, app: API.CustomAppDetail) {
        mutate(API.UpdateCustomApp(note: "Restored v\(seq)", restoreSeq: seq))
    }

    private func mutate(_ body: API.UpdateCustomApp) {
        guard !updating else { return }
        updating = true
        errorText = nil
        Task {
            defer { updating = false }
            do {
                _ = try await context.store.mutate(
                    API.updateCustomApp(slug: slug, body: body),
                    invalidating: QueryInvalidation(resources: ["custom-apps"])
                )
            } catch {
                errorText = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Sandboxed WKWebView Host Controller

@MainActor
final class CustomAppWebHostController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let handlerName = "vesperCustomApp"

    fileprivate weak var webView: WKWebView?
    fileprivate var loadedKey: String?
    fileprivate var onMessage: ((CustomAppBridgeLogic.BridgeMessage) -> Void)?

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = WebViewFactory.userAgentSuffix
        config.websiteDataStore = .default()
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(self, name: Self.handlerName)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        webView = wv
        return wv
    }

    func teardown() {
        closeAllWS()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        loadedKey = nil
    }

    func load(slug: String, name: String, seq: Int, reloadKey: Int, bundleJS: String, bundleCSS: String?, themeVars: [String: String], baseURL: URL) {
        let key = "\(slug):\(seq):\(reloadKey)"
        guard key != loadedKey, let webView else { return }
        loadedKey = key
        let srcDoc = CustomAppBridgeLogic.buildCustomAppSrcDoc(
            slug: slug,
            seq: seq,
            bundleJS: bundleJS,
            bundleCSS: bundleCSS,
            themeVars: themeVars
        )
        let hostHTML = CustomAppBridgeLogic.buildHostHTML(
            slug: slug,
            name: name,
            srcDoc: srcDoc,
            themeVars: themeVars
        )
        let appOriginURL = baseURL.appendingPathComponent("apps/\(slug)")
        webView.loadHTMLString(hostHTML, baseURL: appOriginURL)
    }

    func sendTheme(_ vars: [String: String]) {
        evalHostCall("window.__vesperHost && window.__vesperHost.setTheme(arg)", arg: vars)
    }

    func sendNavActive(_ id: String) {
        evalHostCall("window.__vesperHost && window.__vesperHost.setNavActive(arg)", arg: id)
    }

    func postResponse(id: String, ok: Bool, data: JSONValue? = nil, error: String? = nil) {
        var msg: [String: Any] = ["type": "vesper:response", "id": id, "ok": ok]
        if let data { msg["data"] = data.toAnyObject() }
        if let error { msg["error"] = error }
        evalHostCall("window.__vesperHost && window.__vesperHost.postToFrame(arg)", arg: msg)
    }

    func postWSFailure(connId: String, code: Int, message: String) {
        evalHostCall(
            "window.__vesperHost && window.__vesperHost.postToFrame(arg)",
            arg: ["type": "vesper:ws", "connId": connId, "event": "error", "message": message]
        )
        evalHostCall(
            "window.__vesperHost && window.__vesperHost.postToFrame(arg)",
            arg: ["type": "vesper:ws", "connId": connId, "event": "close", "code": code, "reason": message, "wasClean": false]
        )
    }

    func openProxyWS(connId: String, slug: String, url: String, protocols: [String], approved: Bool) {
        evalHostCall(
            "window.__vesperHost && window.__vesperHost.openProxyWS(arg.connId, arg.slug, arg.url, arg.protocols, arg.approved)",
            arg: ["connId": connId, "slug": slug, "url": url, "protocols": protocols, "approved": approved]
        )
    }

    func sendProxyWS(connId: String, data: String) {
        evalHostCall(
            "window.__vesperHost && window.__vesperHost.sendProxyWS(arg.connId, arg.data)",
            arg: ["connId": connId, "data": data]
        )
    }

    func closeProxyWS(connId: String, code: Int?, reason: String?) {
        evalHostCall(
            "window.__vesperHost && window.__vesperHost.closeProxyWS(arg.connId, arg.code, arg.reason)",
            arg: ["connId": connId, "code": code ?? 1000, "reason": reason ?? ""]
        )
    }

    func closeAllWS() {
        webView?.evaluateJavaScript("window.__vesperHost && window.__vesperHost.closeAllWS()", completionHandler: nil)
    }

    func fetchProxyImage(reqId: String, slug: String, url: String, approved: Bool) {
        evalHostCall(
            "window.__vesperHost && window.__vesperHost.fetchProxyImage(arg.reqId, arg.slug, arg.url, arg.approved)",
            arg: ["reqId": reqId, "slug": slug, "url": url, "approved": approved]
        )
    }

    func playVideo(
        provider: CustomAppBridgeLogic.VideoEmbed.Provider,
        embedURL: String,
        title: String,
        externalURL: String,
        theater: Bool?,
        sidePanel: Bool
    ) {
        var spec: [String: Any] = [
            "provider": provider.rawValue,
            "embedUrl": embedURL,
            "title": title,
            "externalUrl": externalURL,
            "externalLabel": CustomAppBridgeLogic.externalLinkLabel(provider: provider, externalURL: externalURL),
            "sidePanel": sidePanel,
        ]
        if let theater { spec["theater"] = theater }
        evalHostCall("window.__vesperHost && window.__vesperHost.playVideo(arg)", arg: spec)
    }

    private func evalHostCall(_ js: String, arg: Any) {
        guard let webView else { return }
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(js, arguments: ["arg": arg], in: nil, contentWorld: .page)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, message.frameInfo.isMainFrame,
              let parsed = CustomAppBridgeLogic.parseBridgeMessage(message.body) else { return }
        onMessage?(parsed)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

private struct CustomAppWebHostRepresentable: NSViewRepresentable {
    let controller: CustomAppWebHostController
    let slug: String
    let name: String
    let seq: Int
    let reloadKey: Int
    let bundleJS: String
    let bundleCSS: String?
    let themeVars: [String: String]
    let baseURL: URL
    let onMessage: (CustomAppBridgeLogic.BridgeMessage) -> Void

    func makeNSView(context: Context) -> WKWebView {
        controller.onMessage = onMessage
        let wv = controller.makeWebView()
        controller.load(slug: slug, name: name, seq: seq, reloadKey: reloadKey, bundleJS: bundleJS, bundleCSS: bundleCSS, themeVars: themeVars, baseURL: baseURL)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        controller.onMessage = onMessage
        controller.load(slug: slug, name: name, seq: seq, reloadKey: reloadKey, bundleJS: bundleJS, bundleCSS: bundleCSS, themeVars: themeVars, baseURL: baseURL)
    }
}

private extension JSONValue {
    func toAnyObject() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.toAnyObject() }
        case .object(let dict): return dict.mapValues { $0.toAnyObject() }
        }
    }
}
