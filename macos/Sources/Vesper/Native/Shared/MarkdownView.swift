import AppKit
import SwiftUI
import VesperCore

/// Markdown as the web's `<Markdown>` component renders it, for every native screen that shows
/// markdown (ticket descriptions, chat messages, Learn, Knowledge previews). Parsing and the look
/// are VesperCore's (`MarkdownParser`, `MarkdownRenderer`); this view resolves `[[links]]`,
/// highlights the chat's code, loads images and handles clicks.
///
/// - `textStyle`/`textColor`: the container's type and colour (`type-reading text-fg-2` is
///   `.reading`, "text-2").
/// - `anchors`: document headings (`<Markdown anchors>`); `chat`: ChatMarkdown (ticket keys and
///   `citations` link, code blocks get a header, Shiki and a fold).
/// - `findRow`: this text's row in `context.find.texts`; its matches are tinted, and scrolled to
///   when it's the current row.
/// - `onLink`: the screen's own handling (e.g. a citation bringing its source into view); return
///   true when handled. Otherwise in-app paths navigate (⌘-click: new tab), web links open in the
///   browser and ghost links create their page, as on the web.
struct MarkdownView: View {
    let markdown: String
    var textStyle: ThemeTokens.TextStyle = .body
    var textColor = "text"
    var anchors = false
    var chat = false
    var hugWidth = false
    var citations: [Int] = []
    var findRow: Int?
    var onLink: ((MarkdownLinkTarget) -> Bool)?
    var onLinkWithAnchor: ((MarkdownLinkTarget, MarkdownLinkAnchor?) -> Bool)? = nil
    var onSelectionAction: (@MainActor (ChatSelectionAction, String) -> Void)? = nil

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var cache = ParsedMarkdown()
    @State private var highlights: [MarkdownCodeBlock: [[CodeToken]]] = [:]
    @State private var expanded: Set<Int> = []
    @State private var copied: Int?
    @State private var images: [String: NSImage] = [:]
    /// Drawn math, and the colour and size it was drawn in (a theme change redraws it).
    @State private var math: [MarkdownMath: MarkdownMathImage] = [:]
    @State private var mathStyle = ""

    var body: some View {
        let document = cache.document(markdown, chat: chat, citations: citations)
        let refs = document.wikiRefs.sorted()
        let resolve = API.resolveLinks(ref: refs)
        let codeBlocks = document.codeBlocks
        let palette = theme.palette
        MarkdownText(
            document: document,
            theme: theme,
            options: MarkdownRenderOptions(
                textStyle: textStyle, textColor: textColor, anchors: anchors, codeBlocks: chat,
                expandedCodeBlocks: expanded, copiedCodeBlock: copied,
                highlights: Dictionary(uniqueKeysWithValues: codeBlocks.enumerated().compactMap { i, block in highlights[block].map { (i, $0) } }),
                links: refs.isEmpty ? [:] : Self.linkStates(context.store.entry(resolve).data),
                images: images,
                math: mathStyle == mathStyleKey ? math : [:]
            ),
            find: MarkdownText.Find(
                query: findRow == nil ? "" : context.find.query,
                caseSensitive: context.find.caseSensitive,
                isCurrent: findRow != nil && context.find.current == findRow,
                match: NSColor(palette.selected),
                current: NSColor(palette.accent.opacity(0.35))
            ),
            hugWidth: hugWidth,
            onLink: { target, newTab, anchor in open(target, newTab: newTab, anchor: anchor, codeBlocks: codeBlocks) },
            onSelectionAction: onSelectionAction
        )
        .task(id: refs) {
            if !refs.isEmpty { context.store.load(resolve) }
        }
        .task(id: chat ? codeBlocks : []) {
            for block in codeBlocks where highlights[block] == nil {
                guard let language = block.language else { continue }
                if let tokens = await CodeHighlighter.shared.highlight(block.code, language: language) {
                    highlights[block] = tokens
                } else if let reason = await CodeHighlighter.shared.loadError {
                    vlog("markdown: no highlighting: \(reason)")
                    return
                }
            }
        }
        .task(id: MathTask(expressions: document.mathExpressions, style: mathStyleKey)) {
            await drawMath(document.mathExpressions)
        }
        .task(id: document.imageURLs) {
            for url in document.imageURLs where images[url] == nil {
                guard let data = await imageData(url), let image = NSImage(data: data) else { continue }
                images[url] = image
            }
        }
    }

