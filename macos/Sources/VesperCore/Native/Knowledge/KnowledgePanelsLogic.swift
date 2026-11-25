import Foundation

// MARK: - Backlinks & Unlinked Mentions

public struct KnowledgeBacklinkItem: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var path: String
    public var audience: KnowledgeAudience

    public init(id: String, title: String, path: String, audience: KnowledgeAudience = .private) {
        self.id = id
        self.title = title
        self.path = path
        self.audience = audience
    }
}

public struct KnowledgeUnlinkedMention: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(pageId)::\(matchedTerm.lowercased())" }
    public var pageId: String
    public var pageTitle: String
    public var pagePath: String
    public var matchedTerm: String
    public var snippet: String

    public init(pageId: String, pageTitle: String, pagePath: String, matchedTerm: String, snippet: String) {
        self.pageId = pageId
        self.pageTitle = pageTitle
        self.pagePath = pagePath
        self.matchedTerm = matchedTerm
        self.snippet = snippet
    }
}

// MARK: - Typed Properties Model

public enum KnowledgePropertyType: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case text = "Text"
    case number = "Number"
    case bool = "Boolean"
    case date = "Date"
    case list = "List"

    public var id: String { rawValue }
}

public struct KnowledgePropertyField: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var type: KnowledgePropertyType
    public var value: JSONValue

    public init(key: String, type: KnowledgePropertyType, value: JSONValue) {
        self.key = key
        self.type = type
        self.value = value
    }
}

// MARK: - Query Table Sorting

public enum KnowledgeQuerySortColumn: Sendable, Equatable, Hashable {
    case title
    case audience
    case updatedAt
    case property(String)
}

public enum KnowledgeQuerySortDirection: String, Sendable, Equatable, Hashable {
    case ascending
    case descending

    public var toggled: KnowledgeQuerySortDirection {
        self == .ascending ? .descending : .ascending
    }
}

// MARK: - Diff & Review Models

public enum KnowledgeDiffLineKind: String, Sendable, Equatable, Hashable {
    case unchanged
    case removed
    case added
}

public struct KnowledgeDiffSegment: Sendable, Equatable, Hashable {
    public var text: String
    public var isChanged: Bool

    public init(text: String, isChanged: Bool) {
        self.text = text
        self.isChanged = isChanged
    }
}

public struct KnowledgeDiffLine: Sendable, Equatable, Identifiable {
    public var id: Int
    public var kind: KnowledgeDiffLineKind
    public var text: String
    public var segments: [KnowledgeDiffSegment]

    public init(id: Int, kind: KnowledgeDiffLineKind, text: String, segments: [KnowledgeDiffSegment] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.segments = segments
    }
}

public struct KnowledgePendingChange: Sendable, Equatable, Identifiable {
    public var id: String { "\(reviewId):\(changeIndex)" }
    public var reviewId: String
    public var changeIndex: Int
    public var change: KnowledgePageChange
    public var authorId: String
    public var createdAt: String
    public var isStale: Bool

    public init(
        reviewId: String,
        changeIndex: Int,
        change: KnowledgePageChange,
        authorId: String,
        createdAt: String,
        isStale: Bool
    ) {
        self.reviewId = reviewId
        self.changeIndex = changeIndex
        self.change = change
        self.authorId = authorId
        self.createdAt = createdAt
        self.isStale = isStale
    }
}

// MARK: - KnowledgePanelsLogic

public enum KnowledgePanelsLogic: Sendable {
    private static let hiddenPropertyKeys: Set<String> = ["tags", "query", "zettel_id", "title"]
    private static let hiddenQueryColumns: Set<String> = ["tags", "aliases", "query", "zettel_id", "title"]

    // MARK: Backlinks & Mentions

