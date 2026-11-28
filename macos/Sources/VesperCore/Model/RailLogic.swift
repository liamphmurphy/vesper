import Foundation

/// Pure model builder, filtering, and action routing for the native macOS right rail.
/// Swift counterpart of `web/lib/native-shell/models/rail.ts` and `web/lib/github-reviews.ts`
/// so the native shell owns the rail without needing `AppShell` mounted in a hidden `WKWebView`.
public enum RailLogic {
    // MARK: - Item ids

    public static let dockTabPrefix = "dock.tab:"
    public static let prItemId = "pr"
    public static let prSetupId = "pr.setup"
    public static let prOpenPrefix = "pr:"
    public static let prDismissPrefix = "pr.dismiss:"
    public static let prClearId = "pr.clear"
    public static let prRestoreId = "pr.restore"
    public static let prRefreshId = "pr.refresh"
    public static let prDirectId = "pr.direct"
    public static let prTeamId = "pr.team"
    public static let needsYouItemId = "needsYou"
    public static let customizationItemId = "customization"
    public static let settingsItemId = "settings"

    public static let maxListedPRs = 15

    // MARK: - Types

    public struct ReviewFilterPrefs: Codable, Sendable, Equatable {
        public var direct: Bool
        public var team: Bool

        public init(direct: Bool = true, team: Bool = true) {
            self.direct = direct
            self.team = team
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            direct = try c.decodeIfPresent(Bool.self, forKey: .direct) ?? true
            team = try c.decodeIfPresent(Bool.self, forKey: .team) ?? true
        }
    }

    public enum ReviewPrefKey: String, Sendable, Equatable {
        case direct
        case team
    }

    public struct ReviewCounts: Sendable, Equatable {
        public var direct: Int
        public var team: Int

        public init(direct: Int = 0, team: Int = 0) {
            self.direct = direct
            self.team = team
        }
    }

    public struct ReviewInput: Sendable, Equatable {
        public var configured: Bool
        public var requests: [API.GitHubReviewRequest]
        public var approved: Int
        public var prefs: ReviewFilterPrefs
        public var counts: ReviewCounts
        public var dismissed: Int

        public init(
            configured: Bool = false,
            requests: [API.GitHubReviewRequest] = [],
            approved: Int = 0,
            prefs: ReviewFilterPrefs = ReviewFilterPrefs(),
            counts: ReviewCounts = ReviewCounts(),
            dismissed: Int = 0
        ) {
            self.configured = configured
            self.requests = requests
            self.approved = approved
            self.prefs = prefs
            self.counts = counts
            self.dismissed = dismissed
        }
    }

    public enum RailAction: Sendable, Equatable {
        case dockTab(String)
        case openSettings(SettingsDestination?)
        case openExternalURL(URL)
        case refreshReviews
        case clearReviews
        case dismissReview(String)
        case restoreReviews
        case toggleReviewPref(ReviewPrefKey)
        case navigate(String)
    }

    // MARK: - Dock items

    /// Builds the top rail items (`dock.tab:<id>`) directly from an `InspectorModel`.
    public static func dockItems(from model: InspectorModel?, poppedOut: Bool = false) -> [RailItem] {
        guard let model, !model.tabs.isEmpty else { return [] }
        let expanded = model.open || poppedOut
        let activeId = InspectorLogic.activeTab(in: model)?.id
        return model.tabs.map { tab in
            let label: String
            if tab.busy == true {
                label = "\(tab.label) (working)"
            } else if tab.unread == true {
                label = "\(tab.label) (unread)"
            } else {
                label = tab.label
            }
            return RailItem(
                id: dockTabPrefix + tab.id,
                label: label,
                icon: tab.icon,
                badge: tab.unread == true ? AreaBadge(tone: .human) : nil,
                status: tab.busy == true ? .accent : nil,
                active: expanded && tab.id == activeId
            )
        }
    }

    /// Chooses the top dock items for the active tab: native screens always derive them from their
    /// effective inspector; web screens keep the page's own dock items (including web action tabs
    /// like "Start playground") when present.
    public static func effectiveRailTop(
        nativeActive: Bool,
        inspector: InspectorModel?,
        poppedOut: Bool = false,
        pageRailTop: [RailItem]? = nil
    ) -> [RailItem] {
        if nativeActive {
            return dockItems(from: inspector, poppedOut: poppedOut)
        }
        if let pageRailTop, !pageRailTop.isEmpty {
            return pageRailTop
        }
        return dockItems(from: inspector, poppedOut: poppedOut)
    }

    // MARK: - GitHub review requests

    public static func dismissMarker(_ updatedAt: String) -> String {
        updatedAt.isEmpty ? "dismissed" : updatedAt
    }

