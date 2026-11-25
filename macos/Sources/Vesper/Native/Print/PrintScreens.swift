import AppKit
import SwiftUI
import VesperCore
import WebKit

/// Native SwiftUI print preview + macOS print/PDF dialog for `/print/knowledge/:id`.
struct PrintKnowledgeScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var style: KnowledgePrintStyle = .clean
    @State private var showMetadata = false
    @State private var didAutoPrint = false
    @State private var webHolder = PrintWebViewHolder()

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
                    triggerPrint(jobTitle: page?.title ?? "Untitled")
                } label: {
                    Label("Print / Save as PDF", systemImage: "printer")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(!printable)
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
                } else {
                    let html = PrintHTMLBuilder.buildKnowledgePrintHTML(
                        page: page,
                        style: style,
                        showMetadata: showMetadata,
                        savedQuery: queryEntry?.data,
                        darkScreen: theme.mode == .dark
                    )
                    PrintHTMLWebView(
                        holder: webHolder,
                        html: html,
                        baseURL: context.baseURL(),
                        onReady: {
                            guard !didAutoPrint else { return }
                            didAutoPrint = true
                            triggerPrint(jobTitle: page.title.isEmpty ? "Untitled" : page.title)
                        }
                    )
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

    private func triggerPrint(jobTitle: String) {
        webHolder.printDocument(jobTitle: jobTitle, in: context.window()?.window)
    }
}

/// Native SwiftUI print preview + macOS print/PDF dialog for `/print/artifacts/:id`.
struct PrintArtifactScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var oldVersionBody: String?
    @State private var loadingOldVersion = false
    @State private var didAutoPrint = false
    @State private var webHolder = PrintWebViewHolder()

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
                    let job = isOld && viewing != nil ? "\(title) (\(viewing!.label))" : title
                    webHolder.printDocument(jobTitle: job, in: context.window()?.window)
                } label: {
                    Label("Print / Save as PDF", systemImage: "printer")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(!printable || bodyMarkdown == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(p.surface)

            Divider().overlay(p.border)

            if let error = entry.error {
                QueryErrorView(message: error.userMessage) { context.store.load(req) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let artifact, let viewing {
                if !printable {
                    VStack(spacing: 12) {
                        Text("Only markdown artifacts export to PDF.")
                            .vesperText(.heading, theme)
                        Text("Use Download on the artifact page for files and mockups.")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let bodyMarkdown {
                    let html = PrintHTMLBuilder.buildArtifactPrintHTML(
                        title: title,
                        versionLabel: viewing.label,
                        authorName: viewing.createdBy.name,
                        createdAt: viewing.createdAt,
                        summary: artifact.summary,
                        bodyMarkdown: bodyMarkdown,
                        darkScreen: theme.mode == .dark
                    )
                    PrintHTMLWebView(
                        holder: webHolder,
                        html: html,
                        baseURL: context.baseURL(),
                        onReady: {
                            guard !didAutoPrint else { return }
                            didAutoPrint = true
                            let job = isOld ? "\(title) (\(viewing.label))" : title
                            webHolder.printDocument(jobTitle: job, in: context.window()?.window)
                        }
                    )
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

// MARK: - Print WebView Host & NSPrintOperation

@MainActor
private final class PrintWebViewHolder {
    weak var webView: WKWebView?

    func printDocument(jobTitle: String, in window: NSWindow?) {
        guard let webView else { return }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let op = webView.printOperation(with: printInfo)
        op.jobTitle = jobTitle
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}

private struct PrintHTMLWebView: NSViewRepresentable {
    let holder: PrintWebViewHolder
    let html: String
    let baseURL: URL?
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        holder.webView = wv
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: baseURL)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        holder.webView = wv
        context.coordinator.onReady = onReady
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            wv.loadHTMLString(html, baseURL: baseURL)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onReady: () -> Void
        var lastHTML: String = ""

        init(onReady: @escaping () -> Void) {
            self.onReady = onReady
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.onReady()
            }
        }
    }
}
