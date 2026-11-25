import Foundation

/// What the native `/print/knowledge/:id` and `/print/artifacts/:id` screens print, as a
/// `PrintDocument`: the header fields, a saved query's rows and the body split into markdown,
/// callouts and embeds. Platform-neutral so it can be tested without AppKit; `PrintRenderer` turns
/// it into paginated text.
public enum PrintDocumentBuilder {

    // MARK: - Callout Tones & Print Segments

    public enum CalloutTone: String, Sendable, Equatable {
        case note, tip, warning, danger, quote

        public static func from(type: String) -> CalloutTone {
            switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "tip", "hint", "important", "success", "check", "done":
                return .tip
            case "warning", "caution", "attention", "question", "help", "faq":
                return .warning
            case "danger", "error", "fail", "failure", "missing", "bug":
                return .danger
            case "quote", "cite":
                return .quote
            default:
                return .note
            }
        }
    }

    public enum PrintSegment: Sendable, Equatable {
        case markdown(String)
        case callout(calloutType: String, tone: CalloutTone, title: String, body: String)
        case embed(raw: String, fallbackLabel: String, embed: KnowledgeEmbed?)
    }

    // MARK: - Text Helpers

    public static func formatPropertyValue(_ v: JSONValue) -> String {
        switch v {
        case .null:
            return ""
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
        case .string(let s):
            return stripWikiBrackets(s)
        case .array(let arr):
            return arr.map(formatPropertyValue).filter { !$0.isEmpty }.joined(separator: ", ")
        case .object:
            if let data = try? JSONEncoder().encode(v), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return ""
        }
    }

    /// Replaces `[[target|label]]` with `label` and `[[folder/Page]]` with `Page`.
    public static func stripWikiBrackets(_ text: String) -> String {
        guard text.contains("[[") else { return text }
        let pattern = #"\[\[([^\]\n]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let inner = ns.substring(with: m.range(at: 1))
            if let pipe = inner.firstIndex(of: "|") {
                out += String(inner[inner.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            } else {
                let target = inner.split(separator: "#", maxSplits: 1).first.map(String.init) ?? inner
                let base = target.split(separator: "/").last.map(String.init) ?? target
                out += base.trimmingCharacters(in: .whitespaces)
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Drops a leading `# Title` line when it repeats the document's own title header.
    public static func stripDuplicateLeadingHeading(_ md: String, title: String) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTitle.isEmpty else { return md }
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var first = 0
        while first < lines.count && lines[first].trimmingCharacters(in: .whitespaces).isEmpty {
            first += 1
        }
        guard first < lines.count else { return md }
        let trimmed = lines[first].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return md }
        let afterHash = trimmed.dropFirst()
        guard afterHash.first == " " || afterHash.first == "\t" else { return md }
        var heading = afterHash.trimmingCharacters(in: .whitespaces)
        while heading.hasSuffix("#") { heading.removeLast() }
        heading = heading.trimmingCharacters(in: .whitespaces).lowercased()
        guard heading == normalizedTitle else { return md }
        var next = first + 1
        while next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
            next += 1
        }
        return lines[next...].joined(separator: "\n")
    }

    /// Strips Obsidian `^block-id` suffixes outside fenced code blocks and inline code spans.
    public static func stripObsidianBlockIds(_ md: String) -> String {
        let lines = md.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var fence = ""
        let blockIdRe = try? NSRegularExpression(pattern: #"\s+\^[A-Za-z0-9-]+\s*$"#)
        return lines.map { line in
            if fence.isEmpty {
                if let opened = openingFence(line) {
                    fence = opened
                    return line
                }
            } else {
                if isClosingFence(line, fence: fence) { fence = "" }
                return line
            }
            let masked = maskInlineCode(line)
            if let re = blockIdRe,
               let match = re.firstMatch(in: masked, range: NSRange(location: 0, length: (masked as NSString).length)) {
                let nsLine = line as NSString
                return nsLine.substring(to: match.range.location)
            }
            return line
        }.joined(separator: "\n")
    }

    public static func embedFallbackLabel(_ raw: String) -> String {
        var inner = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.hasPrefix("![[") { inner = String(inner.dropFirst(3)) }
        if inner.hasSuffix("]]") { inner = String(inner.dropLast(2)) }
        inner = inner.trimmingCharacters(in: .whitespaces)
        if let pipe = inner.firstIndex(of: "|") {
            let display = String(inner[inner.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            if !display.isEmpty { return display }
            inner = String(inner[..<pipe]).trimmingCharacters(in: .whitespaces)
        }
        var anchor: String?
        if let hash = inner.firstIndex(of: "#") {
            anchor = String(inner[inner.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            inner = String(inner[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        var target = inner
        if target.hasPrefix("attachment:") {
            let rest = String(target.dropFirst("attachment:".count))
            if let slash = rest.firstIndex(of: "/") {
                target = String(rest[rest.index(after: slash)...])
            } else {
                target = rest.isEmpty ? "Attachment" : rest
            }
        } else if target.hasPrefix("library:") {
            let rest = String(target.dropFirst("library:".count))
            target = rest.isEmpty ? "Library item" : rest
        } else if target.hasPrefix("design:") {
            let rest = String(target.dropFirst("design:".count))
            target = rest.isEmpty ? "Design" : rest
        }
        let base = target.split(separator: "/").last.map(String.init) ?? target
        if base.isEmpty { return anchor ?? "Attachment" }
        if let anchor, !anchor.isEmpty { return "\(base) › \(anchor)" }
        return base
    }

    // MARK: - Knowledge Print Segmentation

    public static func prepareKnowledgePrint(
        body: String,
        title: String,
        embeds: [KnowledgeEmbed] = [],
        stripTitle: Bool = true
    ) -> [PrintSegment] {
        let withoutTitle = stripTitle ? stripDuplicateLeadingHeading(body, title: title) : body
        let cleaned = stripObsidianBlockIds(withoutTitle)
        let lines = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var segments: [PrintSegment] = []
        var mdBuffer: [String] = []
        var fence = ""

        func flushMarkdown() {
            let content = mdBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                segments.append(.markdown(content))
            }
            mdBuffer.removeAll()
        }

        let calloutRe = try? NSRegularExpression(pattern: #"^ {0,3}>\s*\[!([A-Za-z-]+)\]([+-])?(?:\s+(.*))?$"#)
        let quoteLineRe = try? NSRegularExpression(pattern: #"^ {0,3}>\s?"#)
        let standaloneEmbedRe = try? NSRegularExpression(pattern: #"^!\[\[([^\[\]\n]+?)\]\]$"#)

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if !fence.isEmpty {
                mdBuffer.append(line)
                if isClosingFence(line, fence: fence) { fence = "" }
                i += 1
                continue
            }
            if let opened = openingFence(line) {
                fence = opened
                mdBuffer.append(line)
                i += 1
                continue
            }

            let nsLine = line as NSString
            if let calloutRe,
               let match = calloutRe.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                flushMarkdown()
                let rawType = nsLine.substring(with: match.range(at: 1))
                let explicitTitle = match.range(at: 3).location != NSNotFound
                    ? nsLine.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                    : ""
                let calloutTitle = explicitTitle.isEmpty
                    ? rawType.prefix(1).uppercased() + rawType.dropFirst().lowercased()
                    : explicitTitle

                var bodyLines: [String] = []
                var calloutFence = ""
                while i + 1 < lines.count {
                    let next = lines[i + 1]
                    let nsNext = next as NSString
                    guard let quoteLineRe,
                          let qm = quoteLineRe.firstMatch(in: next, range: NSRange(location: 0, length: nsNext.length)) else {
                        break
                    }
                    i += 1
                    let inner = nsNext.substring(from: qm.range.location + qm.range.length)
                    if !calloutFence.isEmpty {
                        bodyLines.append(inner)
                        if isClosingFence(inner, fence: calloutFence) { calloutFence = "" }
                    } else if let opened = openingFence(inner) {
                        calloutFence = opened
                        bodyLines.append(inner)
                    } else {
                        bodyLines.append(rewriteInlineEmbeds(inner, embeds: embeds))
                    }
                }
                segments.append(.callout(
                    calloutType: rawType.lowercased(),
                    tone: CalloutTone.from(type: rawType),
                    title: calloutTitle,
                    body: bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                i += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let nsTrimmed = trimmed as NSString
            if let standaloneEmbedRe,
               standaloneEmbedRe.firstMatch(in: trimmed, range: NSRange(location: 0, length: nsTrimmed.length)) != nil {
                flushMarkdown()
                segments.append(.embed(
                    raw: trimmed,
                    fallbackLabel: embedFallbackLabel(trimmed),
                    embed: findEmbed(raw: trimmed, embeds: embeds)
                ))
                i += 1
                continue
            }

            mdBuffer.append(rewriteInlineEmbeds(line, embeds: embeds))
            i += 1
        }
        flushMarkdown()
        return segments
    }

    // MARK: - Documents

    public static func visibleProperties(_ props: [String: JSONValue]) -> [(String, JSONValue)] {
        let hidden: Set<String> = ["query", "zettel_id", "aliases", "title"]
        return props
            .filter { !hidden.contains($0.key) && !$0.key.hasPrefix("_") }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    /// A Knowledge page in one of its four paper styles. Metadata (the folder and properties) only
    /// when asked for; a saved query's rows print above the body, as they show on the page.
    public static func knowledgeDocument(
        page: KnowledgePage,
        style: KnowledgePrintStyle,
        showMetadata: Bool = false,
        savedQuery: KnowledgePageTable? = nil
    ) -> PrintDocument {
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : page.title
        let crumbs = (page.path ?? title).split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var header = PrintHeader(title: title)
        if showMetadata {
            if crumbs.count > 1 { header.folder = crumbs.dropLast().joined(separator: " / ") }
            header.properties = visibleProperties(page.properties).map { key, value in
                if key == "tags", case .array(let tags) = value {
                    return PrintProperty(key: key, value: .tags(tags.map(formatPropertyValue).filter { !$0.isEmpty }))
                }
                let formatted = formatPropertyValue(value)
                return PrintProperty(key: key, value: .text(formatted.isEmpty ? "—" : formatted))
            }
        }
        let query = savedQuery.flatMap { $0.rows.isEmpty ? nil : queryTable($0) }
        let segments = prepareKnowledgePrint(body: page.bodyMd ?? "", title: title, embeds: page.embeds)
        return PrintDocument(title: title, style: style, header: header, query: query, body: blocks(segments))
    }

    /// An artifact version in the Clean style. When the body opens with the title as its own `#`
    /// heading, that heading is the title and the header doesn't repeat it.
    public static func artifactDocument(
        title: String,
        versionLabel: String,
        authorName: String,
        createdAt: String,
        summary: String,
        bodyMarkdown: String
    ) -> PrintDocument {
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        let ownTitle = stripDuplicateLeadingHeading(bodyMarkdown, title: displayTitle) != bodyMarkdown
        let metaLine = [versionLabel, authorName, createdAt].filter { !$0.isEmpty }.joined(separator: " · ")
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = PrintHeader(
            title: ownTitle ? nil : displayTitle,
            metaLine: metaLine.isEmpty ? nil : metaLine,
            summary: trimmedSummary.isEmpty ? nil : trimmedSummary
        )
        return PrintDocument(title: displayTitle, style: .clean, header: header, body: [.markdown(MarkdownParser.parse(bodyMarkdown))])
    }

    static func blocks(_ segments: [PrintSegment]) -> [PrintBlock] {
        segments.map { segment -> PrintBlock in
            switch segment {
            case .markdown(let content):
                return .markdown(MarkdownParser.parse(content))
            case .callout(_, let tone, let title, let body):
                return .callout(tone: tone, title: title, body: MarkdownParser.parse(body))
            case .embed(_, let fallbackLabel, let embed):
                return block(embed: embed, fallbackLabel: fallbackLabel)
            }
        }
    }

    private static func block(embed: KnowledgeEmbed?, fallbackLabel: String) -> PrintBlock {
        guard let e = embed, e.available else {
            return .notice("Embedded reference unavailable: \(fallbackLabel)")
        }
        if let url = e.url, !url.isEmpty, e.kind == "image" || (e.contentType?.hasPrefix("image/") ?? false), isPrintableImageURL(url) {
            return .image(url: url, alt: e.title ?? fallbackLabel)
        }
        if e.kind == "page", let markdown = e.markdown {
            let nested = blocks(prepareKnowledgePrint(body: markdown, title: e.title ?? "", embeds: [], stripTitle: true))
            return .page(caption: e.title, body: nested.isEmpty ? [.notice("Empty page")] : nested)
        }
        let kind: String
        if let ct = e.contentType?.lowercased(), ct == "application/pdf" || ct.hasSuffix("+pdf") {
            kind = "PDF"
        } else if e.kind == "video" || (e.contentType?.hasPrefix("video/") ?? false) {
            kind = "Video"
        } else if e.contentType?.hasPrefix("audio/") ?? false {
            kind = "Audio"
        } else if e.kind == "design" {
            kind = "Design"
        } else {
            kind = "Attachment"
        }
        return .reference(kind: kind, name: e.title ?? fallbackLabel)
    }

    /// The saved query's table as the page shows it: Name, its four most-used properties, Tags
    /// (the first three) and Audience.
    static func queryTable(_ table: KnowledgePageTable) -> PrintQueryTable {
        let excluded: Set<String> = ["tags", "aliases", "query", "zettel_id", "title"]
        var counts: [String: Int] = [:]
        for row in table.rows {
            for key in row.properties.keys where !excluded.contains(key) {
                counts[key, default: 0] += 1
            }
        }
        let cols = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4).map(\.key)
        let rows = table.rows.map { row -> [String] in
            let values = cols.map { col -> String in
                let val = row.properties[col].map(formatPropertyValue) ?? ""
                return val.isEmpty ? "—" : val
            }
            let tags: String
            if case .array(let arr) = row.properties["tags"] {
                tags = arr.prefix(3).map(formatPropertyValue).filter { !$0.isEmpty }.map { "#\($0)" }.joined(separator: " ")
            } else {
                tags = ""
            }
            let audience = switch row.audience {
            case .private: "Private"
            case .shared: "Shared"
            case .agent: "Agent"
            }
            return [row.title] + values + [tags, audience]
        }
        return PrintQueryTable(
            columns: ["Name"] + cols + ["Tags", "Audience"],
            rows: rows,
            footnote: table.hasMore ? "Showing the first \(table.rows.count) pages." : nil
        )
    }

    /// Images the printout can fetch: the server's own paths, the web and inline data. Anything
    /// else (a `file:` URL in pasted markdown) prints as its alt text.
    public static func isPrintableImageURL(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || (lower.hasPrefix("/") && !lower.hasPrefix("//")) || lower.hasPrefix("data:image/")
    }

    // MARK: - Line/Embed Parsing Helpers

    private static func openingFence(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3 else { return nil }
        guard let ch = trimmed.first, ch == "`" || ch == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == ch })
        return run.count >= 3 ? String(run) : nil
    }

    private static func isClosingFence(_ line: String, fence: String) -> Bool {
        guard let ch = fence.first else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == ch }
    }

    private static func maskInlineCode(_ line: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(`+)([^`\n]*?)\1"#) else { return line }
        let ns = line as NSString
        let matches = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return line }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += String(repeating: "_", count: m.range.length)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func findEmbed(raw: String, embeds: [KnowledgeEmbed]) -> KnowledgeEmbed? {
        if let exact = embeds.first(where: { $0.ref == raw }) { return exact }
        let target = raw.trimmingCharacters(in: .whitespaces)
        return embeds.first(where: { $0.ref.trimmingCharacters(in: .whitespaces) == target })
    }

    private static func rewriteInlineEmbeds(_ line: String, embeds: [KnowledgeEmbed]) -> String {
        guard line.contains("![[") else { return line }
        let masked = maskInlineCode(line)
        guard let re = try? NSRegularExpression(pattern: #"!\[\[([^\[\]\n]+?)\]\]"#) else { return line }
        let nsMasked = masked as NSString
        let nsLine = line as NSString
        let matches = re.matches(in: masked, range: NSRange(location: 0, length: nsMasked.length))
        guard !matches.isEmpty else { return line }
        var out = ""
        var cursor = 0
        for m in matches {
            out += nsLine.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let raw = nsLine.substring(with: m.range)
            let embed = findEmbed(raw: raw, embeds: embeds)
            let fallback = embedFallbackLabel(raw)
            if let embed, embed.available, let url = embed.url, !url.isEmpty,
               (embed.kind == "image" || (embed.contentType?.hasPrefix("image/") ?? false)) {
                let alt = (embed.title ?? fallback).replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                let safeUrl = url.replacingOccurrences(of: " ", with: "%20")
                    .replacingOccurrences(of: "(", with: "%28")
                    .replacingOccurrences(of: ")", with: "%29")
                out += "![\(alt)](\(safeUrl))"
            } else {
                out += embed?.title ?? fallback
            }
            cursor = m.range.location + m.range.length
        }
        out += nsLine.substring(from: cursor)
        return out
    }
}

// MARK: - Model

/// A printable document: what is printed and in which order, without fonts or colours.
public struct PrintDocument: Sendable, Equatable {
    /// The print job's name and the running header on every page.
    public var title: String
    public var style: KnowledgePrintStyle
    public var header: PrintHeader
    public var query: PrintQueryTable?
    public var body: [PrintBlock]

    public init(title: String, style: KnowledgePrintStyle, header: PrintHeader, query: PrintQueryTable? = nil, body: [PrintBlock]) {
        self.title = title
        self.style = style
        self.header = header
        self.query = query
        self.body = body
    }

    /// Every image the body shows, in order and without repeats, to fetch before laying it out.
    public var imageURLs: [String] {
        var seen = Set<String>()
        var out: [String] = []
        func visit(_ blocks: [PrintBlock]) {
            for block in blocks {
                switch block {
                case .markdown(let doc), .callout(_, _, let doc):
                    for url in doc.imageURLs where PrintDocumentBuilder.isPrintableImageURL(url) && seen.insert(url).inserted { out.append(url) }
                case .image(let url, _):
                    if seen.insert(url).inserted { out.append(url) }
                case .page(_, let nested):
                    visit(nested)
                case .reference, .notice:
                    break
                }
            }
        }
        visit(body)
        return out
    }
}

/// The block above the body. `title` is nil when the body opens with its own title heading.
public struct PrintHeader: Sendable, Equatable {
    public var folder: String?
    public var title: String?
    public var metaLine: String?
    public var summary: String?
    public var properties: [PrintProperty]

    public init(folder: String? = nil, title: String?, metaLine: String? = nil, summary: String? = nil, properties: [PrintProperty] = []) {
        self.folder = folder
        self.title = title
        self.metaLine = metaLine
        self.summary = summary
        self.properties = properties
    }
}

public struct PrintProperty: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case text(String)
        case tags([String])
    }

    public var key: String
    public var value: Value

    public init(key: String, value: Value) {
        self.key = key
        self.value = value
    }
}

/// A saved query's rows as plain strings, one per column, header included in `columns`.
public struct PrintQueryTable: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[String]]
    /// Said under the table when the server returned only the first rows.
    public var footnote: String?

    public init(columns: [String], rows: [[String]], footnote: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.footnote = footnote
    }
}

public indirect enum PrintBlock: Sendable, Equatable {
    case markdown(MarkdownDocument)
    /// An Obsidian `> [!type] Title` callout, its body parsed on its own.
    case callout(tone: PrintDocumentBuilder.CalloutTone, title: String, body: MarkdownDocument)
    /// A standalone `![[image]]` embed.
    case image(url: String, alt: String)
    /// An embedded page, its body split the same way as the page's own.
    case page(caption: String?, body: [PrintBlock])
    /// An embed that prints as a labelled reference (a PDF, a video, a design).
    case reference(kind: String, name: String)
    /// A muted line in place of something that can't print ("Empty page", a missing embed).
    case notice(String)
}
