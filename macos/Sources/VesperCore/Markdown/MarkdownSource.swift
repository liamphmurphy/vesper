import Foundation

/// The text rewrites the web runs before parsing markdown, ported line for line so links come out
/// the same: `[[wiki links]]` (web/lib/wikilinks.ts), bare ticket keys (lib/ticket-keys.ts) and
/// citation markers (lib/chat-sources.ts) in chat, plus `$$` math marked for the parser (cmark has
/// no math syntax; the web uses remark-math).
public enum MarkdownSource {
    public static let wikiLinkScheme = "wikilink:"
    public static let citeScheme = "cite:"

    /// The source as the web's Markdown component sees it (ChatMarkdown's rewrites first in chat).
    public static func prepare(_ markdown: String, chat: Bool = false, citations: [Int] = []) -> String {
        var md = markdown
        if chat { md = linkCitations(linkTicketKeys(md), numbers: citations) }
        return markMath(linkify(md))
    }

    // MARK: Lines outside code

    private static let fence = regex("^ {0,3}(```|~~~)")
    private static let codeSpan = regex("`+[^`\\n]*`+")

    /// Maps each line outside fenced code; fence lines and the code between them stay as written.
    private static func mapLinesOutsideFences(_ md: String, _ transform: (String) -> String) -> String {
        var open = ""
        return md.components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            if let f = fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let marker = ns.substring(with: f.range(at: 1))
                if open.isEmpty { open = marker } else if open == marker { open = "" }
                return line
            }
            return open.isEmpty ? transform(line) : line
        }.joined(separator: "\n")
    }

    /// lib/wikilinks.ts `eachLine`: `scan` is the line with code spans blanked, so matches in it are
    /// at the same UTF-16 offsets as in `line`.
    private static func eachLine(_ md: String, _ transform: (_ line: NSString, _ scan: NSString) -> String?) -> String {
        mapLinesOutsideFences(md) { line in
            let ns = line as NSString
            let scan = NSMutableString(string: line)
            for m in codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                scan.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
            }
            return transform(ns, scan) ?? line
        }
    }

    /// Rewrites the parts of each line outside fenced code that `skip` doesn't match (JavaScript's
    /// `line.split(/(skip)/)` with every other part rewritten).
    private static func eachUnskippedPart(_ md: String, skip: NSRegularExpression, _ transform: (String) -> String) -> String {
        mapLinesOutsideFences(md) { line in
            let ns = line as NSString
            var out = ""
            var last = 0
            for m in skip.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                out += transform(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
                out += ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            return out + transform(ns.substring(from: last))
        }
    }

    // MARK: Wiki links (web/lib/wikilinks.ts)

    /// One `[[target#anchor|display]]`, as `parseWikiLinks` returns it.
    public struct WikiRef: Sendable, Equatable {
        /// Inside the brackets, as sent to GET /knowledge/resolve.
        public var ref: String
        public var target: String
        public var anchor: String
        public var display: String
        public var embed: Bool
    }

    private static let wikiLink = regex("(!?)\\[\\[([^\\[\\]\\n]+?)\\]\\]")

    private static func split(_ inner: String) -> (target: String, anchor: String, display: String) {
        var inner = inner.replacingOccurrences(of: "\\|", with: "|")
        var display = ""
        var anchor = ""
        if let bar = inner.firstIndex(of: "|") {
            display = String(inner[inner.index(after: bar)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            inner = String(inner[..<bar])
        }
        if let hash = inner.firstIndex(of: "#") {
            anchor = String(inner[inner.index(after: hash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            inner = String(inner[..<hash])
        }
        return (inner.trimmingCharacters(in: .whitespacesAndNewlines), anchor, display)
    }

    /// Every `[[link]]` outside code, in order.
    public static func wikiRefs(_ md: String) -> [WikiRef] {
        var out: [WikiRef] = []
        _ = eachLine(md) { line, scan in
            for m in wikiLink.matches(in: scan as String, range: NSRange(location: 0, length: scan.length)) {
                let raw = line.substring(with: m.range) as NSString
                let bang = m.range(at: 1).length
                let inner = raw.substring(with: NSRange(location: bang + 2, length: raw.length - bang - 4))
                let s = split(inner)
                if s.target.isEmpty && s.anchor.isEmpty { continue }
                out.append(WikiRef(ref: inner.replacingOccurrences(of: "\\|", with: "|"), target: s.target, anchor: s.anchor, display: s.display, embed: bang > 0))
            }
            return nil
        }
        return out
    }

    /// Text shown for a link with no "|display" (`defaultLabel`).
    public static func defaultLabel(target: String, anchor: String, display: String) -> String {
        if !display.isEmpty { return display }
        if target.isEmpty { return anchor }
        let title = target.components(separatedBy: "/").last ?? target
        return anchor.isEmpty ? title : "\(title) › \(anchor)"
    }

    private static func escapeText(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\[]*_`".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Rewrites `[[links]]` into markdown links with a `wikilink:` URL (`linkify`).
    public static func linkify(_ md: String) -> String {
        eachLine(md) { line, scan in
            var out = ""
            var last = 0
            for m in wikiLink.matches(in: scan as String, range: NSRange(location: 0, length: scan.length)) {
                let raw = line.substring(with: m.range) as NSString
                let bang = m.range(at: 1).length
                let inner = raw.substring(with: NSRange(location: bang + 2, length: raw.length - bang - 4))
                let s = split(inner)
                if s.target.isEmpty && s.anchor.isEmpty { continue }
                let label = escapeText(defaultLabel(target: s.target, anchor: s.anchor, display: s.display))
                out += line.substring(with: NSRange(location: last, length: m.range.location - last))
                out += "[\(label)](\(wikiLinkScheme)\(encodeURIComponent(inner.replacingOccurrences(of: "\\|", with: "|"))))"
                last = m.range.location + m.range.length
            }
            return last > 0 ? out + line.substring(from: last) : nil
        }
    }

    /// JavaScript's encodeURIComponent: everything but A–Z a–z 0–9 - _ . ! ~ * ' ( ) as UTF-8 %XX.
    public static func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? s
    }

    private static let uriComponentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    // MARK: Chat rewrites (web/lib/ticket-keys.ts, web/lib/chat-sources.ts)

    // JavaScript's \b is ASCII-only, so the boundaries are spelled out (ICU's \b knows Unicode letters).
    private static let ticketKey = regex("(?<![A-Za-z0-9_])([A-Z][A-Z0-9]+-[0-9]+)(?![A-Za-z0-9_])")
    private static let ticketSkip = regex("(`+[^`\\n]*`+|!?\\[\\[[^\\[\\]\\n]+?\\]\\])")

    /// Wraps bare ticket keys (LAZYAGENTS-12) in `[[…]]` so they link like wiki links.
    public static func linkTicketKeys(_ md: String) -> String {
        eachUnskippedPart(md, skip: ticketSkip) { part in
            ticketKey.stringByReplacingMatches(in: part, range: NSRange(location: 0, length: (part as NSString).length), withTemplate: "[[$1]]")
        }
    }

    private static let citeSkip = regex("(`+[^`\\n]*`+)")
    private static let cite = regex("(?<![\\[\\\\!])\\[([0-9]{1,2})\\](?![(:])")

    /// Turns `[n]` into a `cite:n` link for the numbers the reply's Sources list defines.
    public static func linkCitations(_ md: String, numbers: [Int]) -> String {
        if numbers.isEmpty { return md }
        let known = Set(numbers)
        return eachUnskippedPart(md, skip: citeSkip) { part in
            let ns = part as NSString
            var out = ""
            var last = 0
            for m in cite.matches(in: part, range: NSRange(location: 0, length: ns.length)) {
                let digits = ns.substring(with: m.range(at: 1))
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                out += known.contains(Int(digits) ?? -1) ? "[\(digits)](\(citeScheme)\(digits))" : ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            return out + ns.substring(from: last)
        }
    }

    // MARK: Math

    /// Marks math the parser turns back into math nodes: a code fence with this info, or a code
    /// span wrapped in it. A private-use character can't come from what anyone types.
    static let mathMarker = "\u{E000}"
    private static let mathOpen = regex("^ {0,3}(\\${2,})[^$]*$")
    private static let inlineMath = regex("(?<!\\$)(\\${2,})(?!\\$)(.+?)(?<!\\$)\\1(?!\\$)")
    private static let backtickRun = regex("`+")

    /// `$$` blocks become fences and `$$x$$` spans become code spans, both marked (remark-math with
    /// `singleDollarTextMath: false`). Only top-level blocks: math inside a list or quote stays text.
    static func markMath(_ md: String) -> String {
        guard md.contains("$$") else { return md }
        var out: [String] = []
        var codeFence = ""
        var math: (fence: String, lines: [String])?
        for line in md.components(separatedBy: "\n") {
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)
            if var open = math {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(open.fence),
                   line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "$" }) {
                    out += mathFence(open.lines)
                    math = nil
                } else {
                    open.lines.append(line)
                    math = open
                }
                continue
            }
            if let f = fence.firstMatch(in: line, range: whole) {
                let marker = ns.substring(with: f.range(at: 1))
                if codeFence.isEmpty { codeFence = marker } else if codeFence == marker { codeFence = "" }
                out.append(line)
                continue
            }
            if !codeFence.isEmpty { out.append(line); continue }
            if let m = mathOpen.firstMatch(in: line, range: whole) {
                math = (ns.substring(with: m.range(at: 1)), [])
                continue
            }
            out.append(markInlineMath(line))
        }
        // An unclosed block runs to the end, as an unclosed fence does.
        if let open = math { out += mathFence(open.lines) }
        return out.joined(separator: "\n")
    }

    private static func mathFence(_ lines: [String]) -> [String] {
        let body = lines.joined(separator: "\n")
        let longest = backtickRun.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)).map(\.range.length).max() ?? 0
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return [ticks + mathMarker + "math"] + lines + [ticks]
    }

    private static func markInlineMath(_ line: String) -> String {
        guard line.contains("$$") else { return line }
        let ns = line as NSString
        var out = ""
        var last = 0
        // Code spans first, so dollars inside them stay code.
        let spans = codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length)).map(\.range)
        for m in inlineMath.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            if spans.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            var tex = ns.substring(with: m.range(at: 2))
            if tex.count > 1, tex.hasPrefix(" "), tex.hasSuffix(" "), tex.contains(where: { $0 != " " }) {
                tex = String(tex.dropFirst().dropLast())
            }
            let longest = backtickRun.matches(in: tex, range: NSRange(location: 0, length: (tex as NSString).length)).map(\.range.length).max() ?? 0
            let ticks = String(repeating: "`", count: longest + 1)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ticks + mathMarker + tex + mathMarker + ticks
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    // MARK: Code fences (web/lib/code-diff.ts)

    private static let languageByFence: [String: String] = [
        "ts": "typescript", "typescript": "typescript", "tsx": "tsx", "js": "javascript", "javascript": "javascript", "jsx": "jsx", "json": "json",
        "go": "go", "golang": "go", "py": "python", "python": "python", "rb": "ruby", "ruby": "ruby", "rs": "rust", "rust": "rust", "java": "java",
        "kt": "kotlin", "kotlin": "kotlin", "swift": "swift", "c": "c", "cpp": "cpp", "c++": "cpp", "cs": "csharp", "csharp": "csharp", "php": "php",
        "sh": "shellscript", "bash": "shellscript", "shell": "shellscript", "zsh": "shellscript", "yaml": "yaml", "yml": "yaml", "toml": "toml",
        "md": "markdown", "markdown": "markdown", "html": "html", "css": "css", "scss": "scss", "sql": "sql", "dockerfile": "docker", "make": "make", "makefile": "make",
    ]

    /// Shiki's language for a fence's info string ("```ts"), or nil (plain text): `langFromFence`.
    public static func language(fromFence info: String) -> String? {
        let word = info.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        return languageByFence[word]
    }

    /// The label a chat code block's header shows: the info's first word, or "text".
    public static func fenceLabel(_ info: String) -> String {
        info.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "text"
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals above; a typo is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern)
    }
}