    public static func backlinks(for pageId: String, in network: KnowledgeNetwork) -> [KnowledgeBacklinkItem] {
        let byId = Dictionary(network.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen: Set<String> = []
        var items: [KnowledgeBacklinkItem] = []
        for link in network.links where link.target == pageId && link.source != pageId {
            guard seen.insert(link.source).inserted, let node = byId[link.source] else { continue }
            items.append(KnowledgeBacklinkItem(id: node.id, title: node.title, path: node.path, audience: node.audience))
        }
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public static func outgoingLinks(
        for pageId: String,
        in network: KnowledgeNetwork
    ) -> (resolved: [KnowledgeBacklinkItem], unresolved: [String]) {
        let byId = Dictionary(network.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seenResolved: Set<String> = []
        var resolved: [KnowledgeBacklinkItem] = []
        var seenUnresolved: Set<String> = []
        var unresolved: [String] = []
        for link in network.links where link.source == pageId {
            if let target = link.target, target != pageId, seenResolved.insert(target).inserted, let node = byId[target] {
                resolved.append(KnowledgeBacklinkItem(id: node.id, title: node.title, path: node.path, audience: node.audience))
            } else if let missing = link.unresolved, !missing.isEmpty, seenUnresolved.insert(missing.lowercased()).inserted {
                unresolved.append(missing)
            }
        }
        resolved.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        unresolved.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (resolved, unresolved)
    }

    public static func mentionTerms(for page: KnowledgePage) -> [String] {
        var terms: [String] = []
        let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count >= 2 && !KnowledgeShellLogic.isUntitled(title) {
            terms.append(title)
        }
        if let aliases = page.properties["aliases"] {
            switch aliases {
            case .array(let items):
                for item in items {
                    if case .string(let s) = item {
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.count >= 2 { terms.append(trimmed) }
                    }
                }
            case .string(let s):
                for part in s.split(separator: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 2 { terms.append(trimmed) }
                }
            default:
                break
            }
        }
        var seen: Set<String> = []
        return terms
            .sorted { $0.count > $1.count }
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public static func findUnlinkedMentions(
        of targetPage: KnowledgePage,
        in candidates: [KnowledgePageRow],
        linkedSourceIds: Set<String>
    ) -> [KnowledgeUnlinkedMention] {
        let terms = mentionTerms(for: targetPage)
        guard !terms.isEmpty else { return [] }

        var mentions: [KnowledgeUnlinkedMention] = []
        for row in candidates {
            if row.id == targetPage.id || linkedSourceIds.contains(row.id) { continue }
            let haystack = row.summary
            guard !haystack.isEmpty else { continue }
            for term in terms {
                if let range = firstUnlinkedMatchRange(of: term, in: haystack) {
                    let snippet = excerpt(around: range, in: haystack)
                    mentions.append(KnowledgeUnlinkedMention(
                        pageId: row.id,
                        pageTitle: row.title,
                        pagePath: row.path,
                        matchedTerm: term,
                        snippet: snippet
                    ))
                    break
                }
            }
        }
        return mentions.sorted { $0.pageTitle.localizedCaseInsensitiveCompare($1.pageTitle) == .orderedAscending }
    }

    /// Replaces the first unlinked whole-word occurrence of `term` outside `[[...]]` and inline code.
    public static func linkFirstMention(in markdown: String, term: String, targetTitle: String) -> String? {
        let trimmedTarget = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTarget.isEmpty, let range = firstUnlinkedMatchRange(of: term, in: markdown) else {
            return nil
        }
        let matched = String(markdown[range])
        let replacement = matched.caseInsensitiveCompare(trimmedTarget) == .orderedSame
            ? "[[\(trimmedTarget)]]"
            : "[[\(trimmedTarget)|\(matched)]]"
        var updated = markdown
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    private static func firstUnlinkedMatchRange(of term: String, in text: String) -> Range<String.Index>? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])", options: [.caseInsensitive]) else {
            return nil
        }
        let protected = protectedRanges(in: text)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            if !protected.contains(where: { $0.overlaps(range) }) {
                return range
            }
        }
        return nil
    }

