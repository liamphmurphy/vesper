import Foundation

/// Pure domain logic for the Tickets list, filters, grouping, sorting, saved views, multi-select,
/// bulk operations, and new-ticket draft persistence (Foundation only; zero AppKit).
/// Ports web/lib/ticket-list.ts, web/lib/tickets-layout.ts, and the ticket parts of
/// web/lib/work-rows.ts and web/lib/work-overview.ts.
public enum TicketsLogic {
    public static let estimateScale: [Int] = [1, 2, 3, 5, 8, 13]

    public static let statusOrder: [API.TicketStatus] = [
        .backlog, .todo, .inProgress, .inReview, .done, .canceled,
    ]

    public static let statusGroupOrder: [API.TicketStatus] = [
        .inProgress, .inReview, .todo, .backlog, .done, .canceled,
    ]

    public static let priorityOrder: [API.Priority] = [
        .urgent, .high, .medium, .low, .none,
    ]

    public static func statusLabel(_ status: API.TicketStatus) -> String {
        switch status {
        case .backlog: "Backlog"
        case .todo: "Ready"
        case .inProgress: "In progress"
        case .inReview: "In review"
        case .done: "Done"
        case .canceled: "Canceled"
        default: status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func priorityLabel(_ priority: API.Priority) -> String {
        switch priority {
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .none: "No priority"
        default: priority.rawValue.capitalized
        }
    }

    public static func statusTone(_ status: API.TicketStatus) -> Tone {
        switch status {
        case .backlog: .neutral
        case .todo: .neutral
        case .inProgress: .accent
        case .inReview: .warning
        case .done: .done
        case .canceled: .neutral
        default: .neutral
        }
    }

    public static func statusRank(_ status: API.TicketStatus) -> Int {
        statusGroupOrder.firstIndex(of: status) ?? statusGroupOrder.count
    }

    public static func priorityRank(_ priority: API.Priority) -> Int {
        priorityOrder.firstIndex(of: priority) ?? priorityOrder.count
    }

    // MARK: Layout & URL helpers

    public enum Layout: String, Sendable, CaseIterable, Equatable {
        case list
        case board
        case epics

        public var label: String {
            switch self {
            case .list: "List"
            case .board: "Board"
            case .epics: "Epics"
            }
        }

        public var icon: String {
            switch self {
            case .list: "tickets"
            case .board: "board"
            case .epics: "epics"
            }
        }
    }

    public static let primaryLayouts: [Layout] = [.list, .board]

    public static func parseLayout(_ raw: String?, path: String = "/tickets") -> Layout {
        if path == "/board" { return .board }
        guard let raw, let parsed = Layout(rawValue: raw) else { return .list }
        return parsed
    }

    public static func ticketsHref(layout: Layout = .list, query: [String: String?] = [:]) -> String {
        var pairs: [(String, String)] = []
        if layout != .list {
            pairs.append(("layout", layout.rawValue))
        }
        for key in query.keys.sorted() where key != "layout" {
            if let value = query[key] ?? nil, !value.isEmpty {
                pairs.append((key, value))
            }
        }
        guard !pairs.isEmpty else { return "/tickets" }
        let items = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        return "/tickets?" + APIQuery.encode(items)
    }

    /// Preserves only parameters valid across the target layout (`project`, `epic`, `assignee` for list/board;
    /// `project` only for epics).
    public static func layoutSwitchHref(to layout: Layout, current: [String: String]) -> String {
        let allowed: [String] = switch layout {
        case .list, .board: ["project", "epic", "assignee"]
        case .epics: ["project"]
        }
        var kept: [String: String?] = [:]
        for key in allowed {
            if let v = current[key], !v.isEmpty { kept[key] = v }
        }
        return ticketsHref(layout: layout, query: kept)
    }

    public static func ticketHref(_ key: String) -> String {
        "/tickets/\(WorkLogic.encode(key))"
    }

    public static func newTicketHref(
        project: String? = nil,
        status: API.TicketStatus? = nil,
        epic: String? = nil
    ) -> String {
        var items: [URLQueryItem] = []
        if let project, !project.isEmpty {
            items.append(URLQueryItem(name: "project", value: project))
        }
        if let status {
            items.append(URLQueryItem(name: "status", value: status.rawValue))
        }
        if let epic, !epic.isEmpty {
            items.append(URLQueryItem(name: "epic", value: epic))
        }
        guard !items.isEmpty else { return "/tickets/new" }
        return "/tickets/new?" + APIQuery.encode(items)
    }

    public static func chatAttachHref(
        chatId: String,
        project: String?,
        ticketKey: String,
        title: String
    ) -> String {
        var items: [URLQueryItem] = []
        if let project, !project.isEmpty {
            items.append(URLQueryItem(name: "project", value: project))
        }
        items.append(URLQueryItem(name: "attach", value: "ticket:\(ticketKey)"))
        if !title.isEmpty {
            items.append(URLQueryItem(name: "attach_title", value: title))
        }
        return "/chat/\(WorkLogic.encode(chatId))?" + APIQuery.encode(items)
    }

    // MARK: Grouping, Sorting, Density & Queues

    public enum GroupBy: String, Sendable, CaseIterable, Equatable {
        case status
        case epic
        case assignee
        case priority

        public var label: String {
            switch self {
            case .status: "Status"
            case .epic: "Epic"
            case .assignee: "Assignee"
            case .priority: "Priority"
            }
        }

        public static func parse(_ raw: String?) -> GroupBy {
            guard let raw, let value = GroupBy(rawValue: raw) else { return .status }
            return value
        }
    }

    public enum SortBy: String, Sendable, CaseIterable, Equatable {
        case defaultOrder = "default"
        case updatedDesc = "updated_desc"
        case priorityDesc = "priority_desc"
        case keyAsc = "key_asc"
        case estimateDesc = "estimate_desc"

        public var label: String {
            switch self {
            case .defaultOrder: "Default"
            case .updatedDesc: "Recently updated"
            case .priorityDesc: "Priority"
            case .keyAsc: "Key"
            case .estimateDesc: "Estimate"
            }
        }
    }

    public enum Density: String, Sendable, CaseIterable, Equatable {
        case comfortable
        case compact

        public var label: String {
            switch self {
            case .comfortable: "Comfortable rows"
            case .compact: "Compact rows"
            }
        }
    }

    public enum Queue: String, Sendable, CaseIterable, Equatable {
        case needsYou = "needs_you"
        case inProgress = "in_progress"
        case ready
        case blocked
        case all

        public var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .inProgress: "In progress"
            case .ready: "Ready to dispatch"
            case .blocked: "Blocked"
            case .all: "All tasks"
            }
        }

        public var statusTone: Tone {
            switch self {
            case .needsYou: .human
            case .inProgress: .done
            case .ready: .accent
            case .blocked: .blocked
            case .all: .neutral
            }
        }

        public var badgeTone: Tone? {
            switch self {
            case .needsYou: .human
            case .blocked: .blocked
            default: nil
            }
        }
    }

