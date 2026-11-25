#if os(macOS)
import AppKit

/// Lays a `PrintDocument` out as attributed text for paper: TextKit 1 text blocks and tables give
/// code, callouts, quotes and tables their boxes, so AppKit's own pagination splits them between
/// lines rather than through them. Always the light paper palette, whatever the app's theme, and
/// the sizes the HTML printout had (a CSS px is 0.75pt on paper).
@MainActor
public enum PrintRenderer {
    /// The text for `document` at `width` points (the printable width). `images` are the fetched
    /// `document.imageURLs`; an image that didn't load prints as its alt text.
    public static func render(_ document: PrintDocument, width: CGFloat, images: [String: NSImage] = [:]) -> NSAttributedString {
        var builder = PrintTextBuilder(style: PrintStyleSheet(document.style), width: width, images: images)
        builder.document(document)
        return builder.out
    }

    /// Paper setup shared by the dialog and tests: US Letter or the person's default paper, with
    /// room in the margins for the running title and page numbers.
    public static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        return info
    }

    /// The width text lays out in on `info`'s paper.
    public static func printableWidth(_ info: NSPrintInfo) -> CGFloat {
        max(144, info.paperSize.width - info.leftMargin - info.rightMargin)
    }
}

/// A TextKit 1 text view holding a printout: as tall as its text at a fixed width, with the
/// document's title in each page's header and "Page n of m" in its footer. The preview shows the
/// same view, so what's on screen is what prints.
@MainActor
public final class PrintTextView: NSTextView {
    public let documentTitle: String

    public init(text: NSAttributedString, title: String, width: CGFloat) {
        documentTitle = title
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 1), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = true
        backgroundColor = .white
        textContainerInset = .zero
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = CGSize(width: width, height: 0)
        maxSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The running title top left and "Page n of m" bottom centre, inside the page's margins
    /// (AppKit's own header and footer sit at the paper's edge and add the date).
    public override func drawPageBorder(with borderSize: NSSize) {
        super.drawPageBorder(with: borderSize)
        guard let op = NSPrintOperation.current else { return }
        let info = op.printInfo
        let width = borderSize.width - info.leftMargin - info.rightMargin
        let pages = op.pageRange.length
        let footer = pages > 0 ? "Page \(op.currentPage) of \(pages)" : "Page \(op.currentPage)"
        // The page border's coordinates are this (flipped) view's: y grows down from the top edge.
        let lineHeight: CGFloat = 12
        NSAttributedString(string: documentTitle, attributes: Self.marginAttributes(alignment: .left))
            .draw(in: CGRect(x: info.leftMargin, y: info.topMargin / 2 - lineHeight / 2, width: width, height: lineHeight))
        NSAttributedString(string: footer, attributes: Self.marginAttributes(alignment: .center))
            .draw(in: CGRect(x: info.leftMargin, y: borderSize.height - info.bottomMargin / 2 - lineHeight / 2, width: width, height: lineHeight))
    }

    private static func marginAttributes(alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: PrintStyleSheet.hex("#71717a"), .paragraphStyle: style]
    }
}

// MARK: - Style sheet

/// The HTML printout's `@media print` palette and each paper style's type, in points.
struct PrintStyleSheet {
    enum Family { case sans, serif }

    let style: KnowledgePrintStyle
    let family: Family
    /// Body text size and CSS line-height.
    let size: CGFloat
    let lineHeight: CGFloat
    let titleSize: CGFloat
    /// Space between the header, query and body; between body segments; between prose blocks.
    let sectionGap: CGFloat
    let segmentGap: CGFloat
    let proseGap: CGFloat

    let ink: NSColor
    let ink2: NSColor
    let muted: NSColor
    let border: NSColor
    let surface: NSColor
    let subtle: NSColor
    let accent: NSColor

