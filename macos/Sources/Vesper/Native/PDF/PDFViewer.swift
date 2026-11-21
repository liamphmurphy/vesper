import AppKit
import PDFKit
import SwiftUI
import VesperCore

/// One PDF in PDFKit: fetched from the API with the session, shown with page thumbnails, search and
/// text selection (PDFView's own menu offers Look Up, Copy and Translate). It's also the find bar's
/// target where a screen hands it over (`NativeFindModel.searcher`). Replaces the web's pdf.js viewer
/// in the Mac app.
@MainActor
@Observable
final class PDFViewerModel: FindTarget {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var matchCount = 0
    /// The current match, 0-based; nil when there's none.
    private(set) var matchIndex: Int?
    var showsThumbnails = true

    @ObservationIgnored let pdfView = PDFView()
    @ObservationIgnored let thumbnails = PDFThumbnailView()
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var searched: (query: String, caseSensitive: Bool)?
    @ObservationIgnored private var loadedPath: String?

    init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = CGSize(width: 76, height: 98)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.backgroundColor = .clear
    }

    /// Fetches the PDF at an API path (`/api/v1/…`) and shows it. Loading the same path again is a no-op.
    func load(path: String, client: APIClient?) async {
        guard path != loadedPath || phase != .loaded else { return }
        phase = .loading
        guard let client else {
            phase = .failed(APIError.unauthorized.userMessage)
            return
        }
        do {
            let data = try await client.request("GET", path, headers: ["Accept": "application/pdf"], timeout: 120)
            guard let document = PDFDocument(data: data) else {
                phase = .failed("This file isn\u{2019}t a PDF Vesper can read.")
                return
            }
            pdfView.document = document
            loadedPath = path
            pageCount = document.pageCount
            syncPage()
            clearFind()
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    /// Follows PDFView's current page (the view calls it on `.PDFViewPageChanged`).
    func syncPage() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        pageIndex = document.index(for: page)
    }

    func go(toPage index: Int) {
        guard let page = pdfView.document?.page(at: min(max(index, 0), max(pageCount - 1, 0))) else { return }
        pdfView.go(to: page)
    }

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }

    // MARK: Search

    func find(_ query: String, backwards: Bool, caseSensitive: Bool) async -> Bool {
        search(query, backwards: backwards, caseSensitive: caseSensitive)
    }

    /// Moves to the next (or previous) match, marking every match; a new query starts from the top.
    @discardableResult
    func search(_ query: String, backwards: Bool = false, caseSensitive: Bool = false) -> Bool {
        guard let document = pdfView.document, FindLogic.shouldSearch(query: query) else {
            clearFind()
            return false
        }
        if searched?.query != query || searched?.caseSensitive != caseSensitive {
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
            matches = document.findString(query, withOptions: options)
            for match in matches { match.color = NSColor.findHighlightColor.withAlphaComponent(0.45) }
            pdfView.highlightedSelections = matches
            searched = (query, caseSensitive)
            matchCount = matches.count
            matchIndex = nil
        }
        guard !matches.isEmpty else {
            matchIndex = nil
            return false
        }
        let next = matchIndex.map { (backwards ? $0 - 1 + matches.count : $0 + 1) % matches.count } ?? (backwards ? matches.count - 1 : 0)
        matchIndex = next
        pdfView.setCurrentSelection(matches[next], animate: true)
        pdfView.go(to: matches[next])
        return true
    }

    func clearFind() {
        matches = []
        searched = nil
        matchCount = 0
        matchIndex = nil
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }
}

/// The viewer: a header with thumbnails, page, zoom and search, the thumbnail strip, and the pages.
struct PDFViewerView: View {
    @Environment(\.vesperTheme) private var theme
    let model: PDFViewerModel
    /// Retries a failed load.
    var retry: () -> Void = {}

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.border)
            ZStack {
                HStack(spacing: 0) {
                    if model.showsThumbnails {
                        PDFKitHost(view: model.thumbnails)
                            .frame(width: 104)
                            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
                        Divider().overlay(theme.palette.border)
                    }
                    PDFKitHost(view: model.pdfView)
                }
                .opacity(model.phase == .loaded ? 1 : 0)
                switch model.phase {
                case .loading:
                    ProgressView().controlSize(.small)
                case .failed(let message):
                    QueryErrorView(message: "Couldn\u{2019}t open the PDF: \(message)", retry: retry)
                        .frame(maxWidth: 520)
                case .loaded:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: model.pdfView)) { _ in model.syncPage() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.showsThumbnails.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(model.showsThumbnails ? "Hide thumbnails" : "Show thumbnails")
                .accessibilityLabel(model.showsThumbnails ? "Hide thumbnails" : "Show thumbnails")
            Text(model.pageCount > 0 ? "Page \(model.pageIndex + 1) of \(model.pageCount)" : "")
                .monospacedDigit()
                .foregroundStyle(theme.palette.secondaryText)
            Spacer()
            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Button("Fit") { model.zoomToFit() }.help("Fit to width")
            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            searchField
        }
        .buttonStyle(.borderless)
        .vesperText(.small, theme)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .disabled(model.phase != .loaded)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.palette.tertiaryText)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 140)
                .focused($searchFocused)
                .onSubmit { model.search(query, backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: query) { _, text in model.search(text) }
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Text(model.matchCount == 0 ? "No matches" : "\((model.matchIndex ?? 0) + 1) of \(model.matchCount)")
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.tertiaryText)
                Button { model.search(query, backwards: true) } label: { Image(systemName: "chevron.up") }.help("Previous match")
                Button { model.search(query) } label: { Image(systemName: "chevron.down") }.help("Next match")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? theme.palette.accent : theme.palette.border))
    }
}

/// Puts one of the model's PDFKit views in SwiftUI. The model owns it, so it survives re-renders.
private struct PDFKitHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// /pdf?src=/api/v1/…&title=…: a PDF on its own, for paths that open one outside the Library (the
/// web Knowledge page's PDF embeds, in the Mac app). The find bar searches the document.
struct PDFScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @State private var model = PDFViewerModel()

    private var source: String? {
        guard let src = context.match.query["src"], src.hasPrefix("/api/v1/"), !src.contains("..") else { return nil }
        return src
    }

    private var title: String {
        let raw = context.match.query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "PDF" : raw
    }

    var body: some View {
        Group {
            if let source {
                PDFViewerView(model: model) { Task { await model.load(path: source, client: context.store.client) } }
                    .padding(12)
                    .task(id: source) { await model.load(path: source, client: context.store.client) }
            } else {
                QueryErrorView(message: "This link doesn\u{2019}t name a PDF in Vesper.") { context.navigate("/knowledge") }
            }
        }
        .onChange(of: context.match, initial: true) { _, _ in publishChrome() }
        .onAppear {
            context.find.searcher = model
            context.onCommand = { command in
                guard case .toolbarAction(itemId: "pdf.download", _) = command, let source else { return }
                LibraryFiles.saveCopy(path: source, filename: LibraryFiles.pdfFilename(title), client: context.store.client, context: context)
            }
        }
        .onDisappear { if context.find.searcher === model { context.find.searcher = nil } }
    }

    private func publishChrome() {
        context.chrome = NativeChrome(title: title, toolbarItems: source == nil ? [] : [
            ShellToolbarItem(id: "pdf.download", label: "Download", icon: "download", kind: .button, showsLabel: true),
        ])
    }
}
