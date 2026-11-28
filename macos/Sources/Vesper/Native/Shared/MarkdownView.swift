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
        let linkStates = refs.isEmpty ? [:] : Self.linkStates(context.store.entry(resolve).data)
        let segments = MarkdownViewSegmenter.segment(
            document,
            extractCodeBlocks: chat && !hugWidth,
            extractTables: !hugWidth
        )
        Group {
            if segments.count == 1, case .rich(let singleDoc, let map) = segments[0] {
                richTextView(
                    document: singleDoc,
                    codeIndexMap: map,
                    allCodeBlocks: codeBlocks,
                    linkStates: linkStates
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .rich(let subDoc, let map):
                            richTextView(
                                document: subDoc,
                                codeIndexMap: map,
                                allCodeBlocks: codeBlocks,
                                linkStates: linkStates
                            )
                        case .codeBlock(let index, let info, let code):
                            let block = index < codeBlocks.count ? codeBlocks[index] : nil
                            MarkdownCodeBlockCard(
                                info: info,
                                code: code,
                                tokens: block.flatMap { highlights[$0] },
                                isExpanded: expanded.contains(index),
                                isCopied: copied == index,
                                onToggleExpand: {
                                    if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
                                },
                                onCopy: {
                                    open(.copyCode(index), newTab: false, anchor: nil, codeBlocks: codeBlocks)
                                }
                            )
                        case .table(let table):
                            MarkdownTableCard(
                                table: table,
                                textStyle: textStyle,
                                linkStates: linkStates,
                                onLink: { target, newTab in
                                    open(target, newTab: newTab, anchor: nil, codeBlocks: codeBlocks)
                                }
                            )
                        }
                    }
                }
            }
        }
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

    private func richTextView(
        document: MarkdownDocument,
        codeIndexMap: [Int],
        allCodeBlocks: [MarkdownCodeBlock],
        linkStates: [String: MarkdownLinkState]
    ) -> some View {
        let palette = theme.palette
        let localExpanded = Set(codeIndexMap.enumerated().compactMap { localIdx, globalIdx in
            expanded.contains(globalIdx) ? localIdx : nil
        })
        let localCopied = copied.flatMap { c in codeIndexMap.firstIndex(of: c) }
        let localHighlights = Dictionary(uniqueKeysWithValues: codeIndexMap.enumerated().compactMap { localIdx, globalIdx -> (Int, [[CodeToken]])? in
            guard globalIdx < allCodeBlocks.count, let tokens = highlights[allCodeBlocks[globalIdx]] else { return nil }
            return (localIdx, tokens)
        })
        return MarkdownText(
            document: document,
            theme: theme,
            options: MarkdownRenderOptions(
                textStyle: textStyle, textColor: textColor, anchors: anchors, codeBlocks: chat,
                expandedCodeBlocks: localExpanded, copiedCodeBlock: localCopied,
                highlights: localHighlights,
                links: linkStates,
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
            onLink: { target, newTab, anchor in
                let remapped: MarkdownLinkTarget
                switch target {
                case .copyCode(let localIdx) where localIdx < codeIndexMap.count:
                    remapped = .copyCode(codeIndexMap[localIdx])
                case .toggleCode(let localIdx) where localIdx < codeIndexMap.count:
                    remapped = .toggleCode(codeIndexMap[localIdx])
                default:
                    remapped = target
                }
                open(remapped, newTab: newTab, anchor: anchor, codeBlocks: allCodeBlocks)
            },
            onSelectionAction: onSelectionAction
        )
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
        let coordinator = context.coordinator
        view.onDeferredReflowSettle = { [weak coordinator, weak view] in
            guard let coordinator, let view else { return }
            let settledWidth = view.bounds.width > 0 ? view.bounds.width : (coordinator.width ?? 600)
            coordinator.render(view, width: settledWidth)
        }
        coordinator.latest = (document, theme, options)
        // Before the first sizeThatFits the width is a guess; sizing renders again at the real one.
        coordinator.render(view, width: coordinator.width ?? 600)
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
            if let existing = rendered, view.isDeferringSplitReflow {
                var keyWithOldWidth = key
                keyWithOldWidth.width = existing.width
                if keyWithOldWidth == existing {
                    // Only the width changed on a width-sensitive block (table/image/display math)
                    // mid-split-slide: defer rebuilding until the split animation settles.
                    view.noteDeferredWidthChange()
                    return
                }
            }
            rendered = key
            fullRenderCount &+= 1
            view.show(
                MarkdownRenderer.render(latest.document, theme: latest.theme, options: options),
                renderedWidth: width
            )
        } else if view.isDeferringSplitReflow {
            if !(view.rendering?.rightTabStops.isEmpty ?? true) {
                view.noteDeferredWidthChange()
            }
        } else {
            view.updateRightTabStops(forWidth: width)
        }
    }
}

// MARK: - Horizontally Scrollable Code Fence & Markdown Table Cards

