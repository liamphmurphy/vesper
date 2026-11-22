import Foundation

// MARK: - Live Turn Activity Folding (`web/lib/chat-ui.ts`)

public struct ChatRunEvent: Sendable, Equatable {
    public var seq: Int
    public var type: String
    public var at: String
    public var payload: [String: JSONValue]

    public init(seq: Int, type: String, at: String, payload: [String: JSONValue] = [:]) {
        self.seq = seq; self.type = type; self.at = at; self.payload = payload
    }

    public init(_ event: API.RunEvent) {
        self.seq = event.seq; self.type = event.type.rawValue; self.at = event.at; self.payload = event.payload
    }
}

public struct ChatToolCall: Sendable, Equatable {
    public var key: Int
    public var tool: String
    public var input: JSONValue
    public var done: Bool
    public var output: String?
    public var failed: Bool

    public init(key: Int, tool: String, input: JSONValue = .object([:]), done: Bool = false, output: String? = nil, failed: Bool = false) {
        self.key = key; self.tool = tool; self.input = input; self.done = done; self.output = output; self.failed = failed
    }
}

public enum ChatStepState: String, Sendable, Equatable, Hashable {
    case planned, active, done, failed
}

public enum ChatIntentTag: String, Sendable, Equatable, Hashable {
    case approach, surprise
}

public struct ChatStatusInfo: Sendable, Equatable, Hashable {
    public var kind: ActivitySceneKind
    public var phrase: String

    public init(kind: ActivitySceneKind, phrase: String) {
        self.kind = kind; self.phrase = phrase
    }
}

public struct ChatTurnStep: Sendable, Equatable {
    public var key: String
    public var title: String
    public var state: ChatStepState
    public var kind: ActivitySceneKind?
    public var added: Bool
    public var detail: String?
    public var intent: String?
    public var tag: ChatIntentTag?
    public var reasoning: Bool
    public var startedAt: TimeInterval?
    public var endedAt: TimeInterval?

    public init(
        key: String, title: String, state: ChatStepState, kind: ActivitySceneKind? = nil,
        added: Bool = false, detail: String? = nil, intent: String? = nil, tag: ChatIntentTag? = nil,
        reasoning: Bool = false, startedAt: TimeInterval? = nil, endedAt: TimeInterval? = nil
    ) {
        self.key = key; self.title = title; self.state = state; self.kind = kind
        self.added = added; self.detail = detail; self.intent = intent; self.tag = tag
        self.reasoning = reasoning; self.startedAt = startedAt; self.endedAt = endedAt
    }
}

/// One answered turn's event window; `followup` marks a turn no person's message started (e.g. image reaction).
public struct ChatTurnWindow: Sendable, Equatable {
    public var since: String?
    public var until: String?
    public var followup: Bool

    public init(since: String? = nil, until: String? = nil, followup: Bool = false) {
        self.since = since
        self.until = until
        self.followup = followup
    }
}

/// How a finished turn ended: with a reply, an error, or the person stopping/interrupting it.
public enum ChatTurnOutcome: String, Sendable, Equatable, Hashable {
    case done, failed, stopped
}

/// A finished turn's folded steps and duration for its collapsed card in chat history.
public struct ChatFinishedTurn: Sendable, Equatable {
    public var steps: [ChatTurnStep]
    public var durationMs: Int?

    public init(steps: [ChatTurnStep] = [], durationMs: Int? = nil) {
        self.steps = steps
        self.durationMs = durationMs
    }
}

/// A turn that ended without a reply (failed system notice or stopped/interrupted user message).
public struct ChatEndedTurn: Sendable, Equatable {
    public var outcome: ChatTurnOutcome
    public var since: String
    public var until: String?
    public var end: TimeInterval?

    public init(outcome: ChatTurnOutcome, since: String, until: String? = nil, end: TimeInterval? = nil) {
        self.outcome = outcome
        self.since = since
        self.until = until
        self.end = end
    }
}