    // MARK: Needs-you & State text

    public struct NeedsYou: Sendable, Equatable {
        public var kind: String
        public var id: String
        public var summary: String
        public var href: String
        public var runId: String?
        public var createdAt: String

        public var label: String { TicketsLogic.needsPrefix[kind] ?? "Needs you" }
        public var pillTone: String { (kind == "blocked" || kind == "pr_ci_failed") ? "blocked" : "human" }

        public init(
            kind: String, id: String, summary: String, href: String,
            runId: String? = nil, createdAt: String = ""
        ) {
            self.kind = kind
            self.id = id
            self.summary = summary
            self.href = href
            self.runId = runId
            self.createdAt = createdAt
        }
    }

    public static let needsPrefix: [String: String] = [
        "approval": "Wants approval",
        "question": "Asked you",
        "blocked": "Run stopped",
        "stalled": "Run stalled",
        "pr_ci_failed": "PR CI failed",
        "pr_review_comments": "PR review comments",
        "mockup": "Mockup to review",
        "planning": "Plan to review",
        "review": "Review requested",
        "dispatch": "Ready to dispatch",
        "mention": "Mentioned you",
        "suggestion": "Wiki edit to review",
        "workflow_gate": "Workflow gate",
        "scheduled": "Scheduled task",
        "connector_approval": "Connector to approve",
        "secret_approval": "Secret to approve",
        "secret_expiring": "Secret expiring",
        "merged": "PR merged",
        "pr_approved": "PR approved",
    ]

    private static let endedRunStates: Set<String> = ["completed", "failed", "cancelled"]

    public static func needsYouByTicket(_ items: [API.InboxItem]) -> [String: NeedsYou] {
        var out: [String: NeedsYou] = [:]
        for item in items {
            guard item.needsYou, InboxLogic.isOpen(item), !item.ticketKey.isEmpty else { continue }
            let candidate = NeedsYou(
                kind: item.kind.rawValue,
                id: item.id,
                summary: item.summary,
                href: item.href,
                runId: item.runId,
                createdAt: item.createdAt
            )
            if let existing = out[item.ticketKey] {
                let rankDiff = InboxLogic.kindRank(existing.kind) - InboxLogic.kindRank(candidate.kind)
                if rankDiff < 0 { continue }
                if rankDiff == 0 {
                    let existingEpoch = APIDate.epoch(existing.createdAt)
                    let candidateEpoch = APIDate.epoch(candidate.createdAt)
                    if existingEpoch <= candidateEpoch { continue }
                }
            }
            out[item.ticketKey] = candidate
        }
        return out
    }

