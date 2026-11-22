import Foundation

// MARK: - Wiki Target

/// Parsed target of a `[[link]]` or `![[embed]]` matching `web/lib/wikilinks.ts` and `web/lib/knowledge-editor.ts`.
public struct KnowledgeWikiTarget: Sendable, Equatable, Hashable {
    /// Whole token as written, e.g. `[[Folder/Note#Intro|Overview]]` or `![[diagram.png]]`.
    public let raw: String
    /// Inner text with escaped `\|` normalized to `|`, as sent to `/knowledge/resolve`.
    public let ref: String
    /// Page path or name before `#`, `^`, and `|`.
    public let target: String
    /// Heading section after `#` (when not a `^block` reference).
    public let heading: String?
    /// Block identifier after `^` or `#^` (without the leading `^`).
    public let blockID: String?
    /// Combined anchor (`heading` or `^blockID`), matching `web/lib/wikilinks.ts`.
    public let anchor: String?
    /// Optional display alias after `|`.
    public let alias: String?
    /// `true` for `![[embed]]`, `false` for `[[link]]`.
    public let isEmbed: Bool

    public init(
        raw: String,
        ref: String,
        target: String,
        heading: String? = nil,
        blockID: String? = nil,
        anchor: String? = nil,
        alias: String? = nil,
        isEmbed: Bool = false
    ) {
        self.raw = raw
        self.ref = ref
        self.target = target
        self.heading = heading
        self.blockID = blockID
        self.anchor = anchor
        self.alias = alias
        self.isEmbed = isEmbed
    }

    /// Display text matching `defaultLabel` in `web/lib/wikilinks.ts`.
    public func displayLabel(resolvedTitle: String? = nil) -> String {
        if let alias, !alias.isEmpty { return alias }
        let effectiveTarget = resolvedTitle ?? target
        if effectiveTarget.isEmpty { return anchor ?? "" }
        let leaf = effectiveTarget.components(separatedBy: "/").last ?? effectiveTarget
        if let anchor, !anchor.isEmpty {
            return "\(leaf) › \(anchor)"
        }
        return leaf
    }
}

// MARK: - Syntax Token & Live-Preview State

/// Kind of live-preview syntax token scanned from a Knowledge markdown document.
public enum KnowledgeSyntaxKind: Sendable, Equatable, Hashable {
    case wikiLink(KnowledgeWikiTarget)
    case embed(KnowledgeWikiTarget)
    case tag(String)
    case blockID(String)
    case heading(level: Int)
    case bold
    case italic
    case boldItalic
    case inlineCode
    case strikethrough
    case fencedCodeBlock(language: String?)
    case blockquote(depth: Int)
    case listItem(ordered: Bool, checked: Bool?)
    case frontmatter
}

/// A scanned markdown syntax token with UTF-16 ranges for live-preview rendering.
public struct KnowledgeSyntaxToken: Sendable, Equatable, Hashable {
    public let kind: KnowledgeSyntaxKind
    /// Full UTF-16 range including syntax delimiters.
    public let range: NSRange
    /// UTF-16 range of the inner visible content.
    public let contentRange: NSRange
    /// UTF-16 ranges of syntax delimiters that hide when the caret/selection is outside `range`.
    public let syntaxRanges: [NSRange]

    public init(kind: KnowledgeSyntaxKind, range: NSRange, contentRange: NSRange, syntaxRanges: [NSRange]) {
        self.kind = kind
        self.range = range
        self.contentRange = contentRange
        self.syntaxRanges = syntaxRanges
    }
}

/// Result of evaluating live-preview reveal/hide rules for a selection.
public struct KnowledgeLivePreviewState: Sendable, Equatable {
    public let tokens: [KnowledgeSyntaxToken]
    public let revealedTokenIndices: Set<Int>
    public let hiddenRanges: [NSRange]
    public let revealedRanges: [NSRange]

    public init(
        tokens: [KnowledgeSyntaxToken],
        revealedTokenIndices: Set<Int>,
        hiddenRanges: [NSRange],
        revealedRanges: [NSRange]
    ) {
        self.tokens = tokens
        self.revealedTokenIndices = revealedTokenIndices
        self.hiddenRanges = hiddenRanges
        self.revealedRanges = revealedRanges
    }

