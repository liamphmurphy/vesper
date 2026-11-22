import Foundation

// MARK: - Searchable Types

/// A searchable item type in the command palette: a filter chip (or More menu entry),
/// an `is:` filter token, and the `/search` kinds it maps to.
public enum CommandPaletteType: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case ticket
    case page
    case chat
    case people
    case run
    case epic
    case memory
    case canvas
    case course
    case space
    case workflow
    case library
    case scheduled
    case artifact
    case app

    public var id: String { rawValue }

    /// Primary filter chips shown in the top bar (cycled with `Tab` / `⇧Tab`).
    public static let chipTypes: [CommandPaletteType] = [.ticket, .page, .chat, .people, .run]

    /// Secondary types shown inside the `More +` popover.
    public static let moreTypes: [CommandPaletteType] = allCases.filter { !chipTypes.contains($0) }

    public var label: String {
        switch self {
        case .ticket: "Tickets"
        case .page: "Pages"
        case .chat: "Chats"
        case .people: "People"
        case .run: "Runs"
        case .epic: "Epics"
        case .memory: "Memories"
        case .canvas: "Canvases"
        case .course: "Courses"
        case .space: "Spaces"
        case .workflow: "Workflows"
        case .library: "Library"
        case .scheduled: "Scheduled"
        case .artifact: "Artifacts"
        case .app: "Apps"
        }
    }

    public var singularLabel: String {
        switch self {
        case .ticket: "Ticket"
        case .page: "Page"
        case .chat: "Chat"
        case .people: "Person"
        case .run: "Run"
        case .epic: "Epic"
        case .memory: "Memory"
        case .canvas: "Canvas"
        case .course: "Course"
        case .space: "Space"
        case .workflow: "Workflow"
        case .library: "Library item"
        case .scheduled: "Scheduled task"
        case .artifact: "Artifact"
        case .app: "App"
        }
    }

    /// Plural noun for "+ N more …" and empty-state copy.
    public var noun: String {
        switch self {
        case .ticket: "tickets"
        case .page: "pages"
        case .chat: "chats"
        case .people: "people"
        case .run: "runs"
        case .epic: "epics"
        case .memory: "memories"
        case .canvas: "canvases"
        case .course: "courses"
        case .space: "spaces"
        case .workflow: "workflows"
        case .library: "Library items"
        case .scheduled: "scheduled tasks"
        case .artifact: "artifacts"
        case .app: "apps"
        }
    }

    public var token: String { "is:\(rawValue)" }

    /// The `/search` kind strings covered by this type.
    public var searchKinds: [String] {
        switch self {
        case .ticket: ["ticket"]
        case .page: ["page"]
        case .chat: ["chat"]
        case .people: ["persona", "agent"]
        case .run: ["run"]
        case .epic: ["epic"]
        case .memory: ["memory"]
        case .canvas: ["canvas"]
        case .course: ["course"]
        case .space: ["space"]
        case .workflow: ["workflow"]
        case .library: ["library"]
        case .scheduled: ["scheduled"]
        case .artifact: ["artifact"]
        case .app: []
        }
    }

    /// Single `API.SearchType` when one kind covers this type (nil for multi-kind `.people` or local `.app`).
    public var singleSearchType: API.SearchType? {
        guard searchKinds.count == 1, let first = searchKinds.first else { return nil }
        return API.SearchType(rawValue: first)
    }

    public var sfSymbol: String {
        switch self {
        case .ticket: "checklist"
        case .page: "doc.text"
        case .chat: "bubble.left"
        case .people: "person.2"
        case .run: "play.circle"
        case .epic: "square.stack.3d.up"
        case .memory: "bookmark"
        case .canvas: "pencil.and.outline"
        case .course: "graduationcap"
        case .space: "folder"
        case .workflow: "point.3.connected.trianglepath.dotted"
        case .library: "books.vertical"
        case .scheduled: "clock"
        case .artifact: "doc.richtext"
        case .app: "square.grid.2x2"
        }
    }
}

// MARK: - Filter, Query & Link Models

public struct CommandPaletteFilters: Sendable, Equatable {
    public var text: String
    public var types: [CommandPaletteType]
    public var status: String?
    public var tokens: [String]

    public init(text: String = "", types: [CommandPaletteType] = [], status: String? = nil, tokens: [String] = []) {
        self.text = text
        self.types = types
        self.status = status
        self.tokens = tokens
    }
}

