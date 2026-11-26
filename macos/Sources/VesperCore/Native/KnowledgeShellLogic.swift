import Foundation

// MARK: - Explorer Mode, Destinations & Tree Models

public enum KnowledgeViewMode: String, Codable, Sendable, CaseIterable, Hashable {
    case yours
    case agent
}

public enum KnowledgeDestination: Sendable, Equatable, Hashable {
    case home
    case start(KnowledgePageKind)
    case search(initialQuery: String?)
    case connect
    case graph
    case page(id: String)
    case attachment(id: String)
    case legacyWiki(path: String)

    public var activePageId: String? {
        if case .page(let id) = self { return id }
        return nil
    }

    public var activeAttachmentId: String? {
        if case .attachment(let id) = self { return id }
        return nil
    }
}

public struct KnowledgeTreeFolder: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { path.isEmpty ? "__root__" : "f:\(path)" }
    public var name: String
    public var path: String
    public var folders: [KnowledgeTreeFolder]
    public var pages: [KnowledgePageRow]
    public var attachments: [KnowledgeAttachment]
    public var count: Int

    public init(
        name: String,
        path: String,
        folders: [KnowledgeTreeFolder] = [],
        pages: [KnowledgePageRow] = [],
        attachments: [KnowledgeAttachment] = [],
        count: Int = 0
    ) {
        self.name = name
        self.path = path
        self.folders = folders
        self.pages = pages
        self.attachments = attachments
        self.count = count
    }
}

public enum KnowledgeExplorerRowKind: Sendable, Equatable, Hashable {
    case folder(KnowledgeTreeFolder)
    case page(KnowledgePageRow)
    case attachment(KnowledgeAttachment)
    case showMore(folderPath: String, hiddenCount: Int)
}

public struct KnowledgeExplorerRow: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var depth: Int
    public var kind: KnowledgeExplorerRowKind

    public init(id: String, depth: Int, kind: KnowledgeExplorerRowKind) {
        self.id = id
        self.depth = depth
        self.kind = kind
    }
}

// MARK: - Drag-to-Move & Multi-Select Models

public struct KnowledgeDragItem: Codable, Sendable, Equatable, Hashable {
    public enum ItemKind: String, Codable, Sendable, Hashable {
        case page
        case folder
    }

    public var kind: ItemKind
    public var id: String
    public var path: String
    public var title: String

    private static let payloadPrefix = "vesper-knowledge-drag:"

    public init(kind: ItemKind, id: String, path: String, title: String) {
        self.kind = kind
        self.id = id
        self.path = path
        self.title = title
    }

    public static func page(_ row: KnowledgePageRow) -> KnowledgeDragItem {
        KnowledgeDragItem(kind: .page, id: row.id, path: row.path, title: row.title)
    }

    public static func folder(_ folder: KnowledgeTreeFolder) -> KnowledgeDragItem {
        KnowledgeDragItem(kind: .folder, id: folder.path, path: folder.path, title: folder.name)
    }

    public func encodeDragPayload() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return Self.payloadPrefix + json
    }

    public static func decodeDragPayload(_ raw: String) -> KnowledgeDragItem? {
        guard raw.hasPrefix(payloadPrefix) else { return nil }
        let json = String(raw.dropFirst(payloadPrefix.count))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KnowledgeDragItem.self, from: data)
    }
}

public enum KnowledgeMovePlan: Sendable, Equatable {
    case movePage(id: String, newPath: String, title: String?)
    case moveFolder(from: String, to: String, updatedExpanded: Set<String>)
}

/// Multi-select state for explorer rows (`"f:<path>"` or `"p:<id>"`): click, ⌘-click toggle, ⇧-click range.
public struct KnowledgeSelection: Equatable, Sendable {
    public enum Modifier: Sendable { case none, toggle, extend }

    public private(set) var selected: Set<String> = []
    public private(set) var focused: String?
    public private(set) var anchor: String?

    public init() {}

    public mutating func click(_ id: String, in ids: [String], modifier: Modifier = .none) {
        switch modifier {
        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
                focused = selected.isEmpty ? nil : (focused == id ? ids.first(where: selected.contains) : focused)
                return
            }
            selected.insert(id)
            anchor = id
        case .extend:
            if let anchor, let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: id) {
                selected = Set(ids[min(from, to)...max(from, to)])
            } else {
                selected = [id]
                anchor = id
            }
        case .none:
            selected = [id]
            anchor = id
        }
        focused = id
    }

    public mutating func selectAll(_ ids: [String]) {
        selected = Set(ids)
        if !(focused.map(ids.contains) ?? false) { focused = ids.first }
        anchor = focused
    }

    public mutating func clear() {
        selected = []
        focused = nil
        anchor = nil
    }

    public mutating func prune(to ids: [String]) {
        let present = Set(ids)
        selected.formIntersection(present)
        if let f = focused, !present.contains(f) { focused = ids.first(where: selected.contains) }
        if let a = anchor, !present.contains(a) { anchor = focused }
    }

    public func targets(for id: String, in ids: [String]) -> [String] {
        selected.contains(id) && selected.count > 1 ? ids.filter(selected.contains) : [id]
    }
}

// MARK: - Search Filter & Query Builder

public struct KnowledgeSearchFilter: Sendable, Equatable, Hashable {
    public var text: String
    public var tag: String
    public var folder: String
    public var propertyKey: String
    public var propertyValue: String
    public var audience: KnowledgeAudience?
    public var kind: KnowledgePageKind?
    public var orphansOnly: Bool
    public var unresolvedOnly: Bool
    public var includeAgent: Bool
    public var limit: Int
    public var offset: Int

