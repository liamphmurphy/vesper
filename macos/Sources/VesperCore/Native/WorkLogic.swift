import Foundation

/// Work's Runs view (/work): the run list's grouping and filters, the Overview's telemetry strip and
/// sections, and the formatting they use. The Swift port of web/lib/work-overview.ts and the parts
/// of web/lib/run-list.ts, lib/format.ts and lib/costs.ts the screen reads (keep them in step).
public enum WorkLogic {
    /// The sidebar's View menu.
    public enum ActivityFilter: String, Sendable, CaseIterable {
        case all
        case needsYou = "needs_you"
        case active
        case failed

        /// The URL's `filter`, falling back from the old `done=hide` to Running & queued.
        public init(filter: String?, legacyDone: String?) {
            if let filter, let parsed = ActivityFilter(rawValue: filter) {
                self = parsed
            } else {
                self = legacyDone == "hide" ? .active : .all
            }
        }

        public var label: String {
            switch self {
            case .all: "All runs"
            case .needsYou: "Needs you"
            case .active: "Running & queued"
            case .failed: "Failed today"
            }
        }
    }

    /// A run row's status dot.
    public enum Dot: String, Sendable, CaseIterable {
        case human, running, queued, done, failed, idle

        public var label: String {
            switch self {
            case .human: "Needs you"
            case .running: "Running"
            case .queued: "Queued"
            case .done: "Done"
            case .failed: "Failed"
            case .idle: "Cancelled"
            }
        }
    }

    public struct ViewCounts: Sendable, Equatable {
        public var all = 0
        public var needsYou = 0
        public var active = 0
        public var failed = 0

        public init(all: Int = 0, needsYou: Int = 0, active: Int = 0, failed: Int = 0) {
            self.all = all; self.needsYou = needsYou; self.active = active; self.failed = failed
        }

        public subscript(filter: ActivityFilter) -> Int {
            switch filter {
            case .all: all
            case .needsYou: needsYou
            case .active: active
            case .failed: failed
            }
        }
    }

