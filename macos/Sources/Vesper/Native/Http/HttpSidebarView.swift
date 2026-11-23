import SwiftUI
import VesperCore

/// Publishes HTTP Client's collection tree sidebar with reactive theme and context environment.
struct HttpSidebarHost: View {
    let context: NativeScreenContext
    let model: HttpScreenModel

    var body: some View {
        HttpCollectionSidebarView(model: model)
            .environment(context)
            .environment(\.vesperTheme, model.theme)
            .environment(\.colorScheme, model.colorScheme)
    }
}

/// Native left-hand sidebar for `/http`: workspace & environment pickers, Requests / Auth & Env
/// mode switcher, filter box, and hierarchical folder/request collection tree with method badges.
struct HttpCollectionSidebarView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Bindable var model: HttpScreenModel

    private static let workspacesReq = HttpClientAPI.listWorkspaces()

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
        let bundle = bundleReq.flatMap { store.entry($0).data }
        let selectedRequest = HttpClientLogic.effectiveRequest(
            bundle: bundle,
            selectedRequestId: model.selectedRequestId
        )
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

        VStack(spacing: 0) {
            headerBar(workspaces: workspaces, bundle: bundle)

            if let bundle {
                controls(workspaces: workspaces, bundle: bundle)
                Divider().overlay(theme.palette.border)
                treeList(
                    bundle: bundle,
                    visibleRows: visibleRows,
                    selectedRequest: selectedRequest,
                    isDirty: isDirty
                )
            } else if workspacesEntry.data == nil && workspacesEntry.error == nil {
                Divider().overlay(theme.palette.border)
                VStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { _ in SkeletonBar(height: 20) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if workspaces.isEmpty {
                Divider().overlay(theme.palette.border)
                VStack(spacing: 8) {
                    Text("No workspaces yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("New workspace") {
                        model.newWorkspaceName = "Default API"
                        model.showNewWorkspaceSheet = true
                    }
                    .buttonStyle(.vesper(.primary))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Divider().overlay(theme.palette.border)
                VStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in SkeletonBar(height: 20) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headerBar(workspaces: [HttpWorkspace], bundle: HttpWorkspaceBundle?) -> some View {
        HStack(spacing: 6) {
            Text("HTTP Client")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let bundle {
                Button {
                    Task { await model.createRequest(in: context, workspaceId: bundle.workspace.id, folderId: model.selectedFolderId) }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("New request")
                .accessibilityLabel("New request")

                Button {
                    model.openNewFolderSheet(parentFolder: model.selectedFolderId.flatMap { id in
                        bundle.folders.first(where: { $0.id == id })
                    })
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("New folder")
                .accessibilityLabel("New folder")
            } else {
                Button {
                    model.newWorkspaceName = ""
                    model.showNewWorkspaceSheet = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .help("New workspace")
                .accessibilityLabel("New workspace")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private func controls(workspaces: [HttpWorkspace], bundle: HttpWorkspaceBundle) -> some View {
        let activeEnv = bundle.environments.first { $0.id == bundle.workspace.activeEnvironmentId }

        return VStack(spacing: 6) {
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
                    HStack(spacing: 5) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(bundle.workspace.name)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)

                Menu {
                    Button {
                        Task { await model.setActiveEnvironment(in: context, workspaceId: bundle.workspace.id, environmentId: nil) }
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
                            Task { await model.setActiveEnvironment(in: context, workspaceId: bundle.workspace.id, environmentId: env.id) }
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
                    HStack(spacing: 4) {
                        Circle()
                            .fill(activeEnv.map { HttpStyle.envColor($0.color, theme: theme) } ?? theme.palette.tertiaryText)
                            .frame(width: 6, height: 6)
                        Text(activeEnv?.name ?? "No env")
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            }

            Picker("Mode", selection: $model.viewMode) {
                Text("Requests").tag(HttpScreenModel.ViewMode.requests)
                Text("Auth & Env").tag(HttpScreenModel.ViewMode.authEnv)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter calls\u{2026}", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(theme.font(.small))
                if !model.filter.isEmpty {
                    Button {
                        model.filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func treeList(
        bundle: HttpWorkspaceBundle,
        visibleRows: [HttpClientLogic.HttpTreeRow],
        selectedRequest: HttpRequest?,
        isDirty: Bool
    ) -> some View {
        ScrollView {
            if bundle.folders.isEmpty && bundle.requests.isEmpty {
                VStack(spacing: 8) {
                    Text("No requests yet.")
                        .vesperText(.small, theme)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button("New Request") {
                            Task { await model.createRequest(in: context, workspaceId: bundle.workspace.id, folderId: nil) }
                        }
                        .buttonStyle(.vesper(.primary))
                        Button("Import") {
                            model.importTarget = HttpScreenModel.ImportTarget(folder: nil, tab: .bru)
                        }
                        .buttonStyle(.vesper())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
            } else if visibleRows.isEmpty {
                Text("No requests match \u{201C}\(model.filter)\u{201D}.")
                    .vesperText(.small, theme)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 1) {
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
                                isSelected: model.viewMode == .requests && req.id == selectedRequest?.id,
                                isDirty: req.id == selectedRequest?.id && isDirty
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            Button {
                Task { await model.createRequest(in: context, workspaceId: bundle.workspace.id, folderId: nil) }
            } label: {
                Label("New request", systemImage: "plus")
            }
            Button {
                model.openNewFolderSheet(parentFolder: nil)
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

    private func folderRow(
        folder: HttpFolder,
        depth: Int,
        isCollapsed: Bool,
        childCount: Int,
        bundle: HttpWorkspaceBundle
    ) -> some View {
        let isSelected = model.selectedFolderId == folder.id && model.selectedRequestId == nil
        return HStack(spacing: 5) {
            Button {
                if model.collapsedFolders.contains(folder.id) {
                    model.collapsedFolders.remove(folder.id)
                } else {
                    model.collapsedFolders.insert(folder.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand folder" : "Collapse folder")

            Button {
                model.selectedFolderId = folder.id
                model.collapsedFolders.remove(folder.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(folder.name)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(isSelected ? theme.palette.text : theme.palette.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button {
                model.collapsedFolders.remove(folder.id)
                Task { await model.createRequest(in: context, workspaceId: bundle.workspace.id, folderId: folder.id) }
            } label: {
                Label("New request", systemImage: "plus")
            }
            Button {
                model.collapsedFolders.remove(folder.id)
                model.openNewFolderSheet(parentFolder: folder)
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
                model.openRenameSheet(.folder(folder))
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
        let findMatch = context.find.matches(HttpScreenModel.searchText(req))
        let rowBg: Color = isSelected
            ? Color.accentColor.opacity(0.16)
            : (findMatch ? theme.palette.hover : .clear)

        return Button {
            model.selectRequest(req)
        } label: {
            HStack(spacing: 6) {
                HttpMethodBadge(method: req.method)
                Text(req.name)
                    .font(.system(size: theme.pointSize(.small), weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? theme.palette.text : theme.palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isDirty {
                    Circle()
                        .fill(theme.swiftUIColor("state-human", fallback: .orange))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + 18)
            .padding(.trailing, 8)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBg, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task { await model.createRequest(in: context, workspaceId: bundle.workspace.id, folderId: req.folderId) }
            } label: {
                Label("New request here", systemImage: "plus")
            }
            Button {
                Task { await model.duplicateRequest(in: context, source: req, workspaceId: bundle.workspace.id) }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Button {
                model.openRenameSheet(.request(req))
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
}
