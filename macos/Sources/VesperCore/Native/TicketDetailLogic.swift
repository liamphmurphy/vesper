import Foundation

/// Pure logic for Ticket Detail: criteria diffing & optimistic updates, revision-checked edits and
/// conflict merging, dependency key validation, activity timeline grouping & verb formatting, gates,
/// pager, native toolbar, and native Inspector model building (Foundation only; zero AppKit).
public enum TicketDetailLogic {
    public static let endedRunStates: Set<String> = ["completed", "failed", "cancelled"]

    public static func hasLiveRun(_ ticket: API.Ticket?) -> Bool {
        guard let state = ticket?.run?.state.rawValue else { return false }
        return !endedRunStates.contains(state)
    }

    public static func needsDispatch(_ ticket: API.Ticket) -> Bool {
        guard ticket.assignee != nil, ticket.status == .todo else { return false }
        guard let run = ticket.run else { return true }
        return endedRunStates.contains(run.state.rawValue)
    }

    public static func dispatchHint(for ticket: API.Ticket) -> String {
        let blockers = ticket.blockedBy.filter { $0.status != .done }
        if !blockers.isEmpty {
            let keys = blockers.map(\.key).joined(separator: ", ")
            return "Dispatching queues it until \(keys) \(blockers.count == 1 ? "is" : "are") Done."
        }
        if let run = ticket.run {
            return "The last run \(run.state.rawValue). Dispatch again to start a new run."
        }
        let name = ticket.assignee?.name ?? "The agent"
        return "\(name) is assigned and waiting for dispatch. Assigning doesn\u{2019}t start work."
    }

    public static func runStateBadge(_ state: API.Run.State) -> (label: String, tone: String) {
        switch state {
        case .queued: ("Queued", "neutral")
        case .starting: ("Starting", "neutral")
        case .running: ("Running", "done")
        case .waiting: ("Waiting", "human")
        case .waitingForQuota: ("Waiting for quota", "neutral")
        case .paused: ("Paused", "human")
        case .blocked: ("Blocked", "blocked")
        case .completed: ("Completed", "review")
        case .failed: ("Failed", "blocked")
        case .cancelled: ("Cancelled", "neutral")
        default: (state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, "neutral")
        }
    }

    public static func runStateNavTone(_ state: API.Run.State) -> Tone {
        switch state {
        case .running: .done
        case .waiting, .paused: .human
        case .blocked, .failed: .blocked
        case .completed: .accent
        default: .neutral
        }
    }

    public static func runsCostSummary(_ runs: [API.Run], hasMore: Bool) -> String? {
        guard !runs.isEmpty else { return nil }
        let priced = runs.filter { ($0.costSource ?? "unknown") != "unknown" }
        guard !priced.isEmpty else {
            return "\(runs.count)\(hasMore ? "+" : "")"
        }
        let total = priced.reduce(0.0) { $0 + $1.costUsd }
        let partial = hasMore || priced.count < runs.count || priced.contains { $0.costSource == "partial" }
        let formatted = String(format: "%.2f", total)
        return "\(runs.count)\(hasMore ? "+" : "") · \(partial ? "≥ " : "")$\(formatted)"
    }

    // MARK: Gates

    public enum StageTarget {
        public static func next(after status: API.TicketStatus) -> API.TicketStatus? {
            switch status {
            case .backlog: .todo
            case .todo: .inProgress
            case .inProgress: .inReview
            case .inReview: .done
            default: nil
            }
        }
    }

    public struct Gate: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable { case dependency, mockup, approval, pr }
        public enum Destination: Sendable, Equatable {
            case section(String)
            case route(String)
            case externalURL(String)
        }

        public var id: String { "\(kind.rawValue)-\(title)" }
        public var kind: Kind
        public var title: String
        public var detail: String
        public var icon: String
        public var actionLabel: String
        public var destination: Destination

