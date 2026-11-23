import Foundation

private typealias ShellTone = Tone

/// Pure logic for the native Plans screen (`/plans`), porting `web/lib/plans.ts` and
/// `web/lib/proposals.ts` so every status badge, count, live source-read list and proposal
/// dependency validation rule stays deterministic and unit-tested.
public enum PlansLogic {
    public enum Tone: String, Sendable, Equatable {
        case human
        case blocked
        case review
        case done
        case neutral
    }

    public struct Status: Sendable, Equatable {
        public let label: String
        public let tone: Tone

        public init(label: String, tone: Tone) {
            self.label = label
            self.tone = tone
        }
    }

    public struct ReadSource: Sendable, Equatable, Identifiable {
        public let key: String
        public let verb: String
        public let label: String
        public let ref: String?
        public var done: Bool

        public var id: String { key }

        public init(key: String, verb: String, label: String, ref: String? = nil, done: Bool) {
            self.key = key
            self.verb = verb
            self.label = label
            self.ref = ref
            self.done = done
        }
    }

    public static let estimateOptions: [Int?] = [1, 2, 3, 5, 8, 13, nil]

    private static let stoppedRunStates: Set<String> = ["failed", "cancelled", "blocked"]
    private static let mcpReadTools: Set<String> = ["read_page", "read_artifact", "get_ticket", "get_backlinks"]
    private static let fileReadTools: Set<String> = ["Read", "read", "read_file"]

    /// True while the planner run is queued or executing and has not submitted proposals yet.
    public static func planLive(_ plan: API.PlanningSession) -> Bool {
        planLive(state: plan.state.rawValue, runState: plan.runState)
    }

    public static func planLive(state: String, runState: String) -> Bool {
        state == "planning" && !stoppedRunStates.contains(runState) && runState != "completed"
    }

    /// Status pill for a plan: review outcome once a draft exists, otherwise the underlying run state.
    public static func planStatus(_ plan: API.PlanningSession) -> Status {
        planStatus(state: plan.state.rawValue, runState: plan.runState)
    }

    public static func planStatus(state: String, runState: String) -> Status {
        switch state {
        case "review":
            return Status(label: "Review", tone: .human)
        case "accepted":
            return Status(label: "Accepted", tone: .done)
        case "dismissed":
            return Status(label: "Dismissed", tone: .neutral)
        default:
            break
        }
        if runState == "cancelled" {
            return Status(label: "Cancelled", tone: .neutral)
        }
        if stoppedRunStates.contains(runState) || runState == "completed" {
            return Status(label: "Failed", tone: .blocked)
        }
        if runState == "queued" {
            return Status(label: "Queued", tone: .neutral)
        }
        return Status(label: "Planning", tone: .review)
    }

    /// Right-hand summary count on an index row or accepted card.
    public static func planCount(_ plan: API.PlanningSession) -> String {
        planCount(
            state: plan.state.rawValue,
            runState: plan.runState,
            proposalCount: plan.proposalCount,
            acceptedCount: plan.ticketKeys.count
        )
    }

    public static func planCount(state: String, runState: String, proposalCount: Int, acceptedCount: Int) -> String {
        if planLive(state: state, runState: runState) { return "reading\u{2026}" }
        if proposalCount == 0 { return "no proposals" }
        let accepted = state == "accepted" ? acceptedCount : 0
        return "\(accepted)/\(max(accepted, proposalCount)) accepted"
    }

