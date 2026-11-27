import Foundation

// MARK: - Persistent Web Highlights & Knowledge Backlinks

public enum BrowserHighlightColor: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case yellow
    case green
    case blue
    case pink
    case purple

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }

    public var webBackgroundRGBA: String {
        switch self {
        case .yellow: "rgba(255, 224, 102, 0.45)"
        case .green: "rgba(116, 224, 152, 0.40)"
        case .blue: "rgba(116, 185, 255, 0.40)"
        case .pink: "rgba(255, 148, 194, 0.42)"
        case .purple: "rgba(186, 148, 255, 0.40)"
        }
    }

    public var webBorderRGBA: String {
        switch self {
        case .yellow: "rgba(217, 163, 0, 0.72)"
        case .green: "rgba(38, 166, 91, 0.68)"
        case .blue: "rgba(41, 128, 230, 0.68)"
        case .pink: "rgba(219, 68, 136, 0.68)"
        case .purple: "rgba(138, 86, 232, 0.68)"
        }
    }
}

public struct BrowserWebHighlight: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// Canonical normalized URL key (no fragment, no tracking params, no leading www.).
    public var url: String
    /// Original URL when the highlight was captured.
    public var originalURL: String
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var note: String?
    public var color: BrowserHighlightColor
    public var knowledgePageId: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        url: String,
        originalURL: String? = nil,
        quote: String,
        prefix: String = "",
        suffix: String = "",
        note: String? = nil,
        color: BrowserHighlightColor = .yellow,
        knowledgePageId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.originalURL = originalURL ?? url
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.note = note
        self.color = color
        self.knowledgePageId = knowledgePageId
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case originalURL = "original_url"
        case quote
        case prefix
        case suffix
        case note
        case color
        case knowledgePageId = "knowledge_page_id"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        originalURL = try c.decodeIfPresent(String.self, forKey: .originalURL) ?? url
        quote = try c.decodeIfPresent(String.self, forKey: .quote) ?? ""
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        color = try c.decodeIfPresent(BrowserHighlightColor.self, forKey: .color) ?? .yellow
        knowledgePageId = try c.decodeIfPresent(String.self, forKey: .knowledgePageId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public enum BrowserURLNormalizer {
    /// Produces a stable canonical key for http(s) URLs so fragments, `www.`, trailing slashes,
    /// and tracking query params don't split Knowledge backlinks or web highlights.
    public static func canonicalPageKey(for rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let stripped = BrowserTrackingParamStripper.strip(from: parsed).url
        guard var comps = URLComponents(url: stripped, resolvingAgainstBaseURL: false),
              let rawHost = comps.host?.lowercased(),
              !rawHost.isEmpty
        else { return nil }

        var host = rawHost
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }

        comps.scheme = "https"
        comps.host = host
        comps.fragment = nil
        if (scheme == "http" && comps.port == 80) || (scheme == "https" && comps.port == 443) {
            comps.port = nil
        }

        var path = comps.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        comps.path = path

        if let items = comps.queryItems, !items.isEmpty {
            let sorted = items.sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return ($0.value ?? "") < ($1.value ?? "")
            }
            comps.queryItems = sorted
        } else {
            comps.queryItems = nil
        }
        return comps.url?.absoluteString
    }

    public static func hostKey(for rawURL: String) -> String? {
        BrowserPageGuard.normalizeHost(rawURL)
    }
}

public struct BrowserKnowledgeBacklink: Sendable, Equatable, Hashable, Identifiable {
    public enum MatchKind: Int, Sendable, Equatable, Hashable, Comparable {
        case exactURL = 0
        case sameDomain = 1

        public static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var badgeLabel: String {
            switch self {
            case .exactURL: "This page"
            case .sameDomain: "Same site"
            }
        }
    }

    public var id: String
    public var title: String
    public var path: String
    public var matchKind: MatchKind
    public var sourceURL: String?
    public var updatedAt: String

    public init(
        id: String,
        title: String,
        path: String,
        matchKind: MatchKind,
        sourceURL: String? = nil,
        updatedAt: String = ""
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.matchKind = matchKind
        self.sourceURL = sourceURL
        self.updatedAt = updatedAt
    }
}

