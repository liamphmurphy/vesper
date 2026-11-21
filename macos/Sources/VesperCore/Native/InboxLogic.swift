import Foundation

/// What the Inbox needs of an item; `API.InboxItem` conforms.
public protocol InboxListItem {
    var id: String { get }
    var kindName: String { get }
    var createdAt: String { get }
    var resolved: Bool { get }
    var read: Bool { get }
}

extension API.InboxItem: InboxListItem {
    public var kindName: String { kind.rawValue }
}

/// The Inbox's grouping, ordering and focus rules: the Swift port of web/lib/inbox.ts (keep in step).
public enum InboxLogic {
    public enum View: String, Sendable, CaseIterable { case open, done }
    public enum Sort: String, Sendable, CaseIterable { case oldest, newest }
    public enum Tone: Sendable, Equatable { case human, blocked, info }

    public struct Group<Item>: Identifiable {
        public let key: String
        public let label: String
        public var items: [Item]
        public var id: String { key }
    }

    /// Groups in urgency order. Failed and stalled runs share one group.
    public static let groups: [(key: String, label: String, kinds: [String])] = [
        ("approval", "Approvals", ["approval", "connector_approval", "secret_approval"]),
        ("secrets", "Secrets", ["secret_expiring"]),
        ("scheduled", "Scheduled tasks", ["scheduled"]),
        ("question", "Questions", ["question"]),
        ("runs", "Failed & stalled runs", ["blocked", "stalled"]),
        ("pr_feedback", "PR feedback", ["pr_ci_failed", "pr_review_comments"]),
        ("mockup", "Mockups", ["mockup"]),
        ("planning", "Proposals", ["planning"]),
        ("review", "Reviews", ["review"]),
        ("dispatch", "Dispatch", ["dispatch"]),
        ("mention", "Mentions", ["mention"]),
        ("suggestion", "Wiki edits", ["suggestion"]),
        ("merged", "Merged PRs", ["merged"]),
        ("pr_approved", "Approved PRs", ["pr_approved"]),
    ]

    /// Row pill label and tone: "blocked" means something broke, the rest need a person.
    public static let kinds: [String: (label: String, tone: Tone)] = [
        "approval": ("Approval", .human), "question": ("Question", .human), "blocked": ("Failed", .blocked),
        "stalled": ("Stalled", .blocked), "pr_ci_failed": ("CI failed", .blocked),
        "pr_review_comments": ("Review comments", .human), "mockup": ("Mockup", .human),
        "planning": ("Proposal", .human), "review": ("Review", .info), "dispatch": ("Dispatch", .info),
        "mention": ("Mention", .info), "suggestion": ("Wiki edit", .info), "workflow_gate": ("Workflow", .human),
        "scheduled": ("Scheduled", .info), "connector_approval": ("Connector", .human),
        "secret_approval": ("Secret", .human), "secret_expiring": ("Expiring", .human),
        "merged": ("Merged", .info), "pr_approved": ("Approved", .info),
    ]

    public static func kind(_ name: String) -> (label: String, tone: Tone) {
        kinds[name] ?? (name, .info)
    }

    /// A kind's urgency: its group's place in the Inbox, unknown kinds last (web `kindRank`).
    public static func kindRank(_ kind: String) -> Int {
        groups.firstIndex { $0.kinds.contains(kind) } ?? groups.count
    }

    /// Open: still waiting and not marked done since it last changed.
    public static func isOpen(_ item: some InboxListItem) -> Bool { !item.resolved && !item.read }

    /// Visible groups (empty ones dropped), each sorted by wait time, ties by id.
    public static func group<Item: InboxListItem>(_ items: [Item], view: View, sort: Sort) -> [Group<Item>] {
        let shown = items.filter { view == .open ? isOpen($0) : !isOpen($0) }
        let ascending = sort == .oldest
        return groups.compactMap { g in
            let members = shown.filter { g.kinds.contains($0.kindName) }.sorted { a, b in
                let ta = APIDate.epoch(a.createdAt), tb = APIDate.epoch(b.createdAt)
                if ta != tb { return ascending ? ta < tb : ta > tb }
                return a.id < b.id
            }
            return members.isEmpty ? nil : Group(key: g.key, label: g.label, items: members)
        }
    }

