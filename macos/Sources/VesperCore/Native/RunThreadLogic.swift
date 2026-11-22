import Foundation

/// Folds `API.RunDetail` and `API.RunEvent` streams into structured Thread turns, live activity scenes,
/// paired tool calls, subagent groups, and filtered Trace turn groups. Foundation-only for iOS portability.
public enum RunThreadLogic {
    // MARK: - JSON Helpers

    public static func jsonString(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return d.isFinite ? String(d) : ""
        case .bool(let b): return b ? "true" : "false"
        case .array, .object: return compactJSON(value)
        }
    }

    public static func jsonInt(_ value: JSONValue?) -> Int? {
        RunsLogic.jsonInt(value)
    }

    public static func jsonBool(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if case .bool(let b) = value { return b }
        return false
    }

    public static func jsonObject(_ value: JSONValue?) -> [String: JSONValue] {
        guard let value, case .object(let dict) = value else { return [:] }
        return dict
    }

    public static func jsonArray(_ value: JSONValue?) -> [JSONValue] {
        guard let value, case .array(let arr) = value else { return [] }
        return arr
    }

    public static func compactJSON(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d.isFinite ? String(d) : "null"
        case .string(let s):
            if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
               let arr = String(data: data, encoding: .utf8),
               arr.count >= 2 {
                return String(arr.dropFirst().dropLast())
            }
            return "\"\(s)\""
        case .array, .object:
            let obj = toFoundationObject(value)
            if JSONSerialization.isValidJSONObject(obj),
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "{}"
        }
    }

    public static func prettyJSON(_ payload: [String: JSONValue]) -> String {
        prettyJSON(.object(payload))
    }

    public static func prettyJSON(_ value: JSONValue) -> String {
        switch value {
        case .array, .object:
            let obj = toFoundationObject(value)
            if JSONSerialization.isValidJSONObject(obj),
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return compactJSON(value)
        default:
            return compactJSON(value)
        }
    }

    private static func toFoundationObject(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d.isFinite ? d : NSNull()
        case .string(let s): return s
        case .array(let items): return items.map(toFoundationObject)
        case .object(let dict): return dict.mapValues(toFoundationObject)
        }
    }

    // MARK: - Tool Formatting & Delegation

    /// `"lazyagents.claim_ticket"` for `mcp__lazyagents__claim_ticket`, else raw name.
    public static func toolName(_ raw: String) -> String {
        guard raw.hasPrefix("mcp__") else { return raw }
        let rest = raw.dropFirst(5)
        guard let sep = rest.range(of: "__") else { return raw }
        let server = rest[..<sep.lowerBound]
        let tool = rest[sep.upperBound...]
        guard !server.isEmpty, !tool.isEmpty else { return raw }
        return "\(server).\(tool)"
    }

    /// `"mcp__lazyagents__read_page"` -> `"read_page"`; `"mcp__github__get_issue"` -> `"github.get_issue"`.
    public static func bareTool(_ raw: String) -> String {
        if raw.hasPrefix("mcp__") {
            let rest = raw.dropFirst(5)
            if let sep = rest.range(of: "__") {
                let server = String(rest[..<sep.lowerBound])
                let tool = String(rest[sep.upperBound...])
                if !server.isEmpty && !tool.isEmpty {
                    return server == "lazyagents" ? tool : "\(server).\(tool)"
                }
            }
        }
        if raw.hasPrefix("lazyagents.") || raw.hasPrefix("lazyagents_") {
            return String(raw.dropFirst("lazyagents.".count))
        }
        return raw
    }

    /// Compact argument summary: command, file_path, or `(k: "v", ...)`.
    public static func argSummary(_ input: JSONValue?) -> String {
        let obj = jsonObject(input)
        guard !obj.isEmpty else { return "" }
        if let cmd = obj["command"]?.stringValue { return cmd }
        if let path = obj["file_path"]?.stringValue { return path }
        let sortedKeys = obj.keys.sorted()
        let parts = sortedKeys.prefix(3).compactMap { key -> String? in
            guard let val = obj[key] else { return nil }
            let rendered: String
            switch val {
            case .string(let s):
                let clipped = s.count > 40 ? String(s.prefix(40)) + "…" : s
                rendered = compactJSON(.string(clipped))
            case .array(let arr):
                rendered = "[\(arr.count)]"
            default:
                rendered = compactJSON(val)
            }
            return "\(key): \(rendered)"
        }
        return "(\(parts.joined(separator: ", "))\(sortedKeys.count > 3 ? ", …" : ""))"
    }

    public struct ToolLink: Sendable, Equatable {
        public var href: String
        public var label: String

        public init(href: String, label: String) {
            self.href = href
            self.label = label
        }
    }

    public static func toolLink(tool: String, input: JSONValue?) -> ToolLink? {
        let obj = jsonObject(input)
        let name = toolName(tool)
        if name == "lazyagents.read_page", let ref = obj["ref"]?.stringValue, !ref.isEmpty {
            let encoded = ref.split(separator: "/", omittingEmptySubsequences: false)
                .map { MarkdownSource.encodeURIComponent(String($0)) }
                .joined(separator: "/")
            return ToolLink(href: "/wiki/\(encoded)", label: ref)
        }
        if name == "lazyagents.read_artifact", let artifact = obj["artifact"]?.stringValue, !artifact.isEmpty {
            return ToolLink(href: "/artifacts/\(MarkdownSource.encodeURIComponent(artifact))", label: artifact)
        }
        return nil
    }

    /// Matches a `lazyagents.delegate` call to the closest child run with that handle started after the call.
    public static func delegateChild(
        for call: API.RunEvent,
        children: [API.Run],
        allCalls: [API.RunEvent]
    ) -> API.Run? {
        guard toolName(call.payload["tool"]?.stringValue ?? "") == "lazyagents.delegate" else { return nil }
        let rawAgent = call.payload["input"]?["agent"]?.stringValue ?? ""
        let handle = rawAgent.hasPrefix("@") ? String(rawAgent.dropFirst()) : rawAgent
        guard !handle.isEmpty else { return nil }

        var used = Set<String>()
        for prior in allCalls.sorted(by: { $0.seq < $1.seq }) {
            if prior.seq >= call.seq { break }
            if let matched = matchDelegateSingle(call: prior, children: children.filter { !used.contains($0.id) }) {
                used.insert(matched.id)
            }
        }
        return matchDelegateSingle(call: call, children: children.filter { !used.contains($0.id) })
    }

    private static func matchDelegateSingle(call: API.RunEvent, children: [API.Run]) -> API.Run? {
        guard toolName(call.payload["tool"]?.stringValue ?? "") == "lazyagents.delegate" else { return nil }
        let rawAgent = call.payload["input"]?["agent"]?.stringValue ?? ""
        let handle = rawAgent.hasPrefix("@") ? String(rawAgent.dropFirst()) : rawAgent
        guard !handle.isEmpty else { return nil }
        let callAt = APIDate.epoch(call.at)
        return children
            .filter { $0.agent.handle == handle && APIDate.epoch($0.startedAt) >= callAt - 1.0 }
            .sorted { APIDate.epoch($0.startedAt) < APIDate.epoch($1.startedAt) }
            .first
    }

    // MARK: - Activity Scene Mapping (`web/lib/chat-ui.ts`)

    public struct ActivityStatus: Sendable, Equatable {
        public var kind: ActivitySceneKind
        public var phrase: String
        public var detail: String?

        public init(kind: ActivitySceneKind, phrase: String, detail: String? = nil) {
            self.kind = kind
            self.phrase = phrase
            self.detail = detail
        }
    }

    public static func activityKind(forTool tool: String, input: JSONValue? = nil) -> ActivityStatus {
        let obj = jsonObject(input)
        let bare = bareTool(tool)
        switch bare {
        case "read_page", "read_artifact", "get_backlinks", "search_knowledge", "find_pattern",
             "list_page_versions", "list_page_reviews", "knowledge_graph", "list_imports":
            return ActivityStatus(kind: .wiki, phrase: "looking through the wiki")
        case "librarian_pass", "daily_note", "import_vault", "list_pages", "page_outline",
             "patch_page", "set_properties", "create_page", "capture_note", "suggest_links",
             "write_note", "create_artifact", "propose_pattern", "list_proposed_patterns",
             "publish_pattern", "reject_pattern":
            return ActivityStatus(kind: .wiki, phrase: "writing a wiki note")
        case "move_page", "move_folder":
            return ActivityStatus(kind: .wiki, phrase: "moving pages")
        case "delete_page", "delete_folder":
            return ActivityStatus(kind: .wiki, phrase: "deleting pages")
        case "file_capture":
            return ActivityStatus(kind: .wiki, phrase: "filing a note")
        case "restore_page_version":
            return ActivityStatus(kind: .wiki, phrase: "restoring an earlier version")
        case "attach_file":
            return ActivityStatus(kind: .wiki, phrase: "attaching a file")
        case "withdraw_suggestion":
            return ActivityStatus(kind: .wiki, phrase: "withdrawing a suggestion")
        case "set_page_controls":
            return ActivityStatus(kind: .wiki, phrase: "changing a page's settings")
        case "attach_chat_to_page", "promote_canvas":
            return ActivityStatus(kind: .wiki, phrase: "saving to Knowledge")
        case "confirm_import", "cancel_import", "undo_import":
            return ActivityStatus(kind: .wiki, phrase: "working on a vault import")
        case "get_ticket", "list_epics", "list_tickets", "get_epic", "claim_ticket", "next_ticket":
            return ActivityStatus(kind: .ticketLookup, phrase: "checking tickets")
        case "list_projects":
            return ActivityStatus(kind: .projects, phrase: "looking over your projects")
        case "create_ticket", "create_epic":
            return ActivityStatus(kind: .tickets, phrase: "drafting a ticket")
        case "update_ticket", "comment_ticket", "update_ticket_blockers", "update_epic",
             "estimate_ticket", "propose_tickets", "comment", "check_criterion", "check_epic_criterion":
            return ActivityStatus(kind: .tickets, phrase: "updating ticket progress")
        case "list_runs", "get_run", "get_prior_attempts":
            return ActivityStatus(kind: .runs, phrase: "checking on runs")
        case "reply_to_run":
            return ActivityStatus(kind: .runs, phrase: "replying to a run")
        case "search_memory", "read_memory", "forget_memory":
            return ActivityStatus(kind: .memory, phrase: "recalling what it knows")
        case "save_memory", "update_memory":
            return ActivityStatus(kind: .memorySave, phrase: "making a note")
        case "search_chats", "read_chat":
            return ActivityStatus(kind: .chatHistory, phrase: "looking back through past chats")
        case "set_chat_title", "TodoWrite", "todowrite", "TaskCreate", "TaskUpdate":
            return ActivityStatus(kind: .thinking, phrase: "planning its next steps")
        case "WebSearch", "web_search", "websearch":
            return ActivityStatus(kind: .web, phrase: "searching the web")
        case "WebFetch", "webfetch", "browser_snapshot":
            return ActivityStatus(kind: .webPage, phrase: "reading a web page")
        case "list_saved_links", "save_link":
            return ActivityStatus(kind: .savedLinks, phrase: "checking saved links")
        case "search_library", "save_file", "read_library_item":
            return ActivityStatus(kind: .library, phrase: "working with Library")
        case "render_pdf":
            return ActivityStatus(kind: .pdf, phrase: "creating a PDF")
        case "list_inbox":
            return ActivityStatus(kind: .inbox, phrase: "checking what needs you")
        case "propose_persona", "propose_persona_character":
            return ActivityStatus(kind: .persona, phrase: "working on a persona")
        case "create_space":
            return ActivityStatus(kind: .space, phrase: "setting up a space")
        case "create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task":
            return ActivityStatus(kind: .schedule, phrase: "working on scheduled tasks")
        case "create_learning_module", "list_learning_modules", "get_learning_progress",
             "submit_outline", "submit_lesson", "submit_review":
            return ActivityStatus(kind: .learning, phrase: "working on a learning module")
        case "submit_research_report", "submit_findings":
            return ActivityStatus(kind: .research, phrase: "writing up research")
        case "search_repositories":
            return ActivityStatus(kind: .repoSearch, phrase: "looking for a repository")
        case "use_repository":
            return ActivityStatus(kind: .repoAttach, phrase: "checking out a repository")
        case "request_push":
            return ActivityStatus(kind: .push, phrase: "asking to push a branch")
        case "start_video", "update_video", "finish_video", "fail_video":
            return ActivityStatus(kind: .videoRender, phrase: "rendering a video")
        case "start_audio", "generate_music", "update_audio", "finish_audio", "fail_audio":
            return ActivityStatus(kind: .audioRender, phrase: "rendering audio")
        case "get_video_transcript":
            return ActivityStatus(kind: .video, phrase: "watching a video")
        case "canvas_list", "canvas_read", "canvas_create", "canvas_patch":
            return ActivityStatus(kind: .canvas, phrase: "working on a canvas")
        case "canvas_comment", "canvas_reply":
            return ActivityStatus(kind: .canvasComment, phrase: "commenting on a canvas")
        case "design_flows", "design_list", "design_outline", "design_read", "design_render",
             "design_comments", "design_components", "design_tokens", "design_inspect":
            return ActivityStatus(kind: .designView, phrase: "looking at a design")
        case "design_create", "design_link_ticket", "design_patch", "design_import",
             "design_comment", "design_reply", "create_mockup":
            return ActivityStatus(kind: .design, phrase: "working on a design")
        case "start_playground", "playground_status", "stop_playground", "set_playground_openapi":
            return ActivityStatus(kind: .playground, phrase: "working with the playground")
        case "propose_connector", "list_connectors":
            return ActivityStatus(kind: .connector, phrase: "checking connectors")
        case "propose_secret", "list_secret_names", "run_gated":
            return ActivityStatus(kind: .secret, phrase: "checking secrets")
        case "list_workflows", "read_workflow", "submit_workflow_output", "propose_workflow_edit":
            return ActivityStatus(kind: .workflow, phrase: "working on a workflow")
        case "list_custom_apps", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app":
            return ActivityStatus(kind: .customApp, phrase: "working on a custom app")
        case "custom_app_sql":
            return ActivityStatus(kind: .database, phrase: "querying app data")
        case "http_list_workspaces", "http_get_workspace", "http_save_request", "http_run_request":
            return ActivityStatus(kind: .http, phrase: "working with HTTP requests")
        case "Agent", "Task", "delegate", "run_subagent", "run_subagents":
            return ActivityStatus(kind: .subagent, phrase: "delegating to a helper")
        case "post_plan", "update_step":
            return ActivityStatus(kind: .nextStep, phrase: "updating its plan")
        case "set_branch":
            return ActivityStatus(kind: .repoHistory, phrase: "updating the branch")
        case "set_pr", "recheck_review":
            return ActivityStatus(kind: .pullRequest, phrase: "updating the pull request")
        case "request_approval", "wait_for_approval", "await_human", "await_signal":
            return ActivityStatus(kind: .inbox, phrase: "waiting on you")
        case "image_generation", "image_gen", "generate_image":
            return ActivityStatus(kind: .image, phrase: "creating an image")
        case "Read", "read", "read_file", "LS", "list", "list_dir":
            if let fp = obj["file_path"]?.stringValue, fp.contains(".lazyagents/attachments/generated/") {
                return ActivityStatus(kind: .imageView, phrase: "looking at the image")
            }
            return ActivityStatus(kind: .readingCode, phrase: "reading the code")
        case "Glob", "glob", "Grep", "grep":
            return ActivityStatus(kind: .searchingCode, phrase: "searching the code")
        case "Edit", "edit", "MultiEdit", "Write", "write", "NotebookEdit", "apply_patch", "patch":
            return ActivityStatus(kind: .writingCode, phrase: "writing code")
        case "shell", "Bash", "bash", "exec_command", "shell_command":
            let cmd = obj["command"]?.stringValue ?? obj["cmd"]?.stringValue ?? ""
            return shellStatus(cmd)
        default:
            let lower = bare.lowercased()
            if lower.contains("github") {
                if lower.contains("pull_request") || lower.contains("pullrequest") {
                    return ActivityStatus(kind: .pullRequest, phrase: "preparing a pull request")
                }
                return ActivityStatus(kind: .github, phrase: "working on GitHub")
            }
            return ActivityStatus(kind: .thinking, phrase: "working on it")
        }
    }

    private static func shellStatus(_ rawCommand: String) -> ActivityStatus {
        var c = rawCommand.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = c.range(of: #"^(\S*\/)?(ba|z)?sh\s+-l?c\s+['"]?"#, options: .regularExpression) {
            c.removeSubrange(range)
        }
        if c.contains(".lazyagents/outbox") { return ActivityStatus(kind: .image, phrase: "saving the image") }
        if matchesRegex(#"\bgit(?:\s+-c\s+\S+|\s+--\S+)*\s+push\b"#, in: c) {
            return ActivityStatus(kind: .push, phrase: "pushing its branch")
        }
        if matchesRegex(#"\bgit(?:\s+-c\s+\S+|\s+--\S+)*\s+commit\b"#, in: c) {
            return ActivityStatus(kind: .commit, phrase: "committing changes")
        }
        if matchesRegex(#"\bgh\s+pr\b"#, in: c) {
            return ActivityStatus(kind: .pullRequest, phrase: "preparing a pull request")
        }
        if matchesRegex(#"\bgh\s+\S"#, in: c) {
            return ActivityStatus(kind: .github, phrase: "working on GitHub")
        }
        if matchesRegex(#"\b(go\s+test|npm\s+(run\s+)?test|pnpm\s+(run\s+)?test|yarn\s+test|pytest|jest|vitest|cargo\s+test|make\s+test|rspec|playwright\s+test|mvn\s+test|gradle\w*\s+test|swift\s+test)\b"#, in: c) {
            return ActivityStatus(kind: .tests, phrase: "running tests")
        }
        if matchesRegex(#"\b(npm\s+(ci|install|i)|pnpm\s+install|yarn(\s+install)?\s*$|go\s+mod\s+(download|tidy)|pip\s+install|bundle\s+install|cargo\s+fetch)\b"#, in: c) {
            return ActivityStatus(kind: .install, phrase: "installing dependencies")
        }
        if matchesRegex(#"\b(go\s+(build|vet)|npm\s+run\s+(build|lint|typecheck)|tsc\b|cargo\s+(build|check|clippy)|make\b|eslint|gofmt|swift\s+build)\b"#, in: c) {
            return ActivityStatus(kind: .build, phrase: "checking the build")
        }
        if matchesRegex(#"\bgit(?:\s+-c\s+\S+|\s+--\S+)*\s+(add|am|apply|blame|branch|checkout|cherry-pick|clone|diff|fetch|init|log|ls-files|merge|merge-base|pull|rebase|remote|reset|restore|rev-list|rev-parse|revert|rm|show|stash|status|submodule|switch|tag|worktree)\b"#, in: c) {
            return ActivityStatus(kind: .repoHistory, phrase: "looking over the repository")
        }
        if matchesRegex(#"^\s*(find|rg|grep|fd)\b|\|\s*(rg|grep)\b"#, in: c) {
            return ActivityStatus(kind: .searchingCode, phrase: "searching the code")
        }
        if matchesRegex(#"^\s*(cat|less|head|tail|ls|tree|sed\s+-n|wc|awk)\b|\|\s*(head|tail)\b"#, in: c) {
            return ActivityStatus(kind: .readingCode, phrase: "reading the code")
        }
        return ActivityStatus(kind: .terminal, phrase: "working in the terminal")
    }

    private static func matchesRegex(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    public static func liveActivity(events: [API.RunEvent], run: API.Run) -> ActivityStatus {
        if run.state == .waiting || run.state == .paused {
            if run.waitReason == .delegation {
                return ActivityStatus(kind: .subagent, phrase: "waiting for sub agents")
            }
            return ActivityStatus(kind: .inbox, phrase: "waiting on you")
        }
        if run.state == .queued || run.state == .starting {
            return ActivityStatus(kind: .thinking, phrase: run.state == .queued ? "queued" : "starting")
        }
        let paired = pairRows(events, runId: run.id)
        let toolCalls = paired.compactMap { row -> PairedToolCall? in
            if case .tool(let t) = row { return t }
            return nil
        }
        if let newest = toolCalls.last {
            if newest.isRunning {
                return activityKind(forTool: newest.call.payload["tool"]?.stringValue ?? "", input: newest.input)
            }
        }
        // Check trailing activity or thinking event after the last tool event.
        for event in events.sorted(by: { $0.seq < $1.seq }).reversed() {
            if event.type == .toolCall || event.type == .toolResult { break }
            if event.type == .lifecycle, event.payload["state"]?.stringValue == "activity" {
                let phase = event.payload["phase"]?.stringValue ?? ""
                let detail = event.payload["detail"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                if phase == "writing_reply" {
                    return ActivityStatus(kind: .writingReply, phrase: "drafting a reply")
                }
                if phase == "thinking" {
                    return ActivityStatus(kind: .thinking, phrase: "thinking", detail: detail?.isEmpty == false ? detail : nil)
                }
            }
            if event.type == .message, event.payload["kind"]?.stringValue == "thinking" {
                let heading = thinkingHeading(event.payload["text"]?.stringValue ?? "")
                return ActivityStatus(kind: .thinking, phrase: "thinking", detail: heading)
            }
            if event.type == .message, event.payload["kind"] == nil {
                break
            }
        }
        if let newest = toolCalls.last {
            return activityKind(forTool: newest.call.payload["tool"]?.stringValue ?? "", input: newest.input)
        }
        return ActivityStatus(kind: .thinking, phrase: "thinking")
    }

    static func thinkingHeading(_ text: String) -> String? {
        var latest: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            var candidate = ""
            if s.hasPrefix("**") && s.hasSuffix("**") && s.count > 4 {
                let inner = String(s.dropFirst(2).dropLast(2))
                if inner.contains("**") { continue }
                candidate = inner
            } else if let range = s.range(of: #"^#{1,3}[ \t]+(.+)$"#, options: .regularExpression) {
                let line = String(s[range])
                candidate = line.replacingOccurrences(of: #"^#{1,3}[ \t]+"#, with: "", options: .regularExpression)
            } else {
                continue
            }
            candidate = candidate
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":."))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.count >= 3, candidate.count <= 90 else { continue }
            if candidate.contains("://") || candidate.contains("=") || matchesRegex(#"\/(?:Users|home|etc|var|tmp)\/"#, in: candidate) {
                continue
            }
            latest = candidate.count > 64 ? String(candidate.prefix(63)) + "…" : candidate
        }
        return latest
    }

    private static let waitNowLabels: [String: String] = [
        "approval": "Waiting for a person to decide on an approval",
        "human_reply": "Waiting for your reply",
        "mockup_review": "Waiting for a person to review a mockup",
        "delegation": "Waiting for sub agents to finish",
        "checks": "Waiting for the server to check its result",
    ]

    public static func nowLine(run: API.Run, events: [API.RunEvent]) -> String? {
        guard RunsLogic.isLive(run) else { return nil }
        let sortedPlan = run.plan.sorted { $0.position < $1.position }
        let currentIdx = sortedPlan.firstIndex(where: { $0.state == .current })
        let stepSuffix = currentIdx.map { "plan step \($0 + 1) of \(sortedPlan.count): \(sortedPlan[$0].text)" } ?? ""

        switch run.state.rawValue {
        case "queued":
            return "Waiting for a runner slot"
        case "paused":
            return stepSuffix.isEmpty ? "Paused" : "Paused · \(stepSuffix)"
        case "waiting_for_quota":
            return stepSuffix.isEmpty ? "Waiting for provider usage to reset" : "Waiting for provider usage to reset · \(stepSuffix)"
        case "waiting":
            let base = waitNowLabels[run.waitReason?.rawValue ?? ""] ?? "Waiting"
            return stepSuffix.isEmpty ? base : "\(base) · \(stepSuffix)"
        default:
            for event in events.sorted(by: { $0.seq > $1.seq }) {
                if event.type == .message, event.payload["kind"] == nil,
                   let line = firstNonEmptyLine(event.payload["text"]?.stringValue ?? "") {
                    return line
                }
                if event.type == .toolCall {
                    let name = toolName(event.payload["tool"]?.stringValue ?? "")
                    let args = argSummary(event.payload["input"])
                    return [name, args].filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
            guard !stepSuffix.isEmpty else { return nil }
            return stepSuffix.prefix(1).uppercased() + stepSuffix.dropFirst()
        }
    }

    public static func finalMessage(events: [API.RunEvent]) -> String? {
        for event in events.sorted(by: { $0.seq > $1.seq }) {
            if event.type == .message, event.payload["kind"] == nil {
                let text = (event.payload["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    // MARK: - Pairing & Turns

    public struct PairedToolCall: Sendable, Equatable, Identifiable {
        public var id: String { "\(runId):\(call.seq)" }
        public var runId: String
        public var call: API.RunEvent
        public var result: API.RunEvent?
        public var toolName: String
        public var argSummary: String
        public var input: JSONValue?
        public var output: String
        public var isDenied: Bool
        public var isError: Bool
        public var exitCode: Int?
        public var durationMs: Int?
        public var link: ToolLink?
        public var delegatedChild: API.Run?

        public var isRunning: Bool { result == nil && !isDenied }
        public var isFailed: Bool { isDenied || isError }
    }

    public enum PairedRow: Sendable, Equatable {
        case tool(PairedToolCall)
        case event(API.RunEvent)

        public var anchorEvent: API.RunEvent {
            switch self {
            case .tool(let t): t.call
            case .event(let e): e
            }
        }
    }

    public static func pairRows(
        _ events: [API.RunEvent],
        runId: String,
        childRuns: [API.Run] = []
    ) -> [PairedRow] {
        let sorted = events.sorted { $0.seq < $1.seq }
        let allCalls = sorted.filter { $0.type == .toolCall }
        var rows: [PairedRow] = []
        var openByCallID: [String: Int] = [:]

        for event in sorted {
            if event.type == .toolCall {
                let rawTool = event.payload["tool"]?.stringValue ?? ""
                let inputVal = event.payload["input"]
                let denied = jsonBool(event.payload["denied_by_harness"])
                let child = childRuns.isEmpty ? nil : delegateChild(for: event, children: childRuns, allCalls: allCalls)
                let pair = PairedToolCall(
                    runId: runId,
                    call: event,
                    result: nil,
                    toolName: toolName(rawTool),
                    argSummary: argSummary(inputVal),
                    input: inputVal,
                    output: "",
                    isDenied: denied,
                    isError: false,
                    exitCode: nil,
                    durationMs: nil,
                    link: toolLink(tool: rawTool, input: inputVal),
                    delegatedChild: child
                )
                if let callID = event.payload["id"]?.stringValue, !callID.isEmpty {
                    openByCallID[callID] = rows.count
                }
                rows.append(.tool(pair))
            } else if event.type == .toolResult,
                      let callID = event.payload["id"]?.stringValue,
                      let idx = openByCallID[callID],
                      case .tool(var pair) = rows[idx] {
                pair.result = event
                pair.output = event.payload["output"]?.stringValue ?? ""
                pair.isError = jsonBool(event.payload["is_error"])
                pair.exitCode = jsonInt(event.payload["exit_code"])
                let startEpoch = APIDate.epoch(pair.call.at)
                let endEpoch = APIDate.epoch(event.at)
                if startEpoch > 0, endEpoch >= startEpoch {
                    pair.durationMs = Int(((endEpoch - startEpoch) * 1000).rounded())
                }
                rows[idx] = .tool(pair)
            } else {
                rows.append(.event(event))
            }
        }
        return rows
    }

    public static func turnStarts(_ events: [API.RunEvent]) -> [(turn: Int, at: String)] {
        events.compactMap { event in
            guard event.type == .lifecycle,
                  event.payload["state"]?.stringValue == "turn_started",
                  let turn = jsonInt(event.payload["turn"]) else { return nil }
            return (turn: turn, at: event.at)
        }
    }

    public static func turnByEvent(_ events: [API.RunEvent]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        var turn = 0
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if event.type == .lifecycle,
               event.payload["state"]?.stringValue == "turn_started",
               let next = jsonInt(event.payload["turn"]) {
                turn = next
            }
            out[event.seq] = turn
        }
        return out
    }

    public static func turnAt(_ starts: [(turn: Int, at: String)], at: String) -> Int {
        let target = APIDate.epoch(at)
        var turn = 0
        for start in starts where APIDate.epoch(start.at) <= target && start.turn >= turn {
            turn = start.turn
        }
        return turn
    }

    // MARK: - Structured Thread Folding

    public enum GateKind: String, Sendable, Equatable {
        case approval
        case reply
        case mockup

        public var label: String {
            switch self {
            case .approval: "Asked for approval"
            case .reply: "Asked a question"
            case .mockup: "Submitted a mockup for review"
            }
        }
    }

    public struct SubagentInvocation: Sendable, Equatable, Identifiable {
        public var id: String { "sub:\(callSeq)" }
        public var callSeq: Int
        public var at: String
        public var agentHandle: String
        public var task: String
        public var child: API.Run?

        public init(callSeq: Int, at: String, agentHandle: String, task: String, child: API.Run?) {
            self.callSeq = callSeq
            self.at = at
            self.agentHandle = agentHandle
            self.task = task
            self.child = child
        }
    }

    public enum ThreadItem: Sendable, Equatable, Identifiable {
        case turnHeader(id: String, turn: Int, at: String, label: String, triggerLine: String?, tools: [PairedToolCall])
        case thinking(id: String, turn: Int, at: String, heading: String?, text: String)
        case message(id: String, turn: Int, at: String, text: String)
        case step(id: String, turn: Int, at: String, position: Int, state: String, text: String?)
        case subagentGroup(id: String, turn: Int, at: String, items: [SubagentInvocation])
        case gate(id: String, turn: Int, at: String, gate: GateKind, text: String)
        case error(id: String, turn: Int, at: String, text: String, eventSeq: Int)

        public var id: String {
            switch self {
            case .turnHeader(let id, _, _, _, _, _): id
            case .thinking(let id, _, _, _, _): id
            case .message(let id, _, _, _): id
            case .step(let id, _, _, _, _, _): id
            case .subagentGroup(let id, _, _, _): id
            case .gate(let id, _, _, _, _): id
            case .error(let id, _, _, _, _): id
            }
        }
    }

    public struct ThreadModel: Sendable, Equatable {
        public var items: [ThreadItem]
        public var activity: ActivityStatus
        public var nowLine: String?
        public var stepProgress: RunsLogic.StepProgress
        public var finalMessage: String?
        public var latestQuestion: String?
        public var pendingApprovals: [API.Approval]
        public var lastEventSeq: Int

        public init(
            items: [ThreadItem],
            activity: ActivityStatus,
            nowLine: String?,
            stepProgress: RunsLogic.StepProgress,
            finalMessage: String?,
            latestQuestion: String?,
            pendingApprovals: [API.Approval],
            lastEventSeq: Int
        ) {
            self.items = items
            self.activity = activity
            self.nowLine = nowLine
            self.stepProgress = stepProgress
            self.finalMessage = finalMessage
            self.latestQuestion = latestQuestion
            self.pendingApprovals = pendingApprovals
            self.lastEventSeq = lastEventSeq
        }
    }

    private static let gateTools: [String: GateKind] = [
        "lazyagents.request_approval": .approval,
        "lazyagents.await_human": .reply,
        "lazyagents.create_mockup": .mockup,
    ]

    public static func buildThread(detail: API.RunDetail, events: [API.RunEvent]? = nil) -> ThreadModel {
        let run = detail.run
        let allEvents = (events ?? detail.events).sorted { $0.seq < $1.seq }
        let turnOf = turnByEvent(allEvents)
        let paired = pairRows(allEvents, runId: run.id, childRuns: detail.childRuns)
        let turnsBySeq = Dictionary(uniqueKeysWithValues: detail.turns.map { ($0.seq, $0) })

        var items: [ThreadItem] = []
        var turnHeaderIndex: [Int: Int] = [:]
        var turnFirstMessage: [Int: String] = [:]
        var pendingSubagents: [SubagentInvocation] = []
        var pendingSubagentTurn = 0

        func flushSubagents() {
            guard !pendingSubagents.isEmpty else { return }
            let first = pendingSubagents[0]
            items.append(.subagentGroup(
                id: "subagent-group:\(first.callSeq)",
                turn: pendingSubagentTurn,
                at: first.at,
                items: pendingSubagents
            ))
            pendingSubagents.removeAll(keepingCapacity: true)
        }

        func ensureTurnHeader(turn: Int, at: String) {
            guard turn > 0, turnHeaderIndex[turn] == nil else { return }
            flushSubagents()
            let turnRecord = turnsBySeq[turn]
            let trig = turnRecord.map { triggerLine(trigger: $0.trigger.rawValue, inputMessage: $0.inputMessage) }
            let idx = items.count
            turnHeaderIndex[turn] = idx
            items.append(.turnHeader(
                id: "turn-header:\(turn)",
                turn: turn,
                at: at,
                label: "Turn \(turn)",
                triggerLine: trig,
                tools: []
            ))
        }

        func appendRoutineTool(_ tool: PairedToolCall, turn: Int) {
            ensureTurnHeader(turn: turn, at: tool.call.at)
            guard let idx = turnHeaderIndex[turn],
                  case .turnHeader(let id, let t, let at, let label, let trig, var tools) = items[idx] else {
                return
            }
            tools.append(tool)
            items[idx] = .turnHeader(id: id, turn: t, at: at, label: label, triggerLine: trig, tools: tools)
        }

        for row in paired {
            let anchor = row.anchorEvent
            let turn = turnOf[anchor.seq] ?? 0
            if anchor.type == .lifecycle, anchor.payload["state"]?.stringValue == "turn_started" {
                ensureTurnHeader(turn: turn, at: anchor.at)
                continue
            }
            if turn > 0 {
                ensureTurnHeader(turn: turn, at: anchor.at)
            }

            switch row {
            case .tool(let pair):
                let name = pair.toolName
                let input = jsonObject(pair.input)
                if name == "lazyagents.delegate" {
                    let rawAgent = input["agent"]?.stringValue ?? ""
                    let handle = rawAgent.hasPrefix("@") ? String(rawAgent.dropFirst()) : rawAgent
                    let task = firstNonEmptyLine(input["task"]?.stringValue ?? "") ?? ""
                    if !pendingSubagents.isEmpty && pendingSubagentTurn != turn {
                        flushSubagents()
                    }
                    pendingSubagentTurn = turn
                    pendingSubagents.append(SubagentInvocation(
                        callSeq: anchor.seq,
                        at: anchor.at,
                        agentHandle: handle,
                        task: task,
                        child: pair.delegatedChild
                    ))
                } else if let gateKind = gateTools[name] {
                    flushSubagents()
                    let rawText = firstNonEmptyLine(
                        input["action"]?.stringValue
                            ?? input["reason"]?.stringValue
                            ?? input["title"]?.stringValue
                            ?? ""
                    ) ?? ""
                    let scope = input["scope"]?.stringValue ?? ""
                    let gateText = gateKind == .approval && !scope.isEmpty
                        ? [scope, rawText].filter { !$0.isEmpty }.joined(separator: " · ")
                        : rawText
                    items.append(.gate(id: "gate:\(anchor.seq)", turn: turn, at: anchor.at, gate: gateKind, text: gateText))
                } else {
                    appendRoutineTool(pair, turn: turn)
                }
                if pair.isFailed {
                    flushSubagents()
                    items.append(.error(
                        id: "tool-error:\(anchor.seq)",
                        turn: turn,
                        at: anchor.at,
                        text: toolFailureText(pair),
                        eventSeq: anchor.seq
                    ))
                }

            case .event(let event):
                let payload = event.payload
                if event.type == .error {
                    flushSubagents()
                    let msg = firstNonEmptyLine(payload["message"]?.stringValue ?? payload["error"]?.stringValue ?? "") ?? "Error"
                    items.append(.error(id: "error:\(event.seq)", turn: turn, at: event.at, text: msg, eventSeq: event.seq))
                } else if event.type == .message {
                    let kind = payload["kind"]?.stringValue
                    if kind == "step" {
                        let state = payload["state"]?.stringValue ?? ""
                        if state == "done" || state == "failed" || state == "needs_human" {
                            flushSubagents()
                            let stepNum = jsonInt(payload["step"]) ?? 0
                            let text = (run.plan.first(where: { $0.position == stepNum })
                                ?? (stepNum > 0 && stepNum <= run.plan.count ? run.plan[stepNum - 1] : nil))?.text
                            items.append(.step(
                                id: "step:\(event.seq)",
                                turn: turn,
                                at: event.at,
                                position: stepNum,
                                state: state,
                                text: text
                            ))
                        }
                    } else if kind == "thinking" {
                        let text = (payload["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            flushSubagents()
                            items.append(.thinking(
                                id: "thinking:\(event.seq)",
                                turn: turn,
                                at: event.at,
                                heading: thinkingHeading(text),
                                text: text
                            ))
                        }
                    } else if kind == nil {
                        let text = (payload["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            flushSubagents()
                            if turn > 0 && turnFirstMessage[turn] == nil {
                                turnFirstMessage[turn] = firstNonEmptyLine(text)
                            }
                            items.append(.message(id: "msg:\(event.seq)", turn: turn, at: event.at, text: text))
                        }
                    }
                }
            }
        }

        flushSubagents()

        // Fill turn header fallback summaries with the first line of each turn's opening message.
        for (turn, idx) in turnHeaderIndex {
            guard case .turnHeader(let id, let t, let at, _, let trig, let tools) = items[idx] else { continue }
            let firstMsg = turnFirstMessage[turn]
            let label = firstMsg ?? trig ?? "Turn \(turn)"
            items[idx] = .turnHeader(id: id, turn: t, at: at, label: label, triggerLine: trig, tools: tools)
        }

        return ThreadModel(
            items: items,
            activity: liveActivity(events: allEvents, run: run),
            nowLine: nowLine(run: run, events: allEvents),
            stepProgress: RunsLogic.stepProgress(for: run),
            finalMessage: finalMessage(events: allEvents),
            latestQuestion: RunsLogic.latestQuestion(from: allEvents),
            pendingApprovals: detail.approvals.filter { $0.state == .pending },
            lastEventSeq: allEvents.last?.seq ?? 0
        )
    }

    private static func toolFailureText(_ pair: PairedToolCall) -> String {
        if pair.isDenied {
            return "\(pair.toolName) denied by the harness"
        }
        let line = firstNonEmptyLine(pair.output)
        let exitPart = pair.exitCode.map { " (exit \($0))" } ?? ""
        let linePart = line.map { ": \($0)" } ?? ""
        return "\(pair.toolName) failed\(exitPart)\(linePart)"
    }

    // MARK: - Structured Trace Folding

    public enum TraceFilter: String, Sendable, CaseIterable, Hashable {
        case all
        case messages
        case tools
        case errors

        public var label: String {
            switch self {
            case .all: "All"
            case .messages: "Messages"
            case .tools: "Tools"
            case .errors: "Errors"
            }
        }
    }

    public struct TraceCounts: Sendable, Equatable {
        public var all = 0
        public var messages = 0
        public var tools = 0
        public var errors = 0

        public init(all: Int = 0, messages: Int = 0, tools: Int = 0, errors: Int = 0) {
            self.all = all
            self.messages = messages
            self.tools = tools
            self.errors = errors
        }

        public subscript(filter: TraceFilter) -> Int {
            switch filter {
            case .all: all
            case .messages: messages
            case .tools: tools
            case .errors: errors
            }
        }
    }

    public struct TraceEntry: Sendable, Equatable, Identifiable {
        public var id: String { "\(runId):\(anchorEvent.seq)" }
        public var runId: String
        public var turn: Int
        public var sourceRun: API.Run?
        public var row: PairedRow
        public var summaryText: String
        public var searchableText: String
        public var rawPayloadJSON: String
        public var isError: Bool
        public var isWarning: Bool

        public var anchorEvent: API.RunEvent { row.anchorEvent }

        public var matchesMessagesFilter: Bool {
            if case .event(let e) = row {
                return e.type == .message && e.payload["kind"] == nil
            }
            return false
        }

        public var matchesToolsFilter: Bool {
            if case .tool = row { return true }
            return false
        }
    }

    public struct TraceTurnGroup: Sendable, Equatable, Identifiable {
        public var id: String { "turn-\(turn)" }
        public var turn: Int
        public var title: String
        public var turnRecord: API.RunTurn?
        public var triggerSummary: String?
        public var entries: [TraceEntry]

        public init(turn: Int, title: String, turnRecord: API.RunTurn?, triggerSummary: String?, entries: [TraceEntry]) {
            self.turn = turn
            self.title = title
            self.turnRecord = turnRecord
            self.triggerSummary = triggerSummary
            self.entries = entries
        }
    }

    private static let turnTriggerLabels: [String: String] = [
        "start": "Started by dispatch",
        "approval": "Resumed: a person decided",
        "comment": "Resumed: a person replied",
        "resume": "Resumed",
        "delegation": "Resumed: a sub agent finished",
        "image_followup": "Resumed: generated images to react to",
    ]

    public static func triggerLine(trigger: String, inputMessage: String) -> String {
        let base = turnTriggerLabels[trigger] ?? trigger
        let first = inputMessage.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if trigger != "start" && !first.isEmpty {
            return "\(base): \(first)"
        }
        return base
    }

    public static func lifecycleSummary(_ payload: [String: JSONValue]) -> String {
        let state = payload["state"]?.stringValue ?? ""
        switch state {
        case "queued":
            return "Dispatched; waiting for a runner slot"
        case "starting":
            let backend = payload["backend"]?.stringValue ?? ""
            let runner = payload["runner"]?.stringValue ?? ""
            return "Preparing the workspace on \(backend) (\(runner))"
        case "waiting_for_quota":
            let harness = payload["harness"]?.stringValue ?? ""
            if jsonBool(payload["reset_known"]) {
                return "Out of provider usage on \(harness); holding until the limit resets"
            }
            let attempt = jsonString(payload["attempt"])
            return "Out of provider usage on \(harness); holding, attempt \(attempt), reset time unknown"
        case "quota_resume_requested":
            return "A person asked to try again now"
        case "quota_resumed":
            return "Resumed after the provider limit on \(payload["harness"]?.stringValue ?? "")"
        case "checkpoint_pushed":
            return "Unpushed work saved to \(payload["branch"]?.stringValue ?? "")"
        case "checkpoint_recovered":
            return "Recovered work from an earlier run: \(payload["branch"]?.stringValue ?? "")"
        case "checkpoint_failed":
            return "Could not save unpushed work, so the workspace was kept: \(payload["reason"]?.stringValue ?? "")"
        case "checkpoint_deleted":
            return "Removed checkpoint \(payload["branch"]?.stringValue ?? "") after PR shipped"
        case "environment_snapshot":
            return "Runner environment recorded"
        case "workspace_ready":
            return "Workspace ready on branch \(payload["branch"]?.stringValue ?? "")"
        case "running":
            if payload["trigger"] != nil {
                let first = (payload["message"]?.stringValue ?? "").split(separator: "\n").first.map(String.init) ?? ""
                return "Running again: \(first)"
            }
            return "Running"
        case "turn_started":
            let turn = jsonString(payload["turn"])
            return "Turn \(turn) started" + (jsonBool(payload["resume"]) ? " · resumed the harness session" : "")
        case "harness_notice":
            return "Harness notice: \(payload["message"]?.stringValue ?? "")"
        case "harness_started":
            let harness = payload["harness"]?.stringValue ?? ""
            let session = String((payload["session_id"]?.stringValue ?? "").prefix(13))
            return "\(harness) started · session \(session)"
        case "turn_ended":
            return "Turn \(jsonString(payload["turn"])) ended · exit \(jsonString(payload["exit_code"]))"
        case "waiting", "paused", "completed", "failed", "cancelled":
            let label = RunsLogic.stateLabels[state]?.label ?? state
            let reason = payload["reason"]?.stringValue ?? ""
            return reason.isEmpty ? "Run is now \(label)" : "Run is now \(label) · \(reason)"
        default:
            return state
        }
    }

    public static func buildTrace(
        detail: API.RunDetail,
        events: [API.RunEvent]? = nil,
        childDetails: [API.RunDetail] = [],
        filter: TraceFilter = .all,
        search: String = ""
    ) -> (groups: [TraceTurnGroup], counts: TraceCounts) {
        let mainEvents = events ?? detail.events
        let parentTurn = turnByEvent(mainEvents)
        let starts = turnStarts(mainEvents)

        struct RawEntry {
            var row: PairedRow
            var sourceRun: API.Run?
            var runId: String
            var turn: Int
        }

        var combined: [RawEntry] = pairRows(mainEvents, runId: detail.run.id, childRuns: detail.childRuns).map { row in
            RawEntry(
                row: row,
                sourceRun: nil,
                runId: detail.run.id,
                turn: parentTurn[row.anchorEvent.seq] ?? 0
            )
        }

        for child in childDetails {
            let childRows = pairRows(child.events, runId: child.run.id, childRuns: child.childRuns)
            for row in childRows {
                combined.append(RawEntry(
                    row: row,
                    sourceRun: child.run,
                    runId: child.run.id,
                    turn: turnAt(starts, at: row.anchorEvent.at)
                ))
            }
        }

        combined.sort { a, b in
            let ae = a.row.anchorEvent
            let be = b.row.anchorEvent
            let ta = APIDate.epoch(ae.at)
            let tb = APIDate.epoch(be.at)
            if ta != tb { return ta < tb }
            if a.runId != b.runId { return a.runId < b.runId }
            return ae.seq < be.seq
        }

        // Drop turn_started, turn_ended, and activity heartbeats.
        let visible = combined.filter { item in
            if case .event(let e) = item.row, e.type == .lifecycle {
                let state = e.payload["state"]?.stringValue ?? ""
                return state != "turn_started" && state != "turn_ended" && state != "activity"
            }
            return true
        }

        let entries: [TraceEntry] = visible.map { item in
            let anchor = item.row.anchorEvent
            let isError: Bool
            let isWarning: Bool
            let summary: String
            let rawJSON: String
            let searchable: String

            switch item.row {
            case .tool(let pair):
                isError = pair.isFailed
                isWarning = false
                summary = [pair.toolName, pair.argSummary].filter { !$0.isEmpty }.joined(separator: " ")
                var jsonParts: [String] = []
                if let input = pair.input { jsonParts.append("\"input\": \(prettyJSON(input))") }
                jsonParts.append("\"call\": \(prettyJSON(pair.call.payload))")
                if let res = pair.result { jsonParts.append("\"result\": \(prettyJSON(res.payload))") }
                rawJSON = "{\n\(jsonParts.joined(separator: ",\n"))\n}"
                searchable = "\(item.sourceRun?.agent.name ?? "") \(compactJSON(.object(pair.call.payload))) \(pair.result.map { compactJSON(.object($0.payload)) } ?? "")".lowercased()

            case .event(let event):
                isError = event.type == .error
                let lcState = event.payload["state"]?.stringValue ?? ""
                isWarning = event.type == .lifecycle && (lcState == "waiting" || lcState == "paused")
                rawJSON = prettyJSON(event.payload)
                searchable = "\(item.sourceRun?.agent.name ?? "") \(compactJSON(.object(event.payload)))".lowercased()
                if event.type == .message {
                    let kind = event.payload["kind"]?.stringValue
                    if kind == nil {
                        summary = event.payload["text"]?.stringValue ?? ""
                    } else if kind == "plan" {
                        let steps = jsonArray(event.payload["steps"])
                        summary = "Posted a plan: \(steps.count) steps"
                    } else if kind == "step" {
                        let step = jsonInt(event.payload["step"]) ?? 0
                        let state = event.payload["state"]?.stringValue ?? ""
                        let text = (detail.run.plan.first(where: { $0.position == step })
                            ?? (step > 0 && step <= detail.run.plan.count ? detail.run.plan[step - 1] : nil))?.text
                        summary = "Step \(step) → \(state)" + (text.map { " · \($0)" } ?? "")
                    } else if kind == "thinking" {
                        summary = event.payload["text"]?.stringValue ?? ""
                    } else {
                        summary = "\(kind ?? "") \(event.payload["payload"].map(compactJSON) ?? "")"
                    }
                } else if event.type == .error {
                    summary = event.payload["message"]?.stringValue ?? event.payload["error"]?.stringValue ?? "Error"
                } else if event.type == .usage {
                    let breakdown = RunsLogic.tokenBreakdown(eventPayload: event.payload)
                    let costVal = RunsLogic.jsonDouble(event.payload["cost_usd"]) ?? 0
                    let rawSrc = event.payload["cost_source"]?.stringValue
                    let costSource: String
                    if rawSrc == "harness" || rawSrc == "computed" {
                        costSource = rawSrc!
                    } else if jsonBool(event.payload["cost_known"]) || (event.payload["cost_known"] == nil && costVal > 0) {
                        costSource = "harness"
                    } else {
                        costSource = "unknown"
                    }
                    let costStr = WorkLogic.runCost(costVal, source: costSource)
                    let cachePart: String
                    if breakdown.hasBreakdown {
                        let unknownPart = breakdown.unknown > 0 ? " · \(RunsLogic.compactNumber(breakdown.unknown)) cache unknown" : ""
                        cachePart = " · \(RunsLogic.compactNumber(breakdown.cached)) cached · \(RunsLogic.compactNumber(breakdown.uncached)) uncached\(unknownPart)"
                    } else {
                        cachePart = " · cache breakdown unavailable"
                    }
                    summary = "turn total · \(RunsLogic.compactNumber(breakdown.input)) in · \(RunsLogic.compactNumber(breakdown.output)) out\(cachePart) · \(costStr)"
                } else if event.type == .toolResult {
                    summary = "result for \(toolName(event.payload["tool"]?.stringValue ?? ""))"
                } else {
                    summary = lifecycleSummary(event.payload)
                }
            }

            return TraceEntry(
                runId: item.runId,
                turn: item.turn,
                sourceRun: item.sourceRun,
                row: item.row,
                summaryText: summary,
                searchableText: searchable,
                rawPayloadJSON: rawJSON,
                isError: isError,
                isWarning: isWarning
            )
        }

        let counts = TraceCounts(
            all: entries.count,
            messages: entries.filter(\.matchesMessagesFilter).count,
            tools: entries.filter(\.matchesToolsFilter).count,
            errors: entries.filter(\.isError).count
        )

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = entries.filter { entry in
            let passesFilter: Bool = switch filter {
            case .all: true
            case .messages: entry.matchesMessagesFilter
            case .tools: entry.matchesToolsFilter
            case .errors: entry.isError
            }
            guard passesFilter else { return false }
            return query.isEmpty || entry.searchableText.contains(query) || entry.summaryText.lowercased().contains(query)
        }

        let turnsBySeq = Dictionary(uniqueKeysWithValues: detail.turns.map { ($0.seq, $0) })
        var grouped: [Int: [TraceEntry]] = [:]
        for entry in filtered {
            grouped[entry.turn, default: []].append(entry)
        }
        let groups = grouped.keys.sorted().map { turn in
            let record = turnsBySeq[turn]
            let trig = record.map { triggerLine(trigger: $0.trigger.rawValue, inputMessage: $0.inputMessage) }
            return TraceTurnGroup(
                turn: turn,
                title: turn == 0 ? "Setup" : "Turn \(turn)",
                turnRecord: record,
                triggerSummary: trig,
                entries: grouped[turn] ?? []
            )
        }
        return (groups, counts)
    }

    // MARK: - Helpers

    private static func firstNonEmptyLine(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