    private static func protectedRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let patterns = [
            "\\[\\[[^\\]]+\\]\\]",
            "`[^`]+`",
            "\\[[^\\]]+\\]\\([^\\)]+\\)",
        ]
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: nsRange) {
                if let range = Range(match.range, in: text) {
                    ranges.append(range)
                }
            }
        }
        return ranges
    }

    private static func excerpt(around range: Range<String.Index>, in text: String, radius: Int = 42) -> String {
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start > text.startIndex ? "…" : ""
        let suffix = end < text.endIndex ? "…" : ""
        let body = text[start..<end]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)\(body)\(suffix)"
    }

    // MARK: Typed Properties Inspector

    public static func inferPropertyType(_ value: JSONValue) -> KnowledgePropertyType {
        switch value {
        case .bool: return .bool
        case .int, .double: return .number
        case .array: return .list
        case .string(let s):
            return KnowledgeShellLogic.isISODate(s) ? .date : .text
        case .null, .object:
            return .text
        }
    }

    public static func editableProperties(from properties: [String: JSONValue]) -> [KnowledgePropertyField] {
        properties
            .filter { !hiddenPropertyKeys.contains($0.key) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { key, value in
                KnowledgePropertyField(key: key, type: inferPropertyType(value), value: value)
            }
    }

    public static func parsePropertyValue(_ raw: String, as type: KnowledgePropertyType) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .text, .date:
            return .string(trimmed)
        case .number:
            if let i = Int(trimmed) { return .int(i) }
            if let d = Double(trimmed) { return .double(d) }
            return .double(0)
        case .bool:
            let lowered = trimmed.lowercased()
            return .bool(lowered == "true" || lowered == "1" || lowered == "yes")
        case .list:
            let items = trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { JSONValue.string($0) }
            return .array(items)
        }
    }

    public static func settingProperty(
        _ key: String,
        value: JSONValue,
        in properties: [String: JSONValue]
    ) -> [String: JSONValue] {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { return properties }
        var next = properties
        next[cleanKey] = value
        return next
    }

    public static func removingProperty(_ key: String, from properties: [String: JSONValue]) -> [String: JSONValue] {
        var next = properties
        next.removeValue(forKey: key)
        return next
    }

    public static func addingTag(_ rawTag: String, to properties: [String: JSONValue]) -> [String: JSONValue] {
        let cleaned = rawTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return properties }
        var tags = KnowledgeShellLogic.tags(of: properties)
        if !tags.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            tags.append(cleaned)
        }
        var next = properties
        next["tags"] = .array(tags.map { .string($0) })
        return next
    }

    public static func removingTag(_ tag: String, from properties: [String: JSONValue]) -> [String: JSONValue] {
        let tags = KnowledgeShellLogic.tags(of: properties)
            .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
        var next = properties
        if tags.isEmpty {
            next.removeValue(forKey: "tags")
        } else {
            next["tags"] = .array(tags.map { .string($0) })
        }
        return next
    }

    // MARK: Query Table Columns, Formatting, Filtering & Sorting

    public static func queryTableColumns(for rows: [KnowledgePageRow], maxColumns: Int = 4) -> [String] {
        var counts: [String: Int] = [:]
        for row in rows {
            for key in row.properties.keys where !hiddenQueryColumns.contains(key) {
                counts[key, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(max(0, maxColumns))
            .map(\.key)
    }

    public static func unlinkWikiText(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]") else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: out) else { continue }
            let replacement: String
            if match.range(at: 2).location != NSNotFound, let labelRange = Range(match.range(at: 2), in: out) {
                replacement = String(out[labelRange])
            } else if let targetRange = Range(match.range(at: 1), in: out) {
                let target = String(out[targetRange])
                replacement = target.split(separator: "/").last.map(String.init) ?? target
            } else {
                replacement = ""
            }
            out.replaceSubrange(fullRange, with: replacement)
        }
        return out
    }

    public static func formatQueryCell(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "—" }
        switch value {
        case .string(let s):
            return unlinkWikiText(s)
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return "\(i)"
        case .double(let d):
            return d.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", d) : "\(d)"
        case .array(let items):
            return items.map { formatQueryCell($0) }.joined(separator: ", ")
        case .object:
            if let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{}"
        case .null:
            return "—"
        }
    }

    public static func filterAndSortQueryRows(
        _ rows: [KnowledgePageRow],
        filterText: String,
        sortColumn: KnowledgeQuerySortColumn,
        direction: KnowledgeQuerySortDirection
    ) -> [KnowledgePageRow] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? rows : rows.filter { row in
            if row.title.lowercased().contains(query) || row.path.lowercased().contains(query) {
                return true
            }
            if KnowledgeShellLogic.tags(of: row.properties).contains(where: { $0.lowercased().contains(query) }) {
                return true
            }
            return row.properties.values.contains { formatQueryCell($0).lowercased().contains(query) }
        }

        return filtered.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sortColumn {
            case .title:
                order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            case .audience:
                order = lhs.audience.rawValue.localizedCaseInsensitiveCompare(rhs.audience.rawValue)
            case .updatedAt:
                order = lhs.updatedAt.compare(rhs.updatedAt)
            case .property(let key):
                let a = formatQueryCell(lhs.properties[key])
                let b = formatQueryCell(rhs.properties[key])
                order = a.localizedCaseInsensitiveCompare(b)
            }
            if order == .orderedSame {
                return lhs.id < rhs.id
            }
            return direction == .ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    // MARK: Line & Word Diff Engine + Review Decisions

    public static func diffLines(before: String, after: String) -> [KnowledgeDiffLine] {
        let oldLines = before.isEmpty ? [] : before.components(separatedBy: "\n")
        let newLines = after.isEmpty ? [] : after.components(separatedBy: "\n")
        let ops = lcsDiff(oldLines, newLines)

        var result: [KnowledgeDiffLine] = []
        var idx = 0
        while idx < ops.count {
            if case .removed(let oldText) = ops[idx],
               idx + 1 < ops.count,
               case .added(let newText) = ops[idx + 1] {
                let wordDiff = diffWords(before: oldText, after: newText)
                result.append(KnowledgeDiffLine(id: result.count, kind: .removed, text: oldText, segments: wordDiff.before))
                result.append(KnowledgeDiffLine(id: result.count, kind: .added, text: newText, segments: wordDiff.after))
                idx += 2
            } else {
                switch ops[idx] {
                case .unchanged(let text):
                    result.append(KnowledgeDiffLine(id: result.count, kind: .unchanged, text: text, segments: [KnowledgeDiffSegment(text: text, isChanged: false)]))
                case .removed(let text):
                    result.append(KnowledgeDiffLine(id: result.count, kind: .removed, text: text, segments: [KnowledgeDiffSegment(text: text, isChanged: true)]))
                case .added(let text):
                    result.append(KnowledgeDiffLine(id: result.count, kind: .added, text: text, segments: [KnowledgeDiffSegment(text: text, isChanged: true)]))
                }
                idx += 1
            }
        }
        return result
    }

    public static func diffWords(before: String, after: String) -> (before: [KnowledgeDiffSegment], after: [KnowledgeDiffSegment]) {
        let oldTokens = tokenizeWords(before)
        let newTokens = tokenizeWords(after)
        let ops = lcsDiff(oldTokens, newTokens)
        var beforeSegs: [KnowledgeDiffSegment] = []
        var afterSegs: [KnowledgeDiffSegment] = []

        func append(_ text: String, changed: Bool, to list: inout [KnowledgeDiffSegment]) {
            if let last = list.last, last.isChanged == changed {
                list[list.count - 1].text += text
            } else {
                list.append(KnowledgeDiffSegment(text: text, isChanged: changed))
            }
        }

        for op in ops {
            switch op {
            case .unchanged(let tok):
                append(tok, changed: false, to: &beforeSegs)
                append(tok, changed: false, to: &afterSegs)
            case .removed(let tok):
                append(tok, changed: true, to: &beforeSegs)
            case .added(let tok):
                append(tok, changed: true, to: &afterSegs)
            }
        }
        return (beforeSegs, afterSegs)
    }

    private enum DiffOp<T> {
        case unchanged(T)
        case removed(T)
        case added(T)
    }

    private static func lcsDiff<T: Equatable>(_ a: [T], _ b: [T]) -> [DiffOp<T>] {
        let m = a.count
        let n = b.count
        if m == 0 { return b.map { .added($0) } }
        if n == 0 { return a.map { .removed($0) } }

        // Guard against quadratic blowup on huge inputs by falling back to whole-block replacement.
        if m * n > 250_000 {
            return a.map { .removed($0) } + b.map { .added($0) }
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var ops: [DiffOp<T>] = []
        var i = 0
        var j = 0
        while i < m && j < n {
            if a[i] == b[j] {
                ops.append(.unchanged(a[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.removed(a[i]))
                i += 1
            } else {
                ops.append(.added(b[j]))
                j += 1
            }
        }
        while i < m {
            ops.append(.removed(a[i]))
            i += 1
        }
        while j < n {
            ops.append(.added(b[j]))
            j += 1
        }
        return ops
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for ch in text {
            let isSpace = ch.isWhitespace
            if let prev = currentIsSpace, prev != isSpace {
                tokens.append(current)
                current = String(ch)
                currentIsSpace = isSpace
            } else {
                current.append(ch)
                currentIsSpace = isSpace
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    public static func pendingChanges(in page: KnowledgePage) -> [KnowledgePendingChange] {
        var items: [KnowledgePendingChange] = []
        for review in page.reviews {
            for (offset, change) in review.changes.enumerated() {
                let state = (change.state ?? "").lowercased()
                guard state == "pending" || state == "stale" else { continue }
                items.append(KnowledgePendingChange(
                    reviewId: review.id,
                    changeIndex: change.index ?? offset,
                    change: change,
                    authorId: review.authorId,
                    createdAt: review.createdAt,
                    isStale: state == "stale"
                ))
            }
        }
        return items
    }

    public static func pastReviews(in page: KnowledgePage) -> [KnowledgeReview] {
        page.reviews.filter { review in
            !review.changes.contains { c in
                let s = (c.state ?? "").lowercased()
                return s == "pending" || s == "stale"
            }
        }
    }

    public static func bulkDecisions(
        for page: KnowledgePage,
        accept: Bool
    ) -> [(reviewId: String, decisions: [KnowledgeReviewDecision])] {
        var batches: [(reviewId: String, decisions: [KnowledgeReviewDecision])] = []
        for review in page.reviews {
            let decisions: [KnowledgeReviewDecision] = review.changes.enumerated().compactMap { offset, change in
                guard (change.state ?? "").lowercased() == "pending" else { return nil }
                return KnowledgeReviewDecision(index: change.index ?? offset, accept: accept)
            }
            if !decisions.isEmpty {
                batches.append((review.id, decisions))
            }
        }
        return batches
    }

    public static func singleDecision(
        for item: KnowledgePendingChange,
        accept: Bool,
        reason: String? = nil
    ) -> KnowledgeReviewDecision {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalReason = accept ? nil : (trimmed?.isEmpty == false ? trimmed : nil)
        return KnowledgeReviewDecision(index: item.changeIndex, accept: accept, reason: finalReason)
    }
}
