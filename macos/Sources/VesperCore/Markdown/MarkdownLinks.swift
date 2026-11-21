import Foundation

/// What a link in rendered markdown does when clicked, decoded from the URL the renderer put on it.
public enum MarkdownLinkTarget: Sendable, Equatable {
    /// An in-app path ("/tickets/PAY-1"), including resolved wiki links.
    case path(String)
    /// An http(s) or mailto link.
    case external(URL)
    /// "#section": a heading in the same document.
    case anchor(String)
    /// A wiki link that resolves to nothing yet; clicking creates the page (the web's ghost link).
    case ghost(target: String)
    /// A citation marker; the screen showing the reply brings that source into view.
    case citation(Int)
    /// A footnote reference, or the ↩ back from footnote n to its first reference.
    case footnote(Int)
    case footnoteReference(Int)
    /// A chat code block's Copy and Show more/less.
    case copyCode(Int)
    case toggleCode(Int)

    /// The scheme of the renderer's own controls (copy, expand, footnotes).
    static let actionScheme = "vesper-markdown"

    public init?(url: URL) {
        let string = url.absoluteString
        if string.hasPrefix("/") && !string.hasPrefix("//") {
            self = .path(string)
            return
        }
        if string.hasPrefix("#") {
            self = .anchor(String(string.dropFirst()).removingPercentEncoding ?? String(string.dropFirst()))
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            self = .external(url)
        case "cite":
            guard let n = Int(string.dropFirst(MarkdownSource.citeScheme.count)) else { return nil }
            self = .citation(n)
        case "wikilink":
            let ref = String(string.dropFirst(MarkdownSource.wikiLinkScheme.count)).removingPercentEncoding ?? ""
            let target = MarkdownSource.wikiRefs("[[\(ref)]]").first?.target ?? ref
            self = .ghost(target: target)
        case Self.actionScheme:
            let parts = string.dropFirst(Self.actionScheme.count + 1).split(separator: "/")
            guard parts.count == 2, let n = Int(parts[1]) else { return nil }
            switch parts[0] {
            case "copy": self = .copyCode(n)
            case "toggle": self = .toggleCode(n)
            case "footnote": self = .footnote(n)
            case "fnref": self = .footnoteReference(n)
            default: return nil
            }
        default:
            return nil
        }
    }

    static func action(_ name: String, _ n: Int) -> URL {
        URL(string: "\(actionScheme):\(name)/\(n)")!
    }
}

/// What a `[[link]]` resolved to (GET /knowledge/resolve), as the web's WikiLink renders it.
public enum MarkdownLinkState: Sendable, Equatable {
    /// A page, ticket, epic…: links to `href`; `title` is the tooltip ("Ticket · PAY-1 · Title").
    case resolved(href: String, title: String)
    /// Nothing by that name: a ghost link that creates the page.
    case unresolved
}

extension MarkdownLinkState {
    /// The state for a resolved target, as `WikiLink` picks between a link and a ghost.
    public init(_ target: API.LinkTarget) {
        guard target.kind != .unresolved, let href = target.href, !href.isEmpty else {
            self = .unresolved
            return
        }
        self = .resolved(href: href, title: [Self.kindLabel(target), target.displayId ?? "", target.title].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// wikilink.tsx `kindLabel`.
    static func kindLabel(_ t: API.LinkTarget) -> String {
        switch t.kind {
        case .artifact, .section: return t.artifactType?.rawValue == "note" ? "Page" : (t.artifactType?.rawValue ?? "").uppercased()
        case .ticket: return "Ticket"
        case .agent: return "Agent"
        case .epic: return "Epic"
        default: return ""
        }
    }
}

/// Heading ids as web/lib/slug.ts makes them (and server/internal/artifacts/outline.go), so
/// "#section" links find their heading.
public enum MarkdownAnchors {
    public static func slug(_ s: String) -> String {
        var out = ""
        var dash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }) {
                if dash && !out.isEmpty { out += "-" }
                out.append(ch)
                dash = false
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "section" : out
    }

    /// Dedupes anchors in document order: notes, notes-2, notes-3.
    public struct Anchorer {
        private var seen: [String: Int] = [:]

        public init() {}

        public mutating func next(_ text: String) -> String {
            let base = slug(text)
            let n = seen[base] ?? 0
            seen[base] = n + 1
            return n == 0 ? base : "\(base)-\(n + 1)"
        }
    }
}

/// Where the find bar's query occurs in rendered text, matched as `NativeFindModel.matches` does.
public enum MarkdownFind {
    public static func ranges(of query: String, in text: String, caseSensitive: Bool) -> [NSRange] {
        guard FindLogic.shouldSearch(query: query) else { return [] }
        let ns = text as NSString
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: query, options: options, range: search)
            if found.location == NSNotFound || found.length == 0 { break }
            out.append(found)
            let next = found.location + found.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }
}
