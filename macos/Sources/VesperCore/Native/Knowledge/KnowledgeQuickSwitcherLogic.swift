import Foundation

// MARK: - Knowledge Quick Switcher Models

public enum KnowledgeQuickSwitcherScope: String, Sendable, CaseIterable, Hashable, Identifiable {
    case all = "All"
    case pages = "Docs"
    case headings = "Headings"
    case attachments = "Attachments"

    public var id: String { rawValue }
}

public enum KnowledgeQuickSwitcherTarget: Sendable, Equatable, Hashable {
    case page(KnowledgePageRow)
    case currentHeading(pageId: String, pageTitle: String, heading: KnowledgeOutlineHeading)
    case vaultHeading(KnowledgeHeadingRow)
    case attachment(KnowledgeAttachment)
}

public struct KnowledgeQuickSwitcherItem: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let scope: KnowledgeQuickSwitcherScope
    public let title: String
    public let subtitle: String
    public let badge: String?
    public let target: KnowledgeQuickSwitcherTarget

    public init(
        id: String,
        scope: KnowledgeQuickSwitcherScope,
        title: String,
        subtitle: String,
        badge: String? = nil,
        target: KnowledgeQuickSwitcherTarget
    ) {
        self.id = id
        self.scope = scope
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.target = target
    }
}

// MARK: - Fuzzy Ranking Logic