    public init(
        text: String = "",
        tag: String = "",
        folder: String = "",
        propertyKey: String = "",
        propertyValue: String = "",
        audience: KnowledgeAudience? = nil,
        kind: KnowledgePageKind? = nil,
        orphansOnly: Bool = false,
        unresolvedOnly: Bool = false,
        includeAgent: Bool = false,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.tag = tag
        self.folder = folder
        self.propertyKey = propertyKey
        self.propertyValue = propertyValue
        self.audience = audience
        self.kind = kind
        self.orphansOnly = orphansOnly
        self.unresolvedOnly = unresolvedOnly
        self.includeAgent = includeAgent
        self.limit = limit
        self.offset = offset
    }

    public var hasActiveFilters: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")).isEmpty
            || !KnowledgeShellLogic.normalizeFolderPath(folder).isEmpty
            || !propertyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !propertyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || audience != nil
            || kind != nil
            || orphansOnly
            || unresolvedOnly
            || includeAgent
    }

    /// The `POST /api/v1/knowledge/query` endpoint is required when filtering by `properties` key=value.
    public var requiresPostQuery: Bool {
        !propertyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !propertyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func buildQuery() -> KnowledgePageQuery {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedTag.hasPrefix("#") { trimmedTag.removeFirst() }
        let trimmedFolder = KnowledgeShellLogic.normalizeFolderPath(folder)
        let trimmedKey = propertyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVal = propertyValue.trimmingCharacters(in: .whitespacesAndNewlines)

        var props: [String: JSONValue]?
        if !trimmedKey.isEmpty && !trimmedVal.isEmpty {
            props = [trimmedKey: KnowledgeShellLogic.parsePropertyFilterValue(trimmedVal)]
        }

        let includeAgentFlag = includeAgent || audience == .agent
        return KnowledgePageQuery(
            text: trimmedText.isEmpty ? nil : trimmedText,
            folder: trimmedFolder.isEmpty ? nil : trimmedFolder,
            tag: trimmedTag.isEmpty ? nil : trimmedTag,
            audience: audience,
            properties: props,
            orphans: orphansOnly ? true : nil,
            unresolved: unresolvedOnly ? true : nil,
            includeAgent: includeAgentFlag ? true : nil,
            kind: kind,
            limit: limit,
            offset: offset > 0 ? offset : nil
        )
    }

    public func buildRequest() -> APIRequest<KnowledgePageTable> {
        let query = buildQuery()
        if requiresPostQuery {
            return KnowledgeAPI.queryPages(query)
        }
        return KnowledgeAPI.listPages(
            q: query.text,
            tag: query.tag,
            folder: query.folder,
            audience: query.audience,
            includeAgent: query.includeAgent ?? false,
            orphans: query.orphans ?? false,
            unresolved: query.unresolved ?? false,
            kind: query.kind,
            limit: query.limit,
            offset: query.offset
        )
    }

    /// When a user types a property key without a value, narrow returned rows client-side to pages defining that key.
    public func matchesClientSidePropertyKey(_ row: KnowledgePageRow) -> Bool {
        let key = propertyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let val = propertyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, val.isEmpty else { return true }
        return row.properties[key] != nil
    }
}

// MARK: - Home, Connect, Editor Seam & Import Models

public struct KnowledgeHomeSummary: Sendable, Equatable {
    public var pagesToReview: [KnowledgePageRow]
    public var inboxCaptures: [KnowledgePageRow]
    public var agentProposals: [KnowledgePageRow]
    public var latestPage: KnowledgePageRow?
    public var otherRecentPages: [KnowledgePageRow]
    public var kindCounts: [KnowledgePageKind: Int]
    public var topTags: [(tag: String, count: Int)]
    public var unresolvedCount: Int
    public var orphanCount: Int

    public static func == (lhs: KnowledgeHomeSummary, rhs: KnowledgeHomeSummary) -> Bool {
        lhs.pagesToReview == rhs.pagesToReview
            && lhs.inboxCaptures == rhs.inboxCaptures
            && lhs.agentProposals == rhs.agentProposals
            && lhs.latestPage == rhs.latestPage
            && lhs.otherRecentPages == rhs.otherRecentPages
            && lhs.kindCounts == rhs.kindCounts
            && lhs.topTags.map(\.tag) == rhs.topTags.map(\.tag)
            && lhs.topTags.map(\.count) == rhs.topTags.map(\.count)
            && lhs.unresolvedCount == rhs.unresolvedCount
            && lhs.orphanCount == rhs.orphanCount
    }
}

public struct KnowledgeUnresolvedSource: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct KnowledgeUnresolvedTarget: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name.lowercased() }
    public var name: String
    public var sources: [KnowledgeUnresolvedSource]

    public init(name: String, sources: [KnowledgeUnresolvedSource]) {
        self.name = name
        self.sources = sources
    }
}

/// Target for `KnowledgePageEditorSlot` (seam for LAZYAGENTS-288).
public enum KnowledgePageContentTarget: Sendable, Equatable {
    case deck(canvasId: String, hostedPath: String)
    case design(canvasId: String, hostedPath: String)
    case pdf(sourcePath: String, title: String)
    case hostedPage(hostedPath: String)
}

public enum KnowledgeImportFilter: String, Sendable, CaseIterable, Hashable {
    case all
    case renamed
    case conflicts
    case unresolved
    case files
    case skipped

    public var label: String {
        switch self {
        case .all: "All"
        case .renamed: "Renamed"
        case .conflicts: "Conflicts"
        case .unresolved: "Unresolved"
        case .files: "Kept as files"
        case .skipped: "Skipped"
        }
    }
}

public enum KnowledgeImportStep: Int, Sendable, Equatable {
    case upload = 0
    case review = 1
    case importing = 2
}

public struct KnowledgeImportEntryClassification: Sendable, Equatable {
    public var filter: KnowledgeImportFilter
    public var note: String
    public var symbol: String
    public var tone: Tone

    public init(filter: KnowledgeImportFilter, note: String, symbol: String, tone: Tone) {
        self.filter = filter
        self.note = note
        self.symbol = symbol
        self.tone = tone
    }
}

public struct KnowledgeImportReportSummary: Sendable, Equatable {
    public var createdOrUpdated: Int
    public var unchanged: Int
    public var conflicts: Int
    public var skippedOrFailed: Int
    public var failures: [KnowledgeImportResult]

