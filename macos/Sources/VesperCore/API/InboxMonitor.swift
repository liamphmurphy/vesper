import Foundation

private struct InboxResponse: Decodable { var items: [InboxItem]? }

/// Watches GET /api/v1/inbox so the Dock badge, the menu bar and notifications stay accurate even
/// when no window is showing (desktop/src/notifications.ts `InboxMonitor`). It fetches now, then
/// every 120 s as a fallback, and immediately when `handleServerEvent` is given an inbox-relevant
/// SSE event type. The first read is a baseline: items already there raise no alert.
@MainActor
public final class InboxMonitor {
    public static let defaultPollInterval: Duration = .seconds(120)

    /// (badge text such as "3" or "99+", count). Empty text and 0 on 401/403.
    public var onBadgeChange: ((String, Int) -> Void)?
    public var onAlert: ((DesktopAlert) -> Void)?
    /// Every successful read, for the menu bar's and Dock's Needs-you lists.
    public var onItems: (([InboxItem]) -> Void)?
    /// Asked with the alert's href before `onAlert` (e.g. to skip an item the person is looking at).
    public var shouldNotify: ((String) -> Bool)?

    private let pollInterval: Duration
    private var client: APIClient?
    private var seen = Set<String>()
    private var baselineInitialized = false
    private var refreshing = false
    private var refreshPending = false
    private var pollTask: Task<Void, Never>?

    public init(pollInterval: Duration = defaultPollInterval) {
        self.pollInterval = pollInterval
    }

    public func start(client: APIClient) {
        stop()
        self.client = client
        seen.removeAll()
        baselineInitialized = false
        Task { await refreshNow() }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.refreshNow()
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        client = nil
    }

    /// Feed every SSE event type here.
    public func handleServerEvent(_ type: String) {
        if NotificationLogic.shouldRefreshInbox(forEvent: type) { Task { await refreshNow() } }
    }

    public func refreshNow() async {
        guard let client else { return }
        if refreshing {
            refreshPending = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshPending, self.client != nil {
                refreshPending = false
                Task { await refreshNow() }
            }
        }
        do {
            let response: InboxResponse = try await client.get("/api/v1/inbox", timeout: 5)
            guard self.client != nil else { return }
            let items = response.items ?? []
            let (badgeCount, alerts) = NotificationLogic.collectNewNotifications(
                seen: &seen, items: items, baselineInitialized: baselineInitialized
            )
            baselineInitialized = true
            onBadgeChange?(NotificationLogic.formatDockBadge(badgeCount), badgeCount)
            onItems?(items)
            for alert in alerts where shouldNotify?(alert.href) ?? true { onAlert?(alert) }
        } catch APIError.unauthorized {
            onBadgeChange?("", 0)
        } catch {
            // Server unreachable or offline: degrade silently.
        }
    }
}