public struct CommandPaletteTextPart: Sendable, Equatable {
    public var text: String
    public var match: Bool

    public init(text: String, match: Bool) {
        self.text = text
        self.match = match
    }
}

public struct CommandPaletteLink: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var meta: String?
    public var href: String
    public var kind: String
    public var status: String?

    public init(id: String, title: String, meta: String? = nil, href: String, kind: String, status: String? = nil) {
        self.id = id
        self.title = title
        self.meta = meta
        self.href = href
        self.kind = kind
        self.status = status
    }
}

public struct CommandPaletteMessageMatch: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var href: String
    public var snippet: String
    public var author: String
    public var at: String?

    public init(id: String, href: String, snippet: String, author: String, at: String? = nil) {
        self.id = id
        self.href = href
        self.snippet = snippet
        self.author = author
        self.at = at
    }
}

public struct CommandPaletteChatMatch: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var href: String
    public var persona: String?
    public var at: String?
    public var score: Double
    public var titled: Bool
    public var messages: [CommandPaletteMessageMatch]

    public init(
        id: String,
        title: String,
        href: String,
        persona: String? = nil,
        at: String? = nil,
        score: Double,
        titled: Bool,
        messages: [CommandPaletteMessageMatch] = []
    ) {
        self.id = id
        self.title = title
        self.href = href
        self.persona = persona
        self.at = at
        self.score = score
        self.titled = titled
        self.messages = messages
    }
}

public enum CommandPaletteScopeTarget: Sendable, Equatable, Hashable {
    case knowledge
    case type(CommandPaletteType, label: String)

    public var label: String {
        switch self {
        case .knowledge: "Knowledge"
        case .type(_, let label): label
        }
    }
}

public enum CommandPalettePageContext: Sendable, Equatable, Hashable {
    case ticket(key: String)
    case artifact(id: String)
    case knowledge(id: String)
    case wiki(path: String)
}

public struct CommandPaletteFacet: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { value }
    public var value: String
    public var count: Int

    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

public struct CommandPaletteRankedGroup<Item> {
    public var type: CommandPaletteType
    public var items: [Item]
    public var total: Int
    public var more: Int

    public init(type: CommandPaletteType, items: [Item], total: Int, more: Int) {
        self.type = type
        self.items = items
        self.total = total
        self.more = more
    }
}

extension CommandPaletteRankedGroup: Sendable where Item: Sendable {}

// MARK: - Panel Layout Geometry

/// Pure screen-space geometry for the floating Command Palette `NSPanel`.
public struct CommandPaletteRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var midX: Double { x + width / 2 }
    public var minY: Double { y }
    public var maxY: Double { y + height }
}

public enum CommandPaletteLayout {
    public static let defaultWidth: Double = 920
    public static let defaultHeight: Double = 520
    public static let minWidth: Double = 540
    public static let minHeight: Double = 360
    public static let screenMargin: Double = 16
    public static let splitPreviewThreshold: Double = 820

    /// Centers the palette horizontally over the active content pane (falling back to the window
    /// frame or screen), places it ~12% below the anchor's top edge (capped at 104pt), and clamps
    /// it inside `visibleScreen` with a 16pt margin.
    public static func panelFrame(
        preferredWidth: Double = defaultWidth,
        preferredHeight: Double = defaultHeight,
        contentPane: CommandPaletteRect?,
        window: CommandPaletteRect?,
        visibleScreen: CommandPaletteRect
    ) -> CommandPaletteRect {
        let maxW = max(minWidth, visibleScreen.width - 48)
        let maxH = max(minHeight, visibleScreen.height - 80)
        let width = min(preferredWidth, maxW)
        let height = min(preferredHeight, maxH)

        let horizontalAnchor = (contentPane.flatMap { $0.width >= 320 ? $0 : nil }) ?? window ?? visibleScreen
        let verticalAnchor = window ?? contentPane ?? visibleScreen

        let rawX = horizontalAnchor.midX - width / 2
        let topOffset = min(verticalAnchor.height * 0.12, 104)
        let rawY = verticalAnchor.maxY - topOffset - height

        let minX = visibleScreen.minX + screenMargin
        let maxX = max(minX, visibleScreen.maxX - width - screenMargin)
        let minY = visibleScreen.minY + screenMargin
        let maxY = max(minY, visibleScreen.maxY - height - screenMargin)

        let x = min(max(rawX, minX), maxX)
        let y = min(max(rawY, minY), maxY)
        return CommandPaletteRect(x: floor(x), y: floor(y), width: floor(width), height: floor(height))
    }
}

