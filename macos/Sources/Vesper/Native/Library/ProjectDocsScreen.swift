import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

private struct ArtifactRow: Identifiable, Equatable {
    let artifact: API.ArtifactSummary
    var id: String { artifact.id }
}

/// What an Upload or New mockup sheet starts with.
struct ArtifactSheetRequest: Identifiable {
    enum Kind { case upload([URL]), mockup, newVersion(API.Artifact) }
    let id = UUID()
    let kind: Kind
}

/// Library › From spaces: what agents read before they work and the reports they leave, from
/// GET /artifacts (web library/_components/project-docs.tsx).
struct ProjectDocsScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var type = "all"
    @State private var project = ""
    /// The search, from the sidebar's field (which already waits for typing to pause).
    @State private var query = ""
    @State private var selection: Set<String> = []
    @State private var sheet: ArtifactSheetRequest?
    @State private var dropping = false

    private static let bootstrap = API.getBootstrap()
    private static let pickSpace = "pick-space"
    private static let openSpace = "space-open"

    private var request: APIRequest<API.ArtifactList> {
        API.listArtifacts(type: type == "all" ? nil : API.ArtifactType(rawValue: type),
                          project: project.isEmpty ? nil : project, q: query.isEmpty ? nil : query)
    }

    private var selected: String? { selection.count == 1 ? selection.first : nil }

    var body: some View {
        let entry = context.store.entry(request)
        let rows = (entry.data?.artifacts ?? []).map(ArtifactRow.init)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                LibraryHeading(description: "Shared with the workspace: context agents read before they work, and the reports they leave behind.")
                dropZone
                table(entry: entry, rows: rows)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let selected {
                Divider().overlay(theme.palette.border)
                ArtifactPreviewPane(id: selected, close: { selection = [] }, newVersion: { sheet = ArtifactSheetRequest(kind: .newVersion($0)) })
                    .id(selected)
                    .frame(width: 360)
                    .background(theme.swiftUIColor("panel", fallback: theme.palette.surface))
            }
        }
        .sheet(item: $sheet) { request in
            switch request.kind {
            case .upload(let files):
                ArtifactUploadSheet(initialFiles: files, defaultProject: project) { created in
                    type = "all"
                    query = ""
                    selection = [created.id]
                }
            case .mockup:
                NewMockupSheet(defaultProject: project)
            case .newVersion(let artifact):
                NewVersionSheet(artifact: artifact)
            }
        }
        .onChange(of: context.match, initial: true) { _, match in applyRoute(match) }
        .onChange(of: entry.data?.counts) { _, _ in publishChrome() }
        .onChange(of: context.store.entry(Self.bootstrap).data?.projects.map(\.name)) { _, _ in publishChrome() }
        .onChange(of: request.key, initial: true) { old, new in
            if old != new { context.store.stopObserving(old) }
            context.store.load(request)
            context.store.observe(request)
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            selection.formIntersection(ids)
            context.find.texts = rows.map { Self.searchText($0.artifact) }
        }
        .task { context.store.load(Self.bootstrap) }
        .onAppear {
            publishChrome()
            context.onCommand = { command in handle(command) }
        }
        .onDisappear { context.store.stopObserving(request.key) }
    }

    private static func searchText(_ a: API.ArtifactSummary) -> String {
        [LibraryLogic.artifactTitle(title: a.title, displayId: a.displayId), a.path ?? "", a.author.name, a.project?.name ?? ""].joined(separator: " ")
    }

    // MARK: Route and chrome

    private func applyRoute(_ match: NativeRouteMatch) {
        type = match.query["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "all"
        project = match.query["project"] ?? ""
        query = match.query["q"] ?? ""
        selection = match.query["id"].map { [$0] } ?? []
        publishChrome()
    }

    private func publishChrome() {
        let projects = (context.store.entry(Self.bootstrap).data?.projects ?? []).filter { !$0.archived }
        let current = projects.first { $0.key == project }
        var menu: [MenuItem] = [MenuItem(id: "space:", label: "All spaces", icon: "folder", checked: current == nil), MenuItem(id: "sep-all", separator: true)]
        menu += projects.map { MenuItem(id: "space:\($0.key)", label: $0.name, checked: $0.key == project) }
        menu += [MenuItem(id: "sep-open", separator: true),
                 MenuItem(id: Self.openSpace, label: current.map { "Open \($0.name)" } ?? "New space", icon: current == nil ? "plus" : "gear")]
        let action = NavAction(id: Self.pickSpace, label: "Space: \(current?.name ?? "All spaces")", icon: "folder", menu: menu)
        context.chrome = NativeChrome(
            title: "Library",
            subtitle: "From spaces",
            toolbarItems: [
                ShellToolbarItem(id: "docs.mockup", label: "New mockup", icon: "plus", kind: .button, showsLabel: true),
                ShellToolbarItem(id: "docs.upload", label: "Upload", icon: "upload", kind: .button, accent: true, showsLabel: true),
            ],
            navigator: LibraryLogic.projectDocsNavigator(type: type, counts: context.store.entry(request).data?.counts,
                                                          search: query, projectAction: action))
    }

    private func handle(_ command: NativeCommand) {
        switch command {
        case .toolbarAction(itemId: "docs.mockup", _): sheet = ArtifactSheetRequest(kind: .mockup)
        case .toolbarAction(itemId: "docs.upload", _): sheet = ArtifactSheetRequest(kind: .upload([]))
        case .navActivate(_, let itemId, let newTab):
            if newTab {
                context.openInNewTab(LibraryLogic.projectDocsHref(type: itemId, q: query, project: project, id: nil))
            } else {
                type = itemId
                selection = []
                publishChrome()
            }
        case .navSearch(_, LibraryLogic.searchId, let value):
            query = value
            publishChrome()
        case .navPicker(_, LibraryLogic.sourcePickerId, let value):
            context.navigate(LibraryLogic.sourceHref(LibraryLogic.Source(rawValue: value) ?? .projects))
        case .navAction(_, Self.pickSpace, _, let menuItemId?):
            if menuItemId == Self.openSpace {
                let current = context.store.entry(Self.bootstrap).data?.projects.first { $0.key == project }
                context.navigate(current?.spaceId.map { "/spaces/\($0)" } ?? "/spaces/new?work=1")
            } else if menuItemId.hasPrefix("space:") {
                project = String(menuItemId.dropFirst("space:".count))
                selection = []
                publishChrome()
            }
        default: break
        }
    }

    // MARK: Drop zone and table

    private var dropZone: some View {
        Button { sheet = ArtifactSheetRequest(kind: .upload([])) } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 32, height: 32)
                    .background(theme.palette.selected, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.swiftUIColor("border-strong", fallback: theme.palette.border)))
                    .foregroundStyle(theme.palette.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drop PRDs, specs or ADRs here").fontWeight(.medium)
                    Text("Markdown, PDF or images. Markdown is split into sections so agents can cite them.")
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(dropping ? theme.swiftUIColor("accent-soft", fallback: theme.palette.selected) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropping ? theme.palette.accent : theme.swiftUIColor("border-strong", fallback: theme.palette.border),
                                                                     style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let file = URL(dataRepresentation: url, relativeTo: nil) { urls.append(file) }
                }
                if !urls.isEmpty { sheet = ArtifactSheetRequest(kind: .upload(urls)) }
            }
            return true
        }
    }

    @ViewBuilder
    private func table(entry: QueryEntry<API.ArtifactList>, rows: [ArtifactRow]) -> some View {
        if entry.data == nil, let error = entry.error {
            QueryErrorView(message: "Couldn\u{2019}t load artifacts: \(error.userMessage)") {
                Task { await context.store.refetch(request) }
            }
        } else if entry.data == nil {
            VStack(spacing: 12) { ForEach(0..<5, id: \.self) { _ in SkeletonBar(height: 40) } }
        } else if rows.isEmpty {
            VStack(spacing: 12) {
                LibraryEmptyState(icon: "doc.text", title: query.isEmpty ? "No artifacts yet" : "No artifacts match",
                                  message: query.isEmpty ? "Upload a PRD, spec or ADR so agents can read it before they work." : "Search covers titles, summaries and document text.")
                if query.isEmpty {
                    Button { sheet = ArtifactSheetRequest(kind: .upload([])) } label: { Label("Upload", systemImage: "square.and.arrow.up") }.buttonStyle(.vesper())
                }
            }
            .frame(maxWidth: .infinity)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
        } else {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in nameCell(row.artifact) }
                TableColumn("Author") { row in AuthorCell(author: row.artifact.author) }.width(min: 120, ideal: 150)
                TableColumn("Project") { row in
                    if let p = row.artifact.project {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(cssHex: p.color) ?? .gray).frame(width: 10, height: 10)
                            Text(p.name).lineLimit(1)
                        }
                        .foregroundStyle(theme.palette.secondaryText)
                    } else {
                        Text("Workspace").foregroundStyle(theme.palette.tertiaryText)
                    }
                }
                .width(min: 120, ideal: 170)
                TableColumn("Tickets") { row in
                    Text(row.artifact.ticketCount > 0 ? "\(row.artifact.ticketCount)" : "\u{2013}")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.secondaryText)
                }
                .width(60)
                TableColumn("Updated") { row in
                    Text(APIDate.shortAgo(row.artifact.updatedAt))
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .help(APIDate.parse(row.artifact.updatedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(80)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Open") { context.navigate("/artifacts/\(id)") }
                    Button("Open in New Tab") { context.openInNewTab("/artifacts/\(id)") }
                    Button("Show Preview") { selection = [id] }
                }
            } primaryAction: { ids in
                if let id = ids.first { context.navigate("/artifacts/\(id)") }
            }
            .font(.system(size: theme.pointSize(.body)))
            .frame(minHeight: 320, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
        }
    }

    private func nameCell(_ a: API.ArtifactSummary) -> some View {
        HStack(spacing: 12) {
            DocTypeTag(type: a.type.rawValue).frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(LibraryLogic.artifactTitle(title: a.title, displayId: a.displayId)).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    Text(a.path ?? LibraryLogic.artifactMeta(a)).lineLimit(1)
                    if let review = a.reviewState { ReviewChip(state: review) }
                }
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.tertiaryText)
            }
            .background(context.find.matches(Self.searchText(a)) ? theme.palette.hover : .clear)
        }
        .padding(.vertical, 4)
    }
}