    public init(
        createdOrUpdated: Int,
        unchanged: Int,
        conflicts: Int,
        skippedOrFailed: Int,
        failures: [KnowledgeImportResult]
    ) {
        self.createdOrUpdated = createdOrUpdated
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.skippedOrFailed = skippedOrFailed
        self.failures = failures
    }
}

// MARK: - Knowledge Shell Domain Logic (Foundation-only for iOS-over-Tailscale portability)

public enum KnowledgeShellLogic: Sendable {
    public static let defaultPageCapPerFolder = 8
    public static let importMaxBytes: Int64 = 2_000_000_000
    public static let maxOutlineLength = 4000

    // MARK: Routing

    public static func destination(for match: NativeRouteMatch) -> KnowledgeDestination {
        switch match.screen {
        case .knowledgeGraph:
            return .graph
        case .knowledgePage:
            if match.path.hasPrefix("/wiki/") {
                return .legacyWiki(path: match.path)
            }
            if let id = match.params["id"], !id.isEmpty {
                return .page(id: id)
            }
            if let rest = match.params["*"], !rest.isEmpty {
                return .legacyWiki(path: match.path)
            }
            return .home
        case .knowledge:
            if match.path == "/knowledge/connect" {
                return .connect
            }
            if match.path.hasPrefix("/knowledge/attachments/"),
               let id = match.params["id"], !id.isEmpty {
                return .attachment(id: id)
            }
            if let raw = match.query["kind"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               let kind = KnowledgePageKind(rawValue: raw) {
                return .start(kind)
            }
            let wantsSearch = match.query["search"] == "1"
                || !(match.query["q"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(match.query["tag"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if wantsSearch {
                return .search(initialQuery: match.query["q"])
            }
            return .home
        default:
            return .home
        }
    }

    // MARK: Tree Building & Flattening

    public static let attachmentsFolderName = "attachments"

    public static func attachmentRoute(id: String) -> String {
        "/knowledge/attachments/\(APIPath.escape(id))"
    }

    public static func markdownEmbedBlock(for refs: [String]) -> String {
        refs.map { "![[\($0)]]" }.joined(separator: "\n")
    }

    private final class MutableFolder {
        let name: String
        let path: String
        var folders: [String: MutableFolder] = [:]
        var pages: [KnowledgePageRow] = []
        var attachments: [KnowledgeAttachment] = []
        var count = 0

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func freeze(depth: Int, prioritizeInbox: Bool) -> KnowledgeTreeFolder {
            let sortedSubfolders = folders.values
                .sorted { lhs, rhs in
                    if prioritizeInbox && depth == 0 {
                        let lInbox = lhs.name == "Inbox"
                        let rInbox = rhs.name == "Inbox"
                        if lInbox != rInbox { return lInbox }
                    }
                    let cmp = lhs.name.localizedStandardCompare(rhs.name)
                    if cmp != .orderedSame { return cmp == .orderedAscending }
                    return lhs.path < rhs.path
                }
                .map { $0.freeze(depth: depth + 1, prioritizeInbox: prioritizeInbox) }

            let daily = !pages.isEmpty && pages.allSatisfy { KnowledgeShellLogic.isISODate($0.title) }
            let sortedPages = pages.sorted { lhs, rhs in
                if daily {
                    if lhs.title != rhs.title { return lhs.title > rhs.title }
                    return lhs.id < rhs.id
                }
                let cmp = lhs.title.localizedStandardCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }

            let sortedAttachments = attachments.sorted { lhs, rhs in
                let cmp = lhs.filename.localizedStandardCompare(rhs.filename)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }

            return KnowledgeTreeFolder(
                name: name,
                path: path,
                folders: sortedSubfolders,
                pages: sortedPages,
                attachments: sortedAttachments,
                count: count
            )
        }
    }

    /// Builds an Obsidian-style tree from flat page rows (folders first, Inbox prioritized at root, daily notes newest-first),
    /// placing Knowledge attachments in a top-level `attachments` folder when present.
    public static func buildTree(
        from rows: [KnowledgePageRow],
        attachments: [KnowledgeAttachment] = [],
        prioritizeInbox: Bool = true
    ) -> KnowledgeTreeFolder {
        let root = MutableFolder(name: "", path: "")
        for row in rows {
            let segs = row.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            var current = root
            current.count += 1
            if segs.count > 1 {
                for seg in segs.dropLast() {
                    let nextPath = current.path.isEmpty ? seg : "\(current.path)/\(seg)"
                    let child: MutableFolder
                    if let existing = current.folders[seg] {
                        child = existing
                    } else {
                        child = MutableFolder(name: seg, path: nextPath)
                        current.folders[seg] = child
                    }
                    child.count += 1
                    current = child
                }
            }
            current.pages.append(row)
        }
        if !attachments.isEmpty {
            let folderName = attachmentsFolderName
            let target: MutableFolder
            if let existing = root.folders[folderName] {
                target = existing
            } else {
                target = MutableFolder(name: folderName, path: folderName)
                root.folders[folderName] = target
            }
            target.attachments.append(contentsOf: attachments)
            target.count += attachments.count
            root.count += attachments.count
        }
        return root.freeze(depth: 0, prioritizeInbox: prioritizeInbox)
    }

    public static func flattenTree(
        _ root: KnowledgeTreeFolder,
        expanded: Set<String>,
        showAll: Set<String> = [],
        activePageId: String? = nil,
        activeAttachmentId: String? = nil,
        pageCap: Int = defaultPageCapPerFolder
    ) -> [KnowledgeExplorerRow] {
        var out: [KnowledgeExplorerRow] = []

        func walk(_ folder: KnowledgeTreeFolder, depth: Int) {
            for sub in folder.folders {
                out.append(KnowledgeExplorerRow(id: "f:\(sub.path)", depth: depth, kind: .folder(sub)))
                if expanded.contains(sub.path) {
                    walk(sub, depth: depth + 1)
                }
            }
            let cap = max(1, pageCap)
            let showAllHere = showAll.contains(folder.path)
            let visiblePages: [KnowledgePageRow]
            if showAllHere || folder.pages.count <= cap {
                visiblePages = folder.pages
            } else {
                var slice: [KnowledgePageRow] = []
                for (index, page) in folder.pages.enumerated() where index < cap || page.id == activePageId {
                    slice.append(page)
                }
                visiblePages = slice
            }
            for page in visiblePages {
                out.append(KnowledgeExplorerRow(id: "p:\(page.id)", depth: depth, kind: .page(page)))
            }

            let visibleAttachments: [KnowledgeAttachment]
            if showAllHere || folder.attachments.count <= cap {
                visibleAttachments = folder.attachments
            } else {
                var slice: [KnowledgeAttachment] = []
                for (index, att) in folder.attachments.enumerated() where index < cap || att.id == activeAttachmentId {
                    slice.append(att)
                }
                visibleAttachments = slice
            }
            for att in visibleAttachments {
                out.append(KnowledgeExplorerRow(id: "a:\(att.id)", depth: depth, kind: .attachment(att)))
            }

            let hidden = (folder.pages.count - visiblePages.count) + (folder.attachments.count - visibleAttachments.count)
            if hidden > 0 {
                out.append(KnowledgeExplorerRow(
                    id: "more:\(folder.path)",
                    depth: depth,
                    kind: .showMore(folderPath: folder.path, hiddenCount: hidden)
                ))
            }
        }

        walk(root, depth: 0)
        return out
    }

    public static func filterAttachments(_ attachments: [KnowledgeAttachment], matching text: String) -> [KnowledgeAttachment] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return attachments }
        return attachments.filter { att in
            if att.filename.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            if att.path.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            return att.contentType.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public static func filterRows(_ rows: [KnowledgePageRow], matching text: String) -> [KnowledgePageRow] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { row in
            if row.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            if row.path.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            if row.summary.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            return tags(of: row.properties).contains {
                $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    public static func findFolder(at path: String, in root: KnowledgeTreeFolder) -> KnowledgeTreeFolder? {
        let normalized = normalizeFolderPath(path)
        if normalized.isEmpty { return root }
        for sub in root.folders {
            if sub.path == normalized { return sub }
            if normalized.hasPrefix(sub.path + "/"), let hit = findFolder(at: normalized, in: sub) {
                return hit
            }
        }
        return nil
    }

    // MARK: Paths, Slugs, Rename, Duplicate & Drag-to-Move

    public static func slug(_ title: String) -> String {
        var runs: [String] = []
        var current = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.joined(separator: "-")
    }

    public static func pageHref(id: String, title: String = "") -> String {
        let s = slug(title)
        return s.isEmpty ? "/knowledge/\(id)" : "/knowledge/\(id)/\(s)"
    }

    /// Returns the navigation href for a Knowledge explorer row.
    /// Designs and slide decks open in their dedicated full-screen editors so their
    /// layers/thumbnails sidebar and properties inspector own the window chrome
    /// instead of stacking a second panel next to the Knowledge explorer.
    public static func pageHref(for row: KnowledgePageRow) -> String {
        if row.kind == .design, let cid = row.canvasId, !cid.isEmpty {
            return "/apps/designs/\(cid)"
        }
        if row.kind == .deck, let cid = row.canvasId, !cid.isEmpty {
            return "/apps/slides/\(cid)"
        }
        return pageHref(id: row.id, title: row.title)
    }

    public static func normalizeFolderPath(_ path: String) -> String {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/")
    }

    public static func parentOf(_ path: String) -> String {
        let segs = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard segs.count > 1 else { return "" }
        return segs.dropLast().joined(separator: "/")
    }

    public static func nameOf(_ path: String) -> String {
        let segs = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return segs.last ?? path
    }

    public static func joinPath(_ folder: String, _ name: String) -> String {
        let f = normalizeFolderPath(folder)
        let n = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if f.isEmpty { return n }
        if n.isEmpty { return f }
        return "\(f)/\(n)"
    }

    public static func ancestors(of path: String?) -> [String] {
        guard let path else { return [] }
        let segs = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard segs.count > 1 else { return [] }
        return (1..<segs.count).map { segs.prefix($0).joined(separator: "/") }
    }

    public static func folderPaths(in root: KnowledgeTreeFolder) -> [String] {
        var out: [String] = []
        func walk(_ f: KnowledgeTreeFolder) {
            for sub in f.folders {
                out.append(sub.path)
                walk(sub)
            }
        }
        walk(root)
        return out.sorted { lhs, rhs in
            let cmp = lhs.localizedStandardCompare(rhs)
            return cmp == .orderedSame ? lhs < rhs : cmp == .orderedAscending
        }
    }

    public static func nameError(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give it a name."
        }
        if name.contains("/") {
            return "Names can\u{2019}t contain /. Use Move to\u{2026} to put it in another folder."
        }
        return nil
    }

    /// Rewrites `path` when folder `from` moves to `to`; sibling paths with matching prefix (`NPCs2`) stay put.
    public static func movedPath(_ path: String, from: String, to: String) -> String {
        if path == from || path.hasPrefix("\(from)/") {
            return to + String(path.dropFirst(from.count))
        }
        return path
    }

    public static func moveTargets(
        folders: [String],
        path: String,
        isFolder: Bool,
        filter: String = ""
    ) -> [String] {
        let here = parentOf(path)
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ([""] + folders).filter { target in
            guard target != here else { return false }
            if isFolder && (target == path || target.hasPrefix("\(path)/")) {
                return false
            }
            if !q.isEmpty && !target.lowercased().contains(q) {
                return false
            }
            return true
        }
    }

    public static func planDrop(
        item: KnowledgeDragItem,
        ontoFolder destinationFolder: String,
        expanded: Set<String>
    ) -> KnowledgeMovePlan? {
        let dest = normalizeFolderPath(destinationFolder)
        switch item.kind {
        case .page:
            guard parentOf(item.path) != dest else { return nil }
            let newPath = joinPath(dest, nameOf(item.path))
            return .movePage(id: item.id, newPath: newPath, title: nil)
        case .folder:
            guard !item.path.isEmpty else { return nil }
            guard dest != parentOf(item.path) else { return nil }
            guard dest != item.path && !dest.hasPrefix("\(item.path)/") else { return nil }
            let to = joinPath(dest, nameOf(item.path))
            guard to != item.path else { return nil }
            var nextExpanded = Set(expanded.map { movedPath($0, from: item.path, to: to) })
            nextExpanded.formUnion(ancestors(of: to))
            return .moveFolder(from: item.path, to: to, updatedExpanded: nextExpanded)
        }
    }

    public static func planPageRename(page: KnowledgePageRow, newName: String) -> (title: String, path: String)? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nameError(trimmed) == nil else { return nil }
        let base = page.path.isEmpty ? page.title : page.path
        let newPath = joinPath(parentOf(base), trimmed)
        guard trimmed != page.title || newPath != page.path else { return nil }
        return (title: trimmed, path: newPath)
    }

    public static func planFolderRename(
        folderPath: String,
        newName: String,
        expanded: Set<String>
    ) -> (from: String, to: String, updatedExpanded: Set<String>)? {
        let from = normalizeFolderPath(folderPath)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, nameError(trimmed) == nil else { return nil }
        let to = joinPath(parentOf(from), trimmed)
        guard to != from else { return nil }
        let nextExpanded = Set(expanded.map { movedPath($0, from: from, to: to) })
        return (from: from, to: to, updatedExpanded: nextExpanded)
    }

    public static func duplicatePageInput(from page: KnowledgePage, existingPaths: Set<String>) -> KnowledgePageInput {
        let baseTitle = page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = parentOf(page.path ?? "")
        let loweredExisting = Set(existingPaths.map { $0.lowercased() })

        var candidateTitle = "\(baseTitle) copy"
        var candidatePath = joinPath(folder, candidateTitle)
        var n = 2
        while loweredExisting.contains(candidatePath.lowercased()) {
            candidateTitle = "\(baseTitle) copy \(n)"
            candidatePath = joinPath(folder, candidateTitle)
            n += 1
        }

        return KnowledgePageInput(
            title: candidateTitle,
            path: candidatePath,
            bodyMd: page.bodyMd ?? "",
            properties: page.properties.isEmpty ? nil : page.properties,
            audience: page.audience == .shared ? KnowledgeAudience.shared.rawValue : KnowledgeAudience.private.rawValue
        )
    }

    public static func nextUntitledPath(
        in folder: String,
        existingPaths: Set<String>,
        baseName: String = "Untitled"
    ) -> String {
        let cleanFolder = normalizeFolderPath(folder)
        let lowered = Set(existingPaths.map { $0.lowercased() })
        let first = joinPath(cleanFolder, baseName)
        if !lowered.contains(first.lowercased()) { return first }
        var idx = 2
        while lowered.contains(joinPath(cleanFolder, "\(baseName) \(idx)").lowercased()) {
            idx += 1
        }
        return joinPath(cleanFolder, "\(baseName) \(idx)")
    }

    // MARK: Multi-Select & Bulk Plans

    public static func minimalDeletePlan(
        selectedRowIds: Set<String>,
        allPages: [KnowledgePageRow]
    ) -> (folders: [String], pageIds: [String], affectedPageCount: Int) {
        let rawFolders = selectedRowIds
            .filter { $0.hasPrefix("f:") }
            .map { normalizeFolderPath(String($0.dropFirst(2))) }
            .filter { !$0.isEmpty }
            .sorted { $0.count < $1.count }

        var topFolders: [String] = []
        for f in rawFolders {
            let covered = topFolders.contains { f == $0 || f.hasPrefix("\($0)/") }
            if !covered { topFolders.append(f) }
        }
        topFolders.sort()

        let byId = Dictionary(allPages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let pageIds = selectedRowIds
            .filter { $0.hasPrefix("p:") }
            .map { String($0.dropFirst(2)) }
            .filter { id in
                guard let page = byId[id] else { return false }
                return !topFolders.contains { folder in
                    page.path.hasPrefix("\(folder)/") || page.path == folder
                }
            }
            .sorted()

        let folderAffectedIds = Set(allPages.filter { page in
            topFolders.contains { folder in page.path.hasPrefix("\(folder)/") || page.path == folder }
        }.map(\.id))
        let totalAffected = folderAffectedIds.union(pageIds).count

        return (folders: topFolders, pageIds: pageIds, affectedPageCount: totalAffected)
    }

    public static func bulkMovePlan(
        selectedRowIds: Set<String>,
        intoFolder destinationFolder: String,
        allPages: [KnowledgePageRow]
    ) -> (folders: [(from: String, to: String)], pages: [(id: String, path: String)]) {
        let dest = normalizeFolderPath(destinationFolder)
        let rawFolders = selectedRowIds
            .filter { $0.hasPrefix("f:") }
            .map { normalizeFolderPath(String($0.dropFirst(2))) }
            .filter { !$0.isEmpty }
            .sorted { $0.count < $1.count }

        var topFolders: [String] = []
        for f in rawFolders {
            let covered = topFolders.contains { f == $0 || f.hasPrefix("\($0)/") }
            if !covered { topFolders.append(f) }
        }

        let folderMoves: [(from: String, to: String)] = topFolders.compactMap { folder in
            guard dest != parentOf(folder),
                  dest != folder,
                  !dest.hasPrefix("\(folder)/")
            else { return nil }
            let to = joinPath(dest, nameOf(folder))
            return to == folder ? nil : (from: folder, to: to)
        }

        let byId = Dictionary(allPages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let pageMoves: [(id: String, path: String)] = selectedRowIds
            .filter { $0.hasPrefix("p:") }
            .map { String($0.dropFirst(2)) }
            .sorted()
            .compactMap { id in
                guard let page = byId[id] else { return nil }
                let insideMovedFolder = topFolders.contains { folder in
                    page.path.hasPrefix("\(folder)/") || page.path == folder
                }
                guard !insideMovedFolder, parentOf(page.path) != dest else { return nil }
                return (id: id, path: joinPath(dest, nameOf(page.path)))
            }

        return (folders: folderMoves, pages: pageMoves)
    }

    public static func bulkAudienceTargets(
        selectedRowIds: Set<String>,
        allPages: [KnowledgePageRow],
        to audience: KnowledgeAudience
    ) -> [KnowledgePageRow] {
        guard audience == .private || audience == .shared else { return [] }
        let selectedFolderPaths = selectedRowIds
            .filter { $0.hasPrefix("f:") }
            .map { normalizeFolderPath(String($0.dropFirst(2))) }
            .filter { !$0.isEmpty }
        let selectedPageIds = Set(selectedRowIds.filter { $0.hasPrefix("p:") }.map { String($0.dropFirst(2)) })

        return allPages.filter { page in
            guard page.audience != .agent, page.audience != audience else { return false }
            if selectedPageIds.contains(page.id) { return true }
            return selectedFolderPaths.contains { folder in
                page.path.hasPrefix("\(folder)/") || page.path == folder
            }
        }
    }

    // MARK: Property & Tag Parsing

    public static func parsePropertyFilterValue(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            if let i = Int(trimmed) { return .int(i) }
            if let d = Double(trimmed), trimmed.contains(".") { return .double(d) }
            return .string(trimmed)
        }
    }

    public static func tags(of properties: [String: JSONValue]) -> [String] {
        guard let raw = properties["tags"] else { return [] }
        switch raw {
        case .array(let arr):
            return arr.compactMap { item -> String? in
                guard let s = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                var clean = s
                while clean.hasPrefix("#") { clean.removeFirst() }
                return clean.isEmpty ? nil : clean
            }
        case .string(let s):
            return s.split(separator: ",")
                .map { item -> String in
                    var clean = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    while clean.hasPrefix("#") { clean.removeFirst() }
                    return clean
                }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    public static func extractTags(from rows: [KnowledgePageRow]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in rows {
            let unique = Set(tags(of: row.properties))
            for tag in unique {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag.localizedStandardCompare(rhs.tag) == .orderedAscending
            }
    }

    public static func extractPropertyKeys(from rows: [KnowledgePageRow]) -> [String] {
        let hidden: Set<String> = ["query", "zettel_id", "tags"]
        var keys = Set<String>()
        for row in rows {
            for k in row.properties.keys where !hidden.contains(k) {
                keys.insert(k)
            }
        }
        return keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func visibleProperties(_ properties: [String: JSONValue]) -> [(key: String, value: JSONValue)] {
        let hidden: Set<String> = ["query", "zettel_id"]
        return properties
            .filter { key, value in
                guard !hidden.contains(key) else { return false }
                switch value {
                case .null: return false
                case .string(let s): return !s.isEmpty
                case .array(let a): return !a.isEmpty
                default: return true
                }
            }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (key: $0.key, value: $0.value) }
    }

    public static func formatPropertyValue(_ value: JSONValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array(let items): return items.map(formatPropertyValue).filter { !$0.isEmpty }.joined(separator: ", ")
        case .object(let map):
            guard let data = try? JSONEncoder().encode(map), let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }
    }

    // MARK: Home, Start, Connect, Capture & Presentation

    public static func greeting(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    public static func firstName(from fullName: String?) -> String? {
        guard let fullName else { return nil }
        let parts = fullName.split(whereSeparator: \.isWhitespace)
        return parts.first.map(String.init)
    }

    public static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let y = calendar.component(.year, from: date)
        let m = calendar.component(.month, from: date)
        let d = calendar.component(.day, from: date)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func isISODate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let chars = Array(value)
        guard chars[4] == "-", chars[7] == "-" else { return false }
        for (idx, ch) in chars.enumerated() where idx != 4 && idx != 7 {
            if !ch.isASCII || !ch.isNumber { return false }
        }
        return true
    }

    public static func relativeAgo(
        _ iso: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> String {
        guard let date = APIDate.parse(iso) else { return "" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 86400 && calendar.isDate(date, inSameDayAs: now) {
            return "\(Int(elapsed / 3600)) h ago"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d y")
        return formatter.string(from: date)
    }

    public static func isUntitled(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "untitled" || t == "untitled document" { return true }
        let prefix = t.hasPrefix("untitled document ") ? "untitled document " : (t.hasPrefix("untitled ") ? "untitled " : nil)
        guard let prefix else { return false }
        let suffix = String(t.dropFirst(prefix.count))
        return suffix.first?.isNumber == true && suffix.allSatisfy { ($0.isASCII && ($0.isNumber || ("a"..."z").contains($0))) }
    }

    public static func displayTitle(for row: KnowledgePageRow) -> String {
        if isUntitled(row.title), !row.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Untitled \u{00B7} \u{201C}\(row.summary)\u{201D}"
        }
        return row.title.isEmpty ? "Untitled" : row.title
    }

    public static func folderDisplay(of path: String) -> String {
        let p = parentOf(path)
        return p.isEmpty ? "Top level" : p.split(separator: "/").joined(separator: " / ")
    }

    public static func pageSymbol(for row: KnowledgePageRow) -> String {
        pageSymbol(kind: row.kind, hasQuery: row.properties["query"] != nil)
    }

    public static func pageSymbol(kind: KnowledgePageKind, hasQuery: Bool = false) -> String {
        switch kind {
        case .deck: return "play.rectangle"
        case .design: return "pencil.and.ruler"
        case .document: return hasQuery ? "rectangle.split.3x1" : "doc.text"
        }
    }

    public static func homeSummary(
        allPages: [KnowledgePageRow],
        recentPages: [KnowledgePageRow],
        inboxPages: [KnowledgePageRow],
        proposalPages: [KnowledgePageRow],
        network: KnowledgeNetwork? = nil
    ) -> KnowledgeHomeSummary {
        let toReview = allPages.filter { $0.pending > 0 }
        let latest = recentPages.first
        let rest = recentPages.count > 1 ? Array(recentPages.dropFirst()) : []
        var counts: [KnowledgePageKind: Int] = [.document: 0, .deck: 0, .design: 0]
        for row in allPages {
            counts[row.kind, default: 0] += 1
        }
        let orphanCount = allPages.filter { row in
            guard let net = network else { return false }
            let linked = net.links.contains { $0.target != nil && ($0.source == row.id || $0.target == row.id) }
            return !linked
        }.count
        let unresolvedCount = network.map { unresolvedTargets(in: $0).count } ?? 0

        return KnowledgeHomeSummary(
            pagesToReview: toReview,
            inboxCaptures: inboxPages,
            agentProposals: proposalPages,
            latestPage: latest,
            otherRecentPages: rest,
            kindCounts: counts,
            topTags: Array(extractTags(from: allPages).prefix(12)),
            unresolvedCount: unresolvedCount,
            orphanCount: orphanCount
        )
    }

    public static func unresolvedTargets(in network: KnowledgeNetwork) -> [KnowledgeUnresolvedTarget] {
        let nodesById = Dictionary(network.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var order: [String] = []
        var grouped: [String: (name: String, sources: [KnowledgeUnresolvedSource])] = [:]

        for link in network.links {
            guard let unresolved = link.unresolved, !unresolved.isEmpty else { continue }
            let key = unresolved.lowercased()
            var entry = grouped[key] ?? (name: unresolved, sources: [])
            if grouped[key] == nil { order.append(key) }
            if let src = nodesById[link.source], !entry.sources.contains(where: { $0.id == src.id }) {
                entry.sources.append(KnowledgeUnresolvedSource(id: src.id, title: src.title))
            }
            grouped[key] = entry
        }

        return order.compactMap { grouped[$0] }
            .map { KnowledgeUnresolvedTarget(name: $0.name, sources: $0.sources) }
            .sorted { lhs, rhs in
                if lhs.sources.count != rhs.sources.count { return lhs.sources.count > rhs.sources.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: Start & Capture Helpers (web/lib/start.ts & capture.tsx)

    private static let ticketKeyRegex = try? NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]{1,15}-\\d{1,7}\\b")
    private static let deckLeadRegex = try? NSRegularExpression(pattern: "^(make|create|draft|build|write|turn|a deck|slides)\\b", options: .caseInsensitive)
    private static let designLeadRegex = try? NSRegularExpression(pattern: "^(make|create|draft|design|build|turn|sketch|map|diagram)\\b", options: .caseInsensitive)
    private static let bulletPrefixRegex = try? NSRegularExpression(pattern: "^([-*\u{2022}]|\\d+[.)])\\s+")

    public static func isDeckBrief(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.split(whereSeparator: \.isWhitespace).count > 8 { return true }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        return deckLeadRegex?.firstMatch(in: t, range: range) != nil
    }

    public static func isDesignBrief(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.split(whereSeparator: \.isWhitespace).count > 6 { return true }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        if ticketKeyRegex?.firstMatch(in: t, range: range) != nil { return true }
        return designLeadRegex?.firstMatch(in: t, range: range) != nil
    }

    public static func designBriefTitle(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        guard let match = ticketKeyRegex?.firstMatch(in: t, range: range),
              let swiftRange = Range(match.range, in: t)
        else { return "" }
        return String(t[swiftRange])
    }

    public static func splitOutline(_ outline: String, title: String) -> (title: String, slides: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return (title: trimmedTitle, slides: outline.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let lines = outline.components(separatedBy: .newlines)
        guard let firstIdx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return (title: "", slides: "")
        }
        let firstLine = lines[firstIdx].trimmingCharacters(in: .whitespacesAndNewlines)
        let nsRange = NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
        let stripped: String
        if let match = bulletPrefixRegex?.firstMatch(in: firstLine, range: nsRange),
           let range = Range(match.range, in: firstLine) {
            stripped = String(firstLine[range.upperBound...])
        } else {
            stripped = firstLine
        }
        let rest = lines.dropFirst(firstIdx + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title: String(stripped.prefix(200)), slides: rest)
    }

    public static func namedTemplates(from templates: [String: String]) -> [String] {
        templates.keys
            .filter { $0 != "Daily" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func captureInput(from rawText: String) -> KnowledgePageInput? {
        let t = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lines = t.components(separatedBy: .newlines)
        let first = lines[0]
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = !rest.isEmpty ? rest : (first.count > 120 ? t : "")
        return KnowledgePageInput(title: String(first.prefix(120)), bodyMd: body)
    }

    // MARK: Page Editor Seam (LAZYAGENTS-288)

    /// Chooses the hosted or native view for a `KnowledgePage`:
    /// - `.deck` -> `/apps/slides/<canvasId>`
    /// - `.design` -> `/apps/designs/<canvasId>`
    /// - standalone PDF embed page -> native `PDFViewerView`
    /// - legacy Doc with `canvasId` and empty markdown body -> `/apps/docs/<canvasId>`
    /// - all other Knowledge pages -> `/knowledge/<id>?embed=1`
    public static func editorTarget(
        for page: KnowledgePage,
        query: [String: String] = [:]
    ) -> KnowledgePageContentTarget {
        let forwardedKeys = ["brief", "outline", "review"]
        let forwardedItems: [URLQueryItem] = forwardedKeys.compactMap { key in
            guard let val = query[key], !val.isEmpty else { return nil }
            return URLQueryItem(name: key, value: val)
        }
        let encodedForward = APIQuery.encode(forwardedItems)

        if page.kind == .deck, let cid = page.canvasId, !cid.isEmpty {
            let path = "/apps/slides/\(cid)" + (encodedForward.isEmpty ? "" : "?\(encodedForward)")
            return .deck(canvasId: cid, hostedPath: path)
        }
        if page.kind == .design, let cid = page.canvasId, !cid.isEmpty {
            let path = "/apps/designs/\(cid)" + (encodedForward.isEmpty ? "" : "?\(encodedForward)")
            return .design(canvasId: cid, hostedPath: path)
        }

        let pdfEmbeds = page.embeds.filter { embed in
            guard embed.available,
                  let url = embed.url,
                  url.hasPrefix("/api/v1/"),
                  !url.contains("..")
            else { return false }
            let ct = embed.contentType?.lowercased() ?? ""
            return ct.contains("pdf") || url.lowercased().hasSuffix(".pdf")
        }
        let trimmedBody = (page.bodyMd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pdfEmbeds.count == 1, let pdf = pdfEmbeds.first, let url = pdf.url {
            let isOnlyThatEmbed = trimmedBody.isEmpty
                || (!trimmedBody.contains("\n") && trimmedBody.hasPrefix("![[\(pdf.ref)") && trimmedBody.hasSuffix("]]"))
            if isOnlyThatEmbed {
                let rawTitle = pdf.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = rawTitle.isEmpty ? (page.title.isEmpty ? "PDF" : page.title) : rawTitle
                return .pdf(sourcePath: url, title: title)
            }
        }

        if page.kind == .document, let cid = page.canvasId, !cid.isEmpty, trimmedBody.isEmpty {
            return .hostedPage(hostedPath: "/apps/docs/\(cid)")
        }

        let base = "/knowledge/\(page.id)?embed=1"
        let full = encodedForward.isEmpty ? base : "\(base)&\(encodedForward)"
        return .hostedPage(hostedPath: full)
    }

    // MARK: Obsidian Vault Import Helpers

    public static func normalizeImportFolder(_ raw: String) -> String {
        normalizeFolderPath(raw)
    }

    public static func importStep(for job: KnowledgeImportJob?) -> KnowledgeImportStep {
        guard let job else { return .upload }
        switch job.state {
        case "queued", "scanning", "preview":
            return .review
        default:
            return .importing
        }
    }

    public static func isImportPolling(_ job: KnowledgeImportJob?) -> Bool {
        guard let state = job?.state else { return false }
        return ["queued", "scanning", "queued_commit", "importing"].contains(state)
    }

    public static func classifyImportEntry(_ entry: KnowledgeVaultEntry) -> KnowledgeImportEntryClassification {
        if let err = entry.error, !err.isEmpty {
            return KnowledgeImportEntryClassification(filter: .skipped, note: err, symbol: "xmark.circle", tone: .danger)
        }
        if entry.conflict == true {
            return KnowledgeImportEntryClassification(
                filter: .conflicts,
                note: "Already in Knowledge, edited since",
                symbol: "exclamationmark.triangle",
                tone: .warning
            )
        }
        if entry.renamed == true {
            let fromNote = entry.originalTitle.map { " from \u{201C}\($0)\u{201D}" } ?? ""
            return KnowledgeImportEntryClassification(
                filter: .renamed,
                note: "Renamed\(fromNote); the old name is kept as an alias",
                symbol: "pencil",
                tone: .human
            )
        }
        if entry.unsupported == true {
            return KnowledgeImportEntryClassification(
                filter: .files,
                note: "Not converted; kept as an attachment",
                symbol: "doc",
                tone: .neutral
            )
        }
        if entry.kind == "attachment" {
            return KnowledgeImportEntryClassification(
                filter: .all,
                note: "Attachment",
                symbol: "paperclip",
                tone: .neutral
            )
        }
        let note: String
        if entry.daily == true {
            note = "Daily note"
        } else {
            note = (entry.tags ?? []).map { "#\($0)" }.joined(separator: " ")
        }
        return KnowledgeImportEntryClassification(filter: .all, note: note, symbol: "checkmark.circle", tone: .done)
    }

    public static func importFilterCounts(plan: KnowledgeVaultPlan?) -> [KnowledgeImportFilter: Int] {
        var counts: [KnowledgeImportFilter: Int] = [
            .all: plan?.entries.count ?? 0,
            .renamed: 0,
            .conflicts: 0,
            .unresolved: plan?.unresolved.count ?? 0,
            .files: 0,
            .skipped: 0,
        ]
        for entry in plan?.entries ?? [] {
            let f = classifyImportEntry(entry).filter
            if f != .all { counts[f, default: 0] += 1 }
        }
        return counts
    }

    public static func filteredImportEntries(
        plan: KnowledgeVaultPlan?,
        filter: KnowledgeImportFilter
    ) -> [KnowledgeVaultEntry] {
        let entries = plan?.entries ?? []
        guard filter != .all && filter != .unresolved else { return entries }
        return entries.filter { classifyImportEntry($0).filter == filter }
    }

    public static func importReportSummary(job: KnowledgeImportJob) -> KnowledgeImportReportSummary {
        let report = job.report ?? []
        var createdOrUpdated = 0
        var unchanged = 0
        var conflicts = 0
        var skippedOrFailed = 0
        var failures: [KnowledgeImportResult] = []
        for item in report {
            switch item.status {
            case "created", "updated":
                createdOrUpdated += 1
            case "unchanged":
                unchanged += 1
            case "conflict":
                conflicts += 1
            case "skipped", "failed":
                skippedOrFailed += 1
                failures.append(item)
            default:
                break
            }
        }
        return KnowledgeImportReportSummary(
            createdOrUpdated: createdOrUpdated,
            unchanged: unchanged,
            conflicts: conflicts,
            skippedOrFailed: skippedOrFailed,
            failures: failures
        )
    }

    public static func formatByteCount(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
        }
        let mb = max(1, Int((Double(bytes) / 1_000_000.0).rounded()))
        return "\(mb) MB"
    }
}