// MARK: - Core Logic

public enum CommandPaletteLogic {
    public static let maxRecent = 8
    public static let perGroupCap = 3

    private static let filterTypeAliases: [String: CommandPaletteType] = [
        "ticket": .ticket, "tickets": .ticket,
        "page": .page, "pages": .page, "note": .page,
        "chat": .chat, "chats": .chat, "message": .chat,
        "people": .people, "person": .people, "persona": .people, "agent": .people,
        "run": .run, "runs": .run,
        "epic": .epic, "epics": .epic,
        "memory": .memory, "memories": .memory,
        "canvas": .canvas, "canvases": .canvas,
        "course": .course, "courses": .course, "learn": .course,
        "space": .space, "spaces": .space, "project": .space,
        "workflow": .workflow, "workflows": .workflow,
        "library": .library,
        "scheduled": .scheduled, "schedule": .scheduled,
        "artifact": .artifact, "artifacts": .artifact,
        "app": .app, "apps": .app,
    ]

    /// Splits `is:ticket status:done deploy` into filters and search text; unknown tokens remain text.
    /// A leading `@` filters to people and `#` to tickets.
    public static func parseFilters(_ query: String) -> CommandPaletteFilters {
        var out = CommandPaletteFilters()
        var words: [String] = []
        var rest = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if rest.hasPrefix("@") {
            out.types.append(.people)
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if rest.hasPrefix("#") {
            out.types.append(.ticket)
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        for word in rest.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = word.lowercased()
            if lower.hasPrefix("is:") || lower.hasPrefix("in:") {
                let value = String(lower.dropFirst(3))
                if let type = filterTypeAliases[value] {
                    if !out.types.contains(type) { out.types.append(type) }
                    out.tokens.append(word)
                    continue
                }
            } else if lower.hasPrefix("status:") {
                let value = String(lower.dropFirst(7))
                if !value.isEmpty {
                    out.status = value
                    out.tokens.append(word)
                    continue
                }
            }
            words.append(word)
        }
        out.text = words.joined(separator: " ")
        return out
    }

    /// Removes one filter token from `query`.
    public static func removeToken(_ query: String, token: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0 != token }
            .joined(separator: " ")
    }

    /// Drops `is:` / `in:` tokens and leading `@`/`#` prefixes when the user clicks a type chip.
    public static func stripTypeFilters(from query: String) -> String {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("@") || q.hasPrefix("#") {
            q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = tokens.filter { word in
            let lower = word.lowercased()
            if lower.hasPrefix("is:") || lower.hasPrefix("in:") {
                let value = String(lower.dropFirst(3))
                return filterTypeAliases[value] == nil
            }
            return true
        }
        return kept.joined(separator: " ")
    }

    /// A ticket key typed on its own (`"lazyagents-39"` → `"LAZYAGENTS-39"`), or bare digits in `project`.
    public static func ticketKeyFrom(_ query: String, project: String? = nil) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let project, !project.isEmpty, text.allSatisfy(\.isNumber) {
            return "\(project.uppercased())-\(text)"
        }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = parts.first, let num = parts.last,
              let firstChar = prefix.first, firstChar.isLetter,
              prefix.allSatisfy({ $0.isLetter || $0.isNumber }),
              !num.isEmpty, num.allSatisfy(\.isNumber)
        else { return nil }
        return "\(prefix.uppercased())-\(num)"
    }

