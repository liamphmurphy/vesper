import Foundation

private struct RunsResponse: Decodable { var runs: [RunSummary]? }

extension RunLogic {
    /// States in GET /runs?state=live.
    public static let liveStates: Set<String> = ["queued", "starting", "running", "waiting", "waiting_for_quota", "paused"]
    /// States a run that was live can end in.
    public static let terminalStates: Set<String> = ["completed", "failed", "blocked", "cancelled"]
    /// Purposes whose end deserves an alert. A chat run ends after every reply, so it would be noise.
    static let alertPurposes: Set<String> = ["ticket", "planning", "research", "workflow"]

    /// Finds runs that were live at the previous poll and have now ended, and returns one alert per
    /// run, never twice for the same run (`notified` is updated). Cancelled runs get no alert.
    public static func detectFinishedRuns(
        previousLive: [RunSummary], currentLive: [RunSummary], recent: [RunSummary], notified: inout Set<String>
    ) -> [DesktopAlert] {
        let liveIds = Set(currentLive.map(\.id))
        let recentById = Dictionary(recent.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var alerts: [DesktopAlert] = []
        for before in previousLive {
            let id = before.id
            if liveIds.contains(id) || notified.contains(id) { continue }
            guard let after = recentById[id], terminalStates.contains(after.state) else { continue }
            notified.insert(id)
            let purpose = after.purpose.isEmpty ? before.purpose : after.purpose
            if after.state == "cancelled" || !alertPurposes.contains(purpose) { continue }
            let what = [after.workTitle, before.workTitle, after.ticketKey].compactMap { $0 }.first { !$0.isEmpty } ?? "Run"
            let verb = after.state == "completed" ? "Run finished" : after.state == "blocked" ? "Run blocked" : "Run failed"
            let body = [after.agent?.name, after.ticketKey, after.outcome?.trimmingCharacters(in: .whitespacesAndNewlines)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            alerts.append(DesktopAlert(
                title: "\(verb): \(what)",
                body: body.isEmpty ? "Open in Vesper" : body,
                href: "/runs/\(id)",
                signature: "run_finished:\(id)",
                kind: "run_finished",
                itemId: "",
                runId: id,
                ticketKey: after.ticketKey.flatMap { $0.isEmpty ? nil : $0 }
            ))
        }
        return alerts
    }

    /// Sent for every batch of a run's streamed output (up to every 50 ms while a persona works).
    /// Run state and the inbox change through `run.updated` and friends, never through this hint,
    /// so the app-wide monitors ignore it; only the run's own event queries refetch (`LiveUpdates`).
    public static let streamedEventsHint = "run.events"

    public static func shouldRefreshRuns(forEvent type: String) -> Bool {
        guard type != streamedEventsHint else { return false }
        return type == "reset" || type.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) == "run"
    }
}

/// Polls GET /api/v1/runs?state=live (every 20 s while runs are live, backed off to 60 s when idle;
/// SSE `run.*` events wake it immediately via `handleServerEvent`). When a run leaves the live list,
/// fetches the newest page of all runs to learn how it ended.
@MainActor
public final class RunMonitor {
    public static let defaultPollInterval: Duration = .seconds(20)
    public static let defaultIdlePollInterval: Duration = .seconds(60)

    public var onSnapshot: (([RunSummary]) -> Void)?
    public var onFinished: ((DesktopAlert) -> Void)?

    private let pollInterval: Duration
    private let idlePollInterval: Duration
    private var client: APIClient?
    private var refreshing = false
    private var pending = false
    private var previousLive: [RunSummary] = []
    /// Runs that left the live list before their end state showed up, with how many polls they've waited.
    private var unresolved: [String: Int] = [:]
    private var notified = Set<String>()
    private var pollTask: Task<Void, Never>?
    public private(set) var latest: [RunSummary] = []

    /// Active poll interval while runs are live or resolving, backed off while idle.
    public var currentPollInterval: Duration {
        (latest.isEmpty && unresolved.isEmpty) ? idlePollInterval : pollInterval
    }

    public init(pollInterval: Duration = defaultPollInterval, idlePollInterval: Duration? = nil) {
        self.pollInterval = pollInterval
        if let idlePollInterval {
            self.idlePollInterval = idlePollInterval
        } else {
            self.idlePollInterval = pollInterval == Self.defaultPollInterval ? Self.defaultIdlePollInterval : pollInterval
        }
    }

    public func start(client: APIClient) {
        stop()
        self.client = client
        previousLive = []
        unresolved = [:]
        latest = []
        Task { await refreshNow() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.currentPollInterval ?? Self.defaultIdlePollInterval
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

    public func handleServerEvent(_ type: String) {
        if RunLogic.shouldRefreshRuns(forEvent: type) { Task { await refreshNow() } }
    }

    public func refreshNow() async {
        guard let client else { return }
        if refreshing {
            pending = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if pending, self.client != nil {
                pending = false
                Task { await refreshNow() }
            }
        }
        do {
            guard let live = try await list("live", client: client) else { return }
            guard self.client != nil else { return }
            let liveIds = Set(live.map(\.id))
            let gone = previousLive.contains { !liveIds.contains($0.id) }
            let recent = gone ? ((try await list("all", client: client)) ?? []) : []
            let alerts = RunLogic.detectFinishedRuns(previousLive: previousLive, currentLive: live, recent: recent, notified: &notified)
            var next = live
            // A run that left the live list but isn't on the newest page yet (or not yet terminal)
            // is checked again on the next few polls.
            for before in previousLive {
                if liveIds.contains(before.id) || notified.contains(before.id) {
                    unresolved.removeValue(forKey: before.id)
                    continue
                }
                let tries = (unresolved[before.id] ?? 0) + 1
                if tries <= 3 {
                    unresolved[before.id] = tries
                    next.append(before)
                } else {
                    unresolved.removeValue(forKey: before.id)
                }
            }
            previousLive = next
            latest = live
            onSnapshot?(live)
            for alert in alerts { onFinished?(alert) }
        } catch {
            // Unreachable server: keep the last snapshot.
        }
    }

    private func list(_ state: String, client: APIClient) async throws -> [RunSummary]? {
        do {
            let response: RunsResponse = try await client.get("/api/v1/runs?state=\(state)", timeout: 5)
            return response.runs ?? []
        } catch let error as APIError {
            if case .decoding = error { return [] }
            return nil
        }
    }
}
