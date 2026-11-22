import Foundation

/// Pure domain logic for Epics list, detail progress, wave grouping, burn-up, done gating,
/// and sidebar/inspector models (Foundation only; zero AppKit).
/// Ports `web/lib/epics.ts`, `web/lib/native-shell/models/epics.ts`, and `epic-detail.ts`.
public enum EpicsLogic {
    // MARK: - Filter & Sort Types

    public enum StatusFilter: String, Sendable, CaseIterable, Equatable {
        case open
        case done
        case all

        public var label: String {
            switch self {
            case .open: "Open"
            case .done: "Done"
            case .all: "All"
            }
        }

        public var navLabel: String {
            switch self {
            case .open: "Active epics"
            case .done: "Done"
            case .all: "All epics"
            }
        }
    }

    public enum HealthFilter: String, Sendable, CaseIterable, Equatable {
        case any
        case onTrack = "on_track"
        case atRisk = "at_risk"
        case offTrack = "off_track"

        public var label: String {
            switch self {
            case .any: "Any"
            case .onTrack: "On track"
            case .atRisk: "At risk"
            case .offTrack: "Off track"
            }
        }
    }

    public enum Sort: String, Sendable, CaseIterable, Equatable {
        case attention
        case target
        case progress
        case name

        public var label: String {
            switch self {
            case .attention: "Needs attention"
            case .target: "Target date"
            case .progress: "Points progress"
            case .name: "Name"
            }
        }
    }

    public struct Filters: Sendable, Equatable {
        public var status: StatusFilter
        public var health: HealthFilter
        public var sort: Sort

        public init(status: StatusFilter = .open, health: HealthFilter = .any, sort: Sort = .attention) {
            self.status = status
            self.health = health
            self.sort = sort
        }
    }

    public struct StatusCounts: Sendable, Equatable {
        public var open: Int
        public var done: Int
        public var all: Int

        public init(open: Int = 0, done: Int = 0, all: Int = 0) {
            self.open = open
            self.done = done
            self.all = all
        }

        public subscript(_ filter: StatusFilter) -> Int {
            switch filter {
            case .open: open
            case .done: done
            case .all: all
            }
        }
    }

    public struct ProjectGroup: Sendable, Equatable, Identifiable {
        public var id: String { projectKey }
        public var projectKey: String
        public var projectName: String
        public var epics: [API.EpicOverview]

        public init(projectKey: String, projectName: String, epics: [API.EpicOverview]) {
            self.projectKey = projectKey
            self.projectName = projectName
            self.epics = epics
        }
    }

    // MARK: - Labels & Tones