    public func isRevealed(tokenAt index: Int) -> Bool {
        revealedTokenIndices.contains(index)
    }
}

// MARK: - Scanner & Live-Preview Engine

/// Pure Foundation scanner for Knowledge live-preview markdown syntax (`web/lib/knowledge-editor.ts`).
public enum KnowledgeMarkdownSyntax: Sendable {
    // Regexes matching web/lib/knowledge-editor.ts and web/lib/wikilinks.ts.
    private static let fenceRegex = compile("^ {0,3}(`{3,}|~{3,})(.*)$")
    private static let codeSpanRegex = compile("(`+)([^`\\n]+?)\\1")
    private static let wikiLinkRegex = compile("(!?)\\[\\[([^\\[\\]\\n]+?)\\]\\]")
    private static let tagRegex = compile("(?<![\\w/#])(#([\\p{L}\\p{N}_/-]*\\p{L}[\\p{L}\\p{N}_/-]*))")
    private static let blockIDRegex = compile("([ \\t]+\\^([A-Za-z0-9-]+))[ \\t]*$")
    private static let headingRegex = compile("^ {0,3}(#{1,6})([ \\t]+)(.*)$")
    private static let blockquoteRegex = compile("^ {0,3}((?:>[ \\t]?)+)")
    private static let unorderedListRegex = compile("^[ \\t]*([-*+])[ \\t]+(?:\\[([ xX])\\][ \\t]+)?")
    private static let orderedListRegex = compile("^[ \\t]*(\\d+[.)])[ \\t]+(?:\\[([ xX])\\][ \\t]+)?")
    private static let boldItalicRegex = compile("(\\*\\*\\*|___)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let boldRegex = compile("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let strikethroughRegex = compile("(~~)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicStarRegex = compile("(?<!\\*)(\\*)(?!\\*)(?=\\S)([^\\*\\n]+?)(?<=\\S)(?<!\\*)\\*(?!\\*)")
    private static let italicUnderRegex = compile("(?<![\\w_])(_)(?!_)(?=\\S)([^_\\n]+?)(?<=\\S)(?<!_)_(?![\\w_])")

    private static func compile(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    // MARK: Wiki Target Parsing

    /// Parses a raw `[[...]]` or `![[...]]` string into a structured `KnowledgeWikiTarget`.
    public static func parseWikiTarget(raw: String) -> KnowledgeWikiTarget? {
        let isEmbed: Bool
        let body: Substring
        if raw.hasPrefix("![[") && raw.hasSuffix("]]") && raw.count >= 5 {
            isEmbed = true
            body = raw.dropFirst(3).dropLast(2)
        } else if raw.hasPrefix("[[") && raw.hasSuffix("]]") && raw.count >= 4 {
            isEmbed = false
            body = raw.dropFirst(2).dropLast(2)
        } else {
            return nil
        }

        let normalized = String(body).replacingOccurrences(of: "\\|", with: "|")
        var left = normalized
        var alias: String?
        if let bar = left.firstIndex(of: "|") {
            let right = String(left[left.index(after: bar)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !right.isEmpty { alias = right }
            left = String(left[..<bar])
        }

        var target = left
        var heading: String?
        var blockID: String?
        var anchor: String?

        if let hashCaret = left.range(of: "#^") {
            let blk = String(left[hashCaret.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            target = String(left[..<hashCaret.lowerBound])
            if !blk.isEmpty {
                blockID = blk
                anchor = "^\(blk)"
            }
        } else if let hash = left.firstIndex(of: "#") {
            let sec = String(left[left.index(after: hash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            target = String(left[..<hash])
            if !sec.isEmpty {
                heading = sec
                anchor = sec
            }
        } else if let caret = left.firstIndex(of: "^") {
            let blk = String(left[left.index(after: caret)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            target = String(left[..<caret])
            if !blk.isEmpty {
                blockID = blk
                anchor = "^\(blk)"
            }
        }

        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty || anchor != nil else { return nil }

        return KnowledgeWikiTarget(
            raw: raw,
            ref: normalized,
            target: target,
            heading: heading,
            blockID: blockID,
            anchor: anchor,
            alias: alias,
            isEmbed: isEmbed
        )
    }

    // MARK: Line Iteration Helper

    struct LineSlice: Sendable {
        let text: String
        /// UTF-16 offset of the start of the line in the document.
        let utf16Offset: Int
        /// UTF-16 length of the line content (excluding `\r\n` or `\n`).
        let contentUTF16Length: Int
        /// UTF-16 length including line ending (`\r\n` or `\n`).
        let totalUTF16Length: Int
    }

    static func splitLines(_ markdown: String) -> [LineSlice] {
        let ns = markdown as NSString
        let totalLength = ns.length
        if totalLength == 0 {
            return [LineSlice(text: "", utf16Offset: 0, contentUTF16Length: 0, totalUTF16Length: 0)]
        }

        var lines: [LineSlice] = []
        var pos = 0
        while pos < totalLength {
            var end = pos
            while end < totalLength {
                let ch = ns.character(at: end)
                if ch == 0x0A { // \n
                    break
                }
                end += 1
            }
            let hasLF = end < totalLength && ns.character(at: end) == 0x0A
            let hasCR = end > pos && ns.character(at: end - 1) == 0x0D
            let contentEnd = hasCR ? end - 1 : end
            let lineEnd = hasLF ? end + 1 : end
            let contentLen = contentEnd - pos
            let text = ns.substring(with: NSRange(location: pos, length: contentLen))
            lines.append(LineSlice(
                text: text,
                utf16Offset: pos,
                contentUTF16Length: contentLen,
                totalUTF16Length: lineEnd - pos
            ))
            pos = lineEnd
        }
        return lines
    }

    // MARK: Document Scanning

    /// Scans `markdown` for live-preview tokens, skipping syntax inside frontmatter, fenced code blocks, and inline code.
    public static func scan(_ markdown: String) -> [KnowledgeSyntaxToken] {
        let lines = splitLines(markdown)
        var tokens: [KnowledgeSyntaxToken] = []
        var lineIndex = 0

        // 1. Optional YAML frontmatter starting on line 0 (`---` ... `---` or `...`).
        if let first = lines.first, first.text == "---" {
            var closingIdx: Int?
            var idx = 1
            while idx < lines.count {
                if lines[idx].text == "---" || lines[idx].text == "..." {
                    closingIdx = idx
                    break
                }
                idx += 1
            }
            if let close = closingIdx {
                let startOffset = first.utf16Offset
                let endOffset = lines[close].utf16Offset + lines[close].contentUTF16Length
                let fullRange = NSRange(location: startOffset, length: endOffset - startOffset)
                let openDelim = NSRange(location: first.utf16Offset, length: first.contentUTF16Length)
                let closeDelim = NSRange(location: lines[close].utf16Offset, length: lines[close].contentUTF16Length)
                let contentStart = first.utf16Offset + first.totalUTF16Length
                let contentLen = max(0, lines[close].utf16Offset - contentStart)
                tokens.append(KnowledgeSyntaxToken(
                    kind: .frontmatter,
                    range: fullRange,
                    contentRange: NSRange(location: contentStart, length: contentLen),
                    syntaxRanges: [openDelim, closeDelim]
                ))
                lineIndex = close + 1
            }
        }

        // 2. Scan remaining lines, tracking fenced code blocks.
        var openFenceChar: Character?
        var openFenceLength = 0
        var fenceStartOffset = 0
        var fenceOpenDelim = NSRange(location: 0, length: 0)
        var fenceContentStart = 0
        var fenceLanguage: String?

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let lineNS = line.text as NSString
            let fullLineRange = NSRange(location: 0, length: lineNS.length)

            if let fenceMatch = fenceRegex.firstMatch(in: line.text, range: fullLineRange) {
                let marker = lineNS.substring(with: fenceMatch.range(at: 1))
                let info = lineNS.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let currentChar = openFenceChar {
                    if marker.first == currentChar && marker.count >= openFenceLength && info.isEmpty {
                        let endOffset = line.utf16Offset + line.contentUTF16Length
                        let closeDelim = NSRange(location: line.utf16Offset, length: line.contentUTF16Length)
                        let contentLen = max(0, line.utf16Offset - fenceContentStart)
                        tokens.append(KnowledgeSyntaxToken(
                            kind: .fencedCodeBlock(language: fenceLanguage),
                            range: NSRange(location: fenceStartOffset, length: endOffset - fenceStartOffset),
                            contentRange: NSRange(location: fenceContentStart, length: contentLen),
                            syntaxRanges: [fenceOpenDelim, closeDelim]
                        ))
                        openFenceChar = nil
                        openFenceLength = 0
                        lineIndex += 1
                        continue
                    }
                } else {
                    openFenceChar = marker.first
                    openFenceLength = marker.count
                    fenceStartOffset = line.utf16Offset
                    fenceOpenDelim = NSRange(location: line.utf16Offset, length: line.contentUTF16Length)
                    fenceContentStart = line.utf16Offset + line.totalUTF16Length
                    let langWord = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
                    fenceLanguage = (langWord?.isEmpty == false) ? langWord : nil
                    lineIndex += 1
                    continue
                }
            }

            if openFenceChar != nil {
                lineIndex += 1
                continue
            }

            scanNormalLine(line, into: &tokens)
            lineIndex += 1
        }

        // Close unclosed fence at EOF.
        if openFenceChar != nil, let last = lines.last {
            let endOffset = last.utf16Offset + last.contentUTF16Length
            let contentLen = max(0, endOffset - fenceContentStart)
            tokens.append(KnowledgeSyntaxToken(
                kind: .fencedCodeBlock(language: fenceLanguage),
                range: NSRange(location: fenceStartOffset, length: endOffset - fenceStartOffset),
                contentRange: NSRange(location: fenceContentStart, length: contentLen),
                syntaxRanges: [fenceOpenDelim]
            ))
        }

        tokens.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }
        return tokens
    }

    private static func scanNormalLine(_ line: LineSlice, into tokens: inout [KnowledgeSyntaxToken]) {
        guard line.contentUTF16Length > 0 else { return }
        let lineNS = line.text as NSString
        let whole = NSRange(location: 0, length: lineNS.length)
        let base = line.utf16Offset

        // Block-level prefixes: heading, blockquote, list item.
        if let m = headingRegex.firstMatch(in: line.text, range: whole) {
            let hashes = m.range(at: 1)
            let space = m.range(at: 2)
            let content = m.range(at: 3)
            let prefixRange = NSRange(location: base + m.range.location, length: hashes.length + space.length)
            tokens.append(KnowledgeSyntaxToken(
                kind: .heading(level: hashes.length),
                range: NSRange(location: base, length: line.contentUTF16Length),
                contentRange: NSRange(location: base + content.location, length: content.length),
                syntaxRanges: [prefixRange]
            ))
        } else if let m = blockquoteRegex.firstMatch(in: line.text, range: whole) {
            let prefix = m.range(at: 1)
            let prefixText = lineNS.substring(with: prefix)
            let depth = prefixText.filter { $0 == ">" }.count
            let contentStart = m.range.location + m.range.length
            tokens.append(KnowledgeSyntaxToken(
                kind: .blockquote(depth: max(1, depth)),
                range: NSRange(location: base, length: line.contentUTF16Length),
                contentRange: NSRange(location: base + contentStart, length: max(0, line.contentUTF16Length - contentStart)),
                syntaxRanges: [NSRange(location: base + prefix.location, length: prefix.length)]
            ))
        } else if let m = unorderedListRegex.firstMatch(in: line.text, range: whole) {
            let checked = checkboxState(lineNS, range: m.range(at: 2))
            let contentStart = m.range.location + m.range.length
            tokens.append(KnowledgeSyntaxToken(
                kind: .listItem(ordered: false, checked: checked),
                range: NSRange(location: base, length: line.contentUTF16Length),
                contentRange: NSRange(location: base + contentStart, length: max(0, line.contentUTF16Length - contentStart)),
                syntaxRanges: [NSRange(location: base + m.range.location, length: m.range.length)]
            ))
        } else if let m = orderedListRegex.firstMatch(in: line.text, range: whole) {
            let checked = checkboxState(lineNS, range: m.range(at: 2))
            let contentStart = m.range.location + m.range.length
            tokens.append(KnowledgeSyntaxToken(
                kind: .listItem(ordered: true, checked: checked),
                range: NSRange(location: base, length: line.contentUTF16Length),
                contentRange: NSRange(location: base + contentStart, length: max(0, line.contentUTF16Length - contentStart)),
                syntaxRanges: [NSRange(location: base + m.range.location, length: m.range.length)]
            ))
        }

        // Inline code spans first — their ranges are excluded from Obsidian and emphasis scanning.
        var excluded: [NSRange] = []
        for m in codeSpanRegex.matches(in: line.text, range: whole) {
            let tickLen = m.range(at: 1).length
            let full = NSRange(location: base + m.range.location, length: m.range.length)
            let openDelim = NSRange(location: full.location, length: tickLen)
            let closeDelim = NSRange(location: full.location + full.length - tickLen, length: tickLen)
            let content = NSRange(location: base + m.range(at: 2).location, length: m.range(at: 2).length)
            tokens.append(KnowledgeSyntaxToken(
                kind: .inlineCode,
                range: full,
                contentRange: content,
                syntaxRanges: [openDelim, closeDelim]
            ))
            excluded.append(m.range)
        }

        // Wikilinks and embeds: `[[...]]` and `![[...]]`.
        for m in wikiLinkRegex.matches(in: line.text, range: whole) {
            if overlapsAny(m.range, in: excluded) { continue }
            let raw = lineNS.substring(with: m.range)
            guard let target = parseWikiTarget(raw: raw) else { continue }
            let full = NSRange(location: base + m.range.location, length: m.range.length)
            let openLen = target.isEmbed ? 3 : 2
            let closeLen = 2
            let openRange: NSRange
            let contentRange: NSRange
            let closeRange = NSRange(location: full.location + full.length - closeLen, length: closeLen)

            if let alias = target.alias, !alias.isEmpty, let barRange = (raw as NSString).range(of: "|", options: .backwards).optionalValid {
                let prefixLen = barRange.location + barRange.length
                openRange = NSRange(location: full.location, length: prefixLen)
                contentRange = NSRange(location: full.location + prefixLen, length: max(0, full.length - prefixLen - closeLen))
            } else {
                openRange = NSRange(location: full.location, length: openLen)
                contentRange = NSRange(location: full.location + openLen, length: max(0, full.length - openLen - closeLen))
            }

            tokens.append(KnowledgeSyntaxToken(
                kind: target.isEmbed ? .embed(target) : .wikiLink(target),
                range: full,
                contentRange: contentRange,
                syntaxRanges: [openRange, closeRange]
            ))
            excluded.append(m.range)
        }

        // `#tags` outside code and wikilinks.
        for m in tagRegex.matches(in: line.text, range: whole) {
            let tagRange = m.range(at: 1)
            if overlapsAny(tagRange, in: excluded) { continue }
            let nameRange = m.range(at: 2)
            let name = lineNS.substring(with: nameRange)
            let full = NSRange(location: base + tagRange.location, length: tagRange.length)
            let hashDelim = NSRange(location: full.location, length: 1)
            let content = NSRange(location: base + nameRange.location, length: nameRange.length)
            tokens.append(KnowledgeSyntaxToken(
                kind: .tag(name),
                range: full,
                contentRange: content,
                syntaxRanges: [hashDelim]
            ))
            excluded.append(tagRange)
        }

        // `^block-id` at end of line outside code and wikilinks.
        if let m = blockIDRegex.firstMatch(in: line.text, range: whole) {
            let blockRange = m.range(at: 1)
            if !overlapsAny(blockRange, in: excluded) {
                let idRange = m.range(at: 2)
                let id = lineNS.substring(with: idRange)
                let full = NSRange(location: base + blockRange.location, length: blockRange.length)
                let content = NSRange(location: base + idRange.location, length: idRange.length)
                tokens.append(KnowledgeSyntaxToken(
                    kind: .blockID(id),
                    range: full,
                    contentRange: content,
                    syntaxRanges: [full]
                ))
                excluded.append(blockRange)
            }
        }

        // Inline emphasis: bold-italic, bold, strikethrough, italic (outside code/wikilinks/tags).
        scanEmphasis(boldItalicRegex, kind: .boldItalic, delimLength: 3, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        scanEmphasis(boldRegex, kind: .bold, delimLength: 2, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        scanEmphasis(strikethroughRegex, kind: .strikethrough, delimLength: 2, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        scanEmphasis(italicStarRegex, kind: .italic, delimLength: 1, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        scanEmphasis(italicUnderRegex, kind: .italic, delimLength: 1, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
    }

    private static func scanEmphasis(
        _ regex: NSRegularExpression,
        kind: KnowledgeSyntaxKind,
        delimLength: Int,
        lineText: String,
        whole: NSRange,
        base: Int,
        excluded: inout [NSRange],
        tokens: inout [KnowledgeSyntaxToken]
    ) {
        for m in regex.matches(in: lineText, range: whole) {
            if overlapsAny(m.range, in: excluded) { continue }
            let full = NSRange(location: base + m.range.location, length: m.range.length)
            let openDelim = NSRange(location: full.location, length: delimLength)
            let closeDelim = NSRange(location: full.location + full.length - delimLength, length: delimLength)
            let content = NSRange(location: base + m.range(at: 2).location, length: m.range(at: 2).length)
            tokens.append(KnowledgeSyntaxToken(
                kind: kind,
                range: full,
                contentRange: content,
                syntaxRanges: [openDelim, closeDelim]
            ))
            excluded.append(m.range)
        }
    }

    private static func checkboxState(_ lineNS: NSString, range: NSRange) -> Bool? {
        guard range.location != NSNotFound, range.length == 1 else { return nil }
        let ch = lineNS.substring(with: range)
        return ch == "x" || ch == "X"
    }

    private static func overlapsAny(_ range: NSRange, in ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    // MARK: Live-Preview Reveal / Hide

    /// Returns `true` when `selection` touches or intersects `tokenRange` (`selection.from <= to && selection.to >= from`).
    public static func intersects(tokenRange: NSRange, selection: NSRange) -> Bool {
        let selStart = selection.location
        let selEnd = selection.location + selection.length
        let tokStart = tokenRange.location
        let tokEnd = tokenRange.location + tokenRange.length
        return selStart <= tokEnd && selEnd >= tokStart
    }

    /// Computes which syntax delimiter ranges should be hidden vs. revealed for `selection`.
    public static func livePreview(
        in markdown: String,
        selection: NSRange?,
        isFocused: Bool = true
    ) -> KnowledgeLivePreviewState {
        let tokens = scan(markdown)
        var revealedIndices = Set<Int>()
        var hidden: [NSRange] = []
        var revealed: [NSRange] = []

        for (index, token) in tokens.enumerated() {
            let shouldReveal: Bool
            if isFocused, let selection {
                shouldReveal = intersects(tokenRange: token.range, selection: selection)
            } else {
                shouldReveal = false
            }

            if shouldReveal {
                revealedIndices.insert(index)
                revealed.append(contentsOf: token.syntaxRanges)
            } else {
                hidden.append(contentsOf: token.syntaxRanges)
            }
        }

        return KnowledgeLivePreviewState(
            tokens: tokens,
            revealedTokenIndices: revealedIndices,
            hiddenRanges: hidden,
            revealedRanges: revealed
        )
    }

    // MARK: ⌘-Click Hit Testing

    /// Hit-tests `utf16Offset` for a `[[link]]` or `![[embed]]` token (for `⌘`-click navigation).
    public static func hitTestLink(
        at utf16Offset: Int,
        in markdown: String,
        tokens: [KnowledgeSyntaxToken]? = nil
    ) -> KnowledgeWikiTarget? {
        let list = tokens ?? scan(markdown)
        for token in list {
            let start = token.range.location
            let end = start + token.range.length
            guard utf16Offset >= start && utf16Offset < end else { continue }
            switch token.kind {
            case .wikiLink(let target), .embed(let target):
                return target
            default:
                continue
            }
        }
        return nil
    }

    // MARK: Code-Exclusion Helper for Completion

    /// Returns `true` if `utf16Offset` falls inside a fenced code block, frontmatter, or inline code span.
    static func isInsideCodeOrFrontmatter(utf16Offset: Int, in markdown: String) -> Bool {
        for token in scan(markdown) {
            switch token.kind {
            case .fencedCodeBlock, .inlineCode, .frontmatter:
                let start = token.range.location
                let end = start + token.range.length
                if utf16Offset > start && utf16Offset < end {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}

private extension NSRange {
    var optionalValid: NSRange? {
        location == NSNotFound ? nil : self
    }
}
