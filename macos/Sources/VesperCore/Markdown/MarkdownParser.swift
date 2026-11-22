import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Parses markdown into a `MarkdownDocument` with cmark-gfm (vendored in `macos/Vendor/cmark-gfm`):
/// CommonMark plus the GFM extensions remark-gfm gives the web (tables, task lists,
/// strikethrough, autolink literals, footnotes).
public enum MarkdownParser {
    /// Parses markdown as the web renders it: `MarkdownSource.prepare`'s rewrites, then the parse.
    public static func parse(_ markdown: String, chat: Bool = false, citations: [Int] = []) -> MarkdownDocument {
        parsePrepared(MarkdownSource.prepare(markdown, chat: chat, citations: citations))
    }

    /// Parses text that already went through `MarkdownSource.prepare`.
    static func parsePrepared(_ markdown: String) -> MarkdownDocument {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES) else { return MarkdownDocument(blocks: [.paragraph([.text(markdown)])]) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.utf8CString.withUnsafeBufferPointer { buffer in
            // The buffer ends in a NUL the parser mustn't see.
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1)
        }
        guard let root = cmark_parser_finish(parser) else { return MarkdownDocument(blocks: []) }
        defer { cmark_node_free(root) }

        // cmark moves referenced footnote definitions to the end, in reference order, and drops
        // the rest; each reference's literal is already its number.
        var blocks: [MarkdownBlock] = []
        var footnotes: [MarkdownFootnote] = []
        for child in children(root) {
            if cmark_node_get_type(child) == CMARK_NODE_FOOTNOTE_DEFINITION {
                footnotes.append(MarkdownFootnote(number: footnotes.count + 1, blocks: children(child).compactMap(block)))
            } else if let b = block(child) {
                blocks.append(b)
            }
        }
        return MarkdownDocument(blocks: blocks, footnotes: footnotes)
    }

    // MARK: Blocks

    private static func block(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlock? {
        switch typeName(node) {
        case "paragraph": return .paragraph(inlines(node))
        case "heading": return .heading(level: Int(cmark_node_get_heading_level(node)), inlines(node))
        case "block_quote": return .blockquote(children(node).compactMap(block))
        case "list": return .list(list(node))
        case "code_block":
            let info = string(cmark_node_get_fence_info(node))
            let code = trimmingFinalNewline(literal(node))
            if info == MarkdownSource.mathMarker + "math" { return .math(code) }
            return .code(info: normalizedInfo(info), code: code)
        case "html_block": return .html(trimmingNewlines(literal(node)))
        case "thematic_break": return .thematicBreak
        case "table": return table(node)
        default: return nil
        }
    }

    private static func list(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownList {
        let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        let items = children(node).map { item in
            MarkdownListItem(
                checked: typeName(item) == "tasklist" ? cmark_gfm_extensions_get_tasklist_item_checked(item) : nil,
                blocks: children(item).compactMap(block)
            )
        }
        return MarkdownList(ordered: ordered, start: ordered ? Int(cmark_node_get_list_start(node)) : 1, items: items)
    }

    private static func table(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlock {
        let columns = Int(cmark_gfm_extensions_get_table_columns(node))
        var alignments: [MarkdownAlignment?] = []
        if let raw = cmark_gfm_extensions_get_table_alignments(node) {
            for i in 0..<columns {
                switch UnicodeScalar(raw[i]) {
                case "l": alignments.append(.left)
                case "c": alignments.append(.center)
                case "r": alignments.append(.right)
                default: alignments.append(nil)
                }
            }
        }
        var header: [[MarkdownInline]] = []
        var rows: [[[MarkdownInline]]] = []
        for row in children(node) {
            let cells = children(row).map(inlines)
            if cmark_gfm_extensions_get_table_row_is_header(row) != 0 { header = cells } else { rows.append(cells) }
        }
        return .table(MarkdownTable(alignments: alignments, header: header, rows: rows))
    }

    // MARK: Inlines

    private static func inlines(_ node: UnsafeMutablePointer<cmark_node>) -> [MarkdownInline] {
        merged(children(node).compactMap(inline))
    }

    private static func inline(_ node: UnsafeMutablePointer<cmark_node>) -> MarkdownInline? {
        if cmark_node_get_type(node) == CMARK_NODE_FOOTNOTE_REFERENCE {
            return Int(literal(node)).map(MarkdownInline.footnoteReference) ?? .text(literal(node))
        }
        switch typeName(node) {
        case "text": return .text(literal(node))
        case "softbreak": return .text("\n")
        case "linebreak": return .lineBreak
        case "code":
            let code = literal(node)
            let marker = MarkdownSource.mathMarker
            if code.count >= 2, code.hasPrefix(marker), code.hasSuffix(marker) { return .math(String(code.dropFirst().dropLast())) }
            return .code(code)
        case "html_inline": return .html(literal(node))
        case "emph": return .emphasis(inlines(node))
        case "strong": return .strong(inlines(node))
        case "strikethrough": return .strikethrough(inlines(node))
        case "link":
            let title = string(cmark_node_get_title(node))
            return .link(url: string(cmark_node_get_url(node)), title: title.isEmpty ? nil : title, inlines(node))
        case "image":
            let title = string(cmark_node_get_title(node))
            return .image(url: string(cmark_node_get_url(node)), alt: plainText(inlines(node)), title: title.isEmpty ? nil : title)
        default: return nil
        }
    }

    /// An image's alt text: its inlines without formatting, as remark keeps it.
    private static func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let s), .code(let s), .math(let s), .html(let s): return s
            case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, _, let c): return plainText(c)
            case .image(_, let alt, _): return alt
            case .lineBreak: return "\n"
            case .footnoteReference(let n): return String(n)
            }
        }.joined()
    }

    /// Adjacent text joined (cmark splits text at brackets, entities and soft breaks).
    private static func merged(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        for inline in inlines {
            if case .text(let next) = inline, case .text(let previous)? = out.last {
                out[out.count - 1] = .text(previous + next)
            } else {
                out.append(inline)
            }
        }
        return out
    }

    // MARK: cmark helpers

    private static func children(_ node: UnsafeMutablePointer<cmark_node>) -> [UnsafeMutablePointer<cmark_node>] {
        var out: [UnsafeMutablePointer<cmark_node>] = []
        var child = cmark_node_first_child(node)
        while let c = child {
            out.append(c)
            child = cmark_node_next(c)
        }
        return out
    }

    private static func typeName(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        string(cmark_node_get_type_string(node))
    }

    private static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        string(cmark_node_get_literal(node))
    }

    private static func string(_ c: UnsafePointer<CChar>?) -> String {
        c.map { String(cString: $0) } ?? ""
    }

    private static func trimmingFinalNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }

    private static func trimmingNewlines(_ s: String) -> String {
        var s = s
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    /// "go   title" as remark splits it into lang and meta and the fixtures join them: "go title".
    private static func normalizedInfo(_ info: String) -> String {
        let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
        let meta = trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        return meta.isEmpty ? String(trimmed[..<space]) : "\(trimmed[..<space]) \(meta)"
    }
}