    init(_ style: KnowledgePrintStyle) {
        self.style = style
        let px: (CGFloat) -> CGFloat = { $0 * 0.75 }
        let editorial = style == .editorial
        family = editorial ? .serif : .sans
        switch style {
        case .clean: (size, lineHeight, titleSize) = (px(15), 1.68, px(28))
        case .editorial: (size, lineHeight, titleSize) = (px(16), 1.78, px(31))
        case .compact: (size, lineHeight, titleSize) = (px(13), 1.48, px(22))
        case .technical: (size, lineHeight, titleSize) = (px(14), 1.58, px(28))
        }
        let compact = style == .compact
        sectionGap = px(compact ? 12 : 20)
        segmentGap = px(compact ? 8 : 14)
        proseGap = px(compact ? 8 : 10)
        ink = Self.hex(editorial ? "#1c1917" : "#18181b")
        ink2 = Self.hex(editorial ? "#292524" : "#27272a")
        muted = Self.hex(editorial ? "#57534e" : "#52525b")
        border = Self.hex(editorial ? "#d6d3d1" : "#d4d4d8")
        surface = Self.hex(editorial ? "#f5f5f4" : "#f4f4f5")
        subtle = Self.hex("#fafafa")
        accent = Self.hex(editorial ? "#9a3412" : style == .technical ? "#0f766e" : "#2563eb")
    }

    static func px(_ v: CGFloat) -> CGFloat { v * 0.75 }

    static func hex(_ hex: String) -> NSColor {
        guard let c = RGBA(hex: hex) else { return .black }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    func calloutColors(_ tone: PrintDocumentBuilder.CalloutTone) -> (fill: NSColor, bar: NSColor) {
        switch tone {
        case .note: (Self.hex("#eff6ff"), accent)
        case .tip: (Self.hex("#ecfdf5"), Self.hex("#059669"))
        case .warning: (Self.hex("#fffbeb"), Self.hex("#b45309"))
        case .danger: (Self.hex("#fef2f2"), Self.hex("#b91c1c"))
        case .quote: (surface, muted)
        }
    }

    func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, mono: Bool = false, family: Family? = nil) -> NSFont {
        var font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if !mono, (family ?? self.family) == .serif,
           let serif = font.fontDescriptor.withDesign(.serif).flatMap({ NSFont(descriptor: $0, size: size) }) {
            font = serif
        }
        if italic, let slanted = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) {
            font = slanted
        }
        return font
    }

    /// Extra space between lines for a CSS line-height (a font's natural line is about 1.2em).
    func lineSpacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat { max(0, size * (lineHeight - 1.2)) }
}

// MARK: - Builder

/// Appends paragraphs one at a time; each carries the text blocks it sits in (outermost first).
@MainActor
private struct PrintTextBuilder {
    struct Context {
        /// Enclosing boxes: quotes, callouts, embeds, table cells.
        var blocks: [NSTextBlock] = []
        /// How far the enclosing boxes and list indents take text in from the page edge.
        var inset: CGFloat = 0
        /// List indent inside the innermost box.
        var indent: CGFloat = 0
        var color: NSColor
        var italic = false
        var size: CGFloat
        var lineHeight: CGFloat
    }

    struct InlineStyle {
        var bold = false
        var italic = false
        var mono = false
        var strike = false
        var color: NSColor
        var size: CGFloat
        var link: URL?
        var underline = false
    }

    let sheet: PrintStyleSheet
    let width: CGFloat
    let images: [String: NSImage]
    var out = NSMutableAttributedString()
    /// Space owed above the next paragraph; folded into the margin of a box opened before it.
    private var pendingSpace: CGFloat = 0

    init(style: PrintStyleSheet, width: CGFloat, images: [String: NSImage]) {
        sheet = style
        self.width = width
        self.images = images
    }

    var root: Context { Context(color: sheet.ink2, size: sheet.size, lineHeight: sheet.lineHeight) }
    var px: (CGFloat) -> CGFloat { PrintStyleSheet.px }

    // MARK: Document

    mutating func document(_ doc: PrintDocument) {
        header(doc.header)
        if let query = doc.query {
            pendingSpace = sheet.sectionGap
            queryTable(query)
        }
        pendingSpace = out.length == 0 ? 0 : sheet.sectionGap
        for (i, block) in doc.body.enumerated() {
            if i > 0 { pendingSpace = sheet.segmentGap }
            self.block(block, context: root)
        }
        // A trailing newline would print one more (empty) line; the last paragraph needs none.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
    }

