import Foundation
import SwiftUI
import VesperCore

@MainActor
@Observable
final class HttpScreenModel {
    static let workspaceDefaultsKey = "VesperNativeHttpWorkspace"

    enum ViewMode: Equatable {
        case requests
        case authEnv
    }

    struct NewFolderTarget: Identifiable {
        let id = UUID()
        let parentFolderId: String?
        let parentFolderName: String?
    }

    enum RenameTarget: Identifiable {
        case folder(HttpFolder)
        case request(HttpRequest)

        var id: String {
            switch self {
            case .folder(let f): return "folder:\(f.id)"
            case .request(let r): return "request:\(r.id)"
            }
        }

        var title: String {
            switch self {
            case .folder: return "Rename folder"
            case .request: return "Rename request"
            }
        }

        var currentName: String {
            switch self {
            case .folder(let f): return f.name
            case .request(let r): return r.name
            }
        }
    }

    struct ImportTarget: Identifiable {
        let id = UUID()
        let folder: HttpFolder?
        let tab: HttpImportFormat
    }

    enum DeleteTarget {
        case workspace(HttpWorkspace)
        case folder(HttpFolder)
        case request(HttpRequest)

        var title: String {
            switch self {
            case .workspace(let ws): return "Delete workspace \"\(ws.name)\"?"
            case .folder(let f): return "Delete folder \"\(f.name)\"?"
            case .request(let r): return "Delete request \"\(r.name)\"?"
            }
        }

        var message: String {
            switch self {
            case .workspace:
                return "This deletes all folders, requests, environments, and execution history in this workspace."
            case .folder:
                return "This removes the folder and any nested folders or requests inside it."
            case .request:
                return "This deletes the request and its recorded execution history."
            }
        }
    }

    var selectedWorkspaceId: String?
    var rememberedWorkspaceId: String? = UserDefaults.standard.string(forKey: workspaceDefaultsKey)
    var viewMode: ViewMode = .requests
    var filter = ""
    var collapsedFolders: Set<String> = []
    var selectedFolderId: String?
    var selectedRequestId: String?
    var showNarrowTree = false

    var draftRequestId: String?
    var draft: HttpRequestDraft?
    var lastLoadedDraft: HttpRequestDraft?
    var reqTab: HttpRequestTab = .params
    var respTab: HttpResponseTab = .body

    var latestExecutionRequestId: String?
    var latestExecution: HttpExecution?
    var isSending = false
    var isSaving = false
    var isMutating = false

    var showNewWorkspaceSheet = false
    var newWorkspaceName = ""
    var newFolderTarget: NewFolderTarget?
    var newFolderName = ""
    var renameTarget: RenameTarget?
    var renameText = ""
    var importTarget: ImportTarget?
    var pendingDelete: DeleteTarget?

    func rememberWorkspace(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        if rememberedWorkspaceId != id {
            rememberedWorkspaceId = id
            UserDefaults.standard.set(id, forKey: Self.workspaceDefaultsKey)
        }
    }

    func switchWorkspace(_ id: String) {
        selectedWorkspaceId = id
        rememberWorkspace(id)
        selectedFolderId = nil
        selectedRequestId = nil
        draftRequestId = nil
        draft = nil
        lastLoadedDraft = nil
        latestExecutionRequestId = nil
        latestExecution = nil
    }

    func selectRequest(_ request: HttpRequest) {
        viewMode = .requests
        selectedRequestId = request.id
        selectedFolderId = request.folderId
        let nextDraft = HttpClientLogic.toDraft(request)
        draftRequestId = request.id
        draft = nextDraft
        lastLoadedDraft = nextDraft
        latestExecutionRequestId = nil
        latestExecution = nil
        showNarrowTree = false
    }
}