/// The artifact type chip (web DocTypeTag): `bg-doc-<type>-bg text-doc-<type>`.
struct DocTypeTag: View {
    @Environment(\.vesperTheme) private var theme
    let type: String

    var body: some View {
        Text(type)
            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
            .foregroundStyle(theme.swiftUIColor("doc-\(type)", fallback: theme.palette.secondaryText))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.swiftUIColor("doc-\(type)-bg", fallback: theme.palette.selected), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// A mockup's review state (web ReviewChip).
struct ReviewChip: View {
    let state: API.MockupReviewState

    var body: some View {
        switch state.rawValue {
        case "approved": TonePill(label: "Approved", tone: "done")
        case "changes_requested": TonePill(label: "Changes requested", tone: "blocked")
        default: TonePill(label: "Needs review", tone: "human")
        }
    }
}

/// An artifact's author: the agent as its persona, or the person's initials.
struct AuthorCell: View {
    @Environment(\.vesperTheme) private var theme
    let author: API.Actor

    var body: some View {
        HStack(spacing: 8) {
            if author.type == .agent {
                WorkPersonaAvatarView(id: author.id, handle: nil, name: author.name, colorIndex: author.colorIndex ?? 0, size: 20)
            } else {
                Text(author.initials ?? String(author.name.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color(cssHex: author.avatarColor) ?? .gray, in: Circle())
            }
            Text(author.name).lineLimit(1)
        }
    }
}