    mutating func header(_ header: PrintHeader) {
        let technical = sheet.style == .technical
        let box = Self.newBlock()
        if technical {
            box.backgroundColor = sheet.subtle
            box.setWidth(1, type: .absoluteValueType, for: .border)
            box.setBorderColor(sheet.border)
            box.setWidth(px(3.5), type: .absoluteValueType, for: .border, edge: .minX)
            box.setBorderColor(sheet.accent, for: .minX)
            box.setWidth(px(14), type: .absoluteValueType, for: .padding, edge: .minY)
            box.setWidth(px(14), type: .absoluteValueType, for: .padding, edge: .maxY)
            box.setWidth(px(16), type: .absoluteValueType, for: .padding, edge: .minX)
            box.setWidth(px(16), type: .absoluteValueType, for: .padding, edge: .maxX)
        } else {
            let editorial = sheet.style == .editorial
            box.setWidth(editorial ? px(1.5) : 1, type: .absoluteValueType, for: .border, edge: .maxY)
            box.setBorderColor(editorial ? sheet.ink : sheet.border, for: .maxY)
            box.setWidth(px(sheet.style == .compact ? 10 : 16), type: .absoluteValueType, for: .padding, edge: .maxY)
        }
        var context = root
        context.blocks = [box]
        let gap = px(sheet.style == .compact ? 6 : 10)
        let labelFamily: PrintStyleSheet.Family = .sans
        var first = true
        func spacing() -> CGFloat { defer { first = false }; return first ? 0 : gap }

        if let folder = header.folder {
            let text = NSAttributedString(string: folder.uppercased(), attributes: [
                .font: sheet.font(size: px(11), weight: .semibold, mono: technical, family: labelFamily),
                .foregroundColor: sheet.muted, .kern: px(11) * 0.04,
            ])
            paragraph(text, context: context, spaceBefore: spacing(), size: px(11), lineHeight: 1.3)
        }
        if let title = header.title {
            let text = NSAttributedString(string: title, attributes: [
                .font: sheet.font(size: sheet.titleSize, weight: .bold), .foregroundColor: sheet.ink, .kern: -sheet.titleSize * 0.02,
            ])
            paragraph(text, context: context, spaceBefore: spacing(), size: sheet.titleSize, lineHeight: 1.2)
        }
        if let meta = header.metaLine {
            let text = NSAttributedString(string: meta, attributes: [.font: sheet.font(size: px(12), mono: true), .foregroundColor: sheet.muted])
            paragraph(text, context: context, spaceBefore: spacing(), size: px(12), lineHeight: 1.45)
        }
        if let summary = header.summary {
            let text = NSAttributedString(string: summary, attributes: [.font: sheet.font(size: px(14)), .foregroundColor: sheet.ink2])
            paragraph(text, context: context, spaceBefore: spacing(), size: px(14), lineHeight: 1.6)
        }
        if !header.properties.isEmpty {
            properties(header.properties, context: context, spaceBefore: spacing())
        }
    }

