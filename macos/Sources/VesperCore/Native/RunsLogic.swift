import Foundation

/// Pure domain logic for the standalone Runs list, run detail header/controls, Plan & Usage context dock,
/// event paging, and approval/question actions. Foundation-only for iOS-over-Tailscale portability.
public enum RunsLogic {
    // MARK: - View Modes & Anchors

    public enum ViewMode: String, Sendable, CaseIterable, Hashable {
        case thread = "simple"
        case trace = "details"
        case graph = "graph"
        case files = "files"

        public var label: String {
            switch self {
            case .thread: "Thread"
            case .trace: "Trace"
            case .graph: "Graph"
            case .files: "Files"
            }
        }
    }

    public struct Anchor: Sendable, Equatable, Hashable {
        public enum Kind: String, Sendable, Equatable, Hashable {
            case turn
            case event
        }

        public var kind: Kind
        public var number: Int

        public init(kind: Kind, number: Int) {
            self.kind = kind
            self.number = number
        }

        public var scrollID: String { "\(kind.rawValue)-\(number)" }
    }

    public struct ViewTab: Sendable, Equatable, Identifiable {
        public var id: String { mode.rawValue }
        public var mode: ViewMode
        public var label: String
        public var count: Int?

        public init(mode: ViewMode, label: String, count: Int? = nil) {
            self.mode = mode
            self.label = label
            self.count = count
        }
    }