struct HttpScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var model = HttpScreenModel()
    @State private var watchedKeys: [QueryKey] = []

    private static let workspacesReq = HttpClientAPI.listWorkspaces()
    private static let secretsReq = API.listApiSecrets()

    var body: some View {
        let store = context.store
        let workspacesEntry = store.entry(Self.workspacesReq)
        let workspaces = workspacesEntry.data?.workspaces ?? []
        let effectiveWsId = HttpClientLogic.effectiveWorkspaceId(
            workspaces: workspaces,
            selectedId: model.selectedWorkspaceId,
            rememberedId: model.rememberedWorkspaceId
        )
        let bundleReq = effectiveWsId.map { HttpClientAPI.getWorkspaceBundle(id: $0) }
        let bundleEntry = bundleReq.map { store.entry($0) }
        let bundle = bundleEntry?.data

        let selectedRequest = HttpClientLogic.effectiveRequest(
            bundle: bundle,
            selectedRequestId: model.selectedRequestId
        )
        let activeReqId = selectedRequest?.id
        let execsReq = activeReqId.map { HttpClientAPI.listRequestExecutions(requestId: $0, limit: 25) }
        let execsEntry = execsReq.map { store.entry($0) }
        let history = execsEntry?.data?.executions ?? []
        let activeExecution: HttpExecution? = {
            guard let activeReqId else { return nil }
            if model.latestExecutionRequestId == activeReqId, let latest = model.latestExecution {
                return latest
            }
            return history.first
        }()
        let secrets = store.entry(Self.secretsReq).data?.secrets ?? []

        let isDirty: Bool = {
            guard let selectedRequest,
                  let draft = model.draft,
                  model.draftRequestId == selectedRequest.id
            else { return false }
            return HttpClientLogic.isDirty(draft, comparedTo: selectedRequest)
        }()

        let visibleRows = bundle.map {
            HttpClientLogic.visibleTreeRows(
                bundle: $0,
                filter: model.filter,
                collapsedFolders: model.collapsedFolders
            )
        } ?? []
        let visibleRequests = visibleRows.compactMap { row -> HttpRequest? in
            if case .request(let req) = row.kind { return req }
            return nil
        }

        let currentChrome = NativeChrome(
            title: "HTTP client",
            subtitle: bundle?.workspace.name,
            toolbarItems: HttpClientChrome.toolbarItems(
                workspaces: workspaces,
                effectiveWorkspaceId: effectiveWsId,
                bundle: bundle,
                isAuthEnvMode: model.viewMode == .authEnv
            )
        )

        rootBody(
            workspacesEntry: workspacesEntry,
            workspaces: workspaces,
            effectiveWsId: effectiveWsId,
            bundleEntry: bundleEntry,
            bundle: bundle,
            visibleRows: visibleRows,
            selectedRequest: selectedRequest,
            isDirty: isDirty,
            history: history,
            execsEntry: execsEntry,
            activeExecution: activeExecution,
            secrets: secrets
        )
        .onChange(of: currentChrome, initial: true) { _, nextChrome in
            context.chrome = nextChrome
        }
        .onChange(of: context.match, initial: true) { _, match in
            if let wsQuery = match.query["workspace"], !wsQuery.isEmpty {
                model.selectedWorkspaceId = wsQuery
                model.rememberWorkspace(wsQuery)
            }
        }
        .onChange(of: effectiveWsId, initial: true) { _, nextWsId in
            model.rememberWorkspace(nextWsId)
        }
        .onChange(of: selectedRequest, initial: true) { _, nextReq in
            syncDraft(with: nextReq)
        }
        .onChange(of: visibleRequests.map(Self.searchText), initial: true) { _, texts in
            context.find.texts = texts
        }
        .onChange(of: context.find.current) { _, index in
            guard let index, index < visibleRequests.count else { return }
            model.selectRequest(visibleRequests[index])
        }
        .task(id: "\(effectiveWsId ?? "none")|\(activeReqId ?? "none")") {
            updateWatchedQueries(workspaceId: effectiveWsId, requestId: activeReqId)
        }
        .onAppear {
            context.onCommand = { command in
                handleToolbarCommand(command)
            }
        }
        .onDisappear {
            for key in watchedKeys {
                context.store.stopObserving(key)
            }
            watchedKeys = []
        }
        .sheet(isPresented: $model.showNewWorkspaceSheet) {
            newWorkspaceSheet
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
        .sheet(item: $model.newFolderTarget) { target in
            newFolderSheet(target: target, workspaceId: effectiveWsId)
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
        .sheet(item: $model.renameTarget) { target in
            renameSheet(target: target, workspaceId: effectiveWsId)
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
        .sheet(item: $model.importTarget) { target in
            if let wsId = effectiveWsId {
                HttpImportSheet(
                    workspaceId: wsId,
                    targetFolder: target.folder,
                    initialTab: target.tab,
                    onImported: { _ in
                        Task {
                            if let bundleReq {
                                _ = await context.store.refetch(bundleReq)
                            }
                        }
                    },
                    onDismiss: { model.importTarget = nil }
                )
                .environment(context)
                .environment(\.vesperTheme, theme)
            }
        }
        .confirmationDialog(
            model.pendingDelete?.title ?? "",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = model.pendingDelete {
                Button("Delete", role: .destructive) {
                    Task { await performDelete(target, workspaceId: effectiveWsId) }
                }
            }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            if let target = model.pendingDelete {
                Text(target.message)
            }
        }
    }

    // MARK: - Root Content States

    @ViewBuilder
    private func rootBody(
        workspacesEntry: QueryEntry<HttpWorkspaceList>,
        workspaces: [HttpWorkspace],
        effectiveWsId: String?,
        bundleEntry: QueryEntry<HttpWorkspaceBundle>?,
        bundle: HttpWorkspaceBundle?,
        visibleRows: [HttpClientLogic.HttpTreeRow],
        selectedRequest: HttpRequest?,
        isDirty: Bool,
        history: [HttpExecution],
        execsEntry: QueryEntry<HttpExecutionList>?,
        activeExecution: HttpExecution?,
        secrets: [API.ApiSecret]
    ) -> some View {
        if workspacesEntry.data == nil && workspacesEntry.error == nil {
            VStack(spacing: 12) {
                SkeletonBar(height: 36)
                SkeletonBar(height: 220)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if workspacesEntry.data == nil, let err = workspacesEntry.error {
            QueryErrorView(message: "Couldn\u{2019}t load HTTP workspaces: \(err.userMessage)") {
                Task { await context.store.refetch(Self.workspacesReq) }
            }
        } else if workspaces.isEmpty {
            HttpEmptyState(
                icon: "powerplug",
                title: "No HTTP workspaces yet",
                message: "Organize HTTP calls by app into Workspaces, switch between nonprod and prod environments, inherit auth, or import your Bruno .bru collections."
            ) {
                Button {
                    model.newWorkspaceName = "Default API"
                    model.showNewWorkspaceSheet = true
                } label: {
                    Label("Create your first workspace", systemImage: "plus")
                }
                .buttonStyle(.vesper(.primary))
            }
        } else if let bundle {
            VStack(spacing: 0) {
                if let err = bundleEntry?.error {
                    staleErrorBanner(message: "Refresh failed: \(err.userMessage)") {
                        if let effectiveWsId {
                            Task { await context.store.refetch(HttpClientAPI.getWorkspaceBundle(id: effectiveWsId)) }
                        }
                    }
                }

                if model.viewMode == .authEnv {
                    HttpAuthEnvView(
                        bundle: bundle,
                        initialFolderId: model.selectedFolderId,
                        secrets: secrets,
                        onBack: { model.viewMode = .requests }
                    )
                } else {
                    workbenchLayout(
                        workspaces: workspaces,
                        bundle: bundle,
                        visibleRows: visibleRows,
                        selectedRequest: selectedRequest,
                        isDirty: isDirty,
                        history: history,
                        execsEntry: execsEntry,
                        activeExecution: activeExecution,
                        secrets: secrets
                    )
                }
            }
        } else if let err = bundleEntry?.error {
            QueryErrorView(message: "Couldn\u{2019}t load workspace: \(err.userMessage)") {
                if let effectiveWsId {
                    Task { await context.store.refetch(HttpClientAPI.getWorkspaceBundle(id: effectiveWsId)) }
                }
            }
        } else {
            VStack(spacing: 12) {
                SkeletonBar(height: 36)
                SkeletonBar(height: 220)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func staleErrorBanner(message: String, retry: @escaping () -> Void) -> some View {
        let fg = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let bg = theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.12))
        return HStack(spacing: 10) {
            Text(message)
                .vesperText(.small, theme)
                .foregroundStyle(fg)
            Spacer()
            Button("Retry", action: retry)
                .buttonStyle(.vesper())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bg)
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.border) }
    }

    // MARK: - Adaptive Workbench Layout

    private func workbenchLayout(
        workspaces: [HttpWorkspace],
        bundle: HttpWorkspaceBundle,
        visibleRows: [HttpClientLogic.HttpTreeRow],
        selectedRequest: HttpRequest?,
        isDirty: Bool,
        history: [HttpExecution],
        execsEntry: QueryEntry<HttpExecutionList>?,
        activeExecution: HttpExecution?,
        secrets: [API.ApiSecret]
    ) -> some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 760
            if isCompact {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            model.showNarrowTree.toggle()
                        } label: {
                            Label(
                                model.showNarrowTree ? "Back to Editor" : "Collections",
                                systemImage: model.showNarrowTree ? "chevron.left" : "sidebar.left"
                            )
                        }
                        .buttonStyle(.vesper())

                        if let selectedRequest, !model.showNarrowTree {
                            HttpMethodBadge(method: selectedRequest.method)
                            Text(selectedRequest.name)
                                .vesperText(.small, theme)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(theme.palette.surface)

                    Divider().overlay(theme.palette.border)

                    if model.showNarrowTree {
                        collectionSidebar(
                            workspaces: workspaces,
                            bundle: bundle,
                            visibleRows: visibleRows,
                            selectedRequest: selectedRequest,
                            isDirty: isDirty
                        )
                    } else {
                        mainEditorArea(
                            bundle: bundle,
                            selectedRequest: selectedRequest,
                            isDirty: isDirty,
                            history: history,
                            execsEntry: execsEntry,
                            activeExecution: activeExecution,
                            secrets: secrets
                        )
                    }
                }
            } else {
                HStack(spacing: 0) {
                    collectionSidebar(
                        workspaces: workspaces,
                        bundle: bundle,
                        visibleRows: visibleRows,
                        selectedRequest: selectedRequest,
                        isDirty: isDirty
                    )
                    .frame(width: 264)

                    Divider().overlay(theme.palette.border)

                    mainEditorArea(
                        bundle: bundle,
                        selectedRequest: selectedRequest,
                        isDirty: isDirty,
                        history: history,
                        execsEntry: execsEntry,
                        activeExecution: activeExecution,
                        secrets: secrets
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Collection Tree Sidebar

    private func collectionSidebar(
        workspaces: [HttpWorkspace],
        bundle: HttpWorkspaceBundle,
        visibleRows: [HttpClientLogic.HttpTreeRow],
        selectedRequest: HttpRequest?,
        isDirty: Bool
    ) -> some View {
        let activeEnv = bundle.environments.first { $0.id == bundle.workspace.activeEnvironmentId }

        return VStack(spacing: 0) {
            // Compact workspace & environment switcher (self-contained for iOS/narrow windows too)
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(workspaces) { ws in
                            Button {
                                model.switchWorkspace(ws.id)
                            } label: {
                                if ws.id == bundle.workspace.id {
                                    Label(ws.name, systemImage: "checkmark")
                                } else {
                                    Text(ws.name)
                                }
                            }
                        }
                        Divider()
                        Button {
                            model.newWorkspaceName = ""
                            model.showNewWorkspaceSheet = true
                        } label: {
                            Label("New workspace\u{2026}", systemImage: "plus")
                        }
                        Button(role: .destructive) {
                            model.pendingDelete = .workspace(bundle.workspace)
                        } label: {
                            Label("Delete workspace", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.palette.secondaryText)
                            Text(bundle.workspace.name)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)

                    Menu {
                        Button {
                            Task { await setActiveEnvironment(workspaceId: bundle.workspace.id, environmentId: nil) }
                        } label: {
                            if bundle.workspace.activeEnvironmentId == nil {
                                Label("No environment", systemImage: "checkmark")
                            } else {
                                Text("No environment")
                            }
                        }
                        Divider()
                        ForEach(bundle.environments) { env in
                            Button {
                                Task { await setActiveEnvironment(workspaceId: bundle.workspace.id, environmentId: env.id) }
                            } label: {
                                if env.id == bundle.workspace.activeEnvironmentId {
                                    Label(env.name, systemImage: "checkmark")
                                } else {
                                    Text(env.name)
                                }
                            }
                        }
                        Divider()
                        Button {
                            model.viewMode = .authEnv
                        } label: {
                            Label("Manage environments & auth\u{2026}", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(activeEnv.map { HttpStyle.envColor($0.color, theme: theme) } ?? theme.palette.tertiaryText)
                                .frame(width: 7, height: 7)
                            Text(activeEnv?.name ?? "No env")
                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                }

                // Requests / Auth & Env mode toggle (available on all platforms, including narrow/iOS)
                HStack(spacing: 4) {
                    modeSwitchButton(title: "Requests", active: model.viewMode == .requests) {
                        model.viewMode = .requests
                    }
                    modeSwitchButton(title: "Auth & Env", active: model.viewMode == .authEnv) {
                        model.viewMode = .authEnv
                    }
                }
                .padding(2)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))

                // Filter + New Request + New Folder
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.tertiaryText)
                        TextField("Filter calls\u{2026}", text: $model.filter)
                            .textFieldStyle(.plain)
                            .font(theme.font(.small))
                        if !model.filter.isEmpty {
                            Button {
                                model.filter = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.palette.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear filter")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))

                    Button {
                        Task { await createRequest(workspaceId: bundle.workspace.id, folderId: model.selectedFolderId) }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.vesper(.primary))
                    .help("New request")
                    .accessibilityLabel("New request")

                    Button {
                        openNewFolderSheet(parentFolder: model.selectedFolderId.flatMap { id in
                            bundle.folders.first(where: { $0.id == id })
                        })
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.vesper())
                    .help("New folder")
                    .accessibilityLabel("New folder")
                }
            }
            .padding(10)

            Divider().overlay(theme.palette.border)

            ScrollView {
                if bundle.folders.isEmpty && bundle.requests.isEmpty {
                    VStack(spacing: 8) {
                        Text("No requests yet.")
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.palette.tertiaryText)
                        HStack(spacing: 8) {
                            Button("New Request") {
                                Task { await createRequest(workspaceId: bundle.workspace.id, folderId: nil) }
                            }
                            .buttonStyle(.vesper(.primary))
                            Button("Import") {
                                model.importTarget = HttpScreenModel.ImportTarget(folder: nil, tab: .bru)
                            }
                            .buttonStyle(.vesper())
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                } else if visibleRows.isEmpty {
                    Text("No requests match \u{201C}\(model.filter)\u{201D}.")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.tertiaryText)
                        .padding(16)
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleRows) { row in
                            switch row.kind {
                            case .folder(let folder, let isCollapsed, let childCount):
                                folderRow(
                                    folder: folder,
                                    depth: row.depth,
                                    isCollapsed: isCollapsed,
                                    childCount: childCount,
                                    bundle: bundle
                                )
                            case .request(let req):
                                requestRow(
                                    req: req,
                                    depth: row.depth,
                                    bundle: bundle,
                                    isSelected: req.id == selectedRequest?.id,
                                    isDirty: req.id == selectedRequest?.id && isDirty
                                )
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                Button {
                    Task { await createRequest(workspaceId: bundle.workspace.id, folderId: nil) }
                } label: {
                    Label("New request", systemImage: "plus")
                }
                Button {
                    openNewFolderSheet(parentFolder: nil)
                } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                }
                Divider()
                Button {
                    model.importTarget = HttpScreenModel.ImportTarget(folder: nil, tab: .curl)
                } label: {
                    Label("Import cURL\u{2026}", systemImage: "square.and.arrow.up")
                }
                Button {
                    model.importTarget = HttpScreenModel.ImportTarget(folder: nil, tab: .bru)
                } label: {
                    Label("Import collection\u{2026}", systemImage: "square.and.arrow.up")
                }
            }
        }
        .background(HttpStyle.sidebarBackground(theme))
    }

    private func folderRow(
        folder: HttpFolder,
        depth: Int,
        isCollapsed: Bool,
        childCount: Int,
        bundle: HttpWorkspaceBundle
    ) -> some View {
        let isSelected = model.selectedFolderId == folder.id && model.selectedRequestId == nil
        return HStack(spacing: 6) {
            Button {
                if model.collapsedFolders.contains(folder.id) {
                    model.collapsedFolders.remove(folder.id)
                } else {
                    model.collapsedFolders.insert(folder.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand folder" : "Collapse folder")

            Button {
                model.selectedFolderId = folder.id
                model.collapsedFolders.remove(folder.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.tertiaryText)
                    Text(folder.name)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(isSelected ? theme.palette.text : theme.palette.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(isSelected ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button {
                model.collapsedFolders.remove(folder.id)
                Task { await createRequest(workspaceId: bundle.workspace.id, folderId: folder.id) }
            } label: {
                Label("New request", systemImage: "plus")
            }
            Button {
                model.collapsedFolders.remove(folder.id)
                openNewFolderSheet(parentFolder: folder)
            } label: {
                Label("New folder", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                model.importTarget = HttpScreenModel.ImportTarget(folder: folder, tab: .curl)
            } label: {
                Label("Import cURL\u{2026}", systemImage: "square.and.arrow.up")
            }
            Button {
                model.importTarget = HttpScreenModel.ImportTarget(folder: folder, tab: .bru)
            } label: {
                Label("Import collection\u{2026}", systemImage: "square.and.arrow.up")
            }
            Button {
                model.selectedFolderId = folder.id
                model.viewMode = .authEnv
            } label: {
                Label("Folder auth & headers\u{2026}", systemImage: "slider.horizontal.3")
            }
            Divider()
            Button {
                openRenameSheet(.folder(folder))
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            Button(role: .destructive) {
                model.pendingDelete = .folder(folder)
            } label: {
                Label("Delete folder", systemImage: "trash")
            }
        }
    }

    private func requestRow(
        req: HttpRequest,
        depth: Int,
        bundle: HttpWorkspaceBundle,
        isSelected: Bool,
        isDirty: Bool
    ) -> some View {
        let findMatch = context.find.matches(Self.searchText(req))
        let rowBg: Color = isSelected ? theme.palette.selected : (findMatch ? theme.palette.hover : .clear)

        return Button {
            model.selectRequest(req)
        } label: {
            HStack(spacing: 8) {
                HttpMethodBadge(method: req.method)
                Text(req.name)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(isSelected ? theme.palette.text : theme.palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isDirty {
                    Circle()
                        .fill(theme.swiftUIColor("state-human", fallback: .orange))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 20)
            .padding(.trailing, 8)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBg, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await createRequest(workspaceId: bundle.workspace.id, folderId: req.folderId) }
            } label: {
                Label("New request here", systemImage: "plus")
            }
            Button {
                Task { await duplicateRequest(req, workspaceId: bundle.workspace.id) }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Button {
                openRenameSheet(.request(req))
            } label: {
                Label("Rename\u{2026}", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                model.pendingDelete = .request(req)
            } label: {
                Label("Delete request", systemImage: "trash")
            }
        }
    }

    // MARK: - Main Editor Area

    @ViewBuilder
    private func mainEditorArea(
        bundle: HttpWorkspaceBundle,
        selectedRequest: HttpRequest?,
        isDirty: Bool,
        history: [HttpExecution],
        execsEntry: QueryEntry<HttpExecutionList>?,
        activeExecution: HttpExecution?,
        secrets: [API.ApiSecret]
    ) -> some View {
        if let selectedRequest, let draftBinding = draftBinding(for: selectedRequest) {
            let activeEnv = bundle.environments.first { $0.id == bundle.workspace.activeEnvironmentId }

            VStack(spacing: 0) {
                requestHeaderBar(
                    bundle: bundle,
                    activeEnv: activeEnv,
                    draft: draftBinding,
                    selectedRequest: selectedRequest,
                    isDirty: isDirty
                )

                Divider().overlay(theme.palette.border)

                GeometryReader { proxy in
                    let sideBySide = proxy.size.width >= 820
                    if sideBySide {
                        HStack(spacing: 0) {
                            HttpRequestPane(
                                draft: draftBinding,
                                selectedTab: $model.reqTab,
                                bundle: bundle,
                                secrets: secrets
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            Divider().overlay(theme.palette.border)

                            HttpResponsePane(
                                activeExecution: activeExecution,
                                history: history,
                                isRunning: model.isSending,
                                isLoadingHistory: execsEntry?.isFetching ?? false,
                                historyError: execsEntry?.error,
                                onRetryHistory: {
                                    Task {
                                        await context.store.refetch(
                                            HttpClientAPI.listRequestExecutions(requestId: selectedRequest.id, limit: 25)
                                        )
                                    }
                                },
                                onSelectExecution: { exec in
                                    model.latestExecutionRequestId = selectedRequest.id
                                    model.latestExecution = exec
                                    model.respTab = .body
                                },
                                selectedTab: $model.respTab
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        VStack(spacing: 0) {
                            HttpRequestPane(
                                draft: draftBinding,
                                selectedTab: $model.reqTab,
                                bundle: bundle,
                                secrets: secrets
                            )
                            .frame(minHeight: 240, maxHeight: .infinity)

                            Divider().overlay(theme.palette.border)

                            HttpResponsePane(
                                activeExecution: activeExecution,
                                history: history,
                                isRunning: model.isSending,
                                isLoadingHistory: execsEntry?.isFetching ?? false,
                                historyError: execsEntry?.error,
                                onRetryHistory: {
                                    Task {
                                        await context.store.refetch(
                                            HttpClientAPI.listRequestExecutions(requestId: selectedRequest.id, limit: 25)
                                        )
                                    }
                                },
                                onSelectExecution: { exec in
                                    model.latestExecutionRequestId = selectedRequest.id
                                    model.latestExecution = exec
                                    model.respTab = .body
                                },
                                selectedTab: $model.respTab
                            )
                            .frame(minHeight: 240, maxHeight: .infinity)
                        }
                    }
                }
            }
        } else {
            HttpEmptyState(
                icon: "powerplug",
                title: "Select or create a request",
                message: "External hosts only in v1, with workspace auth inheritance and active environment substitution."
            ) {
                Button {
                    Task { await createRequest(workspaceId: bundle.workspace.id, folderId: nil) }
                } label: {
                    Label("New Request", systemImage: "plus")
                }
                .buttonStyle(.vesper(.primary))

                Button {
                    model.importTarget = HttpScreenModel.ImportTarget(folder: nil, tab: .bru)
                } label: {
                    Label("Import .bru / cURL / OpenAPI", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.vesper())
            }
        }
    }

    private func requestHeaderBar(
        bundle: HttpWorkspaceBundle,
        activeEnv: HttpEnvironment?,
        draft: Binding<HttpRequestDraft>,
        selectedRequest: HttpRequest,
        isDirty: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Request name", text: draft.name)
                    .textFieldStyle(.plain)
                    .font(theme.font(.heading))
                    .foregroundStyle(theme.palette.text)

                if isDirty {
                    TonePill(label: "Unsaved changes", tone: "human")
                }

                Button {
                    Task { await saveCurrentRequest(request: selectedRequest) }
                } label: {
                    HStack(spacing: 6) {
                        if model.isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text("Save")
                        KeyCap(key: "\u{2318}S")
                    }
                }
                .buttonStyle(.vesper())
                .disabled(!isDirty || model.isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }

            HStack(spacing: 8) {
                let currentMethod = draft.wrappedValue.method.uppercased()
                let methodOptions = HttpClientLogic.methods.contains(currentMethod)
                    ? HttpClientLogic.methods
                    : HttpClientLogic.methods + [currentMethod]

                Picker(
                    "HTTP method",
                    selection: Binding(
                        get: { draft.wrappedValue.method.uppercased() },
                        set: { draft.wrappedValue.method = $0 }
                    )
                ) {
                    ForEach(methodOptions, id: \.self) { method in
                        Text(method).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: theme.pointSize(.body), weight: .bold, design: .monospaced))
                .foregroundStyle(HttpStyle.methodColor(currentMethod, theme: theme))
                .frame(width: 108)

                TextField("{{base_url}}/v1/resource", text: draft.url)
                    .httpInputBox(theme, mono: true)
                    .onSubmit {
                        Task { await sendCurrentRequest(request: selectedRequest, bundle: bundle) }
                    }

                Button {
                    Task { await sendCurrentRequest(request: selectedRequest, bundle: bundle) }
                } label: {
                    HStack(spacing: 6) {
                        if model.isSending {
                            ProgressView().controlSize(.small)
                            Text("Sending\u{2026}")
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                            Text("Send")
                            KeyCap(key: "\u{2318}\u{21B5}")
                        }
                    }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(model.isSending)
                .keyboardShortcut(.return, modifiers: .command)
            }

            if draft.wrappedValue.url.contains("{{") {
                let resolution = HttpClientLogic.interpolatePreview(
                    draft.wrappedValue.url,
                    workspace: bundle.workspace,
                    activeEnvironment: activeEnv
                )
                HStack(spacing: 8) {
                    Text(resolution.resolved)
                        .font(theme.font(.mono))
                        .foregroundStyle(theme.palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    if !resolution.secretReferences.isEmpty {
                        Label("\(resolution.secretReferences.count) secret", systemImage: "lock.fill")
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }

                    if !resolution.unresolvedVariables.isEmpty {
                        TonePill(
                            label: "Unresolved: \(resolution.unresolvedVariables.joined(separator: ", "))",
                            tone: "human"
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.palette.surface)
    }

    // MARK: - Sheets

    private var newWorkspaceSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New HTTP Workspace")
                .vesperText(.heading, theme)
            HttpField(
                label: "Workspace name",
                hint: "Seeds nonprod and prod environments automatically."
            ) {
                TextField("Billing API", text: $model.newWorkspaceName)
                    .httpInputBox(theme)
                    .onSubmit {
                        Task { await createWorkspace() }
                    }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.showNewWorkspaceSheet = false
                    model.newWorkspaceName = ""
                }
                .buttonStyle(.vesper())
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await createWorkspace() }
                } label: {
                    if model.isMutating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create Workspace")
                    }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(model.isMutating || model.newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(theme.palette.background)
    }

    private func newFolderSheet(target: HttpScreenModel.NewFolderTarget, workspaceId: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.parentFolderName.map { "New Folder in \u{201C}\($0)\u{201D}" } ?? "New Folder")
                .vesperText(.heading, theme)
            HttpField(label: "Folder name") {
                TextField("Authentication", text: $model.newFolderName)
                    .httpInputBox(theme)
                    .onSubmit {
                        if let workspaceId {
                            Task { await createFolder(workspaceId: workspaceId, parentFolderId: target.parentFolderId) }
                        }
                    }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.newFolderTarget = nil
                    model.newFolderName = ""
                }
                .buttonStyle(.vesper())
                .keyboardShortcut(.cancelAction)

                Button {
                    if let workspaceId {
                        Task { await createFolder(workspaceId: workspaceId, parentFolderId: target.parentFolderId) }
                    }
                } label: {
                    if model.isMutating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create Folder")
                    }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(model.isMutating || model.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(theme.palette.background)
    }

    private func renameSheet(target: HttpScreenModel.RenameTarget, workspaceId: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.title)
                .vesperText(.heading, theme)
            HttpField(label: "Name") {
                TextField("Name", text: $model.renameText)
                    .httpInputBox(theme)
                    .onSubmit {
                        if let workspaceId {
                            Task { await performRename(target, workspaceId: workspaceId) }
                        }
                    }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.renameTarget = nil
                    model.renameText = ""
                }
                .buttonStyle(.vesper())
                .keyboardShortcut(.cancelAction)

                Button {
                    if let workspaceId {
                        Task { await performRename(target, workspaceId: workspaceId) }
                    }
                } label: {
                    if model.isMutating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(model.isMutating || model.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(theme.palette.background)
    }

    // MARK: - Helpers & Draft Sync

    private func modeSwitchButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: theme.pointSize(.small), weight: .medium))
            .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(active ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
            .buttonStyle(.plain)
    }

    private static func searchText(_ req: HttpRequest) -> String {
        "\(req.method) \(req.name) \(req.url)"
    }

    private func draftBinding(for request: HttpRequest) -> Binding<HttpRequestDraft>? {
        guard model.draftRequestId == request.id, let current = model.draft else {
            return nil
        }
        return Binding(
            get: { model.draft ?? current },
            set: { model.draft = $0 }
        )
    }

    private func syncDraft(with request: HttpRequest?) {
        guard let request else {
            model.draftRequestId = nil
            model.draft = nil
            model.lastLoadedDraft = nil
            model.latestExecutionRequestId = nil
            model.latestExecution = nil
            return
        }
        let serverDraft = HttpClientLogic.toDraft(request)
        if model.draftRequestId != request.id {
            model.draftRequestId = request.id
            model.draft = serverDraft
            model.lastLoadedDraft = serverDraft
            model.latestExecutionRequestId = nil
            model.latestExecution = nil
        } else if model.draft == model.lastLoadedDraft && serverDraft != model.lastLoadedDraft {
            // Pick up external edits (rename, live update) without clobbering unsaved typing.
            model.draft = serverDraft
            model.lastLoadedDraft = serverDraft
        }
    }

    private func updateWatchedQueries(workspaceId: String?, requestId: String?) {
        let store = context.store
        for key in watchedKeys {
            store.stopObserving(key)
        }
        func start<V: Sendable>(_ request: APIRequest<V>) -> QueryKey {
            store.observe(request)
            store.load(request)
            return request.key
        }
        var next = [start(Self.workspacesReq), start(Self.secretsReq)]
        if let workspaceId {
            next.append(start(HttpClientAPI.getWorkspaceBundle(id: workspaceId)))
        }
        if let requestId {
            next.append(start(HttpClientAPI.listRequestExecutions(requestId: requestId, limit: 25)))
        }
        watchedKeys = next
    }

    // MARK: - Toolbar Commands

    private func handleToolbarCommand(_ command: NativeCommand) {
        guard case .toolbarAction(let itemId, let menuItemId) = command else { return }
        let workspaces = context.store.entry(Self.workspacesReq).data?.workspaces ?? []
        let effectiveWsId = HttpClientLogic.effectiveWorkspaceId(
            workspaces: workspaces,
            selectedId: model.selectedWorkspaceId,
            rememberedId: model.rememberedWorkspaceId
        )
        let bundle = effectiveWsId.flatMap { context.store.entry(HttpClientAPI.getWorkspaceBundle(id: $0)).data }
        let activeRequestId = HttpClientLogic.effectiveRequest(bundle: bundle, selectedRequestId: model.selectedRequestId)?.id

        switch itemId {
        case HttpClientChrome.workspaceMenuId:
            if let menuItemId, let wsId = HttpClientChrome.parseWorkspaceItemId(menuItemId) {
                model.switchWorkspace(wsId)
            }
        case HttpClientChrome.newWorkspaceId:
            model.newWorkspaceName = ""
            model.showNewWorkspaceSheet = true
        case HttpClientChrome.deleteWorkspaceId:
            if let bundle {
                model.pendingDelete = .workspace(bundle.workspace)
            }
        case HttpClientChrome.environmentMenuId:
            if let bundle, let menuItemId, let parsedEnvId = HttpClientChrome.parseEnvironmentItemId(menuItemId) {
                Task { await setActiveEnvironment(workspaceId: bundle.workspace.id, environmentId: parsedEnvId) }
            }
        case HttpClientChrome.importId:
            if bundle != nil {
                model.importTarget = HttpScreenModel.ImportTarget(folder: nil, tab: .bru)
            }
        case HttpClientChrome.authEnvToggleId:
            if bundle != nil {
                model.viewMode = model.viewMode == .authEnv ? .requests : .authEnv
            }
        case HttpClientChrome.refreshId:
            Task {
                await refreshAll(workspaceId: bundle?.workspace.id ?? effectiveWsId, requestId: activeRequestId)
            }
        default:
            break
        }
    }

    // MARK: - API Actions

    private func refreshAll(workspaceId: String?, requestId: String?) async {
        _ = await context.store.refetch(Self.workspacesReq)
        _ = await context.store.refetch(Self.secretsReq)
        if let workspaceId {
            _ = await context.store.refetch(HttpClientAPI.getWorkspaceBundle(id: workspaceId))
        }
        if let requestId {
            _ = await context.store.refetch(HttpClientAPI.listRequestExecutions(requestId: requestId, limit: 25))
        }
    }

    private func createWorkspace() async {
        guard !model.isMutating else { return }
        let name = model.newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.isMutating = true
        defer { model.isMutating = false }

        let input = HttpWorkspaceInput(
            name: name,
            defaultAuth: .none,
            seedEnvironments: true
        )
        do {
            let created = try await context.store.mutate(
                HttpClientAPI.createWorkspace(input),
                invalidating: HttpClientAPI.workspacesInvalidation
            )
            context.store.setData(created, for: HttpClientAPI.getWorkspaceBundle(id: created.workspace.id))
            model.switchWorkspace(created.workspace.id)
            model.showNewWorkspaceSheet = false
            model.newWorkspaceName = ""
            showToast(id: "http.ws.create", title: "Workspace \"\(created.workspace.name)\" created", tone: .success)
        } catch {
            showToast(
                id: "http.ws.create",
                title: "Failed to create workspace",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func setActiveEnvironment(workspaceId: String, environmentId: String?) async {
        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: workspaceId)
        do {
            _ = try await context.store.mutate(
                HttpClientAPI.setActiveEnvironment(workspaceId: workspaceId, environmentId: environmentId),
                optimistic: [
                    .update(bundleReq) { $0.workspace.activeEnvironmentId = environmentId },
                    .update(Self.workspacesReq) { list in
                        for i in list.workspaces.indices where list.workspaces[i].id == workspaceId {
                            list.workspaces[i].activeEnvironmentId = environmentId
                        }
                    },
                ],
                invalidating: HttpClientAPI.workspacesInvalidation
            )
            context.store.invalidate(HttpClientAPI.bundleInvalidation(workspaceId: workspaceId))
        } catch {
            showToast(
                id: "http.env.switch",
                title: "Failed to switch environment",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func openNewFolderSheet(parentFolder: HttpFolder?) {
        model.newFolderName = ""
        model.newFolderTarget = HttpScreenModel.NewFolderTarget(
            parentFolderId: parentFolder?.id,
            parentFolderName: parentFolder?.name
        )
    }

    private func createFolder(workspaceId: String, parentFolderId: String?) async {
        guard !model.isMutating else { return }
        let name = model.newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.isMutating = true
        defer { model.isMutating = false }

        let input = HttpFolderInput(
            parentFolderId: parentFolderId,
            name: name,
            defaultAuth: .inherit
        )
        do {
            let created = try await context.store.mutate(
                HttpClientAPI.createFolder(workspaceId: workspaceId, body: input),
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
            )
            model.selectedFolderId = created.id
            if let parentFolderId {
                model.collapsedFolders.remove(parentFolderId)
            }
            model.newFolderTarget = nil
            model.newFolderName = ""
            showToast(id: "http.folder.create", title: "Folder \"\(created.name)\" created", tone: .success)
        } catch {
            showToast(
                id: "http.folder.create",
                title: "Failed to create folder",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func createRequest(workspaceId: String, folderId: String?) async {
        let draft = HttpClientLogic.newRequestDraft(folderId: folderId)
        do {
            let created = try await context.store.mutate(
                HttpClientAPI.createRequest(workspaceId: workspaceId, body: draft),
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
            )
            if let folderId {
                model.collapsedFolders.remove(folderId)
            }
            model.selectRequest(created)
        } catch {
            showToast(
                id: "http.req.create",
                title: "Failed to create request",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func duplicateRequest(_ source: HttpRequest, workspaceId: String) async {
        var copy = HttpClientLogic.toDraft(source)
        copy.name = "\(source.name) Copy"
        do {
            let created = try await context.store.mutate(
                HttpClientAPI.createRequest(workspaceId: workspaceId, body: copy),
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
            )
            model.selectRequest(created)
        } catch {
            showToast(
                id: "http.req.duplicate",
                title: "Failed to duplicate request",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func openRenameSheet(_ target: HttpScreenModel.RenameTarget) {
        model.renameText = target.currentName
        model.renameTarget = target
    }

    private func performRename(_ target: HttpScreenModel.RenameTarget, workspaceId: String) async {
        guard !model.isMutating else { return }
        let name = model.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.isMutating = true
        defer { model.isMutating = false }

        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: workspaceId)
        do {
            switch target {
            case .folder(let folder):
                let input = HttpFolderInput(
                    parentFolderId: folder.parentFolderId,
                    name: name,
                    defaultAuth: folder.defaultAuth,
                    defaultHeaders: folder.defaultHeaders,
                    sortOrder: folder.sortOrder
                )
                _ = try await context.store.mutate(
                    HttpClientAPI.updateFolder(id: folder.id, body: input),
                    optimistic: [
                        .update(bundleReq) { b in
                            for i in b.folders.indices where b.folders[i].id == folder.id {
                                b.folders[i].name = name
                            }
                        },
                    ],
                    invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
                )

            case .request(let req):
                var draft = (model.draftRequestId == req.id ? model.draft : nil) ?? HttpClientLogic.toDraft(req)
                draft.name = name
                let updated = try await context.store.mutate(
                    HttpClientAPI.updateRequest(id: req.id, body: draft),
                    optimistic: [
                        .update(bundleReq) { b in
                            for i in b.requests.indices where b.requests[i].id == req.id {
                                b.requests[i].name = name
                            }
                        },
                    ],
                    invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
                )
                if model.draftRequestId == req.id {
                    let savedDraft = HttpClientLogic.toDraft(updated)
                    model.draft = savedDraft
                    model.lastLoadedDraft = savedDraft
                }
            }
            model.renameTarget = nil
            model.renameText = ""
        } catch {
            showToast(
                id: "http.rename",
                title: "Rename failed",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func performDelete(_ target: HttpScreenModel.DeleteTarget, workspaceId: String?) async {
        model.pendingDelete = nil
        switch target {
        case .workspace(let ws):
            do {
                _ = try await context.store.mutate(
                    HttpClientAPI.deleteWorkspace(id: ws.id),
                    optimistic: [
                        .update(Self.workspacesReq) { list in
                            list.workspaces.removeAll { $0.id == ws.id }
                        },
                    ],
                    invalidating: HttpClientAPI.workspacesInvalidation
                )
                if model.selectedWorkspaceId == ws.id {
                    model.selectedWorkspaceId = nil
                }
                if model.rememberedWorkspaceId == ws.id {
                    model.rememberedWorkspaceId = nil
                    UserDefaults.standard.removeObject(forKey: HttpScreenModel.workspaceDefaultsKey)
                }
                model.selectedFolderId = nil
                model.selectedRequestId = nil
                model.draftRequestId = nil
                model.draft = nil
                model.lastLoadedDraft = nil
                model.latestExecutionRequestId = nil
                model.latestExecution = nil
                showToast(id: "http.ws.delete", title: "Workspace deleted", tone: .success)
            } catch {
                showToast(
                    id: "http.ws.delete",
                    title: "Failed to delete workspace",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                )
            }

        case .folder(let folder):
            guard let workspaceId else { return }
            let bundleReq = HttpClientAPI.getWorkspaceBundle(id: workspaceId)
            do {
                _ = try await context.store.mutate(
                    HttpClientAPI.deleteFolder(id: folder.id),
                    optimistic: [
                        .update(bundleReq) { b in
                            b.folders.removeAll { $0.id == folder.id }
                            b.requests.removeAll { $0.folderId == folder.id }
                        },
                    ],
                    invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
                )
                if model.selectedFolderId == folder.id {
                    model.selectedFolderId = nil
                }
                showToast(id: "http.folder.delete", title: "Folder deleted", tone: .success)
            } catch {
                showToast(
                    id: "http.folder.delete",
                    title: "Failed to delete folder",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                )
            }

        case .request(let req):
            guard let workspaceId else { return }
            let bundleReq = HttpClientAPI.getWorkspaceBundle(id: workspaceId)
            do {
                _ = try await context.store.mutate(
                    HttpClientAPI.deleteRequest(id: req.id),
                    optimistic: [
                        .update(bundleReq) { b in
                            b.requests.removeAll { $0.id == req.id }
                        },
                    ],
                    invalidating: HttpClientAPI.bundleInvalidation(workspaceId: workspaceId)
                )
                if model.selectedRequestId == req.id {
                    model.selectedRequestId = nil
                    model.draftRequestId = nil
                    model.draft = nil
                    model.lastLoadedDraft = nil
                    model.latestExecutionRequestId = nil
                    model.latestExecution = nil
                }
                showToast(id: "http.req.delete", title: "Request deleted", tone: .success)
            } catch {
                showToast(
                    id: "http.req.delete",
                    title: "Failed to delete request",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                )
            }
        }
    }

    private func saveCurrentRequest(request: HttpRequest) async {
        guard !model.isSaving, var draft = model.draft, model.draftRequestId == request.id else { return }
        draft.timeoutMs = HttpClientLogic.clampTimeoutMs(draft.timeoutMs)
        model.isSaving = true
        defer { model.isSaving = false }

        let bundleReq = HttpClientAPI.getWorkspaceBundle(id: request.httpWorkspaceId)
        do {
            let saved = try await context.store.mutate(
                HttpClientAPI.updateRequest(id: request.id, body: draft),
                optimistic: [
                    .update(bundleReq) { b in
                        for i in b.requests.indices where b.requests[i].id == request.id {
                            b.requests[i].folderId = draft.folderId
                            b.requests[i].name = draft.name
                            b.requests[i].method = draft.method
                            b.requests[i].url = draft.url
                            b.requests[i].params = draft.params
                            b.requests[i].headers = draft.headers
                            b.requests[i].auth = draft.auth
                            b.requests[i].bodyMode = draft.bodyMode
                            b.requests[i].body = draft.body
                            b.requests[i].bodyForm = draft.bodyForm
                            b.requests[i].timeoutMs = draft.timeoutMs
                            b.requests[i].followRedirects = draft.followRedirects
                        }
                    },
                ],
                invalidating: HttpClientAPI.bundleInvalidation(workspaceId: request.httpWorkspaceId)
            )
            let savedDraft = HttpClientLogic.toDraft(saved)
            model.draftRequestId = saved.id
            model.draft = savedDraft
            model.lastLoadedDraft = savedDraft
            showToast(id: "http.req.save", title: "Request saved", tone: .success)
        } catch {
            showToast(
                id: "http.req.save",
                title: "Failed to save request",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func sendCurrentRequest(request: HttpRequest, bundle: HttpWorkspaceBundle) async {
        guard !model.isSending, var draft = model.draft, model.draftRequestId == request.id else { return }
        guard let client = context.store.client else {
            showToast(id: "http.req.send", title: APIError.unauthorized.userMessage, tone: .error)
            return
        }
        draft.timeoutMs = HttpClientLogic.clampTimeoutMs(draft.timeoutMs)

        model.isSending = true
        defer { model.isSending = false }

        let options = HttpRunRequestOptions(
            environmentId: bundle.workspace.activeEnvironmentId,
            override: draft
        )
        let apiTimeout = HttpClientLogic.runTimeoutSeconds(timeoutMs: draft.timeoutMs)
        do {
            let execution = try await client.send(
                HttpClientAPI.runRequest(requestId: request.id, options: options),
                timeout: apiTimeout
            )
            model.latestExecutionRequestId = request.id
            model.latestExecution = execution
            model.respTab = .body
            context.store.invalidate(HttpClientAPI.executionsInvalidation(requestId: request.id))
            if let err = execution.error, !err.isEmpty {
                showToast(id: "http.req.send", title: err, tone: .error)
            }
        } catch {
            showToast(
                id: "http.req.send",
                title: "Request failed",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            )
        }
    }

    private func showToast(id: String, title: String, description: String? = nil, tone: ToastTone) {
        context.showToast(ToastItemModel(id: id, title: title, description: description, tone: tone))
    }
}
