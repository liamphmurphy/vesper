import Foundation

// MARK: - Docs Review, Outline, Quote Matching & Export Logic

public enum DocReviewDecision: String, Sendable, Equatable, Codable {
    case accept
    case reject
}

public enum DocReviewSegment: Sendable, Equatable, Identifiable {
    case same(index: Int, blocks: [String])
    case change(id: Int, before: [String], after: [String])

    public var id: String {
        switch self {
        case .same(let idx, _): "same-\(idx)"
        case .change(let cid, _, _): "change-\(cid)"
        }
    }
}

public struct DocHeadingItem: Sendable, Equatable, Hashable, Identifiable {
    public let index: Int
    public let level: Int
    public let text: String

    public var id: String { "doc-h-\(index)" }

    public init(index: Int, level: Int, text: String) {
        self.index = index
        self.level = level
        self.text = text
    }
}

public struct DocQuoteRange: Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct DocPersonaMention: Sendable, Equatable {
    public let instruction: String
    public let afterContext: String
    public let lineRange: NSRange

    public init(instruction: String, afterContext: String, lineRange: NSRange) {
        self.instruction = instruction
        self.afterContext = afterContext
        self.lineRange = lineRange
    }
}

public enum DocEditorLogic: Sendable {
    /// The version a persona's changes are counted from: the person's own last edit, or the last
    /// version they finished reviewing, whichever is newer.
    public static func reviewBase(versions: [API.ChatCanvasVersion], reviewedSeq: Int = 0) -> Int {
        let ownLast = versions
            .filter { $0.authorType == .user }
            .map(\.seq)
            .max() ?? 0
        return max(ownLast, reviewedSeq)
    }

    /// Splits a Markdown document into top-level blocks (headings, paragraphs, lists, tables,
    /// fenced code blocks, blockquotes, horizontal rules) so review changes group naturally.
    public static func splitMarkdownBlocks(_ markdown: String) -> [String] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [String] = []
        var i = 0

        func isFence(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { return "```" }
            if trimmed.hasPrefix("~~~") { return "~~~" }
            return nil
        }