    public static func healthLabel(_ health: API.Epic.HealthValue) -> String {
        switch health {
        case .onTrack: "On track"
        case .atRisk: "At risk"
        case .offTrack: "Off track"
        default: health.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func healthTone(_ health: API.Epic.HealthValue) -> Tone {
        switch health {
        case .onTrack: .done
        case .atRisk: .human
        case .offTrack: .blocked
        default: .neutral
        }
    }

    public static func healthPillTone(_ health: API.Epic.HealthValue) -> String {
        switch health {
        case .onTrack: "done"
        case .atRisk: "human"
        case .offTrack: "blocked"
        default: "neutral"
        }
    }

    public static func healthRank(_ health: API.Epic.HealthValue) -> Int {
        switch health {
        case .offTrack: 0
        case .atRisk: 1
        case .onTrack: 2
        default: 3
        }
    }

    public static func statusLabel(_ status: API.EpicStatus) -> String {
        status == .done ? "Done" : "Open"
    }

    // MARK: - Query & URLs

    public static func parseFilters(query: [String: String]) -> Filters {
        Filters(
            status: query["status"].flatMap(StatusFilter.init(rawValue:)) ?? .open,
            health: query["health"].flatMap(HealthFilter.init(rawValue:)) ?? .any,
            sort: query["sort"].flatMap(Sort.init(rawValue:)) ?? .attention
        )
    }

    public static func filterQuery(_ filters: Filters, project: String? = nil) -> String {
        var items: [URLQueryItem] = []
        if let project, !project.isEmpty { items.append(URLQueryItem(name: "project", value: project)) }
        if filters.status != .open { items.append(URLQueryItem(name: "status", value: filters.status.rawValue)) }
        if filters.health != .any { items.append(URLQueryItem(name: "health", value: filters.health.rawValue)) }
        if filters.sort != .attention { items.append(URLQueryItem(name: "sort", value: filters.sort.rawValue)) }
        let encoded = APIQuery.encode(items)
        return encoded.isEmpty ? "" : "?\(encoded)"
    }

    public static func epicsHref(_ filters: Filters = Filters(), project: String? = nil) -> String {
        "/epics\(filterQuery(filters, project: project))"
    }

    public static func epicDetailHref(_ id: String) -> String {
        "/epics/\(APIPath.escape(id))"
    }

    public static func boardHref(projectKey: String, epicId: String) -> String {
        TicketsLogic.ticketsHref(layout: .board, query: ["project": projectKey, "epic": epicId])
    }

    public static func ticketListHref(projectKey: String, epicId: String) -> String {
        TicketsLogic.ticketsHref(layout: .list, query: ["view": "all", "epic": epicId, "project": projectKey])
    }

    public static func planHref(projectKey: String, epicId: String, sourceArtifactId: String? = nil) -> String {
        var items = [
            URLQueryItem(name: "epic", value: epicId),
            URLQueryItem(name: "project", value: projectKey),
        ]
        if let sourceArtifactId, !sourceArtifactId.isEmpty {
            items.append(URLQueryItem(name: "artifact", value: sourceArtifactId))
        }
        return "/plans?\(APIQuery.encode(items))"
    }

    // MARK: - Filtering, Grouping & Sorting

    public static func statusCounts(_ epics: [API.EpicOverview]) -> StatusCounts {
        let done = epics.filter { $0.epic.status == .done }.count
        return StatusCounts(open: epics.count - done, done: done, all: epics.count)
    }

    public static func atRiskCount(_ epics: [API.EpicOverview]) -> Int {
        epics.filter { $0.epic.status == .open && ($0.epic.health == .atRisk || $0.epic.health == .offTrack) }.count
    }

    public static func filter(
        _ epics: [API.EpicOverview],
        status: StatusFilter = .open,
        health: HealthFilter = .any,
        project: String? = nil,
        search: String = ""
    ) -> [API.EpicOverview] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return epics.filter { item in
            if let project, !project.isEmpty, item.project.key != project { return false }
            if status == .open && item.epic.status != .open { return false }
            if status == .done && item.epic.status != .done { return false }
            if health != .any && item.epic.health.rawValue != health.rawValue { return false }
            if !needle.isEmpty {
                let hay = "\(item.epic.name) \(item.objective) \(item.project.name)".lowercased()
                if !hay.contains(needle) { return false }
            }
            return true
        }
    }

    public static func ratio(done: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    public static func sort(_ epics: [API.EpicOverview], by sort: Sort) -> [API.EpicOverview] {
        epics.sorted { a, b in
            switch sort {
            case .attention:
                let hr = healthRank(a.epic.health) - healthRank(b.epic.health)
                if hr != 0 { return hr < 0 }
                let tr = compareTargetDate(a.targetDate, b.targetDate)
                if tr != 0 { return tr < 0 }
                return a.epic.name.localizedCaseInsensitiveCompare(b.epic.name) == .orderedAscending
            case .target:
                let tr = compareTargetDate(a.targetDate, b.targetDate)
                if tr != 0 { return tr < 0 }
                return a.epic.name.localizedCaseInsensitiveCompare(b.epic.name) == .orderedAscending
            case .progress:
                let ra = ratio(done: a.epic.pointsDone, total: a.epic.pointsTotal)
                let rb = ratio(done: b.epic.pointsDone, total: b.epic.pointsTotal)
                if ra != rb { return ra > rb }
                return a.epic.name.localizedCaseInsensitiveCompare(b.epic.name) == .orderedAscending
            case .name:
                return a.epic.name.localizedCaseInsensitiveCompare(b.epic.name) == .orderedAscending
            }
        }
    }

    private static func compareTargetDate(_ a: String?, _ b: String?) -> Int {
        switch (a, b) {
        case let (a?, b?) where !a.isEmpty && !b.isEmpty:
            if a == b { return 0 }
            return a < b ? -1 : 1
        case let (a?, _) where !a.isEmpty:
            return -1
        case let (_, b?) where !b.isEmpty:
            return 1
        default:
            return 0
        }
    }

    public static func groupByProject(_ epics: [API.EpicOverview]) -> [ProjectGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var buckets: [String: [API.EpicOverview]] = [:]
        for item in epics {
            let key = item.project.key
            if buckets[key] == nil {
                order.append(key)
                names[key] = item.project.name
            }
            buckets[key, default: []].append(item)
        }
        return order.map { key in
            ProjectGroup(projectKey: key, projectName: names[key] ?? key, epics: buckets[key] ?? [])
        }
    }

    // MARK: - Dates & Overdue

    public static func todayYMD(now: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    public static func isOverdue(status: API.EpicStatus, targetDate: String?, today: String) -> Bool {
        guard status == .open, let targetDate, !targetDate.isEmpty else { return false }
        return targetDate < today
    }

    public static func isOverdue(_ overview: API.EpicOverview, today: String) -> Bool {
        isOverdue(status: overview.epic.status, targetDate: overview.targetDate, today: today)
    }

    public static func formatDueDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return ymd }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = cal.date(from: comps) else { return ymd }
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    // MARK: - Detail Progress, Waves, Burn-up & Start Ready

    public struct ProgressSummary: Sendable, Equatable {
        public var done: Int
        public var running: Int
        public var needs: Int
        public var open: Int

        public var total: Int { done + running + needs + open }

        public init(done: Int = 0, running: Int = 0, needs: Int = 0, open: Int = 0) {
            self.done = done; self.running = running; self.needs = needs; self.open = open
        }
    }

    public static func progress(tickets: [API.TicketSummary], needsByKey: [String: TicketsLogic.NeedsYou]) -> ProgressSummary {
        var out = ProgressSummary()
        for t in tickets where t.status != .canceled {
            if t.status == .done {
                out.done += 1
            } else if needsByKey[t.key] != nil {
                out.needs += 1
            } else if t.status == .inProgress || t.status == .inReview {
                out.running += 1
            } else {
                out.open += 1
            }
        }
        return out
    }

    public struct BurnUpPoint: Sendable, Equatable, Identifiable {
        public var id: String { date }
        public var date: String
        public var done: Int

        public init(date: String, done: Int) {
            self.date = date; self.done = done
        }
    }

    public struct BurnUp: Sendable, Equatable {
        public var scope: Int
        public var done: Int
        public var points: [BurnUpPoint]

        public init(scope: Int, done: Int, points: [BurnUpPoint]) {
            self.scope = scope; self.done = done; self.points = points
        }
    }

    public static func burnUp(
        tickets: [API.TicketSummary],
        startDate: String?,
        today: String,
        calendar: Calendar = .current
    ) -> BurnUp {
        let live = tickets.filter { $0.status != .canceled }
        let scope = live.reduce(0) { $0 + ($1.estimatePoints ?? 0) }
        var perDay: [String: Int] = [:]
        for t in live {
            guard t.status == .done, let pts = t.estimatePoints, pts > 0 else { continue }
            let day: String
            if let parsed = APIDate.parse(t.updatedAt) {
                day = todayYMD(now: parsed, calendar: calendar)
            } else {
                day = String(t.updatedAt.prefix(10))
            }
            perDay[day, default: 0] += pts
        }
        let days = perDay.keys.sorted()
        let first: String
        if let startDate, !startDate.isEmpty, days.isEmpty || startDate <= days[0] {
            first = startDate
        } else {
            first = days.first ?? today
        }
        var points = [BurnUpPoint(date: first, done: 0)]
        var done = 0
        for day in days {
            done += perDay[day] ?? 0
            if points.last?.date == day {
                points[points.count - 1].done = done
            } else {
                points.append(BurnUpPoint(date: day, done: done))
            }
        }
        if let last = points.last, last.date < today {
            points.append(BurnUpPoint(date: today, done: done))
        }
        return BurnUp(scope: scope, done: done, points: points)
    }

    public struct WaveGroup: Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        public var tickets: [API.TicketSummary]

        public init(id: String, label: String, tickets: [API.TicketSummary]) {
            self.id = id; self.label = label; self.tickets = tickets
        }
    }

    /// Groups an epic's tickets into execution waves: Needs you, Active, Ready to start, Blocked,
    /// Backlog, Done, and Canceled.
    public static func groupByWave(
        tickets: [API.TicketSummary],
        needsByKey: [String: TicketsLogic.NeedsYou]
    ) -> [WaveGroup] {
        var buckets: [String: [API.TicketSummary]] = [:]
        for ticket in tickets {
            let key: String
            if ticket.status == .done {
                key = "done"
            } else if ticket.status == .canceled {
                key = "canceled"
            } else if needsByKey[ticket.key] != nil {
                key = "needs"
            } else if ticket.status == .inProgress || ticket.status == .inReview {
                key = "active"
            } else if ticket.status == .todo && ticket.unmetDependencies == 0 {
                key = "ready"
            } else if ticket.unmetDependencies > 0 {
                key = "blocked"
            } else {
                key = "backlog"
            }
            buckets[key, default: []].append(ticket)
        }
        let order: [(String, String)] = [
            ("needs", "Needs you"),
            ("active", "In progress"),
            ("ready", "Ready to start"),
            ("blocked", "Blocked"),
            ("backlog", "Backlog"),
            ("done", "Done"),
            ("canceled", "Canceled"),
        ]
        return order.compactMap { id, label in
            guard let items = buckets[id], !items.isEmpty else { return nil }
            let sorted = items.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            return WaveGroup(id: id, label: label, tickets: sorted)
        }
    }

    public struct StartReadySplit: Sendable, Equatable {
        public var ready: [API.TicketSummary]
        public var blocked: [API.TicketSummary]
        public var unassignedKeys: [String]

        public init(ready: [API.TicketSummary] = [], blocked: [API.TicketSummary] = [], unassignedKeys: [String] = []) {
            self.ready = ready; self.blocked = blocked; self.unassignedKeys = unassignedKeys
        }
    }

    public static func startReady(
        tickets: [API.TicketSummary],
        liveKeys: Set<String> = []
    ) -> StartReadySplit {
        let open = tickets.filter { $0.status != .done && $0.status != .canceled && !liveKeys.contains($0.key) }
        let ready = open.filter { $0.unmetDependencies == 0 && ($0.status == .todo || $0.status == .backlog) }
        let blocked = open.filter { $0.unmetDependencies > 0 }
        let unassignedKeys = ready.filter { $0.assignee == nil }.map(\.key)
        return StartReadySplit(ready: ready, blocked: blocked, unassignedKeys: unassignedKeys)
    }

    public static func canMarkDone(
        status: API.EpicStatus,
        criteriaCount: Int,
        blockers: API.BoardEpic.DoneBlockers?
    ) -> Bool {
        guard status != .done, criteriaCount > 0, let blockers else { return false }
        return blockers.openTickets.isEmpty && blockers.uncheckedCriteria.isEmpty
    }

    public static func blockerSummary(_ blockers: API.BoardEpic.DoneBlockers?) -> String? {
        guard let blockers else { return nil }
        var parts: [String] = []
        if !blockers.openTickets.isEmpty {
            parts.append("Open: \(blockers.openTickets.joined(separator: ", "))")
        }
        if !blockers.uncheckedCriteria.isEmpty {
            let n = blockers.uncheckedCriteria.count
            parts.append("\(n) unchecked \(n == 1 ? "criterion" : "criteria")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - NavModel & Inspector Builders

    public static let epicsNavId = "epics"
    public static let epicDetailNavId = "epic-detail"
    public static let statusFilterId = "epic-status"
    public static let healthFilterId = "epic-health"
    public static let openEpicActionId = "open_epic"
    public static let markDoneActionId = "mark_epic_done"
    public static let reopenEpicActionId = "reopen_epic"
    public static let requiresMockupFieldId = "requires_mockup"

    public static func epicsNavModel(
        project: String?,
        projects: [API.Project],
        filters: Filters,
        counts: StatusCounts,
        atRiskCount: Int,
        groups: [ProjectGroup],
        selectedEpicId: String?,
        search: String,
        loading: Bool
    ) -> NavModel {
        let spaces = [NavFilterOption(value: "", label: "All spaces", checked: (project ?? "").isEmpty)]
            + projects.filter { !$0.archived }.map { NavFilterOption(value: $0.key, label: $0.name, checked: project == $0.key) }
        let statusMenu = StatusFilter.allCases.map {
            NavFilterOption(value: $0.rawValue, label: "\($0.navLabel) (\(counts[$0]))", checked: filters.status == $0)
        }
        let healthMenu = HealthFilter.allCases.map { h in
            let suffix = (h == .atRisk && atRiskCount > 0) ? " (\(atRiskCount))" : ""
            return NavFilterOption(value: h.rawValue, label: "\(h.label)\(suffix)", checked: filters.health == h)
        }
        var sections: [NavSection] = groups.map { group in
            NavSection(
                id: "space:\(group.projectKey)",
                title: group.projectName,
                items: group.epics.map { item in
                    NavItem(
                        id: item.epic.id,
                        title: item.epic.name,
                        status: healthTone(item.epic.health),
                        trailing: "\(item.counts.done)/\(item.counts.total)"
                    )
                }
            )
        }
        if sections.isEmpty && !loading {
            sections.append(NavSection(id: "empty", items: [], emptyText: "No epics match."))
        }
        return NavModel(
            id: epicsNavId,
            title: "Work",
            picker: NavPicker(id: WorkNav.viewPicker, value: "tickets", options: [
                NavPickerOption(value: "activity", label: "Runs"),
                NavPickerOption(value: "tickets", label: "Tasks"),
            ]),
            filters: [
                NavFilterMenu(id: WorkNav.spaceFilter, label: "Space", icon: "briefcase", options: spaces),
                NavFilterMenu(id: statusFilterId, label: "Status", icon: "sliders", options: statusMenu),
                NavFilterMenu(id: healthFilterId, label: "Health", icon: "activity", options: healthMenu),
            ],
            search: NavSearch(id: WorkNav.searchId, placeholder: "Filter epics…", value: search),
            sections: sections,
            selectedId: selectedEpicId
        )
    }

    public static func epicDetailNavModel(
        project: String?,
        projectName: String?,
        epics: [API.EpicOverview],
        epicId: String
    ) -> NavModel {
        let items = epics.map { item in
            let done = max(0, item.epic.ticketsTotal - item.epic.ticketsOpen)
            return NavItem(
                id: item.epic.id,
                title: item.epic.name,
                trailing: "\(done)/\(item.epic.ticketsTotal)",
                href: epicDetailHref(item.epic.id)
            )
        }
        return NavModel(
            id: epicDetailNavId,
            title: "Work",
            picker: NavPicker(id: WorkNav.viewPicker, value: "tickets", options: [
                NavPickerOption(value: "activity", label: "Runs"),
                NavPickerOption(value: "tickets", label: "Tasks"),
            ]),
            sections: [
                NavSection(
                    id: "epics",
                    title: projectName ?? "Epics",
                    items: items,
                    badge: NavBadge(text: "\(epics.count)")
                ),
            ],
            selectedId: epicId
        )
    }

    public static func epicDetailInspectorSections(
        overview: API.EpicOverview,
        criteria: [API.EpicCriterion],
        blockers: API.BoardEpic.DoneBlockers?,
        burnUp: BurnUp?
    ) -> [InspectorSection] {
        let closed = overview.epic.status == .done
        let canDone = canMarkDone(status: overview.epic.status, criteriaCount: criteria.count, blockers: blockers)
        let blockerNote = closed ? nil : blockerSummary(blockers)

        var gateItems: [InspectorItem] = [
            InspectorItem(
                id: "points",
                kind: .progress,
                label: "Points",
                value: "\(overview.epic.pointsDone)/\(overview.epic.pointsTotal)",
                fraction: ratio(done: overview.epic.pointsDone, total: overview.epic.pointsTotal)
            ),
            InspectorItem(
                id: "criteria_progress",
                kind: .progress,
                label: "Criteria",
                value: "\(overview.epic.criteriaDone)/\(overview.epic.criteriaTotal)",
                fraction: ratio(done: overview.epic.criteriaDone, total: overview.epic.criteriaTotal)
            ),
        ]
        for c in criteria.sorted(by: { $0.position < $1.position }) {
            gateItems.append(InspectorItem(
                id: "criterion:\(c.id)",
                kind: .toggle,
                label: "\(c.position). \(c.text)",
                checked: c.done,
                disabled: closed
            ))
        }
        if let blockerNote {
            gateItems.append(InspectorItem(id: "blockers", kind: .note, value: blockerNote, tone: .human))
        }
        gateItems.append(InspectorItem(
            id: "gate_actions",
            kind: .actions,
            actions: [
                closed
                    ? InspectorAction(id: reopenEpicActionId, label: "Reopen epic")
                    : InspectorAction(id: markDoneActionId, label: "Mark epic done", disabled: !canDone),
            ]
        ))

        let schedule = "\(overview.startDate.map(formatDueDate) ?? "No start") → \(overview.targetDate.map(formatDueDate) ?? "No target")"
        var detailItems: [InspectorItem] = [
            InspectorItem(id: "owner", kind: .fact, label: "Owner", value: overview.owner?.name ?? "Unassigned"),
            InspectorItem(id: "schedule", kind: .fact, label: "Schedule", value: schedule),
            InspectorItem(id: "agent_hours", kind: .fact, label: "Agent time", value: String(format: "%.1fh", overview.agentSeconds / 3600.0)),
            InspectorItem(id: requiresMockupFieldId, kind: .toggle, label: "Requires mockup", checked: overview.epic.requiresMockup),
        ]
        if let source = overview.source {
            detailItems.append(InspectorItem(id: "source", kind: .fact, label: "Source", value: source.title, href: source.href))
        }

        var sections = [
            InspectorSection(id: "gate", title: "Acceptance & gate", items: gateItems),
            InspectorSection(id: "details", title: "Details", items: detailItems),
        ]
        if let burnUp, burnUp.scope > 0 {
            let pct = Int((ratio(done: burnUp.done, total: burnUp.scope) * 100).rounded())
            sections.append(InspectorSection(
                id: "burnup",
                title: "Burn-up",
                aside: "\(burnUp.done)/\(burnUp.scope) pts (\(pct)%)",
                items: [
                    InspectorItem(
                        id: "burnup_chart",
                        kind: .chart,
                        points: burnUp.points.map {
                            InspectorBarPoint(label: formatDueDate($0.date), value: Double($0.done), secondary: Double(burnUp.scope))
                        }
                    ),
                ]
            ))
        }
        return sections
    }
}
