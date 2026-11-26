import CoreGraphics
import Foundation

// MARK: - Wiki Target

/// Explicit Obsidian-style display dimensions parsed from `![[img.png|400]]` or `![[img.png|400x300]]`.
public struct KnowledgeEmbedDimensions: Sendable, Equatable, Hashable {
    public let width: CGFloat
    public let height: CGFloat?

    public init(width: CGFloat, height: CGFloat? = nil) {
        self.width = width
        self.height = height
    }

    /// Parses an Obsidian dimension token (`"400"` or `"400x300"`), clamping values to sensible display bounds.
    public static func parse(_ raw: String) -> KnowledgeEmbedDimensions? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let xIdx = trimmed.firstIndex(of: "x") {
            let wStr = String(trimmed[..<xIdx])
            let hStr = String(trimmed[trimmed.index(after: xIdx)...])
            guard !wStr.isEmpty, wStr.allSatisfy(\.isNumber),
                  !hStr.isEmpty, hStr.allSatisfy(\.isNumber),
                  let w = Int(wStr), let h = Int(hStr),
                  w > 0, h > 0 else {
                return nil
            }
            return KnowledgeEmbedDimensions(
                width: CGFloat(max(60, min(2400, w))),
                height: CGFloat(max(40, min(2400, h)))
            )
        }
        guard trimmed.allSatisfy(\.isNumber), let w = Int(trimmed), w > 0 else {
            return nil
        }
        return KnowledgeEmbedDimensions(width: CGFloat(max(60, min(2400, w))), height: nil)
    }
}

/// Parsed target of a `[[link]]` or `![[embed]]` matching `web/lib/wikilinks.ts` and `web/lib/knowledge-editor.ts`.
public struct KnowledgeWikiTarget: Sendable, Equatable, Hashable {
    /// Whole token as written, e.g. `[[Folder/Note#Intro|Overview]]` or `![[diagram.png|400]]`.
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

    /// Explicit width (and optional height) parsed from Obsidian-style embed sizing
    /// (`![[img.png|400]]`, `![[img.png|400x260]]`, or `![[img.png|Alt text|400]]`).
    public var embedDimensions: KnowledgeEmbedDimensions? {
        guard isEmbed, let alias, !alias.isEmpty else { return nil }
        let trailing = alias.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? alias
        return KnowledgeEmbedDimensions.parse(trailing)
    }

    /// Display text matching `defaultLabel` in `web/lib/wikilinks.ts`.
    public func displayLabel(resolvedTitle: String? = nil) -> String {
        if let alias, !alias.isEmpty {
            if isEmbed {
                let parts = alias.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 1 && KnowledgeEmbedDimensions.parse(parts[0]) != nil {
                    // Pure dimension alias like `|400`: fall through to target/title.
                } else if parts.count > 1, let last = parts.last, KnowledgeEmbedDimensions.parse(last) != nil {
                    let caption = parts.dropLast().joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !caption.isEmpty { return caption }
                } else {
                    return alias
                }
            } else {
                return alias
            }
        }
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

/// A single resolved `![[...]]` embed occurrence anchored to its UTF-16 token and enclosing line ranges.
public struct KnowledgeInlineEmbedPlacement: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    /// 0-based index of this resolved embed occurrence in document order.
    public let occurrenceIndex: Int
    /// UTF-16 range of the `![[...]]` token.
    public let tokenRange: NSRange
    /// UTF-16 range of the enclosing line excluding its trailing line ending.
    public let lineContentRange: NSRange
    /// UTF-16 range of the enclosing line including its trailing line ending (`\n` or `\r\n`).
    public let lineRange: NSRange
    /// `true` when the line contains only resolved embed token(s) and optional whitespace.
    public let isStandaloneLine: Bool
    /// Parsed wiki target of the `![[...]]` token.
    public let target: KnowledgeWikiTarget
    /// Server-resolved embed metadata.
    public let embed: KnowledgeEmbed

    public init(
        id: String,
        occurrenceIndex: Int,
        tokenRange: NSRange,
        lineContentRange: NSRange,
        lineRange: NSRange,
        isStandaloneLine: Bool,
        target: KnowledgeWikiTarget,
        embed: KnowledgeEmbed
    ) {
        self.id = id
        self.occurrenceIndex = occurrenceIndex
        self.tokenRange = tokenRange
        self.lineContentRange = lineContentRange
        self.lineRange = lineRange
        self.isStandaloneLine = isStandaloneLine
        self.target = target
        self.embed = embed
    }
}

/// All resolved inline embeds belonging to a single markdown line/paragraph, in document order.
public struct KnowledgeInlineEmbedParagraph: Sendable, Equatable, Hashable, Identifiable {
    /// Stable key independent of character offsets above this paragraph so typing above does not remount views.
    public let id: String
    /// 0-based index among paragraphs containing resolved embeds.
    public let groupIndex: Int
    /// UTF-16 range of the enclosing line excluding its trailing line ending.
    public let lineContentRange: NSRange
    /// UTF-16 range of the enclosing line including its trailing line ending (`\n` or `\r\n`).
    public let lineRange: NSRange
    /// `true` when the line contains only resolved embed token(s) and optional whitespace.
    public let isStandaloneLine: Bool
    /// Ordered resolved embeds appearing on this line.
    public let placements: [KnowledgeInlineEmbedPlacement]