    /// Parses `#turn-3`, `turn-3`, or `#event-42` anchors.
    public static func parseAnchor(_ raw: String?) -> Anchor? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let parts = stripped.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = Anchor.Kind(rawValue: String(parts[0])),
              let number = Int(parts[1]),
              number >= 0 else {
            return nil
        }
        return Anchor(kind: kind, number: number)
    }

    /// Resolves the initial tab from `#turn-N`/`#event-N` anchor, `?view=`, or `?tab=`.
    public static func pickViewMode(view: String?, tab: String? = nil, anchor: Anchor? = nil) -> ViewMode {
        if anchor != nil { return .trace }
        for raw in [view, tab] {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
                continue
            }
            if raw == "thread" { return .thread }
            if raw == "trace" { return .trace }
            if let mode = ViewMode(rawValue: raw) { return mode }
        }
        return .thread
    }

    /// Tabs for Run Detail: Graph appears only when child runs exist or Graph is active.
    public static func viewTabs(traceCount: Int?, fileCount: Int, childRunCount: Int, mode: ViewMode) -> [ViewTab] {
        var items: [ViewTab] = [
            ViewTab(mode: .thread, label: "Thread"),
            ViewTab(mode: .trace, label: "Trace", count: traceCount),
        ]
        if childRunCount > 0 || mode == .graph {
            items.append(ViewTab(mode: .graph, label: "Graph"))
        }
        items.append(ViewTab(mode: .files, label: "Files", count: fileCount > 0 ? fileCount : nil))
        return items
    }

    // MARK: - Status, Persona Character & Links

    public struct StatusBadge: Sendable, Equatable {
        public var label: String
        public var tone: String

        public init(label: String, tone: String) {
            self.label = label
            self.tone = tone
        }
    }

    static let stateLabels: [String: (label: String, tone: String)] = [
        "queued": ("Queued", "neutral"),
        "starting": ("Starting", "neutral"),
        "running": ("Running", "done"),
        "waiting": ("Waiting", "human"),
        "waiting_for_quota": ("Waiting for quota", "neutral"),
        "paused": ("Paused", "human"),
        "blocked": ("Blocked", "blocked"),
        "completed": ("Completed", "review"),
        "failed": ("Failed", "blocked"),
        "cancelled": ("Cancelled", "neutral"),
    ]

    static let waitLabels: [String: String] = [
        "approval": "approval",
        "human_reply": "reply",
        "pause": "paused",
        "delegation": "sub agents",
        "mockup_review": "mockup review",
        "checks": "checks",
    ]

    static let purposeLabels: [String: String] = [
        "ticket": "Ticket run",
        "planning": "Planning run",
        "chat": "Chat run",
        "research": "Research run",
        "workflow": "Workflow run",
        "learning": "Learning run",
    ]

    public static func statusBadge(for run: API.Run) -> StatusBadge {
        let base = stateLabels[run.state.rawValue] ?? (run.state.rawValue, "neutral")
        if run.state == .waiting, let reason = run.waitReason?.rawValue, let suffix = waitLabels[reason] {
            return StatusBadge(label: "\(base.label) · \(suffix)", tone: base.tone)
        }
        return StatusBadge(label: base.label, tone: base.tone)
    }

    public static func stateTone(_ state: String) -> Tone {
        switch state {
        case "running": .done
        case "waiting", "paused": .human
        case "failed", "blocked": .blocked
        default: .neutral
        }
    }

    /// Maps a run's lifecycle state to its animated SVG character state (`web/lib/work-persona.ts`).
    public static func characterState(for run: API.Run) -> CharacterState {
        switch run.state.rawValue {
        case "running": .coding
        case "waiting", "paused": .needsYou
        case "queued", "starting": .thinking
        default: .staticState
        }
    }

    public static func purposeLabel(_ purpose: String) -> String {
        purposeLabels[purpose] ?? purpose.capitalized
    }

    /// Where the work of a run lives; never returns `/tickets/` without a key.
    public static func workHref(for run: API.Run) -> String? {
        switch run.purpose.rawValue {
        case "ticket":
            guard !run.ticketKey.isEmpty else { return nil }
            return "/tickets/\(MarkdownSource.encodeURIComponent(run.ticketKey))"
        case "planning":
            guard let id = run.planningId, !id.isEmpty else { return nil }
            return "/plans?id=\(MarkdownSource.encodeURIComponent(id))"
        case "chat":
            guard let id = run.chatId, !id.isEmpty else { return nil }
            let base = "/chat/\(MarkdownSource.encodeURIComponent(id))"
            if let project = run.projectKey, !project.isEmpty {
                return "\(base)?project=\(MarkdownSource.encodeURIComponent(project))"
            }
            return base
        default:
            return nil
        }
    }

    public static func isLive(_ run: API.Run) -> Bool {
        !WorkLogic.isEnded(run.state.rawValue)
    }

    /// Ticket runs waiting on `human_reply` answer directly on the run page; plans and chats reply in place.
    public static func waitsForReply(_ run: API.Run) -> Bool {
        run.state == .waiting
            && run.waitReason == .humanReply
            && run.purpose != .planning
            && run.purpose != .chat
    }

    public static func canWriteFollowUp(_ run: API.Run) -> Bool {
        isLive(run) && run.purpose == .ticket && !run.ticketKey.isEmpty
    }

    /// Sidebar muted line: current plan step while live, else `ticket · agent` (or `purpose · agent`).
    public static func runLine(_ run: API.Run) -> String {
        if isLive(run) {
            let sorted = run.plan.sorted { $0.position < $1.position }
            if let idx = sorted.firstIndex(where: { $0.state == .current }) {
                return "Step \(idx + 1) of \(sorted.count) · \(sorted[idx].text)"
            }
        }
        let subject = !run.ticketKey.isEmpty ? run.ticketKey : purposeLabel(run.purpose.rawValue)
        return [subject, run.agent.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Plan Progress & Usage Telemetry

    public struct StepProgress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var current: API.PlanStep?
        public var steps: [API.PlanStep]

        public init(done: Int, total: Int, current: API.PlanStep?, steps: [API.PlanStep]) {
            self.done = done
            self.total = total
            self.current = current
            self.steps = steps
        }

        public var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(done) / Double(total)
        }
    }

    public static func stepProgress(for run: API.Run) -> StepProgress {
        let steps = run.plan.sorted { $0.position < $1.position }
        let done = steps.filter { $0.state == .done }.count
        let current = steps.first(where: { $0.state == .current })
            ?? steps.first(where: { $0.state == .needsHuman || $0.state == .failed })
        return StepProgress(done: done, total: steps.count, current: current, steps: steps)
    }

    public struct CostSummary: Sendable, Equatable {
        public var primary: String
        public var subSuffix: String?
        public var combined: String

        public init(primary: String, subSuffix: String?, combined: String) {
            self.primary = primary
            self.subSuffix = subSuffix
            self.combined = combined
        }
    }

    public static func costSummary(for detail: API.RunDetail) -> CostSummary {
        let primary = WorkLogic.runCost(detail.run.costUsd, source: detail.run.costSource)
        guard !detail.childRuns.isEmpty else {
            return CostSummary(primary: primary, subSuffix: nil, combined: primary)
        }
        let sub = detail.childRuns.reduce(0.0) { $0 + $1.costUsd }
        let allPriced = detail.childRuns.allSatisfy {
            guard let src = $0.costSource else { return false }
            return !src.isEmpty && src != "unknown"
        }
        let suffix = "\(allPriced ? "+" : "≥ +")$\(String(format: "%.2f", sub)) sub"
        return CostSummary(primary: primary, subSuffix: suffix, combined: "\(primary) (\(suffix))")
    }

    public struct ModelUsage: Sendable, Equatable, Identifiable {
        public var id: String { model }
        public var model: String
        public var runs: Int
        public var cost: Double
        public var unpriced: Bool
        public var summary: String

        public init(model: String, runs: Int, cost: Double, unpriced: Bool) {
            self.model = model
            self.runs = runs
            self.cost = cost
            self.unpriced = unpriced
            let costStr = "\(unpriced ? "≥ " : "")$\(String(format: "%.2f", cost))"
            self.summary = "\(runs) run\(runs == 1 ? "" : "s") · \(costStr)"
        }
    }

    public static func usageByModel(_ runs: [API.Run]) -> [ModelUsage] {
        var map: [String: (runs: Int, cost: Double, unpriced: Bool)] = [:]
        for run in runs {
            var cur = map[run.model] ?? (0, 0, false)
            cur.runs += 1
            cur.cost += run.costUsd
            let src = run.costSource
            if src == nil || src == "unknown" || src == "partial" {
                cur.unpriced = true
            }
            map[run.model] = cur
        }
        return map.map { ModelUsage(model: $0.key, runs: $0.value.runs, cost: $0.value.cost, unpriced: $0.value.unpriced) }
            .sorted {
                if $0.cost != $1.cost { return $0.cost > $1.cost }
                return $0.model < $1.model
            }
    }

    /// 0...1 share of input served from cache; nil when unknown.
    public static func cacheShare(input: Int, cached: Int?) -> Double? {
        guard let cached, input > 0 else { return nil }
        return max(0, min(1, Double(cached) / Double(input)))
    }

    public struct TokenBreakdown: Sendable, Equatable {
        public var input: Int
        public var output: Int
        public var cached: Int
        public var uncached: Int
        public var unknown: Int
        public var hasBreakdown: Bool

        public init(input: Int, output: Int, cached: Int, uncached: Int, unknown: Int, hasBreakdown: Bool) {
            self.input = input
            self.output = output
            self.cached = cached
            self.uncached = uncached
            self.unknown = unknown
            self.hasBreakdown = hasBreakdown
        }
    }

    public static func tokenBreakdown(eventPayload: [String: JSONValue]) -> TokenBreakdown {
        let input = max(0, jsonInt(eventPayload["input_tokens"]) ?? 0)
        let output = max(0, jsonInt(eventPayload["output_tokens"]) ?? 0)
        let cachedRaw = max(0, jsonInt(eventPayload["cached_tokens"]) ?? 0)
        let reported: Int
        if let explicit = jsonInt(eventPayload["cache_reported_input_tokens"]) {
            reported = explicit
        } else if eventPayload["cached_tokens"] != nil {
            reported = input
        } else {
            reported = 0
        }
        let known = max(0, min(input, reported))
        let cached = max(0, min(cachedRaw, known))
        let uncached = max(0, known - cached)
        let unknown = max(0, input - cached - uncached)
        let hasBreakdown = input == 0 || cached + uncached > 0
        return TokenBreakdown(
            input: input,
            output: output,
            cached: cached,
            uncached: uncached,
            unknown: unknown,
            hasBreakdown: hasBreakdown
        )
    }

    /// 2_100_000 -> "2.1M", 18_400 -> "18.4K", 420 -> "420".
    public static func compactNumber(_ n: Int) -> String {
        if n >= 1_000_000 {
            let formatted = String(format: "%.1f", Double(n) / 1_000_000)
            return (formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) + "M"
        }
        if n >= 1_000 {
            let formatted = String(format: "%.1f", Double(n) / 1_000)
            return (formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) + "K"
        }
        return String(n)
    }

    /// Sentence style ("just now", "12m ago", "5h ago", "3d ago", "on Oct 3") from `web/lib/format.ts` `ago`.
    public static func ago(_ iso: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = APIDate.parse(iso) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 30 { return "\(days)d ago" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "on \(formatter.string(from: date))"
    }

    public static func clockTime(_ iso: String, includeSeconds: Bool = false, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = APIDate.parse(iso) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = includeSeconds ? "HH:mm:ss" : "HH:mm"
        return formatter.string(from: date)
    }

    public static func absoluteTime(_ iso: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = APIDate.parse(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Standalone Runs List Grouping, Needs You & Events Paging

    public struct RunGroup: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var label: String
        public var runs: [API.Run]

        public init(key: String, label: String, runs: [API.Run]) {
            self.key = key
            self.label = label
            self.runs = runs
        }
    }

    /// Running (live & non-queued), Queued, then finished runs by local calendar day ended, latest first.
    /// Runs in `skipIds` (shown under Needs you) and duplicates across pages are dropped.
    public static func groupRuns(
        _ runs: [API.Run],
        skipIds: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [RunGroup] {
        var seen = Set<String>()
        let shown = runs.filter { !skipIds.contains($0.id) && seen.insert($0.id).inserted }
        let running = shown
            .filter { isLive($0) && $0.state != .queued }
            .sorted { APIDate.epoch($0.startedAt) > APIDate.epoch($1.startedAt) }
        let queued = shown
            .filter { $0.state == .queued }
            .sorted { APIDate.epoch($0.startedAt) > APIDate.epoch($1.startedAt) }
        let ended = shown
            .filter { !isLive($0) }
            .sorted { APIDate.epoch($0.endedAt ?? $0.startedAt) > APIDate.epoch($1.endedAt ?? $1.startedAt) }

        var groups: [RunGroup] = []
        if !running.isEmpty {
            groups.append(RunGroup(key: "running", label: "Running", runs: running))
        }
        if !queued.isEmpty {
            groups.append(RunGroup(key: "queued", label: "Queued", runs: queued))
        }
        for run in ended {
            let label = WorkLogic.dayLabel(run.endedAt ?? run.startedAt, now: now, calendar: calendar, locale: locale)
            let key = "day:\(label)"
            if let last = groups.indices.last, groups[last].key == key {
                groups[last].runs.append(run)
            } else {
                groups.append(RunGroup(key: key, label: label, runs: [run]))
            }
        }
        return groups
    }

    /// The Needs-you item after `runId` (wrapping), else the first one not for `runId`.
    public static func nextNeedsItem(in items: [API.InboxItem], afterRunId runId: String) -> API.InboxItem? {
        guard !items.isEmpty else { return nil }
        if let idx = items.firstIndex(where: { $0.runId == runId }) {
            let reordered = Array(items[(idx + 1)...]) + Array(items[..<idx])
            return reordered.first { $0.runId != runId }
        }
        return items.first { $0.runId != runId }
    }

    public static func itemHref(_ item: API.InboxItem, listQuery: String = "") -> String {
        if let runId = item.runId, !runId.isEmpty {
            return listQuery.isEmpty ? "/runs/\(runId)" : "/runs/\(runId)?\(listQuery)"
        }
        return item.href
    }

    public static func runnerSlot(from events: [API.RunEvent]) -> (runner: String, backend: String)? {
        for event in events.reversed() {
            guard event.type == .lifecycle,
                  event.payload["state"]?.stringValue == "starting" else { continue }
            let runner = event.payload["runner"]?.stringValue ?? ""
            let backend = event.payload["backend"]?.stringValue ?? ""
            if !runner.isEmpty || !backend.isEmpty {
                return (runner: runner, backend: backend)
            }
        }
        return nil
    }

    private static let waitKeywords: Set<String> = ["approval", "human_reply", "pause", "delegation"]

    /// Newest `await_human` tool call `input.reason`, else `waiting` lifecycle `reason` (ignoring bare keywords).
    public static func latestQuestion(from events: [API.RunEvent]) -> String? {
        for event in events.reversed() {
            if event.type == .toolCall,
               let tool = event.payload["tool"]?.stringValue,
               tool == "await_human" || tool.hasSuffix("__await_human") || tool.hasSuffix(".await_human"),
               let reason = event.payload["input"]?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty {
                return reason
            }
            if event.type == .lifecycle,
               event.payload["state"]?.stringValue == "waiting",
               let reason = event.payload["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reason.isEmpty,
               !waitKeywords.contains(reason) {
                return reason
            }
        }
        return nil
    }

    public static let runEventsPage = 1000
    public static let runEventsOverlap = 32

    /// Cursor for incremental `GET /runs/{id}/events?after=` with tail overlap so late-committed seqs aren't missed.
    public static func nextEventsCursor(known: [API.RunEvent], overlap: Int = runEventsOverlap) -> Int {
        guard known.count > overlap else { return 0 }
        return known[known.count - overlap - 1].seq
    }

    /// Merges incoming events into existing ones, deduplicating by `seq` and sorting ascending.
    public static func mergeEvents(existing: [API.RunEvent], incoming: [API.RunEvent]) -> [API.RunEvent] {
        guard !incoming.isEmpty else { return existing }
        var bySeq: [Int: API.RunEvent] = Dictionary(uniqueKeysWithValues: existing.map { ($0.seq, $0) })
        for event in incoming {
            bySeq[event.seq] = event
        }
        return bySeq.values.sorted { $0.seq < $1.seq }
    }

    // MARK: - Controls, Approvals & Questions

    public struct ControlState: Sendable, Equatable {
        public var canPause: Bool
        public var canResume: Bool
        public var resumeLabel: String
        public var canCancel: Bool
        public var canRetry: Bool

        public init(canPause: Bool, canResume: Bool, resumeLabel: String, canCancel: Bool, canRetry: Bool) {
            self.canPause = canPause
            self.canResume = canResume
            self.resumeLabel = resumeLabel
            self.canCancel = canCancel
            self.canRetry = canRetry
        }
    }

    public static func controlState(for run: API.Run) -> ControlState {
        let live = isLive(run)
        let managed = run.mode == .managed
        let canResume = live && ((managed && run.state == .paused) || run.state == .waitingForQuota)
        let canPause = live && managed && run.state != .paused && run.state != .waitingForQuota && run.state != .queued
        let resumeLabel = run.state == .waitingForQuota ? "Try now" : "Resume"
        let canRetry = (run.state == .failed || run.state == .cancelled)
            && !run.ticketKey.isEmpty
            && (run.parentRunId ?? "").isEmpty
        return ControlState(
            canPause: canPause,
            canResume: canResume,
            resumeLabel: resumeLabel,
            canCancel: live,
            canRetry: canRetry
        )
    }

    public static func controlActionRequest(runId: String, action: API.ControlRunAction) -> APIRequest<API.Run> {
        API.controlRun(id: runId, action: action)
    }

    public static func approvalDecisionRequest(
        approvalId: String,
        decision: API.DecideApprovalDecision,
        note: String?
    ) -> APIRequest<API.Approval> {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = decision == .deny && !(trimmed ?? "").isEmpty ? API.DecideApprovalBody(note: trimmed) : nil
        return API.decideApproval(id: approvalId, decision: decision, body: body)
    }

    public static func replyCommentRequest(
        ticketKey: String,
        agentHandle: String,
        body: String
    ) -> APIRequest<API.ActivityEvent>? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ticketKey.isEmpty else { return nil }
        let formatted = agentHandle.isEmpty ? trimmed : InboxLogic.withMention(trimmed, handle: agentHandle)
        return API.createComment(key: ticketKey, body: API.NewComment(bodyMd: formatted))
    }

    public static let runMutationInvalidation = QueryInvalidation(resources: ["runs", "tickets", "inbox", "bootstrap"])

    public static func rawLogPath(runId: String, turnSeq: Int) -> String {
        "/api/v1/runs/\(APIPath.escape(runId))/turns/\(turnSeq)/log"
    }

    // MARK: - Context Dock & Inspector Model

    public struct TicketContext: Sendable, Equatable {
        public var key: String
        public var title: String
        public var statusLabel: String
        public var priorityLabel: String
        public var epicId: String?
        public var epicName: String?
        public var epicDone: Int?
        public var epicTotal: Int?
        public var criteria: [API.Criterion]

        public init(
            key: String,
            title: String,
            statusLabel: String,
            priorityLabel: String,
            epicId: String? = nil,
            epicName: String? = nil,
            epicDone: Int? = nil,
            epicTotal: Int? = nil,
            criteria: [API.Criterion] = []
        ) {
            self.key = key
            self.title = title
            self.statusLabel = statusLabel
            self.priorityLabel = priorityLabel
            self.epicId = epicId
            self.epicName = epicName
            self.epicDone = epicDone
            self.epicTotal = epicTotal
            self.criteria = criteria
        }
    }

    public struct CodeContext: Sendable, Equatable {
        public var branch: String?
        public var additions: Int?
        public var deletions: Int?
        public var prNumber: Int?
        public var prState: String?
        public var prUrl: String?

        public init(
            branch: String? = nil,
            additions: Int? = nil,
            deletions: Int? = nil,
            prNumber: Int? = nil,
            prState: String? = nil,
            prUrl: String? = nil
        ) {
            self.branch = branch
            self.additions = additions
            self.deletions = deletions
            self.prNumber = prNumber
            self.prState = prState
            self.prUrl = prUrl
        }
    }

    public struct SubAgentRow: Sendable, Equatable, Identifiable {
        public var id: String
        public var agentName: String
        public var subtitle: String
        public var stateTone: Tone

        public init(id: String, agentName: String, subtitle: String, stateTone: Tone) {
            self.id = id
            self.agentName = agentName
            self.subtitle = subtitle
            self.stateTone = stateTone
        }
    }

    public struct ContextFact: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var value: String
        public var mono: Bool
        public var href: String?
        public var url: String?

        public init(id: String, label: String, value: String, mono: Bool = false, href: String? = nil, url: String? = nil) {
            self.id = id
            self.label = label
            self.value = value
            self.mono = mono
            self.href = href
            self.url = url
        }
    }

    public struct TurnUsageRow: Sendable, Equatable, Identifiable {
        public var id: String { "turn:\(seq)" }
        public var seq: Int
        public var summary: String

        public init(seq: Int, summary: String) {
            self.seq = seq
            self.summary = summary
        }
    }

    public struct UsageContext: Sendable, Equatable {
        public var tokensSummary: String
        public var costSummary: String
        public var cacheSharePct: Int?
        public var turns: [TurnUsageRow]
        public var models: [ModelUsage]

        public init(
            tokensSummary: String,
            costSummary: String,
            cacheSharePct: Int?,
            turns: [TurnUsageRow],
            models: [ModelUsage]
        ) {
            self.tokensSummary = tokensSummary
            self.costSummary = costSummary
            self.cacheSharePct = cacheSharePct
            self.turns = turns
            self.models = models
        }
    }

    public struct ContextDockModel: Sendable, Equatable {
        public var plan: StepProgress
        public var ticket: TicketContext?
        public var code: CodeContext?
        public var subAgents: [SubAgentRow]
        public var facts: [ContextFact]
        public var usage: UsageContext
        public var rawLogPath: String?
        public var environmentHref: String
        public var hasChildren: Bool

        public init(
            plan: StepProgress,
            ticket: TicketContext?,
            code: CodeContext?,
            subAgents: [SubAgentRow],
            facts: [ContextFact],
            usage: UsageContext,
            rawLogPath: String?,
            environmentHref: String,
            hasChildren: Bool
        ) {
            self.plan = plan
            self.ticket = ticket
            self.code = code
            self.subAgents = subAgents
            self.facts = facts
            self.usage = usage
            self.rawLogPath = rawLogPath
            self.environmentHref = environmentHref
            self.hasChildren = hasChildren
        }
    }

    public static func buildContextDock(
        detail: API.RunDetail,
        events: [API.RunEvent]? = nil,
        ticket: API.Ticket? = nil,
        epic: API.EpicOverview? = nil,
        grandchildren: [[API.Run]] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> ContextDockModel {
        let run = detail.run
        let allEvents = events ?? detail.events
        let plan = stepProgress(for: run)
        let cost = costSummary(for: detail)

        let ticketCtx: TicketContext? = ticket.map { t in
            TicketContext(
                key: t.key,
                title: t.title,
                statusLabel: t.status.rawValue.replacingOccurrences(of: "_", with: " "),
                priorityLabel: t.priority.rawValue,
                epicId: t.epic?.id,
                epicName: t.epic?.name,
                epicDone: epic?.counts.done,
                epicTotal: epic?.counts.total,
                criteria: t.criteria.sorted { $0.position < $1.position }
            )
        }

        let branch = (ticket?.branch?.isEmpty == false ? ticket?.branch : nil) ?? (run.branch?.isEmpty == false ? run.branch : nil)
        let prNumber = ticket?.pr?.number ?? run.prNumber
        let prState = ticket?.pr?.state.rawValue ?? run.prState
        let prUrl = ticket?.pr?.url ?? run.prUrl
        let codeCtx: CodeContext? = (branch != nil || prNumber != nil)
            ? CodeContext(
                branch: branch,
                additions: ticket?.pr?.additions,
                deletions: ticket?.pr?.deletions,
                prNumber: prNumber,
                prState: prState,
                prUrl: prUrl
            )
            : nil

        let subAgents = detail.childRuns.map { child in
            let subElapsed = APIDate.duration(since: child.startedAt, until: child.endedAt, now: now)
            let subCost = WorkLogic.runCost(child.costUsd, source: child.costSource)
            return SubAgentRow(
                id: child.id,
                agentName: child.agent.name,
                subtitle: "\(child.model) · \(subElapsed) · \(subCost)",
                stateTone: stateTone(child.state.rawValue)
            )
        }

        let slot = runnerSlot(from: allEvents)
        let slotText = slot.map { [$0.runner, $0.backend].filter { !$0.isEmpty }.joined(separator: " · ") }
            ?? (run.mode == .unmanaged ? "none (unmanaged)" : "–")

        let elapsed = APIDate.duration(since: run.startedAt, until: run.endedAt, now: now)
        let started = ago(run.startedAt, now: now, calendar: calendar, locale: locale)
        let subRunsCount = run.childCount ?? detail.childRuns.count

        var facts: [ContextFact] = [
            ContextFact(id: "purpose", label: "Purpose", value: purposeLabel(run.purpose.rawValue)),
            ContextFact(id: "model", label: "Model", value: run.model, mono: true),
            ContextFact(id: "harness", label: "Harness", value: "\(run.harness) · \(run.mode.rawValue)", mono: true),
            ContextFact(id: "started", label: "Started", value: started),
            ContextFact(id: "elapsed", label: "Elapsed", value: elapsed, mono: true),
            ContextFact(id: "cost", label: "Cost", value: cost.combined, mono: true),
            ContextFact(
                id: "tokens",
                label: "Tokens",
                value: "\(compactNumber(run.inputTokens + run.outputTokens)) · \(run.toolCalls) tool calls",
                mono: true
            ),
        ]
        if subRunsCount > 0 {
            facts.append(ContextFact(id: "sub_runs", label: "Sub runs", value: String(subRunsCount), mono: true))
        }
        facts.append(ContextFact(id: "slot", label: "Runner slot", value: slotText, mono: true))
        if let dispatcher = run.dispatchedBy {
            facts.append(ContextFact(id: "dispatched_by", label: "Dispatched by", value: dispatcher.name))
        }
        if let workspace = run.workspacePath, !workspace.isEmpty {
            facts.append(ContextFact(id: "workspace", label: "Workspace", value: workspace, mono: true))
        }

        var seenRuns = Set<String>()
        let allUsageRuns = ([run] + detail.childRuns + grandchildren.flatMap { $0 })
            .filter { seenRuns.insert($0.id).inserted }
        let modelUsages = usageByModel(allUsageRuns)
        let share = cacheShare(input: run.inputTokens, cached: run.cachedInputTokens)
        let sharePct = share.map { Int(($0 * 100).rounded()) }
        let turnRows = detail.turns.map { turn in
            let usage = turn.usage ?? [:]
            let inputTok = jsonInt(usage["input_tokens"]) ?? 0
            let outputTok = jsonInt(usage["output_tokens"]) ?? 0
            let costVal = jsonDouble(usage["cost_usd"]) ?? 0
            let costSource = usage["cost_source"]?.stringValue
            let summary = "\(compactNumber(inputTok)) in · \(compactNumber(outputTok)) out · \(WorkLogic.runCost(costVal, source: costSource))"
            return TurnUsageRow(seq: turn.seq, summary: summary)
        }
        let usageCtx = UsageContext(
            tokensSummary: "\(compactNumber(run.inputTokens)) in · \(compactNumber(run.outputTokens)) out",
            costSummary: cost.combined,
            cacheSharePct: sharePct,
            turns: turnRows,
            models: modelUsages
        )

        let lastLog = detail.turns.reversed().first(where: { $0.hasLog })
        let rawLog = lastLog.map { rawLogPath(runId: run.id, turnSeq: $0.seq) }
        return ContextDockModel(
            plan: plan,
            ticket: ticketCtx,
            code: codeCtx,
            subAgents: subAgents,
            facts: facts,
            usage: usageCtx,
            rawLogPath: rawLog,
            environmentHref: "/settings/runner?run_id=\(MarkdownSource.encodeURIComponent(run.id))",
            hasChildren: !detail.childRuns.isEmpty || subRunsCount > 0
        )
    }

    /// Converts a `ContextDockModel` to declarative `InspectorSection` items (matching `web/lib/native-shell/models/run-inspector.ts`).
    public static func buildInspectorSections(dock: ContextDockModel, mode: ViewMode) -> [InspectorSection] {
        var sections: [InspectorSection] = []

        if !dock.plan.steps.isEmpty {
            sections.append(InspectorSection(
                id: "plan",
                title: "Plan",
                aside: "\(dock.plan.done)/\(dock.plan.total)",
                items: [
                    InspectorItem(
                        id: "plan_steps",
                        kind: .checklist,
                        steps: dock.plan.steps.map { step in
                            InspectorStep(
                                id: "step:\(step.position)",
                                text: step.text,
                                state: InspectorStepState(rawValue: step.state.rawValue) ?? .pending
                            )
                        }
                    ),
                ]
            ))
        }

        if let t = dock.ticket {
            var items: [InspectorItem] = [
                InspectorItem(
                    id: "ticket_link",
                    kind: .fact,
                    label: "Ticket",
                    value: "\(t.key) · \(t.title)",
                    href: "/tickets/\(MarkdownSource.encodeURIComponent(t.key))"
                ),
                InspectorItem(
                    id: "ticket_state",
                    kind: .fact,
                    label: "State",
                    value: "\(t.statusLabel) · \(t.priorityLabel)"
                ),
            ]
            if let epicId = t.epicId, let epicName = t.epicName {
                items.append(InspectorItem(
                    id: "epic_link",
                    kind: .fact,
                    label: "Epic",
                    value: epicName,
                    href: "/epics/\(MarkdownSource.encodeURIComponent(epicId))"
                ))
                if let done = t.epicDone, let total = t.epicTotal, total > 0 {
                    items.append(InspectorItem(
                        id: "epic_progress",
                        kind: .progress,
                        label: "Epic progress",
                        detail: "\(done)/\(total) done",
                        tone: .done,
                        fraction: Double(done) / Double(total)
                    ))
                }
            }
            sections.append(InspectorSection(id: "ticket", title: "Ticket", items: items))

            if !t.criteria.isEmpty {
                let met = t.criteria.filter(\.done).count
                sections.append(InspectorSection(
                    id: "criteria",
                    title: "Acceptance criteria",
                    aside: "\(met)/\(t.criteria.count)",
                    items: [
                        InspectorItem(
                            id: "ticket_criteria",
                            kind: .checklist,
                            steps: t.criteria.map {
                                InspectorStep(id: $0.id, text: $0.text, state: $0.done ? .done : .pending)
                            }
                        ),
                    ]
                ))
            }
        }

        if let code = dock.code, code.branch != nil || code.prNumber != nil {
            var items: [InspectorItem] = []
            if let branch = code.branch {
                items.append(InspectorItem(id: "branch", kind: .fact, label: "Branch", value: branch, mono: true))
            }
            if code.additions != nil || code.deletions != nil {
                items.append(InspectorItem(
                    id: "diff",
                    kind: .fact,
                    label: "Diff",
                    value: "+\(code.additions ?? 0) −\(code.deletions ?? 0)",
                    mono: true
                ))
            }
            if let pr = code.prNumber {
                let prState = code.prState.map { " · \($0)" } ?? ""
                items.append(InspectorItem(
                    id: "pr",
                    kind: .fact,
                    label: "Pull request",
                    value: "#\(pr)\(prState)",
                    url: code.prUrl
                ))
            }
            sections.append(InspectorSection(id: "code", title: "Code", items: items))
        }

        if !dock.subAgents.isEmpty {
            sections.append(InspectorSection(
                id: "sub_agents",
                title: "Sub-agents",
                aside: "\(dock.subAgents.count)",
                items: [
                    InspectorItem(
                        id: "sub_agent_rows",
                        kind: .list,
                        rows: dock.subAgents.map { sub in
                            NavItem(
                                id: sub.id,
                                title: sub.agentName,
                                subtitle: sub.subtitle,
                                status: sub.stateTone,
                                href: "/runs/\(MarkdownSource.encodeURIComponent(sub.id))"
                            )
                        }
                    ),
                ]
            ))
        }

        sections.append(InspectorSection(
            id: "run",
            title: "Run",
            items: dock.facts.map { fact in
                InspectorItem(
                    id: fact.id,
                    kind: .fact,
                    label: fact.label,
                    value: fact.value,
                    mono: fact.mono ? true : nil,
                    href: fact.href,
                    url: fact.url
                )
            }
        ))

        var usageItems: [InspectorItem] = []
        if !dock.usage.tokensSummary.isEmpty {
            usageItems.append(InspectorItem(id: "usage_tokens", kind: .fact, label: "Total tokens", value: dock.usage.tokensSummary, mono: true))
        }
        if !dock.usage.costSummary.isEmpty {
            usageItems.append(InspectorItem(id: "usage_cost", kind: .fact, label: "Estimated cost", value: dock.usage.costSummary, mono: true))
        }
        if let pct = dock.usage.cacheSharePct {
            let clamped = max(0, min(100, pct))
            usageItems.append(InspectorItem(
                id: "cache_share",
                kind: .progress,
                label: "Cache share",
                detail: "\(clamped)%",
                tone: .accent,
                fraction: Double(clamped) / 100.0
            ))
        }
        for turn in dock.usage.turns {
            usageItems.append(InspectorItem(id: "turn:\(turn.seq)", kind: .fact, label: "Turn \(turn.seq)", value: turn.summary, mono: true))
        }
        if dock.usage.models.count > 1 {
            for model in dock.usage.models {
                usageItems.append(InspectorItem(id: "model:\(model.model)", kind: .fact, label: model.model, value: model.summary, mono: true))
            }
        }
        if !usageItems.isEmpty {
            sections.append(InspectorSection(id: "usage", title: "Usage", items: usageItems))
        }

        var viewActions: [InspectorAction] = [
            InspectorAction(id: "view:details", label: "Raw log", icon: "terminal", active: mode == .trace),
        ]
        if dock.hasChildren || mode == .graph {
            viewActions.append(InspectorAction(id: "view:graph", label: "Graph", icon: "graph", active: mode == .graph))
        }
        viewActions.append(InspectorAction(id: "view:files", label: "Files", icon: "folder", active: mode == .files))

        var openItems: [InspectorItem] = [
            InspectorItem(id: "views", kind: .actions, actions: viewActions),
            InspectorItem(id: "environment", kind: .fact, label: "Environment", value: "Open settings", href: dock.environmentHref),
        ]
        if let rawLog = dock.rawLogPath {
            openItems.append(InspectorItem(id: "raw_log", kind: .fact, label: "Raw log", value: "Download JSONL", url: rawLog))
        }
        sections.append(InspectorSection(id: "open", title: "Open", items: openItems))

        return sections
    }

    // MARK: - JSONValue Helpers

    public static func jsonInt(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d) : nil
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public static func jsonDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let d): return d.isFinite ? d : nil
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}
