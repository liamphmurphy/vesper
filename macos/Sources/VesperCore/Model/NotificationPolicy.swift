import Foundation

// Port of the policy half of desktop/src/notifications.ts and the pure part of its monitor.

public enum NotificationLogic {
    public static let kindLabels: [String: String] = [
        "approval": "Approval needed", "question": "Question", "blocked": "Run failed", "stalled": "Run stalled",
        "mockup": "Mockup review", "planning": "Proposal", "review": "Review ready", "dispatch": "Ready to start",
        "mention": "Mention", "suggestion": "Wiki edit", "workflow_gate": "Workflow gate", "scheduled": "Scheduled task",
        "connector_approval": "Connector approval", "secret_approval": "Secret approval",
        "secret_expiring": "Secret expiring", "merged": "PR merged", "pr_approved": "PR approved",
    ]

    static let notifiableKinds = Set(NotificationKind.all)

    public static func countNeedsYou(_ items: [InboxItem]) -> Int {
        items.reduce(0) { $0 + (!$1.resolved && !$1.read && $1.needsYou ? 1 : 0) }
    }

    /// "" for none, the count, or "99+".
    public static func formatDockBadge(_ count: Int) -> String {
        if count <= 0 { return "" }
        return count > 99 ? "99+" : String(count)
    }

    public static func itemSignature(_ item: InboxItem) -> String { "\(item.id):\(item.createdAt)" }

    /// The current Needs-you badge count and any new notifications. When `baselineInitialized` is
    /// false, open items are recorded without alerts so startup doesn't flood Notification Center.
    public static func collectNewNotifications(
        seen: inout Set<String>, items: [InboxItem], baselineInitialized: Bool
    ) -> (badgeCount: Int, alerts: [DesktopAlert]) {
        let badgeCount = countNeedsYou(items)
        var alerts: [DesktopAlert] = []
        for item in items {
            if item.resolved || item.read { continue }
            let signature = itemSignature(item)
            let alreadySeen = !seen.insert(signature).inserted
            if !baselineInitialized || alreadySeen { continue }
            if !item.needsYou && !notifiableKinds.contains(item.kind) { continue }
            let label = kindLabels[item.kind] ?? "Vesper"
            let parts = [item.agent?.name, item.ticketKey, item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            alerts.append(DesktopAlert(
                title: "\(label): \(item.title)",
                body: parts.isEmpty ? "Open in Vesper" : parts.joined(separator: " · "),
                href: item.href.isEmpty ? "/inbox" : item.href,
                signature: signature,
                kind: item.kind,
                itemId: item.id,
                runId: item.runId.flatMap { $0.isEmpty ? nil : $0 },
                ticketKey: item.ticketKey.flatMap { $0.isEmpty ? nil : $0 },
                agentHandle: item.agent?.handle.flatMap { $0.isEmpty ? nil : $0 }
            ))
        }
        return (badgeCount, alerts)
    }

    public static func shouldRefreshInbox(forEvent type: String) -> Bool {
        if type == "reset" { return true }
        let entity = type.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return ["inbox", "run", "approval", "ticket", "workflow"].contains(entity)
    }

    // MARK: Quiet hours, grouping, actions

    private static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    /// Whether `now` (local time) falls in the quiet window. The window may cross midnight. Equal
    /// start and end means no quiet time at all.
    public static func isWithinQuietHours(_ now: Date, _ quiet: QuietHours, calendar: Calendar = .current) -> Bool {
        guard quiet.enabled, let start = minutes(quiet.start), let end = minutes(quiet.end), start != end else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let cur = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start < end ? (cur >= start && cur < end) : (cur >= start || cur < end)
    }

    /// Whether an alert should be shown at all. Suppressed alerts are still marked seen.
    public static func shouldShowAlert(_ alert: DesktopAlert, _ policy: NotificationPolicy, now: Date, calendar: Calendar = .current) -> Bool {
        if !policy.enabled { return false }
        if isWithinQuietHours(now, policy.quietHours, calendar: calendar) { return false }
        if alert.kind == "run_finished" { return policy.runFinished }
        return policy.kinds[alert.kind] != false
    }

    /// Notification Center thread: one ticket, else one run. Nil when grouping is off or nothing to group by.
    public static func alertGroupId(_ alert: DesktopAlert, groupByWork: Bool) -> String? {
        if !groupByWork { return nil }
        if let t = alert.ticketKey, !t.isEmpty { return "ticket:\(t)" }
        if let r = alert.runId, !r.isEmpty { return "run:\(r)" }
        return nil
    }

    public enum AlertAction: Equatable, Sendable {
        case decide(approve: String, decline: String)
        case reply(placeholder: String)
        case none
    }

    /// Which inline controls a notification gets.
    public static func alertActionFor(_ alert: DesktopAlert, actionsEnabled: Bool) -> AlertAction {
        if !actionsEnabled { return .none }
        if decisionRequest(alert, .approve) != nil { return .decide(approve: "Approve", decline: "Decline") }
        if alert.kind == "question", let t = alert.ticketKey, !t.isEmpty, let h = alert.agentHandle, !h.isEmpty {
            return .reply(placeholder: "Reply to \(h)")
        }
        return .none
    }

    public enum Decision: Sendable { case approve, deny }

    private static func isUUID(_ s: String) -> Bool { s.range(of: uuidPattern, options: .regularExpression) != nil }

    /// The existing API call that approves or declines an inbox item, or nil.
    public static func decisionRequest(_ alert: DesktopAlert, _ decision: Decision) -> APICall? {
        let parts = alert.itemId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, isUUID(parts[1]) else { return nil }
        let id = parts[1]
        switch parts[0] {
        case "approval":
            guard alert.kind == "approval" else { return nil }
            return APICall(path: "/api/v1/approvals/\(id)/\(decision == .approve ? "approve" : "deny")", body: [:])
        case "connector_approval":
            guard alert.kind == "connector_approval" else { return nil }
            return APICall(path: "/api/v1/connector-approvals/\(id)", body: ["decision": .string(decision == .approve ? "allow" : "deny")])
        case "secret_approval":
            guard alert.kind == "secret_approval" else { return nil }
            return APICall(path: "/api/v1/api-secret-approvals/\(id)", body: ["decision": .string(decision == .approve ? "allow" : "deny")])
        default:
            return nil
        }
    }

    /// A reply to a run's question: a ticket comment mentioning the agent.
    public static func replyRequest(_ alert: DesktopAlert, _ reply: String) -> APICall? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.utf16.count > 20_000 { return nil }
        guard alert.kind == "question", let ticket = alert.ticketKey, let handle = alert.agentHandle,
              ticket.range(of: #"^[A-Z][A-Z0-9_]{0,31}-[1-9][0-9]{0,8}\z"#, options: .regularExpression) != nil,
              handle.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z"#, options: .regularExpression) != nil
        else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        let mentioned = text.range(of: "(^|[^\\w@])@\(escaped)(?![\\w-])", options: [.regularExpression, .caseInsensitive]) != nil
        return APICall(path: "/api/v1/tickets/\(ticket)/comments", body: ["body_md": .string(mentioned ? text : "@\(handle) \(text)")])
    }

    /// The Touch ID scope an inbox approval kind falls under.
    public static func touchIdScopeForKind(_ kind: String) -> TouchIdScope? {
        switch kind {
        case "approval": return .runApprovals
        case "connector_approval": return .connectorApprovals
        case "secret_approval": return .secretApprovals
        default: return nil
        }
    }
}

let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z"#
let ticketKeyPattern = #"^[A-Z][A-Z0-9_]{0,31}-[1-9][0-9]{0,8}\z"#
