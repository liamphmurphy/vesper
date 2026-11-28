#if os(macOS)
import AppKit

/// How a `MarkdownView` draws: the type token and colour its container gives the text (the web's
/// `className` on `<Markdown>`), the component's flags, and what has loaded since the last render.
public struct MarkdownRenderOptions {
    /// `type-reading` for descriptions, `body` by default, `chat` in a conversation.
    public var textStyle: ThemeTokens.TextStyle
    /// CSS colour token of the text ("text", "text-2" for `text-fg-2`…).
    public var textColor: String
    /// Headings one size up with ids, as in documents (`<Markdown anchors>`).
    public var anchors: Bool
    /// The chat's code blocks: a header with the language and Copy, highlighting, long blocks folded.
    public var codeBlocks: Bool
    /// The width the text lays out in; tables fill it and the chat header's Copy sits at its end.
    public var width: CGFloat
    /// Code blocks (by `MarkdownDocument.codeBlocks` index) the person unfolded or just copied.
    public var expandedCodeBlocks: Set<Int>
    public var copiedCodeBlock: Int?
    /// Shiki's tokens per code block index, once highlighted.
    public var highlights: [Int: [[CodeToken]]]
    /// What each `[[ref]]` resolved to; a missing ref is still resolving.
    public var links: [String: MarkdownLinkState]
    /// Loaded images by URL; the alt text shows until then.
    public var images: [String: NSImage]
    /// Drawn math (the chat embeds' render-once path); the TeX source shows until then.
    public var math: [MarkdownMath: MarkdownMathImage]

    public init(
        textStyle: ThemeTokens.TextStyle = .body, textColor: String = "text", anchors: Bool = false, codeBlocks: Bool = false,
        width: CGFloat = 600, expandedCodeBlocks: Set<Int> = [], copiedCodeBlock: Int? = nil,
        highlights: [Int: [[CodeToken]]] = [:], links: [String: MarkdownLinkState] = [:], images: [String: NSImage] = [:],
        math: [MarkdownMath: MarkdownMathImage] = [:]
    ) {
        self.textStyle = textStyle
        self.textColor = textColor
        self.anchors = anchors
        self.codeBlocks = codeBlocks
        self.width = width
        self.expandedCodeBlocks = expandedCodeBlocks
        self.copiedCodeBlock = copiedCodeBlock
        self.highlights = highlights
        self.links = links
        self.images = images
        self.math = math
    }
}

/// Math drawn as an image, with how far its baseline sits below the top (to set it inline).
public struct MarkdownMathImage {
    public var image: NSImage
    public var ascent: CGFloat

    public init(image: NSImage, ascent: CGFloat) {
        self.image = image
        self.ascent = ascent
    }
}

/// A paragraph whose single right-aligned trailing tab stop (such as a chat code-fence header's
/// "Copy" link) tracks container width so resizes update it in-place without rebuilding the document.
public struct MarkdownRightTabStop: Equatable, Sendable {
    public var range: NSRange
    public var minLocation: CGFloat
    public var trailingInset: CGFloat

    public init(range: NSRange, minLocation: CGFloat, trailingInset: CGFloat) {
        self.range = range
        self.minLocation = minLocation
        self.trailingInset = trailingInset
    }
}

/// Rendered markdown, with where its anchors and footnotes start.
public struct MarkdownRendering {
    public var text: NSAttributedString
    /// Heading ids (anchors mode) and footnotes, to where they start in `text`.
    public var anchors: [String: Int]
    public var footnotes: [Int: Int]
    public var footnoteReferences: [Int: Int]
    /// Paragraphs whose right-aligned tab stop should track container width on resize.
    public var rightTabStops: [MarkdownRightTabStop]

    public init(
        text: NSAttributedString,
        anchors: [String: Int],
        footnotes: [Int: Int],
        footnoteReferences: [Int: Int],
        rightTabStops: [MarkdownRightTabStop] = []
    ) {
        self.text = text
        self.anchors = anchors
        self.footnotes = footnotes
        self.footnoteReferences = footnoteReferences
        self.rightTabStops = rightTabStops
    }
}

extension NSAttributedString.Key {
    /// A paragraph's `MarkdownDecoration`: the boxes, rules and quote bars drawn behind its text.
    public static let markdownDecoration = NSAttributedString.Key("VesperMarkdownDecoration")
    /// An inline code span's rounded pill chrome drawn behind the monospace run by `MarkdownLayoutFragment`.
    public static let markdownInlineCode = NSAttributedString.Key("VesperMarkdownInlineCode")
}

