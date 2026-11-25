import Foundation

/// Pure Swift port of `web/lib/run-graph.ts` and `web/lib/run-graph-layout.ts`.
/// Builds a DAG of turns, human gates, errors, delegated runs, and outcome from `API.RunDetail`,
/// lays it out into columns/branches, and exports both `NodeGraphDocument` and `ELKGraph`.
public enum RunGraphLogic {
    public static let groupThreshold = 12
    public static let minGroup = 3

    // Layout geometry matching `web/app/(app)/runs/[id]/run-graph-view.tsx`.
    public static let columnStep: Double = 168
    public static let nodeWidth: Double = 148
    public static let nodeHeight: Double = 54
    public static let moreHeight: Double = 36
    public static let mainY: Double = 24
    public static let branchY: Double = mainY + nodeHeight + 36
    public static let rowStep: Double = 66
    public static let branchIndent: Double = 16

    // MARK: - Graph Model

    public enum NodeStatus: String, Sendable, Equatable, Hashable {
        case pending, running, waiting, done, failed, cancelled

        public var label: String { rawValue }

        public var tone: NodeGraphTone {
            switch self {
            case .done: .done
            case .running: .accent
            case .waiting: .human
            case .failed: .blocked
            case .pending, .cancelled: .neutral
            }
        }
    }

    public enum GateKind: String, Sendable, Equatable, Hashable, CaseIterable {
        case approval
        case humanReply = "human_reply"
        case mockupReview = "mockup_review"

        public var label: String {
            switch self {
            case .approval: "Approval"
            case .humanReply: "Reply"
            case .mockupReview: "Mockup review"
            }
        }
    }

    public enum GateState: String, Sendable, Equatable, Hashable {
        case pending, resolved
    }

    public struct TurnNode: Sendable, Equatable, Identifiable {
        public var id: String
        public var turn: Int
        public var trigger: String
        public var status: NodeStatus
        public var startedAt: String
        public var endedAt: String?
        public var durationMs: Double?
        public var costUsd: Double?
    }

    public struct SubagentNode: Sendable, Equatable, Identifiable {
        public var id: String
        public var runId: String
        public var agent: String
        public var status: NodeStatus
        public var costUsd: Double
        public var depth: Int
        public var childCount: Int
        public var expanded: Bool
    }

    public enum SubagentFlag: String, Sendable, Equatable, Hashable {
        case capped
        case spinning
        case queueBound = "queue_bound"
        case serial
        case failed

        public var label: String {
            switch self {
            case .capped: "capped ↓"
            case .spinning: "spinning"
            case .queueBound: "queue"
            case .serial: "serial!"
            case .failed: "failed"
            }
        }
    }

    public struct SubagentJobNode: Sendable, Equatable, Identifiable {
        public var id: String
        public var jobId: String
        public var turn: Int
        public var batchId: String?
        public var batchSize: Int
        public var agentType: String
        public var role: String
        public var reason: String
        public var requestedTier: String
        public var tier: String
        public var model: String
        public var effort: String
        public var status: NodeStatus
        public var toolCalls: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var cachedTokens: Int
        public var costUsd: Double?
        public var createdAt: String
        public var startedAt: String?
        public var completedAt: String?
        public var queuedMs: Double?
        public var durationMs: Double?
        public var prompt: String
        public var resultText: String
        public var error: String
        public var flags: [SubagentFlag]
    }

    public struct GateNode: Sendable, Equatable, Identifiable {
        public var id: String
        public var gate: GateKind
        public var state: GateState
        public var afterTurn: Int
        public var detail: String?
    }

    public struct ErrorNode: Sendable, Equatable, Identifiable {
        public var id: String
        public var turn: Int
        public var seq: Int
        public var message: String
    }

    public struct OutcomeNode: Sendable, Equatable, Identifiable {
        public var id: String
        public var status: NodeStatus
        public var text: String
    }

    public enum GraphNode: Sendable, Equatable, Identifiable {
        case turn(TurnNode)
        case subagentRun(SubagentNode)
        case subagentJob(SubagentJobNode)
        case gate(GateNode)
        case error(ErrorNode)
        case outcome(OutcomeNode)

