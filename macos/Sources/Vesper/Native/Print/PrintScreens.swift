import AppKit
import SwiftUI
import VesperCore

/// Native SwiftUI print preview + macOS print/PDF dialog for `/print/knowledge/:id`.
struct PrintKnowledgeScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var style: KnowledgePrintStyle = .clean
    @State private var showMetadata = false
    @State private var didAutoPrint = false
    @State private var images = PrintImages()

    private var pageId: String { context.match.params["id"] ?? "" }
    private var initialStyle: KnowledgePrintStyle {
        KnowledgePrintStyle(rawValue: (context.match.query["style"] ?? "").lowercased()) ?? .clean
    }

    var body: some View {
        let p = theme.palette
        let pageReq = KnowledgeAPI.getPage(id: pageId)
        let pageEntry = context.store.entry(pageReq)
        let page = pageEntry.data
        let hasQuery = page?.properties["query"] != nil
        let queryEntry = hasQuery ? context.store.entry(KnowledgeAPI.getSavedQuery(id: pageId)) : nil
        let printable = page.map { $0.kind == .document } ?? false
        let document = page.flatMap { page in
            printable ? PrintDocumentBuilder.knowledgeDocument(page: page, style: style, showMetadata: showMetadata, savedQuery: queryEntry?.data) : nil
        }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    context.navigate("/knowledge/\(pageId)")
                } label: {
                    Label("Back to page", systemImage: "chevron.left")
                }
                .buttonStyle(.vesper(.outline))

                HStack(spacing: 2) {
                    ForEach(KnowledgePrintStyle.allCases, id: \.self) { s in
                        Button(s.label) { style = s }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: style == s ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(style == s ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(style == s ? p.text : p.secondaryText)
                    }
                }
                .padding(3)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))

                Toggle("Include metadata", isOn: $showMetadata)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)

                Spacer(minLength: 8)

                Button {
                    if let document { NativePrint.run(document, images: images.loaded, in: context.window()?.window) }
                } label: {
                    Label("Print / Save as PDF", systemImage: "printer")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(document == nil || !images.ready)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(p.surface)

            Divider().overlay(p.border)

            if let error = pageEntry.error {
                QueryErrorView(message: error.userMessage) { context.store.load(pageReq) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let page {
                if !printable {
                    VStack(spacing: 12) {
                        Text("Decks and designs export from their own editor.")
                            .vesperText(.heading, theme)
                        Button("Return to \(page.title.isEmpty ? "page" : page.title)") {
                            context.navigate("/knowledge/\(page.id)")
                        }
                        .buttonStyle(.vesper(.primary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let document {
                    PrintPreview(document: document, images: images.loaded)
                        .task(id: document.imageURLs) {
                            await images.load(document.imageURLs, client: context.store.client)
                            guard !didAutoPrint else { return }
                            didAutoPrint = true
                            NativePrint.run(document, images: images.loaded, in: context.window()?.window)
                        }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .onAppear {
            style = initialStyle
            context.store.load(pageReq)
            syncChrome(title: page?.title)
        }
        .onChange(of: pageId) { _, nextId in
            didAutoPrint = false
            context.store.load(KnowledgeAPI.getPage(id: nextId))
        }
        .onChange(of: page?.id) { _, _ in
            if let page, page.properties["query"] != nil {
                context.store.load(KnowledgeAPI.getSavedQuery(id: page.id))
            }
            syncChrome(title: page?.title)
        }
        .onChange(of: style) { _, _ in
            syncChrome(title: page?.title)
        }
    }

    private func syncChrome(title: String?) {
        let docTitle = (title?.isEmpty == false ? title! : "Untitled")
        context.chrome = NativeChrome(title: docTitle, subtitle: "PDF · \(style.label)")
    }
}

/// Native SwiftUI print preview + macOS print/PDF dialog for `/print/artifacts/:id`.
struct PrintArtifactScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var oldVersionBody: String?
    @State private var loadingOldVersion = false
    @State private var didAutoPrint = false
    @State private var images = PrintImages()

    private var artifactId: String { context.match.params["id"] ?? "" }
    private var requestedVersionId: String? { context.match.query["version"] }

    var body: some View {
        let p = theme.palette
        let req = API.getArtifact(id: artifactId)
        let entry = context.store.entry(req)
        let artifact = entry.data
        let viewing = artifact.map { a in
            if let vid = requestedVersionId, let match = a.versions.first(where: { $0.id == vid }) { return match }
            return a.currentVersion
        }
        let isOld = artifact != nil && viewing != nil && viewing?.id != artifact?.currentVersion.id
        let printable = artifact?.type != .mockup && viewing?.content.kind.rawValue == "markdown"
        let bodyMarkdown = isOld ? oldVersionBody : artifact?.bodyMd
        let title = artifact.map { LibraryLogic.artifactTitle(title: $0.title, displayId: $0.displayId) } ?? "Artifact"
        let document = artifact.flatMap { artifact -> PrintDocument? in
            guard printable, let viewing, let bodyMarkdown else { return nil }
            var document = PrintDocumentBuilder.artifactDocument(
                title: title,
                versionLabel: viewing.label,
                authorName: viewing.createdBy.name,
                createdAt: viewing.createdAt,
                summary: artifact.summary,
                bodyMarkdown: bodyMarkdown
            )
            // An older version's job and running header say which version it is.
            if isOld { document.title = "\(title) (\(viewing.label))" }
            return document
        }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    let q = isOld, vid = viewing?.id ?? ""
                    context.navigate("/artifacts/\(artifactId)\(q ? "?version=\(vid)" : "")")
                } label: {
                    Label("Back to artifact", systemImage: "chevron.left")
                }
                .buttonStyle(.vesper(.outline))

                Spacer(minLength: 8)

                Button {
                    if let document { NativePrint.run(document, images: images.loaded, in: context.window()?.window) }
                } label: {
                    Label("Print / Save as PDF", systemImage: "printer")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(document == nil || !images.ready)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(p.surface)

            Divider().overlay(p.border)

            if let error = entry.error {
                QueryErrorView(message: error.userMessage) { context.store.load(req) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if artifact != nil, viewing != nil {
                if !printable {
                    VStack(spacing: 12) {
                        Text("Only markdown artifacts export to PDF.")
                            .vesperText(.heading, theme)
                        Text("Use Download on the artifact page for files and mockups.")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let document {
                    PrintPreview(document: document, images: images.loaded)
                        .task(id: document.imageURLs) {
                            await images.load(document.imageURLs, client: context.store.client)
                            guard !didAutoPrint else { return }
                            didAutoPrint = true
                            NativePrint.run(document, images: images.loaded, in: context.window()?.window)
                        }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .onAppear {
            context.store.load(req)
            context.chrome = NativeChrome(title: title, subtitle: "Export PDF")
        }
        .task(id: "\(artifactId)|\(requestedVersionId ?? "")|\(artifact?.currentVersion.id ?? "")") {
            guard let artifact, let viewing, viewing.id != artifact.currentVersion.id,
                  let client = context.store.client, !loadingOldVersion else { return }
            loadingOldVersion = true
            defer { loadingOldVersion = false }
            let path = ArtifactDetailLogic.contentPath(artifactId: artifact.id, versionId: viewing.id, download: false)
            if let data = try? await client.request("GET", path, headers: ["Accept": "*/*"], timeout: 60),
               let text = String(data: data, encoding: .utf8) {
                oldVersionBody = text
            }
        }
    }
}

// MARK: - Native printing

/// The printout's images, fetched before it's laid out: TextKit lays an attachment out at the size
/// it has, so an image that arrived after printing started would be missing from the paper.
@MainActor
@Observable
private final class PrintImages {
    private(set) var loaded: [String: NSImage] = [:]
    /// False while a fetch is in flight; printing waits for it so every page has its images.
    private(set) var ready = false

    func load(_ urls: [String], client: APIClient?) async {
        ready = false
        defer { ready = true }
        for url in urls where loaded[url] == nil {
            guard let data = await Self.data(url, client: client), let image = NSImage(data: data) else { continue }
            if Task.isCancelled { return }
            loaded[url] = image
        }
    }

    /// The API's own files with the session, other in-app paths from the server, web and inline
    /// `data:` images directly (as `MarkdownView` loads them).
    private static func data(_ source: String, client: APIClient?) async -> Data? {
        if source.hasPrefix("/api/v1/"), let client {
            return try? await client.request("GET", source, timeout: 30)
        }
        let url: URL?
        if source.hasPrefix("/") && !source.hasPrefix("//") {
            url = client.flatMap { URL(string: source, relativeTo: $0.baseURL) }
        } else {
            url = URL(string: source).flatMap { ["https", "http", "data"].contains($0.scheme ?? "") ? $0 : nil }
        }
        guard let url else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }
}

@MainActor
private enum NativePrint {
    /// The macOS print dialog (with Save as PDF) for `document`, laid out afresh at the paper's
    /// printable width so it paginates as text rather than as a scaled picture of the preview.
    static func run(_ document: PrintDocument, images: [String: NSImage], in window: NSWindow?) {
        let info = PrintRenderer.printInfo()
        let width = PrintRenderer.printableWidth(info)
        let view = PrintTextView(text: PrintRenderer.render(document, width: width, images: images), title: document.title, width: width)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = document.title
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

/// The printout on a sheet of paper, at the default paper's printable width: the same text view
/// that prints, so the preview is what comes out.
private struct PrintPreview: View {
    let document: PrintDocument
    let images: [String: NSImage]

    var body: some View {
        let info = PrintRenderer.printInfo()
        let width = PrintRenderer.printableWidth(info)
        ScrollView {
            PrintPaper(text: PrintRenderer.render(document, width: width, images: images), title: document.title, width: width)
                .frame(width: width)
                .padding(.horizontal, info.leftMargin)
                .padding(.vertical, info.topMargin)
                .background(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(28)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct PrintPaper: NSViewRepresentable {
    let text: NSAttributedString
    let title: String
    let width: CGFloat

    func makeNSView(context: Context) -> PrintTextView {
        PrintTextView(text: text, title: title, width: width)
    }

    func updateNSView(_ view: PrintTextView, context: Context) {
        guard view.textStorage?.isEqual(to: text) != true else { return }
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: PrintTextView, context: Context) -> CGSize? {
        CGSize(width: width, height: view.frame.height)
    }
}
