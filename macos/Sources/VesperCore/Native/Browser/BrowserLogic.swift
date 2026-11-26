import Foundation

// MARK: - Omnibox & URL Resolution

public enum BrowserURLResolver {
    /// Allowed schemes for user-typed URLs in the omnibox.
    private static let allowedSchemes: Set<String> = ["http", "https"]

    /// Turns raw omnibox text into a navigable URL: either a direct web address or a search query.
    /// Rejects dangerous schemes (`javascript:`, `file:`, `data:`) by treating them as plain search
    /// terms or returning nil when empty.
    public static func resolve(_ raw: String, searchEngine: BrowserSearchEngine = .duckDuckGo) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Explicit scheme check: allow http/https directly; block javascript:/file:/data: execution.
        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
            if allowedSchemes.contains(scheme),
               let url = URL(string: trimmed),
               let host = url.host,
               !host.isEmpty
            {
                return url
            }
            return searchEngine.searchURL(for: trimmed)
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") || lower.hasPrefix("about:") {
            return searchEngine.searchURL(for: trimmed)
        }

        // Spaces mean a search query.
        if trimmed.contains(where: \.isWhitespace) {
            return searchEngine.searchURL(for: trimmed)
        }

        // localhost or loopback IP (with optional port/path): default to http.
        if isLocalHostLike(trimmed) {
            return URL(string: "http://" + trimmed)
        }

        // Bare domain (contains a dot, valid host segment before first slash/query/fragment): default to https.
        if looksLikeDomain(trimmed), let url = URL(string: "https://" + trimmed), let host = url.host, !host.isEmpty {
            return url
        }

        return searchEngine.searchURL(for: trimmed)
    }

    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        return !(url.host?.isEmpty ?? true)
    }

    /// Compact host label without `www.` for tabs, subtitles, and history rows.
    public static func displayHost(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return "" }
        let cleaned = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = url.port {
            return "\(cleaned):\(port)"
        }
        return cleaned
    }

    /// Human-readable short address for unfocused omnibox display.
    public static func displayAddress(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        let cleanHost = displayHost(for: urlString)
        let path = url.path == "/" ? "" : url.path
        return cleanHost + path
    }

    private static func isLocalHostLike(_ value: String) -> Bool {
        let hostPart = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let lower = hostPart.lowercased()
        if lower == "localhost" || lower.hasPrefix("localhost:") { return true }
        if lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]") { return true }
        // Private RFC1918 IPv4 with optional port (e.g. 192.168.1.10:8080, 10.0.0.5:3000)
        let bareHost = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
        let octets = bareHost.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) {
            return true
        }
        return false
    }

    private static func looksLikeDomain(_ value: String) -> Bool {
        let authority = value
            .split(separator: "/", maxSplits: 1).first
            .flatMap { $0.split(separator: "?", maxSplits: 1).first }
            .flatMap { $0.split(separator: "#", maxSplits: 1).first }
            .map(String.init) ?? value
        guard !authority.contains("@") else { return false }
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Page Privacy, Redaction & Site Actions (Swift counterpart of SafariExtension/lib.js)

public struct BrowserNeverShareLists: Codable, Sendable, Equatable {
    public var builtin: [String]
    public var mine: [String]

    public init(builtin: [String] = [], mine: [String] = []) {
        self.builtin = builtin
        self.mine = mine
    }
}

public struct BrowserPageShareCheck: Sendable, Equatable {
    public var ok: Bool
    public var host: String?
    public var isUserBlocked: Bool
    public var reason: String?

    public init(ok: Bool, host: String? = nil, isUserBlocked: Bool = false, reason: String? = nil) {
        self.ok = ok
        self.host = host
        self.isUserBlocked = isUserBlocked
        self.reason = reason
    }
}

public struct BrowserSiteAction: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var personaId: String?
    public var prompt: String

    public init(id: String, label: String, personaId: String?, prompt: String) {
        self.id = id
        self.label = label
        self.personaId = personaId
        self.prompt = prompt
    }
}

public enum BrowserPageGuard {
    /// Lower case, no "www.", no port, no trailing dot; nil for non-hosts.
    public static func normalizeHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        if host.contains("://") {
            guard let parsed = URL(string: host), let h = parsed.host else { return nil }
            host = h.lowercased()
        } else if let colon = host.lastIndex(of: ":"),
                  host[host.index(after: colon)...].allSatisfy(\.isNumber)
        {
            host = String(host[..<colon])
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let forbidden = CharacterSet(charactersIn: "/?#@\\").union(.whitespacesAndNewlines)
        guard host.rangeOfCharacter(from: forbidden) == nil else { return nil }
        return host
    }

    public static func isCovered(_ host: String, by entry: String) -> Bool {
        host == entry || host.hasSuffix("." + entry)
    }