    /// Suppresses stale dispatch alerts when a ticket is closed, not `todo`, or already has a live run.
    public static func ticketNeedsYou(status: API.TicketStatus, runState: String? = nil, item: NeedsYou?) -> NeedsYou? {
        guard let item else { return nil }
        if status == .done || status == .canceled { return nil }
        if item.kind == "dispatch" {
            let liveRun = runState.map { !$0.isEmpty && !endedRunStates.contains($0) } ?? false
            return status == .todo && !liveRun ? item : nil
        }
        return item
    }

    public struct StateSummary: Sendable, Equatable {
        public enum ToneKind: String, Sendable, Equatable { case human, blocked, quiet }
        public var tone: ToneKind
        public var text: String

        public init(tone: ToneKind, text: String) {
            self.tone = tone
            self.text = text
        }
    }

    public static func isBlocked(_ ticket: API.TicketSummary) -> Bool {
        ticket.status != .done && ticket.status != .canceled && ticket.unmetDependencies > 0
    }

    public static func stateText(for ticket: API.TicketSummary, needs: NeedsYou?) -> StateSummary {
        if let needs {
            let prefix = needsPrefix[needs.kind] ?? "Needs you"
            let text = needs.summary.isEmpty ? prefix : "\(prefix): \(needs.summary)"
            return StateSummary(tone: .human, text: text)
        }
        if isBlocked(ticket) {
            return StateSummary(tone: .blocked, text: "Blocked by \(ticket.unmetDependencies)")
        }
        var text = statusLabel(ticket.status)
        if let pr = ticket.pr {
            text += " · PR #\(pr.number)\(pr.state == .merged ? " merged" : "")"
            if (pr.state == .open || pr.state == .draft), let fb = pr.feedback {
                if fb.failedChecksCount > 0 { text += " · CI failed" }
                if fb.unresolvedThreads > 0 {
                    text += " · \(fb.unresolvedThreads) \(fb.unresolvedThreads == 1 ? "comment" : "comments")"
                }
            }
        }
        return StateSummary(tone: .quiet, text: text)
    }

    // MARK: Tokenized filter box

    public enum FilterKey: String, Sendable, CaseIterable, Equatable {
        case project
        case epic
        case agent
        case status
    }

    public struct FilterToken: Sendable, Equatable {
        public var key: FilterKey
        public var value: String

        public init(key: FilterKey, value: String) {
            self.key = key
            self.value = value
        }
    }

    public struct FilterLookups: Sendable {
        public var projects: [API.Project]
        public var epics: [API.Epic]
        public var agents: [API.Agent]
        public var currentEpic: String?

        public init(
            projects: [API.Project] = [],
            epics: [API.Epic] = [],
            agents: [API.Agent] = [],
            currentEpic: String? = nil
        ) {
            self.projects = projects
            self.epics = epics
            self.agents = agents
            self.currentEpic = currentEpic
        }
    }

    public struct ResolvedFilter: Sendable, Equatable {
        public var project: String?
        public var epic: String?
        public var assignee: String?
        public var status: API.TicketStatus?
        public var q: String?
        public var unknown: [String]