        func isHeading(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return false }
            let hashes = t.prefix(while: { $0 == "#" }).count
            guard hashes >= 1, hashes <= 6 else { return false }
            return t.count == hashes || t[t.index(t.startIndex, offsetBy: hashes)] == " "
        }

        func isHR(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
            guard t.count >= 3 else { return false }
            return t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" }
        }

        func isListLine(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") { return true }
            var idx = t.startIndex
            while idx < t.endIndex, t[idx].isNumber { idx = t.index(after: idx) }
            guard idx > t.startIndex, idx < t.endIndex else { return false }
            let punct = t[idx]
            let next = t.index(after: idx)
            return (punct == "." || punct == ")") && next < t.endIndex && t[next] == " "
        }

        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            if let fence = isFence(line) {
                var chunk = [line]
                i += 1
                while i < lines.count {
                    chunk.append(lines[i])
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    i += 1
                }
                blocks.append(chunk.joined(separator: "\n"))
                continue
            }
            if isHeading(line) || isHR(line) {
                blocks.append(line)
                i += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var chunk = [line]
                i += 1
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    chunk.append(lines[i])
                    i += 1
                }
                blocks.append(chunk.joined(separator: "\n"))
                continue
            }
            if isListLine(line) {
                var chunk = [line]
                i += 1
                while i < lines.count {
                    let cur = lines[i]
                    if cur.trimmingCharacters(in: .whitespaces).isEmpty {
                        if i + 1 < lines.count && (isListLine(lines[i + 1]) || lines[i + 1].hasPrefix("  ") || lines[i + 1].hasPrefix("\t")) {
                            chunk.append(cur)
                            i += 1
                            continue
                        }
                        break
                    }
                    if isListLine(cur) || cur.hasPrefix("  ") || cur.hasPrefix("\t") {
                        chunk.append(cur)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(chunk.joined(separator: "\n"))
                continue
            }
            // Table or paragraph: collect until blank line or block boundary.
            var chunk = [line]
            i += 1
            while i < lines.count {
                let cur = lines[i]
                if cur.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if isFence(cur) != nil || isHeading(cur) || isHR(cur) || cur.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    break
                }
                chunk.append(cur)
                i += 1
            }
            blocks.append(chunk.joined(separator: "\n"))
        }
        return blocks
    }

    /// Computes block-level diff segments between `base` and `head`, matching `web/lib/doc-review.ts`.
    public static func reviewSegments(base: String, head: String) -> [DocReviewSegment] {
        let a = splitMarkdownBlocks(base)
        let b = splitMarkdownBlocks(head)
        let n = a.count
        let m = b.count

        // LCS DP table
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        enum Step { case same(String), del(String), add(String) }
        var steps: [Step] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                steps.append(.same(a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                steps.append(.del(a[i]))
                i += 1
            } else {
                steps.append(.add(b[j]))
                j += 1
            }
        }
        while i < n { steps.append(.del(a[i])); i += 1 }
        while j < m { steps.append(.add(b[j])); j += 1 }

        var out: [DocReviewSegment] = []
        var changeId = 0
        var sameIdx = 0

        for step in steps {
            switch step {
            case .same(let blk):
                if case .same(let idx, var blocks) = out.last {
                    blocks.append(blk)
                    out[out.count - 1] = .same(index: idx, blocks: blocks)
                } else {
                    out.append(.same(index: sameIdx, blocks: [blk]))
                    sameIdx += 1
                }
            case .del(let blk):
                if case .change(let cid, var before, let after) = out.last {
                    before.append(blk)
                    out[out.count - 1] = .change(id: cid, before: before, after: after)
                } else {
                    out.append(.change(id: changeId, before: [blk], after: []))
                    changeId += 1
                }
            case .add(let blk):
                if case .change(let cid, let before, var after) = out.last {
                    after.append(blk)
                    out[out.count - 1] = .change(id: cid, before: before, after: after)
                } else {
                    out.append(.change(id: changeId, before: [], after: [blk]))
                    changeId += 1
                }
            }
        }
        return out
    }

    public static func resolveReview(
        segments: [DocReviewSegment],
        decisions: [Int: DocReviewDecision]
    ) -> String {
        var blocks: [String] = []
        for seg in segments {
            switch seg {
            case .same(_, let sameBlocks):
                blocks.append(contentsOf: sameBlocks)
            case .change(let id, let before, let after):
                if decisions[id] == .reject {
                    blocks.append(contentsOf: before)
                } else {
                    blocks.append(contentsOf: after)
                }
            }
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    public static func reviewNote(
        segments: [DocReviewSegment],
        decisions: [Int: DocReviewDecision],
        persona: String
    ) -> String {
        let changes = segments.compactMap { seg -> Int? in
            if case .change(let id, _, _) = seg { return id }
            return nil
        }
        let kept = changes.filter { decisions[$0] != .reject }.count
        if kept == 0 {
            return "Rejected \(persona)'s \(changes.count == 1 ? "change" : "\(changes.count) changes")"
        }
        return "Kept \(kept) of \(persona)'s \(changes.count) changes, rejected \(changes.count - kept)"
    }

    /// Plain-text headings in document order.
    public static func outlineOf(_ body: String) -> [DocHeadingItem] {
        var out: [DocHeadingItem] = []
        for blk in splitMarkdownBlocks(body) {
            let firstLine = blk.components(separatedBy: "\n").first ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard level >= 1, level <= 6 else { continue }
            let rest = trimmed.dropFirst(level)
            guard rest.first == " " else { continue }
            var title = String(rest.dropFirst())
            title = title.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            title = stripInlineMarkdown(title)
            if !title.isEmpty {
                out.append(DocHeadingItem(index: out.count, level: level, text: title))
            }
        }
        return out
    }

    public static func stripInlineMarkdown(_ md: String) -> String {
        var s = md
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Locates a plain-text selection inside Markdown source (skipping inline syntax markers),
    /// returning UTF-16 offsets (matching the server's `ChatCanvasAnchor` UTF-16 convention).
    public static func locateQuote(in markdown: String, quote: String, nearUTF16: Int = 0) -> DocQuoteRange? {
        let words = quote
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let inline = #"(?:[*_~`]|\][^\n)]*\)|\[)*"#
        let between = #"(?:\s|[*_~`>#|\-]|\d+[.)]|\][^\n)]*\)|\[|\[[ xX]\])+"#

        let escapedWords = words.map { word in
            word.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: inline)
        }
        let pattern = escapedWords.joined(separator: between)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = markdown as NSString
        let matches = regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let best = matches.min { a, b in
            abs(a.range.location - nearUTF16) < abs(b.range.location - nearUTF16)
        }!
        return DocQuoteRange(start: best.range.location, end: best.range.location + best.range.length)
    }

    /// Detects a standalone `@PersonaName instruction` paragraph on the current line.
    public static func detectPersonaMention(in text: String, cursorUTF16: Int, personaName: String) -> DocPersonaMention? {
        let first = personaName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? personaName
        let target = first.lowercased()
        guard !target.isEmpty else { return nil }

        let ns = text as NSString
        let clamped = max(0, min(cursorUTF16, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let rawLine = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        guard rawLine.hasPrefix("@") else { return nil }
        let rest = rawLine.dropFirst()
        guard let spaceIdx = rest.firstIndex(where: \.isWhitespace) else { return nil }
        let handle = String(rest[..<spaceIdx]).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?")).lowercased()
        guard handle == target else { return nil }
        let instruction = String(rest[spaceIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }

        let prefix = ns.substring(to: lineRange.location)
        let afterContext = prefix
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        return DocPersonaMention(instruction: instruction, afterContext: afterContext, lineRange: lineRange)
    }

    /// Sanitizes a document title for saving to disk.
    public static func sanitizedFileName(_ title: String, ext: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[\\/:*?"<>|\u0000-\u001f]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "document" : String(cleaned.prefix(120))
        return "\(stem).\(ext)"
    }

    /// Renders basic semantic HTML from Markdown for rich-text clipboard copy and print/PDF export.
    public static func renderHTML(markdown: String, title: String) -> String {
        var bodyParts: [String] = []
        for blk in splitMarkdownBlocks(markdown) {
            let trimmed = blk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                var lines = blk.components(separatedBy: "\n")
                if !lines.isEmpty { lines.removeFirst() }
                if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") || last.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                    lines.removeLast()
                }
                bodyParts.append("<pre><code>\(escapeXML(lines.joined(separator: "\n")))</code></pre>")
            } else if trimmed.hasPrefix("#") {
                let level = min(6, trimmed.prefix(while: { $0 == "#" }).count)
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                bodyParts.append("<h\(level)>\(inlineHTML(text))</h\(level)>")
            } else if isHorizontalRule(trimmed) {
                bodyParts.append("<hr/>")
            } else if trimmed.hasPrefix(">") {
                let inner = blk.components(separatedBy: "\n")
                    .map { $0.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression) }
                    .joined(separator: "<br/>")
                bodyParts.append("<blockquote><p>\(inlineHTML(inner))</p></blockquote>")
            } else if isPipeTable(blk) {
                bodyParts.append(renderTableHTML(blk))
            } else if isOrderedListBlock(blk) {
                let items = listItems(blk).map { "<li>\(inlineHTML($0.text))</li>" }.joined()
                bodyParts.append("<ol>\(items)</ol>")
            } else if isBulletListBlock(blk) {
                let items = listItems(blk).map { item -> String in
                    if let checked = item.checked {
                        return "<li>\(checked ? "&#9745;" : "&#9744;") \(inlineHTML(item.text))</li>"
                    }
                    return "<li>\(inlineHTML(item.text))</li>"
                }.joined()
                bodyParts.append("<ul>\(items)</ul>")
            } else {
                let text = blk.components(separatedBy: "\n").map(inlineHTML).joined(separator: "<br/>")
                bodyParts.append("<p>\(text)</p>")
            }
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapeXML(title))</title>
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #1a1a1f; line-height: 1.6; max-width: 720px; margin: 32px auto; padding: 0 24px; font-size: 14px; }
        h1, h2, h3, h4, h5, h6 { margin: 1.2em 0 0.45em; line-height: 1.25; }
        h1 { font-size: 26px; } h2 { font-size: 20px; } h3 { font-size: 16px; }
        p { margin: 0.6em 0; }
        pre { background: #f4f5f7; padding: 12px 14px; border-radius: 6px; overflow-x: auto; font-family: Menlo, monospace; font-size: 12px; }
        code { background: #f4f5f7; padding: 1px 4px; border-radius: 4px; font-family: Menlo, monospace; font-size: 0.92em; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #d0d4dc; margin: 0.8em 0; padding: 2px 14px; color: #525866; }
        table { border-collapse: collapse; width: 100%; margin: 1em 0; }
        th, td { border: 1px solid #d8dce4; padding: 6px 10px; text-align: left; }
        th { background: #f4f5f7; font-weight: 600; }
        hr { border: none; border-top: 1px solid #d8dce4; margin: 1.4em 0; }
        </style>
        </head>
        <body>
        \(bodyParts.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    // MARK: - DOCX Export (Pure Swift OpenXML)

    /// Exports a Markdown document to a valid Word `.docx` binary archive (headings, inline marks,
    /// links, bullet/ordered/task lists, blockquotes, code blocks, tables, horizontal rules).
    public static func exportDocx(markdown: String, title: String) -> Data {
        var rels: [(id: String, url: String)] = []
        var nextRelId = 3 // rId1 = styles, rId2 = numbering
        var bodyXML = ""
        var listNumId = 0
        var orderedListNumIds: [Int] = []

        func addHyperlink(_ url: String) -> String {
            let rid = "rId\(nextRelId)"
            nextRelId += 1
            rels.append((rid, url))
            return rid
        }

        func runsXML(_ text: String, forceCode: Bool = false) -> String {
            let tokens = parseInlineTokens(text)
            if tokens.isEmpty { return "" }
            var out = ""
            for tok in tokens {
                let rPr = buildRunProps(bold: tok.bold, italic: tok.italic, strike: tok.strike, code: tok.code || forceCode, isLink: tok.link != nil)
                let rXML = "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escapeXML(tok.text))</w:t></w:r>"
                if let href = tok.link, !href.isEmpty {
                    let rid = addHyperlink(href)
                    out += "<w:hyperlink r:id=\"\(rid)\">\(rXML)</w:hyperlink>"
                } else {
                    out += rXML
                }
            }
            return out
        }

        for blk in splitMarkdownBlocks(markdown) {
            let trimmed = blk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                var lines = blk.components(separatedBy: "\n")
                if !lines.isEmpty { lines.removeFirst() }
                if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") || last.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                    lines.removeLast()
                }
                let runLines = lines.enumerated().map { idx, line in
                    let br = idx > 0 ? "<w:br/>" : ""
                    return "\(br)<w:t xml:space=\"preserve\">\(escapeXML(line))</w:t>"
                }.joined()
                bodyXML += """
                <w:p><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F3F3F3"/><w:ind w:left="200" w:right="200"/><w:spacing w:before="80" w:after="120"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="20"/></w:rPr>\(runLines)</w:r></w:p>
                """
            } else if trimmed.hasPrefix("#") {
                let level = min(6, trimmed.prefix(while: { $0 == "#" }).count)
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                bodyXML += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(level)\"/></w:pPr>\(runsXML(text))</w:p>"
            } else if isHorizontalRule(trimmed) {
                bodyXML += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"CCCCCC\"/></w:pBdr><w:spacing w:before=\"120\" w:after=\"120\"/></w:pPr></w:p>"
            } else if trimmed.hasPrefix(">") {
                let lines = blk.components(separatedBy: "\n")
                    .map { $0.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression) }
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    bodyXML += "<w:p><w:pPr><w:ind w:left=\"360\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"12\" w:space=\"8\" w:color=\"CCCCCC\"/></w:pBdr><w:spacing w:after=\"80\"/></w:pPr>\(runsXML(line))</w:p>"
                }
            } else if isPipeTable(blk) {
                bodyXML += renderTableDocx(blk, runsXML: { runsXML($0) })
            } else if isOrderedListBlock(blk) {
                listNumId += 1
                let numId = 10 + listNumId
                orderedListNumIds.append(numId)
                for item in listItems(blk) {
                    let ilvl = min(5, item.indent / 2)
                    bodyXML += "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr>\(runsXML(item.text))</w:p>"
                }
            } else if isBulletListBlock(blk) {
                for item in listItems(blk) {
                    let ilvl = min(5, item.indent / 2)
                    if let checked = item.checked {
                        let prefix = checked ? "☑ " : "☐ "
                        bodyXML += "<w:p><w:pPr><w:ind w:left=\"\(360 * (ilvl + 1))\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(prefix)</w:t></w:r>\(runsXML(item.text))</w:p>"
                    } else {
                        bodyXML += "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>\(runsXML(item.text))</w:p>"
                    }
                }
            } else {
                let joined = blk.components(separatedBy: "\n").joined(separator: " ")
                bodyXML += "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr>\(runsXML(joined))</w:p>"
            }
        }

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:body>
        \(bodyXML)
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
        </w:body>
        </w:document>
        """

        let relEntries = rels.map {
            "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escapeXML($0.url))\" TargetMode=\"External\"/>"
        }.joined()
        let documentRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        \(relEntries)
        </Relationships>
        """

        let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        </Types>
        """

        let corePropsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(escapeXML(title))</dc:title>
        <dc:creator>Vesper</dc:creator>
        </cp:coreProperties>
        """

        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:pPr><w:spacing w:before="200" w:after="100"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:pPr><w:spacing w:before="160" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading4"><w:name w:val="heading 4"/><w:pPr><w:spacing w:before="140" w:after="60"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading5"><w:name w:val="heading 5"/><w:rPr><w:b/><w:sz w:val="22"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="Heading6"><w:name w:val="heading 6"/><w:rPr><w:b/><w:sz w:val="20"/></w:rPr></w:style>
        </w:styles>
        """

        let bulletLevels = (0..<6).map { lvl in
            "<w:lvl w:ilvl=\"\(lvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\((lvl + 1) * 360)\" w:hanging=\"180\"/></w:pPr></w:lvl>"
        }.joined()
        let decimalLevels = (0..<6).map { lvl in
            "<w:lvl w:ilvl=\"\(lvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%\(lvl + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\((lvl + 1) * 360)\" w:hanging=\"180\"/></w:pPr></w:lvl>"
        }.joined()
        let orderedNums = orderedListNumIds.map { numId in
            "<w:num w:numId=\"\(numId)\"><w:abstractNumId w:val=\"2\"/></w:num>"
        }.joined()
        let numberingXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:abstractNum w:abstractNumId="1">\(bulletLevels)</w:abstractNum>
        <w:abstractNum w:abstractNumId="2">\(decimalLevels)</w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
        \(orderedNums)
        </w:numbering>
        """

        return MinimalZipWriter.archive([
            .init(path: "[Content_Types].xml", utf8: contentTypesXML),
            .init(path: "_rels/.rels", utf8: rootRelsXML),
            .init(path: "docProps/core.xml", utf8: corePropsXML),
            .init(path: "word/document.xml", utf8: documentXML),
            .init(path: "word/_rels/document.xml.rels", utf8: documentRelsXML),
            .init(path: "word/styles.xml", utf8: stylesXML),
            .init(path: "word/numbering.xml", utf8: numberingXML),
        ])
    }

    // MARK: - Private Markdown/XML Helpers

    private struct InlineToken {
        var text: String
        var bold: Bool = false
        var italic: Bool = false
        var strike: Bool = false
        var code: Bool = false
        var link: String? = nil
    }

    private struct ListItemParsed {
        var indent: Int
        var text: String
        var checked: Bool?
    }

    private static func buildRunProps(bold: Bool, italic: Bool, strike: Bool, code: Bool, isLink: Bool) -> String {
        var props = ""
        if bold { props += "<w:b/>" }
        if italic { props += "<w:i/>" }
        if strike { props += "<w:strike/>" }
        if code { props += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
        if isLink { props += "<w:color w:val=\"2563EB\"/><w:u w:val=\"single\"/>" }
        return props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    private static func isOrderedListBlock(_ blk: String) -> Bool {
        guard let first = blk.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) else { return false }
        var idx = first.startIndex
        while idx < first.endIndex, first[idx].isNumber { idx = first.index(after: idx) }
        guard idx > first.startIndex, idx < first.endIndex else { return false }
        let ch = first[idx]
        let next = first.index(after: idx)
        return (ch == "." || ch == ")") && next < first.endIndex && first[next] == " "
    }

    private static func isBulletListBlock(_ blk: String) -> Bool {
        guard let first = blk.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) else { return false }
        return first.hasPrefix("- ") || first.hasPrefix("* ") || first.hasPrefix("+ ")
    }

    private static func listItems(_ blk: String) -> [ListItemParsed] {
        var out: [ListItemParsed] = []
        for raw in blk.components(separatedBy: "\n") {
            let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            var content = t
            if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
                content = String(content.dropFirst(2))
            } else {
                content = content.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
            }
            var checked: Bool?
            if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                checked = true
                content = String(content.dropFirst(4))
            } else if content.hasPrefix("[ ] ") {
                checked = false
                content = String(content.dropFirst(4))
            }
            out.append(ListItemParsed(indent: indent, text: content, checked: checked))
        }
        return out
    }

    private static func isPipeTable(_ blk: String) -> Bool {
        let lines = blk.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, lines[0].contains("|"), lines[1].contains("|") else { return false }
        let sep = lines[1].replacingOccurrences(of: "|", with: "").replacingOccurrences(of: " ", with: "")
        return !sep.isEmpty && sep.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func parseTableRows(_ blk: String) -> [[String]] {
        let lines = blk.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var rows: [[String]] = []
        for (idx, line) in lines.enumerated() where idx != 1 {
            var s = line
            if s.hasPrefix("|") { s.removeFirst() }
            if s.hasSuffix("|") { s.removeLast() }
            rows.append(s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        return rows
    }

    private static func renderTableHTML(_ blk: String) -> String {
        let rows = parseTableRows(blk)
        guard !rows.isEmpty else { return "" }
        var html = "<table><thead><tr>"
        for cell in rows[0] { html += "<th>\(inlineHTML(cell))</th>" }
        html += "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>"
            for cell in row { html += "<td>\(inlineHTML(cell))</td>" }
            html += "</tr>"
        }
        html += "</tbody></table>"
        return html
    }

    private static func renderTableDocx(_ blk: String, runsXML: (String) -> String) -> String {
        let rows = parseTableRows(blk)
        guard !rows.isEmpty else { return "" }
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:color=\"D1D5DB\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"D1D5DB\"/><w:left w:val=\"single\" w:sz=\"4\" w:color=\"D1D5DB\"/><w:right w:val=\"single\" w:sz=\"4\" w:color=\"D1D5DB\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"D1D5DB\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"D1D5DB\"/></w:tblBorders></w:tblPr>"
        for (rowIdx, row) in rows.enumerated() {
            xml += "<w:tr>"
            for cell in row {
                let shading = rowIdx == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F3F3\"/>" : ""
                let boldStart = rowIdx == 0 ? "<w:rPr><w:b/></w:rPr>" : ""
                let cellContent = rowIdx == 0 && !cell.isEmpty
                    ? "<w:r>\(boldStart)<w:t xml:space=\"preserve\">\(escapeXML(stripInlineMarkdown(cell)))</w:t></w:r>"
                    : runsXML(cell)
                xml += "<w:tc><w:tcPr>\(shading)</w:tcPr><w:p>\(cellContent)</w:p></w:tc>"
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"
        return xml
    }

    private static func parseInlineTokens(_ input: String) -> [InlineToken] {
        // Regex matches links, inline code, bold, strikethrough, italic in priority order.
        let pattern = #"\[([^\]]+)\]\(([^)\s]+)\)|`([^`]+)`|\*\*([^*]+)\*\*|__([^_]+)__|~~([^~]+)~~|\*([^*]+)\*|_([^_]+)_"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [InlineToken(text: input)]
        }
        let ns = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        var out: [InlineToken] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                out.append(InlineToken(text: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            if m.range(at: 1).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 1)), link: ns.substring(with: m.range(at: 2))))
            } else if m.range(at: 3).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 3)), code: true))
            } else if m.range(at: 4).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 4)), bold: true))
            } else if m.range(at: 5).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 5)), bold: true))
            } else if m.range(at: 6).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 6)), strike: true))
            } else if m.range(at: 7).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 7)), italic: true))
            } else if m.range(at: 8).location != NSNotFound {
                out.append(InlineToken(text: ns.substring(with: m.range(at: 8)), italic: true))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(InlineToken(text: ns.substring(from: cursor)))
        }
        return out
    }

    private static func inlineHTML(_ input: String) -> String {
        parseInlineTokens(input).map { tok -> String in
            var s = escapeXML(tok.text)
            if tok.code { s = "<code>\(s)</code>" }
            if tok.bold { s = "<strong>\(s)</strong>" }
            if tok.italic { s = "<em>\(s)</em>" }
            if tok.strike { s = "<del>\(s)</del>" }
            if let href = tok.link { s = "<a href=\"\(escapeXML(href))\">\(s)</a>" }
            return s
        }.joined()
    }
}