    /// Key and value in two columns (the value wrapping under itself); Compact runs them together.
    mutating func properties(_ props: [PrintProperty], context: Context, spaceBefore: CGFloat) {
        let size = px(sheet.style == .compact ? 11.5 : 12.5)
        let mono = sheet.style == .technical
        let keyFont = sheet.font(size: size, weight: .medium, mono: mono, family: .sans)
        let valueFont = sheet.font(size: size)
        func value(_ v: PrintProperty.Value) -> NSAttributedString {
            switch v {
            case .text(let s):
                return NSAttributedString(string: s, attributes: [.font: valueFont, .foregroundColor: sheet.ink2])
            case .tags(let tags):
                let tagFont = sheet.font(size: px(11), weight: .medium, mono: mono, family: .sans)
                let out = NSMutableAttributedString()
                for (i, tag) in tags.enumerated() {
                    if i > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: valueFont])) }
                    out.append(NSAttributedString(string: "\u{2009}#\(tag)\u{2009}", attributes: [.font: tagFont, .foregroundColor: sheet.ink2, .backgroundColor: sheet.surface]))
                }
                return out
            }
        }
        // The properties sit under a rule inside the header.
        let rule = Self.newBlock()
        rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        rule.setBorderColor(sheet.border, for: .minY)
        rule.setWidth(px(sheet.style == .compact ? 8 : 10), type: .absoluteValueType, for: .padding, edge: .minY)
        rule.setWidth(spaceBefore + px(4), type: .absoluteValueType, for: .margin, edge: .minY)
        var inner = context
        inner.blocks.append(rule)

        if sheet.style == .compact {
            let text = NSMutableAttributedString()
            for (i, prop) in props.enumerated() {
                if i > 0 { text.append(NSAttributedString(string: "    ", attributes: [.font: valueFont])) }
                text.append(NSAttributedString(string: prop.key + " ", attributes: [.font: keyFont, .foregroundColor: sheet.muted]))
                text.append(value(prop.value))
            }
            paragraph(text, context: inner, spaceBefore: 0, size: size, lineHeight: 1.5)
            return
        }
        let column = px(140) + px(12)
        for (i, prop) in props.enumerated() {
            let text = NSMutableAttributedString(string: prop.key, attributes: [.font: keyFont, .foregroundColor: sheet.muted])
            text.append(NSAttributedString(string: "\t", attributes: [.font: keyFont]))
            text.append(value(prop.value))
            let style = paragraphStyle(inner, spaceBefore: i == 0 ? 0 : px(4), size: size, lineHeight: 1.5)
            style.tabStops = [NSTextTab(textAlignment: .left, location: column)]
            style.headIndent = column
            append(text, style: style)
        }
    }

    mutating func queryTable(_ query: PrintQueryTable) {
        let size = sheet.size * 0.9
        let header = query.columns.map { NSAttributedString(string: $0, attributes: [.font: sheet.font(size: size, weight: .semibold), .foregroundColor: sheet.ink]) }
        let rows = query.rows.map { row in
            row.enumerated().map { i, cell in
                NSAttributedString(string: cell, attributes: [.font: sheet.font(size: size, weight: i == 0 ? .semibold : .regular), .foregroundColor: i == 0 ? sheet.ink : sheet.ink2])
            }
        }
        table(header: header, rows: rows, alignments: [], context: root, framed: true)
        if let note = query.footnote {
            let text = NSAttributedString(string: note, attributes: [.font: sheet.font(size: px(11.5)), .foregroundColor: sheet.muted])
            paragraph(text, context: root, spaceBefore: px(6), size: px(11.5), lineHeight: 1.45)
        }
    }

    // MARK: Blocks

    mutating func block(_ block: PrintBlock, context: Context) {
        switch block {
        case .markdown(let doc):
            markdown(doc, context: context)
        case .callout(let tone, let title, let body):
            let colors = sheet.calloutColors(tone)
            let box = self.box(fill: colors.fill, border: sheet.border, padding: (px(11), px(14)))
            box.setWidth(px(3), type: .absoluteValueType, for: .border, edge: .minX)
            box.setBorderColor(colors.bar, for: .minX)
            var inner = open(box, context: context, padX: px(14) + px(3))
            let titleSize = sheet.size * 0.92
            let titleText = NSAttributedString(string: title, attributes: [
                .font: sheet.font(size: titleSize, weight: .semibold, mono: sheet.style == .technical), .foregroundColor: sheet.ink,
            ])
            paragraph(titleText, context: inner, spaceBefore: 0, size: titleSize, lineHeight: 1.4)
            inner.color = sheet.ink2
            if !body.blocks.isEmpty || !body.footnotes.isEmpty {
                pendingSpace = px(6)
                markdown(body, context: inner)
            }
        case .image(let url, let alt):
            imageParagraph(url: url, alt: alt, context: context, maxHeight: px(460))
        case .page(let caption, let body):
            let box = self.box(fill: sheet.subtle, border: nil, padding: (px(12), px(16)))
            box.setWidth(px(3), type: .absoluteValueType, for: .border, edge: .minX)
            box.setBorderColor(sheet.border, for: .minX)
            let inner = open(box, context: context, padX: px(16) * 2 + px(3))
            if let caption {
                let text = NSAttributedString(string: caption, attributes: [.font: sheet.font(size: px(12), weight: .semibold, family: .sans), .foregroundColor: sheet.muted])
                paragraph(text, context: inner, spaceBefore: 0, size: px(12), lineHeight: 1.4)
                pendingSpace = px(8)
            }
            for (i, nested) in body.enumerated() {
                if i > 0 { pendingSpace = sheet.proseGap }
                self.block(nested, context: inner)
            }
        case .reference(let kind, let name):
            let box = self.box(fill: sheet.surface, border: sheet.border, padding: (px(8), px(12)))
            let inner = open(box, context: context, padX: px(24) + 2)
            let text = NSMutableAttributedString(string: kind.uppercased(), attributes: [
                .font: sheet.font(size: px(10.5), weight: .semibold, mono: true), .foregroundColor: sheet.muted, .kern: px(10.5) * 0.04,
            ])
            text.append(NSAttributedString(string: "   " + name, attributes: [.font: sheet.font(size: px(12.5), weight: .medium, family: .sans), .foregroundColor: sheet.ink]))
            paragraph(text, context: inner, spaceBefore: 0, size: px(12.5), lineHeight: 1.4)
        case .notice(let message):
            let text = NSAttributedString(string: message, attributes: [.font: sheet.font(size: px(12.5), italic: true), .foregroundColor: sheet.muted])
            paragraph(text, context: context, spaceBefore: 0, size: px(12.5), lineHeight: 1.45)
        }
    }

    mutating func markdown(_ doc: MarkdownDocument, context: Context) {
        blocks(doc.blocks, context: context, gap: sheet.proseGap)
        guard !doc.footnotes.isEmpty else { return }
        pendingSpace = sheet.proseGap
        rule(context: context)
        for note in doc.footnotes {
            pendingSpace = px(4)
            let item = MarkdownListItem(blocks: note.blocks.isEmpty ? [.paragraph([])] : note.blocks)
            list(MarkdownList(ordered: true, start: note.number, items: [item]), context: context, small: true)
        }
    }

    mutating func blocks(_ blocks: [MarkdownBlock], context: Context, gap: CGFloat) {
        for (i, block) in blocks.enumerated() {
            if i > 0 { pendingSpace = max(pendingSpace, gap) }
            markdownBlock(block, context: context)
        }
    }

    mutating func markdownBlock(_ block: MarkdownBlock, context: Context) {
        switch block {
        case .paragraph(let inlines):
            paragraph(inlineText(inlines, base: inlineStyle(context)), context: context, spaceBefore: 0, size: context.size, lineHeight: context.lineHeight)
        case .heading(let level, let inlines):
            heading(level, inlines, context: context)
        case .blockquote(let inner):
            let box = Self.newBlock()
            box.setWidth(px(2.5), type: .absoluteValueType, for: .border, edge: .minX)
            box.setBorderColor(sheet.border, for: .minX)
            box.setWidth(px(14), type: .absoluteValueType, for: .padding, edge: .minX)
            box.setWidth(px(2), type: .absoluteValueType, for: .padding, edge: .minY)
            box.setWidth(px(2), type: .absoluteValueType, for: .padding, edge: .maxY)
            var quoted = open(box, context: context, padX: px(14) + px(2.5))
            quoted.color = sheet.muted
            quoted.italic = sheet.style == .editorial
            blocks(inner, context: quoted, gap: sheet.proseGap)
        case .list(let list):
            self.list(list, context: context, small: false)
        case .code(_, let code):
            preformatted(code, context: context)
        case .math(let tex):
            displayMath(tex, context: context)
        case .html(let raw):
            preformatted(raw, context: context)
        case .thematicBreak:
            rule(context: context)
        case .table(let table):
            let size = context.size * 0.9
            let base = InlineStyle(color: context.color, size: size)
            var head = base
            head.bold = true
            head.color = sheet.ink
            let header = table.header.map { inlineText($0, base: head) }
            let rows = table.rows.map { $0.map { inlineText($0, base: base) } }
            self.table(header: header, rows: rows, alignments: table.alignments, context: context, framed: false)
        }
    }

    mutating func heading(_ level: Int, _ inlines: [MarkdownInline], context: Context) {
        let clamped = min(max(level, 1), 6)
        let (scale, margin): (CGFloat, CGFloat) = switch clamped {
        case 1, 2: (1.38, 1.15)
        case 3: (1.18, 1.05)
        case 4: (1.04, 0.85)
        default: (0.96, 0.7)
        }
        let size = context.size * scale
        var style = InlineStyle(color: sheet.ink, size: size)
        style.bold = true
        let text = inlineText(inlines, base: style)
        // CSS margin-top in em, on top of the gap (none at the very top of the page).
        if out.length > 0 { pendingSpace += size * margin }
        var inner = context
        if sheet.style == .technical && clamped <= 3 {
            let box = Self.newBlock()
            box.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            box.setBorderColor(sheet.border, for: .maxY)
            box.setWidth(px(4), type: .absoluteValueType, for: .padding, edge: .maxY)
            inner = open(box, context: context, padX: 0)
        }
        let paragraphStyle = paragraphStyle(inner, spaceBefore: takeSpace(), size: size, lineHeight: 1.3)
        paragraphStyle.paragraphSpacing = size * 0.15
        append(text, style: paragraphStyle)
    }

    mutating func list(_ list: MarkdownList, context: Context, small: Bool) {
        let isTaskList = list.items.contains { $0.checked != nil }
        let indent = context.size * 1.4
        var inner = context
        inner.indent += indent
        inner.inset += indent
        if small { inner.size = context.size * 0.9 }
        for (i, item) in list.items.enumerated() {
            if i > 0 { pendingSpace = max(pendingSpace, px(4)) }
            let first = out.length
            if item.blocks.isEmpty {
                paragraph(NSAttributedString(), context: inner, spaceBefore: 0, size: inner.size, lineHeight: inner.lineHeight)
            } else {
                blocks(item.blocks, context: inner, gap: 0)
            }
            guard first < out.length else { continue }
            let marker: String
            if let checked = item.checked { marker = checked ? "\u{2611}" : "\u{2610}" }
            else if isTaskList { marker = "" }
            else { marker = list.ordered ? "\(list.start + i)." : "\u{2022}" }
            let markerFont = sheet.font(size: inner.size)
            let markerText = NSAttributedString(string: "\t\(marker)\t", attributes: [.font: markerFont, .foregroundColor: item.checked != nil ? sheet.muted : inner.color])
            // The marker sits right-aligned in the indent, outside the text (list-style-position: outside).
            let paragraphRange = (out.string as NSString).paragraphRange(for: NSRange(location: first, length: 0))
            if let existing = out.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle,
               let style = existing.mutableCopy() as? NSMutableParagraphStyle {
                style.firstLineHeadIndent = context.indent
                style.tabStops = [NSTextTab(textAlignment: .right, location: inner.indent - px(6)), NSTextTab(textAlignment: .left, location: inner.indent)]
                    + style.tabStops.filter { $0.location > inner.indent }
                out.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
                out.insert(NSAttributedString(attributedString: markerText).withParagraphStyle(style), at: first)
            }
        }
    }

    /// `<pre>`: monospace on a light box; one paragraph per line so a long block breaks across pages.
    mutating func preformatted(_ code: String, context: Context) {
        let box = self.box(fill: sheet.surface, border: sheet.border, padding: (px(11), px(13)))
        let inner = open(box, context: context, padX: px(26) + 2)
        let size = context.size * 0.84
        let font = sheet.font(size: size, mono: true)
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            let style = paragraphStyle(inner, spaceBefore: 0, size: size, lineHeight: 1.55)
            style.lineBreakMode = .byCharWrapping
            style.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 8
            style.tabStops = []
            append(NSAttributedString(string: line.isEmpty ? " " : line, attributes: [.font: font, .foregroundColor: sheet.ink]), style: style)
        }
    }

    mutating func displayMath(_ tex: String, context: Context) {
        let available = width - context.inset
        if let image = mathImage(tex, display: true, size: context.size, color: context.color) {
            let attachment = NSTextAttachment()
            attachment.image = image.image
            let scale = min(1, available / max(image.image.size.width, 1))
            attachment.bounds = CGRect(x: 0, y: 0, width: image.image.size.width * scale, height: image.image.size.height * scale)
            let text = NSMutableAttributedString(attachment: attachment)
            text.addAttribute(.toolTip, value: tex, range: NSRange(location: 0, length: text.length))
            let style = paragraphStyle(context, spaceBefore: takeSpace(), size: context.size, lineHeight: 1.2)
            style.alignment = .center
            append(text, style: style)
        } else {
            preformatted(tex, context: context)
        }
    }

    /// A hairline across the column: an empty paragraph whose box has only a bottom border.
    mutating func rule(context: Context) {
        let box = Self.newBlock()
        box.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        box.setBorderColor(sheet.border, for: .maxY)
        let inner = open(box, context: context, padX: 0)
        let style = paragraphStyle(inner, spaceBefore: 0, size: 1, lineHeight: 1.2)
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        append(NSAttributedString(string: "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 1)]), style: style)
        pendingSpace = max(pendingSpace, px(8))
    }

    /// Markdown and saved-query tables as `NSTextTable`s: column widths from their content, a
    /// shaded header row and row rules (every cell framed in the Technical style).
    mutating func table(header: [NSAttributedString], rows: [[NSAttributedString]], alignments: [MarkdownAlignment?], context: Context, framed: Bool) {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(takeSpace(), type: .absoluteValueType, for: .margin, edge: .minY)
        if framed {
            table.setWidth(1, type: .absoluteValueType, for: .border)
            table.setBorderColor(sheet.border)
        }
        let grid = sheet.style == .technical
        let padY = px(sheet.style == .compact ? 4 : 7)
        let padX = px(sheet.style == .compact ? 8 : 10)
        for (r, cells) in all.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(padY, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(padY, type: .absoluteValueType, for: .padding, edge: .maxY)
                cell.setWidth(padX, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(padX, type: .absoluteValueType, for: .padding, edge: .maxX)
                if grid {
                    cell.setWidth(1, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(sheet.border)
                } else if r < all.count - 1 || !framed {
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(sheet.border, for: .maxY)
                }
                if r == 0 { cell.backgroundColor = sheet.surface }
                var inner = context
                inner.blocks.append(cell)
                inner.indent = 0
                let style = paragraphStyle(inner, spaceBefore: 0, size: context.size * 0.9, lineHeight: 1.45)
                switch c < alignments.count ? alignments[c] : nil {
                case .center?: style.alignment = .center
                case .right?: style.alignment = .right
                default: style.alignment = .natural
                }
                let text = c < cells.count ? cells[c] : NSAttributedString()
                append(text.length == 0 ? NSAttributedString(string: "\u{200B}", attributes: [.font: sheet.font(size: context.size * 0.9)]) : text, style: style)
            }
        }
    }

    mutating func imageParagraph(url: String, alt: String, context: Context, maxHeight: CGFloat) {
        let style = paragraphStyle(context, spaceBefore: takeSpace(), size: context.size, lineHeight: 1.2)
        append(imageText(url: url, alt: alt, base: inlineStyle(context), available: width - context.inset, maxHeight: maxHeight), style: style)
    }

    // MARK: Inlines

    func inlineStyle(_ context: Context) -> InlineStyle {
        var style = InlineStyle(color: context.color, size: context.size)
        style.italic = context.italic
        return style
    }

    func inlineText(_ inlines: [MarkdownInline], base: InlineStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines { out.append(self.inline(inline, style: base)) }
        return out
    }

    func inline(_ inline: MarkdownInline, style: InlineStyle) -> NSAttributedString {
        switch inline {
        case .text(let s):
            // A soft break is a space on paper, as in the browser.
            return text(s.replacingOccurrences(of: "\n", with: " "), style)
        case .emphasis(let children):
            var s = style
            s.italic = true
            return inlineText(children, base: s)
        case .strong(let children):
            var s = style
            s.bold = true
            return inlineText(children, base: s)
        case .strikethrough(let children):
            var s = style
            s.strike = true
            return inlineText(children, base: s)
        case .code(let code):
            var s = style
            s.mono = true
            s.size = style.size * 0.86
            s.color = sheet.ink
            let out = NSMutableAttributedString(attributedString: text("\u{2009}\(code)\u{2009}", s))
            out.addAttribute(.backgroundColor, value: sheet.surface, range: NSRange(location: 0, length: out.length))
            return out
        case .math(let tex):
            guard let image = mathImage(tex, display: false, size: style.size, color: style.color) else {
                var s = style
                s.mono = true
                s.size = style.size * 0.86
                return text(tex, s)
            }
            let attachment = NSTextAttachment()
            attachment.image = image.image
            let size = image.image.size
            attachment.bounds = CGRect(x: 0, y: image.ascent - size.height, width: size.width, height: size.height)
            return NSAttributedString(attachment: attachment)
        case .link(let url, _, let children):
            var s = style
            if url.hasPrefix("wikilink:") {
                s.color = sheet.ink
                s.underline = true
                return inlineText(children, base: s)
            }
            if url.hasPrefix("cite:") {
                let out = NSMutableAttributedString(attributedString: inlineText(children, base: s))
                out.addAttribute(.superscript, value: 1, range: NSRange(location: 0, length: out.length))
                return out
            }
            s.color = sheet.accent
            s.underline = true
            // Only absolute links stay clickable in a saved PDF; an in-app path has nowhere to go.
            if let link = URL(string: url), ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { s.link = link }
            return inlineText(children, base: s)
        case .image(let url, let alt, _):
            // The HTML printout's `img { max-height: 240mm }`.
            return imageText(url: url, alt: alt, base: style, available: width, maxHeight: 680)
        case .lineBreak:
            return text("\u{2028}", style)
        case .html(let raw):
            return text(raw, style)
        case .footnoteReference(let n):
            let out = NSMutableAttributedString(attributedString: text("[\(n)]", style))
            out.addAttribute(.superscript, value: 1, range: NSRange(location: 0, length: out.length))
            return out
        }
    }

    func text(_ string: String, _ style: InlineStyle) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: sheet.font(size: style.size, weight: style.bold ? .semibold : .regular, italic: style.italic, mono: style.mono),
            .foregroundColor: style.color,
        ]
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link { attrs[.link] = link }
        return NSAttributedString(string: string, attributes: attrs)
    }

    /// A fetched image, shrunk to the column (and `maxHeight`) but never enlarged; its alt text
    /// when it didn't load.
    func imageText(url: String, alt: String, base: InlineStyle, available: CGFloat, maxHeight: CGFloat) -> NSAttributedString {
        guard let image = images[url], image.size.width > 0, image.size.height > 0 else {
            var s = base
            s.italic = true
            s.color = sheet.muted
            return text(alt.isEmpty ? "Image" : alt, s)
        }
        let scale = min(1, max(1, available) / image.size.width, maxHeight / image.size.height)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    /// TeX drawn by `NativeMath` as a vector PDF image, in the text's colour; nil when it doesn't parse.
    func mathImage(_ tex: String, display: Bool, size: CGFloat, color: NSColor) -> (image: NSImage, ascent: CGFloat)? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let hex = String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        guard let drawn = NativeMath.render(MathRenderRequest(tex: tex, display: display, color: hex, fontSize: Double(size))),
              let image = NSImage(data: drawn.pdf) else { return nil }
        image.size = NSSize(width: drawn.width, height: drawn.height)
        return (image, CGFloat(drawn.ascent ?? drawn.height))
    }

    // MARK: Paragraphs

    /// A box as wide as the column it's in. TextKit 1 neither pads nor draws a block that has no
    /// content width, so every block gets one.
    static func newBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        return block
    }

    func box(fill: NSColor?, border: NSColor?, padding: (y: CGFloat, x: CGFloat)) -> NSTextBlock {
        let box = Self.newBlock()
        box.backgroundColor = fill
        if let border {
            box.setWidth(1, type: .absoluteValueType, for: .border)
            box.setBorderColor(border)
        }
        box.setWidth(padding.y, type: .absoluteValueType, for: .padding, edge: .minY)
        box.setWidth(padding.y, type: .absoluteValueType, for: .padding, edge: .maxY)
        box.setWidth(padding.x, type: .absoluteValueType, for: .padding, edge: .minX)
        box.setWidth(padding.x, type: .absoluteValueType, for: .padding, edge: .maxX)
        return box
    }

    /// Nests `box` in the context, with the space owed above it as its top margin and any list
    /// indent as its left margin, so the box itself sits where the text would have.
    mutating func open(_ box: NSTextBlock, context: Context, padX: CGFloat) -> Context {
        box.setWidth(takeSpace(), type: .absoluteValueType, for: .margin, edge: .minY)
        if context.indent > 0 { box.setWidth(context.indent, type: .absoluteValueType, for: .margin, edge: .minX) }
        var inner = context
        inner.blocks.append(box)
        inner.indent = 0
        inner.inset += padX
        return inner
    }

    mutating func takeSpace() -> CGFloat {
        defer { pendingSpace = 0 }
        return pendingSpace
    }

    mutating func paragraph(_ text: NSAttributedString, context: Context, spaceBefore: CGFloat, size: CGFloat, lineHeight: CGFloat) {
        let style = paragraphStyle(context, spaceBefore: spaceBefore + takeSpace(), size: size, lineHeight: lineHeight)
        let body = text.length == 0 ? NSAttributedString(string: "\u{200B}", attributes: [.font: sheet.font(size: size)]) : text
        append(body, style: style)
    }

    func paragraphStyle(_ context: Context, spaceBefore: CGFloat, size: CGFloat, lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = context.blocks
        style.firstLineHeadIndent = context.indent
        style.headIndent = context.indent
        style.paragraphSpacingBefore = spaceBefore
        style.lineSpacing = sheet.lineSpacing(size: size, lineHeight: lineHeight)
        return style
    }

    mutating func append(_ text: NSAttributedString, style: NSParagraphStyle) {
        let paragraph = NSMutableAttributedString(attributedString: text)
        // The newline keeps the last font (the line's height) but not a background or link, which
        // would otherwise run on to the end of the line.
        let font = text.length > 0 ? text.attribute(.font, at: text.length - 1, effectiveRange: nil) : nil
        paragraph.append(NSAttributedString(string: "\n", attributes: font.map { [.font: $0] } ?? [:]))
        out.append(paragraph.withParagraphStyle(style))
    }
}

private extension NSAttributedString {
    func withParagraphStyle(_ style: NSParagraphStyle) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: self)
        copy.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: copy.length))
        return copy
    }
}
#endif
