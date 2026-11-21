import Foundation

/// Parsed markdown, in the shape `web/components/domain/markdown.tsx` renders: GFM blocks and
/// inlines, `$$` math, and footnotes gathered at the end numbered by first reference (as
/// remark-rehype lists them). Wiki links, ticket keys and citations are links with the
/// `wikilink:` and `cite:` schemes (`MarkdownSource`).
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]
    /// Footnote definitions in reference order; `number` is what the reference shows.
    public var footnotes: [MarkdownFootnote]

    public init(blocks: [MarkdownBlock], footnotes: [MarkdownFootnote] = []) {
        self.blocks = blocks
        self.footnotes = footnotes
    }
}

public struct MarkdownFootnote: Sendable, Equatable {
    public var number: Int
    public var blocks: [MarkdownBlock]

    public init(number: Int, blocks: [MarkdownBlock]) {
        self.number = number
        self.blocks = blocks
    }
}

public indirect enum MarkdownBlock: Sendable, Equatable {
    case paragraph([MarkdownInline])
    case heading(level: Int, [MarkdownInline])
    case blockquote([MarkdownBlock])
    case list(MarkdownList)
    /// A fenced or indented block; `info` is the fence's info string ("go", "ts title").
    case code(info: String, code: String)
    /// A `$$` display formula, shown as its TeX source.
    case math(String)
    /// Raw HTML, which the web escapes and shows as text.
    case html(String)
    case thematicBreak
    case table(MarkdownTable)
}

public struct MarkdownList: Sendable, Equatable {
    public var ordered: Bool
    public var start: Int
    public var items: [MarkdownListItem]