/// Pure Foundation fuzzy search & ranking engine for Knowledge Quick Switcher (`⌘O` / `⌘K`):
/// searches across docs, current-page live headings, cross-doc headings, and `attachments/`.
public enum KnowledgeQuickSwitcherLogic: Sendable {
    /// Parses optional scope prefix shortcuts (`#query` -> headings, `!query` -> attachments).
    public static func parseQuery(
        _ raw: String,
        selectedScope: KnowledgeQuickSwitcherScope
    ) -> (scope: KnowledgeQuickSwitcherScope, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if selectedScope == .all {
            if trimmed.hasPrefix("#") {
                return (.headings, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            if trimmed.hasPrefix("!") {
                return (.attachments, String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return (selectedScope, trimmed)
    }

    public static func search(
        query rawQuery: String,
        scope selectedScope: KnowledgeQuickSwitcherScope = .all,
        pages: [KnowledgePageRow],
        attachments: [KnowledgeAttachment],
        vaultHeadings: [KnowledgeHeadingRow] = [],
        currentPageId: String? = nil,
        currentPageTitle: String? = nil,
        currentHeadings: [KnowledgeOutlineHeading] = [],
        limit: Int = 40
    ) -> [KnowledgeQuickSwitcherItem] {
        let parsed = parseQuery(rawQuery, selectedScope: selectedScope)
        let effectiveScope = parsed.scope
        let q = parsed.text.lowercased()

        var scored: [(item: KnowledgeQuickSwitcherItem, score: Int, order: Int)] = []
        var order = 0

        // 1. Docs / Pages
        if effectiveScope == .all || effectiveScope == .pages {
            for page in pages {
                let title = KnowledgeShellLogic.displayTitle(for: page)
                let folder = KnowledgeShellLogic.folderDisplay(of: page.path)
                let tags = KnowledgeShellLogic.tags(of: page.properties).map { "#\($0)" }
                let subtitle = ([folder] + tags.prefix(3)).joined(separator: " \u{00B7} ")
                let badge: String? = switch page.kind {
                case .deck: "Deck"
                case .design: "Design"
                case .document: page.id == currentPageId ? "Open" : nil
                }

                let score: Int?
                if q.isEmpty {
                    score = page.id == currentPageId ? 450 : 500
                } else {
                    score = bestScore(
                        query: q,
                        primary: title,
                        secondary: page.path,
                        extra: tags.joined(separator: " ") + " " + page.summary
                    )
                }
                if let score {
                    scored.append((
                        KnowledgeQuickSwitcherItem(
                            id: "page:\(page.id)",
                            scope: .pages,
                            title: title,
                            subtitle: subtitle,
                            badge: badge,
                            target: .page(page)
                        ),
                        score,
                        order
                    ))
                    order += 1
                }
            }
        }

        // 2. Headings (live current-doc headings + cross-doc server headings)
        if effectiveScope == .all || effectiveScope == .headings {
            if let currentPageId {
                let pageLabel = (currentPageTitle?.isEmpty == false ? currentPageTitle! : "Current doc")
                for heading in currentHeadings {
                    let score: Int?
                    if q.isEmpty {
                        // In "All" mode with empty query, keep current-doc headings right after pages;
                        // in Headings mode (or `#`), surface them at the very top.
                        score = effectiveScope == .headings ? 700 : 320
                    } else if let s = bestScore(query: q, primary: heading.text, secondary: pageLabel, extra: "h\(heading.level)") {
                        score = s + 60 // Slight boost for headings in the currently open doc.
                    } else {
                        score = nil
                    }
                    if let score {
                        scored.append((
                            KnowledgeQuickSwitcherItem(
                                id: "cur-heading:\(currentPageId):\(heading.index):\(heading.text)",
                                scope: .headings,
                                title: heading.text,
                                subtitle: "\(pageLabel) \u{00B7} Current doc",
                                badge: "H\(heading.level)",
                                target: .currentHeading(pageId: currentPageId, pageTitle: pageLabel, heading: heading)
                            ),
                            score,
                            order
                        ))
                        order += 1
                    }
                }
            }

            // Cross-doc headings (skip the currently open page since live headings above are fresher).
            for h in vaultHeadings where h.pageId != currentPageId {
                let pageName = h.pageTitle.isEmpty ? KnowledgeShellLogic.nameOf(h.pagePath) : h.pageTitle
                let subtitle = h.pagePath.isEmpty ? pageName : h.pagePath
                let score: Int?
                if q.isEmpty {
                    // Only show cross-doc headings when specifically browsing Headings or searching.
                    score = effectiveScope == .headings ? 450 : nil
                } else {
                    score = bestScore(query: q, primary: h.heading, secondary: pageName, extra: h.pagePath)
                }
                if let score {
                    scored.append((
                        KnowledgeQuickSwitcherItem(
                            id: "heading:\(h.id)",
                            scope: .headings,
                            title: h.heading,
                            subtitle: subtitle,
                            badge: "H\(h.level)",
                            target: .vaultHeading(h)
                        ),
                        score,
                        order
                    ))
                    order += 1
                }
            }
        }

        // 3. Attachments
        if effectiveScope == .all || effectiveScope == .attachments {
            for att in attachments {
                let subtitle = "\(att.path) \u{00B7} \(att.usageSummary)"
                let score: Int?
                if q.isEmpty {
                    score = effectiveScope == .attachments ? 600 : 360
                } else {
                    score = bestScore(
                        query: q,
                        primary: att.filename,
                        secondary: att.path,
                        extra: "\(att.contentType) \(att.usageSummary)"
                    )
                }
                if let score {
                    scored.append((
                        KnowledgeQuickSwitcherItem(
                            id: "att:\(att.id)",
                            scope: .attachments,
                            title: att.filename,
                            subtitle: subtitle,
                            badge: att.isOrphaned ? "Unused" : nil,
                            target: .attachment(att)
                        ),
                        score,
                        order
                    ))
                    order += 1
                }
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.title.count != rhs.item.title.count { return lhs.item.title.count < rhs.item.title.count }
            return lhs.order < rhs.order
        }

        let capped = max(0, limit)
        return Array(scored.prefix(capped).map(\.item))
    }

    // MARK: - Fuzzy Scoring

    private static func bestScore(query: String, primary: String, secondary: String, extra: String) -> Int? {
        let p = primary.lowercased()
        let s = secondary.lowercased()
        let e = extra.lowercased()

        if p == query { return 1000 }
        if p.hasPrefix(query) { return 880 }
        if hasWordPrefix(in: p, query: query) { return 760 }
        if p.contains(query) { return 660 }
        if s.hasPrefix(query) || hasWordPrefix(in: s, query: query) { return 560 }
        if s.contains(query) { return 480 }
        if let subBonus = subsequenceScore(query, in: p) { return 340 + subBonus }
        if let subBonus = subsequenceScore(query, in: s) { return 240 + subBonus }
        if !e.isEmpty && e.contains(query) { return 180 }

        // Multi-token AND match across combined text (e.g. "dnd ambush" matches title + path).
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1 {
            let combined = "\(p) \(s) \(e)"
            if words.allSatisfy({ combined.contains($0) }) {
                return 520
            }
        }
        return nil
    }

    private static func hasWordPrefix(in haystack: String, query: String) -> Bool {
        haystack.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { !$0.isEmpty && $0.hasPrefix(query) }
    }

    private static func subsequenceScore(_ needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty else { return nil }
        var nIdx = needle.startIndex
        var consecutive = 0
        var maxConsecutive = 0
        var prevMatched = false
        for ch in haystack where nIdx < needle.endIndex {
            if ch == needle[nIdx] {
                nIdx = needle.index(after: nIdx)
                consecutive = prevMatched ? consecutive + 1 : 1
                maxConsecutive = max(maxConsecutive, consecutive)
                prevMatched = true
            } else {
                prevMatched = false
            }
        }
        guard nIdx == needle.endIndex else { return nil }
        return min(80, maxConsecutive * 10)
    }
}