    private struct MathTask: Equatable {
        var expressions: [MarkdownMath]
        var style: String
    }

    /// What math in this view is drawn with; part of each render's cache key too.
    private var mathStyleKey: String {
        let request = MathBlockView.request(tex: "", display: false, theme: theme, textStyle: textStyle, textColor: textColor)
        return "\(request.color)@\(request.fontSize)"
    }

    /// `$$` math through the chat embeds' `MathRendering` (drawn natively, cached), in the text's colour and
    /// size. What can't be drawn keeps showing its TeX.
    private func drawMath(_ expressions: [MarkdownMath]) async {
        let style = mathStyleKey
        if mathStyle != style {
            math = [:]
            mathStyle = style
        }
        for expression in expressions where math[expression] == nil {
            let request = MathBlockView.request(tex: expression.tex, display: expression.display, theme: theme, textStyle: textStyle, textColor: textColor)
            guard let drawn = MathRendering.render(request, messageID: ""),
                  let image = EmbedImages.image(drawn, key: request.cacheKey()) else { continue }
            if Task.isCancelled { return }
            math[expression] = MarkdownMathImage(image: image, ascent: drawn.ascent ?? drawn.height)
        }
    }

    static func linkStates(_ response: API.ResolveLinksResponse?) -> [String: MarkdownLinkState] {
        var out: [String: MarkdownLinkState] = [:]
        for link in response?.links ?? [] { out[link.ref] = MarkdownLinkState(link.target) }
        return out
    }

    private func open(_ target: MarkdownLinkTarget, newTab: Bool, anchor: MarkdownLinkAnchor?, codeBlocks: [MarkdownCodeBlock]) {
        if onLinkWithAnchor?(target, anchor) == true { return }
        if onLink?(target) == true { return }
        switch target {
        case .path(let path):
            newTab ? context.openInNewTab(path) : context.navigate(path)
        case .external(let url):
            if url.scheme == "mailto" { NSWorkspace.shared.open(url) } else { context.openExternal(url.absoluteString) }
        case .ghost(let target):
            createPage(target)
        case .copyCode(let index):
            guard index < codeBlocks.count else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeBlocks[index].code, forType: .string)
            copied = index
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if copied == index { copied = nil }
            }
        case .toggleCode(let index):
            if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
        case .citation, .anchor, .footnote, .footnoteReference:
            // Citations belong to the screen (onLink); the text view scrolls to anchors and footnotes.
            break
        }
    }

    /// wikilink.tsx GhostLink: creates the page, then opens it for editing.
    private func createPage(_ target: String) {
        Task {
            do {
                let page = try await context.store.mutate(
                    API.createWikiPage(body: API.NewWikiPage(bodyMd: "", path: target)),
                    invalidating: QueryInvalidation(resources: ["wiki", "knowledge", "artifacts", "bootstrap", "inbox"])
                )
                let path = page.path ?? target
                context.navigate("/wiki/" + path.components(separatedBy: "/").map(MarkdownSource.encodeURIComponent).joined(separator: "/") + "?edit=1")
            } catch {
                context.showToast(ToastItemModel(id: "markdown.create.\(target)", title: "Couldn\u{2019}t create \u{201C}\(target)\u{201D}", description: (error as? APIError)?.userMessage, tone: .error))
            }
        }
    }

    /// An image's bytes: the API's own files with the session, other in-app paths from the
    /// server, web images directly.
    private func imageData(_ source: String) async -> Data? {
        let client = context.store.client
        if source.hasPrefix("/api/v1/"), let client {
            return try? await client.request("GET", source, timeout: 30)
        }
        let url: URL?
        if source.hasPrefix("/") && !source.hasPrefix("//") { url = client.flatMap { URL(string: source, relativeTo: $0.baseURL) } }
        else { url = URL(string: source).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil } }
        guard let url else { return nil }
        return try? await URLSession.shared.data(from: url).0
    }
}

/// The last parse, so a body re-evaluation (find, hover, a store update) doesn't parse again.
@MainActor
final class ParsedMarkdown {
    private var key: (markdown: String, chat: Bool, citations: [Int])?
    private var document = MarkdownDocument(blocks: [])