        public init(
            kind: Kind, title: String, detail: String, icon: String,
            actionLabel: String, destination: Destination
        ) {
            self.kind = kind
            self.title = title
            self.detail = detail
            self.icon = icon
            self.actionLabel = actionLabel
            self.destination = destination
        }
    }

    public static func unmetGates(for ticket: API.Ticket, now: Date = Date()) -> [Gate] {
        var gates: [Gate] = []

        let blockers = ticket.blockedBy.filter { $0.status != .done }
        if !blockers.isEmpty {
            let detail = blockers.map { "\($0.key) is \(TicketsLogic.statusLabel($0.status))" }.joined(separator: " · ")
            gates.append(Gate(
                kind: .dependency,
                title: blockers.count == 1 ? "Unmet dependency" : "\(blockers.count) unmet dependencies",
                detail: detail,
                icon: "link",
                actionLabel: "View blockers",
                destination: .section("blocked-by")
            ))
        }

        let mg = ticket.mockupGate
        if mg.required && !mg.approved {
            let candidate = mg.mockups.first { $0.reviewState != .approved }
            let detail: String
            let action: String
            let dest: Gate.Destination
            if let m = candidate {
                let stateLabel = m.reviewState == .pending ? "Pending review" : "Changes requested"
                detail = "\(m.title) · \(m.versionLabel) · \(stateLabel)"
                action = "Review mockup"
                dest = .route("/artifacts/\(TicketsLogic.savedEncoded(m.id))/review?ticket=\(TicketsLogic.savedEncoded(ticket.key))")
            } else {
                detail = "No mockup yet"
                action = "Add a mockup"
                dest = .section("mockups")
            }
            gates.append(Gate(
                kind: .mockup,
                title: "Mockup not approved",
                detail: detail,
                icon: "artifacts",
                actionLabel: action,
                destination: dest
            ))
        }

        let pendingApprovals = ticket.approvals.filter { $0.state == .pending }
        if let first = pendingApprovals.first {
            let waited = APIDate.shortAgo(first.createdAt, now: now)
            let waitedPart = waited.isEmpty ? "" : " \(waited)"
            gates.append(Gate(
                kind: .approval,
                title: pendingApprovals.count == 1 ? "Approval pending" : "\(pendingApprovals.count) approvals pending",
                detail: "\(first.scope) · requested by @\(first.agent.handle)\(waitedPart)",
                icon: "shield",
                actionLabel: "Review approval",
                destination: .section("approval-\(first.id)")
            ))
        }

        if let pr = ticket.pr, pr.state == .open || pr.state == .draft {
            let diff = pr.additions.map { " · +\($0) −\(pr.deletions ?? 0)" } ?? ""
            let dest: Gate.Destination = pr.url.map(Gate.Destination.externalURL) ?? .section("code")
            gates.append(Gate(
                kind: .pr,
                title: pr.state == .draft ? "Draft PR" : "PR in review",
                detail: "#\(pr.number) · \(pr.state == .draft ? "Draft" : "Open")\(diff)",
                icon: "pr",
                actionLabel: "Open PR",
                destination: dest
            ))
        }

        return gates
    }

    // MARK: Criteria & Atomic Draft Diffing (ADR-034)

    public struct CriterionCheckInfo: Sendable, Equatable {
        public var actorName: String
        public var actorType: API.Actor.TypeValue
        public var actorId: String?
        public var avatarColor: String?
        public var colorIndex: Int?
        public var createdAt: String

        public init(
            actorName: String,
            actorType: API.Actor.TypeValue,
            actorId: String? = nil,
            avatarColor: String? = nil,
            colorIndex: Int? = nil,
            createdAt: String
        ) {
            self.actorName = actorName
            self.actorType = actorType
            self.actorId = actorId
            self.avatarColor = avatarColor
            self.colorIndex = colorIndex
            self.createdAt = createdAt
        }
    }

    public static func checkedByMap(from events: [API.ActivityEvent]) -> [String: CriterionCheckInfo] {
        var map: [String: CriterionCheckInfo] = [:]
        for event in events {
            guard let cid = event.payload["criterion_id"]?.stringValue, !cid.isEmpty else { continue }
            if event.verb == "criterion_checked" {
                map[cid] = CriterionCheckInfo(
                    actorName: event.actor.name,
                    actorType: event.actor.type,
                    actorId: event.actor.id,
                    avatarColor: event.actor.avatarColor,
                    colorIndex: event.actor.colorIndex,
                    createdAt: event.createdAt
                )
            } else if event.verb == "criterion_unchecked" {
                map.removeValue(forKey: cid)
            }
        }
        return map
    }

    public struct DraftCriterion: Sendable, Equatable, Identifiable {
        public var id: String
        public var criterionId: String?
        public var text: String
        public var done: Bool

        public init(id: String = UUID().uuidString, criterionId: String? = nil, text: String = "", done: Bool = false) {
            self.id = id
            self.criterionId = criterionId
            self.text = text
            self.done = done
        }
    }

    public struct TicketSnapshot: Sendable, Equatable {
        public var revision: Int
        public var title: String
        public var descriptionMd: String
        public var status: API.TicketStatus
        public var priority: API.Priority
        public var estimatePoints: Int?
        public var assigneeAgentId: String?
        public var epicId: String?
        public var criteria: [API.Criterion]

        public init(
            revision: Int,
            title: String,
            descriptionMd: String,
            status: API.TicketStatus,
            priority: API.Priority,
            estimatePoints: Int?,
            assigneeAgentId: String?,
            epicId: String?,
            criteria: [API.Criterion]
        ) {
            self.revision = revision
            self.title = title
            self.descriptionMd = descriptionMd
            self.status = status
            self.priority = priority
            self.estimatePoints = estimatePoints
            self.assigneeAgentId = assigneeAgentId
            self.epicId = epicId
            self.criteria = criteria
        }
    }

    public struct TicketDraft: Sendable, Equatable {
        public var title: String
        public var descriptionMd: String
        public var status: API.TicketStatus
        public var priority: API.Priority
        public var estimatePoints: Int?
        public var assigneeAgentId: String?
        public var epicId: String?
        public var criteria: [DraftCriterion]

        public init(
            title: String,
            descriptionMd: String,
            status: API.TicketStatus,
            priority: API.Priority,
            estimatePoints: Int?,
            assigneeAgentId: String?,
            epicId: String?,
            criteria: [DraftCriterion]
        ) {
            self.title = title
            self.descriptionMd = descriptionMd
            self.status = status
            self.priority = priority
            self.estimatePoints = estimatePoints
            self.assigneeAgentId = assigneeAgentId
            self.epicId = epicId
            self.criteria = criteria
        }
    }

    public static func snapshot(from ticket: API.Ticket) -> TicketSnapshot {
        TicketSnapshot(
            revision: ticket.revision,
            title: ticket.title,
            descriptionMd: ticket.descriptionMd,
            status: ticket.status,
            priority: ticket.priority,
            estimatePoints: ticket.estimatePoints,
            assigneeAgentId: ticket.assignee?.id,
            epicId: ticket.epic?.id,
            criteria: ticket.criteria
        )
    }

    public static func draft(from snapshot: TicketSnapshot) -> TicketDraft {
        TicketDraft(
            title: snapshot.title,
            descriptionMd: snapshot.descriptionMd,
            status: snapshot.status,
            priority: snapshot.priority,
            estimatePoints: snapshot.estimatePoints,
            assigneeAgentId: snapshot.assigneeAgentId,
            epicId: snapshot.epicId,
            criteria: snapshot.criteria.map {
                DraftCriterion(id: $0.id, criterionId: $0.id, text: $0.text, done: $0.done)
            }
        )
    }

    private static func effectiveDraftItems(_ draft: TicketDraft) -> [API.TicketCriterionDraft] {
        draft.criteria
            .filter { $0.criterionId != nil || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { API.TicketCriterionDraft(done: $0.done, id: $0.criterionId, text: $0.text) }
    }

    public static func criteriaChanged(base: TicketSnapshot, draft: TicketDraft) -> Bool {
        let items = effectiveDraftItems(draft)
        if items.count != base.criteria.count { return true }
        return zip(items, base.criteria).contains { item, orig in
            item.id != orig.id || item.text != orig.text || item.done != orig.done
        }
    }

    public static func buildPatch(base: TicketSnapshot, draft: TicketDraft) -> API.TicketPatch? {
        var patch = API.TicketPatch(revision: base.revision)
        var changed = false

        if draft.title != base.title {
            patch.title = draft.title
            changed = true
        }
        if draft.descriptionMd != base.descriptionMd {
            patch.descriptionMd = draft.descriptionMd
            changed = true
        }
        if draft.status != base.status {
            patch.status = draft.status
            changed = true
        }
        if draft.priority != base.priority {
            patch.priority = draft.priority
            changed = true
        }
        if draft.estimatePoints != base.estimatePoints {
            patch.estimatePoints = draft.estimatePoints.map(APINullable.value) ?? .null
            changed = true
        }
        if draft.assigneeAgentId != base.assigneeAgentId {
            patch.assigneeAgentId = draft.assigneeAgentId.map(APINullable.value) ?? .null
            changed = true
        }
        if draft.epicId != base.epicId {
            patch.epicId = draft.epicId.map(APINullable.value) ?? .null
            changed = true
        }
        if criteriaChanged(base: base, draft: draft) {
            patch.criteria = API.TicketCriteriaDraft(expected: base.criteria, items: effectiveDraftItems(draft))
            changed = true
        }
        return changed ? patch : nil
    }

    public static func moveCriterion(_ list: [DraftCriterion], at index: Int, delta: Int) -> [DraftCriterion] {
        let to = index + delta
        guard index >= 0, index < list.count, to >= 0, to < list.count, index != to else { return list }
        var next = list
        next.swapAt(index, to)
        return next
    }

    public static func isValidDescriptionChange(original: String, draft: String) -> Bool {
        draft != original
    }

    // MARK: Revision Conflicts & Optimistic Criterion Toggle

    public struct SaveConflict: Sendable, Equatable {
        public var patch: API.TicketPatch
        public var description: String

        public init(patch: API.TicketPatch, description: String) {
            self.patch = patch
            self.description = description
        }
    }

    public static func isConflict(_ error: APIError) -> Bool {
        if case .http(status: 409, _) = error { return true }
        return false
    }

    public static func mergePatches(_ existing: API.TicketPatch, _ newer: API.TicketPatch) -> API.TicketPatch {
        API.TicketPatch(
            assigneeAgentId: newer.assigneeAgentId ?? existing.assigneeAgentId,
            criteria: newer.criteria ?? existing.criteria,
            descriptionMd: newer.descriptionMd ?? existing.descriptionMd,
            dueDate: newer.dueDate ?? existing.dueDate,
            epicId: newer.epicId ?? existing.epicId,
            estimate: newer.estimate ?? existing.estimate,
            estimatePoints: newer.estimatePoints ?? existing.estimatePoints,
            labelIds: newer.labelIds ?? existing.labelIds,
            priority: newer.priority ?? existing.priority,
            requiresMockup: newer.requiresMockup ?? existing.requiresMockup,
            reviewerUserId: newer.reviewerUserId ?? existing.reviewerUserId,
            revision: newer.revision ?? existing.revision,
            status: newer.status ?? existing.status,
            title: newer.title ?? existing.title
        )
    }

    @MainActor
    public static func toggleCriterionOptimisticUpdate(
        ticketRequest: APIRequest<API.Ticket>,
        criterionId: String,
        done: Bool
    ) -> OptimisticUpdate {
        OptimisticUpdate.update(ticketRequest) { ticket in
            guard let idx = ticket.criteria.firstIndex(where: { $0.id == criterionId }) else { return }
            ticket.criteria[idx].done = done
        }
    }

    // MARK: Dependencies

    public static func isValidTicketKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^[A-Za-z][A-Za-z0-9]*-\d+$"#, options: .regularExpression) != nil
    }

    public static func normalizeTicketKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func updatedBlockerKeys(current: [API.TicketDependency], adding rawKey: String) -> [String]? {
        let key = normalizeTicketKey(rawKey)
        guard isValidTicketKey(key) else { return nil }
        let existing = current.map(\.key)
        guard !existing.contains(key) else { return nil }
        return existing + [key]
    }

    public static func updatedBlockerKeys(current: [API.TicketDependency], removing key: String) -> [String] {
        let normalized = normalizeTicketKey(key)
        return current.map(\.key).filter { $0.uppercased() != normalized }
    }

    public static func blockerCandidates(
        from tickets: [API.TicketSummary],
        excluding excludedKeys: Set<String>,
        limit: Int = 6
    ) -> [API.TicketSummary] {
        Array(tickets.filter { !excludedKeys.contains($0.key) }.prefix(max(0, limit)))
    }

    // MARK: Activity Timeline & Verb Formatting

    public struct TimelineEntry: Sendable, Equatable, Identifiable {
        public var id: String { event.id }
        public var event: API.ActivityEvent
        public var isComment: Bool
        public var commentId: String?
        public var replies: [API.ActivityEvent]
        public var showLivePlan: Bool

        public init(
            event: API.ActivityEvent,
            isComment: Bool,
            commentId: String?,
            replies: [API.ActivityEvent],
            showLivePlan: Bool
        ) {
            self.event = event
            self.isComment = isComment
            self.commentId = commentId
            self.replies = replies
            self.showLivePlan = showLivePlan
        }
    }

    public static func buildTimeline(events: [API.ActivityEvent], liveRunId: String? = nil) -> [TimelineEntry] {
        var repliesByParent: [String: [API.ActivityEvent]] = [:]
        for event in events where event.verb == "commented" {
            if let parent = event.payload["parent_comment_id"]?.stringValue, !parent.isEmpty {
                repliesByParent[parent, default: []].append(event)
            }
        }

        let latestPlanEventId: String? = liveRunId.flatMap { runId in
            events.last { $0.verb == "plan_posted" && $0.payload["run_id"]?.stringValue == runId }?.id
        }

        return events.compactMap { event -> TimelineEntry? in
            if event.verb == "commented",
               let parent = event.payload["parent_comment_id"]?.stringValue,
               !parent.isEmpty
            {
                return nil
            }
            let cid = event.payload["comment_id"]?.stringValue
            let replies = cid.flatMap { repliesByParent[$0] } ?? []
            return TimelineEntry(
                event: event,
                isComment: event.verb == "commented",
                commentId: cid,
                replies: replies,
                showLivePlan: event.id == latestPlanEventId
            )
        }
    }

    public struct FormattedActivity: Sendable, Equatable {
        public enum ToneKind: String, Sendable, Equatable { case normal, human, blocked, done }
        public var text: String
        public var quote: String?
        public var linkPath: String?
        public var externalURL: String?
        public var viaChatId: String?
        public var tone: ToneKind

        public init(
            text: String,
            quote: String? = nil,
            linkPath: String? = nil,
            externalURL: String? = nil,
            viaChatId: String? = nil,
            tone: ToneKind = .normal
        ) {
            self.text = text
            self.quote = quote
            self.linkPath = linkPath
            self.externalURL = externalURL
            self.viaChatId = viaChatId
            self.tone = tone
        }
    }

    public static func formatActivity(_ event: API.ActivityEvent) -> FormattedActivity {
        let p = event.payload
        let viaChat = p["via"]?["chat_id"]?.stringValue
        let str: (String) -> String = { p[$0]?.stringValue ?? "" }
        let intVal: (String) -> Int? = { key in
            switch p[key] {
            case .int(let n): n
            case .double(let d): Int(d)
            default: nil
            }
        }
        let boolVal: (String) -> Bool = { key in
            if case .bool(let b) = p[key] { return b }
            return false
        }
        let stringArray: (String) -> [String] = { key in
            guard case .array(let arr) = p[key] else { return [] }
            return arr.compactMap(\.stringValue)
        }

        func statusName(_ raw: String) -> String {
            raw.isEmpty ? "" : TicketsLogic.statusLabel(API.TicketStatus(rawValue: raw))
        }
        func priorityName(_ raw: String) -> String {
            raw.isEmpty ? "" : TicketsLogic.priorityLabel(API.Priority(rawValue: raw))
        }

        switch event.verb {
        case "created":
            return FormattedActivity(text: "created the ticket", viaChatId: viaChat)
        case "status_changed":
            return FormattedActivity(
                text: "moved this from \(statusName(str("from"))) to \(statusName(str("to")))",
                viaChatId: viaChat
            )
        case "priority_changed":
            return FormattedActivity(text: "set priority to \(priorityName(str("to")))", viaChatId: viaChat)
        case "title_changed":
            return FormattedActivity(text: "renamed this from \u{201C}\(str("from"))\u{201D}", viaChatId: viaChat)
        case "description_edited":
            return FormattedActivity(text: "edited the description", viaChatId: viaChat)
        case "assigned":
            return FormattedActivity(text: "assigned this to \(str("agent_name"))", viaChatId: viaChat)
        case "unassigned":
            return FormattedActivity(text: "unassigned \(str("agent_name"))", viaChatId: viaChat)
        case "reviewer_set":
            return FormattedActivity(text: "set \(str("user_name")) as reviewer", viaChatId: viaChat)
        case "reviewer_cleared":
            return FormattedActivity(text: "removed the reviewer", viaChatId: viaChat)
        case "epic_changed":
            let name = str("epic_name")
            return FormattedActivity(
                text: name.isEmpty ? "removed it from its epic" : "moved this to \(name)",
                viaChatId: viaChat
            )
        case "labels_changed":
            let added = stringArray("added")
            let removed = stringArray("removed")
            var parts: [String] = []
            if !added.isEmpty { parts.append("added \(added.joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
            return FormattedActivity(text: parts.isEmpty ? "updated labels" : parts.joined(separator: " and "), viaChatId: viaChat)
        case "estimate_changed":
            if let points = intVal("to_points") {
                let rationale = str("rationale")
                return FormattedActivity(
                    text: "estimated \(points) points",
                    quote: rationale.isEmpty ? nil : rationale,
                    viaChatId: viaChat
                )
            }
            if p["to_points"] != nil {
                return FormattedActivity(text: "cleared the estimate", viaChatId: viaChat)
            }
            let legacy = str("to")
            return FormattedActivity(
                text: legacy.isEmpty ? "cleared the estimate" : "set the estimate to \(legacy)",
                viaChatId: viaChat
            )
        case "due_changed":
            let to = str("to")
            return FormattedActivity(
                text: to.isEmpty ? "cleared the due date" : "set the due date to \(formatDueDate(to))",
                viaChatId: viaChat
            )
        case "criterion_added":
            return FormattedActivity(text: "added a criterion: \(str("text"))", viaChatId: viaChat)
        case "criterion_checked":
            return FormattedActivity(text: "checked off \(str("text"))", viaChatId: viaChat)
        case "criterion_unchecked":
            return FormattedActivity(text: "unchecked \(str("text"))", viaChatId: viaChat)
        case "criterion_removed":
            return FormattedActivity(text: "removed a criterion: \(str("text"))", viaChatId: viaChat)
        case "dependencies_changed":
            let blockers = stringArray("blocked_by")
            return FormattedActivity(
                text: "updated dependencies: \(blockers.isEmpty ? "no blockers" : blockers.joined(separator: ", "))",
                viaChatId: viaChat
            )
        case "artifact_attached":
            let verb = str("relation") == "generated" ? "generated" : "attached"
            let aid = str("artifact_id")
            return FormattedActivity(
                text: "\(verb) \(str("title"))",
                linkPath: aid.isEmpty ? nil : "/artifacts/\(aid)",
                viaChatId: viaChat
            )
        case "artifact_detached":
            return FormattedActivity(text: "removed \(str("title")) from context", viaChatId: viaChat)
        case "dispatched":
            return FormattedActivity(text: "dispatched this to \(str("agent_name"))", viaChatId: viaChat)
        case "run_started":
            if str("mode") == "unmanaged" {
                return FormattedActivity(text: "started working (unmanaged session)", viaChatId: viaChat)
            }
            let harness = str("harness")
            return FormattedActivity(
                text: harness.isEmpty ? "started working" : "started working on \(harness)",
                viaChatId: viaChat
            )
        case "run_failed":
            return FormattedActivity(
                text: "stopped the run: \(str("reason"))",
                viaChatId: viaChat,
                tone: .blocked
            )
        case "pr_merged":
            let num = intVal("number").map(String.init) ?? str("number")
            return FormattedActivity(text: "saw PR #\(num) merge on GitHub", viaChatId: viaChat, tone: .done)
        case "pr_closed":
            let num = intVal("number").map(String.init) ?? str("number")
            return FormattedActivity(text: "saw PR #\(num) closed without merging", viaChatId: viaChat)
        case "plan_posted":
            return FormattedActivity(text: "posted an execution plan", viaChatId: viaChat)
        case "tests_ran":
            let passed = intVal("passed") ?? 0
            let failed = intVal("failed") ?? 0
            var durText = ""
            if let durationS = intVal("duration_s"), durationS > 0 {
                durText = " · \(durationS / 60)m \(durationS % 60)s"
            }
            return FormattedActivity(
                text: "ran the test suite: \(passed) passed, \(failed) failed\(durText)",
                viaChatId: viaChat,
                tone: failed > 0 ? .blocked : .done
            )
        case "branch_set":
            return FormattedActivity(text: "created branch \(str("branch"))", viaChatId: viaChat)
        case "pr_opened":
            let num = intVal("number").map(String.init) ?? str("number")
            let draft = boolVal("draft") ? " as a draft" : ""
            let url = str("url")
            return FormattedActivity(
                text: "opened PR #\(num)\(draft)",
                externalURL: url.isEmpty ? nil : url,
                viaChatId: viaChat
            )
        case "approval_requested":
            return FormattedActivity(
                text: "paused and requested approval for \(str("scope")): \(str("summary"))",
                viaChatId: viaChat,
                tone: .human
            )
        case "approval_approved":
            let note = str("note")
            return FormattedActivity(
                text: "approved \(str("scope"))\(note.isEmpty ? "" : ": \u{201C}\(note)\u{201D}")",
                viaChatId: viaChat,
                tone: .done
            )
        case "approval_denied":
            let note = str("note")
            return FormattedActivity(
                text: "denied \(str("scope"))\(note.isEmpty ? "" : ": \u{201C}\(note)\u{201D}")",
                viaChatId: viaChat,
                tone: .blocked
            )
        case "gated_action_ran":
            let ok = boolVal("ok")
            let err = str("error")
            return FormattedActivity(
                text: "ran \(str("scope")) through Vesper: \(str("summary"))",
                quote: err.isEmpty ? nil : err,
                viaChatId: viaChat,
                tone: ok ? .done : .blocked
            )
        case "waiting_for_human":
            return FormattedActivity(
                text: "is waiting for a reply: \(str("reason"))",
                viaChatId: viaChat,
                tone: .human
            )
        case "delegated":
            return FormattedActivity(text: "delegated to \(str("agent_name")): \(str("task"))", viaChatId: viaChat)
        case "run_paused":
            return FormattedActivity(text: "paused the run", viaChatId: viaChat)
        case "run_resumed":
            return FormattedActivity(text: "resumed the run", viaChatId: viaChat)
        case "run_cancelled":
            let reason = str("reason")
            return FormattedActivity(
                text: reason.isEmpty ? "cancelled the run" : "stopped the run: \(reason)",
                viaChatId: viaChat
            )
        case "run_completed":
            let outcome = str("outcome")
            return FormattedActivity(
                text: outcome.isEmpty ? "finished the run" : "finished the run: \(outcome)",
                viaChatId: viaChat,
                tone: .done
            )
        case "mockup_requirement_changed":
            return FormattedActivity(
                text: boolVal("to") ? "made an approved UI mockup required" : "no longer requires a UI mockup",
                viaChatId: viaChat
            )
        case "mockup_review_requested":
            let aid = str("artifact_id")
            return FormattedActivity(
                text: "drafted mockup \(str("title")) \(str("version")) and is waiting for a review",
                linkPath: aid.isEmpty ? nil : "/artifacts/\(aid)",
                viaChatId: viaChat,
                tone: .human
            )
        case "mockup_approved", "mockup_changes_requested":
            let approved = event.verb == "mockup_approved"
            let note = str("note")
            let aid = str("artifact_id")
            return FormattedActivity(
                text: "\(approved ? "approved" : "requested changes to") mockup \(str("title")) \(str("version"))\(note.isEmpty ? "" : ": \u{201C}\(note)\u{201D}")",
                linkPath: aid.isEmpty ? nil : "/artifacts/\(aid)",
                viaChatId: viaChat,
                tone: approved ? .done : .human
            )
        default:
            return FormattedActivity(text: event.verb, viaChatId: viaChat)
        }
    }

    // MARK: Formatting

    public static func formatDueDate(_ ymd: String, locale: Locale = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: ymd) else { return ymd }
        let out = DateFormatter()
        out.locale = locale
        out.setLocalizedDateFormatFromTemplate("MMM d")
        return out.string(from: date)
    }

    public static func formatCompactNumber(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    // MARK: Pager & Toolbar

    public struct PagerState: Sendable, Equatable {
        public var index: Int
        public var total: Int
        public var prevKey: String?
        public var nextKey: String?

        public init(index: Int, total: Int, prevKey: String?, nextKey: String?) {
            self.index = index
            self.total = total
            self.prevKey = prevKey
            self.nextKey = nextKey
        }
    }

    public static func pager(for key: String, in tickets: [API.TicketSummary]) -> PagerState {
        let keys = tickets.map(\.key)
        guard let idx = keys.firstIndex(of: key) else {
            return PagerState(index: -1, total: keys.count, prevKey: nil, nextKey: nil)
        }
        return PagerState(
            index: idx,
            total: keys.count,
            prevKey: idx > 0 ? keys[idx - 1] : nil,
            nextKey: idx < keys.count - 1 ? keys[idx + 1] : nil
        )
    }

    public enum ToolbarAction: Sendable, Equatable {
        case cost, prev, next, copy
    }

    public static func buildToolbar(cost: String?, pager: PagerState?, copied: Bool) -> [ToolbarItem] {
        var items: [ToolbarItem] = []
        if let cost, !cost.isEmpty {
            items.append(ToolbarItem(id: "ticket.cost", label: cost, icon: "dollar", kind: .button, showsLabel: true))
        }
        if let pager, pager.total > 0, pager.index >= 0 {
            items.append(ToolbarItem(
                id: "ticket.pager", label: "\(pager.index + 1) / \(pager.total)",
                kind: .button, disabled: true, showsLabel: true
            ))
        }
        items.append(ToolbarItem(
            id: "ticket.prev", label: "← Previous (K)", kind: .button,
            disabled: pager?.prevKey == nil, showsLabel: true
        ))
        items.append(ToolbarItem(
            id: "ticket.next", label: "Next (J) →", kind: .button,
            disabled: pager?.nextKey == nil, showsLabel: true
        ))
        items.append(ToolbarItem(
            id: "ticket.copy", label: copied ? "Link copied" : "Copy link",
            icon: copied ? "check" : "link", kind: .button
        ))
        return items
    }

    public static func toolbarAction(for itemId: String) -> ToolbarAction? {
        switch itemId {
        case "ticket.cost": .cost
        case "ticket.prev": .prev
        case "ticket.next": .next
        case "ticket.copy": .copy
        default: nil
        }
    }

    // MARK: Native Inspector Model

    public static func buildInspectorModel(
        ticket: API.Ticket,
        bootstrap: API.Bootstrap?,
        runs: [API.Run],
        runsHasMore: Bool,
        backlinks: API.Backlinks?,
        canEditBlockedBy: Bool,
        saveError: String?,
        open: Bool,
        activeTabId: String,
        now: Date = Date()
    ) -> InspectorModel {
        let projectEpics = (bootstrap?.epics ?? []).filter { $0.projectId == ticket.project.id }
        let mainAgents = (bootstrap?.agents ?? []).filter { $0.kind == .main }
        let users = bootstrap?.users ?? []
        let allLabels = bootstrap?.labels ?? []
        let closed = ticket.status == .done || ticket.status == .canceled

        var scale = TicketsLogic.estimateScale
        if let pts = ticket.estimatePoints, !scale.contains(pts) {
            scale.append(pts)
            scale.sort()
        }

        var propItems: [InspectorItem] = []
        if let saveError, !saveError.isEmpty {
            propItems.append(InspectorItem(
                id: "save_error", kind: .note, label: "Save failed", detail: saveError, tone: .blocked
            ))
        }

        let assigneeBadge: NavBadge? = needsDispatch(ticket)
            ? NavBadge(text: "Not dispatched", tone: .human)
            : ticket.run?.state == .queued
                ? NavBadge(text: "Queued", tone: .neutral)
                : nil

        propItems.append(InspectorItem(
            id: "status", kind: .picker, label: "Status", value: ticket.status.rawValue,
            options: TicketsLogic.statusOrder.map {
                InspectorOption(value: $0.rawValue, label: TicketsLogic.statusLabel($0))
            }
        ))
        propItems.append(InspectorItem(
            id: "priority", kind: .picker, label: "Priority", value: ticket.priority.rawValue,
            options: TicketsLogic.priorityOrder.map {
                InspectorOption(value: $0.rawValue, label: TicketsLogic.priorityLabel($0))
            }
        ))
        propItems.append(InspectorItem(
            id: "assignee_agent_id", kind: .picker, label: "Persona",
            value: ticket.assignee?.id ?? "",
            badge: assigneeBadge,
            options: [InspectorOption(value: "", label: "Unassigned")]
                + mainAgents.map { InspectorOption(value: $0.id, label: $0.name) }
        ))
        propItems.append(InspectorItem(
            id: "reviewer_user_id", kind: .picker, label: "Reviewer",
            value: ticket.reviewer?.id ?? "",
            options: [InspectorOption(value: "", label: "No reviewer")]
                + users.map { InspectorOption(value: $0.id, label: $0.name) }
        ))
        propItems.append(InspectorItem(
            id: "epic_id", kind: .picker, label: "Epic",
            value: ticket.epic?.id ?? "",
            options: [InspectorOption(value: "", label: "No epic")]
                + projectEpics.map { InspectorOption(value: $0.id, label: $0.name) }
        ))
        propItems.append(InspectorItem(
            id: "space", kind: .fact, label: "Space", value: ticket.project.name
        ))

        if ticket.mockupGate.fromEpic {
            propItems.append(InspectorItem(
                id: "requires_mockup_note", kind: .fact, label: "Mockup",
                value: "Required by epic \(ticket.epic?.name ?? "epic")"
            ))
        } else {
            propItems.append(InspectorItem(
                id: "requires_mockup", kind: .toggle, label: "Mockup",
                value: ticket.requiresMockup ? "Required" : "Not required",
                detail: ticket.requiresMockup ? "Required" : "Not required",
                checked: ticket.requiresMockup
            ))
        }

        propItems.append(InspectorItem(
            id: "estimate_points", kind: .picker, label: "Estimate",
            value: ticket.estimatePoints.map(String.init) ?? "",
            disabled: closed,
            options: [InspectorOption(value: "", label: "Unestimated")]
                + scale.map { InspectorOption(value: String($0), label: "\($0) pts") }
        ))

        if closed {
            propItems.append(InspectorItem(
                id: "estimate_note", kind: .note,
                detail: "Closed tickets can\u{2019}t be re-estimated.", tone: .neutral
            ))
        } else if let legacy = ticket.estimate, !legacy.isEmpty {
            propItems.append(InspectorItem(
                id: "estimate_note", kind: .note,
                detail: "Legacy note: \(legacy)", tone: .neutral
            ))
        }

        propItems.append(InspectorItem(
            id: "due_date", kind: .text, label: "Due",
            value: ticket.dueDate ?? "", placeholder: "YYYY-MM-DD"
        ))

        let selectedLabelIds = Set(ticket.labels.map(\.id))
        let labelMenu = allLabels.map {
            MenuItem(id: $0.id, label: $0.name, checked: selectedLabelIds.contains($0.id))
        }
        propItems.append(InspectorItem(
            id: "labels", kind: .chips, label: "Labels",
            placeholder: "Toggle label", actionId: "labels",
            chips: ticket.labels.map {
                InspectorChip(id: $0.id, text: $0.name, color: $0.color, removable: true)
            },
            menu: labelMenu.isEmpty ? nil : labelMenu
        ))

        var sections: [InspectorSection] = [
            InspectorSection(id: "properties", title: "Properties", items: propItems)
        ]

        sections.append(InspectorSection(
            id: "blocked_by",
            title: "Blocked by",
            aside: ticket.blockedBy.isEmpty ? nil : "\(ticket.blockedBy.count)",
            emptyText: "No blockers.",
            items: ticket.blockedBy.isEmpty ? [] : [
                InspectorItem(
                    id: "blocked_by_list",
                    kind: .list,
                    actionId: "remove_blocked_by",
                    rows: ticket.blockedBy.map { dep in
                        NavItem(
                            id: dep.key,
                            title: "\(dep.key) · \(dep.title)",
                            status: TicketsLogic.statusTone(dep.status),
                            trailing: TicketsLogic.statusLabel(dep.status),
                            href: "/tickets/\(TicketsLogic.savedEncoded(dep.key))",
                            contextMenu: canEditBlockedBy
                                ? [MenuItem(id: "remove", label: "Remove blocker", icon: "x", destructive: true)]
                                : nil
                        )
                    }
                ),
            ]
        ))

        sections.append(InspectorSection(
            id: "blocks",
            title: "Blocks",
            aside: ticket.blocks.isEmpty ? nil : "\(ticket.blocks.count)",
            emptyText: "Doesn\u{2019}t block other tickets.",
            items: ticket.blocks.isEmpty ? [] : [
                InspectorItem(
                    id: "blocks_list",
                    kind: .list,
                    actionId: "remove_blocks",
                    rows: ticket.blocks.map { dep in
                        NavItem(
                            id: dep.key,
                            title: "\(dep.key) · \(dep.title)",
                            status: TicketsLogic.statusTone(dep.status),
                            trailing: TicketsLogic.statusLabel(dep.status),
                            href: "/tickets/\(TicketsLogic.savedEncoded(dep.key))",
                            contextMenu: [
                                MenuItem(id: "remove", label: "Remove blocking link", icon: "x", destructive: true)
                            ]
                        )
                    }
                ),
            ]
        ))

        sections.append(InspectorSection(
            id: "runs",
            title: "Runs",
            aside: runsCostSummary(runs, hasMore: runsHasMore),
            emptyText: "No runs yet. Dispatch the ticket to start one.",
            items: runs.isEmpty ? [] : [
                InspectorItem(
                    id: "runs_list",
                    kind: .list,
                    rows: runs.map { run in
                        let st = runStateBadge(run.state)
                        let when = run.endedAt != nil
                            ? "\(APIDate.timeline(run.startedAt, now: now)) · \(APIDate.duration(since: run.startedAt, until: run.endedAt, now: now))"
                            : "Started \(APIDate.shortAgo(run.startedAt, now: now))"
                        return NavItem(
                            id: run.id,
                            title: "@\(run.agent.handle) · \(st.label)",
                            subtitle: "\(when) · \(run.model)",
                            status: runStateNavTone(run.state),
                            trailing: WorkLogic.runCost(run.costUsd, source: run.costSource),
                            href: "/runs/\(TicketsLogic.savedEncoded(run.id))"
                        )
                    }
                ),
            ]
        ))

        if ticket.branch != nil || ticket.pr != nil {
            var codeItems: [InspectorItem] = []
            if let branch = ticket.branch, !branch.isEmpty {
                codeItems.append(InspectorItem(id: "branch", kind: .fact, label: "Branch", value: branch, mono: true))
            }
            if let pr = ticket.pr {
                let stateLabel = pr.state.rawValue.prefix(1).uppercased() + pr.state.rawValue.dropFirst()
                let diff = pr.additions.map { " (+\($0) −\(pr.deletions ?? 0))" } ?? ""
                codeItems.append(InspectorItem(
                    id: "pr", kind: .fact, label: "Pull request",
                    value: "#\(pr.number) · \(stateLabel)\(diff)", url: pr.url
                ))
                if pr.closedUnmerged == true {
                    codeItems.append(InspectorItem(
                        id: "pr_closed", kind: .note,
                        detail: "PR closed without merging", tone: .blocked
                    ))
                }
                if let synced = pr.syncedAt {
                    codeItems.append(InspectorItem(
                        id: "pr_synced", kind: .fact, label: "Synced",
                        value: "Synced \(APIDate.shortAgo(synced, now: now))"
                    ))
                }
            }
            sections.append(InspectorSection(id: "code", title: "Code", items: codeItems))
        }

        if let backlinks {
            func mentionRow(_ m: API.Mention, clickableToLink: Bool) -> NavItem {
                let s = m.source
                let raw = (s.kind == .artifact && s.artifactType == .note) ? (s.path ?? s.title) : s.title
                let name = s.kind == .comment ? "Comment" : raw
                let title = (s.displayId != nil && s.kind != .agent) ? "\(s.displayId!) · \(name)" : name
                return NavItem(
                    id: clickableToLink ? "\(m.sourceKind.rawValue):\(m.sourceId)" : "\(m.sourceKind.rawValue):\(m.sourceId)",
                    title: title,
                    subtitle: clickableToLink ? "Click to link" : nil,
                    trailing: clickableToLink ? "Link" : nil,
                    href: clickableToLink ? nil : s.href
                )
            }
            let unlinked = backlinks.unlinked.filter {
                $0.sourceKind == .artifact || $0.sourceKind == .ticket
            }
            var blItems: [InspectorItem] = []
            if !backlinks.linked.isEmpty {
                blItems.append(InspectorItem(
                    id: "linked_mentions", kind: .list, label: "Linked mentions",
                    rows: backlinks.linked.map { mentionRow($0, clickableToLink: false) }
                ))
            }
            if !unlinked.isEmpty {
                blItems.append(InspectorItem(
                    id: "unlinked_mentions", kind: .list, label: "Unlinked mentions",
                    actionId: "link_mention",
                    rows: unlinked.map { mentionRow($0, clickableToLink: true) }
                ))
            }
            let total = backlinks.linked.count + unlinked.count
            sections.append(InspectorSection(
                id: "backlinks",
                title: "Backlinks",
                aside: total > 0 ? "\(total)" : nil,
                emptyText: "Nothing links here yet.",
                items: blItems
            ))
        }

        let propsTab = InspectorTab(
            id: "properties", label: "Properties", icon: "sliders", kind: .native, sections: sections
        )
        let chatTab = InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .companion)
        let companion = CompanionContext(
            subject: CompanionSubject(
                kind: .ticket,
                id: ticket.id,
                title: ticket.title,
                agent: ticket.assignee?.handle,
                ticketKey: ticket.key
            ),
            path: "/tickets/\(TicketsLogic.savedEncoded(ticket.key))"
        )
        return InspectorModel(
            id: "ticket:\(ticket.key)",
            open: open,
            activeTabId: activeTabId,
            tabs: [propsTab, chatTab],
            companion: companion
        )
    }
}

private extension TicketsLogic {
    static func savedEncoded(_ s: String) -> String {
        WorkLogic.encode(s)
    }
}
