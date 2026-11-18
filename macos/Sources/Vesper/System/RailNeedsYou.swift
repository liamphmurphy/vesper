import AppKit
import Observation
import VesperCore

/// The inbox items the right rail's Needs-you popover lists. Observable, so the open popover
/// follows the inbox monitor's updates.
@MainActor
@Observable
final class RailInbox {
    var items: [InboxItem] = [] {
        didSet { needsYou = TrayModel.newestNeedsYou(items) }
    }
    /// Open, unread items that need the person, newest first.
    private(set) var needsYou: [InboxItem] = []
}

/// What the Needs-you popover can do with an item.
enum RailItemActions {
    static func alert(for item: InboxItem) -> DesktopAlert {
        DesktopAlert(
            title: item.title, body: item.summary ?? "", href: item.href.isEmpty ? "/inbox" : item.href,
            signature: "\(item.id):\(item.createdAt)", kind: item.kind, itemId: item.id,
            runId: item.runId.flatMap { $0.isEmpty ? nil : $0 },
            ticketKey: item.ticketKey.flatMap { $0.isEmpty ? nil : $0 },
            agentHandle: item.agent?.handle.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Approve and Decline: only for the kinds the notification actions cover.
    static func canDecide(_ item: InboxItem) -> Bool {
        NotificationLogic.decisionRequest(alert(for: item), .approve) != nil
    }

    /// A reply field: a question on a ticket from a named agent.
    static func canReply(_ item: InboxItem) -> Bool {
        NotificationLogic.replyRequest(alert(for: item), "x") != nil
    }

    static func replyPlaceholder(_ item: InboxItem) -> String {
        "Reply to \(item.agent?.handle ?? item.agent?.name ?? "the agent")"
    }

    /// "agent · KEY-12", or what there is.
    static func subtitle(_ item: InboxItem) -> String {
        [item.agent?.name, item.ticketKey].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "4m", "2h", "3d".
    static func age(_ createdAt: String, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(parseISODate(createdAt)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

extension SystemServices {
    /// Approve or decline from the popover: the same requests and Touch ID gate as the notification
    /// actions. nil on success, else a short message for the row.
    func railDecide(_ item: InboxItem, approve: Bool) async -> String? {
        let alert = RailItemActions.alert(for: item)
        let decision: NotificationLogic.Decision = approve ? .approve : .deny
        guard let call = NotificationLogic.decisionRequest(alert, decision) else { return "Open it to decide." }
        if approve, let scope = NotificationLogic.touchIdScopeForKind(alert.kind) {
            guard await TouchID.confirm(nativeSettings.touchId, scope: scope) else { return "Touch ID wasn't confirmed." }
        }
        do {
            try await sendRailCall(call)
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? "Couldn't \(approve ? "approve" : "decline")."
        }
    }

    /// Reply to a question from the popover (a ticket comment mentioning the agent). nil on success.
    func railReply(_ item: InboxItem, text: String) async -> String? {
        guard let call = NotificationLogic.replyRequest(RailItemActions.alert(for: item), text) else { return "Couldn't send that." }
        do {
            try await sendRailCall(call)
            return nil
        } catch {
            return (error as? APIError)?.userMessage ?? "Reply not sent."
        }
    }
}