        public var id: String {
            switch self {
            case .turn(let n): n.id
            case .subagentRun(let n): n.id
            case .subagentJob(let n): n.id
            case .gate(let n): n.id
            case .error(let n): n.id
            case .outcome(let n): n.id
            }
        }
    }

    public enum EdgeKind: String, Sendable, Equatable, Hashable {
        case sequence, delegation, resume
    }

    public struct GraphEdge: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: EdgeKind
        public var from: String
        public var to: String
    }

    public struct RunGraph: Sendable, Equatable {
        public var nodes: [GraphNode]
        public var edges: [GraphEdge]

        public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) {
            self.nodes = nodes
            self.edges = edges
        }
    }

    public enum NodeID {
        public static func turn(_ n: Int) -> String { "turn:\(n)" }
        public static func gate(afterTurn: Int) -> String { "gate:\(afterTurn)" }
        public static func run(_ id: String) -> String { "run:\(id)" }
        public static func job(_ id: String) -> String { "job:\(id)" }
        public static func error(_ seq: Int) -> String { "error:\(seq)" }
        public static let outcome = "outcome"
        public static func group(_ firstTurn: Int) -> String { "group:\(firstTurn)" }
        public static func more(_ runNode: String) -> String { "more:\(runNode)" }
    }

    // MARK: - Layout Model

    public struct GroupItem: Sendable, Equatable, Identifiable {
        public var id: String
        public var turns: [TurnNode]
        public var status: NodeStatus
    }

    public enum MainItem: Sendable, Equatable, Identifiable {
        case node(GraphNode)
        case group(GroupItem)

        public var id: String {
            switch self {
            case .node(let n): n.id
            case .group(let g): g.id
            }
        }
    }

    public enum BranchItem: Sendable, Equatable, Identifiable {
        case node(GraphNode, depth: Int)
        case more(id: String, parent: String, count: Int, depth: Int)

        public var id: String {
            switch self {
            case .node(let n, _): n.id
            case .more(let id, _, _, _): id
            }
        }

        public var depth: Int {
            switch self {
            case .node(_, let d): d
            case .more(_, _, _, let d): d
            }
        }
    }

    public struct Column: Sendable, Equatable {
        public var main: MainItem
        public var branch: [BranchItem]
    }

    public struct GraphLayout: Sendable, Equatable {
        public var columns: [Column]
        public var turnCount: Int
    }

    public struct ItemLabels: Sendable, Equatable {
        public var title: String
        public var subtitle: String
        public var status: NodeStatus
    }

    // MARK: - Helpers

    private static let endedStates: Set<String> = ["completed", "failed", "cancelled"]
    private static let activeStatuses: Set<NodeStatus> = [.running, .waiting, .pending]

    public static func runStatus(_ state: String) -> NodeStatus {
        switch state {
        case "queued", "starting": .pending
        case "running": .running
        case "completed": .done
        case "failed": .failed
        case "cancelled": .cancelled
        default: .waiting
        }
    }

    public static func subagentJobStatus(_ status: String) -> NodeStatus {
        switch status {
        case "queued": .pending
        case "running": .running
        case "completed": .done
        case "failed": .failed
        case "canceled", "cancelled": .cancelled
        default: .pending
        }
    }

    public static func subagentFlags(
        requestedTier: String,
        tier: String,
        status: String,
        toolCalls: Int,
        queuedMs: Double?,
        durationMs: Double?,
        serialInTurn: Bool
    ) -> [SubagentFlag] {
        var flags: [SubagentFlag] = []
        if !requestedTier.isEmpty && !tier.isEmpty && requestedTier != tier { flags.append(.capped) }
        if status == "failed" { flags.append(.failed) }
        if toolCalls >= 20 { flags.append(.spinning) }
        if let q = queuedMs, q >= 5_000, durationMs == nil || q > (durationMs ?? 0) { flags.append(.queueBound) }
        if serialInTurn { flags.append(.serial) }
        return flags
    }

    private static func turnStatus(_ turn: API.RunTurn, run: API.Run, isLast: Bool) -> NodeStatus {
        if turn.status.rawValue == "done" {
            if let exit = turn.exitCode, exit != 0 { return .failed }
            return isLast && run.state.rawValue == "failed" ? .failed : .done
        }
        if endedStates.contains(run.state.rawValue) {
            return run.state.rawValue == "completed" ? .done : runStatus(run.state.rawValue)
        }
        return turn.status.rawValue == "pending" ? .pending : .running
    }

    private static func jsonString(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .array, .object:
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }

    private static func jsonDouble(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    private static func jsonInt(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    private static func normalizedToolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let rest = raw.dropFirst(5)
        guard let sep = rest.range(of: "__") else { return raw }
        return "\(rest[..<sep.lowerBound]).\(rest[sep.upperBound...])"
    }

    public static func turnByEvent(_ events: [API.RunEvent]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var turn = 0
        for e in events.sorted(by: { $0.seq < $1.seq }) {
            if e.type.rawValue == "lifecycle",
               e.payload["state"]?.stringValue == "turn_started",
               let t = jsonInt(e.payload["turn"]) {
                turn = t
            }
            out[e.seq] = turn
        }
        return out
    }

    public static func finalMessage(_ events: [API.RunEvent]) -> String? {
        for e in events.sorted(by: { $0.seq > $1.seq }) {
            if e.type.rawValue == "message",
               e.payload["kind"] == nil || e.payload["kind"] == .null {
                let text = jsonString(e.payload["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func delegateChild(call: API.RunEvent, children: [API.Run]) -> API.Run? {
        let tool = normalizedToolName(jsonString(call.payload["tool"]))
        guard tool == "lazyagents.delegate" else { return nil }
        let rawHandle = jsonString(call.payload["input"]?["agent"])
        let handle = rawHandle.hasPrefix("@") ? String(rawHandle.dropFirst()) : rawHandle
        guard !handle.isEmpty else { return nil }
        let at = APIDate.epoch(call.at)
        return children
            .filter { $0.agent.handle == handle && APIDate.epoch($0.startedAt) >= at - 1.0 }
            .sorted { APIDate.epoch($0.startedAt) < APIDate.epoch($1.startedAt) }
            .first
    }

    private static func turnStarts(_ events: [API.RunEvent]) -> [(turn: Int, at: TimeInterval)] {
        events.compactMap { e in
            guard e.type.rawValue == "lifecycle",
                  e.payload["state"]?.stringValue == "turn_started",
                  let turn = jsonInt(e.payload["turn"]) else { return nil }
            return (turn, APIDate.epoch(e.at))
        }
    }

    private static func turnAt(_ starts: [(turn: Int, at: TimeInterval)], at iso: String) -> Int {
        let t = APIDate.epoch(iso)
        var turn = 0
        for s in starts where s.at <= t && s.turn >= turn { turn = s.turn }
        return turn
    }

    // MARK: - Build Graph

    public static func buildRunGraph(detail: API.RunDetail, loaded: [API.RunDetail] = []) -> RunGraph {
        let detailsById = Dictionary(loaded.map { ($0.run.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        func addEdge(_ kind: EdgeKind, _ from: String, _ to: String) {
            edges.append(GraphEdge(id: "\(kind.rawValue):\(from)->\(to)", kind: kind, from: from, to: to))
        }

        let run = detail.run
        let events = detail.events.sorted { $0.seq < $1.seq }
        let byEvent = turnByEvent(events)

        var turns = detail.turns.sorted { $0.seq < $1.seq }
        if turns.isEmpty && (!events.isEmpty || !(detail.subagentJobs ?? []).isEmpty) {
            turns.append(API.RunTurn(
                endedAt: run.endedAt,
                exitCode: nil,
                hasLog: false,
                inputMessage: "",
                processStartedAt: nil,
                seq: 0,
                startedAt: run.startedAt,
                status: .init(rawValue: endedStates.contains(run.state.rawValue) ? "done" : "running"),
                trigger: .init(rawValue: "start"),
                usage: nil
            ))
        }

        let turnIds = Set(turns.map(\.seq))
        func turnOf(_ n: Int) -> Int? {
            if turnIds.contains(n) { return n }
            var best = turns.first?.seq
            for t in turns where t.seq <= n { best = t.seq }
            return best
        }

        var waits: [Int: [String: JSONValue]] = [:]
        for e in events where e.type.rawValue == "lifecycle" && e.payload["state"]?.stringValue == "waiting" {
            waits[byEvent[e.seq] ?? 0] = e.payload
        }

        func addGate(after prev: Int, kind: GateKind, state: GateState) -> String {
            let w = waits[prev]
            var detailStr: String?
            if let w, w["reason"]?.stringValue == kind.rawValue {
                let s = jsonString(w["scope"] ?? w["artifact_id"])
                if !s.isEmpty { detailStr = s }
            }
            let gate = GateNode(id: NodeID.gate(afterTurn: prev), gate: kind, state: state, afterTurn: prev, detail: detailStr)
            nodes.append(.gate(gate))
            return gate.id
        }

        var prevId: String?
        for (i, t) in turns.enumerated() {
            let id = NodeID.turn(t.seq)
            let durationMs: Double? = t.endedAt.map { (APIDate.epoch($0) - APIDate.epoch(t.startedAt)) * 1000.0 }
            let costUsd = jsonDouble(t.usage?["cost_usd"])
            nodes.append(.turn(TurnNode(
                id: id,
                turn: t.seq,
                trigger: t.trigger.rawValue,
                status: turnStatus(t, run: run, isLast: i == turns.count - 1),
                startedAt: t.startedAt,
                endedAt: t.endedAt,
                durationMs: durationMs,
                costUsd: costUsd
            )))
            if let prevId {
                let prevSeq = turns[i - 1].seq
                let gateKind: GateKind?
                if t.trigger.rawValue == "comment" {
                    gateKind = .humanReply
                } else if t.trigger.rawValue == "approval" {
                    gateKind = waits[prevSeq]?["reason"]?.stringValue == "mockup_review" ? .mockupReview : .approval
                } else {
                    gateKind = nil
                }
                if let gateKind {
                    let gId = addGate(after: prevSeq, kind: gateKind, state: .resolved)
                    addEdge(.sequence, prevId, gId)
                    addEdge(.resume, gId, id)
                } else {
                    addEdge(.sequence, prevId, id)
                }
            }
            prevId = id
        }

        if let last = turns.last,
           run.state.rawValue == "waiting",
           let reason = run.waitReason?.rawValue,
           let gateKind = GateKind(rawValue: reason) {
            let gId = addGate(after: last.seq, kind: gateKind, state: .pending)
            addEdge(.sequence, NodeID.turn(last.seq), gId)
        }

        for e in events where e.type.rawValue == "error" {
            let turn = turnOf(byEvent[e.seq] ?? 0) ?? 0
            let msg = jsonString(e.payload["message"] ?? e.payload["error"])
            let id = NodeID.error(e.seq)
            nodes.append(.error(ErrorNode(id: id, turn: turn, seq: e.seq, message: msg.isEmpty ? "error" : msg)))
            if turnIds.contains(turn) { addEdge(.sequence, NodeID.turn(turn), id) }
        }

        let starts = turnStarts(events)
        var remaining = detail.childRuns
        var parentTurnOf: [String: Int] = [:]
        for call in events where call.type.rawValue == "tool_call" && jsonString(call.payload["tool"]).hasSuffix("delegate") {
            if let child = delegateChild(call: call, children: remaining),
               let idx = remaining.firstIndex(where: { $0.id == child.id }) {
                remaining.remove(at: idx)
                parentTurnOf[child.id] = byEvent[call.seq] ?? 0
            }
        }

        var seen: Set<String> = [run.id]
        func byStart(_ runs: [API.Run]) -> [API.Run] {
            runs.sorted {
                let a = APIDate.epoch($0.startedAt), b = APIDate.epoch($1.startedAt)
                return a == b ? $0.id < $1.id : a < b
            }
        }
        func addRun(_ r: API.Run, from: String, depth: Int) {
            guard !seen.contains(r.id) else { return }
            seen.insert(r.id)
            let id = NodeID.run(r.id)
            let d = detailsById[r.id]
            nodes.append(.subagentRun(SubagentNode(
                id: id,
                runId: r.id,
                agent: r.agent.handle,
                status: runStatus(r.state.rawValue),
                costUsd: r.costUsd,
                depth: depth,
                childCount: d?.childRuns.count ?? r.childCount ?? 0,
                expanded: d != nil
            )))
            addEdge(.delegation, from, id)
            for child in byStart(d?.childRuns ?? []) {
                addRun(child, from: id, depth: depth + 1)
            }
        }

        for child in byStart(detail.childRuns) {
            let t = parentTurnOf[child.id] ?? turnAt(starts, at: child.startedAt)
            guard let resolvedTurn = turnOf(t) else { continue }
            addRun(child, from: NodeID.turn(resolvedTurn), depth: 1)
        }

        // In-turn explorer/helper subagent jobs: attach via their first lifecycle event
        // (or timestamp fallback), preserve creation order, and compute batching/anomaly flags.
        var jobTurn: [String: Int] = [:]
        for e in events where e.type.rawValue == "lifecycle" {
            let state = e.payload["state"]?.stringValue
            guard state == "subagent_queued" || state == "subagent_started" else { continue }
            let sid = e.payload["subagent_id"]?.stringValue ?? ""
            if !sid.isEmpty && jobTurn[sid] == nil {
                jobTurn[sid] = byEvent[e.seq] ?? 0
            }
        }
        let sortedJobs = (detail.subagentJobs ?? []).sorted { a, b in
            let ta = APIDate.epoch(a.createdAt), tb = APIDate.epoch(b.createdAt)
            return ta == tb ? a.id < b.id : ta < tb
        }
        var batchCount: [String: Int] = [:]
        for j in sortedJobs {
            if let bid = j.batchId?.value, !bid.isEmpty {
                batchCount[bid, default: 0] += 1
            }
        }
        let resolvedJobs: [(job: API.SubagentJob, turn: Int)] = sortedJobs.compactMap { j in
            let rawTurn = jobTurn[j.id] ?? turnAt(starts, at: j.createdAt)
            guard let turn = turnOf(rawTurn) else { return nil }
            return (j, turn)
        }
        var unbatchedPerTurn: [Int: Int] = [:]
        for item in resolvedJobs {
            if item.job.batchId?.value?.isEmpty ?? true {
                unbatchedPerTurn[item.turn, default: 0] += 1
            }
        }
        for (j, turn) in resolvedJobs {
            let id = NodeID.job(j.id)
            let createdEpoch = APIDate.epoch(j.createdAt)
            let startedAt = j.startedAt?.value
            let completedAt = j.completedAt?.value
            let queuedMs: Double? = startedAt.map { max(0, (APIDate.epoch($0) - createdEpoch) * 1000.0) }
            let durationMs: Double? = (startedAt != nil && completedAt != nil)
                ? max(0, (APIDate.epoch(completedAt!) - APIDate.epoch(startedAt!)) * 1000.0)
                : nil
            let batchId = (j.batchId?.value).flatMap { $0.isEmpty ? nil : $0 }
            let batchSize = batchId.flatMap { batchCount[$0] } ?? 1
            let status = subagentJobStatus(j.status.rawValue)
            let flags = subagentFlags(
                requestedTier: j.requestedTier,
                tier: j.tier,
                status: j.status.rawValue,
                toolCalls: j.toolCalls,
                queuedMs: queuedMs,
                durationMs: durationMs,
                serialInTurn: batchId == nil && (unbatchedPerTurn[turn] ?? 0) >= 3
            )
            nodes.append(.subagentJob(SubagentJobNode(
                id: id,
                jobId: j.id,
                turn: turn,
                batchId: batchId,
                batchSize: batchSize,
                agentType: j.agentType.rawValue,
                role: j.role,
                reason: j.reason,
                requestedTier: j.requestedTier,
                tier: j.tier,
                model: j.model,
                effort: j.effort,
                status: status,
                toolCalls: j.toolCalls,
                inputTokens: j.inputTokens,
                outputTokens: j.outputTokens,
                cachedTokens: j.cachedTokens,
                costUsd: j.costUsd?.value,
                createdAt: j.createdAt,
                startedAt: startedAt,
                completedAt: completedAt,
                queuedMs: queuedMs,
                durationMs: durationMs,
                prompt: j.prompt,
                resultText: j.resultText,
                error: j.error,
                flags: flags
            )))
            addEdge(.delegation, NodeID.turn(turn), id)
        }

        if endedStates.contains(run.state.rawValue) {
            nodes.append(.outcome(OutcomeNode(id: NodeID.outcome, status: runStatus(run.state.rawValue), text: run.outcome ?? "")))
            if let last = turns.last {
                addEdge(.sequence, NodeID.turn(last.seq), NodeID.outcome)
            }
        }

        return RunGraph(nodes: nodes, edges: edges)
    }

    // MARK: - Column & Branch Layout

    public static func groupStatus(_ turns: [TurnNode]) -> NodeStatus {
        for s in [NodeStatus.failed, .running, .waiting, .pending, .cancelled] {
            if turns.contains(where: { $0.status == s }) { return s }
        }
        return .done
    }

    public static func layoutRunGraph(
        _ graph: RunGraph,
        expanded: Set<String> = [],
        keep: Set<String> = [],
        threshold: Int = groupThreshold
    ) -> GraphLayout {
        let byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var out: [String: [String]] = [:]
        for e in graph.edges { out[e.from, default: []].append(e.to) }

        func countRuns(_ ids: [String]) -> Int {
            ids.reduce(0) { sum, kid in
                let subKids = (out[kid] ?? []).filter { if case .subagentRun = byId[$0] { true } else { false } }
                return sum + 1 + countRuns(subKids)
            }
        }

        func branchOf(_ turnId: String) -> [BranchItem] {
            var items: [BranchItem] = []
            func walk(_ runNodeId: String, depth: Int) {
                guard let node = byId[runNodeId] else { return }
                items.append(.node(node, depth: depth))
                let kids = (out[runNodeId] ?? []).filter { if case .subagentRun = byId[$0] { true } else { false } }
                guard !kids.isEmpty else { return }
                if depth >= 1 && !expanded.contains(runNodeId) {
                    items.append(.more(id: NodeID.more(runNodeId), parent: runNodeId, count: countRuns(kids), depth: depth + 1))
                    return
                }
                for kid in kids { walk(kid, depth: depth + 1) }
            }
            let targets = out[turnId] ?? []
            for k in targets {
                if case .subagentRun = byId[k] { walk(k, depth: 1) }
            }
            for k in targets {
                if let n = byId[k], case .subagentJob = n {
                    items.append(.node(n, depth: 1))
                }
            }
            for k in targets {
                if let n = byId[k], case .error = n {
                    items.append(.node(n, depth: 1))
                }
            }
            return items
        }

        let turns: [TurnNode] = graph.nodes.compactMap {
            if case .turn(let t) = $0 { return t }
            return nil
        }.sorted { $0.turn < $1.turn }

        var gateAfter: [Int: GraphNode] = [:]
        for n in graph.nodes {
            if case .gate(let g) = n { gateAfter[g.afterTurn] = n }
        }

        let grouping = turns.count > threshold
        var columns: [Column] = []
        var pendingQuiet: [TurnNode] = []

        func flush() {
            guard let first = pendingQuiet.first else { return }
            let gId = NodeID.group(first.turn)
            if pendingQuiet.count >= minGroup && !expanded.contains(gId) {
                columns.append(Column(main: .group(GroupItem(id: gId, turns: pendingQuiet, status: groupStatus(pendingQuiet))), branch: []))
            } else {
                for t in pendingQuiet {
                    columns.append(Column(main: .node(.turn(t)), branch: []))
                }
            }
            pendingQuiet = []
        }

        for (i, t) in turns.enumerated() {
            let branch = branchOf(t.id)
            let quiet = grouping && i < turns.count - 1 && branch.isEmpty && !activeStatuses.contains(t.status) && !keep.contains(t.id)
            if quiet {
                pendingQuiet.append(t)
            } else {
                flush()
                columns.append(Column(main: .node(.turn(t)), branch: branch))
            }
            if let gate = gateAfter[t.turn] {
                flush()
                columns.append(Column(main: .node(gate), branch: []))
            }
        }
        flush()

        if let outcome = graph.nodes.first(where: { if case .outcome = $0 { true } else { false } }) {
            columns.append(Column(main: .node(outcome), branch: []))
        }

        let placed = Set(columns.flatMap { [$0.main.id] + $0.branch.map(\.id) })
        var stray = graph.nodes.filter {
            if case .error = $0 { return !placed.contains($0.id) }
            return false
        }
        if !stray.isEmpty {
            if columns.isEmpty {
                let first = stray.removeFirst()
                columns.append(Column(main: .node(first), branch: []))
            }
            columns[0].branch.append(contentsOf: stray.map { .node($0, depth: 1) })
        }

        return GraphLayout(columns: columns, turnCount: turns.count)
    }

    public static func labels(for item: MainItem) -> ItemLabels {
        switch item {
        case .group(let g):
            let first = g.turns.first?.turn ?? 0
            let last = g.turns.last?.turn ?? first
            return ItemLabels(title: "Turns \(first)–\(last)", subtitle: "\(g.turns.count) \(g.status.label) · expand", status: g.status)
        case .node(let n):
            return labels(for: n)
        }
    }

    public static func labels(for item: BranchItem) -> ItemLabels {
        switch item {
        case .more(_, _, let count, _):
            return ItemLabels(title: "+\(count) nested run\(count == 1 ? "" : "s")", subtitle: "expand", status: .pending)
        case .node(let n, _):
            return labels(for: n)
        }
    }

    public static func labels(for node: GraphNode) -> ItemLabels {
        switch node {
        case .turn(let n):
            let timing = n.status == .running
                ? "live"
                : (n.durationMs != nil ? APIDate.duration(since: n.startedAt, until: n.endedAt) : n.status.label)
            return ItemLabels(title: "Turn \(n.turn)", subtitle: "\(n.trigger) · \(timing)", status: n.status)
        case .subagentRun(let n):
            let cost = String(format: "$%.2f", n.costUsd)
            return ItemLabels(title: "↳ \(n.agent)", subtitle: "\(n.status.label) · \(cost)", status: n.status)
        case .subagentJob(let n):
            let name = n.role.isEmpty ? n.agentType : n.role
            let timing: String
            if n.status == .running {
                timing = "live"
            } else if n.durationMs != nil {
                timing = APIDate.duration(since: n.startedAt ?? n.createdAt, until: n.completedAt)
            } else {
                timing = n.status.label
            }
            let tierPart = n.tier.isEmpty ? n.agentType : n.tier
            let flagSuffix = n.flags.isEmpty ? "" : " · \(n.flags.map(\.label).joined(separator: " "))"
            return ItemLabels(title: "↳ \(name)", subtitle: "\(tierPart) · \(timing)\(flagSuffix)", status: n.status)
        case .gate(let n):
            let suffix = n.state == .pending ? "?" : " ✓"
            return ItemLabels(
                title: "\(n.gate.label)\(suffix)",
                subtitle: n.state == .pending ? "waiting on you" : "resolved",
                status: n.state == .pending ? .waiting : .pending
            )
        case .error(let n):
            return ItemLabels(title: "Error", subtitle: n.message, status: .failed)
        case .outcome(let n):
            return ItemLabels(title: "Outcome", subtitle: n.status.label, status: n.status)
        }
    }

    /// Builds a `NodeGraphDocument` using deterministic lane positions matching the web's RunGraphView.
    public static func buildDocument(from layout: GraphLayout, selectedId: String? = nil) -> NodeGraphDocument {
        var nodes: [NodeGraphNodeModel] = []
        var edges: [NodeGraphEdgeModel] = []

        func colX(_ col: Int) -> Double { 16 + Double(col) * columnStep }
        func branchX(_ col: Int, depth: Int) -> Double { colX(col) + 16 + Double(max(0, depth - 1)) * branchIndent }
        func rowY(_ row: Int) -> Double { branchY + Double(row) * rowStep }

        for (colIdx, col) in layout.columns.enumerated() {
            let lbl = labels(for: col.main)
            let shape: NodeGraphShape
            let isDashed: Bool
            switch col.main {
            case .group:
                shape = .card
                isDashed = true
            case .node(.gate):
                shape = .diamond
                isDashed = false
            case .node(.outcome):
                shape = .pill
                isDashed = false
            default:
                shape = .card
                isDashed = lbl.status == .cancelled
            }
            let x = colX(colIdx)
            nodes.append(NodeGraphNodeModel(
                id: col.main.id,
                title: lbl.title,
                subtitle: lbl.subtitle,
                frame: GraphRect(x: x, y: mainY, width: nodeWidth, height: nodeHeight),
                shape: shape,
                tone: lbl.status.tone,
                isLive: lbl.status == .running,
                isDashed: isDashed,
                hasInputPort: colIdx > 0,
                hasOutputPort: colIdx < layout.columns.count - 1,
                deletable: false
            ))

            if colIdx > 0 {
                let prev = layout.columns[colIdx - 1].main.id
                let p0 = GraphPoint(x: colX(colIdx - 1) + nodeWidth, y: mainY + nodeHeight * 0.5)
                let p1 = GraphPoint(x: x, y: mainY + nodeHeight * 0.5)
                edges.append(NodeGraphEdgeModel(id: "seq:\(prev)->\(col.main.id)", from: prev, to: col.main.id, points: [p0, p1]))
            }

            for (rowIdx, b) in col.branch.enumerated() {
                let bLbl = labels(for: b)
                let bx = branchX(colIdx, depth: b.depth)
                let by = rowY(rowIdx)
                let h = if case .more = b { moreHeight } else { nodeHeight }
                let isErr = if case .node(.error, _) = b { true } else { false }
                let isMore = if case .more = b { true } else { false }
                nodes.append(NodeGraphNodeModel(
                    id: b.id,
                    title: bLbl.title,
                    subtitle: bLbl.subtitle,
                    frame: GraphRect(x: bx, y: by, width: nodeWidth, height: h),
                    shape: .card,
                    tone: bLbl.status.tone,
                    isLive: bLbl.status == .running,
                    isDashed: isMore || bLbl.status == .cancelled,
                    hasInputPort: true,
                    hasOutputPort: false,
                    deletable: false
                ))
                let stemX = x + 10
                let midY = by + h * 0.5
                edges.append(NodeGraphEdgeModel(
                    id: "br:\(col.main.id)->\(b.id)",
                    from: col.main.id,
                    to: b.id,
                    tone: isErr ? .blocked : .neutral,
                    isDashed: !isErr,
                    points: [
                        GraphPoint(x: stemX, y: mainY + nodeHeight),
                        GraphPoint(x: stemX, y: midY),
                        GraphPoint(x: bx, y: midY),
                    ]
                ))
            }
        }

        return NodeGraphDocument(nodes: nodes, edges: edges, selectedNodeId: selectedId)
    }

    /// Exports the laid-out run graph to an `ELKGraph` for `ELKLayoutEngine`.
    public static func toELKGraph(from layout: GraphLayout) -> ELKGraph {
        let doc = buildDocument(from: layout)
        let elkNodes = doc.nodes.map { ELKNode(id: $0.id, width: $0.frame.size.width, height: $0.frame.size.height) }
        let elkEdges = doc.edges.map { ELKEdge(id: $0.id, sources: [$0.from], targets: [$0.to]) }
        return ELKGraph(id: "run-graph", layoutOptions: ELKGraph.defaultLayeredOptions, children: elkNodes, edges: elkEdges)
    }
}