/// Native chat code fence card: scrolls horizontally by default so long lines never break
/// mid-identifier, with a one-click Wrap/Scroll toggle, Shiki syntax colors, Copy, and >20-line fold.
private struct MarkdownCodeBlockCard: View {
    @Environment(\.vesperTheme) private var theme

    let info: String
    let code: String
    let tokens: [[CodeToken]]?
    let isExpanded: Bool
    let isCopied: Bool
    let onToggleExpand: () -> Void
    let onCopy: () -> Void

    @State private var wrapLines = false
    @State private var wrapHovered = false
    @State private var copyHovered = false
    @State private var foldHovered = false

    private static let foldedLines = 20

    var body: some View {
        let p = theme.palette
        let sunken = theme.swiftUIColor("surface-sunken", fallback: p.surface)
        let lines = code.components(separatedBy: "\n")
        let isLong = lines.count > Self.foldedLines
        let shownCount = isLong && !isExpanded ? Self.foldedLines : lines.count
        let renderedCode = attributedCode(lines: lines, count: shownCount)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(MarkdownSource.fenceLabel(info))
                    .font(.system(size: theme.contentPointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    wrapLines.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: wrapLines ? "arrow.left.and.right" : "text.alignleft")
                            .font(.system(size: 10, weight: .medium))
                        Text(wrapLines ? "Scroll" : "Wrap")
                            .font(.system(size: theme.contentPointSize(.small)))
                    }
                    .foregroundStyle(wrapHovered ? p.text : p.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(wrapHovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { wrapHovered = $0 }
                .help(wrapLines ? "Switch to horizontal scrolling" : "Wrap long code lines")

                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: theme.contentPointSize(.small)))
                    }
                    .foregroundStyle(isCopied ? p.accent : (copyHovered ? p.text : p.tertiaryText))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(copyHovered ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { copyHovered = $0 }
                .help("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Rectangle()
                .fill(p.rowBorder)
                .frame(height: 1)

            Group {
                if wrapLines {
                    Text(renderedCode)
                        .font(.system(size: theme.contentPointSize(.mono), design: .monospaced))
                        .lineSpacing(max(0, theme.contentPointSize(.mono) * 0.42))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(12)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(renderedCode)
                            .font(.system(size: theme.contentPointSize(.mono), design: .monospaced))
                            .lineSpacing(max(0, theme.contentPointSize(.mono) * 0.42))
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                }
            }

            if isLong {
                Rectangle()
                    .fill(p.rowBorder)
                    .frame(height: 1)

                Button(action: onToggleExpand) {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(isExpanded ? "Show less" : "Show \(lines.count - Self.foldedLines) more lines")
                            .font(.system(size: theme.contentPointSize(.small)))
                    }
                    .foregroundStyle(foldHovered ? p.text : p.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(foldHovered ? p.hover : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { foldHovered = $0 }
            }
        }
        .background(sunken, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
    }

    private func attributedCode(lines: [String], count: Int) -> AttributedString {
        let ink = theme.palette.text
        var result = AttributedString()
        let palette = CodePalette(theme: theme)
        for idx in 0..<count {
            if idx > 0 {
                result.append(AttributedString("\n"))
            }
            if let tokens, idx < tokens.count, !tokens[idx].isEmpty {
                for token in tokens[idx] {
                    var part = AttributedString(token.content)
                    let hex = palette.color(for: theme.mode == .dark ? token.dark : token.light)
                    part.foregroundColor = Color(cssHex: hex) ?? ink
                    result.append(part)
                }
            } else {
                let line = lines[idx]
                var part = AttributedString(line.isEmpty ? " " : line)
                part.foregroundColor = ink
                result.append(part)
            }
        }
        return result
    }
}

/// Native Markdown table card: renders GFM tables inside a horizontally scrollable SwiftUI `Grid`
/// with clamped per-column width bounds so wide tables never collide or crush when the inspector
/// narrows the reading column.
private struct MarkdownTableCard: View {
    @Environment(\.vesperTheme) private var theme

    let table: MarkdownTable
    let textStyle: ThemeTokens.TextStyle
    let linkStates: [String: MarkdownLinkState]
    let onLink: (MarkdownLinkTarget, Bool) -> Void

    var body: some View {
        let p = theme.palette
        let sunken = theme.swiftUIColor("surface-sunken", fallback: p.surface)
        let columnCount = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        if columnCount > 0 {
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { col in
                            let cell = col < table.header.count ? table.header[col] : []
                            let align = horizontalAlignment(for: col)
                            Text(inlineAttributed(cell, isHeader: true))
                                .font(.system(size: cellFontSize, weight: .semibold))
                                .foregroundStyle(p.text)
                                .multilineTextAlignment(textAlignment(for: col))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minWidth: 64, maxWidth: 320, alignment: Alignment(horizontal: align, vertical: .center))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .gridColumnAlignment(align)
                        }
                    }
                    .background(sunken)

                    Rectangle()
                        .fill(p.border)
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)

                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rIdx, row in
                        GridRow {
                            ForEach(0..<columnCount, id: \.self) { col in
                                let cell = col < row.count ? row[col] : []
                                let align = horizontalAlignment(for: col)
                                Text(inlineAttributed(cell, isHeader: false))
                                    .font(.system(size: cellFontSize))
                                    .foregroundStyle(p.text)
                                    .multilineTextAlignment(textAlignment(for: col))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minWidth: 64, maxWidth: 320, alignment: Alignment(horizontal: align, vertical: .top))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .textSelection(.enabled)
                                    .gridColumnAlignment(align)
                            }
                        }

                        if rIdx + 1 < table.rows.count {
                            Rectangle()
                                .fill(p.rowBorder)
                                .frame(height: 1)
                                .gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
                .frame(minWidth: 1, maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border, lineWidth: 1))
            .environment(\.openURL, OpenURLAction { url in
                guard let target = MarkdownLinkTarget(url: url) else { return .systemAction }
                let newTab = NSApp.currentEvent?.modifierFlags.contains(.command) == true
                onLink(target, newTab)
                return .handled
            })
        }
    }

    private var cellFontSize: CGFloat {
        theme.contentPointSize(textStyle) * 0.92
    }

    private func horizontalAlignment(for col: Int) -> HorizontalAlignment {
        guard col < table.alignments.count else { return .leading }
        switch table.alignments[col] {
        case .center?: return .center
        case .right?: return .trailing
        default: return .leading
        }
    }

    private func textAlignment(for col: Int) -> TextAlignment {
        guard col < table.alignments.count else { return .leading }
        switch table.alignments[col] {
        case .center?: return .center
        case .right?: return .trailing
        default: return .leading
        }
    }

    private func inlineAttributed(_ inlines: [MarkdownInline], isHeader: Bool) -> AttributedString {
        var out = AttributedString()
        for item in inlines {
            out.append(renderInline(item, isHeader: isHeader))
        }
        return out
    }

    private func renderInline(_ inline: MarkdownInline, isHeader: Bool) -> AttributedString {
        let p = theme.palette
        switch inline {
        case .text(let s):
            return AttributedString(s.replacingOccurrences(of: "\n", with: " "))
        case .emphasis(let children):
            var s = inlineAttributed(children, isHeader: isHeader)
            s.font = .system(size: cellFontSize, weight: isHeader ? .semibold : .regular).italic()
            return s
        case .strong(let children):
            var s = inlineAttributed(children, isHeader: isHeader)
            s.font = .system(size: cellFontSize, weight: .bold)
            return s
        case .strikethrough(let children):
            var s = inlineAttributed(children, isHeader: isHeader)
            s.strikethroughStyle = .single
            return s
        case .code(let code):
            var s = AttributedString(" \(code) ")
            s.font = .system(size: theme.contentPointSize(.mono), design: .monospaced)
            s.backgroundColor = theme.swiftUIColor("surface-raised", fallback: p.surface)
            return s
        case .math(let tex):
            var s = AttributedString(tex)
            s.font = .system(size: cellFontSize * 0.95, design: .monospaced)
            return s
        case .html(let html):
            return AttributedString(html)
        case .lineBreak:
            return AttributedString("\n")
        case .footnoteReference(let n):
            var s = AttributedString("[\(n)]")
            s.foregroundColor = p.accent
            return s
        case .image(_, let alt, _):
            var s = AttributedString(alt.isEmpty ? "[image]" : alt)
            s.foregroundColor = p.tertiaryText
            return s
        case .link(let url, _, let children):
            if url.hasPrefix(MarkdownSource.citeScheme), let n = Int(url.dropFirst(MarkdownSource.citeScheme.count)) {
                var s = AttributedString("\u{202F}\(n)\u{202F}")
                s.font = .system(size: theme.contentPointSize(.micro) + 1, weight: .semibold, design: .monospaced)
                s.foregroundColor = p.accent
                s.backgroundColor = theme.swiftUIColor("accent-soft", fallback: p.selected)
                if let parsed = URL(string: url) { s.link = parsed }
                return s
            }
            if url.hasPrefix(MarkdownSource.wikiLinkScheme) {
                let ref = String(url.dropFirst(MarkdownSource.wikiLinkScheme.count)).removingPercentEncoding ?? ""
                var s = inlineAttributed(children, isHeader: isHeader)
                switch linkStates[ref] {
                case .resolved(let href, _)?:
                    s.foregroundColor = p.accent
                    if let parsed = URL(string: href) { s.link = parsed }
                case .unresolved?:
                    s.foregroundColor = p.tertiaryText
                    s.underlineStyle = .single
                    if let parsed = URL(string: url) { s.link = parsed }
                case nil:
                    s.foregroundColor = p.accent
                }
                return s
            }
            var s = inlineAttributed(children, isHeader: isHeader)
            s.foregroundColor = p.accent
            if let parsed = URL(string: url) { s.link = parsed }
            return s
        }
    }
}