    public static func parseReviewFilterPrefs(_ raw: String?) -> ReviewFilterPrefs {
        guard let raw, let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ReviewFilterPrefs.self, from: data) else {
            return ReviewFilterPrefs()
        }
        return parsed
    }

    public static func encodeReviewFilterPrefs(_ prefs: ReviewFilterPrefs) -> String? {
        guard let data = try? JSONEncoder().encode(prefs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func parseDismissedReviews(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return parsed.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    public static func encodeDismissedReviews(_ dismissed: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(dismissed) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func isDismissed(_ item: API.GitHubReviewRequest, in dismissed: [String: String]) -> Bool {
        guard let marker = dismissed[item.id] else { return false }
        return marker == dismissMarker(item.updatedAt)
    }

    public static func excludeDismissed(
        _ items: [API.GitHubReviewRequest],
        dismissed: [String: String]
    ) -> [API.GitHubReviewRequest] {
        items.filter { !isDismissed($0, in: dismissed) }
    }

    public static func dismiss(
        _ items: [API.GitHubReviewRequest],
        in dismissed: [String: String]
    ) -> [String: String] {
        guard !items.isEmpty else { return dismissed }
        var next = dismissed
        for item in items {
            next[item.id] = dismissMarker(item.updatedAt)
        }
        return next
    }

    public static func restore(
        _ items: [API.GitHubReviewRequest],
        from dismissed: [String: String]
    ) -> [String: String] {
        var next = dismissed
        for item in items {
            next.removeValue(forKey: item.id)
        }
        return next
    }

    public static func filterReviews(
        _ items: [API.GitHubReviewRequest],
        prefs: ReviewFilterPrefs
    ) -> [API.GitHubReviewRequest] {
        items.filter { (prefs.direct && $0.direct) || (prefs.team && $0.team) }
    }

    public static func countReviews(_ items: [API.GitHubReviewRequest]) -> ReviewCounts {
        var direct = 0
        var team = 0
        for item in items {
            if item.direct { direct += 1 }
            if item.team { team += 1 }
        }
        return ReviewCounts(direct: direct, team: team)
    }

    public static func buildReviewInput(
        response: API.GitHubReviewRequestsResponse?,
        dismissed: [String: String],
        prefs: ReviewFilterPrefs,
        approved: Int
    ) -> ReviewInput {
        let all = response?.items ?? []
        let active = excludeDismissed(all, dismissed: dismissed)
        let visible = filterReviews(active, prefs: prefs)
        let hidden = filterReviews(all, prefs: prefs).filter { isDismissed($0, in: dismissed) }
        return ReviewInput(
            configured: response?.configured ?? false,
            requests: visible,
            approved: approved,
            prefs: prefs,
            counts: countReviews(active),
            dismissed: hidden.count
        )
    }

    // MARK: - Settings attention

    /// Sidebar/rail attention dot: secrets can't be stored, or a required harness key is missing.
    public static func settingsNeedAttention(_ list: API.SecretList?) -> Bool {
        guard let list else { return false }
        return !list.keyConfigured || !ProviderSecretsHelpers.missingConnections(list.secrets).isEmpty
    }

    // MARK: - Whole rail model

    public static func buildModel(
        dock: [RailItem],
        pathname: String,
        review: ReviewInput,
        needsYou: Int,
        settingsNeedYou: Bool
    ) -> RailModel {
        let settings = RailItem(
            id: settingsItemId,
            label: settingsNeedYou ? "Settings: a setting runs need is missing" : "Settings",
            icon: "gear",
            badge: settingsNeedYou ? AreaBadge(tone: .human) : nil,
            active: isPathActive(pathname, href: "/settings")
        )
        let needsItem = RailItem(
            id: needsYouItemId,
            label: needsYou > 0 ? "Needs you, \(needsYou) waiting" : "Needs you",
            icon: "inbox",
            badge: needsYou > 0 ? AreaBadge(text: badgeCount(needsYou), tone: .human) : nil,
            kind: .needsYou
        )
        let middle: [RailItem] = [reviewItem(review), needsItem]
        return RailModel(top: dock, middle: middle, foot: [settings])
    }

    private static func reviewItem(_ r: ReviewInput) -> RailItem {
        let n = r.requests.count
        let waiting = r.configured ? n : 0
        var parts = ["GitHub review requests"]
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if r.approved > 0 { parts.append("\(r.approved) of yours approved") }

        var menu: [MenuItem] = []
        if !r.configured {
            menu.append(MenuItem(id: prSetupId, label: "Add a GitHub token in Settings…", icon: "gear"))
        } else {
            if n == 0 {
                menu.append(MenuItem(id: "pr.none", label: "No review requests", disabled: true))
            }
            for pr in r.requests.prefix(maxListedPRs) {
                menu.append(MenuItem(
                    id: prOpenPrefix + pr.id,
                    label: shorten("\(pr.repository) #\(pr.number)  \(pr.title)", max: 64),
                    icon: "pr"
                ))
            }
            if n > maxListedPRs {
                menu.append(MenuItem(id: "pr.more", label: "\(n - maxListedPRs) more on GitHub", disabled: true))
            }
            menu.append(MenuItem(id: "pr.sep", separator: true))
            menu.append(MenuItem(id: prDirectId, label: "Directly requested (\(r.counts.direct))", checked: r.prefs.direct))
            menu.append(MenuItem(id: prTeamId, label: "Requested of a team (\(r.counts.team))", checked: r.prefs.team))
            menu.append(MenuItem(id: "pr.sep2", separator: true))
            menu.append(MenuItem(id: prRefreshId, label: "Refresh", icon: "refresh"))
            if n > 0 {
                menu.append(MenuItem(id: prClearId, label: "Clear all", icon: "x"))
                menu.append(MenuItem(id: "pr.sep3", separator: true))
                menu.append(MenuItem(
                    id: "pr.dismiss",
                    label: "Dismiss",
                    children: r.requests.prefix(maxListedPRs).map { pr in
                        MenuItem(
                            id: prDismissPrefix + pr.id,
                            label: shorten("\(pr.repository) #\(pr.number)  \(pr.title)", max: 56),
                            icon: "x"
                        )
                    }
                ))
            } else if r.dismissed > 0 {
                menu.append(MenuItem(id: prRestoreId, label: "Restore dismissed (\(r.dismissed))", icon: "history"))
            }
        }

        let badge: AreaBadge? = waiting > 0
            ? AreaBadge(text: badgeCount(waiting), tone: .accent)
            : (r.approved > 0 ? AreaBadge(text: badgeCount(r.approved), tone: .done) : nil)

        return RailItem(
            id: prItemId,
            label: parts.joined(separator: ", "),
            icon: "pr",
            badge: badge,
            menu: menu
        )
    }

    // MARK: - Actions

    public static func resolveAction(
        itemId: String,
        menuItemId: String?,
        reviewURL: (String) -> String?
    ) -> RailAction? {
        if let tabId = InspectorLogic.railDockTabId(from: itemId), menuItemId == nil {
            return .dockTab(tabId)
        }
        switch itemId {
        case settingsItemId where menuItemId == nil:
            return .openSettings(nil)
        case customizationItemId where menuItemId == nil:
            return .openSettings(.pane(pane: .memory))
        case needsYouItemId where menuItemId == nil:
            return .navigate("/inbox")
        case prItemId:
            guard let menuItemId else { return nil }
            if menuItemId == prSetupId { return .openSettings(.pane(pane: .secrets)) }
            if menuItemId == prRefreshId { return .refreshReviews }
            if menuItemId == prClearId { return .clearReviews }
            if menuItemId == prRestoreId { return .restoreReviews }
            if menuItemId == prDirectId { return .toggleReviewPref(.direct) }
            if menuItemId == prTeamId { return .toggleReviewPref(.team) }
            if menuItemId.hasPrefix(prDismissPrefix) {
                let id = String(menuItemId.dropFirst(prDismissPrefix.count))
                return id.isEmpty ? nil : .dismissReview(id)
            }
            if menuItemId.hasPrefix(prOpenPrefix) {
                let id = String(menuItemId.dropFirst(prOpenPrefix.count))
                guard !id.isEmpty, let raw = reviewURL(id),
                      let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http" else {
                    return nil
                }
                return .openExternalURL(url)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Formatting helpers

    /// Keyboard shortcut hint shown beside a right-rail hover tooltip when a global shortcut exists.
    public static func tooltipHint(for item: RailItem) -> String? {
        if item.id == settingsItemId {
            return "⌘,"
        }
        if item.id == dockTabPrefix + ChatInspectorLogic.outlineTabId {
            return "⌘⇧O"
        }
        if item.id.hasPrefix(dockTabPrefix),
           item.active == true || item.id == dockTabPrefix + InspectorLogic.defaultCompanionTabId {
            return "⌘\\"
        }
        return nil
    }

    private static func badgeCount(_ n: Int) -> String {
        n > 99 ? "99+" : String(n)
    }

    private static func shorten(_ s: String, max: Int) -> String {
        guard s.count > max, max > 1 else { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    private static func isPathActive(_ pathname: String, href: String) -> Bool {
        let cleanPath = pathname.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathname
        return cleanPath == href || cleanPath.hasPrefix("\(href)/")
    }
}