    public init(ordered: Bool, start: Int = 1, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

public struct MarkdownListItem: Sendable, Equatable {
    /// A task list item's checkbox; nil for an ordinary item.
    public var checked: Bool?
    public var blocks: [MarkdownBlock]

    public init(checked: Bool? = nil, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public enum MarkdownAlignment: String, Sendable, Equatable {
    case left, center, right
}

public struct MarkdownTable: Sendable, Equatable {
    /// One per column; nil leaves the column's text at its natural (leading) alignment.
    public var alignments: [MarkdownAlignment?]
    public var header: [[MarkdownInline]]
    public var rows: [[[MarkdownInline]]]

    public init(alignments: [MarkdownAlignment?], header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

public indirect enum MarkdownInline: Sendable, Equatable {
    /// Text; a soft line break is a "\n" in it.
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case math(String)
    case link(url: String, title: String?, [MarkdownInline])
    case image(url: String, alt: String, title: String?)
    case lineBreak
    case html(String)
    case footnoteReference(Int)
}

/// A code block, for highlighting and Copy.
public struct MarkdownCodeBlock: Sendable, Hashable {
    public var code: String
    /// Shiki's language from the fence, nil for plain text.
    public var language: String?

    public init(code: String, language: String?) {
        self.code = code
        self.language = language
    }
}

extension MarkdownDocument {
    /// Every block, depth first in reading order, footnotes last: the order the renderer numbers
    /// code blocks in.
    public var allBlocks: [MarkdownBlock] {
        func walk(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
            blocks.flatMap { block -> [MarkdownBlock] in
                switch block {
                case .blockquote(let inner): return [block] + walk(inner)
                case .list(let list): return [block] + list.items.flatMap { walk($0.blocks) }
                default: return [block]
                }
            }
        }
        return walk(blocks) + footnotes.flatMap { walk($0.blocks) }
    }

    /// The code blocks, indexed as `MarkdownRenderOptions.highlights` keys them.
    public var codeBlocks: [MarkdownCodeBlock] {
        allBlocks.compactMap { block in
            guard case .code(let info, let code) = block else { return nil }
            return MarkdownCodeBlock(code: code, language: MarkdownSource.language(fromFence: info))
        }
    }

    /// Every inline, depth first (paragraphs, headings, table cells, link text).
    public var allInlines: [MarkdownInline] {
        func walk(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
            inlines.flatMap { inline -> [MarkdownInline] in
                switch inline {
                case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, _, let c): return [inline] + walk(c)
                default: return [inline]
                }
            }
        }
        return allBlocks.flatMap { block -> [MarkdownInline] in
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines): return walk(inlines)
            case .table(let table): return ([table.header] + table.rows).flatMap { $0.flatMap(walk) }
            default: return []
            }
        }
    }

    /// The `[[refs]]` to resolve with GET /knowledge/resolve, each once, in order.
    public var wikiRefs: [String] {
        var out: [String] = []
        for case .link(let url, _, _) in allInlines where url.hasPrefix(MarkdownSource.wikiLinkScheme) {
            let ref = String(url.dropFirst(MarkdownSource.wikiLinkScheme.count)).removingPercentEncoding ?? ""
            if !ref.isEmpty && !out.contains(ref) { out.append(ref) }
        }
        return out
    }

    /// Image URLs, each once, in order.
    public var imageURLs: [String] {
        var out: [String] = []
        for case .image(let url, _, _) in allInlines where !out.contains(url) { out.append(url) }
        return out
    }
}

// MARK: - Snapshots

extension MarkdownDocument {
    /// The document as JSON-compatible values in the normalized mdast shape
    /// `web/scripts/markdown-fixtures.mjs` writes, so tests compare the two renderers' structure.
    public func snapshot() -> [String: Any] {
        [
            "type": "root",
            "children": blocks.map(\.snapshot),
            "footnotes": footnotes.map { ["type": "footnote", "n": $0.number, "children": $0.blocks.map(\.snapshot)] as [String: Any] },
        ]
    }
}

extension MarkdownBlock {
    var snapshot: [String: Any] {
        switch self {
        case .paragraph(let inlines): return ["type": "paragraph", "children": inlines.map(\.snapshot)]
        case .heading(let level, let inlines): return ["type": "heading", "depth": level, "children": inlines.map(\.snapshot)]
        case .blockquote(let blocks): return ["type": "blockquote", "children": blocks.map(\.snapshot)]
        case .list(let list):
            var node: [String: Any] = ["type": "list", "ordered": list.ordered]
            if list.ordered { node["start"] = list.start }
            node["children"] = list.items.map { item -> [String: Any] in
                var node: [String: Any] = ["type": "listItem", "children": item.blocks.map(\.snapshot)]
                if let checked = item.checked { node["checked"] = checked }
                return node
            }
            return node
        case .code(let info, let code): return ["type": "code", "info": info, "value": code]
        case .math(let tex): return ["type": "math", "value": tex]
        case .html(let html): return ["type": "html", "value": html]
        case .thematicBreak: return ["type": "thematicBreak"]
        case .table(let table):
            let row = { (cells: [[MarkdownInline]]) -> [String: Any] in
                ["type": "tableRow", "children": cells.map { ["type": "tableCell", "children": $0.map(\.snapshot)] as [String: Any] }]
            }
            return [
                "type": "table",
                "align": table.alignments.map { $0.map { $0.rawValue as Any } ?? NSNull() },
                "children": [row(table.header)] + table.rows.map(row),
            ]
        }
    }
}

extension MarkdownInline {
    var snapshot: [String: Any] {
        switch self {
        case .text(let text): return ["type": "text", "value": text]
        case .emphasis(let inlines): return ["type": "emphasis", "children": inlines.map(\.snapshot)]
        case .strong(let inlines): return ["type": "strong", "children": inlines.map(\.snapshot)]
        case .strikethrough(let inlines): return ["type": "delete", "children": inlines.map(\.snapshot)]
        case .code(let code): return ["type": "inlineCode", "value": code]
        case .math(let tex): return ["type": "inlineMath", "value": tex]
        case .link(let url, let title, let inlines):
            var node: [String: Any] = ["type": "link", "url": url, "children": inlines.map(\.snapshot)]
            if let title, !title.isEmpty { node["title"] = title }
            return node
        case .image(let url, let alt, let title):
            var node: [String: Any] = ["type": "image", "url": url, "alt": alt]
            if let title, !title.isEmpty { node["title"] = title }
            return node
        case .lineBreak: return ["type": "break"]
        case .html(let html): return ["type": "html", "value": html]
        case .footnoteReference(let number): return ["type": "footnoteReference", "n": number]
        }
    }
}
