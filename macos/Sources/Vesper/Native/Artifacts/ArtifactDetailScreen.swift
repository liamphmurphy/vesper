import AVKit
import AppKit
import SwiftUI
import VesperCore

/// Native SwiftUI implementation of `/artifacts/:id`.
/// Renders markdown, images, inline MP4 videos, PDFs, generic files, and SVG mockups natively,
/// including the direct-manipulation SVG visual/source/split editor (`?edit=1` on mockups).
struct ArtifactDetailScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var selectedVersionId: String?
    @State private var oldVersionBody: String?
    @State private var loadingOldVersion = false
    @State private var showingNewVersionSheet = false
    @State private var editingSummary = false
    @State private var summaryDraft = ""
    @State private var savingSummary = false
    @State private var startingChat = false

    private var artifactId: String { context.match.params["id"] ?? "" }
    private var wantsEdit: Bool { context.match.query["edit"] == "1" }
    private var showVersions: Bool { context.match.query["versions"] != nil }

    var body: some View {
        let req = API.getArtifact(id: artifactId)
        let entry = context.store.entry(req)
        let backlinksReq = API.getBacklinks(kind: .artifact, id: artifactId)
        let backlinks = context.store.entry(backlinksReq).data

        Group {
            if let error = entry.error {
                errorView(error)
            } else if let artifact = entry.data {
                if artifact.type == .mockup && wantsEdit {
                    MockupEditorView(artifact: artifact) {
                        context.navigate("/artifacts/\(artifact.id)")
                    }
                } else {
                    loadedView(artifact: artifact, backlinks: backlinks)
                }
            } else {
                loadingSkeleton
            }
        }
        .background(theme.palette.background)
        .onAppear {
            selectedVersionId = context.match.query["version"]
            context.store.load(req)
            context.store.observe(req)
            context.store.load(backlinksReq)
            bindCommands(artifact: entry.data)
            syncChrome(artifact: entry.data, backlinks: backlinks)
        }
        .onDisappear {
            context.store.stopObserving(req.key)
            context.onCommand = nil
        }
        .onChange(of: artifactId) { oldId, newId in
            context.store.stopObserving(API.getArtifact(id: oldId).key)
            selectedVersionId = context.match.query["version"]
            oldVersionBody = nil
            editingSummary = false
            let next = API.getArtifact(id: newId)
            context.store.load(next)
            context.store.observe(next)
            context.store.load(API.getBacklinks(kind: .artifact, id: newId))
        }
        .onChange(of: entry.data) { _, artifact in
            if let artifact, let redirect = ArtifactDetailLogic.wikiRedirectPath(type: artifact.type, path: artifact.path, showVersions: showVersions) {
                context.navigate(redirect)
                return
            }
            syncChrome(artifact: artifact, backlinks: backlinks)
            bindCommands(artifact: artifact)
        }
        .onChange(of: backlinks) { _, nextLinks in
            syncChrome(artifact: entry.data, backlinks: nextLinks)
        }
        .onChange(of: wantsEdit) { _, _ in
            syncChrome(artifact: entry.data, backlinks: backlinks)
            bindCommands(artifact: entry.data)
        }
        .onChange(of: selectedVersionId) { _, _ in
            syncChrome(artifact: entry.data, backlinks: backlinks)
            bindCommands(artifact: entry.data)
        }
        .task(id: "\(artifactId)|\(selectedVersionId ?? "")|\(entry.data?.currentVersion.id ?? "")") {
            await loadOldVersionIfNeeded(artifact: entry.data)
        }
        .sheet(isPresented: $showingNewVersionSheet) {
            if let artifact = entry.data {
                NewVersionSheet(artifact: artifact)
                    .environment(context)
                    .environment(\.vesperTheme, theme)
            }
        }
    }

    private func viewingVersion(for artifact: API.Artifact) -> API.ArtifactVersion {
        if let id = selectedVersionId, let match = artifact.versions.first(where: { $0.id == id }) {
            return match
        }
        return artifact.currentVersion
    }

    private func syncChrome(artifact: API.Artifact?, backlinks: API.Backlinks?) {
        let nav = ArtifactDetailLogic.navModel(
            artifact: artifact,
            selectedVersionId: selectedVersionId,
            backlinks: backlinks
        )
        guard let artifact else {
            context.chrome = NativeChrome(title: "Artifact", navigator: nav)
            return
        }
        let title = LibraryLogic.artifactTitle(title: artifact.title, displayId: artifact.displayId)
        if artifact.type == .mockup && wantsEdit {
            context.chrome = NativeChrome(
                title: title,
                subtitle: "Editing",
                toolbarItems: [
                    ShellToolbarItem(id: "artifact.doneEdit", label: "Done", icon: "checkmark", kind: .button, showsLabel: true),
                ],
                navigator: nav
            )
            return
        }
        let viewing = viewingVersion(for: artifact)
        let isMockup = artifact.type == .mockup
        let isMarkdown = viewing.content.kind.rawValue == "markdown"
        var items: [ShellToolbarItem] = []
        if isMockup {
            items.append(ShellToolbarItem(id: "artifact.review", label: "Review", icon: "eye", kind: .button, showsLabel: true))
            items.append(ShellToolbarItem(id: "artifact.edit", label: "Edit", icon: "pencil", kind: .button, showsLabel: true))
        }
        items.append(ShellToolbarItem(id: "artifact.chat", label: "Start chat", icon: "bubble.left", kind: .button, showsLabel: true))
        items.append(ShellToolbarItem(id: "artifact.newVersion", label: "New version", icon: "plus.square.on.square", kind: .button, showsLabel: false))
        items.append(ShellToolbarItem(id: "artifact.download", label: "Download", icon: "arrow.down.circle", kind: .button, showsLabel: false))
        if !isMockup && isMarkdown {
            items.append(ShellToolbarItem(id: "artifact.exportPdf", label: "Export PDF", icon: "printer", kind: .button, showsLabel: false))
        }
        context.chrome = NativeChrome(
            title: title,
            subtitle: artifact.project?.name,
            toolbarItems: items,
            navigator: nav
        )
    }

    private func bindCommands(artifact: API.Artifact?) {
        context.onCommand = { cmd in
            if let navAction = ArtifactDetailLogic.navAction(for: cmd) {
                switch navAction {
                case .backToLibrary:
                    context.navigate("/library")
                case .selectVersion(let versionId):
                    selectedVersionId = versionId
                case .openLink(let href, let newTab):
                    if newTab { context.openInNewTab(href) } else { context.navigate(href) }
                }
                return
            }
            guard let artifact, case .toolbarAction(let itemId, _) = cmd else { return }
            let viewing = viewingVersion(for: artifact)
            let isOld = viewing.id != artifact.currentVersion.id
            switch itemId {
            case "artifact.doneEdit":
                context.navigate("/artifacts/\(artifact.id)")
            case "artifact.edit":
                context.navigate("/artifacts/\(artifact.id)?edit=1")
            case "artifact.review":
                let q = isOld ? "?version=\(viewing.id)" : ""
                context.navigate("/artifacts/\(artifact.id)/review\(q)")
            case "artifact.newVersion":
                showingNewVersionSheet = true
            case "artifact.download":
                let filename = viewing.content.filename ?? "\(LibraryLogic.artifactTitle(title: artifact.title, displayId: artifact.displayId)).md"
                LibraryFiles.saveCopy(
                    path: ArtifactDetailLogic.contentPath(artifactId: artifact.id, versionId: viewing.id, download: true),
                    filename: filename,
                    contentType: viewing.content.contentType,
                    client: context.store.client,
                    context: context
                )
            case "artifact.exportPdf":
                let q = isOld ? "?version=\(viewing.id)" : ""
                context.openInNewTab("/print/artifacts/\(artifact.id)\(q)")
            case "artifact.chat":
                Task { await startChat(for: artifact) }
            default:
                break
            }
        }
    }

    private func startChat(for artifact: API.Artifact) async {
        guard let client = context.store.client, !startingChat else { return }
        startingChat = true
        defer { startingChat = false }
        do {
            let chat = try await client.send(API.createChat(body: API.NewChat(project: artifact.project?.key)))
            let kind = artifact.type == .note ? "page" : "artifact"
            let title = LibraryLogic.artifactTitle(title: artifact.title, displayId: artifact.displayId)
            let q = CommandPaletteLogic.attachQuery(project: nil, kind: kind, idOrKey: artifact.id, title: title)
            context.navigate("/chat/\(chat.id)?\(q)")
        } catch {
            context.showToast(ToastItemModel(
                id: "artifact.chat.err",
                title: "Couldn\u{2019}t start chat",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            ))
        }
    }

    private func loadOldVersionIfNeeded(artifact: API.Artifact?) async {
        guard let artifact else { return }
        let viewing = viewingVersion(for: artifact)
        let isOld = viewing.id != artifact.currentVersion.id
        guard isOld, viewing.content.kind.rawValue == "markdown" || artifact.type == .mockup else {
            oldVersionBody = nil
            return
        }
        guard let client = context.store.client else { return }
        loadingOldVersion = true
        defer { loadingOldVersion = false }
        let path = ArtifactDetailLogic.contentPath(artifactId: artifact.id, versionId: viewing.id)
        if let data = try? await client.request("GET", path, headers: ["Accept": "*/*"], timeout: 60),
           let text = String(data: data, encoding: .utf8) {
            oldVersionBody = text
        } else {
            oldVersionBody = nil
        }
    }

    private func loadedView(artifact: API.Artifact, backlinks: API.Backlinks?) -> some View {
        let viewing = viewingVersion(for: artifact)
        let isOld = viewing.id != artifact.currentVersion.id
        let isMockup = artifact.type == .mockup
        let bodyText = isOld ? oldVersionBody : artifact.bodyMd

        return HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            DocTypeTag(type: artifact.type.rawValue)
                            Text(viewing.label)
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                        Text(LibraryLogic.artifactTitle(title: artifact.title, displayId: artifact.displayId))
                            .vesperText(.display, theme)
                            .textSelection(.enabled)

                        summaryView(artifact: artifact)
                    }

                    if isOld {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Viewing \(viewing.label), not the current version")
                                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                                    .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                                Text("Agents always read the current version (\(artifact.currentVersion.label)).")
                                    .font(.system(size: theme.pointSize(.small)))
                                    .foregroundStyle(theme.palette.secondaryText)
                            }
                            Spacer()
                            Button("Back to \(artifact.currentVersion.label)") {
                                selectedVersionId = nil
                            }
                            .buttonStyle(.vesper(.outline))
                        }
                        .padding(12)
                        .background(theme.swiftUIColor("pill-human-bg", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                    }

                    if isMockup {
                        MockupReviewBannerView(artifact: artifact, version: viewing, isOld: isOld)
                    }

                    Divider().overlay(theme.palette.border)

                    if isMockup {
                        MockupDetailViewer(artifactId: artifact.id, versionId: viewing.id, title: artifact.title, source: bodyText, isLoading: loadingOldVersion)
                    } else if viewing.content.kind.rawValue == "file" {
                        ArtifactFileBodyView(artifact: artifact, version: viewing)
                    } else if loadingOldVersion || bodyText == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            SkeletonBar(height: 16).frame(width: 280)
                            SkeletonBar(height: 12)
                            SkeletonBar(height: 12).frame(width: 340)
                        }
                    } else if let bodyText {
                        MarkdownView(markdown: bodyText, textStyle: .reading, anchors: true, chat: false)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider().overlay(theme.palette.border)

            detailsSidebar(artifact: artifact, viewing: viewing, isOld: isOld, backlinks: backlinks)
                .frame(width: 320)
                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
        }
    }

    @ViewBuilder
    private func summaryView(artifact: API.Artifact) -> some View {
        if editingSummary {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $summaryDraft)
                    .font(.system(size: theme.pointSize(.body)))
                    .frame(height: 76)
                    .padding(4)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                HStack {
                    Spacer()
                    Button("Cancel") { editingSummary = false }
                        .buttonStyle(.vesper(.outline))
                        .keyboardShortcut(.cancelAction)
                    Button(savingSummary ? "Saving\u{2026}" : "Save") {
                        Task { await saveSummary(artifact: artifact) }
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(savingSummary)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } else {
            Button {
                summaryDraft = artifact.summary
                editingSummary = true
            } label: {
                Text(artifact.summary.isEmpty ? "Add a summary\u{2026}" : artifact.summary)
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(artifact.summary.isEmpty ? theme.palette.tertiaryText : theme.palette.secondaryText)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .help("Click to edit summary")
        }
    }

    private func saveSummary(artifact: API.Artifact) async {
        guard let client = context.store.client else { return }
        if summaryDraft == artifact.summary {
            editingSummary = false
            return
        }
        savingSummary = true
        defer { savingSummary = false }
        do {
            _ = try await client.send(API.updateArtifact(id: artifact.id, body: API.UpdateArtifactBody(summary: summaryDraft)))
            context.store.invalidate(QueryInvalidation(resources: ["artifacts"]))
            await context.store.refetch(API.getArtifact(id: artifact.id))
            editingSummary = false
        } catch {
            context.showToast(ToastItemModel(
                id: "artifact.summary.err",
                title: "Couldn\u{2019}t save summary",
                description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                tone: .error
            ))
        }
    }

    private func detailsSidebar(artifact: API.Artifact, viewing: API.ArtifactVersion, isOld: Bool, backlinks: API.Backlinks?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if artifact.type != .mockup, !artifact.outline.isEmpty, !isOld {
                    railSection("Outline \u{00B7} citations") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(artifact.outline, id: \.id) { section in
                                HStack(spacing: 8) {
                                    Text(section.heading)
                                        .font(.system(size: theme.pointSize(.small), weight: section.level == 1 ? .medium : .regular))
                                        .lineLimit(1)
                                        .padding(.leading, CGFloat(max(0, section.level - 1)) * 10)
                                    Spacer()
                                    if section.citations > 0 {
                                        Text("\(section.citations)")
                                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                            .foregroundStyle(theme.palette.secondaryText)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                railSection("Read by") {
                    if artifact.readBy.isEmpty {
                        Text("No agent has read this yet.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(artifact.readBy, id: \.agent.id) { reader in
                                HStack(spacing: 8) {
                                    WorkPersonaAvatarView(agent: reader.agent, size: 18)
                                    Text(reader.agent.name)
                                        .font(.system(size: theme.pointSize(.small)))
                                    Spacer()
                                    Text("\(reader.reads) read\(reader.reads == 1 ? "" : "s")")
                                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                        .foregroundStyle(theme.palette.tertiaryText)
                                }
                            }
                        }
                    }
                }

                railSection("Backlinks") {
                    let linked = backlinks?.linked ?? []
                    if linked.isEmpty {
                        Text("No backlinks yet.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(linked.enumerated()), id: \.offset) { _, mention in
                                Button {
                                    if let href = mention.source.href, !href.isEmpty {
                                        context.navigate(href)
                                    }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mention.source.title)
                                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                                            .foregroundStyle(theme.palette.accent)
                                            .lineLimit(1)
                                        if let snippet = mention.snippets.first, !snippet.isEmpty {
                                            Text(snippet)
                                                .font(.system(size: theme.pointSize(.micro)))
                                                .foregroundStyle(theme.palette.tertiaryText)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                railSection("Tickets") {
                    if artifact.tickets.isEmpty {
                        Text("Not attached to any ticket. Attach it from a ticket\u{2019}s Context artifacts.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(artifact.tickets, id: \.key) { ticket in
                                Button {
                                    context.navigate("/tickets/\(ticket.key)")
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(ticket.key)
                                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                            .foregroundStyle(theme.palette.tertiaryText)
                                            .frame(width: 68, alignment: .leading)
                                        Text(ticket.title)
                                            .font(.system(size: theme.pointSize(.small)))
                                            .foregroundStyle(theme.palette.text)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                railSection("History") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(artifact.versions, id: \.id) { version in
                            let on = version.id == viewing.id
                            Button {
                                selectedVersionId = version.id == artifact.currentVersion.id ? nil : version.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(version.label)
                                            .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                                        if version.id == artifact.currentVersion.id {
                                            Text("current")
                                                .font(.system(size: theme.pointSize(.micro)))
                                                .foregroundStyle(theme.swiftUIColor("pill-done-fg", fallback: .green))
                                        }
                                        if let review = version.review {
                                            ReviewChip(state: review.state)
                                        }
                                        Spacer()
                                        Text(APIDate.shortAgo(version.createdAt))
                                            .font(.system(size: theme.pointSize(.micro)))
                                            .foregroundStyle(theme.palette.tertiaryText)
                                    }
                                    Text(version.note.isEmpty ? version.createdBy.name : "\(version.createdBy.name) \u{00B7} \(version.note)")
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(theme.palette.tertiaryText)
                                        .lineLimit(1)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(on ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func railSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.tertiaryText)
            content()
        }
    }

    private func errorView(_ error: APIError) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .http(let status, _) = error, status == 404 {
                Text("This artifact doesn\u{2019}t exist").vesperText(.heading, theme)
                Text("It may have been removed, or the link is wrong.")
                    .foregroundStyle(theme.palette.secondaryText)
                Button("Back to Library") { context.navigate("/library?source=projects") }
                    .buttonStyle(.vesper(.outline))
            } else {
                QueryErrorView(message: error.userMessage) {
                    Task { await context.store.refetch(API.getArtifact(id: artifactId)) }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonBar(height: 28).frame(width: 320)
            SkeletonBar(height: 16).frame(width: 480)
            SkeletonBar(height: 260)
        }
        .frame(maxWidth: 780, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Artifact File Body

private struct ArtifactFileBodyView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let artifact: API.Artifact
    let version: API.ArtifactVersion

    @State private var pdfModel = PDFViewerModel()
    @State private var videoPlayer: AVPlayer?
    @State private var videoError: String?

    private var contentPath: String {
        ArtifactDetailLogic.contentPath(artifactId: artifact.id, versionId: version.id)
    }

    private var downloadPath: String {
        ArtifactDetailLogic.contentPath(artifactId: artifact.id, versionId: version.id, download: true)
    }

    private var quickLookItem: QuickLookItem {
        QuickLookItem(
            url: contentPath,
            title: LibraryLogic.artifactTitle(title: artifact.title, displayId: artifact.displayId),
            filename: version.content.filename ?? artifact.title,
            contentType: version.content.contentType
        )
    }

    var body: some View {
        let content = version.content
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button {
                    context.showQuickLook([quickLookItem], index: 0)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                .buttonStyle(.vesper(.outline))
            }

            if ArtifactDetailLogic.isImage(contentType: content.contentType) {
                LibraryImageView(path: contentPath, maxPixel: nil, fill: false)
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 560)
                    .background(theme.palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            } else if ArtifactDetailLogic.isInlineVideo(contentType: content.contentType) {
                ZStack {
                    if let videoPlayer {
                        VideoPlayer(player: videoPlayer)
                            .frame(minHeight: 360, maxHeight: 560)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let videoError {
                        Text(videoError).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .task(id: contentPath) {
                    guard let client = context.store.client else { return }
                    do {
                        let local = try await LibraryFiles.localFile(
                            path: contentPath,
                            filename: content.filename ?? "\(artifact.title).mp4",
                            contentType: content.contentType,
                            client: client
                        )
                        videoPlayer = AVPlayer(url: local)
                    } catch {
                        videoError = (error as? APIError)?.userMessage ?? error.localizedDescription
                    }
                }
            } else if ArtifactDetailLogic.isPDF(contentType: content.contentType, filename: content.filename) {
                PDFViewerView(model: pdfModel) {
                    Task { await pdfModel.load(path: contentPath, client: context.store.client) }
                }
                .frame(height: 620)
                .task(id: contentPath) {
                    await pdfModel.load(path: contentPath, client: context.store.client)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(content.filename ?? artifact.title).vesperText(.heading, theme)
                    Text("\(LibraryLogic.fileKind(contentType: content.contentType, filename: content.filename)) \u{00B7} \(LibraryLogic.formatBytes(content.sizeBytes)). This file type can\u{2019}t be previewed inline.")
                        .foregroundStyle(theme.palette.secondaryText)
                    Button("Download") {
                        LibraryFiles.saveCopy(
                            path: downloadPath,
                            filename: content.filename ?? artifact.title,
                            contentType: content.contentType,
                            client: context.store.client,
                            context: context
                        )
                    }
                    .buttonStyle(.vesper(.outline))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            }
        }
    }
}

// MARK: - Mockup Banner & SVG Viewer

private struct MockupReviewBannerView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let artifact: API.Artifact
    let version: API.ArtifactVersion
    let isOld: Bool

    @State private var requestingChanges = false
    @State private var note = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let review = version.review
        let state = review?.state ?? .pending

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ReviewChip(state: state)
                Text(version.label)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                if let reviewer = review?.reviewedBy {
                    Text(reviewer.name)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                    if let reviewedAt = review?.reviewedAt {
                        Text("\u{00B7} \(APIDate.shortAgo(reviewedAt))")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                }
                Spacer()
                if !isOld {
                    Button("Approve") {
                        Task { await submit(decision: .approved, note: nil) }
                    }
                    .buttonStyle(.vesper(.approve))
                    .disabled(state == .approved || busy)

                    Button("Request changes") {
                        requestingChanges = true
                    }
                    .buttonStyle(.vesper(.approveOutline))
                    .disabled(busy || requestingChanges)
                }
            }

            if let noteText = review?.note, !noteText.isEmpty {
                Text("\u{201C}\(noteText)\u{201D}")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.text)
            }
            if isOld {
                Text("Only the current version can be reviewed.")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(theme.palette.tertiaryText)
            } else if state == .pending {
                Text("Agents that need an approved mockup wait for this review.")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }

            if requestingChanges && !isOld {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What needs to change?")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(theme.palette.secondaryText)
                    TextEditor(text: $note)
                        .font(.system(size: theme.pointSize(.body)))
                        .frame(height: 76)
                        .padding(4)
                        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                    HStack {
                        Spacer()
                        Button("Cancel") { requestingChanges = false }
                            .buttonStyle(.vesper(.outline))
                        Button("Send feedback") {
                            Task { await submit(decision: .changesRequested, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        }
                        .buttonStyle(.vesper(.primary))
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(14)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }

    private func submit(decision: API.ReviewArtifactVersionBody.Decision, note: String?) async {
        guard let client = context.store.client, !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let source = version.id == artifact.currentVersion.id
                ? artifact.bodyMd
                : await MockupRendering.source(client: client, artifactId: artifact.id, versionId: version.id)
            _ = try await MockupRendering.review(client: client, artifactId: artifact.id, versionId: version.id,
                                                 source: source, decision: decision, note: note)
            context.store.invalidate(QueryInvalidation(resources: ["artifacts", "tickets", "epics"]))
            await context.store.refetch(API.getArtifact(id: artifact.id))
            requestingChanges = false
            self.note = ""
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

/// Renders an SVG mockup natively with Fit / 100% / 200% zoom; a version outside mockup SVG profile
/// v1 is simplified to draw and labelled legacy.
struct MockupDetailViewer: View {
    @Environment(\.vesperTheme) private var theme
    let artifactId: String
    let versionId: String
    let title: String
    let source: String?
    let isLoading: Bool

    @State private var zoom: ArtifactDetailLogic.MockupZoomMode = .fit
    @State private var image: NSImage?
    @State private var intrinsicSize: CGSize = CGSize(width: 1280, height: 800)
    @State private var failed = false
    @State private var legacy: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let legacy {
                    MockupLegacyLabel(dropped: legacy)
                }
                Spacer()
                Picker("Zoom", selection: $zoom) {
                    ForEach(ArtifactDetailLogic.MockupZoomMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            if isLoading || (source != nil && image == nil && !failed) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Rendering mockup\u{2026}")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            } else if let image {
                Group {
                    if zoom == .fit {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 580)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        let factor: CGFloat = zoom == .double ? 2.0 : 1.0
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: intrinsicSize.width * factor, height: intrinsicSize.height * factor)
                                .background(Color.white)
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 620)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
                .accessibilityLabel(title)
            } else {
                Text("Couldn\u{2019}t render this mockup SVG.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            }
        }
        .task(id: "\(artifactId)|\(versionId)|\(source?.hashValue ?? 0)") {
            await renderSVG()
        }
    }

    private func renderSVG() async {
        guard let source, !source.isEmpty else {
            image = nil
            return
        }
        failed = false
        let parsed = ArtifactDetailLogic.svgSize(source)
        intrinsicSize = CGSize(width: parsed.width, height: parsed.height)
        if let drawing = MockupRendering.draw(source: source) {
            intrinsicSize = CGSize(width: drawing.size.width, height: drawing.size.height)
            image = drawing.image
            legacy = drawing.isLegacy ? drawing.dropped : nil
        } else if let fallback = NSImage(data: Data(source.utf8)) {
            image = fallback
        } else {
            failed = true
        }
    }
}

/// Marks a mockup drawn by WebKit because its SVG predates profile v1.
struct MockupLegacyLabel: View {
    /// What simplifying the version left out (`MockupSVGSimplified.dropped`).
    var dropped: [String] = []
    @Environment(\.vesperTheme) private var theme

    var body: some View {
        Label("Legacy SVG \u{00B7} simplified to draw", systemImage: "clock.arrow.circlepath")
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(theme.palette.tertiaryText)
            .help("This version uses SVG outside mockup profile v1, so it\u{2019}s shown simplified"
                + (dropped.isEmpty ? "" : " (left out: \(dropped.joined(separator: ", ")))")
                + ". Edit it to bring it into the profile.")
    }
}