    /// The goal's first non-empty trimmed line, for the plan sidebar list.
    public static func firstLine(_ goal: String) -> String {
        goal
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    /// Ensures every proposal has a stable non-empty `ref` (`ticket-1`, `ticket-2`, ...).
    public static func normalizedProposals(_ proposals: [API.TicketProposal]) -> [API.TicketProposal] {
        proposals.enumerated().map { index, proposal in
            var copy = proposal
            if (copy.ref ?? "").isEmpty {
                copy.ref = "ticket-\(index + 1)"
            }
            return copy
        }
    }

    /// Baseline estimate recorded by the planner before human review edits.
    public static func baselineEstimate(
        for proposal: API.TicketProposal,
        originals: [API.TicketProposal]
    ) -> (points: Int?, rationale: String?) {
        if let est = proposal.plannerEstimate {
            return (est.points, est.rationale)
        }
        if let orig = originals.first(where: { $0.ref == proposal.ref }) {
            if let est = orig.plannerEstimate {
                return (est.points, est.rationale)
            }
            return (orig.estimatePoints, orig.estimateRationale)
        }
        return (nil, nil)
    }

    public static func estimateChanged(_ proposal: API.TicketProposal, originals: [API.TicketProposal]) -> Bool {
        proposal.estimatePoints != baselineEstimate(for: proposal, originals: originals).points
    }

    /// Splits a comma/whitespace-separated list of existing ticket blocker keys into uppercase keys.
    public static func parseBlockerKeys(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    /// Validates the exact selected subset for atomic acceptance: detects cycles and dependencies on
    /// proposals that are unselected or missing (port of `web/lib/proposals.ts`).
    public static func dependencyProblems(
        items: [API.TicketProposal],
        selected: Set<String>
    ) -> [String] {
        var byRef: [String: API.TicketProposal] = [:]
        for item in items {
            if let ref = item.ref, !ref.isEmpty {
                byRef[ref] = item
            }
        }
        var errors: [String] = []
        var seenErrors: Set<String> = []
        var visiting: Set<String> = []
        var visited: Set<String> = []

        func record(_ message: String) {
            if seenErrors.insert(message).inserted {
                errors.append(message)
            }
        }

        func visit(_ ref: String) {
            guard let item = byRef[ref] else { return }
            let itemLabel = item.title.isEmpty ? ref : item.title
            if visiting.contains(ref) {
                record("Dependency cycle includes \u{201C}\(itemLabel)\u{201D}. Remove a link before accepting.")
                return
            }
            if visited.contains(ref) { return }
            visiting.insert(ref)
            for dep in item.dependsOn ?? [] {
                if !selected.contains(dep) || byRef[dep] == nil {
                    let depLabel = byRef[dep].flatMap { $0.title.isEmpty ? nil : $0.title } ?? dep
                    record("\u{201C}\(itemLabel)\u{201D} depends on \u{201C}\(depLabel)\u{201D}, which is not selected. Select it or remove the dependency.")
                } else {
                    visit(dep)
                }
            }
            visiting.remove(ref)
            visited.insert(ref)
        }

        // Preserve item order for deterministic messages.
        for item in items {
            if let ref = item.ref, selected.contains(ref) {
                visit(ref)
            }
        }
        for ref in selected.sorted() where !visited.contains(ref) {
            visit(ref)
        }
        return errors
    }

    /// Extracts deduplicated sources read by the planner from its run events, oldest first.
    public static func readSources(from events: [API.RunEvent]) -> [ReadSource] {
        var completedCallIds: Set<String> = []
        for event in events where event.type == .toolResult {
            if let callId = stringField(event.payload, keys: ["call_id", "id", "tool_call_id"]) {
                completedCallIds.insert(callId)
            }
        }

        var out: [ReadSource] = []
        var indexByKey: [String: Int] = [:]

        for event in events where event.type == .toolCall {
            guard let rawTool = stringField(event.payload, keys: ["tool", "name"]) else { continue }
            let tool = bareToolName(rawTool)
            let input = objectField(event.payload["input"]) ?? objectField(event.payload["arguments"]) ?? [:]
            let callId = stringField(event.payload, keys: ["call_id", "id", "tool_call_id"])
            let done = callId.map { completedCallIds.contains($0) } ?? false

            let verb: String
            let label: String
            let ref: String?
            let dedupPrefix: String

            if mcpReadTools.contains(tool) {
                switch tool {
                case "get_ticket":
                    let ticket = stringField(input, keys: ["ticket", "key"]) ?? "ticket"
                    verb = "Reading"
                    label = ticket
                    ref = "/tickets/\(ticket)"
                    dedupPrefix = "ticket"
                case "read_page":
                    let target = stringField(input, keys: ["path", "id", "page", "title"]) ?? "page"
                    verb = "Reading"
                    label = target
                    ref = target.contains("/") || !target.isEmpty ? nil : nil
                    dedupPrefix = "doc"
                case "read_artifact":
                    let target = stringField(input, keys: ["id", "artifact_id", "title"]) ?? "artifact"
                    verb = "Reading"
                    label = target
                    ref = "/artifacts/\(target)"
                    dedupPrefix = "doc"
                case "get_backlinks":
                    let target = stringField(input, keys: ["id", "path", "title"]) ?? "backlinks"
                    verb = "Checking backlinks"
                    label = target
                    ref = nil
                    dedupPrefix = "doc"
                default:
                    continue
                }
            } else if fileReadTools.contains(tool) {
                let path = stringField(input, keys: ["file_path", "path"]) ?? ""
                guard path.contains(".lazyagents/") else { continue }
                let base = path.split(separator: "/").last.map(String.init) ?? path
                verb = "Reading"
                label = base
                ref = nil
                dedupPrefix = "doc"
            } else {
                continue
            }

            let key = "\(dedupPrefix):\(ref ?? label)"
            if let existing = indexByKey[key] {
                out[existing].done = out[existing].done || done
            } else {
                indexByKey[key] = out.count
                out.append(ReadSource(key: key, verb: verb, label: label, ref: ref, done: done))
            }
        }
        return out
    }

    private static func bareToolName(_ raw: String) -> String {
        if raw.hasPrefix("mcp__") {
            let parts = raw.split(separator: "_", omittingEmptySubsequences: false)
            if let last = raw.components(separatedBy: "__").last, !last.isEmpty {
                return last
            }
            _ = parts
        }
        if let idx = raw.lastIndex(of: ".") {
            return String(raw[raw.index(after: idx)...])
        }
        return raw
    }

    private static func stringField(_ dict: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if case .string(let value)? = dict[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func objectField(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let dict)? = value { return dict }
        return nil
    }

    // MARK: - Sidebar NavModel

    public static let navId = "plans"
    public static let newPlanAction = "new-plan"
    public static let spaceFilterId = "plans-space"
    public static let searchId = "plans-search"
    public static let retryItemId = "retry"
    public static let openNewTabMenu = "open-new-tab"

    private static func navTone(for tone: Tone) -> ShellTone {
        switch tone {
        case .human: .human
        case .blocked: .blocked
        case .review: .accent
        case .done: .done
        case .neutral: .neutral
        }
    }

    public static func navModel(
        plans: [API.PlanningSession]?,
        projects: [API.Project],
        projectFilter: String = "",
        search: String = "",
        selectedId: String?,
        loading: Bool = false,
        error: String? = nil
    ) -> NavModel {
        let activeProjects = projects.filter { !$0.archived }
        let filters: [NavFilterMenu]? = activeProjects.isEmpty ? nil : [
            NavFilterMenu(
                id: spaceFilterId,
                label: "Space",
                icon: "briefcase",
                options: [NavFilterOption(value: "", label: "All spaces", checked: projectFilter.isEmpty)]
                    + activeProjects.map {
                        NavFilterOption(value: $0.key, label: $0.name, checked: projectFilter == $0.key)
                    }
            ),
        ]

        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        let allPlans = plans ?? []
        let filtered = allPlans.filter { plan in
            if !projectFilter.isEmpty && plan.project != projectFilter { return false }
            if needle.isEmpty { return true }
            return plan.goal.lowercased().contains(needle)
                || plan.project.lowercased().contains(needle)
        }

        let sections: [NavSection]
        if loading && plans == nil {
            sections = [NavSection(id: "loading", items: [], emptyText: "Loading plans\u{2026}")]
        } else if let error, !error.isEmpty, plans == nil {
            sections = [NavSection(id: "error", items: [
                NavItem(id: retryItemId, title: "Couldn\u{2019}t load plans", subtitle: error, icon: "refresh"),
            ])]
        } else {
            let items = filtered.map { plan -> NavItem in
                let line = firstLine(plan.goal)
                let status = planStatus(plan)
                return NavItem(
                    id: plan.id,
                    title: line.isEmpty ? "Untitled plan" : line,
                    subtitle: "\(plan.project) \u{00B7} \(APIDate.shortAgo(plan.createdAt))",
                    status: navTone(for: status.tone),
                    trailing: planCount(plan),
                    href: "/plans?id=\(plan.id)",
                    contextMenu: [MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external")]
                )
            }
            let emptyText: String = {
                if allPlans.isEmpty { return "Your plans will appear here." }
                return "No plans match this filter."
            }()
            sections = [NavSection(
                id: "plans",
                title: "Plans",
                items: items,
                badge: items.isEmpty ? nil : NavBadge(text: "\(items.count)"),
                emptyText: emptyText
            )]
        }

        return NavModel(
            id: navId,
            title: "Plans",
            actions: [NavAction(id: newPlanAction, label: "New plan", icon: "plus", accent: true)],
            filters: filters,
            search: NavSearch(id: searchId, placeholder: "Filter plans\u{2026}", value: search),
            sections: sections,
            selectedId: selectedId
        )
    }

    public enum NavActionResult: Sendable, Equatable {
        case newPlan
        case selectPlan(String, newTab: Bool)
        case filterSpace(String)
        case search(String)
        case retry
    }

    public static func navAction(for command: NativeCommand) -> NavActionResult? {
        switch command {
        case .navAction(navId, newPlanAction, _, _):
            return .newPlan
        case .navAction(navId, openNewTabMenu, let itemId?, _):
            return .selectPlan(itemId, newTab: true)
        case .navFilter(navId, spaceFilterId, let value, _):
            return .filterSpace(value)
        case .navSearch(navId, searchId, let value):
            return .search(value)
        case .navActivate(navId, let itemId, let newTab):
            if itemId == retryItemId { return .retry }
            return .selectPlan(itemId, newTab: newTab)
        default:
            return nil
        }
    }
}
