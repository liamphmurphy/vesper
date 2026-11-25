import Foundation

/// Pure HTML and print-segmentation logic for native `/print/knowledge/:id` and `/print/artifacts/:id`
/// screens. Produces self-contained, paper-first HTML documents with the four Knowledge print styles
/// (Clean, Editorial, Compact, Technical) and safe HTML escaping throughout.
public enum PrintHTMLBuilder {

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

    public static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

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

    // MARK: - Markdown AST -> HTML

    public static func renderMarkdownToHTML(_ markdown: String) -> String {
        let doc = MarkdownParser.parse(markdown)
        var html = doc.blocks.map(renderBlock).joined(separator: "\n")
        if !doc.footnotes.isEmpty {
            html += "\n<section class=\"print-footnotes\"><hr><ol>"
            for fn in doc.footnotes {
                html += "<li id=\"fn-\(fn.number)\">\(fn.blocks.map(renderBlock).joined(separator: "\n"))</li>"
            }
            html += "</ol></section>"
        }
        return html
    }

    private static func renderBlock(_ block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let inlines):
            return "<p>\(renderInlines(inlines))</p>"
        case .heading(let level, let inlines):
            let clamped = min(max(level, 1), 6)
            return "<h\(clamped)>\(renderInlines(inlines))</h\(clamped)>"
        case .blockquote(let blocks):
            return "<blockquote>\(blocks.map(renderBlock).joined(separator: "\n"))</blockquote>"
        case .list(let list):
            let tag = list.ordered ? "ol" : "ul"
            let startAttr = list.ordered && list.start != 1 ? " start=\"\(list.start)\"" : ""
            let items = list.items.map { item -> String in
                let inner = item.blocks.map(renderBlock).joined(separator: "\n")
                if let checked = item.checked {
                    let box = checked ? "&#9745;" : "&#9744;"
                    return "<li class=\"task-item\"><span class=\"task-box\">\(box)</span><div>\(inner)</div></li>"
                }
                return "<li>\(inner)</li>"
            }.joined(separator: "\n")
            return "<\(tag)\(startAttr)>\(items)</\(tag)>"
        case .code(let info, let code):
            let lang = info.split(separator: " ").first.map(String.init) ?? ""
            let cls = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
            return "<pre><code\(cls)>\(escapeHTML(code))</code></pre>"
        case .math(let tex):
            return "<pre class=\"print-math\"><code>\(escapeHTML(tex))</code></pre>"
        case .html(let raw):
            return "<pre><code>\(escapeHTML(raw))</code></pre>"
        case .thematicBreak:
            return "<hr>"
        case .table(let table):
            var out = "<table><thead><tr>"
            for (idx, cell) in table.header.enumerated() {
                out += "<th\(alignAttr(table.alignments, idx))>\(renderInlines(cell))</th>"
            }
            out += "</tr></thead><tbody>"
            for row in table.rows {
                out += "<tr>"
                for (idx, cell) in row.enumerated() {
                    out += "<td\(alignAttr(table.alignments, idx))>\(renderInlines(cell))</td>"
                }
                out += "</tr>"
            }
            out += "</tbody></table>"
            return out
        }
    }

    private static func alignAttr(_ alignments: [MarkdownAlignment?], _ index: Int) -> String {
        guard index < alignments.count, let align = alignments[index] else { return "" }
        return " style=\"text-align:\(align.rawValue)\""
    }

    private static func renderInlines(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let s):
                return escapeHTML(s)
            case .emphasis(let children):
                return "<em>\(renderInlines(children))</em>"
            case .strong(let children):
                return "<strong>\(renderInlines(children))</strong>"
            case .strikethrough(let children):
                return "<del>\(renderInlines(children))</del>"
            case .code(let s):
                return "<code>\(escapeHTML(s))</code>"
            case .math(let tex):
                return "<code class=\"print-math-inline\">\(escapeHTML(tex))</code>"
            case .link(let url, let title, let children):
                let inner = renderInlines(children)
                if url.hasPrefix("wikilink:") {
                    return "<span class=\"print-wikilink\">\(inner)</span>"
                }
                if url.hasPrefix("cite:") {
                    return "<sup class=\"print-cite\">\(inner)</sup>"
                }
                guard isSafeHref(url) else { return inner }
                let titleAttr = title.map { " title=\"\(escapeHTML($0))\"" } ?? ""
                return "<a href=\"\(escapeHTML(url))\"\(titleAttr)>\(inner)</a>"
            case .image(let url, let alt, let title):
                guard isSafeImageSrc(url) else { return escapeHTML(alt) }
                let titleAttr = title.map { " title=\"\(escapeHTML($0))\"" } ?? ""
                return "<img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(alt))\"\(titleAttr)>"
            case .lineBreak:
                return "<br>"
            case .html(let raw):
                return escapeHTML(raw)
            case .footnoteReference(let n):
                return "<sup><a href=\"#fn-\(n)\">[\(n)]</a></sup>"
            }
        }.joined()
    }

    private static func isSafeHref(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") || lower.hasPrefix("/") || lower.hasPrefix("#")
    }

    private static func isSafeImageSrc(_ url: String) -> Bool {
        let lower = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("/") || lower.hasPrefix("data:image/")
    }

    // MARK: - Complete Document Builders

    public static func visibleProperties(_ props: [String: JSONValue]) -> [(String, JSONValue)] {
        let hidden: Set<String> = ["query", "zettel_id", "aliases", "title"]
        return props
            .filter { !hidden.contains($0.key) && !$0.key.hasPrefix("_") }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    public static func buildKnowledgePrintHTML(
        page: KnowledgePage,
        style: KnowledgePrintStyle,
        showMetadata: Bool = false,
        savedQuery: KnowledgePageTable? = nil,
        darkScreen: Bool = false
    ) -> String {
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : page.title
        let crumbs = (page.path ?? title).split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let propRows = visibleProperties(page.properties)
        let segments = prepareKnowledgePrint(body: page.bodyMd ?? "", title: title, embeds: page.embeds)

        var headerHTML = "<header class=\"print-kn-header\">"
        if showMetadata && crumbs.count > 1 {
            headerHTML += "<p class=\"print-kn-folder\">\(escapeHTML(crumbs.dropLast().joined(separator: " / ")))</p>"
        }
        headerHTML += "<h1 class=\"print-kn-title\">\(escapeHTML(title))</h1>"
        if showMetadata && !propRows.isEmpty {
            headerHTML += "<dl class=\"print-kn-props\">"
            for (key, value) in propRows {
                headerHTML += "<div class=\"print-kn-prop-row\"><dt class=\"print-kn-prop-key\">\(escapeHTML(key))</dt><dd class=\"print-kn-prop-val\">"
                if key == "tags", case .array(let tags) = value {
                    headerHTML += "<span class=\"print-kn-tags\">"
                    for tag in tags {
                        let s = formatPropertyValue(tag)
                        if !s.isEmpty {
                            headerHTML += "<span class=\"print-kn-tag\">#\(escapeHTML(s))</span>"
                        }
                    }
                    headerHTML += "</span>"
                } else {
                    let formatted = formatPropertyValue(value)
                    headerHTML += escapeHTML(formatted.isEmpty ? "—" : formatted)
                }
                headerHTML += "</dd></div>"
            }
            headerHTML += "</dl>"
        }
        headerHTML += "</header>"

        var queryHTML = ""
        if let savedQuery, !savedQuery.rows.isEmpty {
            queryHTML = renderQueryTable(savedQuery)
        }

        let bodyHTML = "<div class=\"print-kn-body\">\(renderSegments(segments))</div>"
        let themeAttr = darkScreen ? "dark" : "light"

        return """
        <!doctype html>
        <html lang="en" data-theme="\(themeAttr)">
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <style>\(knowledgePrintCSS)</style>
        </head>
        <body>
        <article class="print-doc print-knowledge" data-print-style="\(style.rawValue)">
        \(headerHTML)
        \(queryHTML)
        \(bodyHTML)
        </article>
        </body>
        </html>
        """
    }

    public static func buildArtifactPrintHTML(
        title: String,
        versionLabel: String,
        authorName: String,
        createdAt: String,
        summary: String,
        bodyMarkdown: String,
        darkScreen: Bool = false
    ) -> String {
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        let stripped = stripDuplicateLeadingHeading(bodyMarkdown, title: displayTitle)
        let ownTitle = stripped != bodyMarkdown
        let metaLine = [versionLabel, authorName, createdAt].filter { !$0.isEmpty }.joined(separator: " · ")

        var headerHTML = "<header class=\"print-kn-header\">"
        if !ownTitle {
            headerHTML += "<h1 class=\"print-kn-title\">\(escapeHTML(displayTitle))</h1>"
        }
        if !metaLine.isEmpty {
            headerHTML += "<p class=\"print-artifact-meta\">\(escapeHTML(metaLine))</p>"
        }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            headerHTML += "<p class=\"print-artifact-summary\">\(escapeHTML(trimmedSummary))</p>"
        }
        headerHTML += "</header>"

        let proseHTML = "<div class=\"print-kn-body\"><div class=\"print-kn-prose\">\(renderMarkdownToHTML(bodyMarkdown))</div></div>"
        let themeAttr = darkScreen ? "dark" : "light"

        return """
        <!doctype html>
        <html lang="en" data-theme="\(themeAttr)">
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(displayTitle))</title>
        <style>\(knowledgePrintCSS)</style>
        </head>
        <body>
        <article class="print-doc print-knowledge" data-print-style="clean">
        \(headerHTML)
        \(proseHTML)
        </article>
        </body>
        </html>
        """
    }

    // MARK: - Private Segment / Table Renderers

    private static func renderSegments(_ segments: [PrintSegment]) -> String {
        segments.map { seg -> String in
            switch seg {
            case .markdown(let content):
                return "<div class=\"print-kn-prose\">\(renderMarkdownToHTML(content))</div>"
            case .callout(_, let tone, let title, let body):
                let bodyPart = body.isEmpty
                    ? ""
                    : "<div class=\"print-callout-body print-kn-prose\">\(renderMarkdownToHTML(body))</div>"
                return "<aside class=\"print-callout\" data-callout=\"\(tone.rawValue)\"><p class=\"print-callout-title\">\(escapeHTML(title))</p>\(bodyPart)</aside>"
            case .embed(_, let fallbackLabel, let embed):
                return renderEmbed(embed: embed, fallbackLabel: fallbackLabel)
            }
        }.joined(separator: "\n")
    }

    private static func renderEmbed(embed: KnowledgeEmbed?, fallbackLabel: String) -> String {
        guard let e = embed, e.available else {
            return "<p class=\"print-embed-missing\">Embedded reference unavailable: \(escapeHTML(fallbackLabel))</p>"
        }
        if let url = e.url, !url.isEmpty, (e.kind == "image" || (e.contentType?.hasPrefix("image/") ?? false)), isSafeImageSrc(url) {
            let alt = e.title ?? fallbackLabel
            return "<figure class=\"print-embed-image\"><img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(alt))\"></figure>"
        }
        if e.kind == "page", let markdown = e.markdown {
            let nested = prepareKnowledgePrint(body: markdown, title: e.title ?? "", embeds: [], stripTitle: true)
            let caption = e.title.map { "<figcaption class=\"print-embed-caption\">\(escapeHTML($0))</figcaption>" } ?? ""
            let inner = nested.isEmpty ? "<p class=\"print-embed-missing\">Empty page</p>" : renderSegments(nested)
            return "<figure class=\"print-embed-page\">\(caption)<div class=\"print-embed-body\">\(inner)</div></figure>"
        }
        let kindLabel: String
        if let ct = e.contentType?.lowercased(), ct == "application/pdf" || ct.hasSuffix("+pdf") {
            kindLabel = "PDF"
        } else if e.kind == "video" || (e.contentType?.hasPrefix("video/") ?? false) {
            kindLabel = "Video"
        } else if e.contentType?.hasPrefix("audio/") ?? false {
            kindLabel = "Audio"
        } else if e.kind == "design" {
            kindLabel = "Design"
        } else {
            kindLabel = "Attachment"
        }
        return "<figure class=\"print-embed-ref\"><span class=\"print-embed-kind\">\(kindLabel)</span><span class=\"print-embed-name\">\(escapeHTML(e.title ?? fallbackLabel))</span></figure>"
    }

    private static func renderQueryTable(_ table: KnowledgePageTable) -> String {
        let excluded: Set<String> = ["tags", "aliases", "query", "zettel_id", "title"]
        var counts: [String: Int] = [:]
        for row in table.rows {
            for key in row.properties.keys where !excluded.contains(key) {
                counts[key, default: 0] += 1
            }
        }
        let cols = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4).map(\.key)
        var html = "<div class=\"print-kn-query-wrap\"><table class=\"print-kn-query\"><thead><tr><th>Name</th>"
        for col in cols { html += "<th>\(escapeHTML(col))</th>" }
        html += "<th>Tags</th><th>Audience</th></tr></thead><tbody>"
        for row in table.rows {
            html += "<tr><td class=\"print-kn-query-title\">\(escapeHTML(row.title))</td>"
            for col in cols {
                let val = row.properties[col].map(formatPropertyValue) ?? ""
                html += "<td>\(escapeHTML(val.isEmpty ? "—" : val))</td>"
            }
            let tagsText: String
            if case .array(let arr) = row.properties["tags"] {
                tagsText = arr.prefix(3).map(formatPropertyValue).filter { !$0.isEmpty }.map { "#\($0)" }.joined(separator: " ")
            } else {
                tagsText = ""
            }
            let audienceLabel: String = switch row.audience {
            case .private: "Private"
            case .shared: "Shared"
            case .agent: "Agent"
            }
            html += "<td>\(escapeHTML(tagsText))</td><td>\(audienceLabel)</td></tr>"
        }
        html += "</tbody></table>"
        if table.hasMore {
            html += "<p class=\"print-kn-query-more\">Showing the first \(table.rows.count) pages.</p>"
        }
        html += "</div>"
        return html
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

    // MARK: - Paper-First Print CSS

    private static let knowledgePrintCSS = """
    *, *::before, *::after { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; min-height: 100%; }
    :root[data-theme="dark"] {
      background: #141418;
      color: #f4f4f5;
      color-scheme: dark;
    }
    :root[data-theme="light"] {
      background: #f4f4f6;
      color: #18181b;
      color-scheme: light;
    }
    .print-knowledge {
      --kn-paper: #1c1c22;
      --kn-ink: #f4f4f5;
      --kn-ink-2: #d4d4d8;
      --kn-muted: #a1a1aa;
      --kn-border: #2e2e36;
      --kn-surface: #23232b;
      --kn-surface-subtle: #1f1f26;
      --kn-badge-bg: #27272f;
      --kn-accent: #60a5fa;
      --kn-callout-note-bg: #1e2433;
      --kn-callout-tip-bg: #192924;
      --kn-callout-tip-border: #34d399;
      --kn-callout-warning-bg: #2b2419;
      --kn-callout-warning-border: #f59e0b;
      --kn-callout-danger-bg: #2d1c1e;
      --kn-callout-danger-border: #f87171;
      --kn-font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", Inter, system-ui, sans-serif;
      --kn-font-serif: Georgia, "Iowan Old Style", "New York", serif;
      --kn-font-mono: ui-monospace, "SF Mono", Menlo, monospace;
      font-family: var(--kn-font-sans);
      font-size: 15px;
      line-height: 1.68;
      color: var(--kn-ink-2);
      background: var(--kn-paper);
      max-width: 780px;
      margin: 28px auto;
      padding: 44px 48px;
      border-radius: 6px;
      border: 1px solid var(--kn-border);
      box-shadow: 0 2px 8px rgba(0,0,0,0.08), 0 12px 32px rgba(0,0,0,0.16);
      display: flex;
      flex-direction: column;
      gap: 20px;
    }
    :root[data-theme="light"] .print-knowledge {
      --kn-paper: #ffffff;
      --kn-ink: #18181b;
      --kn-ink-2: #27272a;
      --kn-muted: #52525b;
      --kn-border: #e4e4e7;
      --kn-surface: #f4f4f5;
      --kn-surface-subtle: #fafafa;
      --kn-badge-bg: #f4f4f5;
      --kn-accent: #2563eb;
      --kn-callout-note-bg: #eff6ff;
      --kn-callout-tip-bg: #ecfdf5;
      --kn-callout-tip-border: #059669;
      --kn-callout-warning-bg: #fffbeb;
      --kn-callout-warning-border: #b45309;
      --kn-callout-danger-bg: #fef2f2;
      --kn-callout-danger-border: #b91c1c;
    }
    .print-kn-header { display: flex; flex-direction: column; gap: 10px; padding-bottom: 16px; border-bottom: 1px solid var(--kn-border); }
    .print-kn-folder { margin: 0; font-size: 11px; font-weight: 600; letter-spacing: 0.04em; text-transform: uppercase; color: var(--kn-muted); }
    .print-kn-title { margin: 0; font-size: 28px; font-weight: 700; line-height: 1.2; letter-spacing: -0.02em; color: var(--kn-ink); }
    .print-artifact-meta { margin: 0; font-family: var(--kn-font-mono); font-size: 12px; color: var(--kn-muted); }
    .print-artifact-summary { margin: 0; font-size: 14px; line-height: 1.6; color: var(--kn-ink-2); }
    .print-kn-props { display: flex; flex-direction: column; gap: 4px; margin: 4px 0 0; padding-top: 10px; border-top: 1px solid var(--kn-border); }
    .print-kn-prop-row { display: grid; grid-template-columns: 140px 1fr; gap: 12px; align-items: baseline; font-size: 12.5px; line-height: 1.5; }
    .print-kn-prop-key { color: var(--kn-muted); font-weight: 500; }
    .print-kn-prop-val { margin: 0; color: var(--kn-ink-2); }
    .print-kn-tags { display: inline-flex; flex-wrap: wrap; gap: 5px; }
    .print-kn-tag { display: inline-flex; padding: 1px 7px; border-radius: 999px; background: var(--kn-surface); font-size: 11px; font-weight: 500; color: var(--kn-ink-2); }
    .print-kn-body { display: flex; flex-direction: column; gap: 14px; }
    .print-kn-prose { display: flex; flex-direction: column; gap: 10px; color: var(--kn-ink-2); }
    .print-kn-prose > :first-child { margin-top: 0; }
    .print-kn-prose p { margin: 0; }
    .print-kn-prose h1, .print-kn-prose h2 { margin: 1.15em 0 0.15em; font-size: 1.38em; font-weight: 650; line-height: 1.3; letter-spacing: -0.015em; color: var(--kn-ink); }
    .print-kn-prose h3 { margin: 1.05em 0 0.15em; font-size: 1.18em; font-weight: 650; line-height: 1.32; color: var(--kn-ink); }
    .print-kn-prose h4 { margin: 0.85em 0 0.1em; font-size: 1.04em; font-weight: 600; color: var(--kn-ink); }
    .print-kn-prose h5, .print-kn-prose h6 { margin: 0.7em 0 0.05em; font-size: 0.96em; font-weight: 600; color: var(--kn-ink); }
    .print-kn-prose ul, .print-kn-prose ol { margin: 0; padding-left: 1.4em; display: flex; flex-direction: column; gap: 4px; }
    .print-kn-prose li.task-item { list-style: none; margin-left: -1.4em; display: flex; gap: 8px; align-items: flex-start; }
    .print-kn-prose .task-box { font-size: 1.05em; line-height: 1.4; color: var(--kn-muted); }
    .print-kn-prose blockquote { margin: 0; border-left: 2.5px solid var(--kn-border); padding: 2px 0 2px 14px; color: var(--kn-muted); }
    .print-kn-prose code { font-family: var(--kn-font-mono); font-size: 0.86em; padding: 1px 4px; border-radius: 4px; background: var(--kn-surface); border: 1px solid var(--kn-border); color: var(--kn-ink); }
    .print-kn-prose pre { margin: 0; font-family: var(--kn-font-mono); font-size: 0.84em; line-height: 1.55; padding: 11px 13px; border-radius: 6px; background: var(--kn-surface); border: 1px solid var(--kn-border); color: var(--kn-ink); overflow-x: auto; }
    .print-kn-prose pre code { padding: 0; border: 0; background: transparent; }
    .print-kn-prose hr { border: 0; border-top: 1px solid var(--kn-border); margin: 8px 0; }
    .print-kn-prose a { color: var(--kn-accent); text-decoration: underline; }
    .print-kn-prose img { max-width: 100%; border-radius: 6px; }
    .print-kn-prose table, .print-kn-query { width: 100%; border-collapse: collapse; font-size: 0.9em; line-height: 1.45; text-align: left; }
    .print-kn-prose th, .print-kn-prose td, .print-kn-query th, .print-kn-query td { padding: 7px 10px; border-bottom: 1px solid var(--kn-border); vertical-align: top; }
    .print-kn-prose th, .print-kn-query th { background: var(--kn-surface); font-weight: 600; color: var(--kn-ink); }
    .print-kn-query-wrap { border: 1px solid var(--kn-border); border-radius: 8px; overflow: hidden; }
    .print-kn-query-title { font-weight: 600; color: var(--kn-ink); }
    .print-kn-query-more { margin: 0; padding: 6px 10px; font-size: 11.5px; color: var(--kn-muted); border-top: 1px solid var(--kn-border); background: var(--kn-surface); }
    .print-wikilink { font-weight: 500; color: var(--kn-ink); text-decoration: underline; text-underline-offset: 2px; }
    .print-callout { padding: 11px 14px; border-radius: 8px; border: 1px solid var(--kn-border); border-left: 3px solid var(--kn-accent); background: var(--kn-callout-note-bg); }
    .print-callout[data-callout="tip"] { border-left-color: var(--kn-callout-tip-border); background: var(--kn-callout-tip-bg); }
    .print-callout[data-callout="warning"] { border-left-color: var(--kn-callout-warning-border); background: var(--kn-callout-warning-bg); }
    .print-callout[data-callout="danger"] { border-left-color: var(--kn-callout-danger-border); background: var(--kn-callout-danger-bg); }
    .print-callout[data-callout="quote"] { border-left-color: var(--kn-muted); background: var(--kn-surface); }
    .print-callout-title { margin: 0; font-size: 0.92em; font-weight: 650; color: var(--kn-ink); }
    .print-callout-body { margin-top: 6px; }
    .print-embed-image { margin: 4px 0; }
    .print-embed-image img { max-width: 100%; max-height: 460px; border-radius: 6px; object-fit: contain; }
    .print-embed-page { margin: 4px 0; padding: 12px 16px; border-left: 3px solid var(--kn-border); background: var(--kn-surface-subtle); border-radius: 0 8px 8px 0; }
    .print-embed-caption { margin-bottom: 8px; font-size: 12px; font-weight: 600; color: var(--kn-muted); }
    .print-embed-body { display: flex; flex-direction: column; gap: 10px; }
    .print-embed-ref { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border: 1px solid var(--kn-border); border-radius: 6px; background: var(--kn-surface); font-size: 12.5px; margin: 0; }
    .print-embed-kind { font-family: var(--kn-font-mono); font-size: 10.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; padding: 1px 6px; border-radius: 4px; background: var(--kn-badge-bg); border: 1px solid var(--kn-border); color: var(--kn-muted); }
    .print-embed-name { font-weight: 500; color: var(--kn-ink); }
    .print-embed-missing { margin: 0; font-size: 12.5px; font-style: italic; color: var(--kn-muted); }

    /* Editorial */
    .print-knowledge[data-print-style="editorial"] { font-family: var(--kn-font-serif); font-size: 16px; line-height: 1.78; --kn-accent: #fb923c; }
    :root[data-theme="light"] .print-knowledge[data-print-style="editorial"] { --kn-ink: #1c1917; --kn-ink-2: #292524; --kn-muted: #57534e; --kn-border: #d6d3d1; --kn-surface: #f5f5f4; --kn-accent: #9a3412; }
    .print-knowledge[data-print-style="editorial"] .print-kn-header { padding-bottom: 18px; border-bottom: 1.5px solid var(--kn-ink); }
    .print-knowledge[data-print-style="editorial"] .print-kn-title { font-family: var(--kn-font-serif); font-size: 31px; }
    .print-knowledge[data-print-style="editorial"] .print-kn-folder,
    .print-knowledge[data-print-style="editorial"] .print-kn-prop-key,
    .print-knowledge[data-print-style="editorial"] .print-kn-tag,
    .print-knowledge[data-print-style="editorial"] .print-kn-query th { font-family: var(--kn-font-sans); }
    .print-knowledge[data-print-style="editorial"] .print-kn-prose blockquote { font-style: italic; }

    /* Compact */
    .print-knowledge[data-print-style="compact"] { font-size: 13px; line-height: 1.48; gap: 12px; }
    .print-knowledge[data-print-style="compact"] .print-kn-header { gap: 6px; padding-bottom: 10px; }
    .print-knowledge[data-print-style="compact"] .print-kn-title { font-size: 22px; }
    .print-knowledge[data-print-style="compact"] .print-kn-props { flex-direction: row; flex-wrap: wrap; gap: 6px 16px; padding-top: 8px; }
    .print-knowledge[data-print-style="compact"] .print-kn-prop-row { display: inline-flex; gap: 6px; font-size: 11.5px; }
    .print-knowledge[data-print-style="compact"] .print-kn-body, .print-knowledge[data-print-style="compact"] .print-kn-prose { gap: 8px; }
    .print-knowledge[data-print-style="compact"] th, .print-knowledge[data-print-style="compact"] td { padding: 4px 8px; }
    .print-knowledge[data-print-style="compact"] .print-callout { padding: 8px 11px; }

    /* Technical */
    .print-knowledge[data-print-style="technical"] { font-size: 14px; line-height: 1.58; --kn-accent: #2dd4bf; }
    :root[data-theme="light"] .print-knowledge[data-print-style="technical"] { --kn-border: #d4d4d8; --kn-surface: #f4f4f5; --kn-surface-subtle: #fafafa; --kn-accent: #0f766e; }
    .print-knowledge[data-print-style="technical"] .print-kn-header { padding: 14px 16px; border: 1px solid var(--kn-border); border-left: 3.5px solid var(--kn-accent); border-radius: 6px; background: var(--kn-surface-subtle); }
    .print-knowledge[data-print-style="technical"] .print-kn-folder,
    .print-knowledge[data-print-style="technical"] .print-kn-prop-key,
    .print-knowledge[data-print-style="technical"] .print-kn-tag,
    .print-knowledge[data-print-style="technical"] .print-callout-title { font-family: var(--kn-font-mono); }
    .print-knowledge[data-print-style="technical"] .print-kn-props { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 5px 18px; }
    .print-knowledge[data-print-style="technical"] .print-kn-prose h1,
    .print-knowledge[data-print-style="technical"] .print-kn-prose h2,
    .print-knowledge[data-print-style="technical"] .print-kn-prose h3 { padding-bottom: 4px; border-bottom: 1px solid var(--kn-border); }
    .print-knowledge[data-print-style="technical"] th, .print-knowledge[data-print-style="technical"] td { border: 1px solid var(--kn-border); }

    @media print {
      @page { margin: 16mm 14mm; }
      html, body { background: #ffffff !important; color: #18181b !important; color-scheme: light !important; }
      .print-knowledge {
        margin: 0 !important; padding: 0 !important; max-width: none !important;
        border: 0 !important; border-radius: 0 !important; box-shadow: none !important;
        background: transparent !important;
        print-color-adjust: exact; -webkit-print-color-adjust: exact;
        --kn-paper: transparent; --kn-ink: #18181b; --kn-ink-2: #27272a; --kn-muted: #52525b;
        --kn-border: #d4d4d8; --kn-surface: #f4f4f5; --kn-surface-subtle: #fafafa;
        --kn-badge-bg: #f4f4f5; --kn-accent: #2563eb;
        --kn-callout-note-bg: #eff6ff; --kn-callout-tip-bg: #ecfdf5; --kn-callout-tip-border: #059669;
        --kn-callout-warning-bg: #fffbeb; --kn-callout-warning-border: #b45309;
        --kn-callout-danger-bg: #fef2f2; --kn-callout-danger-border: #b91c1c;
      }
      .print-knowledge[data-print-style="editorial"] { --kn-ink: #1c1917; --kn-ink-2: #292524; --kn-muted: #57534e; --kn-border: #d6d3d1; --kn-surface: #f5f5f4; --kn-accent: #9a3412; }
      .print-knowledge[data-print-style="technical"] { --kn-accent: #0f766e; }
      h1, h2, h3, h4, h5, h6 { break-after: avoid; break-inside: avoid; }
      figure, img, svg, blockquote, .print-callout, .print-embed-ref, .print-kn-header, .print-kn-props, tr { break-inside: avoid; }
      thead { display: table-header-group; }
      pre { overflow: visible; white-space: pre-wrap; overflow-wrap: anywhere; }
      img { max-height: 240mm; }
      a { color: inherit; text-decoration: underline; }
    }
    """
}