    public struct SidebarGroup: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case active, history }
        public var label: String
        public var kind: Kind
        public var runs: [API.Run]
    }

    static let endedStates: Set<String> = ["completed", "failed", "cancelled"]
    static let purposeLabels = ["ticket": "Ticket run", "planning": "Planning run", "chat": "Chat run"]
    static let humanWaits: Set<String> = ["approval", "human_reply", "mockup_review"]

    // MARK: Runs

    public static func isEnded(_ state: String) -> Bool { endedStates.contains(state) }

    /// What the run works on, else its purpose.
    public static func runTitle(_ run: API.Run) -> String {
        if let title = run.workTitle, !title.isEmpty { return title }
        if !run.ticketKey.isEmpty { return run.ticketKey }
        return purposeLabels[run.purpose.rawValue] ?? "Run"
    }

    public static func runDot(_ run: API.Run, needsYou: Bool = false) -> Dot {
        if needsYou { return .human }
        switch run.state.rawValue {
        case "failed", "blocked": return .failed
        case "completed": return .done
        case "cancelled": return .idle
        case "queued": return .queued
        case "paused": return .human
        case "waiting" where humanWaits.contains(run.waitReason?.rawValue ?? ""): return .human
        default: return .running
        }
    }

    /// Case-insensitive match on title, ticket key, agent and purpose.
    public static func matchesRun(_ run: API.Run, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [run.workTitle, run.ticketKey, run.agent.name, run.agent.handle, purposeLabels[run.purpose.rawValue]]
            .contains { $0?.lowercased().contains(q) == true }
    }

    public static func matchesItem(_ item: API.InboxItem, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return [item.title, item.ticketKey, item.agent?.name, item.agent?.handle].contains { $0?.lowercased().contains(q) == true }
    }

    /// Runs once each, in the order given (pages can overlap as runs start).
    public static func unique(_ runs: [API.Run]) -> [API.Run] {
        var seen = Set<String>()
        return runs.filter { seen.insert($0.id).inserted }
    }

    /// Waiting on a person: an open Needs you item for it, or a non-delegation wait.
    public static func isRunNeedsYou(_ run: API.Run, needsRunIds: Set<String>) -> Bool {
        if needsRunIds.contains(run.id) { return true }
        return run.state.rawValue == "waiting" && run.waitReason?.rawValue != "delegation"
    }

    public static func isRunFailed(_ run: API.Run) -> Bool {
        run.state.rawValue == "failed" || run.state.rawValue == "blocked"
    }

    static func endTime(_ run: API.Run) -> String { run.endedAt ?? run.startedAt }

    /// The same local calendar day as `now`.
    public static func isSameLocalDay(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date = APIDate.parse(iso) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    /// The View menu's counts.
    public static func viewCounts(_ runs: [API.Run], needsRunIds: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> ViewCounts {
        var counts = ViewCounts()
        for run in unique(runs) {
            counts.all += 1
            if isRunNeedsYou(run, needsRunIds: needsRunIds) { counts.needsYou += 1 }
            if !isEnded(run.state.rawValue) { counts.active += 1 }
            if isRunFailed(run), isSameLocalDay(endTime(run), now: now, calendar: calendar) { counts.failed += 1 }
        }
        return counts
    }

    public static func filterRuns(_ runs: [API.Run], _ filter: ActivityFilter, needsRunIds: Set<String>, now: Date = Date(),
                                  calendar: Calendar = .current) -> [API.Run] {
        switch filter {
        case .all: runs
        case .needsYou: runs.filter { isRunNeedsYou($0, needsRunIds: needsRunIds) }
        case .active: runs.filter { !isEnded($0.state.rawValue) || isRunNeedsYou($0, needsRunIds: needsRunIds) }
        case .failed: runs.filter { isRunFailed($0) && isSameLocalDay(endTime($0), now: now, calendar: calendar) }
        }
    }

    /// One Active group, then finished runs by the day they ended ("Earlier today", "Yesterday"…).
    public static func groupSidebarRuns(_ runs: [API.Run], now: Date = Date(), calendar: Calendar = .current,
                                        locale: Locale = .current) -> [SidebarGroup] {
        var active: [API.Run] = []
        var days: [SidebarGroup] = []
        for run in unique(runs) {
            if !isEnded(run.state.rawValue) {
                active.append(run)
                continue
            }
            let label = dayLabel(endTime(run), now: now, calendar: calendar, locale: locale)
            if let i = days.firstIndex(where: { $0.label == label }) {
                days[i].runs.append(run)
            } else {
                days.append(SidebarGroup(label: label, kind: .history, runs: [run]))
            }
        }
        return (active.isEmpty ? [] : [SidebarGroup(label: "Active", kind: .active, runs: active)]) + days
    }

    /// "Earlier today", "Yesterday", a weekday within the week, else a date.
    public static func dayLabel(_ iso: String, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = APIDate.parse(iso) else { return "Earlier today" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Earlier today" }
        if days == 1 { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, template: days < 7 ? "EEEE" : sameYear ? "MMMd" : "MMMdy", calendar: calendar, locale: locale)
    }

    /// The sidebar row's one-word time: wait, live, queue, else how long ago it ended.
    public static func compactRunTime(_ run: API.Run, dot: Dot, now: Date = Date()) -> String {
        if dot == .human { return "wait" }
        if dot == .running { return "live" }
        if run.state.rawValue == "queued" { return "queue" }
        let seconds = max(0, (now.timeIntervalSince1970 - APIDate.epoch(endTime(run))).rounded())
        if seconds < 60 { return "now" }
        let minutes = (seconds / 60).rounded()
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = (minutes / 60).rounded()
        if hours < 24 { return "\(Int(hours))h" }
        return "\(Int((hours / 24).rounded()))d"
    }

    // MARK: Needs you

    /// The sidebar tray's Needs you queue (web lib/inbox.ts `trayItems`): open needs-you items in the
    /// Inbox's urgency order, longest wait first, narrowed to the project and persona.
    public static func needs(_ items: [API.InboxItem], project: String?, agent: String?) -> [API.InboxItem] {
        items
            .filter { $0.needsYou && InboxLogic.isOpen($0) }
            .filter { (project ?? "").isEmpty || $0.project == project }
            .filter { (agent ?? "").isEmpty || $0.agent?.handle == agent }
            .sorted { a, b in
                let ra = InboxLogic.kindRank(a.kindName), rb = InboxLogic.kindRank(b.kindName)
                if ra != rb { return ra < rb }
                let ta = APIDate.epoch(a.createdAt), tb = APIDate.epoch(b.createdAt)
                if ta != tb { return ta < tb }
                return a.id < b.id
            }
    }

    /// Where a Needs you item opens: its run, else its own page.
    public static func itemHref(_ item: API.InboxItem) -> String {
        if let run = item.runId, !run.isEmpty { return "/runs/\(run)" }
        return item.href
    }

    /// What the sidebar list shows (web run-list.tsx `useActivityLists`).
    public struct ActivityLists: Sendable {
        public var needsRunIds: Set<String>
        public var counts: ViewCounts
        public var groups: [SidebarGroup]
        /// Needs you items with no run row in the list.
        public var nonRunNeeds: [API.InboxItem]
    }

    public static func activityLists(runs: [API.Run], shownNeeds: [API.InboxItem], search: String, filter: ActivityFilter,
                                     now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ActivityLists {
        let needsRunIds = Set(shownNeeds.compactMap { $0.runId.flatMap { $0.isEmpty ? nil : $0 } })
        let searched = runs.filter { matchesRun($0, search) }
        var counts = viewCounts(searched, needsRunIds: needsRunIds, now: now, calendar: calendar)
        counts.needsYou = max(counts.needsYou, shownNeeds.count)
        let groups = groupSidebarRuns(filterRuns(searched, filter, needsRunIds: needsRunIds, now: now, calendar: calendar),
                                      now: now, calendar: calendar, locale: locale)
        let runIds = Set(runs.map(\.id))
        let nonRunNeeds = filter == .all || filter == .needsYou
            ? shownNeeds.filter { ($0.runId ?? "").isEmpty || !runIds.contains($0.runId ?? "") }
            : []
        return ActivityLists(needsRunIds: needsRunIds, counts: counts, groups: groups, nonRunNeeds: nonRunNeeds)
    }

    // MARK: Overview

    /// The Overview's telemetry strip, from what the API reports (nothing invented).
    public struct ActivityStats: Sendable, Equatable {
        public var slotsBusy = 0
        public var slotsMax = 0
        public var queued = 0
        public var online = false
        public var starting = false
        public var needsYouCount = 0
        public var needsApprovals = 0
        public var needsQuestions = 0
        public var needsReviews = 0
        public var completedToday = 0
        public var prsToday = 0
        public var passRatePct: Int?

        /// "2 approval · 1 question", or "Queue clear".
        public var needsBreakdown: String {
            guard needsYouCount > 0 else { return "Queue clear" }
            return [(needsApprovals, "approval"), (needsQuestions, "question"), (needsReviews, "review")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        }

        /// "2 PRs · 75% pass".
        public var todayDetail: String {
            "\(prsToday) PR\(prsToday == 1 ? "" : "s")" + (passRatePct.map { " · \($0)% pass" } ?? "")
        }

        /// "online", "starting" or "offline".
        public var runnerState: String { online ? "online" : starting ? "starting" : "offline" }
    }

    public static func activityStats(runs: [API.Run], inbox: [API.InboxItem], runner: API.RunnerStatus?, now: Date = Date(),
                                     calendar: Calendar = .current) -> ActivityStats {
        var stats = ActivityStats()
        let open = inbox.filter { $0.needsYou && !$0.resolved && !$0.read }
        stats.needsYouCount = open.count
        for item in open {
            switch item.kind.rawValue {
            case "approval": stats.needsApprovals += 1
            case "question": stats.needsQuestions += 1
            default: stats.needsReviews += 1
            }
        }
        let cutoff = now.timeIntervalSince1970 - 24 * 3600
        var passed = 0, terminal = 0
        var prs = Set<Int>()
        for run in runs {
            let end = endTime(run)
            if isEnded(run.state.rawValue), APIDate.epoch(end) >= cutoff {
                if run.state.rawValue == "completed" {
                    passed += 1
                    terminal += 1
                } else if isRunFailed(run) {
                    terminal += 1
                }
            }
            if run.state.rawValue == "completed", isSameLocalDay(end, now: now, calendar: calendar) {
                stats.completedToday += 1
                if let pr = run.prNumber { prs.insert(pr) }
            }
        }
        stats.prsToday = prs.count
        stats.passRatePct = terminal > 0 ? Int((Double(passed) / Double(terminal) * 100).rounded()) : nil
        stats.slotsBusy = runner?.busy ?? 0
        stats.slotsMax = runner?.slots ?? 0
        stats.queued = runner?.queued ?? 0
        stats.online = runner?.online ?? false
        stats.starting = !(runner?.online ?? false) && (runner?.starting ?? false)
        return stats
    }

    /// Running now: every run that hasn't ended.
    public static func runningNow(_ runs: [API.Run]) -> [API.Run] {
        unique(runs).filter { !isEnded($0.state.rawValue) }
    }

    /// Finished today: up to six runs that ended today.
    public static func finishedToday(_ runs: [API.Run], now: Date = Date(), calendar: Calendar = .current) -> [API.Run] {
        Array(unique(runs).filter { isEnded($0.state.rawValue) && isSameLocalDay(endTime($0), now: now, calendar: calendar) }.prefix(6))
    }

    /// Ready to start: unblocked todo tickets with no live run, up to six.
    public static func readyTickets(_ tickets: [API.TicketSummary], running: [API.Run]) -> [API.TicketSummary] {
        Array(ready(tickets, running: running).prefix(6))
    }

    /// The ready tickets that have an assignee, so Start ready can dispatch them all.
    public static func assignedReadyKeys(_ tickets: [API.TicketSummary], running: [API.Run]) -> [String] {
        ready(tickets, running: running).filter { $0.assignee != nil }.map(\.key)
    }

    static func ready(_ tickets: [API.TicketSummary], running: [API.Run]) -> [API.TicketSummary] {
        let active = Set(running.map(\.ticketKey).filter { !$0.isEmpty })
        return tickets.filter { $0.status.rawValue == "todo" && $0.unmetDependencies == 0 && !active.contains($0.key) }
    }

    /// "Step 2/5 · Write the tests" for a live run's current plan step.
    public static func currentStep(_ run: API.Run) -> String? {
        guard let step = run.plan.first(where: { $0.state.rawValue == "current" }) else { return nil }
        return "Step \(step.position)/\(run.plan.count) · \(step.text)"
    }

    /// The progress bar's width in percent: done steps, at least 8 so it shows.
    public static func planProgress(_ run: API.Run) -> Int? {
        guard !run.plan.isEmpty else { return nil }
        let done = run.plan.filter { $0.state.rawValue == "done" }.count
        return max(8, Int((Double(done) / Double(run.plan.count) * 100).rounded()))
    }

    // MARK: Status line and links

    /// The sidebar's status line: "2 busy · 6 slots · $18.42 7d".
    public static func statusText(runner: API.RunnerStatus?, costs: API.CostReport?) -> String {
        var parts: [String] = []
        if let runner {
            parts.append(runner.online ? "\(runner.busy) busy · \(runner.slots) slots"
                : (runner.starting ?? false) ? "Runner starting" : "Runner offline")
        }
        if let costs { parts.append("\(spendLabel(micros: costs.total.costMicros, unpricedRuns: costs.unpricedRuns)) 7d") }
        return parts.joined(separator: " · ")
    }

    public static func reportsHref(project: String?) -> String {
        "/reports?tab=costs&range=7" + ((project ?? "").isEmpty ? "" : "&project=\(encode(project!))")
    }

    public static func tasksHref(project: String?) -> String {
        (project ?? "").isEmpty ? "/tickets" : "/tickets?project=\(encode(project!))"
    }

    public static func newTicketHref(project: String?) -> String {
        (project ?? "").isEmpty ? "/tickets/new" : "/tickets/new?project=\(encode(project!))"
    }

    /// Where an old Work link goes now (web work-screen.tsx and legacy-work.tsx): `?view=tickets` and
    /// `?view=epics` (or `?layout=epics`) open Tickets, `?run=` the run's page. Nil stays on Work.
    public static func redirect(query: [String: String]) -> String? {
        let project = query["project"].flatMap { $0.isEmpty ? nil : $0 }
        let keep = project.map { "project=\(encode($0))" }
        func tickets(_ layout: String?) -> String {
            let parts = [layout.map { "layout=\($0)" }, keep].compactMap { $0 }
            return parts.isEmpty ? "/tickets" : "/tickets?" + parts.joined(separator: "&")
        }
        let view = query["layout"] == "epics" ? "epics" : query["view"]
        switch view {
        case "tickets":
            if let key = query["ticket"], !key.isEmpty { return "/tickets/\(encode(key))" }
            return tickets(query["layout"] == "board" ? "board" : nil)
        case "epics":
            if let id = query["epic"], !id.isEmpty { return "/epics/\(encode(id))" }
            return tickets("epics")
        default:
            if let run = query["run"], !run.isEmpty { return "/runs/\(encode(run))" }
            return nil
        }
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    // MARK: Formatting

    /// List-row time: "now", "12m", "5h", "Fri", "Oct 30" (web lib/format.ts `shortAgo`).
    public static func shortAgo(_ iso: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date = APIDate.parse(iso) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return format(date, template: seconds < 6 * 86_400 ? "EEE" : "MMMd", calendar: calendar, locale: locale)
    }

    /// A run's cost; unknown and partially priced runs never look free (web `runCost`).
    public static func runCost(_ value: Double, source: String?) -> String {
        let amount = String(format: "%.2f", value)
        switch source {
        case nil, "unknown": return "Unknown"
        case "partial": return "≥ $\(amount) (partial)"
        case "computed": return "~$\(amount)"
        default: return "$\(amount)"
        }
    }

    /// "$18.42", "$0.004", "< $0.001" (web lib/costs.ts `usd`).
    public static func usd(micros: Int) -> String {
        let value = Double(micros) / 1e6
        if value > 0 && value < 0.01 { return value < 0.001 ? "< $0.001" : "$" + String(format: "%.3f", value) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "$" + (f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    /// Spend with unpriced runs: a lower bound, or Unknown when nothing was priced.
    public static func spendLabel(micros: Int, unpricedRuns: Int) -> String {
        if unpricedRuns > 0 { return micros > 0 ? "≥ \(usd(micros: micros))" : "Unknown" }
        return usd(micros: micros)
    }

    /// The last `days` UTC days up to today, as GET /costs takes them ("2026-11-15").
    public static func presetRange(days: Int, now: Date) -> (from: String, to: String) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let to = utc.startOfDay(for: now)
        let from = utc.date(byAdding: .day, value: -(days - 1), to: to) ?? to
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = utc.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return (f.string(from: from), f.string(from: to))
    }

    static func format(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