    /// Splits a Knowledge query into plain text and/or a leading `#tag`.
    /// Supports both `#dnd` (tag-only) and `#dnd veil` (tag + text).
    public static func parseKnowledgeQuery(_ raw: String) -> (text: String, tag: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return (trimmed, "") }
        let afterHash = String(trimmed.dropFirst())
        let parts = afterHash.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let tag = parts.first.map(String.init) ?? ""
        let text = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (text, tag)
    }

    /// Display folder for a Knowledge page path (`"Campaign/Sessions/Dawn"` → `"Campaign / Sessions"`).
    public static func knowledgeFolder(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "Top level" }
        return parts.dropLast().joined(separator: " / ")
    }

    public static func stepChip(_ current: CommandPaletteType?, back: Bool = false) -> CommandPaletteType? {
        let order: [CommandPaletteType?] = [nil] + CommandPaletteType.chipTypes.map(Optional.some)
        let idx = order.firstIndex(of: current) ?? 0
        return order[(idx + (back ? order.count - 1 : 1)) % order.count]
    }

    public static func stepKnowledgeKind(_ current: KnowledgePageKind?, back: Bool = false) -> KnowledgePageKind? {
        let order: [KnowledgePageKind?] = [nil, .document, .deck, .design]
        let idx = order.firstIndex(of: current) ?? 0
        return order[(idx + (back ? order.count - 1 : 1)) % order.count]
    }

    // MARK: - Scope & Page Context

    private static let knowledgePrefixes = ["/knowledge", "/wiki", "/apps/docs", "/apps/slides", "/apps/designs"]

    private static let typeScopePrefixes: [(String, CommandPaletteType)] = [
        ("/tickets", .ticket),
        ("/board", .ticket),
        ("/epics", .epic),
        ("/runs", .run),
        ("/chat", .chat),
        ("/agents", .people),
        ("/workflows", .workflow),
        ("/library", .library),
        ("/scheduled", .scheduled),
        ("/learn", .course),
        ("/spaces", .space),
        ("/artifacts", .artifact),
        ("/apps", .app),
    ]

    private static func matchesPrefix(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    /// Resolves the page-scoped target for `⇧⌘K` given the current route path and optional query string.
    public static func pageScope(path rawPath: String, search: String? = nil) -> CommandPaletteScopeTarget? {
        let split = rawPath.split(separator: "?", maxSplits: 1)
        let path = split.first.map(String.init) ?? "/"
        let queryString = search ?? (split.count > 1 ? String(split[1]) : "")
        let queryItems = parseQueryItems(queryString)

        if knowledgePrefixes.contains(where: { matchesPrefix(path, $0) }) {
            return .knowledge
        }
        if matchesPrefix(path, "/tickets"), queryItems["layout"] == "epics" {
            return .type(.epic, label: CommandPaletteType.epic.label)
        }
        if matchesPrefix(path, "/work") {
            let type: CommandPaletteType = switch queryItems["view"] {
            case "tickets": .ticket
            case "epics": .epic
            default: .run
            }
            return .type(type, label: type.label)
        }
        if matchesPrefix(path, "/settings") {
            let section = queryItems["section"]
            if section == "personas" || section == "persona" || queryItems["persona"] != nil {
                return .type(.people, label: CommandPaletteType.people.label)
            }
        }
        if let hit = typeScopePrefixes.first(where: { matchesPrefix(path, $0.0) }) {
            return .type(hit.1, label: hit.1.label)
        }
        return nil
    }

    /// Resolves a `CommandPaletteRequest`'s scope against the active route.
    public static func resolveScope(request: CommandPaletteRequest) -> CommandPaletteScopeTarget? {
        switch request.scope {
        case .knowledge:
            return .knowledge
        case .type:
            if let raw = request.scopeType, let type = CommandPaletteType(rawValue: raw) {
                return .type(type, label: request.scopeLabel ?? type.label)
            }
            return nil
        case .page:
            return pageScope(path: request.path ?? "/", search: request.search)
        case .all, .none:
            return nil
        }
    }

    public static func pageContext(path rawPath: String) -> CommandPalettePageContext? {
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        if path.hasPrefix("/tickets/") {
            let key = String(path.dropFirst("/tickets/".count))
            if !key.contains("/"), let normalized = ticketKeyFrom(key) {
                return .ticket(key: normalized)
            }
        }
        if path.hasPrefix("/artifacts/") {
            let id = String(path.dropFirst("/artifacts/".count))
            if isUUID(id) { return .artifact(id: id) }
        }
        if path.hasPrefix("/knowledge/") {
            let rest = String(path.dropFirst("/knowledge/".count))
            let firstSeg = rest.split(separator: "/").first.map(String.init) ?? ""
            if isUUID(firstSeg) { return .knowledge(id: firstSeg) }
        }
        if path.hasPrefix("/wiki/") {
            let rest = String(path.dropFirst("/wiki/".count))
            if !rest.isEmpty {
                let decoded = rest.split(separator: "/").map { seg in
                    String(seg).removingPercentEncoding ?? String(seg)
                }.joined(separator: "/")
                return .wiki(path: decoded)
            }
        }
        return nil
    }

    public static func projectOfKey(_ key: String) -> String {
        guard let dash = key.lastIndex(of: "-") else { return key }
        return String(key[..<dash])
    }

    public static func projectFromRoute(path: String, search: String? = nil) -> String? {
        if case .ticket(let key) = pageContext(path: path) {
            return projectOfKey(key)
        }
        let split = path.split(separator: "?", maxSplits: 1)
        let q = search ?? (split.count > 1 ? String(split[1]) : "")
        let items = parseQueryItems(q)
        if let project = items["project"], !project.isEmpty {
            return project
        }
        return nil
    }

    /// Builds `/chat/<id>?attach=...` query parameters matching `web/lib/chat-context.ts`.
    public static func attachQuery(project: String?, kind: String, idOrKey: String, title: String?) -> String {
        var items: [URLQueryItem] = []
        if let project, !project.isEmpty {
            items.append(URLQueryItem(name: "project", value: project))
        }
        items.append(URLQueryItem(name: "attach", value: "\(kind):\(idOrKey)"))
        if let title, !title.isEmpty {
            items.append(URLQueryItem(name: "attach_title", value: title))
        }
        var comps = URLComponents()
        comps.queryItems = items
        return comps.percentEncodedQuery ?? ""
    }

    /// URL path for a Knowledge page (`/knowledge/<id>`).
    public static func knowledgePageHref(id: String) -> String {
        "/knowledge/\(id)"
    }

    // MARK: - Text Matching & Excerpts

    /// Splits a server snippet containing `«match»` markers into plain and highlighted runs.
    public static func snippetParts(_ snippet: String) -> [CommandPaletteTextPart] {
        var cleaned = snippet
        // Replace [[Path|Label]] -> Label and [[Path]] -> Path
        if let regex = try? NSRegularExpression(pattern: #"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: "$1"
            )
        }
        cleaned = cleaned.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")

        var out: [CommandPaletteTextPart] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            guard let open = cleaned[idx...].firstIndex(of: "«") else {
                let tail = String(cleaned[idx...])
                if !tail.isEmpty { out.append(CommandPaletteTextPart(text: tail, match: false)) }
                break
            }
            if open > idx {
                out.append(CommandPaletteTextPart(text: String(cleaned[idx..<open]), match: false))
            }
            let afterOpen = cleaned.index(after: open)
            guard let close = cleaned[afterOpen...].firstIndex(of: "»") else {
                let tail = String(cleaned[open...])
                if !tail.isEmpty { out.append(CommandPaletteTextPart(text: tail, match: false)) }
                break
            }
            let hit = String(cleaned[afterOpen..<close])
            if !hit.isEmpty {
                out.append(CommandPaletteTextPart(text: hit, match: true))
            }
            idx = cleaned.index(after: close)
        }
        return out
    }

    /// Splits `text` around case-insensitive occurrences of any word in `query`.
    public static func matchParts(text: String, query: String) -> [CommandPaletteTextPart] {
        let words = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, !text.isEmpty else {
            return text.isEmpty ? [] : [CommandPaletteTextPart(text: text, match: false)]
        }
        // Sort longest first so longer words match before shorter prefixes.
        let escaped = words
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "(" + escaped.joined(separator: "|") + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [CommandPaletteTextPart(text: text, match: false)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [CommandPaletteTextPart(text: text, match: false)] }

        var parts: [CommandPaletteTextPart] = []
        var cursor = 0
        for m in matches {
            let r = m.range
            if r.location > cursor {
                parts.append(CommandPaletteTextPart(text: nsText.substring(with: NSRange(location: cursor, length: r.location - cursor)), match: false))
            }
            if r.length > 0 {
                parts.append(CommandPaletteTextPart(text: nsText.substring(with: r), match: true))
            }
            cursor = r.location + r.length
        }
        if cursor < nsText.length {
            parts.append(CommandPaletteTextPart(text: nsText.substring(from: cursor), match: false))
        }
        return parts
    }

    /// True when the highlighted words in a server snippet do not appear in the title.
    public static func foundInBody(snippet: String, title: String) -> Bool {
        let parts = snippetParts(snippet).filter(\.match)
        guard !parts.isEmpty else { return false }
        let lowerTitle = title.lowercased()
        return !parts.contains { lowerTitle.contains($0.text.lowercased()) }
    }

    /// Strips markdown syntax into a single plain-text line truncated to `maxLength`.
    public static func plainExcerpt(_ md: String, max maxLength: Int) -> String {
        var text = md
        let replacements: [(String, String)] = [
            (#"```[\s\S]*?(```|$)"#, " "),
            (#"!\[[^\]]*\]\([^)]*\)|!\[\[[^\]]*\]\]"#, " "),
            (#"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#, "$1"),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"^---\n[\s\S]*?\n---\n"#, " "),
            (#"(?m)^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+"#, ""),
            (#"[*_`~]+"#, ""),
            (#"\s+"#, " "),
        ]
        for (pattern, template) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxLength, maxLength > 1 else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: maxLength - 1)
        return String(text[..<cutoff]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Every whitespace-separated word of `query` appears in `text` (case-insensitive).
    public static func matchesWords(_ text: String, query: String) -> Bool {
        let hay = text.lowercased()
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { hay.contains($0) }
    }

    /// Every word of `query` prefixes a word of `text`.
    public static func startsWords(_ text: String, query: String) -> Bool {
        let hay = text.lowercased().split(whereSeparator: \.isWhitespace)
        let want = query.lowercased().split(whereSeparator: \.isWhitespace)
        return !want.isEmpty && want.allSatisfy { w in hay.contains { $0.hasPrefix(w) } }
    }

    /// Ranks personas matching `query`, stripping leading `"chat with"` / `"talk to"`.
    public static func personaMatches<P>(_ personas: [P], name: (P) -> String, query: String) -> [P] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["chat with ", "talk to ", "chat "] where q.hasPrefix(prefix) {
            q = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !q.isEmpty else { return [] }
        let ranked: [(item: P, index: Int, rank: Int)] = personas.enumerated().compactMap { i, p in
            let n = name(p).lowercased()
            let r: Int
            if n == q { r = 0 }
            else if n.hasPrefix(q) { r = 1 }
            else if startsWords(n, query: q) { r = 2 }
            else { return nil }
            return (p, i, r)
        }
        return ranked.sorted { a, b in a.rank != b.rank ? a.rank < b.rank : a.index < b.index }.map(\.item)
    }

    /// Matches apps/tools against `query`, stripping leading `"open"` / `"go to"`.
    public static func appMatches<A>(_ apps: [A], searchable: (A) -> String, query: String) -> [A] {
        var q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["open ", "go to "] where q.hasPrefix(prefix) {
            q = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !q.isEmpty else { return [] }
        return apps.filter { startsWords("\(searchable($0)) apps", query: q) }
    }

    // MARK: - Search Hit Mapping & Ranking

    public static func typeOf(_ target: API.LinkTarget) -> CommandPaletteType {
        switch target.kind {
        case .ticket: .ticket
        case .chat: .chat
        case .run: .run
        case .epic: .epic
        case .memory: .memory
        case .canvas: .canvas
        case .course: .course
        case .space: .space
        case .workflow: .workflow
        case .library: .library
        case .scheduled: .scheduled
        case .agent, .persona: .people
        default:
            target.artifactType == .note ? .page : .artifact
        }
    }

    public static func typeCounts(_ counts: [String: Int]?) -> [CommandPaletteType: Int] {
        guard let counts else { return [:] }
        var out: [CommandPaletteType: Int] = [:]
        for type in CommandPaletteType.allCases {
            let n = type.searchKinds.reduce(0) { $0 + (counts[$1] ?? 0) }
            if n > 0 { out[type] = n }
        }
        return out
    }

    public static func linkFromTarget(_ target: API.LinkTarget) -> CommandPaletteLink? {
        guard let href = target.href, !href.isEmpty else { return nil }
        let type = typeOf(target)
        let isPage = type == .page
        let title = (isPage && !(target.path ?? "").isEmpty) ? target.path! : target.title
        let meta: String
        if isPage {
            meta = "page"
        } else if let displayId = target.displayId, !displayId.isEmpty {
            meta = displayId
        } else if let artType = target.artifactType?.rawValue {
            meta = artType
        } else if target.kind == .agent || target.kind == .persona {
            meta = "persona"
        } else {
            meta = type.label.lowercased()
        }
        return CommandPaletteLink(
            id: target.id ?? href,
            title: title,
            meta: meta,
            href: href,
            kind: type.label,
            status: target.status
        )
    }

    /// Folds `/search` chat hits into one row per chat with nested matching messages.
    public static func groupChats(_ hits: [API.SearchHit]) -> [CommandPaletteChatMatch] {
        var order: [String] = []
        var byId: [String: CommandPaletteChatMatch] = [:]

        for hit in hits {
            let t = hit.target
            guard t.kind == .chat, let id = t.id, !id.isEmpty, let href = t.href, !href.isEmpty else { continue }
            var chat = byId[id] ?? CommandPaletteChatMatch(
                id: id,
                title: t.title.isEmpty ? "Untitled chat" : t.title,
                href: "/chat/\(id)",
                persona: nil,
                at: nil,
                score: hit.score,
                titled: false,
                messages: []
            )
            if byId[id] == nil { order.append(id) }
            chat.score = max(chat.score, hit.score)

            if let anchor = t.anchor, !anchor.isEmpty {
                chat.messages.append(CommandPaletteMessageMatch(
                    id: anchor,
                    href: href,
                    snippet: hit.snippet,
                    author: hit.detail ?? "",
                    at: hit.updatedAt
                ))
                if chat.persona == nil, let detail = hit.detail, !detail.isEmpty, detail != "You" {
                    chat.persona = detail
                }
            } else {
                chat.titled = true
                chat.href = href
                if let detail = hit.detail, !detail.isEmpty { chat.persona = detail }
                if let at = hit.updatedAt { chat.at = at }
            }
            if chat.at == nil, let at = hit.updatedAt { chat.at = at }
            byId[id] = chat
        }

        return order.compactMap { byId[$0] }
    }

    public static func rankGroups<Item>(
        _ groups: [(type: CommandPaletteType, items: [Item])],
        score: (Item) -> Double,
        cap: Int = perGroupCap,
        counts: [CommandPaletteType: Int] = [:]
    ) -> [CommandPaletteRankedGroup<Item>] {
        let nonEmpty = groups.enumerated().compactMap { index, group -> (index: Int, best: Double, group: (type: CommandPaletteType, items: [Item]))? in
            guard !group.items.isEmpty else { return nil }
            let best = group.items.map(score).max() ?? 0
            return (index, best, group)
        }
        return nonEmpty
            .sorted { a, b in a.best != b.best ? a.best > b.best : a.index < b.index }
            .map { entry in
                let total = max(counts[entry.group.type] ?? 0, entry.group.items.count)
                let slice = Array(entry.group.items.prefix(cap))
                return CommandPaletteRankedGroup(
                    type: entry.group.type,
                    items: slice,
                    total: total,
                    more: max(0, total - slice.count)
                )
            }
    }

    public static func facets(_ values: [String?]) -> [CommandPaletteFacet] {
        var counts: [String: Int] = [:]
        for value in values {
            if let value, !value.isEmpty {
                counts[value, default: 0] += 1
            }
        }
        return counts
            .map { CommandPaletteFacet(value: $0.key, count: $0.value) }
            .sorted { a, b in a.count != b.count ? a.count > b.count : a.value.localizedCompare(b.value) == .orderedAscending }
    }

    // MARK: - Recents

    public static func pushRecent(_ list: [CommandPaletteLink], item: CommandPaletteLink, max maxCount: Int = maxRecent) -> [CommandPaletteLink] {
        Array(([item] + list.filter { $0.href != item.href }).prefix(maxCount))
    }

    public static func parseRecent(data: Data?) -> [CommandPaletteLink] {
        guard let data, let decoded = try? JSONDecoder().decode([CommandPaletteLink].self, from: data) else {
            return []
        }
        return Array(decoded.filter { $0.href.hasPrefix("/") && !$0.title.isEmpty }.prefix(maxRecent))
    }

    // MARK: - Contrast Helper

    /// True when pure white text reads better than dark charcoal on `accentHex`.
    /// macOS system blue (`#0a84ff`, luminance ~0.23) returns `true`, fixing the dark-on-blue
    /// contrast issue, while very bright yellow/pastel accents (`>= 0.45`) return `false`.
    public static func prefersLightText(onAccentHex hex: String) -> Bool {
        guard PaletteTokens.isHex(hex) else { return true }
        let opaque = String(hex.prefix(7))
        return PaletteTokens.luminance(opaque) < 0.45
    }

    // MARK: - Private Helpers

    private static func parseQueryItems(_ raw: String) -> [String: String] {
        let stripped = raw.hasPrefix("?") ? String(raw.dropFirst()) : raw
        guard !stripped.isEmpty else { return [:] }
        var comps = URLComponents()
        comps.percentEncodedQuery = stripped
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    private static func isUUID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }
}