    /// Mirrors `SafariExtension/Resources/lib.js` and `server/internal/browserext` rules so the UI
    /// disables sharing before anything leaves the webview.
    public static func shareablePage(
        url urlString: String,
        isPrivate: Bool,
        neverShare: BrowserNeverShareLists
    ) -> BrowserPageShareCheck {
        if isPrivate {
            return BrowserPageShareCheck(ok: false, reason: "Private tabs are never shared.")
        }
        guard let url = URL(string: urlString) else {
            return BrowserPageShareCheck(ok: false, reason: "This isn't a web page.")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return BrowserPageShareCheck(ok: false, reason: "Only web pages can be shared.")
        }
        if url.user != nil || url.password != nil {
            return BrowserPageShareCheck(ok: false, reason: "Addresses with a password in them are never shared.")
        }
        guard let rawHost = url.host, let host = normalizeHost(rawHost) else {
            return BrowserPageShareCheck(ok: false, reason: "This isn't a web page.")
        }
        if neverShare.builtin.contains(where: { isCovered(host, by: $0) }) {
            return BrowserPageShareCheck(
                ok: false,
                host: host,
                reason: "\(host) is on Vesper's never-share list (passwords, sign-in and payments)."
            )
        }
        if neverShare.mine.contains(where: { isCovered(host, by: $0) }) {
            return BrowserPageShareCheck(
                ok: false,
                host: host,
                isUserBlocked: true,
                reason: "You set \(host) to never share."
            )
        }
        return BrowserPageShareCheck(ok: true, host: host)
    }

    /// Equal ignoring `#fragment`, used for `until: "page"` shares.
    public static func samePage(_ a: String, _ b: String) -> Bool {
        guard var ca = URLComponents(string: a), var cb = URLComponents(string: b) else { return false }
        ca.fragment = nil
        cb.fragment = nil
        return ca.string == cb.string
    }

    /// Replaces 13–19 digit sequences passing the Luhn check with `[card number removed]`.
    public static func redactCardNumbers(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let pattern = #"(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            let digits = candidate.filter(\.isNumber)
            if passesLuhn(digits) {
                result.replaceSubrange(range, with: "[card number removed]")
            }
        }
        return result
    }

    public static func passesLuhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let raw = ch.wholeNumberValue else { return false }
            var d = raw
            if i % 2 == 1 {
                d *= 2
                if d > 9 { d -= 9 }
            }
            sum += d
        }
        return sum % 10 == 0
    }

    /// Context-aware one-click persona actions (GitHub PRs/issues, YouTube videos).
    public static func siteActions(url urlString: String, personas: [BrowserExtensionPersona]) -> [BrowserSiteAction] {
        guard let url = URL(string: urlString), let rawHost = url.host else { return [] }
        let host = rawHost.lowercased().hasPrefix("www.") ? String(rawHost.dropFirst(4)).lowercased() : rawHost.lowercased()
        let fallback = personas.first(where: \.isDefault) ?? personas.first
        var out: [BrowserSiteAction] = []

        if host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 4, (parts[2] == "pull" || parts[2] == "issues"), Int(parts[3]) != nil {
                if parts[2] == "pull" {
                    let reviewer = personas.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "code reviewer" }
                    out.append(BrowserSiteAction(
                        id: "review-pr",
                        label: reviewer.map { "Review with \($0.name)" } ?? "Review this pull request",
                        personaId: (reviewer ?? fallback)?.id,
                        prompt: "Review this pull request: read it on GitHub, then give me your findings, most severe first."
                    ))
                    out.append(BrowserSiteAction(
                        id: "ticket-from-pr",
                        label: "Make a ticket from this",
                        personaId: fallback?.id,
                        prompt: "Make a Vesper ticket from this pull request: a clear title, what it changes and acceptance criteria. Ask me which project if it isn't clear."
                    ))
                } else {
                    out.append(BrowserSiteAction(
                        id: "ticket-from-issue",
                        label: "Make a ticket from this",
                        personaId: fallback?.id,
                        prompt: "Make a Vesper ticket from this GitHub issue: a clear title, the problem and acceptance criteria. Ask me which project if it isn't clear."
                    ))
                }
            }
        }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let isYouTubeWatch = (host == "youtube.com" || host == "m.youtube.com")
            && url.path == "/watch"
            && (comps?.queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true)
        let isYouTuBe = host == "youtu.be" && url.path.count > 1
        if isYouTubeWatch || isYouTuBe {
            out.append(BrowserSiteAction(
                id: "video-notes",
                label: "Take notes on this video",
                personaId: fallback?.id,
                prompt: "Take notes on this video: read its transcript with get_video_transcript, then save the notes as a Knowledge source note for it."
            ))
        }
        return out
    }
}

