import Foundation

// Port of the pure parts of web/lib/inbox.ts's tray (trayItems, trayAction, isOpen, isExternalHref),
// so the native Needs-you popover groups and acts on items exactly as the web tray does.

public enum InboxTrayTab: String, Equatable, Sendable, CaseIterable {
    case needs, updates
}

/// What a tray row offers inline: approve/deny, a reply box, a Start button, or a labelled link.
public enum InboxTrayAction: Equatable, Sendable {
    case approve
    case reply
    case dispatch
    case open(label: String)
}

public struct InboxTrayItems: Equatable, Sendable {
    public var needs: [InboxItem]
    public var updates: [InboxItem]
    /// Ids of unread updates, for the tab's dot.
    public var unread: [String]
    public init(needs: [InboxItem], updates: [InboxItem], unread: [String]) {
        self.needs = needs
        self.updates = updates
        self.unread = unread
    }
}

public enum InboxTray {
    /// Kinds in the Inbox's urgency order (web GROUPS).
    private static let groups: [[String]] = [
        ["approval", "connector_approval", "secret_approval"], ["secret_expiring"], ["scheduled"],
        ["question"], ["blocked", "stalled"], ["pr_ci_failed", "pr_review_comments"], ["mockup"], ["planning"], ["review"], ["dispatch"], ["mention"],
        ["suggestion"], ["merged"], ["pr_approved"],
    ]

    /// A kind's urgency: its group's place in the Inbox, unknown kinds last.
    public static func kindRank(_ kind: String) -> Int {
        groups.firstIndex { $0.contains(kind) } ?? groups.count
    }

    /// Still waiting and not marked done since it last changed.
    public static func isOpen(_ item: InboxItem) -> Bool { !item.resolved && !item.read }

    /// Opening an item from the tray reads it, except a needs-you item (which resolves itself) unless it is a mention.
    public static func shouldMarkRead(_ item: InboxItem) -> Bool {
        isOpen(item) && (!item.needsYou || item.kind == "mention")
    }

    /// Needs you: open needs_you items by urgency, longest wait first. Updates: the rest, newest first, read or not.
    public static func items(_ items: [InboxItem], updatesLimit: Int = 30) -> InboxTrayItems {
        func age(_ i: InboxItem) -> Date { parseISODate(i.createdAt) }
        let needs = items.filter { $0.needsYou && isOpen($0) }.sorted {
            let ra = kindRank($0.kind), rb = kindRank($1.kind)
            if ra != rb { return ra < rb }
            let a = age($0), b = age($1)
            if a != b { return a < b }
            return $0.id < $1.id
        }
        let updates = Array(items.filter { !$0.needsYou }.sorted {
            let a = age($0), b = age($1)
            if a != b { return a > b }
            return $0.id < $1.id
        }.prefix(updatesLimit))
        return InboxTrayItems(needs: needs, updates: updates, unread: updates.filter(isOpen).map(\.id))
    }

    public static func action(kind: String, hasRun: Bool = true) -> InboxTrayAction {
        if kind == "approval" { return .approve }
        if kind == "question" && hasRun { return .reply }
        if kind == "dispatch" { return .dispatch }
        let labels = [
            "review": "Open review", "mockup": "Open review", "planning": "Review plan", "suggestion": "Review edit",
            "workflow_gate": "Review", "connector_approval": "Review", "secret_approval": "Review",
            "secret_expiring": "Replace", "pr_approved": "Open on GitHub",
            "pr_ci_failed": "Fix CI", "pr_review_comments": "Address comments",
            "blocked": "Open run", "stalled": "Open run",
        ]
        return .open(label: labels[kind] ?? "Open")
    }

    /// An item's href is an app route, except a GitHub pull request's, which is a full URL.
    public static func isExternalHref(_ href: String) -> Bool {
        href.range(of: "^https?://", options: .regularExpression) != nil
    }

    /// POST /inbox/read, the call the web's useReadInbox makes.
    public static func readRequest(_ itemId: String) -> APICall {
        APICall(path: "/api/v1/inbox/read", body: ["id": .string(itemId)])
    }
}
