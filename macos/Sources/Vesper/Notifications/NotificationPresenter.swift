import AppKit
import UserNotifications
import VesperCore

/// Shows alerts in Notification Center with Approve/Decline or an inline Reply, grouped by ticket or
/// run (desktop/src/native-notify.ts). Needs a bundled app: an unbundled debug binary has no
/// bundle identifier, and UNUserNotificationCenter would crash, so every call is then a no-op.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let approval = "vesper.approval"
        static let question = "vesper.question"
    }
    enum ActionID {
        static let approve = "approve"
        static let decline = "decline"
        static let reply = "reply"
    }
    /// What a click on a plain notice does.
    enum NoticeTarget {
        case href(String)
        case logs
    }

    var onOpen: ((DesktopAlert) -> Void)?
    var onDecide: ((DesktopAlert, NotificationLogic.Decision) -> Void)?
    var onReply: ((DesktopAlert, String) -> Void)?
    var onOpenHref: ((String) -> Void)?
    var onOpenCustomApp: ((String) -> Void)?
    var onShowLogs: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    var isAvailable: Bool { center != nil }

    func start() {
        guard let center else {
            vlog("notifications: not a bundled app, skipped")
            return
        }
        center.delegate = self
        let secure: UNNotificationActionOptions = [.authenticationRequired]
        let approval = UNNotificationCategory(
            identifier: Category.approval,
            actions: [UNNotificationAction(identifier: ActionID.approve, title: "Approve", options: secure),
                      UNNotificationAction(identifier: ActionID.decline, title: "Decline", options: secure)],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([approval])
        // The question category's placeholder carries the agent's handle, so it is set per alert.
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    // MARK: Showing

    func show(_ alert: DesktopAlert, policy: NotificationPolicy) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = policy.sound ? .default : nil
        if let group = NotificationLogic.alertGroupId(alert, groupByWork: policy.groupByWork) { content.threadIdentifier = group }
        content.userInfo = Self.encode(alert)
        switch NotificationLogic.alertActionFor(alert, actionsEnabled: policy.actions) {
        case .decide:
            content.categoryIdentifier = Category.approval
        case .reply(let placeholder):
            let identifier = Category.question + "." + placeholder
            let reply = UNTextInputNotificationAction(
                identifier: ActionID.reply, title: "Reply", options: [.authenticationRequired],
                textInputButtonTitle: "Send", textInputPlaceholder: placeholder)
            let category = UNNotificationCategory(identifier: identifier, actions: [reply], intentIdentifiers: [], options: [])
            content.categoryIdentifier = identifier
            Task {
                var categories = await center.notificationCategories()
                categories.insert(category)
                center.setNotificationCategories(categories)
                try? await center.add(UNNotificationRequest(identifier: alert.signature, content: content, trigger: nil))
            }
            return
        case .none:
            break
        }
        Task { try? await center.add(UNNotificationRequest(identifier: alert.signature, content: content, trigger: nil)) }
    }

    /// A plain notice (an action's result, a stack error, a test); clicking runs `target`.
    func notice(title: String, body: String, target: NoticeTarget? = nil, silent: Bool = false) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = silent ? nil : .default
        switch target {
        case .href(let href): content.userInfo = ["notice": "href", "href": href]
        case .logs: content.userInfo = ["notice": "logs"]
        case nil: break
        }
        Task { try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
    }

    /// A notification requested by a Custom App via `os.notifications`; clicking focuses its
    /// standalone window if open, else opens `/apps/<slug>` in the main window.
    @discardableResult
    func customAppNotice(slug: String, title: String, subtitle: String?, body: String, silent: Bool) -> Bool {
        guard let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty, subtitle != title {
            content.subtitle = subtitle
        }
        content.body = body
        content.sound = silent ? nil : .default
        content.threadIdentifier = "vesper.custom-app.\(slug)"
        content.userInfo = ["notice": "customApp", "slug": slug]
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        return true
    }

    /// Settings › Test notification: asks for permission when it hasn't been decided.
    func sendTest(silent: Bool) {
        guard let center else { return }
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            } else if settings.authorizationStatus == .denied {
                vlog("notifications are denied in System Settings")
            }
            notice(title: "Vesper notifications are on", body: "This is what an alert looks like.", silent: silent)
        }
    }

    // MARK: alert <-> userInfo

    nonisolated static func encode(_ alert: DesktopAlert) -> [String: String] {
        var info = [
            "title": alert.title, "body": alert.body, "href": alert.href, "signature": alert.signature,
            "kind": alert.kind, "itemId": alert.itemId,
        ]
        if let v = alert.runId { info["runId"] = v }
        if let v = alert.ticketKey { info["ticketKey"] = v }
        if let v = alert.agentHandle { info["agentHandle"] = v }
        return info
    }

    nonisolated static func decode(_ info: [String: String]) -> DesktopAlert? {
        guard let href = info["href"], let kind = info["kind"] else { return nil }
        return DesktopAlert(
            title: info["title"] ?? "", body: info["body"] ?? "", href: href, signature: info["signature"] ?? "",
            kind: kind, itemId: info["itemId"] ?? "", runId: info["runId"], ticketKey: info["ticketKey"],
            agentHandle: info["agentHandle"])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let k = key as? String, let v = value as? String { info[k] = v }
        }
        Task { @MainActor in
            self.handle(action: action, text: text, info: info)
            completionHandler()
        }
    }

    private func handle(action: String, text: String?, info: [String: String]) {
        if info["notice"] == "logs" { onShowLogs?(); return }
        if info["notice"] == "href", let href = info["href"] { onOpenHref?(href); return }
        if info["notice"] == "customApp", let slug = info["slug"] { onOpenCustomApp?(slug); return }
        guard let alert = Self.decode(info) else { return }
        switch action {
        case ActionID.approve: onDecide?(alert, .approve)
        case ActionID.decline: onDecide?(alert, .deny)
        case ActionID.reply: onReply?(alert, text ?? "")
        case UNNotificationDismissActionIdentifier: break
        default: onOpen?(alert)
        }
    }
}