/// Visual tokens for a rounded inline `` `code` `` pill drawn behind monospace runs.
public final class MarkdownInlineCodeStyle: NSObject, @unchecked Sendable {
    public let fill: NSColor
    public let border: NSColor

    public init(fill: NSColor, border: NSColor) {
        self.fill = fill
        self.border = border
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownInlineCodeStyle else { return false }
        return fill == other.fill && border == other.border
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(fill)
        hasher.combine(border)
        return hasher.finalize()
    }
}

/// What a paragraph's layout fragment draws behind its text. Consecutive paragraphs of one box
/// (a table's rows) draw one continuous shape: the first draws the top, the last the bottom.
public final class MarkdownDecoration: NSObject {
    public struct Box: Equatable {
        public var left: CGFloat
        public var fill: NSColor?
        public var border: NSColor?
        public var isFirst: Bool
        public var isLast: Bool
        /// Space painted above the first line and below the last (the box's padding).
        public var padTop: CGFloat
        public var padBottom: CGFloat
        /// A line across the top or bottom of this paragraph's slice (a header's or row's border).
        public var lineAbove: NSColor?
        public var lineBelow: NSColor?
        public var cornerRadius: CGFloat = 8
    }

    /// A blockquote's left border, at `x`; it starts at the quote's first line and ends at its last.
    public struct QuoteBar: Equatable {
        public var x: CGFloat
        public var color: NSColor
        public var isFirst: Bool
        public var isLast: Bool
    }

    public var box: Box?
    public var quoteBars: [QuoteBar]
    /// A horizontal rule through the middle of the paragraph, from `left`.
    public var rule: (left: CGFloat, color: NSColor)?

    init(box: Box?, quoteBars: [QuoteBar], rule: (left: CGFloat, color: NSColor)?) {
        self.box = box
        self.quoteBars = quoteBars
        self.rule = rule
    }
}

extension ThemeTokens {
    /// A palette colour by CSS name, or `fallback` before the page has sent its palette.
    public func nsColor(_ name: String, fallback: NSColor) -> NSColor {
        guard let c = color(name) else { return fallback }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}

/// Markdown to attributed text with the page's theme tokens, reproducing the web's
/// `components/domain/markdown.tsx` (and `code-fence.tsx` for the chat's code blocks).
@MainActor
public enum MarkdownRenderer {
    public static func render(_ document: MarkdownDocument, theme: ThemeTokens, options: MarkdownRenderOptions) -> MarkdownRendering {
        var builder = Builder(theme: theme, options: options)
        builder.blocks(document.blocks, context: builder.root, gap: Builder.blockGap)
        builder.footnotes(document.footnotes)
        return builder.finish()
    }
}

// MARK: - Builder

/// Builds the text paragraph by paragraph; decorations that span paragraphs (quotes, boxes) are
/// joined up in `finish`.
@MainActor
private struct Builder {
    /// `flex flex-col gap-2.5` between top-level blocks; `gap-2` inside quotes; `space-y-1` between items.
    static let blockGap: CGFloat = 10
    static let quoteGap: CGFloat = 8
    static let itemGap: CGFloat = 4
    /// `ml-5` lists, `border-l-2 pl-3` quotes.
    static let listIndent: CGFloat = 20
    static let quoteIndent: CGFloat = 14
    static let foldedLines = 20

    struct Context {
        var indent: CGFloat = 0
        var color: NSColor
        var quotes: [Int] = []
    }

    struct Paragraph {
        var text: NSMutableAttributedString
        var style: NSMutableParagraphStyle
        var quotes: [Int]
        var box: MarkdownDecoration.Box?
        var rule: (left: CGFloat, color: NSColor)?
        var rightTabStop: (minLocation: CGFloat, trailingInset: CGFloat)? = nil
    }

    let theme: ThemeTokens
    let options: MarkdownRenderOptions
    let base: NSFont
    let mono: NSFont
    var paragraphs: [Paragraph] = []
    var quoteBars: [Int: (x: CGFloat, color: NSColor)] = [:]
    /// The next code block's index in `MarkdownDocument.codeBlocks`.
    var codeBlockCount = 0
    var anchorer = MarkdownAnchors.Anchorer()
    var anchorParagraphs: [String: Int] = [:]
    var footnoteParagraphs: [Int: Int] = [:]
    var footnoteReferenceParagraphs: [Int: Int] = [:]