        public init(
            project: String? = nil, epic: String? = nil, assignee: String? = nil,
            status: API.TicketStatus? = nil, q: String? = nil, unknown: [String] = []
        ) {
            self.project = project
            self.epic = epic
            self.assignee = assignee
            self.status = status
            self.q = q
            self.unknown = unknown
        }
    }

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)(project|epic|persona|agent|status):(?:"([^"]*)"?|(\S*))"#,
        options: [.caseInsensitive]
    )

    private static let projectStripRegex = try! NSRegularExpression(
        pattern: #"(^|\s)project:(?:"[^"]*"?|\S*)"#,
        options: [.caseInsensitive]
    )

    private static let statusAliases: [String: API.TicketStatus] = [
        "backlog": .backlog,
        "todo": .todo,
        "ready": .todo,
        "in_progress": .inProgress,
        "progress": .inProgress,
        "in-progress": .inProgress,
        "in_review": .inReview,
        "review": .inReview,
        "in-review": .inReview,
        "done": .done,
        "canceled": .canceled,
        "cancelled": .canceled,
    ]

    public static func parseFilterText(_ text: String) -> (tokens: [FilterToken], text: String) {
        let ns = text as NSString
        let matches = tokenRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var tokens: [FilterToken] = []
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let rawKey = ns.substring(with: match.range(at: 1)).lowercased()
            let key: FilterKey = (rawKey == "persona") ? .agent : (FilterKey(rawValue: rawKey) ?? .project)
            let quotedRange = match.range(at: 2)
            let bareRange = match.range(at: 3)
            let value: String
            if quotedRange.location != NSNotFound {
                value = ns.substring(with: quotedRange).trimmingCharacters(in: .whitespaces)
            } else if bareRange.location != NSNotFound {
                value = ns.substring(with: bareRange).trimmingCharacters(in: .whitespaces)
            } else {
                value = ""
            }
            if !value.isEmpty {
                tokens.insert(FilterToken(key: key, value: value), at: 0)
            }
            mutable.replaceCharacters(in: match.range, with: " ")
        }
        let free = (mutable as String)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return (tokens, free)
    }

    public static func withoutProjectToken(_ text: String) -> String {
        let ns = text as NSString
        let stripped = projectStripRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length),
            withTemplate: " "
        )
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func quoteTokenValue(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "\"\(value.replacingOccurrences(of: "\"", with: ""))\""
        }
        return value
    }

    public static func filterText(
        project: String? = nil,
        epic: String? = nil,
        agent: String? = nil,
        status: String? = nil,
        q: String? = nil
    ) -> String {
        var parts: [String] = []
        if let project, !project.isEmpty { parts.append("project:\(quoteTokenValue(project))") }
        if let epic, !epic.isEmpty { parts.append("epic:\(quoteTokenValue(epic))") }
        if let agent, !agent.isEmpty { parts.append("persona:\(quoteTokenValue(agent))") }
        if let status, !status.isEmpty { parts.append("status:\(quoteTokenValue(status))") }
        if let q, !q.isEmpty { parts.append(q) }
        return parts.joined(separator: " ")
    }

    private static func normalizeLookup(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[\s_-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    public static func resolveFilter(_ text: String, lookups: FilterLookups) -> ResolvedFilter {
        let parsed = parseFilterText(text)
        var out = ResolvedFilter()
        if !parsed.text.isEmpty { out.q = parsed.text }

        var byKey: [FilterKey: String] = [:]
        for token in parsed.tokens { byKey[token.key] = token.value }

        if let pv = byKey[.project] {
            let normPv = normalizeLookup(pv)
            if let match = lookups.projects.first(where: { $0.key.lowercased() == pv.lowercased() })
                ?? lookups.projects.first(where: { normalizeLookup($0.name) == normPv })
            {
                out.project = match.key
            } else {
                out.unknown.append("project:\(pv)")
            }
        }

        if let ev = byKey[.epic] {
            let normEv = normalizeLookup(ev)
            let proj = out.project.flatMap { key in lookups.projects.first { $0.key == key } }
            let named = lookups.epics.filter { $0.id == ev || normalizeLookup($0.name) == normEv }
            let match = named.first { $0.id == lookups.currentEpic }
                ?? named.first { proj == nil || $0.projectId == proj?.id }
                ?? named.first
            if let match {
                out.epic = match.id
            } else {
                out.unknown.append("epic:\(ev)")
            }
        }

        if let av = byKey[.agent] {
            let handle = av.hasPrefix("@") ? String(av.dropFirst()).lowercased() : av.lowercased()
            let normAv = normalizeLookup(av)
            if let match = lookups.agents.first(where: { $0.handle.lowercased() == handle })
                ?? lookups.agents.first(where: { normalizeLookup($0.name) == normAv })
            {
                out.assignee = match.handle
            } else {
                out.unknown.append("agent:\(av)")
            }
        }

        if let sv = byKey[.status] {
            let normalized = sv.lowercased().replacingOccurrences(of: #"[\s]+"#, with: "_", options: .regularExpression)
            if let status = statusAliases[normalized] {
                out.status = status
            } else {
                out.unknown.append("status:\(sv)")
            }
        }

        return out
    }

    // MARK: Local Filtering, Sorting & Grouping

    public static func applyLocalFilters(
        _ tickets: [API.TicketSummary],
        blockedOnly: Bool = false,
        unestimatedOnly: Bool = false,
        searchText: String = ""
    ) -> [API.TicketSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return tickets.filter { ticket in
            if blockedOnly && !isBlocked(ticket) { return false }
            if unestimatedOnly && !(ticket.estimatePoints == nil && ticket.status != .done && ticket.status != .canceled) {
                return false
            }
            if !query.isEmpty {
                let haystacks = [
                    ticket.key, ticket.title, ticket.epic?.name ?? "",
                    ticket.assignee?.name ?? "", ticket.assignee?.handle ?? "",
                ]
                if !haystacks.contains(where: { $0.lowercased().contains(query) }) { return false }
            }
            return true
        }
    }

    /// Natural ticket key comparator ("VES-2" < "VES-10").
    public static func compareKeys(_ lhs: String, _ rhs: String) -> Bool {
        let lp = splitTicketKey(lhs)
        let rp = splitTicketKey(rhs)
        if lp.prefix != rp.prefix { return lp.prefix < rp.prefix }
        if let ln = lp.number, let rn = rp.number, ln != rn { return ln < rn }
        return lhs < rhs
    }

    private static func splitTicketKey(_ key: String) -> (prefix: String, number: Int?) {
        guard let dash = key.lastIndex(of: "-"), let num = Int(key[key.index(after: dash)...]) else {
            return (key, nil)
        }
        return (String(key[..<dash]), num)
    }

    public static func sortTickets(_ tickets: [API.TicketSummary], by sort: SortBy) -> [API.TicketSummary] {
        switch sort {
        case .defaultOrder:
            return tickets
        case .updatedDesc:
            return tickets.sorted {
                let ta = APIDate.epoch($0.updatedAt), tb = APIDate.epoch($1.updatedAt)
                if ta != tb { return ta > tb }
                return compareKeys($0.key, $1.key)
            }
        case .priorityDesc:
            return tickets.sorted {
                let ra = priorityRank($0.priority), rb = priorityRank($1.priority)
                if ra != rb { return ra < rb }
                return compareKeys($0.key, $1.key)
            }
        case .keyAsc:
            return tickets.sorted { compareKeys($0.key, $1.key) }
        case .estimateDesc:
            return tickets.sorted {
                let ea = $0.estimatePoints ?? -1, eb = $1.estimatePoints ?? -1
                if ea != eb { return ea > eb }
                return compareKeys($0.key, $1.key)
            }
        }
    }

    public struct TicketGroup: Sendable, Equatable, Identifiable {
        public var id: String
        public var by: GroupBy
        public var title: String
        public var tickets: [API.TicketSummary]
        public var criteriaDone: Int
        public var criteriaTotal: Int
        public var points: Int
        public var isNeedsYou: Bool

        public init(
            id: String, by: GroupBy, title: String, tickets: [API.TicketSummary],
            criteriaDone: Int, criteriaTotal: Int, points: Int, isNeedsYou: Bool = false
        ) {
            self.id = id
            self.by = by
            self.title = title
            self.tickets = tickets
            self.criteriaDone = criteriaDone
            self.criteriaTotal = criteriaTotal
            self.points = points
            self.isNeedsYou = isNeedsYou
        }
    }

    private static func makeGroup(
        id: String,
        by: GroupBy,
        title: String,
        tickets: [API.TicketSummary],
        isNeedsYou: Bool = false
    ) -> TicketGroup {
        var criteriaDone = 0
        var criteriaTotal = 0
        var points = 0
        for ticket in tickets {
            criteriaDone += ticket.criteriaDone
            criteriaTotal += ticket.criteriaTotal
            if ticket.status != .canceled {
                points += ticket.estimatePoints ?? 0
            }
        }
        return TicketGroup(
            id: id, by: by, title: title, tickets: tickets,
            criteriaDone: criteriaDone, criteriaTotal: criteriaTotal, points: points, isNeedsYou: isNeedsYou
        )
    }

    public static func groupTickets(_ tickets: [API.TicketSummary], by: GroupBy) -> [TicketGroup] {
        var buckets: [String: (title: String, tickets: [API.TicketSummary])] = [:]
        func add(_ id: String, _ title: String, _ ticket: API.TicketSummary) {
            if var existing = buckets[id] {
                existing.tickets.append(ticket)
                buckets[id] = existing
            } else {
                buckets[id] = (title, [ticket])
            }
        }

        for ticket in tickets {
            switch by {
            case .status:
                add(ticket.status.rawValue, statusLabel(ticket.status), ticket)
            case .priority:
                add(ticket.priority.rawValue, priorityLabel(ticket.priority), ticket)
            case .epic:
                add(ticket.epic?.id ?? "none", ticket.epic?.name ?? "No epic", ticket)
            case .assignee:
                add(ticket.assignee?.id ?? "none", ticket.assignee?.name ?? "Unassigned", ticket)
            }
        }

        let orderedIds: [String]
        switch by {
        case .status:
            orderedIds = statusGroupOrder.map(\.rawValue).filter { buckets[$0] != nil }
        case .priority:
            orderedIds = priorityOrder.map(\.rawValue).filter { buckets[$0] != nil }
        case .epic, .assignee:
            var named = buckets.keys.filter { $0 != "none" }.sorted { a, b in
                let la = buckets[a]?.title ?? "", lb = buckets[b]?.title ?? ""
                let cmp = la.localizedCaseInsensitiveCompare(lb)
                return cmp == .orderedSame ? a < b : cmp == .orderedAscending
            }
            if buckets["none"] != nil { named.append("none") }
            orderedIds = named
        }

        return orderedIds.compactMap { id in
            guard let bucket = buckets[id] else { return nil }
            return makeGroup(id: id, by: by, title: bucket.title, tickets: bucket.tickets)
        }
    }

    /// Monday 00:00 local time of the week containing `now`.
    public static func weekStart(for now: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: startOfDay) // 1 = Sun, 2 = Mon...
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    }

    public static func workGroups(
        _ tickets: [API.TicketSummary],
        needs: [String: NeedsYou],
        by: GroupBy,
        sort: SortBy = .defaultOrder,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TicketGroup] {
        let ordered = sortTickets(tickets, by: sort)
        let waiting = ordered.filter { ticketNeedsYou(status: $0.status, item: needs[$0.key]) != nil }
        let waitingKeys = Set(waiting.map(\.key))
        let rest = ordered.filter { !waitingKeys.contains($0.key) }

        var out: [TicketGroup] = []
        if !waiting.isEmpty {
            out.append(makeGroup(id: "needs_you", by: by, title: "Needs you", tickets: waiting, isNeedsYou: true))
        }

        if by == .status {
            let weekEpoch = weekStart(for: now, calendar: calendar).timeIntervalSince1970
            var remaining = rest
            let buckets: [(id: String, title: String, match: (API.TicketSummary) -> Bool)] = [
                ("in_progress", "In progress", { $0.status == .inProgress || $0.status == .inReview }),
                ("todo", "Ready", { $0.status == .todo }),
                ("backlog", "Backlog", { $0.status == .backlog }),
                ("done_week", "Done this week", { $0.status == .done && APIDate.epoch($0.updatedAt) >= weekEpoch }),
                ("done", "Done earlier", { $0.status == .done }),
                ("canceled", "Canceled", { $0.status == .canceled }),
            ]
            for bucket in buckets {
                let hits = remaining.filter(bucket.match)
                if !hits.isEmpty {
                    let hitKeys = Set(hits.map(\.key))
                    remaining.removeAll { hitKeys.contains($0.key) }
                    out.append(makeGroup(id: bucket.id, by: by, title: bucket.title, tickets: hits))
                }
            }
            if !remaining.isEmpty {
                out.append(makeGroup(id: "other", by: by, title: "Other", tickets: remaining))
            }
            return out
        }

        return out + groupTickets(rest, by: by)
    }

    // MARK: Queue Counts & Sidebar Epics

    public struct QueueCounts: Sendable, Equatable {
        public var needsYou = 0
        public var inProgress = 0
        public var ready = 0
        public var blocked = 0
        public var all = 0

        public init(needsYou: Int = 0, inProgress: Int = 0, ready: Int = 0, blocked: Int = 0, all: Int = 0) {
            self.needsYou = needsYou
            self.inProgress = inProgress
            self.ready = ready
            self.blocked = blocked
            self.all = all
        }

        public subscript(queue: Queue) -> Int {
            switch queue {
            case .needsYou: needsYou
            case .inProgress: inProgress
            case .ready: ready
            case .blocked: blocked
            case .all: all
            }
        }
    }

    public static func queueCounts(tickets: [API.TicketSummary], inbox: [API.InboxItem]) -> QueueCounts {
        let needsMap = needsYouByTicket(inbox)
        var counts = QueueCounts()
        counts.all = tickets.count
        for ticket in tickets {
            if ticketNeedsYou(status: ticket.status, item: needsMap[ticket.key]) != nil { counts.needsYou += 1 }
            if ticket.status == .inProgress || ticket.status == .inReview { counts.inProgress += 1 }
            if ticket.status == .todo && ticket.unmetDependencies == 0 && ticket.assignee != nil { counts.ready += 1 }
            if ticket.unmetDependencies > 0 { counts.blocked += 1 }
        }
        return counts
    }

    public static func readyDispatchKeys(in tickets: [API.TicketSummary]) -> [String] {
        tickets
            .filter { $0.status == .todo && $0.unmetDependencies == 0 && $0.assignee != nil }
            .map(\.key)
    }

    public struct SidebarEpic: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var done: Int
        public var total: Int

        public init(id: String, name: String, done: Int, total: Int) {
            self.id = id
            self.name = name
            self.done = done
            self.total = total
        }
    }

    public static func sidebarEpics(from overviews: [API.EpicOverview], projectKey: String?) -> [SidebarEpic] {
        overviews
            .filter { (projectKey ?? "").isEmpty || $0.project.key == projectKey }
            .filter { $0.epic.status == .open }
            .map { SidebarEpic(id: $0.epic.id, name: $0.epic.name, done: $0.counts.done, total: $0.counts.total) }
    }

    // MARK: Saved Views

    public static let viewParams: [String] = [
        "view", "status", "group", "assignee", "epic", "q", "ready", "blocked", "unestimated",
    ]

    public struct SuggestedView: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var query: String
        public var hint: String

        public init(name: String, query: String, hint: String) {
            self.name = name
            self.query = query
            self.hint = hint
        }
    }

    public static let suggestedViews: [SuggestedView] = [
        SuggestedView(name: "My review queue", query: "status=in_review", hint: "In review assigned to anyone"),
        SuggestedView(name: "Blocked", query: "blocked=true", hint: "Blocked by an open dependency"),
        SuggestedView(name: "Unestimated", query: "unestimated=true", hint: "No estimate yet (done and canceled excluded)"),
    ]

    public static func parseQueryString(_ raw: String) -> [String: String] {
        let stripped = raw.hasPrefix("?") ? String(raw.dropFirst()) : raw
        guard !stripped.isEmpty, let comps = URLComponents(string: "?" + stripped) else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] where out[item.name] == nil {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    public static func normalizedViewQuery(_ params: [String: String]) -> String {
        var items: [URLQueryItem] = []
        for key in viewParams {
            guard let value = params[key], !value.isEmpty else { continue }
            if key == "view" && value == "all" { continue }
            if key == "group" && value == "status" { continue }
            if (key == "ready" || key == "blocked" || key == "unestimated") && value != "true" { continue }
            items.append(URLQueryItem(name: key, value: value))
        }
        return APIQuery.encode(items)
    }

    public static func normalizedViewQuery(_ raw: String) -> String {
        normalizedViewQuery(parseQueryString(raw))
    }

    public static func savedViewHref(id: String, query: String, project: String?) -> String {
        var items: [URLQueryItem] = []
        if let project, !project.isEmpty {
            items.append(URLQueryItem(name: "project", value: project))
        }
        items.append(URLQueryItem(name: "sv", value: id))
        let parsed = parseQueryString(normalizedViewQuery(query))
        for key in viewParams {
            if let value = parsed[key], !value.isEmpty {
                items.append(URLQueryItem(name: key, value: value))
            }
        }
        return "/tickets?" + APIQuery.encode(items)
    }

    public static func describeViewQuery(_ query: String, epicName: (String) -> String? = { _ in nil }) -> String {
        let p = parseQueryString(normalizedViewQuery(query))
        var parts: [String] = []
        let viewLabel: String = switch p["view"] {
        case "active": "Active"
        case "backlog": "Backlog"
        case "needs_human": "Needs you"
        default: "All tickets"
        }
        parts.append("View \(viewLabel)")
        parts.append("Group \(GroupBy.parse(p["group"]).label)")
        parts.append("Agent \(p["assignee"] ?? "any")")
        if let st = p["status"], !st.isEmpty {
            parts.append("Status \(st.replacingOccurrences(of: "_", with: " "))")
        }
        if let epicId = p["epic"], !epicId.isEmpty {
            parts.append("Epic \(epicName(epicId) ?? "selected")")
        }
        if p["ready"] == "true" { parts.append("Ready to dispatch") }
        if p["blocked"] == "true" { parts.append("Blocked") }
        if p["unestimated"] == "true" { parts.append("Unestimated") }
        parts.append((p["q"] ?? "").isEmpty ? "Search none" : "Search \u{201C}\(p["q"]!)\u{201D}")
        return parts.joined(separator: " · ")
    }

    public static func activeQueue(
        svId: String?,
        view: String,
        ready: Bool,
        blocked: Bool,
        epic: String?
    ) -> Queue? {
        if let svId, !svId.isEmpty { return nil }
        if view == "needs_human" { return .needsYou }
        if view == "active" { return .inProgress }
        if ready { return .ready }
        if blocked { return .blocked }
        if view == "all" && (epic ?? "").isEmpty { return .all }
        return nil
    }

    // MARK: Multi-select & Bulk execution

    public static func moveFocus(in keys: [String], current: String?, delta: Int) -> String? {
        guard !keys.isEmpty else { return nil }
        guard let current, let index = keys.firstIndex(of: current) else {
            return delta > 0 ? keys.first : keys.last
        }
        let target = min(keys.count - 1, max(0, index + delta))
        return keys[target]
    }

    public static func rangeKeys(in keys: [String], from anchor: String?, to target: String) -> [String] {
        guard let targetIndex = keys.firstIndex(of: target) else { return [] }
        guard let anchor, let anchorIndex = keys.firstIndex(of: anchor) else { return [target] }
        let lo = min(anchorIndex, targetIndex)
        let hi = max(anchorIndex, targetIndex)
        return Array(keys[lo...hi])
    }

    public struct BulkFailure: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var status: Int
        public var message: String

        public init(key: String, status: Int, message: String) {
            self.key = key
            self.status = status
            self.message = message
        }
    }

    public struct BulkResult: Sendable, Equatable {
        public var label: String
        public var updated: [String]
        public var failed: [BulkFailure]

        public init(label: String, updated: [String], failed: [BulkFailure]) {
            self.label = label
            self.updated = updated
            self.failed = failed
        }
    }

    public static func failureReason(_ failure: BulkFailure) -> String {
        if failure.status == 409 && failure.message.range(of: "cancel the run", options: .caseInsensitive) != nil {
            return "Cancel the run first: a run is live on this ticket."
        }
        guard let first = failure.message.first else { return "Request failed" }
        return String(first).uppercased() + failure.message.dropFirst()
    }

    /// Runs `operation` across `keys` with bounded concurrency, keeping successes even when some fail
    /// and returning results in the original `keys` order.
    public static func runEach(
        keys: [String],
        maxConcurrent: Int = 6,
        operation: @Sendable @escaping (String) async throws -> Void
    ) async -> (updated: [String], failed: [BulkFailure]) {
        guard !keys.isEmpty else { return ([], []) }
        let limit = max(1, maxConcurrent)
        var outcomes: [String: BulkFailure?] = [:]
        var nextIndex = 0

        await withTaskGroup(of: (String, BulkFailure?).self) { group in
            let initial = min(limit, keys.count)
            for _ in 0..<initial {
                let key = keys[nextIndex]
                nextIndex += 1
                group.addTask {
                    await executeOne(key: key, operation: operation)
                }
            }
            while let result = await group.next() {
                outcomes[result.0] = result.1
                if nextIndex < keys.count {
                    let key = keys[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await executeOne(key: key, operation: operation)
                    }
                }
            }
        }

        var updated: [String] = []
        var failed: [BulkFailure] = []
        for key in keys {
            if let maybeFailure = outcomes[key], let failure = maybeFailure {
                failed.append(failure)
            } else {
                updated.append(key)
            }
        }
        return (updated, failed)
    }

    private static func executeOne(
        key: String,
        operation: @Sendable (String) async throws -> Void
    ) async -> (String, BulkFailure?) {
        do {
            try await operation(key)
            return (key, nil)
        } catch let error as APIError {
            let status: Int = switch error {
            case .http(let code, _): code
            case .unauthorized: 401
            default: 0
            }
            return (key, BulkFailure(key: key, status: status, message: error.userMessage))
        } catch {
            return (key, BulkFailure(key: key, status: 0, message: error.localizedDescription))
        }
    }

    // MARK: New-Ticket Draft Persistence

    public struct NewTicketDraft: Codable, Sendable, Equatable {
        public var projectKey: String
        public var title: String
        public var descriptionMd: String
        public var criteria: [String]
        public var statusRaw: String
        public var priorityRaw: String
        public var assigneeAgentId: String?
        public var reviewerUserId: String?
        public var epicId: String?
        public var labelIds: [String]
        public var estimatePoints: Int?
        public var dueDate: String
        public var requiresMockup: Bool

        public init(
            projectKey: String = "",
            title: String = "",
            descriptionMd: String = "",
            criteria: [String] = [],
            statusRaw: String = API.TicketStatus.todo.rawValue,
            priorityRaw: String = API.Priority.none.rawValue,
            assigneeAgentId: String? = nil,
            reviewerUserId: String? = nil,
            epicId: String? = nil,
            labelIds: [String] = [],
            estimatePoints: Int? = nil,
            dueDate: String = "",
            requiresMockup: Bool = false
        ) {
            self.projectKey = projectKey
            self.title = title
            self.descriptionMd = descriptionMd
            self.criteria = criteria
            self.statusRaw = statusRaw
            self.priorityRaw = priorityRaw
            self.assigneeAgentId = assigneeAgentId
            self.reviewerUserId = reviewerUserId
            self.epicId = epicId
            self.labelIds = labelIds
            self.estimatePoints = estimatePoints
            self.dueDate = dueDate
            self.requiresMockup = requiresMockup
        }

        public var isMeaningful: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !descriptionMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || criteria.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        public func toNewTicket(resolvedProjectKey: String) -> API.NewTicket {
            let trimmedCriteria = criteria
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return API.NewTicket(
                assigneeAgentId: assigneeAgentId,
                criteria: trimmedCriteria.isEmpty ? nil : trimmedCriteria,
                descriptionMd: descriptionMd,
                dueDate: dueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : dueDate.trimmingCharacters(in: .whitespacesAndNewlines),
                epicId: epicId,
                estimate: nil,
                estimatePoints: estimatePoints,
                labelIds: labelIds.isEmpty ? nil : labelIds,
                priority: API.Priority(rawValue: priorityRaw),
                projectKey: resolvedProjectKey,
                requiresMockup: requiresMockup ? true : nil,
                reviewerUserId: reviewerUserId,
                status: API.TicketStatus(rawValue: statusRaw),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public static func draftStorageKey(projectKey: String?) -> String {
        let suffix = (projectKey ?? "").isEmpty ? "default" : projectKey!
        return "VesperNativeTicketDraft.\(suffix)"
    }

    public static func encodeDraft(_ draft: NewTicketDraft) -> String? {
        guard let data = try? JSONEncoder().encode(draft) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeDraft(_ json: String) -> NewTicketDraft? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(NewTicketDraft.self, from: data)
    }

    public static func loadDraft(from defaults: UserDefaults, projectKey: String?) -> NewTicketDraft? {
        guard let raw = defaults.string(forKey: draftStorageKey(projectKey: projectKey)) else { return nil }
        return decodeDraft(raw)
    }

    public static func saveDraft(_ draft: NewTicketDraft, to defaults: UserDefaults, projectKey: String?) {
        let key = draftStorageKey(projectKey: projectKey)
        guard draft.isMeaningful, let encoded = encodeDraft(draft) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(encoded, forKey: key)
    }

    public static func clearDraft(from defaults: UserDefaults, projectKey: String?) {
        defaults.removeObject(forKey: draftStorageKey(projectKey: projectKey))
    }
}