    func document(_ markdown: String, chat: Bool, citations: [Int]) -> MarkdownDocument {
        if let key, key.markdown == markdown, key.chat == chat, key.citations == citations { return document }
        document = MarkdownParser.parse(markdown, chat: chat, citations: citations)
        key = (markdown, chat, citations)
        return document
    }
}

/// The text view for SwiftUI: as wide as offered and as tall as its text. It re-renders only when
/// what it shows changes, so a selection survives unrelated updates.
private struct MarkdownText: NSViewRepresentable {
    struct Find {
        var query: String
        var caseSensitive: Bool
        var isCurrent: Bool
        var match: NSColor
        var current: NSColor
    }

    let document: MarkdownDocument
    let theme: ThemeTokens
    let options: MarkdownRenderOptions
    let find: Find
    let hugWidth: Bool
    let onLink: (MarkdownLinkTarget, Bool, MarkdownLinkAnchor?) -> Void
    let onSelectionAction: (@MainActor (ChatSelectionAction, String) -> Void)?

    func makeCoordinator() -> MarkdownRenderCoordinator { MarkdownRenderCoordinator() }

    func makeNSView(context: Context) -> MarkdownTextView { MarkdownTextView() }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        view.onLink = onLink
        view.onSelectionAction = onSelectionAction
        view.selectionTheme = theme
        context.coordinator.latest = (document, theme, options)
        // Before the first sizeThatFits the width is a guess; sizing renders again at the real one.
        context.coordinator.render(view, width: context.coordinator.width ?? 600)
        view.highlight(query: find.query, caseSensitive: find.caseSensitive, isCurrent: find.isCurrent, match: find.match, current: find.current)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MarkdownTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        context.coordinator.render(view, width: width)
        if hugWidth {
            return view.fittingSize(maxWidth: width)
        }
        return CGSize(width: width, height: view.fittingHeight(width: width))
    }
}

/// Caches rendered markdown for `MarkdownTextView`, avoiding full `NSAttributedString` rebuilds and
/// TextKit storage replacement when only container width changes on prose or code-block documents.
@MainActor
final class MarkdownRenderCoordinator {
    var latest: (document: MarkdownDocument, theme: ThemeTokens, options: MarkdownRenderOptions)?
    var width: CGFloat?
    private(set) var fullRenderCount = 0
    private var rendered: Key?

    /// Everything the rendered attributed text depends on; `width` is `nil` whenever the document
    /// does not contain tables, loaded images, or loaded display math (code-fence "Copy" headers
    /// adjust their right tab stop in-place on `MarkdownTextView`).
    struct Key: Equatable {
        var document: MarkdownDocument
        var theme: ThemeTokens
        var textStyle: ThemeTokens.TextStyle
        var textColor: String
        var anchors: Bool
        var codeBlocks: Bool
        var width: CGFloat?
        var expanded: Set<Int>
        var copied: Int?
        var highlights: [Int: [[CodeToken]]]
        var links: [String: MarkdownLinkState]
        var images: Set<String>
        var math: Set<MarkdownMath>
    }

    func render(_ view: MarkdownTextView, width: CGFloat) {
        guard let latest else { return }
        self.width = width
        var options = latest.options
        options.width = width
        let imageKeys = Set(options.images.keys)
        let displayMathKeys = Set(options.math.keys.filter(\.display).map(\.tex))
        let widthSensitive = latest.document.requiresRerenderOnWidthChange(
            loadedImageURLs: imageKeys,
            loadedDisplayMath: displayMathKeys
        )
        let key = Key(
            document: latest.document, theme: latest.theme, textStyle: options.textStyle, textColor: options.textColor,
            anchors: options.anchors, codeBlocks: options.codeBlocks, width: widthSensitive ? width.rounded() : nil,
            expanded: options.expandedCodeBlocks, copied: options.copiedCodeBlock, highlights: options.highlights,
            links: options.links, images: imageKeys, math: Set(options.math.keys)
        )
        if key != rendered {
            rendered = key
            fullRenderCount &+= 1
            view.show(
                MarkdownRenderer.render(latest.document, theme: latest.theme, options: options),
                renderedWidth: width
            )
        } else {
            view.updateRightTabStops(forWidth: width)
        }
    }
}