// MARK: - Tab Ordering, Shortcuts & Omnibox Suggestions

public struct BrowserOmniboxSuggestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case openTab
        case bookmark
        case savedLink
        case history
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var url: String
    public var subtitle: String
    public var tabId: UUID?

    public init(id: String, kind: Kind, title: String, url: String, subtitle: String, tabId: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.subtitle = subtitle
        self.tabId = tabId
    }
}

public enum BrowserTabListLogic {
    /// Orders pinned tabs first, then regular tabs, preserving relative order inside each group.
    /// This matches the sidebar layout and makes `⌘⌃1`–`⌘⌃9` predictable.
    public static func displayOrder<T>(_ tabs: [T], isPinned: (T) -> Bool) -> [T] {
        let pinned = tabs.filter(isPinned)
        let unpinned = tabs.filter { !isPinned($0) }
        return pinned + unpinned
    }

    /// 1..8 selects that 1-based position; 9 selects the last tab (matching Safari & Vesper window tabs).
    public static func indexForNumberedShortcut(_ number: Int, count: Int) -> Int? {
        guard count > 0, (1...9).contains(number) else { return nil }
        if number == 9 { return count - 1 }
        let idx = number - 1
        return idx < count ? idx : nil
    }

    public static func nextIndex(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return 0 }
        return (current + 1) % count
    }

    public static func previousIndex(before current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return count - 1 }
        return (current - 1 + count) % count
    }

    /// Upserts a history entry at the top of the list, incrementing visitCount and capping size.
    public static func recordVisit(
        url: String,
        title: String,
        at date: Date = Date(),
        in history: [BrowserHistoryEntry],
        limit: Int = BrowserStorage.maxHistoryEntries
    ) -> [BrowserHistoryEntry] {
        guard let parsed = URL(string: url), BrowserURLResolver.isWebURL(parsed) else { return history }
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanedTitle.isEmpty ? BrowserURLResolver.displayHost(for: url) : cleanedTitle

        var updated = history
        if let idx = updated.firstIndex(where: { $0.url == url }) {
            var existing = updated.remove(at: idx)
            existing.title = finalTitle
            existing.visitedAt = date
            existing.visitCount += 1
            updated.insert(existing, at: 0)
        } else {
            updated.insert(BrowserHistoryEntry(url: url, title: finalTitle, visitedAt: date, visitCount: 1), at: 0)
        }
        if updated.count > limit {
            updated = Array(updated.prefix(limit))
        }
        return updated
    }

    /// Ranks matching open tabs, bookmarks, saved links, and history entries for the omnibox dropdown.
    public static func suggestions(
        query: String,
        openTabs: [BrowserTabRecord],
        bookmarks: [BrowserBookmark],
        savedLinks: [(id: String, title: String, url: String, site: String?)],
        history: [BrowserHistoryEntry],
        limit: Int = 8
    ) -> [BrowserOmniboxSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        var results: [BrowserOmniboxSuggestion] = []
        var seenURLs = Set<String>()

        func matches(_ title: String, _ url: String) -> Bool {
            title.lowercased().contains(needle) || url.lowercased().contains(needle)
        }

        for tab in openTabs where !tab.url.isEmpty && matches(tab.title, tab.url) {
            results.append(BrowserOmniboxSuggestion(
                id: "tab:\(tab.id.uuidString)",
                kind: .openTab,
                title: tab.title.isEmpty ? BrowserURLResolver.displayHost(for: tab.url) : tab.title,
                url: tab.url,
                subtitle: "Switch to tab · \(BrowserURLResolver.displayHost(for: tab.url))",
                tabId: tab.id
            ))
            seenURLs.insert(tab.url)
            if results.count >= limit { return results }
        }

        for bm in bookmarks where !seenURLs.contains(bm.url) && matches(bm.title, bm.url) {
            results.append(BrowserOmniboxSuggestion(
                id: "bm:\(bm.id)",
                kind: .bookmark,
                title: bm.title,
                url: bm.url,
                subtitle: "Bookmark · \(BrowserURLResolver.displayHost(for: bm.url))"
            ))
            seenURLs.insert(bm.url)
            if results.count >= limit { return results }
        }

        for link in savedLinks where !seenURLs.contains(link.url) && matches(link.title, link.url) {
            let host = link.site?.isEmpty == false ? link.site! : BrowserURLResolver.displayHost(for: link.url)
            results.append(BrowserOmniboxSuggestion(
                id: "saved:\(link.id)",
                kind: .savedLink,
                title: link.title,
                url: link.url,
                subtitle: "Saved link · \(host)"
            ))
            seenURLs.insert(link.url)
            if results.count >= limit { return results }
        }

        for entry in history where !seenURLs.contains(entry.url) && matches(entry.title, entry.url) {
            results.append(BrowserOmniboxSuggestion(
                id: "hist:\(entry.id)",
                kind: .history,
                title: entry.title,
                url: entry.url,
                subtitle: BrowserURLResolver.displayHost(for: entry.url)
            ))
            seenURLs.insert(entry.url)
            if results.count >= limit { return results }
        }

        return results
    }
}