public struct ChatTurnActivity: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case thinking(detail: String?)
        case writingReply
    }

    public static let nextStepAfterMs = 8_000
    public static let quietAfterMs = 120_000
    public static let quietRunningMs = 300_000
    public static let replyBlockTool = "reply_block"
    public static let nextStepKey = "next-step"

    private static let bookkeeping: Set<String> = [
        "TodoWrite", "todowrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
        "ToolSearch", "Skill", "set_chat_title", "whoami",
    ]
    private static let failableKinds: Set<ActivitySceneKind> = [
        .tests, .build, .install, .commit, .push, .pullRequest, .github, .terminal, .connector, .secret, .image,
    ]

    public var status: ChatStatusInfo
    public var openingLine: String?
    public var steps: [ChatTurnStep]
    public var planned: Bool
    public var elapsedMs: Int?
    public var idleMs: Int?
    public var between: Bool
    public var quiet: Bool
    public var activePhase: Phase?

    public init(
        status: ChatStatusInfo, openingLine: String? = nil, steps: [ChatTurnStep] = [],
        planned: Bool = false, elapsedMs: Int? = nil, idleMs: Int? = nil,
        between: Bool = false, quiet: Bool = false, activePhase: Phase? = nil
    ) {
        self.status = status; self.openingLine = openingLine; self.steps = steps
        self.planned = planned; self.elapsedMs = elapsedMs; self.idleMs = idleMs
        self.between = between; self.quiet = quiet; self.activePhase = activePhase
    }

    public static func bareTool(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let afterPrefix = tool.index(tool.startIndex, offsetBy: 5)
            if let sep = tool.range(of: "__", range: afterPrefix..<tool.endIndex) {
                let server = String(tool[afterPrefix..<sep.lowerBound])
                let name = String(tool[sep.upperBound...])
                return server == "lazyagents" ? name : "\(server).\(name)"
            }
        }
        if tool.hasPrefix("lazyagents.") || tool.hasPrefix("lazyagents_") {
            return String(tool.dropFirst("lazyagents.".count))
        }
        return tool
    }

    public static func statusOf(tool rawTool: String, input: JSONValue) -> ChatStatusInfo {
        let tool = bareTool(rawTool)
        switch tool {
        case "read_page", "read_artifact", "get_backlinks", "search_knowledge", "find_pattern",
             "list_page_versions", "list_page_reviews", "knowledge_graph", "list_imports":
            return ChatStatusInfo(kind: .wiki, phrase: "looking through the wiki")
        case "write_note", "create_page", "patch_page", "capture_note", "daily_note", "set_properties", "suggest_links":
            return ChatStatusInfo(kind: .wiki, phrase: "writing a wiki note")
        case "get_ticket", "list_epics", "list_tickets", "get_epic", "claim_ticket", "next_ticket":
            return ChatStatusInfo(kind: .ticketLookup, phrase: "checking tickets")
        case "create_ticket", "create_epic", "update_ticket", "comment_ticket", "update_ticket_blockers", "update_epic":
            return ChatStatusInfo(kind: .tickets, phrase: "updating a ticket")
        case "list_runs", "get_run", "reply_to_run":
            return ChatStatusInfo(kind: .runs, phrase: "checking on runs")
        case "search_memory", "read_memory", "forget_memory":
            return ChatStatusInfo(kind: .memory, phrase: "recalling what it knows about you")
        case "save_memory", "update_memory":
            return ChatStatusInfo(kind: .memorySave, phrase: "making a note")
        case "search_chats", "read_chat":
            return ChatStatusInfo(kind: .chatHistory, phrase: "looking back through your past chats")
        case "WebSearch", "web_search", "websearch":
            return ChatStatusInfo(kind: .web, phrase: "searching the web")
        case "WebFetch", "webfetch", "browser_snapshot":
            return ChatStatusInfo(kind: .webPage, phrase: "reading a page")
        case "get_video_transcript":
            return ChatStatusInfo(kind: .video, phrase: "watching a video")
        case "generate_image", "image_generation", "image_gen":
            return ChatStatusInfo(kind: .image, phrase: "creating an image")
        case "canvas_list", "canvas_read", "canvas_create", "canvas_patch":
            return ChatStatusInfo(kind: .canvas, phrase: "working on a canvas")
        case "canvas_comment", "canvas_reply":
            return ChatStatusInfo(kind: .canvasComment, phrase: "commenting on a canvas")
        case "design_create", "design_patch", "design_comment", "design_reply":
            return ChatStatusInfo(kind: .design, phrase: "working on a design")
        case "design_list", "design_read", "design_outline", "design_flows", "design_render":
            return ChatStatusInfo(kind: .designView, phrase: "looking at a design")
        case "start_playground", "playground_status", "stop_playground", "set_playground_openapi":
            return ChatStatusInfo(kind: .playground, phrase: "working on the playground")
        case "list_workflows", "read_workflow", "propose_workflow_edit":
            return ChatStatusInfo(kind: .workflow, phrase: "working on a workflow")
        case "start_video", "update_video", "finish_video", "fail_video":
            return ChatStatusInfo(kind: .videoRender, phrase: "rendering a video")
        case "start_audio", "update_audio", "finish_audio", "fail_audio", "generate_music":
            return ChatStatusInfo(kind: .audioRender, phrase: "rendering audio")
        case "render_pdf":
            return ChatStatusInfo(kind: .pdf, phrase: "creating a PDF")
        case "Agent", "Task", "delegate", "run_subagent", "run_subagents":
            return ChatStatusInfo(kind: .subagent, phrase: "delegating to a helper")
        case "request_push":
            return ChatStatusInfo(kind: .push, phrase: "asking to push a branch")
        case "Read", "read", "read_file", "LS", "list", "list_dir":
            if let fp = input["file_path"]?.stringValue, fp.contains(".lazyagents/attachments/generated/") {
                return ChatStatusInfo(kind: .imageView, phrase: "looking at the image")
            }
            return ChatStatusInfo(kind: .readingCode, phrase: "reading the code")
        case "Glob", "glob", "Grep", "grep":
            return ChatStatusInfo(kind: .searchingCode, phrase: "searching the code")
        case "Edit", "edit", "MultiEdit", "Write", "write", "NotebookEdit", "apply_patch", "patch":
            return ChatStatusInfo(kind: .writingCode, phrase: "writing code")
        case "shell", "Bash", "bash", "exec_command", "shell_command":
            let cmd = input["command"]?.stringValue ?? input["cmd"]?.stringValue ?? ""
            return shellStatus(cmd)
        case replyBlockTool:
            return replyBlockStatus(input["kind"]?.stringValue ?? "")
        default:
            if tool.hasPrefix("vesper_secrets.") { return ChatStatusInfo(kind: .secret, phrase: "checking its secrets") }
            if tool.contains(".") { return ChatStatusInfo(kind: .connector, phrase: "using a connector") }
            return ChatStatusInfo(kind: .thinking, phrase: "working on it")
        }
    }

    // MARK: Turn Windows & History (`web/lib/chat-ui.ts`)

    /// Each turn's last assistant reply gets the window of events between the turn's start
    /// and the next one's. A turn starts at a user message, or right after an earlier turn's
    /// reply when the assistant replies again on its own (a different run turn, e.g. reacting
    /// to generated images). Mid-turn steer messages keep the active turn's window open.
    public static func turnWindows(for messages: [API.ChatMessage]) -> [String: ChatTurnWindow] {
        var out: [String: ChatTurnWindow] = [:]
        var since: String?
        var reply: API.ChatMessage?
        var followup = false

        func close(until: String?) {
            if let r = reply {
                out[r.id] = ChatTurnWindow(since: since, until: until, followup: followup)
            }
        }
        func turnKey(_ m: API.ChatMessage) -> String? {
            guard let seq = m.turnSeq else { return nil }
            return "\(m.runId ?? ""):\(seq)"
        }

        for m in messages {
            if m.role == .user {
                if reply == nil && since != nil && m.runId == nil && m.turnSeq == nil { continue }
                close(until: m.createdAt)
                since = m.createdAt
                reply = nil
                followup = false
            } else if m.role == .assistant {
                if let prev = reply, let currKey = turnKey(m), let prevKey = turnKey(prev), currKey != prevKey {
                    close(until: prev.createdAt)
                    since = prev.createdAt
                    followup = true
                }
                reply = m
            }
        }
        close(until: nil)
        return out
    }

    /// Where the running turn's events start: the newest message. That is the person's message
    /// for a turn they started (walking back over mid-turn steers), or the previous reply/note
    /// for a turn the assistant takes on its own, so earlier turns' opening line and steps
    /// aren't shown again.
    public static func runningSince(for messages: [API.ChatMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        var i = messages.count - 1
        if messages[i].role == .user {
            while i > 0 && messages[i - 1].role == .user && messages[i].runId == nil && messages[i].turnSeq == nil {
                i -= 1
            }
        }
        return messages[i].createdAt
    }

    /// Turns that ended without a reply, keyed by the message the strip attaches to. A failed
    /// turn leaves a system message with `turnSeq` (keyed by that message); a stopped or
    /// interrupted turn attaches to the unanswered user message until the next one. While
    /// `running` is true, the newest unanswered message is the live turn.
    public static func endedTurns(for messages: [API.ChatMessage], running: Bool) -> [String: ChatEndedTurn] {
        var out: [String: ChatEndedTurn] = [:]
        var open: API.ChatMessage?

        for m in messages {
            if m.role == .assistant {
                open = nil
            } else if m.role == .system && m.turnSeq != nil, let started = open {
                out[m.id] = ChatEndedTurn(
                    outcome: .failed,
                    since: started.createdAt,
                    until: m.createdAt,
                    end: APIDate.epoch(m.createdAt)
                )
                open = nil
            } else if m.role == .user {
                // Mid-turn steer messages carry no run/turn; keep the active turn open.
                if let started = open, started.runId != nil, m.runId == nil && m.turnSeq == nil {
                    continue
                }
                if let started = open {
                    out[started.id] = ChatEndedTurn(outcome: .stopped, since: started.createdAt, until: m.createdAt)
                }
                open = m
            }
        }
        if let started = open, !running {
            out[started.id] = ChatEndedTurn(outcome: .stopped, since: started.createdAt)
        }
        return out
    }

    /// Deduplicated, order-preserving run IDs referenced by finished or ended turns in `messages`.
    public static func historicalRunIds(
        for messages: [API.ChatMessage],
        turnWindows: [String: ChatTurnWindow],
        endedTurns: [String: ChatEndedTurn]
    ) -> [String] {
        var seen: Set<String> = []
        var ids: [String] = []
        for m in messages {
            guard turnWindows[m.id] != nil || endedTurns[m.id] != nil,
                  let runId = m.runId, !runId.isEmpty,
                  seen.insert(runId).inserted else { continue }
            ids.append(runId)
        }
        return ids
    }

    public static func fold(events: [ChatRunEvent], since: String? = nil, until: String? = nil, now: Date = Date()) -> ChatTurnActivity {
        let minEpoch = since.map(APIDate.epoch) ?? 0
        let parsed = parseEventWindow(events: events, since: since, until: until)

        let started = since != nil ? minEpoch : parsed.firstAt
        let nowEpoch = now.timeIntervalSince1970
        let elapsedMs = started.map { max(0, Int((nowEpoch - $0) * 1000)) }
        let lastEvent = parsed.lastAt ?? started
        let idleMs = lastEvent.map { max(0, Int((nowEpoch - $0) * 1000)) }
        let newest = parsed.calls.last
        let doneAt: TimeInterval? = {
            guard let newest, newest.done, newest.tool != replyBlockTool else { return nil }
            return parsed.callTimes[newest.key]?.doneAt
        }()
        let between = doneAt.map { Int((nowEpoch - $0) * 1000) >= nextStepAfterMs } ?? false
        let quietThreshold = (newest != nil && newest?.done == false) ? quietRunningMs : quietAfterMs
        let quiet = idleMs.map { $0 >= quietThreshold } ?? false

        let status = computeStatus(calls: parsed.calls, between: between, phase: parsed.activePhase)
        let (steps, planned) = buildSteps(calls: parsed.calls, callTimes: parsed.callTimes, between: between, phase: parsed.activePhase)

        return ChatTurnActivity(
            status: status,
            openingLine: parsed.openingLine,
            steps: steps,
            planned: planned,
            elapsedMs: elapsedMs,
            idleMs: idleMs,
            between: between,
            quiet: quiet,
            activePhase: parsed.activePhase
        )
    }

    /// A finished turn's steps for the strip kept in chat history above its reply (or under a
    /// stopped/failed turn). Plain replies with only bookkeeping/reply blocks return empty steps.
    public static func finishedTurn(
        events: [ChatRunEvent],
        outcome: ChatTurnOutcome,
        since: String? = nil,
        until: String? = nil,
        end: TimeInterval? = nil
    ) -> ChatFinishedTurn {
        let minEpoch = since.map(APIDate.epoch) ?? 0
        let parsed = parseEventWindow(events: events, since: since, until: until)
        guard parsed.calls.contains(where: { $0.tool != replyBlockTool && !bookkeeping.contains(bareTool($0.tool)) }) else {
            return ChatFinishedTurn()
        }
        var (steps, _) = buildSteps(calls: parsed.calls, callTimes: parsed.callTimes, between: false, phase: nil)
        for idx in steps.indices where steps[idx].state == .active {
            steps[idx].state = outcome == .failed ? .failed : .done
        }
        let started = since != nil ? minEpoch : parsed.firstAt
        let last = end ?? parsed.lastAt
        let durationMs = (started != nil && last != nil) ? max(0, Int((last! - started!) * 1000)) : nil
        return ChatFinishedTurn(steps: steps, durationMs: durationMs)
    }

    public static func foldSteps(_ steps: [ChatTurnStep]) -> (earlier: Int, shown: [ChatTurnStep], later: Int) {
        let doneKeys = steps.filter { $0.state == .done }.map(\.key)
        let hiddenDone = Set(doneKeys.count > 3 ? Array(doneKeys.dropLast(2)) : [])
        let plannedKeys = steps.filter { $0.state == .planned }.map(\.key)
        let hiddenPlanned = Set(plannedKeys.count > 4 ? Array(plannedKeys.dropFirst(4)) : [])
        let hidden = hiddenDone.union(hiddenPlanned)
        return (
            earlier: doneKeys.count > 3 ? doneKeys.count - 2 : 0,
            shown: steps.filter { !hidden.contains($0.key) },
            later: max(0, plannedKeys.count - 4)
        )
    }

    /// A failed turn opens on where it failed: steps before the first failure fold into a count.
    public static func foldStepsFromFailure(_ steps: [ChatTurnStep]) -> (earlier: Int, shown: [ChatTurnStep]) {
        let at = steps.firstIndex(where: { $0.state == .failed }) ?? 0
        return (earlier: at, shown: Array(steps.dropFirst(at)))
    }

    /// Summary line for a finished working card ("Worked for 2m 14s · 7 steps").
    public static func finishedSummary(outcome: ChatTurnOutcome, stepCount: Int, durationMs: Int?) -> String {
        let verb: String
        switch outcome {
        case .done: verb = "Worked for"
        case .failed: verb = "Failed after"
        case .stopped: verb = "Stopped after"
        }
        let lead: String
        if let durationMs, durationMs >= 1000 {
            lead = "\(verb) \(formatSpan(ms: durationMs))"
        } else {
            lead = String(verb.split(separator: " ").first ?? Substring(verb))
        }
        let noun = stepCount == 1 ? "step" : "steps"
        return "\(lead) · \(stepCount) \(noun)"
    }

    public static func formatSpan(ms: Int) -> String {
        let s = max(0, ms) / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m \(String(format: "%02d", s % 60))s" }
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    public static func replyCost(_ cost: Double?) -> String? {
        guard let cost, cost.isFinite, cost > 0 else { return nil }
        if cost < 0.001 { return "< $0.001" }
        return cost < 1 ? String(format: "$%.3f", cost) : String(format: "$%.2f", cost)
    }

    // MARK: Private Activity Helpers

    private struct ParsedEventWindow {
        var calls: [ChatToolCall]
        var callTimes: [Int: (at: TimeInterval, doneAt: TimeInterval?)]
        var firstAt: TimeInterval?
        var lastAt: TimeInterval?
        var openingLine: String?
        var activePhase: Phase?
    }

    private static func parseEventWindow(events: [ChatRunEvent], since: String?, until: String?) -> ParsedEventWindow {
        let minEpoch = since.map(APIDate.epoch) ?? 0
        let maxEpoch = until.map(APIDate.epoch) ?? Double.infinity

        var calls: [ChatToolCall] = []
        var openCalls: [String: Int] = [:]
        var callTimes: [Int: (at: TimeInterval, doneAt: TimeInterval?)] = [:]
        var firstAt: TimeInterval?
        var lastAt: TimeInterval?
        var firstAssistantText: String?
        var openingLine: String?
        var activePhase: Phase?

        for e in events {
            let at = APIDate.epoch(e.at)
            if at < minEpoch || at > maxEpoch { continue }
            if firstAt == nil { firstAt = at }
            lastAt = max(lastAt ?? at, at)
            if case .bool(true) = e.payload["subagent"] { continue }

            switch e.type {
            case "tool_call":
                activePhase = nil
                if let text = firstAssistantText, openingLine == nil {
                    openingLine = String(text.prefix(280))
                }
                let id = e.payload["id"]?.stringValue ?? ""
                let tool = e.payload["tool"]?.stringValue ?? ""
                let input = e.payload["input"] ?? .object([:])
                if !id.isEmpty { openCalls[id] = calls.count }
                calls.append(ChatToolCall(key: e.seq, tool: tool, input: input, done: false))
                callTimes[e.seq] = (at, nil)

            case "tool_result":
                activePhase = nil
                if let id = e.payload["id"]?.stringValue, let idx = openCalls[id] {
                    calls[idx].done = true
                    calls[idx].output = e.payload["output"]?.stringValue
                    if case .bool(true) = e.payload["is_error"] { calls[idx].failed = true }
                    if var times = callTimes[calls[idx].key] {
                        times.doneAt = at
                        callTimes[calls[idx].key] = times
                    }
                }

            case "lifecycle":
                let state = e.payload["state"]?.stringValue ?? ""
                if state == replyBlockTool {
                    activePhase = nil
                    let kind = e.payload["kind"]?.stringValue ?? ""
                    calls.append(ChatToolCall(key: e.seq, tool: replyBlockTool, input: .object(["kind": .string(kind)]), done: true))
                    callTimes[e.seq] = (at, at)
                } else if state == "activity" {
                    let phase = e.payload["phase"]?.stringValue ?? ""
                    if phase == "thinking" {
                        let detail = e.payload["detail"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                        activePhase = .thinking(detail: (detail?.isEmpty == false) ? detail : nil)
                    } else if phase == "writing_reply" {
                        activePhase = .writingReply
                    }
                }

            case "message":
                let kind = e.payload["kind"]?.stringValue ?? ""
                let role = e.payload["role"]?.stringValue ?? ""
                let text = e.payload["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if kind == "thinking" {
                    activePhase = .thinking(detail: nil)
                } else if role == "assistant" && kind.isEmpty {
                    activePhase = nil
                    if firstAssistantText == nil && !text.isEmpty {
                        firstAssistantText = text
                    }
                }

            default:
                break
            }
        }

        return ParsedEventWindow(
            calls: calls,
            callTimes: callTimes,
            firstAt: firstAt,
            lastAt: lastAt,
            openingLine: openingLine,
            activePhase: activePhase
        )
    }

    private static func computeStatus(calls: [ChatToolCall], between: Bool, phase: Phase?) -> ChatStatusInfo {
        if let newest = calls.last {
            if newest.tool == replyBlockTool || !newest.done {
                return statusOf(tool: newest.tool, input: newest.input)
            }
        }
        if case .writingReply = phase { return ChatStatusInfo(kind: .writingReply, phrase: "drafting a reply") }
        guard let newest = calls.last else { return ChatStatusInfo(kind: .thinking, phrase: "thinking") }
        if between { return ChatStatusInfo(kind: .nextStep, phrase: "planning the next step") }
        return statusOf(tool: newest.tool, input: newest.input)
    }

    private static func buildSteps(
        calls: [ChatToolCall],
        callTimes: [Int: (at: TimeInterval, doneAt: TimeInterval?)],
        between: Bool,
        phase: Phase?
    ) -> ([ChatTurnStep], Bool) {
        // Check for TodoWrite plan first.
        if let latestTodos = calls.last(where: { bareTool($0.tool).lowercased() == "todowrite" }),
           case .array(let items) = latestTodos.input["todos"] {
            var steps: [ChatTurnStep] = []
            for (idx, item) in items.enumerated() {
                let title = item["content"]?.stringValue ?? ""
                let rawState = item["status"]?.stringValue ?? ""
                guard !title.isEmpty, rawState != "cancelled" else { continue }
                let state: ChatStepState = rawState == "completed" ? .done : rawState == "in_progress" ? .active : .planned
                steps.append(ChatTurnStep(key: "\(title)#\(idx)", title: title, state: state))
            }
            if !steps.isEmpty { return (steps, true) }
        }

        // Planless: coalesce consecutive calls with the same phrase.
        var steps: [ChatTurnStep] = []
        var lastPhrase: String?
        for call in calls {
            if bookkeeping.contains(bareTool(call.tool)) { continue }
            let info = statusOf(tool: call.tool, input: call.input)
            let isFailed = call.failed && failableKinds.contains(info.kind)
            let t = callTimes[call.key]
            if info.phrase == lastPhrase, !steps.isEmpty {
                steps[steps.count - 1].state = isFailed ? .failed : .done
                if let done = t?.doneAt ?? t?.at { steps[steps.count - 1].endedAt = done }
                continue
            }
            lastPhrase = info.phrase
            let title = info.phrase.prefix(1).uppercased() + info.phrase.dropFirst()
            steps.append(ChatTurnStep(
                key: String(call.key),
                title: title,
                state: isFailed ? .failed : .done,
                kind: info.kind,
                startedAt: t?.at,
                endedAt: t?.doneAt ?? t?.at
            ))
        }
        guard !steps.isEmpty else {
            if case .writingReply = phase {
                return ([ChatTurnStep(key: nextStepKey, title: "Drafting a reply", state: .active, kind: .writingReply)], false)
            }
            if case .thinking(let detail) = phase, let detail, !detail.isEmpty {
                return ([ChatTurnStep(key: nextStepKey, title: "Thinking", state: .active, kind: .thinking, detail: detail)], false)
            }
            return ([], false)
        }
        let newestFinished = steps[steps.count - 1].state
        steps[steps.count - 1].state = .active
        let lastCallRunning = calls.last.map { !$0.done } ?? false
        if !lastCallRunning && (between || phase != nil) {
            steps[steps.count - 1].state = newestFinished
            if case .writingReply = phase {
                steps.append(ChatTurnStep(key: nextStepKey, title: "Drafting a reply", state: .active, kind: .writingReply))
            } else {
                var detail: String?
                if case .thinking(let d) = phase { detail = d }
                steps.append(ChatTurnStep(key: nextStepKey, title: "Planning the next step", state: .active, kind: .nextStep, detail: detail))
            }
        }
        return (steps, false)
    }

    private static func shellStatus(_ command: String) -> ChatStatusInfo {
        let c = command.lowercased()
        if c.contains(".lazyagents/outbox") { return ChatStatusInfo(kind: .image, phrase: "saving the image") }
        if c.contains("git ") && c.contains(" push") { return ChatStatusInfo(kind: .push, phrase: "pushing its branch") }
        if c.contains("git ") && c.contains(" commit") { return ChatStatusInfo(kind: .commit, phrase: "committing changes") }
        if c.contains("gh pr") { return ChatStatusInfo(kind: .pullRequest, phrase: "preparing a pull request") }
        if c.contains("go test") || c.contains("npm test") || c.contains("npm run test") || c.contains("pytest") || c.contains("cargo test") || c.contains("swift test") {
            return ChatStatusInfo(kind: .tests, phrase: "running tests")
        }
        if c.contains("npm ci") || c.contains("npm install") || c.contains("pip install") {
            return ChatStatusInfo(kind: .install, phrase: "installing dependencies")
        }
        if c.contains("go build") || c.contains("go vet") || c.contains("npm run build") || c.contains("cargo build") || c.contains("swift build") {
            return ChatStatusInfo(kind: .build, phrase: "checking the build")
        }
        if c.contains("git ") { return ChatStatusInfo(kind: .repoHistory, phrase: "looking over the repository") }
        if c.hasPrefix("rg ") || c.hasPrefix("grep ") || c.hasPrefix("find ") {
            return ChatStatusInfo(kind: .searchingCode, phrase: "searching the code")
        }
        return ChatStatusInfo(kind: .terminal, phrase: "working in the terminal")
    }

    private static func replyBlockStatus(_ kind: String) -> ChatStatusInfo {
        switch kind {
        case "app": return ChatStatusInfo(kind: .app, phrase: "building an interactive app")
        case "svg-image": return ChatStatusInfo(kind: .image, phrase: "drawing an image")
        case "svg-steps": return ChatStatusInfo(kind: .image, phrase: "drawing a step-through")
        case "chart": return ChatStatusInfo(kind: .chart, phrase: "drawing a chart")
        case "mermaid": return ChatStatusInfo(kind: .diagram, phrase: "drawing a diagram")
        case "choices": return ChatStatusInfo(kind: .choices, phrase: "laying out your options")
        case "workflow-run": return ChatStatusInfo(kind: .workflow, phrase: "lining up a workflow")
        case "recommend": return ChatStatusInfo(kind: .web, phrase: "picking something for you to look at")
        case "pdf": return ChatStatusInfo(kind: .pdf, phrase: "attaching a PDF")
        default: return ChatStatusInfo(kind: .thinking, phrase: "working on it")
        }
    }
}