    init(theme: ThemeTokens, options: MarkdownRenderOptions) {
        self.theme = theme
        self.options = options
        base = NSFont.systemFont(ofSize: theme.contentPointSize(options.textStyle), weight: options.textStyle.metrics.weight >= 600 ? .semibold : .regular)
        mono = NSFont.monospacedSystemFont(ofSize: theme.contentPointSize(.mono), weight: .regular)
    }

    var root: Context { Context(color: color(options.textColor, .labelColor)) }

    func color(_ name: String, _ fallback: NSColor) -> NSColor { theme.nsColor(name, fallback: fallback) }

    var border: NSColor { color("border", .separatorColor) }
    var rowBorder: NSColor { color("border-row", .separatorColor) }
    var sunken: NSColor { color("surface-sunken", .controlBackgroundColor) }
    var accent: NSColor { color("accent", .controlAccentColor) }

    // MARK: Blocks

    mutating func blocks(_ blocks: [MarkdownBlock], context: Context, gap: CGFloat, spaceBefore: CGFloat = 0) {
        for (i, block) in blocks.enumerated() {
            self.block(block, context: context, spaceBefore: i == 0 ? spaceBefore : gap)
        }
    }

    mutating func block(_ block: MarkdownBlock, context: Context, spaceBefore: CGFloat) {
        switch block {
        case .paragraph(let inlines):
            append(inlines: inlines, context: context, font: base, spaceBefore: spaceBefore)
        case .heading(let level, let inlines):
            heading(level, inlines, context: context, spaceBefore: spaceBefore)
        case .blockquote(let inner):
            var quoted = context
            let id = quoteBars.count
            quoteBars[id] = (context.indent, color("border-strong", .separatorColor))
            quoted.quotes.append(id)
            quoted.indent += Self.quoteIndent
            quoted.color = color("text-secondary", .secondaryLabelColor)
            blocks(inner, context: quoted, gap: Self.quoteGap, spaceBefore: spaceBefore)
        case .list(let list):
            self.list(list, context: context, spaceBefore: spaceBefore)
        case .code(let info, let code):
            if options.codeBlocks { codeFence(info: info, code: code, context: context, spaceBefore: spaceBefore) }
            else { preformatted(code, context: context, spaceBefore: spaceBefore) }
        case .math(let tex):
            let text: NSMutableAttributedString
            if let drawn = options.math[MarkdownMath(tex: tex, display: true)] {
                // KaTeX's display math, shrunk to the column when it's wider.
                let attachment = NSTextAttachment()
                attachment.image = drawn.image
                let size = drawn.image.size
                let scale = min(1, max(40, options.width - 4) / max(size.width, 1))
                attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
                text = NSMutableAttributedString(attachment: attachment)
                text.addAttributes([.font: mono, .toolTip: tex], range: NSRange(location: 0, length: text.length))
            } else {
                text = NSMutableAttributedString(string: tex.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [.font: mono, .foregroundColor: context.color])
            }
            let style = paragraphStyle(context, spaceBefore: spaceBefore, textStyle: .mono)
            style.alignment = .center
            paragraphs.append(Paragraph(text: text, style: style, quotes: context.quotes))
        case .html(let html):
            // The web escapes raw HTML: it shows as written.
            append(inlines: [.text(html)], context: context, font: base, spaceBefore: spaceBefore)
        case .thematicBreak:
            // `hr.my-1`: a hairline with 4px above and below.
            let text = NSMutableAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 1)])
            let style = paragraphStyle(context, spaceBefore: spaceBefore + 4, textStyle: nil)
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            style.paragraphSpacing = 4
            paragraphs.append(Paragraph(text: text, style: style, quotes: context.quotes, rule: (context.indent, border)))
        case .table(let table):
            self.table(table, context: context, spaceBefore: spaceBefore)
        }
    }

    mutating func heading(_ level: Int, _ inlines: [MarkdownInline], context: Context, spaceBefore: CGFloat) {
        // markdown.tsx: documents (anchors) step h1 up to type-title; elsewhere h1 and h2 are
        // type-heading. h3 (and h4 in documents) are semibold; the rest look like paragraphs.
        // `margin` is the heading's mt-1/2/4 on top of the gap.
        let look: (style: ThemeTokens.TextStyle, margin: CGFloat)?
        switch (options.anchors, level) {
        case (true, 1): look = (.title, 16)
        case (true, 2): look = (.heading, 16)
        case (false, 1), (false, 2): look = (.heading, 8)
        case (true, 3), (true, 4): look = (options.textStyle, 8)
        case (false, 3): look = (options.textStyle, 4)
        default: look = nil
        }
        guard let look else {
            append(inlines: inlines, context: context, font: base, spaceBefore: spaceBefore)
            return
        }
        let font = NSFont.systemFont(ofSize: theme.contentPointSize(look.style), weight: .semibold)
        append(inlines: inlines, context: context, font: font, spaceBefore: spaceBefore + look.margin, textStyle: look.style)
        if options.anchors {
            anchorParagraphs[anchorer.next(plainText(inlines))] = paragraphs.count - 1
        }
    }

    mutating func list(_ list: MarkdownList, context: Context, spaceBefore: CGFloat) {
        let isTaskList = list.items.contains { $0.checked != nil }
        var inner = context
        // Task lists: `ml-1 list-none`, the checkbox in place of a bullet.
        inner.indent += isTaskList ? 4 : Self.listIndent
        for (i, item) in list.items.enumerated() {
            let first = paragraphs.count
            if item.blocks.isEmpty {
                append(inlines: [], context: inner, font: base, spaceBefore: i == 0 ? spaceBefore : Self.itemGap)
            } else {
                // Blocks inside an item have no margins between them (a paragraph then a nested list).
                blocks(item.blocks, context: inner, gap: 0, spaceBefore: i == 0 ? spaceBefore : Self.itemGap)
            }
            guard first < paragraphs.count else { continue }
            let marker = NSMutableAttributedString()
            if isTaskList {
                if let checked = item.checked { marker.append(checkbox(checked)) }
            } else {
                let label = list.ordered ? "\(list.start + i)." : "•"
                let style = paragraphs[first].style
                // The marker sits right-aligned in the indent, outside the text (list-style-position: outside).
                style.firstLineHeadIndent = context.indent
                style.tabStops = [NSTextTab(textAlignment: .right, location: inner.indent - 6), NSTextTab(textAlignment: .left, location: inner.indent)] + style.tabStops.filter { $0.location > inner.indent }
                marker.append(NSAttributedString(string: "\t\(label)\t", attributes: [.font: base, .foregroundColor: inner.color]))
            }
            paragraphs[first].text.insert(marker, at: 0)
        }
    }

    func checkbox(_ checked: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        let config = NSImage.SymbolConfiguration(pointSize: base.pointSize, weight: .regular)
        attachment.image = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: checked ? "Done" : "Not done")?
            .withSymbolConfiguration(config)
        out.append(NSAttributedString(attachment: attachment))
        // `[&_input]:mr-2`.
        out.append(NSAttributedString(string: "\u{2002}", attributes: [.font: base]))
        out.addAttribute(.foregroundColor, value: checked ? accent : color("text-tertiary", .tertiaryLabelColor), range: NSRange(location: 0, length: out.length))
        return out
    }

    /// `<pre>` outside the chat: `rounded-lg border bg-surface-sunken p-3 font-mono text-12 leading-relaxed`.
    mutating func preformatted(_ code: String, context: Context, spaceBefore: CGFloat) {
        codeBlockCount += 1
        let text = NSMutableAttributedString(string: codeText(code.components(separatedBy: "\n")), attributes: [.font: mono, .foregroundColor: context.color])
        let style = codeStyle(context, spaceBefore: spaceBefore + 12)
        style.paragraphSpacing = 12
        let box = MarkdownDecoration.Box(left: context.indent, fill: sunken, border: border, isFirst: true, isLast: true, padTop: 12, padBottom: 12)
        paragraphs.append(Paragraph(text: text, style: style, quotes: context.quotes, box: box))
    }

    /// code-fence.tsx: a header with the language and Copy, the code (highlighted once Shiki has
    /// run), and past 20 lines a fold.
    mutating func codeFence(info: String, code: String, context: Context, spaceBefore: CGFloat) {
        let index = codeBlockCount
        codeBlockCount += 1
        let lines = code.components(separatedBy: "\n")
        let long = lines.count > Self.foldedLines
        let expanded = options.expandedCodeBlocks.contains(index)
        let shown = long && !expanded ? Array(lines.prefix(Self.foldedLines)) : lines
        let small = NSFont.systemFont(ofSize: theme.contentPointSize(.small))
        let tertiary = color("text-tertiary", .tertiaryLabelColor)

        // Header: `px-3 py-1 text-12 text-fg-tertiary`, `border-b border-border-row`.
        let header = NSMutableAttributedString(string: MarkdownSource.fenceLabel(info), attributes: [.font: NSFont.monospacedSystemFont(ofSize: theme.contentPointSize(.small), weight: .regular), .foregroundColor: tertiary])
        header.append(NSAttributedString(string: "\t" + (options.copiedCodeBlock == index ? "Copied" : "Copy"), attributes: [.font: small, .foregroundColor: tertiary, .link: MarkdownLinkTarget.action("copy", index)]))
        let headerStyle = paragraphStyle(context, spaceBefore: spaceBefore + 4, textStyle: .small)
        headerStyle.firstLineHeadIndent = context.indent + 12
        headerStyle.headIndent = context.indent + 12
        headerStyle.tabStops = [NSTextTab(textAlignment: .right, location: max(context.indent + 60, options.width - 12))]
        headerStyle.paragraphSpacing = 4
        paragraphs.append(Paragraph(
            text: header,
            style: headerStyle,
            quotes: context.quotes,
            box: fenceBox(context, first: true, last: false, padTop: 4, padBottom: 4, lineBelow: rowBorder),
            rightTabStop: (minLocation: context.indent + 60, trailingInset: 12)
        ))

        // Body: `p-3 font-mono text-12 leading-relaxed`, `text-fg`, tokens in the palette's colours.
        let body = NSMutableAttributedString()
        let ink = color("text", .labelColor)
        if let tokens = options.highlights[index] {
            let palette = CodePalette(theme: theme)
            for (i, line) in shown.enumerated() {
                if i > 0 { body.append(NSAttributedString(string: "\u{2028}", attributes: [.font: mono])) }
                let lineTokens = i < tokens.count ? tokens[i] : []
                if lineTokens.isEmpty {
                    body.append(NSAttributedString(string: line.isEmpty ? " " : line, attributes: [.font: mono, .foregroundColor: ink]))
                }
                for token in lineTokens {
                    let hex = palette.color(for: theme.mode == .dark ? token.dark : token.light)
                    let tokenColor = RGBA(hex: hex).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha) } ?? ink
                    body.append(NSAttributedString(string: token.content, attributes: [.font: mono, .foregroundColor: tokenColor]))
                }
            }
        } else {
            body.append(NSAttributedString(string: codeText(shown), attributes: [.font: mono, .foregroundColor: ink]))
        }
        let bodyStyle = codeStyle(context, spaceBefore: 12)
        bodyStyle.paragraphSpacing = 12
        paragraphs.append(Paragraph(text: body, style: bodyStyle, quotes: context.quotes, box: fenceBox(context, first: false, last: !long, padTop: 12, padBottom: 12)))

        // Fold: `border-t border-border-row px-3 py-1 text-12 text-fg-secondary`.
        if long {
            let label = expanded ? "Show less" : "Show \(lines.count - Self.foldedLines) more lines"
            let fold = NSMutableAttributedString(string: label, attributes: [.font: small, .foregroundColor: color("text-secondary", .secondaryLabelColor), .link: MarkdownLinkTarget.action("toggle", index)])
            let foldStyle = paragraphStyle(context, spaceBefore: 4, textStyle: .small)
            foldStyle.firstLineHeadIndent = context.indent + 12
            foldStyle.headIndent = context.indent + 12
            foldStyle.paragraphSpacing = 4
            paragraphs.append(Paragraph(text: fold, style: foldStyle, quotes: context.quotes, box: fenceBox(context, first: false, last: true, padTop: 4, padBottom: 4, lineAbove: rowBorder)))
        }
    }

    func fenceBox(_ context: Context, first: Bool, last: Bool, padTop: CGFloat, padBottom: CGFloat, lineAbove: NSColor? = nil, lineBelow: NSColor? = nil) -> MarkdownDecoration.Box {
        MarkdownDecoration.Box(left: context.indent, fill: sunken, border: border, isFirst: first, isLast: last, padTop: padTop, padBottom: padBottom, lineAbove: lineAbove, lineBelow: lineBelow)
    }

    /// Code as one paragraph: lines joined by line separators, so the box is one layout fragment;
    /// an empty line keeps its height (code-fence.tsx renders it as a space).
    func codeText(_ lines: [String]) -> String {
        lines.map { $0.isEmpty ? " " : $0 }.joined(separator: "\u{2028}")
    }

    func codeStyle(_ context: Context, spaceBefore: CGFloat) -> NSMutableParagraphStyle {
        let style = paragraphStyle(context, spaceBefore: spaceBefore, textStyle: nil)
        style.firstLineHeadIndent = context.indent + 12
        style.headIndent = context.indent + 12
        style.tailIndent = -12
        // `leading-relaxed` (1.625) on 12px mono.
        style.lineSpacing = max(0, mono.pointSize * 1.625 - mono.pointSize * 1.2)
        style.lineBreakMode = .byCharWrapping
        style.tabStops = []
        // A browser's tab-size: 8 spaces.
        style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: mono]).width * 8
        return style
    }

    /// Tables: `rounded-lg border`, `text-[0.92em]`, a sunken header, `px-3 py-2` cells and row
    /// borders. Columns are tab stops sized to their widest cell and stretched to fill the width
    /// (`w-full`); a table too wide for the view wraps instead of scrolling.
    mutating func table(_ table: MarkdownTable, context: Context, spaceBefore: CGFloat) {
        let size = base.pointSize * 0.92
        let cellFont = NSFont.systemFont(ofSize: size)
        let headerFont = NSFont.systemFont(ofSize: size, weight: .semibold)
        let rows = [table.header] + table.rows
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let rendered: [[NSAttributedString]] = rows.enumerated().map { r, cells in
            (0..<columns).map { c in
                c < cells.count ? inlineText(cells[c], font: r == 0 ? headerFont : cellFont, color: context.color) : NSAttributedString()
            }
        }
        var widths = (0..<columns).map { c in rendered.map { ceil($0[c].size().width) }.max() ?? 0 }.map { $0 + 24 }
        let available = options.width - context.indent
        let natural = widths.reduce(0, +)
        if natural < available, natural > 0 { widths = widths.map { $0 * available / natural } }
        var starts: [CGFloat] = []
        var x = context.indent
        for w in widths { starts.append(x); x += w }

        for (r, cells) in rendered.enumerated() {
            let text = NSMutableAttributedString()
            var tabs: [NSTextTab] = []
            for c in 0..<columns {
                let alignment = c < table.alignments.count ? table.alignments[c] : nil
                switch alignment {
                case .center?: tabs.append(NSTextTab(textAlignment: .center, location: starts[c] + widths[c] / 2))
                case .right?: tabs.append(NSTextTab(textAlignment: .right, location: starts[c] + widths[c] - 12))
                default: tabs.append(NSTextTab(textAlignment: .left, location: starts[c] + 12))
                }
                text.append(NSAttributedString(string: "\t", attributes: [.font: cellFont]))
                text.append(cells[c])
            }
            let style = paragraphStyle(context, spaceBefore: (r == 0 ? spaceBefore : 0) + 8, textStyle: nil)
            style.firstLineHeadIndent = context.indent
            style.headIndent = context.indent + 12
            style.tabStops = tabs
            style.paragraphSpacing = 8
            let last = r == rendered.count - 1
            let box = MarkdownDecoration.Box(
                left: context.indent, fill: r == 0 ? sunken : nil, border: border, isFirst: r == 0, isLast: last,
                padTop: 8, padBottom: 8, lineBelow: last ? nil : (r == 0 ? border : rowBorder)
            )
            paragraphs.append(Paragraph(text: text, style: style, quotes: context.quotes, box: box))
        }
    }

    // MARK: Footnotes

    /// remark-rehype's footnote section: a numbered list (its screen-reader heading is hidden), each
    /// note ending in ↩ back to its reference.
    mutating func footnotes(_ notes: [MarkdownFootnote]) {
        for (i, note) in notes.enumerated() {
            let start = paragraphs.count
            let spaceBefore = i > 0 ? Self.itemGap : paragraphs.isEmpty ? 0 : Self.blockGap
            let item = MarkdownListItem(blocks: note.blocks.isEmpty ? [.paragraph([])] : note.blocks)
            list(MarkdownList(ordered: true, start: note.number, items: [item]), context: root, spaceBefore: spaceBefore)
            footnoteParagraphs[note.number] = start
            let back = NSAttributedString(string: " ↩", attributes: [.font: base, .foregroundColor: accent, .link: MarkdownLinkTarget.action("fnref", note.number)])
            paragraphs[paragraphs.count - 1].text.append(back)
        }
    }

    // MARK: Inlines

    mutating func append(inlines: [MarkdownInline], context: Context, font: NSFont, spaceBefore: CGFloat, textStyle: ThemeTokens.TextStyle? = nil) {
        let text = NSMutableAttributedString(attributedString: inlineText(inlines, font: font, color: context.color))
        if text.length == 0 { text.append(NSAttributedString(string: "\u{200B}", attributes: [.font: font])) }
        paragraphs.append(Paragraph(text: text, style: paragraphStyle(context, spaceBefore: spaceBefore, textStyle: textStyle ?? options.textStyle), quotes: context.quotes))
    }

    mutating func inlineText(_ inlines: [MarkdownInline], font: NSFont, color: NSColor, link: URL? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines { out.append(self.inline(inline, font: font, color: color, link: link)) }
        return out
    }

    mutating func inline(_ inline: MarkdownInline, font: NSFont, color: NSColor, link: URL?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let link { attributes[.link] = link }
        switch inline {
        case .text(let text):
            return NSAttributedString(string: collapsingWhitespace(text), attributes: attributes)
        case .emphasis(let children):
            return inlineText(children, font: font.with(trait: .italic), color: color, link: link)
        case .strong(let children):
            return inlineText(children, font: font.with(trait: .bold), color: color, link: link)
        case .strikethrough(let children):
            let s = NSMutableAttributedString(attributedString: inlineText(children, font: font, color: color, link: link))
            s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: s.length))
            return s
        case .code(let code):
            // Rounded neutral pill painted by `MarkdownLayoutFragment` instead of a sharp selection-blue `.backgroundColor`.
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: theme.contentPointSize(.mono), weight: .regular)
            attributes[.foregroundColor] = self.color("text", .labelColor)
            attributes[.markdownInlineCode] = MarkdownInlineCodeStyle(
                fill: self.color("surface-raised", self.color("surface", NSColor.labelColor.withAlphaComponent(0.08))),
                border: self.color("border-subtle", self.color("border", NSColor.separatorColor.withAlphaComponent(0.45)))
            )
            return NSAttributedString(string: code, attributes: attributes)
        case .math(let tex):
            if let drawn = options.math[MarkdownMath(tex: tex, display: false)] {
                // On the text's baseline: the image hangs below it by its depth.
                let attachment = NSTextAttachment()
                attachment.image = drawn.image
                let size = drawn.image.size
                attachment.bounds = CGRect(x: 0, y: -(size.height - drawn.ascent), width: size.width, height: size.height)
                let s = NSMutableAttributedString(attachment: attachment)
                attributes[.toolTip] = tex
                s.addAttributes(attributes, range: NSRange(location: 0, length: s.length))
                return s
            }
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
            return NSAttributedString(string: tex, attributes: attributes)
        case .html(let html):
            return NSAttributedString(string: html, attributes: attributes)
        case .lineBreak:
            return NSAttributedString(string: "\u{2028}", attributes: attributes)
        case .footnoteReference(let n):
            // `<sup><a>n</a></sup>`.
            attributes[.font] = NSFont.systemFont(ofSize: font.pointSize * 0.75)
            attributes[.baselineOffset] = font.pointSize * 0.35
            attributes[.foregroundColor] = accent
            attributes[.link] = MarkdownLinkTarget.action("footnote", n)
            if footnoteReferenceParagraphs[n] == nil { footnoteReferenceParagraphs[n] = paragraphs.count }
            return NSAttributedString(string: String(n), attributes: attributes)
        case .image(let url, let alt, let title):
            if let image = options.images[url] {
                let attachment = NSTextAttachment()
                attachment.image = image
                let maxWidth = max(40, options.width - 4)
                let scale = min(1, maxWidth / max(image.size.width, 1))
                attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                let s = NSMutableAttributedString(attachment: attachment)
                if let title, !title.isEmpty { s.addAttribute(.toolTip, value: title, range: NSRange(location: 0, length: s.length)) }
                if let link { s.addAttribute(.link, value: link, range: NSRange(location: 0, length: s.length)) }
                return s
            }
            attributes[.foregroundColor] = self.color("text-tertiary", .tertiaryLabelColor)
            return NSAttributedString(string: alt.isEmpty ? "[image]" : alt, attributes: attributes)
        case .link(let url, let title, let children):
            return linkText(url: url, title: title, children: children, font: font, color: color)
        }
    }

    mutating func linkText(url: String, title: String?, children: [MarkdownInline], font: NSFont, color: NSColor) -> NSAttributedString {
        if url.hasPrefix(MarkdownSource.citeScheme), let n = Int(url.dropFirst(MarkdownSource.citeScheme.count)) {
            // cite-marker.tsx: an 11px mono semibold number on `accent-soft`, raised a little.
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: theme.contentPointSize(.micro) + 1, weight: .semibold),
                .foregroundColor: accent,
                .backgroundColor: self.color("accent-soft", NSColor.controlAccentColor.withAlphaComponent(0.15)),
                .baselineOffset: 2,
                .toolTip: "Source \(n)",
            ]
            if let link = URL(string: url) { attributes[.link] = link }
            return NSAttributedString(string: "\u{202F}\(n)\u{202F}", attributes: attributes)
        }
        if url.hasPrefix(MarkdownSource.wikiLinkScheme) {
            let ref = String(url.dropFirst(MarkdownSource.wikiLinkScheme.count)).removingPercentEncoding ?? ""
            switch options.links[ref] {
            case .resolved(let href, let tooltip)?:
                let s = NSMutableAttributedString(attributedString: inlineText(children, font: font, color: accent, link: URL(string: href)))
                s.addAttribute(.toolTip, value: tooltip, range: NSRange(location: 0, length: s.length))
                return s
            case .unresolved?:
                // A ghost: tertiary with a dashed underline; clicking creates the page.
                let s = NSMutableAttributedString(attributedString: inlineText(children, font: font, color: self.color("text-tertiary", .tertiaryLabelColor), link: URL(string: url)))
                let range = NSRange(location: 0, length: s.length)
                s.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue, range: range)
                s.addAttribute(.toolTip, value: "“\(MarkdownSource.wikiRefs("[[\(ref)]]").first?.target ?? ref)” doesn't exist yet. Click to create it.", range: range)
                return s
            case nil:
                // Still resolving: accent text that goes nowhere yet.
                return inlineText(children, font: font, color: accent)
            }
        }
        let s = NSMutableAttributedString(attributedString: inlineText(children, font: font, color: accent, link: URL(string: url)))
        if let title, !title.isEmpty { s.addAttribute(.toolTip, value: title, range: NSRange(location: 0, length: s.length)) }
        return s
    }

    /// HTML collapses runs of whitespace and shows a soft line break as a space.
    func collapsingWhitespace(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in text {
            if ch == " " || ch == "\n" || ch == "\t" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let s), .code(let s), .math(let s), .html(let s): return s
            case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, _, let c): return plainText(c)
            case .image(_, let alt, _): return alt
            case .lineBreak: return " "
            case .footnoteReference: return ""
            }
        }.joined()
    }

    // MARK: Paragraphs

    func paragraphStyle(_ context: Context, spaceBefore: CGFloat, textStyle: ThemeTokens.TextStyle?) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = context.indent
        style.headIndent = context.indent
        style.paragraphSpacingBefore = spaceBefore
        if let textStyle { style.lineSpacing = theme.contentLineSpacing(textStyle) }
        return style
    }

    mutating func finish() -> MarkdownRendering {
        // Each quote's bar starts at its first paragraph and ends at its last.
        var firstOfQuote: [Int: Int] = [:]
        var lastOfQuote: [Int: Int] = [:]
        for (i, p) in paragraphs.enumerated() {
            for q in p.quotes {
                if firstOfQuote[q] == nil { firstOfQuote[q] = i }
                lastOfQuote[q] = i
            }
        }
        let out = NSMutableAttributedString()
        var starts: [Int] = []
        var rightTabStops: [MarkdownRightTabStop] = []
        for (i, p) in paragraphs.enumerated() {
            let start = out.length
            starts.append(start)
            let text = p.text
            if i < paragraphs.count - 1 { text.append(NSAttributedString(string: "\n", attributes: text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:])) }
            let range = NSRange(location: 0, length: text.length)
            text.addAttribute(.paragraphStyle, value: p.style, range: range)
            let bars = p.quotes.compactMap { q -> MarkdownDecoration.QuoteBar? in
                guard let bar = quoteBars[q] else { return nil }
                return MarkdownDecoration.QuoteBar(x: bar.x, color: bar.color, isFirst: firstOfQuote[q] == i, isLast: lastOfQuote[q] == i)
            }
            if p.box != nil || !bars.isEmpty || p.rule != nil {
                text.addAttribute(.markdownDecoration, value: MarkdownDecoration(box: p.box, quoteBars: bars, rule: p.rule), range: range)
            }
            if let tab = p.rightTabStop {
                rightTabStops.append(MarkdownRightTabStop(
                    range: NSRange(location: start, length: text.length),
                    minLocation: tab.minLocation,
                    trailingInset: tab.trailingInset
                ))
            }
            out.append(text)
        }
        let location = { (paragraph: Int) in paragraph < starts.count ? starts[paragraph] : out.length }
        return MarkdownRendering(
            text: out,
            anchors: anchorParagraphs.mapValues(location),
            footnotes: footnoteParagraphs.mapValues(location),
            footnoteReferences: footnoteReferenceParagraphs.mapValues(location),
            rightTabStops: rightTabStops
        )
    }
}

private extension NSFont {
    func with(trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
#endif