    /// Image-only groups hug their fitted image width so clicking beside an image focuses the text view;
    /// PDF and note cards expand to the full text container width.
    public var fillsContainerWidth: Bool {
        placements.contains { !$0.embed.isImageEmbed }
    }

    public init(
        id: String,
        groupIndex: Int,
        lineContentRange: NSRange,
        lineRange: NSRange,
        isStandaloneLine: Bool,
        placements: [KnowledgeInlineEmbedPlacement]
    ) {
        self.id = id
        self.groupIndex = groupIndex
        self.lineContentRange = lineContentRange
        self.lineRange = lineRange
        self.isStandaloneLine = isStandaloneLine
        self.placements = placements
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

            if lineMayBeFence(lineNS), let fenceMatch = fenceRegex.firstMatch(in: line.text, range: fullLineRange) {
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

    /// Scans only ATX heading tokens in `markdown`, skipping frontmatter and fenced code blocks
    /// without running any inline markdown regexes.
    public static func scanHeadings(_ markdown: String) -> [KnowledgeSyntaxToken] {
        guard markdown.contains("#") else { return [] }
        let lines = splitLines(markdown)
        var tokens: [KnowledgeSyntaxToken] = []
        var lineIndex = 0

        if let first = lines.first, first.text == "---" {
            var idx = 1
            while idx < lines.count {
                if lines[idx].text == "---" || lines[idx].text == "..." {
                    lineIndex = idx + 1
                    break
                }
                idx += 1
            }
        }

        var openFenceChar: Character?
        var openFenceLength = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let lineNS = line.text as NSString
            let fullLineRange = NSRange(location: 0, length: lineNS.length)

            if lineMayBeFence(lineNS), let fenceMatch = fenceRegex.firstMatch(in: line.text, range: fullLineRange) {
                let marker = lineNS.substring(with: fenceMatch.range(at: 1))
                let info = lineNS.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let currentChar = openFenceChar {
                    if marker.first == currentChar && marker.count >= openFenceLength && info.isEmpty {
                        openFenceChar = nil
                        openFenceLength = 0
                    }
                } else {
                    openFenceChar = marker.first
                    openFenceLength = marker.count
                }
                lineIndex += 1
                continue
            }

            if openFenceChar == nil,
               lineMayBeHeading(lineNS),
               let m = headingRegex.firstMatch(in: line.text, range: fullLineRange) {
                let hashes = m.range(at: 1)
                let space = m.range(at: 2)
                let content = m.range(at: 3)
                let base = line.utf16Offset
                let prefixRange = NSRange(location: base + m.range.location, length: hashes.length + space.length)
                tokens.append(KnowledgeSyntaxToken(
                    kind: .heading(level: hashes.length),
                    range: NSRange(location: base, length: line.contentUTF16Length),
                    contentRange: NSRange(location: base + content.location, length: content.length),
                    syntaxRanges: [prefixRange]
                ))
            }
            lineIndex += 1
        }
        return tokens
    }

    private static func lineMayBeFence(_ lineNS: NSString) -> Bool {
        let len = lineNS.length
        guard len >= 3 else { return false }
        var i = 0
        while i < len && i < 3 && lineNS.character(at: i) == 0x20 { i += 1 }
        guard i + 2 < len else { return false }
        let ch = lineNS.character(at: i)
        return (ch == 0x60 || ch == 0x7E) // '`' or '~'
            && lineNS.character(at: i + 1) == ch
            && lineNS.character(at: i + 2) == ch
    }

    private static func lineMayBeHeading(_ lineNS: NSString) -> Bool {
        let len = lineNS.length
        guard len >= 2 else { return false }
        var i = 0
        while i < len && i < 3 && lineNS.character(at: i) == 0x20 { i += 1 }
        return i < len && lineNS.character(at: i) == 0x23 // '#'
    }

    private static func scanNormalLine(_ line: LineSlice, into tokens: inout [KnowledgeSyntaxToken]) {
        guard line.contentUTF16Length > 0 else { return }
        let lineNS = line.text as NSString
        let len = lineNS.length
        let whole = NSRange(location: 0, length: len)
        let base = line.utf16Offset

        // Single-pass UTF-16 character inventory so plain prose lines skip all unused NSRegularExpressions.
        var leadingSpaces = 0
        var leadingSpacesOnly = true
        var firstNonWS: unichar = 0
        var backtickCount = 0
        var openBracketCount = 0
        var closeBracketCount = 0
        var hashCount = 0
        var caretCount = 0
        var starCount = 0
        var underCount = 0
        var tildeCount = 0

        for i in 0..<len {
            let ch = lineNS.character(at: i)
            if firstNonWS == 0 {
                if ch == 0x20 { // ' '
                    leadingSpaces += 1
                    continue
                } else if ch == 0x09 { // '\t'
                    leadingSpacesOnly = false
                    continue
                } else {
                    firstNonWS = ch
                }
            }
            switch ch {
            case 0x60: backtickCount += 1      // '`'
            case 0x5B: openBracketCount += 1   // '['
            case 0x5D: closeBracketCount += 1  // ']'
            case 0x23: hashCount += 1          // '#'
            case 0x5E: caretCount += 1         // '^'
            case 0x2A: starCount += 1          // '*'
            case 0x5F: underCount += 1         // '_'
            case 0x7E: tildeCount += 1         // '~'
            default: break
            }
        }

        // Block-level prefixes: heading, blockquote, list item.
        let canBlockPrefix = leadingSpacesOnly && leadingSpaces <= 3
        if canBlockPrefix, firstNonWS == 0x23, let m = headingRegex.firstMatch(in: line.text, range: whole) {
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
        } else if canBlockPrefix, firstNonWS == 0x3E, let m = blockquoteRegex.firstMatch(in: line.text, range: whole) {
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
        } else if (firstNonWS == 0x2D || firstNonWS == 0x2A || firstNonWS == 0x2B),
                  let m = unorderedListRegex.firstMatch(in: line.text, range: whole) {
            let checked = checkboxState(lineNS, range: m.range(at: 2))
            let contentStart = m.range.location + m.range.length
            tokens.append(KnowledgeSyntaxToken(
                kind: .listItem(ordered: false, checked: checked),
                range: NSRange(location: base, length: line.contentUTF16Length),
                contentRange: NSRange(location: base + contentStart, length: max(0, line.contentUTF16Length - contentStart)),
                syntaxRanges: [NSRange(location: base + m.range.location, length: m.range.length)]
            ))
        } else if firstNonWS >= 0x30 && firstNonWS <= 0x39,
                  let m = orderedListRegex.firstMatch(in: line.text, range: whole) {
            let checked = checkboxState(lineNS, range: m.range(at: 2))
            let contentStart = m.range.location + m.range.length
            tokens.append(KnowledgeSyntaxToken(
                kind: .listItem(ordered: true, checked: checked),
                range: NSRange(location: base, length: line.contentUTF16Length),
                contentRange: NSRange(location: base + contentStart, length: max(0, line.contentUTF16Length - contentStart)),
                syntaxRanges: [NSRange(location: base + m.range.location, length: m.range.length)]
            ))
        }

        // Fast exit for plain prose lines with no inline syntax markers at all.
        let hasInlineMarkers = backtickCount >= 2
            || (openBracketCount >= 2 && closeBracketCount >= 2)
            || hashCount >= 1
            || caretCount >= 1
            || starCount >= 2
            || underCount >= 2
            || tildeCount >= 4
        guard hasInlineMarkers else { return }

        // Inline code spans first — their ranges are excluded from Obsidian and emphasis scanning.
        var excluded: [NSRange] = []
        if backtickCount >= 2 {
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
        }

        // Wikilinks and embeds: `[[...]]` and `![[...]]`.
        if openBracketCount >= 2 && closeBracketCount >= 2 {
            for m in wikiLinkRegex.matches(in: line.text, range: whole) {
                if overlapsAny(m.range, in: excluded) { continue }
                let raw = lineNS.substring(with: m.range)
                guard let target = parseWikiTarget(raw: raw) else { continue }
                let full = NSRange(location: base + m.range.location, length: m.range.length)
                let (contentRange, syntaxRanges) = wikiLinkDisplayRanges(raw: raw, full: full, target: target)

                tokens.append(KnowledgeSyntaxToken(
                    kind: target.isEmbed ? .embed(target) : .wikiLink(target),
                    range: full,
                    contentRange: contentRange,
                    syntaxRanges: syntaxRanges
                ))
                excluded.append(m.range)
            }
        }

        // `#tags` outside code and wikilinks.
        if hashCount >= 1 {
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
        }

        // `^block-id` at end of line outside code and wikilinks.
        if caretCount >= 1, let m = blockIDRegex.firstMatch(in: line.text, range: whole) {
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
        if starCount >= 6 || underCount >= 6 {
            scanEmphasis(boldItalicRegex, kind: .boldItalic, delimLength: 3, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        }
        if starCount >= 4 || underCount >= 4 {
            scanEmphasis(boldRegex, kind: .bold, delimLength: 2, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        }
        if tildeCount >= 4 {
            scanEmphasis(strikethroughRegex, kind: .strikethrough, delimLength: 2, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        }
        if starCount >= 2 {
            scanEmphasis(italicStarRegex, kind: .italic, delimLength: 1, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        }
        if underCount >= 2 {
            scanEmphasis(italicUnderRegex, kind: .italic, delimLength: 1, lineText: line.text, whole: whole, base: base, excluded: &excluded, tokens: &tokens)
        }
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

    private static func wikiLinkDisplayRanges(
        raw: String,
        full: NSRange,
        target: KnowledgeWikiTarget
    ) -> (contentRange: NSRange, syntaxRanges: [NSRange]) {
        let rawNS = raw as NSString
        let openLen = target.isEmbed ? 3 : 2
        let closeLen = 2
        let innerStart = openLen
        let innerEnd = max(innerStart, full.length - closeLen)
        let innerRange = NSRange(location: innerStart, length: innerEnd - innerStart)

        let firstBar = rawNS.range(of: "|", range: innerRange)
        let pipeTokenStart: Int? = {
            guard firstBar.location != NSNotFound else { return nil }
            if firstBar.location > innerStart && rawNS.character(at: firstBar.location - 1) == 0x5C {
                return firstBar.location - 1
            }
            return firstBar.location
        }()

        func makeRanges(contentStart rawStart: Int, contentEnd rawEnd: Int) -> (NSRange, [NSRange]) {
            var start = max(innerStart, min(rawStart, innerEnd))
            var end = max(start, min(rawEnd, innerEnd))
            while start < end && isHorizontalWhitespace(rawNS.character(at: start)) { start += 1 }
            while end > start && isHorizontalWhitespace(rawNS.character(at: end - 1)) { end -= 1 }
            let openRange = NSRange(location: full.location, length: start)
            let contentRange = NSRange(location: full.location + start, length: end - start)
            let closeRange = NSRange(location: full.location + end, length: full.length - end)
            return (contentRange, [openRange, closeRange])
        }

        // 1. Explicit display alias (ignoring pure Obsidian embed dimension suffixes like `|400`).
        if let alias = target.alias, !alias.isEmpty, firstBar.location != NSNotFound {
            let aliasStart = firstBar.location + firstBar.length
            if target.isEmbed {
                let lastBar = rawNS.range(of: "|", options: .backwards, range: innerRange)
                if lastBar.location == firstBar.location {
                    if KnowledgeEmbedDimensions.parse(alias) == nil {
                        return makeRanges(contentStart: aliasStart, contentEnd: innerEnd)
                    }
                } else {
                    let trailingStart = lastBar.location + lastBar.length
                    let trailing = rawNS.substring(with: NSRange(location: trailingStart, length: innerEnd - trailingStart))
                    if KnowledgeEmbedDimensions.parse(trailing) != nil {
                        let captionEnd = (lastBar.location > aliasStart && rawNS.character(at: lastBar.location - 1) == 0x5C)
                            ? lastBar.location - 1
                            : lastBar.location
                        let caption = rawNS.substring(with: NSRange(location: aliasStart, length: max(0, captionEnd - aliasStart)))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !caption.isEmpty {
                            return makeRanges(contentStart: aliasStart, contentEnd: captionEnd)
                        }
                    } else {
                        return makeRanges(contentStart: aliasStart, contentEnd: innerEnd)
                    }
                }
            } else {
                return makeRanges(contentStart: aliasStart, contentEnd: innerEnd)
            }
        }

        // 2. No display alias: hide folder segments before the last `/` in the target portion
        //    (before `#`, `^`, or `|`) so `[[Folder/Subfolder/Note]]` displays as `Note`.
        let targetAndAnchorEnd = pipeTokenStart ?? innerEnd
        let targetAndAnchorRange = NSRange(location: innerStart, length: max(0, targetAndAnchorEnd - innerStart))

        var targetEnd = targetAndAnchorEnd
        let hashRange = rawNS.range(of: "#", range: targetAndAnchorRange)
        if hashRange.location != NSNotFound {
            targetEnd = min(targetEnd, hashRange.location)
        }
        let caretRange = rawNS.range(of: "^", range: targetAndAnchorRange)
        if caretRange.location != NSNotFound {
            targetEnd = min(targetEnd, caretRange.location)
        }

        let targetRange = NSRange(location: innerStart, length: max(0, targetEnd - innerStart))
        let lastSlash = rawNS.range(of: "/", options: .backwards, range: targetRange)
        if lastSlash.location != NSNotFound {
            let leafStart = lastSlash.location + lastSlash.length
            let leaf = rawNS.substring(with: NSRange(location: leafStart, length: max(0, targetEnd - leafStart)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !leaf.isEmpty {
                return makeRanges(contentStart: leafStart, contentEnd: targetAndAnchorEnd)
            }
        }

        return makeRanges(contentStart: innerStart, contentEnd: targetAndAnchorEnd)
    }

    private static func isHorizontalWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
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

    /// Computes which syntax delimiter ranges should be hidden vs. revealed for `selection`
    /// (and any active `⌘F` match, so matches inside hidden link paths remain visible).
    public static func livePreview(
        in markdown: String,
        selection: NSRange?,
        isFocused: Bool = true,
        activeFindMatch: NSRange? = nil
    ) -> KnowledgeLivePreviewState {
        livePreview(
            tokens: scan(markdown),
            selection: selection,
            isFocused: isFocused,
            activeFindMatch: activeFindMatch
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

    /// Rewrites an embed token's Obsidian width specifier (`![[target|400]]`), preserving any
    /// non-dimension caption alias (`![[target|Caption|400]]`). Passing `width: nil` removes
    /// any existing dimension suffix to restore default sizing.
    public static func updatingEmbedWidth(in rawToken: String, width: Int?) -> String {
        guard rawToken.hasPrefix("![["), rawToken.hasSuffix("]]"), rawToken.count >= 5 else {
            return rawToken
        }
        let inner = String(rawToken.dropFirst(3).dropLast(2))
        var parts = inner.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return rawToken }

        // Strip existing trailing dimension segment if present (keep target at index 0).
        if parts.count > 1, let last = parts.last, KnowledgeEmbedDimensions.parse(last) != nil {
            parts.removeLast()
        }
        if let width {
            let clamped = max(60, min(2400, width))
            parts.append("\(clamped)")
        }
        return "![[\(parts.joined(separator: "|"))]]"
    }

    /// Matches a server-resolved `KnowledgeEmbed` against a parsed `![[...]]` target,
    /// including when the user edits an inline `|width` alias before the next save round-trip.
    private static func embedMatchesTarget(_ embed: KnowledgeEmbed, target: KnowledgeWikiTarget) -> Bool {
        if embed.ref == target.raw || embed.ref == target.ref || embed.ref == target.target {
            return true
        }
        if let parsedEmbed = parseWikiTarget(raw: embed.ref),
           !parsedEmbed.target.isEmpty,
           parsedEmbed.target == target.target,
           parsedEmbed.anchor == target.anchor {
            return true
        }
        return false
    }

    // MARK: Inline Embed Resolution

    /// Resolves `![[...]]` embeds referenced in `markdown` against the server-resolved `embeds`
    /// list, preserving document order and deduplicating by `embed.ref`.
    ///
    /// The server returns `embed.ref` as the full raw token (`![[attachment:<uuid>/name.png]]`),
    /// so matching checks `target.raw` in addition to the inner `target.ref`, `target.target`,
    /// and target identity ignoring `|width` resize edits.
    public static func resolveInlineEmbeds(
        in markdown: String,
        embeds: [KnowledgeEmbed]
    ) -> [KnowledgeEmbed] {
        guard !embeds.isEmpty else { return [] }
        var seen = Set<String>()
        var result: [KnowledgeEmbed] = []
        for token in scan(markdown) {
            guard case .embed(let target) = token.kind else { continue }
            if let match = embeds.first(where: { $0.available && embedMatchesTarget($0, target: target) }),
               seen.insert(match.ref).inserted {
                result.append(match)
            }
        }
        return result
    }

    /// Resolves every renderable `![[...]]` embed occurrence in `markdown` in document order,
    /// preserving duplicate occurrences and anchoring each to its exact token and line UTF-16 ranges.
    public static func resolveInlineEmbedPlacements(
        in markdown: String,
        embeds: [KnowledgeEmbed],
        tokens: [KnowledgeSyntaxToken]? = nil
    ) -> [KnowledgeInlineEmbedPlacement] {
        groupInlineEmbedsByParagraph(in: markdown, embeds: embeds, tokens: tokens)
            .flatMap(\.placements)
    }

    /// Groups renderable `![[...]]` embed occurrences by their enclosing markdown line/paragraph
    /// in strict document order.
    public static func groupInlineEmbedsByParagraph(
        in markdown: String,
        embeds: [KnowledgeEmbed],
        tokens: [KnowledgeSyntaxToken]? = nil
    ) -> [KnowledgeInlineEmbedParagraph] {
        guard !embeds.isEmpty else { return [] }
        let scanned = tokens ?? scan(markdown)
        let lines = splitLines(markdown)
        guard !lines.isEmpty else { return [] }

        var matchedByLine: [Int: [(token: KnowledgeSyntaxToken, target: KnowledgeWikiTarget, embed: KnowledgeEmbed)]] = [:]
        var lineCursor = 0

        for token in scanned {
            guard case .embed(let target) = token.kind else { continue }
            guard let embed = embeds.first(where: { $0.hasInlinePreview && embedMatchesTarget($0, target: target) }) else {
                continue
            }

            let tokLoc = token.range.location
            while lineCursor + 1 < lines.count,
                  lines[lineCursor].utf16Offset + lines[lineCursor].totalUTF16Length <= tokLoc {
                lineCursor += 1
            }
            let lineIdx = lineIndex(containing: tokLoc, in: lines, hint: lineCursor)
            matchedByLine[lineIdx, default: []].append((token, target, embed))
        }

        guard !matchedByLine.isEmpty else { return [] }

        var groups: [KnowledgeInlineEmbedParagraph] = []
        var occurrenceIndex = 0

        for lineIdx in matchedByLine.keys.sorted() {
            let line = lines[lineIdx]
            let entries = matchedByLine[lineIdx] ?? []
            let lineContentRange = NSRange(location: line.utf16Offset, length: line.contentUTF16Length)
            let lineRange = NSRange(location: line.utf16Offset, length: line.totalUTF16Length)
            let isStandalone = isLineOnlyEmbedTokens(line: line, tokenRanges: entries.map(\.token.range))

            var placements: [KnowledgeInlineEmbedPlacement] = []
            placements.reserveCapacity(entries.count)
            for entry in entries {
                let stableKey = updatingEmbedWidth(in: entry.embed.ref, width: nil)
                placements.append(KnowledgeInlineEmbedPlacement(
                    id: "\(occurrenceIndex):\(stableKey)",
                    occurrenceIndex: occurrenceIndex,
                    tokenRange: entry.token.range,
                    lineContentRange: lineContentRange,
                    lineRange: lineRange,
                    isStandaloneLine: isStandalone,
                    target: entry.target,
                    embed: entry.embed
                ))
                occurrenceIndex += 1
            }

            let groupIndex = groups.count
            let groupID = "\(groupIndex):\(placements.map { updatingEmbedWidth(in: $0.embed.ref, width: nil) }.joined(separator: "|"))"
            groups.append(KnowledgeInlineEmbedParagraph(
                id: groupID,
                groupIndex: groupIndex,
                lineContentRange: lineContentRange,
                lineRange: lineRange,
                isStandaloneLine: isStandalone,
                placements: placements
            ))
        }

        return groups
    }

    /// Returns `true` when the raw `![[...]]` source of `placement` should be shown instead of hidden
    /// (for example because the focused caret/selection or active `⌘F` match intersects it).
    public static func shouldRevealEmbedSource(
        for placement: KnowledgeInlineEmbedPlacement,
        selection: NSRange?,
        isFocused: Bool,
        activeFindMatch: NSRange? = nil
    ) -> Bool {
        let checkRange = placement.isStandaloneLine ? placement.lineContentRange : placement.tokenRange
        if isFocused, let selection, intersects(tokenRange: checkRange, selection: selection) {
            return true
        }
        if let activeFindMatch, intersects(tokenRange: checkRange, selection: activeFindMatch) {
            return true
        }
        return false
    }

    /// Surgical UTF-16 edit removing a single inline embed placement from markdown prose.
    public struct EmbedRemovalEdit: Sendable, Equatable {
        public let replacementRange: NSRange
        public let replacement: String
        public let caretUTF16: Int
        public let resultingText: String

        public init(
            replacementRange: NSRange,
            replacement: String,
            caretUTF16: Int,
            resultingText: String
        ) {
            self.replacementRange = replacementRange
            self.replacement = replacement
            self.caretUTF16 = caretUTF16
            self.resultingText = resultingText
        }
    }

    /// Computes a surgical edit that removes `placement` from `markdown`.
    /// - When `placement` is the sole content on its line, removes the entire line (collapsing one
    ///   redundant blank line when sandwiched between blank lines, or consuming a preceding newline
    ///   when removing a trailing line that has no line terminator).
    /// - When prose or another embed shares the line, removes only `placement.tokenRange` and tidies
    ///   up a single adjacent horizontal space so no double or dangling spaces remain.
    public static func removingEmbed(
        _ placement: KnowledgeInlineEmbedPlacement,
        in markdown: String
    ) -> EmbedRemovalEdit? {
        let ns = markdown as NSString
        let len = ns.length
        let tokenRange = placement.tokenRange
        let lineContentRange = placement.lineContentRange
        let lineRange = placement.lineRange

        let tokenEnd = tokenRange.location + tokenRange.length
        let lineContentEnd = lineContentRange.location + lineContentRange.length
        let lineEnd = lineRange.location + lineRange.length

        guard tokenRange.location >= 0, tokenRange.length > 0, tokenEnd <= len,
              lineContentRange.location >= 0, lineContentEnd <= len,
              lineRange.location >= 0, lineEnd <= len,
              tokenRange.location >= lineContentRange.location,
              tokenEnd <= lineContentEnd else {
            return nil
        }

        let prefix = ns.substring(with: NSRange(
            location: lineContentRange.location,
            length: tokenRange.location - lineContentRange.location
        ))
        let suffix = ns.substring(with: NSRange(
            location: tokenEnd,
            length: lineContentEnd - tokenEnd
        ))
        let prefixBlank = prefix.trimmingCharacters(in: .whitespaces).isEmpty
        let suffixBlank = suffix.trimmingCharacters(in: .whitespaces).isEmpty

        let removeStart: Int
        let removeEnd: Int

        if prefixBlank && suffixBlank {
            var start = lineRange.location
            var end = lineEnd
            let lineHasNewline = end > lineContentEnd

            if lineHasNewline {
                let precededByBlankLine: Bool = {
                    guard start >= 2, ns.character(at: start - 1) == 0x0A else { return false }
                    if ns.character(at: start - 2) == 0x0A { return true }
                    return start >= 3 && ns.character(at: start - 2) == 0x0D && ns.character(at: start - 3) == 0x0A
                }()
                let trailingBlankNewlineLen: Int = {
                    if end < len && ns.character(at: end) == 0x0A { return 1 }
                    if end + 1 < len && ns.character(at: end) == 0x0D && ns.character(at: end + 1) == 0x0A { return 2 }
                    return 0
                }()
                if precededByBlankLine && trailingBlankNewlineLen > 0 {
                    end += trailingBlankNewlineLen
                }
            } else if start > 0 && ns.character(at: start - 1) == 0x0A {
                start -= 1
                if start > 0 && ns.character(at: start - 1) == 0x0D {
                    start -= 1
                }
            }

            removeStart = start
            removeEnd = end
        } else {
            var start = tokenRange.location
            var end = tokenEnd
            let isSpace: (unichar) -> Bool = { $0 == 0x20 || $0 == 0x09 }
            let spaceBefore = start > lineContentRange.location && isSpace(ns.character(at: start - 1))
            let spaceAfter = end < lineContentEnd && isSpace(ns.character(at: end))

            if spaceBefore && spaceAfter {
                end += 1
            } else if spaceAfter && prefixBlank {
                end += 1
            } else if spaceBefore && suffixBlank {
                start -= 1
            }

            removeStart = start
            removeEnd = end
        }

        let range = NSRange(location: removeStart, length: removeEnd - removeStart)
        let resulting = ns.replacingCharacters(in: range, with: "")
        return EmbedRemovalEdit(
            replacementRange: range,
            replacement: "",
            caretUTF16: removeStart,
            resultingText: resulting
        )
    }

    /// Computes the aspect-fitted display size for an inline image.
    /// When `explicitDimensions` is `nil`, scales down to `maxWidth × maxHeight` without upscaling past `naturalSize`.
    /// When `explicitDimensions` is provided (from `![[img.png|400]]` or `![[img.png|400x300]]`), honors the requested
    /// width clamped to `containerMaxWidth` (defaulting to `maxWidth`) while preserving aspect ratio.
    public static func fittedInlineImageSize(
        naturalSize: CGSize,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        explicitDimensions: KnowledgeEmbedDimensions? = nil,
        containerMaxWidth: CGFloat? = nil
    ) -> CGSize {
        let clampedMaxW = max(1, maxWidth)
        let clampedMaxH = max(1, maxHeight)
        if let explicit = explicitDimensions {
            let capW = max(60, containerMaxWidth ?? clampedMaxW)
            let targetW = max(60, min(capW, explicit.width))
            if let explicitH = explicit.height {
                let targetH = max(40, min(2400, explicitH))
                guard naturalSize.width > 0, naturalSize.height > 0 else {
                    return CGSize(width: ceil(targetW), height: ceil(targetH))
                }
                let scale = min(targetW / naturalSize.width, targetH / naturalSize.height)
                return CGSize(
                    width: max(1, ceil(naturalSize.width * scale)),
                    height: max(1, ceil(naturalSize.height * scale))
                )
            }
            guard naturalSize.width > 0, naturalSize.height > 0 else {
                return CGSize(width: ceil(targetW), height: ceil(targetW * 0.75))
            }
            let aspectH = targetW * (naturalSize.height / naturalSize.width)
            return CGSize(
                width: max(1, ceil(targetW)),
                height: max(1, min(2400, ceil(aspectH)))
            )
        }
        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return CGSize(width: min(clampedMaxW, 160), height: min(clampedMaxH, 120))
        }
        let scale = min(1, min(clampedMaxW / naturalSize.width, clampedMaxH / naturalSize.height))
        return CGSize(
            width: max(1, ceil(naturalSize.width * scale)),
            height: max(1, ceil(naturalSize.height * scale))
        )
    }

    private static func lineIndex(containing utf16Offset: Int, in lines: [LineSlice], hint: Int) -> Int {
        if hint >= 0, hint < lines.count {
            let candidate = lines[hint]
            let end = candidate.utf16Offset + max(1, candidate.totalUTF16Length)
            if utf16Offset >= candidate.utf16Offset && utf16Offset < end {
                return hint
            }
        }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].utf16Offset <= utf16Offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    private static func isLineOnlyEmbedTokens(line: LineSlice, tokenRanges: [NSRange]) -> Bool {
        let lineNS = line.text as NSString
        let total = lineNS.length
        guard total > 0 else { return false }

        var covered = Array(repeating: false, count: total)
        for range in tokenRanges {
            let localStart = max(0, range.location - line.utf16Offset)
            let localEnd = min(total, localStart + range.length)
            if localStart < localEnd {
                for i in localStart..<localEnd {
                    covered[i] = true
                }
            }
        }

        for i in 0..<total where !covered[i] {
            let ch = lineNS.character(at: i)
            if ch != 0x20 && ch != 0x09 { // space or tab
                return false
            }
        }
        return true
    }

    // MARK: Code-Exclusion & Incremental Diff Helpers

    /// Computes which syntax delimiter ranges should be hidden vs. revealed for `selection`
    /// using pre-scanned `tokens`, avoiding a redundant full-document scan on selection-only updates.
    public static func livePreview(
        tokens: [KnowledgeSyntaxToken],
        selection: NSRange?,
        isFocused: Bool = true,
        activeFindMatch: NSRange? = nil
    ) -> KnowledgeLivePreviewState {
        var revealedIndices = Set<Int>()
        var hidden: [NSRange] = []
        var revealed: [NSRange] = []

        for (index, token) in tokens.enumerated() {
            var shouldReveal = false
            if isFocused, let selection, intersects(tokenRange: token.range, selection: selection) {
                shouldReveal = true
            } else if let activeFindMatch, intersects(tokenRange: token.range, selection: activeFindMatch) {
                shouldReveal = true
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

    /// Minimal UTF-16 replacement ranges transforming `oldText` into `newText`, or `nil` when equal.
    public static func minimalEditDelta(
        from oldText: String,
        to newText: String
    ) -> (oldRange: NSRange, newRange: NSRange)? {
        if oldText == newText { return nil }
        let oldNS = oldText as NSString
        let newNS = newText as NSString
        let oldLen = oldNS.length
        let newLen = newNS.length
        let minLen = min(oldLen, newLen)

        var prefix = 0
        while prefix < minLen && oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }

        var suffix = 0
        let maxSuffix = minLen - prefix
        while suffix < maxSuffix && oldNS.character(at: oldLen - 1 - suffix) == newNS.character(at: newLen - 1 - suffix) {
            suffix += 1
        }

        return (
            oldRange: NSRange(location: prefix, length: oldLen - prefix - suffix),
            newRange: NSRange(location: prefix, length: newLen - prefix - suffix)
        )
    }

    /// Expands `range` to the full UTF-16 line span(s) covering it (including trailing newline if present).
    public static func lineSpan(covering range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return NSRange(location: 0, length: 0) }

        let clampedStart = max(0, min(range.location, len))
        let clampedEnd = max(clampedStart, min(range.location + range.length, len))

        var lineStart = clampedStart
        // If range starts right at EOF after a trailing newline, include that empty line only;
        // otherwise walk back to the start of the line containing `clampedStart`.
        while lineStart > 0 && ns.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }

        var lineEnd = clampedEnd
        // If a non-empty range ends exactly after '\n', it already ends at a line boundary.
        let endsAfterNewline = clampedEnd > clampedStart && clampedEnd > 0 && ns.character(at: clampedEnd - 1) == 0x0A
        if !endsAfterNewline {
            while lineEnd < len {
                let ch = ns.character(at: lineEnd)
                lineEnd += 1
                if ch == 0x0A { break }
            }
        }
        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }

    /// Returns `true` if `utf16Offset` falls strictly inside a YAML frontmatter block or fenced code block.
    static func isInsideFencedCodeOrFrontmatter(utf16Offset: Int, in markdown: String) -> Bool {
        isInsideCodeRegion(utf16Offset: utf16Offset, in: markdown, includeInlineCode: false)
    }

    /// Returns `true` if `utf16Offset` falls inside a fenced code block, frontmatter, or inline code span.
    static func isInsideCodeOrFrontmatter(utf16Offset: Int, in markdown: String) -> Bool {
        isInsideCodeRegion(utf16Offset: utf16Offset, in: markdown, includeInlineCode: true)
    }

    private static func isInsideCodeRegion(
        utf16Offset: Int,
        in markdown: String,
        includeInlineCode: Bool
    ) -> Bool {
        let ns = markdown as NSString
        let totalLength = ns.length
        guard utf16Offset > 0, utf16Offset < totalLength else { return false }

        // Walk line by line only up to `utf16Offset`, skipping all inline regexes on preceding lines.
        var pos = 0
        var lineIndex = 0
        var inFrontmatter = false
        var openFenceChar: Character?
        var openFenceLength = 0
        var fenceStartOffset = 0

        while pos < totalLength {
            var end = pos
            while end < totalLength && ns.character(at: end) != 0x0A {
                end += 1
            }
            let hasLF = end < totalLength && ns.character(at: end) == 0x0A
            let hasCR = end > pos && ns.character(at: end - 1) == 0x0D
            let contentEnd = hasCR ? end - 1 : end
            let lineEnd = hasLF ? end + 1 : end
            let contentLen = contentEnd - pos
            let lineText = ns.substring(with: NSRange(location: pos, length: contentLen))

            if lineIndex == 0 && lineText == "---" {
                // Only counts as frontmatter if a closing `---` or `...` exists later in the document.
                var scanPos = lineEnd
                var closingEnd: Int?
                while scanPos < totalLength {
                    var sEnd = scanPos
                    while sEnd < totalLength && ns.character(at: sEnd) != 0x0A { sEnd += 1 }
                    let sHasCR = sEnd > scanPos && ns.character(at: sEnd - 1) == 0x0D
                    let sContentEnd = sHasCR ? sEnd - 1 : sEnd
                    let sText = ns.substring(with: NSRange(location: scanPos, length: sContentEnd - scanPos))
                    if sText == "---" || sText == "..." {
                        closingEnd = sContentEnd
                        break
                    }
                    scanPos = (sEnd < totalLength && ns.character(at: sEnd) == 0x0A) ? sEnd + 1 : sEnd
                }
                if let closingEnd {
                    if utf16Offset < closingEnd {
                        return true
                    }
                    inFrontmatter = true
                }
            } else if inFrontmatter {
                if lineText == "---" || lineText == "..." {
                    inFrontmatter = false
                }
                lineIndex += 1
                pos = lineEnd
                continue
            }

            let lineNS = lineText as NSString
            if lineMayBeFence(lineNS),
               let fenceMatch = fenceRegex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
                let marker = lineNS.substring(with: fenceMatch.range(at: 1))
                let info = lineNS.substring(with: fenceMatch.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let currentChar = openFenceChar {
                    if marker.first == currentChar && marker.count >= openFenceLength && info.isEmpty {
                        let fenceEndOffset = contentEnd
                        if utf16Offset > fenceStartOffset && utf16Offset < fenceEndOffset {
                            return true
                        }
                        if utf16Offset < lineEnd {
                            return false
                        }
                        openFenceChar = nil
                        openFenceLength = 0
                        lineIndex += 1
                        pos = lineEnd
                        continue
                    }
                } else {
                    openFenceChar = marker.first
                    openFenceLength = marker.count
                    fenceStartOffset = pos
                    if utf16Offset < lineEnd {
                        let fenceEnd = (lineEnd == totalLength) ? contentEnd : totalLength
                        return utf16Offset > fenceStartOffset && utf16Offset < fenceEnd
                    }
                    lineIndex += 1
                    pos = lineEnd
                    continue
                }
            }

            // Reached the line containing `utf16Offset`.
            if utf16Offset >= pos && utf16Offset < lineEnd {
                if openFenceChar != nil {
                    let fenceEnd = (lineEnd == totalLength) ? contentEnd : totalLength
                    return utf16Offset > fenceStartOffset && utf16Offset < fenceEnd
                }
                guard includeInlineCode else { return false }
                // Only check inline code spans on this single line (and only if it has >= 2 backticks).
                var ticks = 0
                for i in 0..<lineNS.length where lineNS.character(at: i) == 0x60 {
                    ticks += 1
                    if ticks >= 2 { break }
                }
                guard ticks >= 2 else { return false }
                let localOffset = utf16Offset - pos
                for m in codeSpanRegex.matches(in: lineText, range: NSRange(location: 0, length: lineNS.length)) {
                    if localOffset > m.range.location && localOffset < m.range.location + m.range.length {
                        return true
                    }
                }
                return false
            }

            lineIndex += 1
            pos = lineEnd
        }

        return false
    }
}