// MARK: - Native Content Blocker Rules (WKContentRuleList)

public enum BrowserContentBlockerRules {
    /// Well-known ad networks and third-party tracking hosts blocked natively by WebKit.
    public static let blockedDomains: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "google-analytics.com",
        "googletagmanager.com",
        "adservice.google.com",
        "pagead2.googlesyndication.com",
        "adnxs.com",
        "adsrvr.org",
        "amazon-adsystem.com",
        "criteo.com",
        "criteo.net",
        "outbrain.com",
        "taboola.com",
        "pubmatic.com",
        "rubiconproject.com",
        "openx.net",
        "casalemedia.com",
        "scorecardresearch.com",
        "quantserve.com",
        "hotjar.com",
        "fullstory.com",
        "mixpanel.com",
        "segment.io",
        "segment.com",
        "amplitude.com",
        "clarity.ms",
        "bat.bing.com",
        "connect.facebook.net",
        "analytics.tiktok.com",
        "ads.linkedin.com",
        "px.ads.linkedin.com",
        "ads-twitter.com",
        "static.ads-twitter.com",
        "moatads.com",
        "doubleverify.com",
        "adsafeprotected.com",
        "zedo.com",
        "media.net",
        "sharethrough.com",
        "revcontent.com",
        "mgid.com",
        "popads.net",
        "smartadserver.com",
        "yieldmo.com",
        "33across.com",
        "indexww.com",
        "lijit.com",
        "bidswitch.net",
        "demdex.net",
        "omtrdc.net",
        "krxd.net",
        "bluekai.com",
        "rlcdn.com",
        "tapad.com",
        "chartbeat.com",
        "chartbeat.net",
        "newrelic.com",
        "bam.nr-data.net",
        "sentry-cdn.com",
    ]

    /// Builds a valid Safari/WebKit `WKContentRuleList` JSON payload.
    /// Any host in `disabledHosts` (plus its subdomains) is exempted via `unless-top-url`.
    public static func ruleListJSON(disabledHosts: [String] = []) -> String {
        let escapedHosts = blockedDomains
            .map { $0.replacingOccurrences(of: ".", with: "\\.") }
            .joined(separator: "|")
        let urlFilter = "^https?://([^/]+\\.)?(\(escapedHosts))([/:?]|$)"

        var trigger: [String: Any] = [
            "url-filter": urlFilter,
            "load-type": ["third-party"],
        ]

        let normalizedExclusions = disabledHosts.compactMap { BrowserPageGuard.normalizeHost($0) }
        if !normalizedExclusions.isEmpty {
            trigger["unless-domain"] = normalizedExclusions.map { "*\($0)" }
        }

        let rules: [[String: Any]] = [
            [
                "trigger": trigger,
                "action": ["type": "block"],
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    public static func isAdBlockActive(globalEnabled: Bool, host: String?, disabledHosts: [String]) -> Bool {
        guard globalEnabled else { return false }
        guard let host, let normalized = BrowserPageGuard.normalizeHost(host) else { return true }
        return !disabledHosts.contains(where: { BrowserPageGuard.isCovered(normalized, by: $0) })
    }
}

// MARK: - Screenshot / Clip Markdown Helpers

public enum BrowserKnowledgeFormatter {
    /// Builds the Markdown body for a Knowledge clipping note containing a captured page screenshot.
    public static func screenshotNoteBody(
        title: String,
        url: String,
        assetRef: String,
        caption: String? = nil
    ) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if !cleanTitle.isEmpty {
            lines.append("Captured from [\(cleanTitle)](\(url))")
        } else if !url.isEmpty {
            lines.append("Captured from <\(url)>")
        }
        if let caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
            lines.append("")
            lines.append(caption)
        }
        lines.append("")
        lines.append(KnowledgeShellLogic.markdownEmbedBlock(for: [assetRef]))
        return lines.joined(separator: "\n")
    }

    /// Formats a Markdown blockquote with source link for "Copy Markdown Quote".
    public static func markdownQuote(selection: String, title: String, url: String) -> String {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = trimmed
            .components(separatedBy: .newlines)
            .map { "> \($0)" }
            .joined(separator: "\n")
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? BrowserURLResolver.displayHost(for: url)
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        if quoted.isEmpty {
            return "[\(label)](\(url))"
        }
        return "\(quoted)\n\n— [\(label)](\(url))"
    }
}