    /// Which item to select after the list changes: the selection while it's listed, else the same slot.
    public static func nextSelection(_ ids: [String], selected: String?, lastIndex: Int) -> String? {
        if let selected, ids.contains(selected) { return selected }
        guard !ids.isEmpty else { return nil }
        return ids[min(max(lastIndex, 0), ids.count - 1)]
    }

    /// Move by one with wrap-around, for J/K.
    public static func step(_ ids: [String], selected: String?, by: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let at = ids.firstIndex(of: selected) else { return by > 0 ? ids.first : ids.last }
        return ids[(at + by + ids.count) % ids.count]
    }

    /// A pull request's GitHub URL is external; app routes are not.
    public static func isExternalHref(_ href: String) -> Bool {
        href.hasPrefix("http://") || href.hasPrefix("https://")
    }

    /// The approval's id from its inbox id ("approval:<uuid>"), for /approvals/{id}/{decision}.
    public static func approvalId(_ itemId: String) -> String? {
        itemId.hasPrefix("approval:") ? String(itemId.dropFirst("approval:".count)) : nil
    }

    /// The push request id of a PR feedback item raised on a chat's push ("pr_ci_failed:push:<id>").
    public static func pushRequestId(_ itemId: String) -> String? {
        for prefix in ["pr_ci_failed:push:", "pr_review_comments:push:"] where itemId.hasPrefix(prefix) {
            return String(itemId.dropFirst(prefix.count))
        }
        return nil
    }

    /// The detail pane's headline (detail-pane.tsx HEADLINE), or nil to use the item's title.
    public static func headline(kind: String, agent: String) -> String? {
        switch kind {
        case "approval": "\(agent) is waiting for your approval"
        case "question": "\(agent) is asking you"
        case "blocked": "\(agent)\u{2019}s run failed"
        case "stalled": "\(agent) has been quiet"
        case "pr_ci_failed": "Pull request checks failed"
        case "pr_review_comments": "New pull request review comments"
        case "mockup": "\(agent) needs a mockup decision"
        case "planning": "\(agent) drafted tickets"
        case "review": "Ready for your review"
        case "dispatch": "\(agent) is waiting for dispatch"
        case "mention": "\(agent) mentioned you"
        case "suggestion": "\(agent) suggested a wiki edit"
        default: nil
        }
    }

    /// The info pane's link label (detail-pane.tsx OPEN_LABEL).
    public static func openLabel(kind: String) -> String {
        switch kind {
        case "workflow_gate", "connector_approval": "Review \u{2197}"
        case "scheduled": "Open result \u{2197}"
        case "planning": "Review drafts \u{2197}"
        case "suggestion": "Review wiki edit \u{2197}"
        case "review", "dispatch", "mention": "Open ticket \u{2197}"
        default: "Open \u{2197}"
        }
    }

    /// Prefixes `@handle ` unless the text already mentions that handle (web lib/run-question.ts `withMention`).
    public static func withMention(_ body: String, handle: String) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "(^|[^\\w@])@\(NSRegularExpression.escapedPattern(for: handle))(?![\\w-])"
        if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return text }
        return "@\(handle) \(text)"
    }
}

/// Resolves a ticket or run's agent reference to the person's persona (web lib/work-persona.ts).
public enum WorkPersona {
    /// Agent identity hues in assignment order (web components/domain/avatars.tsx AGENT_HUES).
    public static let hues = ["atlas", "quill", "sentry", "juno", "nova", "relay", "pike", "echo"]

    public static func hue(_ colorIndex: Int) -> String {
        hues[((colorIndex % hues.count) + hues.count) % hues.count]
    }

    /// Same UUID first, then handle, then case-insensitive name (historical records).
    public static func match(_ personas: [API.Persona], id: String?, handle: String?, name: String) -> API.Persona? {
        guard !personas.isEmpty else { return nil }
        if let id, let byId = personas.first(where: { $0.id == id }) { return byId }
        if let handle {
            let h = handle.trimmingCharacters(in: .whitespaces).lowercased()
            if let byHandle = personas.first(where: { $0.handle?.lowercased() == h || $0.id == handle }) { return byHandle }
        }
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        return lower.isEmpty ? nil : personas.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == lower }
    }
}