public enum BrowserKnowledgeMatcher {
    /// Finds Knowledge pages linked to the current web page via `source` / `url` / `source_site`
    /// properties, prioritizing exact page matches ahead of same-domain notes.
    public static func matchingPages(
        for urlString: String,
        in pages: [KnowledgePageRow]
    ) -> [BrowserKnowledgeBacklink] {
        guard let pageKey = BrowserURLNormalizer.canonicalPageKey(for: urlString),
              let pageHost = BrowserURLNormalizer.hostKey(for: urlString)
        else { return [] }

        var resultsByID: [String: BrowserKnowledgeBacklink] = [:]

        for page in pages {
            let sourceProp = stringProperty("source", in: page.properties)
                ?? stringProperty("url", in: page.properties)
            let siteProp = stringProperty("source_site", in: page.properties)

            var matchKind: BrowserKnowledgeBacklink.MatchKind?
            if let sourceProp, let sourceKey = BrowserURLNormalizer.canonicalPageKey(for: sourceProp) {
                if sourceKey == pageKey {
                    matchKind = .exactURL
                } else if BrowserURLNormalizer.hostKey(for: sourceProp) == pageHost {
                    matchKind = .sameDomain
                }
            } else if let siteProp,
                      let normalizedSite = BrowserPageGuard.normalizeHost(siteProp),
                      normalizedSite == pageHost
            {
                matchKind = .sameDomain
            }

            guard let kind = matchKind else { continue }
            let backlink = BrowserKnowledgeBacklink(
                id: page.id,
                title: page.title.isEmpty ? page.path : page.title,
                path: page.path,
                matchKind: kind,
                sourceURL: sourceProp,
                updatedAt: page.updatedAt
            )
            if let existing = resultsByID[page.id] {
                if backlink.matchKind < existing.matchKind {
                    resultsByID[page.id] = backlink
                }
            } else {
                resultsByID[page.id] = backlink
            }
        }

        return resultsByID.values.sorted { lhs, rhs in
            if lhs.matchKind != rhs.matchKind { return lhs.matchKind < rhs.matchKind }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func stringProperty(_ key: String, in props: [String: JSONValue]) -> String? {
        guard case .string(let raw)? = props[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum BrowserHighlightFormatter {
    public static func highlightBlock(for highlight: BrowserWebHighlight) -> String {
        let quoted = highlight.quote
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")

        var lines: [String] = [quoted]
        if let note = highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("")
            lines.append(note)
        }
        let timestamp = highlight.createdAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .colon))
        lines.append("<!-- vesper-highlight:\(highlight.id.uuidString.lowercased()) color:\(highlight.color.rawValue) at:\(timestamp) -->")
        return lines.joined(separator: "\n")
    }

    /// Creates or appends a highlight blockquote under `## Highlights` in a Knowledge literature note.
    public static func appendHighlightMarkdown(
        existingBody: String?,
        pageTitle: String,
        pageURL: String,
        highlight: BrowserWebHighlight
    ) -> String {
        let block = highlightBlock(for: highlight)
        let trimmedExisting = (existingBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedExisting.isEmpty {
            let safeTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let linkTitle = safeTitle.isEmpty ? pageURL : safeTitle
            return """
            Source: [\(linkTitle)](\(pageURL))

            ## Highlights

            \(block)
            """
        }

        if trimmedExisting.contains("## Highlights") {
            return "\(trimmedExisting)\n\n\(block)\n"
        }

        return """
        \(trimmedExisting)

        ## Highlights

        \(block)
        """
    }

    public static func noteBodyForClip(
        title: String,
        url: String,
        selection: String
    ) -> String {
        let safeTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkTitle = safeTitle.isEmpty ? url : safeTitle
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSelection.isEmpty {
            return """
            Source: [\(linkTitle)](\(url))

            ## Notes

            """
        }
        let quoted = trimmedSelection
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return """
        Source: [\(linkTitle)](\(url))

        \(quoted)

        ## Notes

        """
    }
}

public enum BrowserHighlightScripts {
    /// Captures the current page text selection plus surrounding prefix/suffix context for
    /// reliable re-highlighting when the user revisits the page.
    public static let extractSelectionContextJS = #"""
    (() => {
      const sel = window.getSelection ? window.getSelection() : null;
      if (!sel || sel.rangeCount === 0) return { quote: "", prefix: "", suffix: "" };
      const quote = (sel.toString() || "").trim();
      if (!quote) return { quote: "", prefix: "", suffix: "" };
      let prefix = "";
      let suffix = "";
      try {
        const range = sel.getRangeAt(0);
        const startText = range.startContainer && range.startContainer.nodeType === 3 ? (range.startContainer.textContent || "") : "";
        const endText = range.endContainer && range.endContainer.nodeType === 3 ? (range.endContainer.textContent || "") : "";
        prefix = startText.slice(Math.max(0, range.startOffset - 36), range.startOffset).trim();
        suffix = endText.slice(range.endOffset, Math.min(endText.length, range.endOffset + 36)).trim();
      } catch (_) {}
      return { quote, prefix, suffix };
    })();
    """#

    private struct HighlightPayload: Encodable {
        let id: String
        let quote: String
        let prefix: String
        let suffix: String
        let bg: String
        let border: String
    }

    /// Generates an idempotent JS snippet that wraps matching text passages in `<mark data-vesper-highlight="...">`.
    public static func applyHighlightsJS(highlights: [BrowserWebHighlight]) -> String {
        let payloads = highlights.compactMap { h -> HighlightPayload? in
            let q = h.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return nil }
            return HighlightPayload(
                id: h.id.uuidString.lowercased(),
                quote: q,
                prefix: h.prefix,
                suffix: h.suffix,
                bg: h.color.webBackgroundRGBA,
                border: h.color.webBorderRGBA
            )
        }
        guard !payloads.isEmpty,
              let jsonData = try? JSONEncoder().encode(payloads),
              let json = String(data: jsonData, encoding: .utf8)
        else { return "0;" }

        return """
        (() => {
          const items = \(json);
          if (!document.body || !items.length) return 0;
          const skipTags = new Set(['SCRIPT','STYLE','NOSCRIPT','TEXTAREA','INPUT','SELECT','OPTION','MARK']);
          let applied = 0;

          function collectTextNodes() {
            const out = [];
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
              acceptNode(node) {
                if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
                let el = node.parentElement;
                while (el) {
                  if (skipTags.has(el.tagName) || el.isContentEditable) return NodeFilter.FILTER_REJECT;
                  el = el.parentElement;
                }
                return NodeFilter.FILTER_ACCEPT;
              }
            });
            let n;
            while ((n = walker.nextNode())) out.push(n);
            return out;
          }

          for (const item of items) {
            if (document.querySelector('mark[data-vesper-highlight="' + item.id + '"]')) {
              applied++;
              continue;
            }
            const needle = item.quote;
            if (!needle) continue;
            const nodes = collectTextNodes();
            let best = null;
            let bestScore = -1;
            for (const node of nodes) {
              const text = node.nodeValue || '';
              let pos = text.indexOf(needle);
              while (pos !== -1) {
                let score = 0;
                if (item.prefix && text.slice(Math.max(0, pos - item.prefix.length - 8), pos).includes(item.prefix)) score += 2;
                if (item.suffix && text.slice(pos + needle.length, pos + needle.length + item.suffix.length + 8).includes(item.suffix)) score += 2;
                if (score > bestScore) {
                  bestScore = score;
                  best = { node, pos };
                }
                if (score === 4) break;
                pos = text.indexOf(needle, pos + needle.length);
              }
              if (bestScore === 4) break;
            }
            if (!best) continue;
            try {
              const range = document.createRange();
              range.setStart(best.node, best.pos);
              range.setEnd(best.node, best.pos + needle.length);
              const mark = document.createElement('mark');
              mark.setAttribute('data-vesper-highlight', item.id);
              mark.style.backgroundColor = item.bg;
              mark.style.borderBottom = '1.5px solid ' + item.border;
              mark.style.borderRadius = '2px';
              mark.style.padding = '0 1px';
              mark.style.color = 'inherit';
              range.surroundContents(mark);
              applied++;
            } catch (_) {}
          }
          return applied;
        })();
        """
    }

    public static func scrollToHighlightJS(id: UUID) -> String {
        let token = id.uuidString.lowercased()
        return """
        (() => {
          const el = document.querySelector('mark[data-vesper-highlight="\(token)"]');
          if (!el) return false;
          el.scrollIntoView({ behavior: 'smooth', block: 'center' });
          const prevOutline = el.style.outline;
          el.style.outline = '2px solid rgba(255, 149, 0, 0.9)';
          setTimeout(() => { el.style.outline = prevOutline || ''; }, 1400);
          return true;
        })();
        """
    }

    public static func removeHighlightJS(id: UUID) -> String {
        let token = id.uuidString.lowercased()
        return """
        (() => {
          const marks = document.querySelectorAll('mark[data-vesper-highlight="\(token)"]');
          marks.forEach((mark) => {
            const parent = mark.parentNode;
            if (!parent) return;
            while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
            parent.removeChild(mark);
            parent.normalize();
          });
          return marks.length;
        })();
        """
    }
}

// MARK: - Space-Bound Tab Groups & Smart Clip Routing

public struct BrowserSpaceSummary: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var personaId: String?
    public var defaultKnowledgeFolder: String?
    public var firstKnowledgeFolder: String?

    public init(
        id: String,
        name: String,
        personaId: String? = nil,
        defaultKnowledgeFolder: String? = nil,
        firstKnowledgeFolder: String? = nil
    ) {
        self.id = id
        self.name = name
        self.personaId = personaId
        self.defaultKnowledgeFolder = defaultKnowledgeFolder
        self.firstKnowledgeFolder = firstKnowledgeFolder
    }

    public init(space: API.ChatSpace) {
        let folderLinks = (space.knowledgeLinks ?? []).filter { $0.kind == .folder && !$0.path.isEmpty }
        let defaultFolder = folderLinks.first(where: \.isDefaultTarget)?.path
        let firstFolder = folderLinks.first?.path
        self.init(
            id: space.id,
            name: space.name,
            personaId: space.personaId,
            defaultKnowledgeFolder: defaultFolder,
            firstKnowledgeFolder: firstFolder
        )
    }
}

public enum BrowserSpaceRoutingLogic {
    /// Resolves the bound Vesper Space for a tab: Tab Group binding takes precedence over Profile binding.
    public static func resolvedSpaceId(
        for tab: BrowserTabRecord,
        tabGroups: [BrowserTabGroup],
        profileSpaceId: String?
    ) -> String? {
        if let gid = tab.groupId,
           let group = tabGroups.first(where: { $0.id == gid }),
           let groupSpace = trimmedNonEmpty(group.spaceId)
        {
            return groupSpace
        }
        return trimmedNonEmpty(profileSpaceId)
    }

    /// Determines the destination Knowledge folder for clippings and screenshots:
    /// 1. Bound Space's default linked Knowledge folder (`isDefaultTarget`)
    /// 2. Bound Space's first linked Knowledge folder
    /// 3. `Spaces/<SpaceName>/Clippings`
    /// 4. `Clippings` when no Space is bound.
    public static func clipFolder(for space: BrowserSpaceSummary?) -> String {
        guard let space else { return "Clippings" }
        if let def = trimmedFolder(space.defaultKnowledgeFolder) {
            return def
        }
        if let first = trimmedFolder(space.firstKnowledgeFolder) {
            return first
        }
        let safeSpace = safeFolderSegment(space.name)
        return "Spaces/\(safeSpace)/Clippings"
    }

    public static func clipProperties(
        url: String,
        title: String,
        host: String,
        space: BrowserSpaceSummary?,
        clippedFrom: String = "browser"
    ) -> [String: JSONValue] {
        var props: [String: JSONValue] = [
            "type": .string("literature"),
            "source": .string(url),
            "source_title": .string(title),
            "source_site": .string(host),
            "clipped_from": .string(clippedFrom),
        ]
        if let space {
            props["space"] = .string(space.name)
            props["space_id"] = .string(space.id)
        }
        return props
    }

    /// Picks the best default share target in the Share popover for a tab.
    public static func defaultShareTarget(
        space: BrowserSpaceSummary?,
        companionChatId: String?,
        personas: [BrowserExtensionPersona]
    ) -> String {
        if companionChatId != nil {
            return "companion"
        }
        if let pid = space?.personaId, personas.contains(where: { $0.id == pid }) {
            return "persona:\(pid)"
        }
        return "companion"
    }

    public static func safeFolderSegment(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(filtered)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        let prefix = String(collapsed.prefix(48))
        return prefix.isEmpty ? "Space" : prefix
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func trimmedFolder(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
        return t.isEmpty ? nil : t
    }
}

// MARK: - Companion Auto-Follow & Multi-Tab Sharing

public struct BrowserMultiTabInput: Sendable, Equatable {
    public var tabId: UUID
    public var url: String
    public var title: String
    public var text: String
    public var isPrivate: Bool

    public init(tabId: UUID, url: String, title: String, text: String, isPrivate: Bool = false) {
        self.tabId = tabId
        self.url = url
        self.title = title
        self.text = text
        self.isPrivate = isPrivate
    }
}

public struct BrowserMultiTabBundle: Sendable, Equatable {
    public var primaryURL: String
    public var title: String
    public var combinedText: String
    public var includedCount: Int
    public var skippedCount: Int
    public var includedTabIDs: [UUID]

    public init(
        primaryURL: String,
        title: String,
        combinedText: String,
        includedCount: Int,
        skippedCount: Int,
        includedTabIDs: [UUID]
    ) {
        self.primaryURL = primaryURL
        self.title = title
        self.combinedText = combinedText
        self.includedCount = includedCount
        self.skippedCount = skippedCount
        self.includedTabIDs = includedTabIDs
    }
}

public enum BrowserMultiTabShareLogic {
    /// Leaves comfortable headroom below the server's 200,000-rune snapshot cap.
    public static let maxCombinedRunes = 185_000
    public static let maxPerTabRunes = 45_000

    /// Returns whether a tab may be automatically pushed to Companion Chat under Follow Active Tab.
    /// Private tabs, empty tabs, non-http(s) URLs, and never-share hosts are always excluded.
    public static func isAutoFollowEligible(
        urlString: String,
        isPrivate: Bool,
        isCompanionOpen: Bool,
        neverShare: BrowserNeverShareLists
    ) -> Bool {
        guard isCompanionOpen, !isPrivate, !urlString.isEmpty else { return false }
        return BrowserPageGuard.shareablePage(
            url: urlString,
            isPrivate: isPrivate,
            neverShare: neverShare
        ).ok
    }

    /// Combines multiple open browser tabs into one cleanly structured, redacted snapshot payload
    /// compatible with Vesper's `browser_snapshot` tool, skipping private & never-share tabs.
    public static func buildBundle(
        tabs: [BrowserMultiTabInput],
        groupName: String? = nil,
        neverShare: BrowserNeverShareLists = BrowserNeverShareLists()
    ) -> BrowserMultiTabBundle? {
        var shareable: [BrowserMultiTabInput] = []
        var skipped = 0

        for tab in tabs {
            let check = BrowserPageGuard.shareablePage(
                url: tab.url,
                isPrivate: tab.isPrivate,
                neverShare: neverShare
            )
            if check.ok {
                shareable.append(tab)
            } else {
                skipped += 1
            }
        }

        guard let first = shareable.first else { return nil }

        let count = shareable.count
        let perTabBudget = max(2_000, min(maxPerTabRunes, maxCombinedRunes / max(1, count)))

        var headerLines: [String] = []
        if let g = groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            headerLines.append("# Shared Browser Tabs (\(count) tabs — Group: \(g))")
        } else {
            headerLines.append("# Shared Browser Tabs (\(count) tabs)")
        }
        if skipped > 0 {
            headerLines.append("_\(skipped) private or protected tab\(skipped == 1 ? "" : "s") excluded._")
        }
        headerLines.append("")
        for (idx, tab) in shareable.enumerated() {
            let cleanTitle = cleanedTitle(tab.title, fallbackURL: tab.url)
            headerLines.append("\(idx + 1). [\(cleanTitle)](\(tab.url))")
        }

        var sections: [String] = [headerLines.joined(separator: "\n")]
        for (idx, tab) in shareable.enumerated() {
            let cleanTitle = cleanedTitle(tab.title, fallbackURL: tab.url)
            let redacted = BrowserPageGuard.redactCardNumbers(tab.text)
            let clipped = clip(redacted, maxChars: perTabBudget)
            sections.append(
                """
                ---
                ## Tab \(idx + 1) of \(count): \(cleanTitle)
                URL: \(tab.url)

                \(clipped)
                """
            )
        }

        let summaryTitle: String
        if let g = groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            summaryTitle = "\(g) (\(count) tabs)"
        } else if count == 1 {
            summaryTitle = cleanedTitle(first.title, fallbackURL: first.url)
        } else {
            let preview = shareable.prefix(2).map { cleanedTitle($0.title, fallbackURL: $0.url) }.joined(separator: ", ")
            let extra = count > 2 ? " +\(count - 2)" : ""
            summaryTitle = "\(count) Tabs: \(preview)\(extra)"
        }

        return BrowserMultiTabBundle(
            primaryURL: first.url,
            title: String(summaryTitle.prefix(240)),
            combinedText: sections.joined(separator: "\n\n"),
            includedCount: count,
            skippedCount: skipped,
            includedTabIDs: shareable.map(\.tabId)
        )
    }

    private static func cleanedTitle(_ raw: String, fallbackURL: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !collapsed.isEmpty { return collapsed }
        let host = BrowserURLResolver.displayHost(for: fallbackURL)
        return host.isEmpty ? fallbackURL : host
    }

    private static func clip(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        return String(trimmed.prefix(maxChars)) + "\n\n[Truncated to fit multi-tab budget]"
    }
}
