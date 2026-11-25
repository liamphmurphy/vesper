import Foundation

/// Pure right-rail / inspector model builders for the native Persona Chat screen.
public enum ChatInspectorLogic {
    public static let modelId = "chat"
    public static let landingModelId = "chat-landing"
    public static let designTabId = "design"
    public static let canvasTabId = "canvas"
    public static let playgroundTabId = "playground"
    public static let codeTabId = "code"
    public static let threadTabId = "thread"
    public static let outlineTabId = "outline"
    public static let activityTabId = "activity"

    public static let jumpTurnActionId = "jump_turn"
    public static let closeActionId = "close"
    public static let reviewActionId = "review"

    public struct Input: Sendable {
        public var chatId: String?
        public var session: API.ChatSession?
        public var messages: [API.ChatMessage]
        public var harnessModels: [API.ChatHarnessModels]
        public var costs: API.CostReport?
        public var codeReviews: [API.CodeReview]
        public var playgroundState: API.ChatPlaygroundState?
        public var canvases: [API.ChatCanvasSummary]
        public var liveActivity: ChatTurnActivity?
        public var open: Bool
        public var activeTabId: String
        public var activeDesignId: String?
        public var activeCanvasId: String?
        public var designReviewing: Bool
        public var threadMessageId: String?
        public var forceShowCode: Bool
        public var startingPlayground: Bool

        public init(
            chatId: String?,
            session: API.ChatSession? = nil,
            messages: [API.ChatMessage] = [],
            harnessModels: [API.ChatHarnessModels] = [],
            costs: API.CostReport? = nil,
            codeReviews: [API.CodeReview] = [],
            playgroundState: API.ChatPlaygroundState? = nil,
            canvases: [API.ChatCanvasSummary] = [],
            liveActivity: ChatTurnActivity? = nil,
            open: Bool = false,
            activeTabId: String = ChatInspectorLogic.activityTabId,
            activeDesignId: String? = nil,
            activeCanvasId: String? = nil,
            designReviewing: Bool = false,
            threadMessageId: String? = nil,
            forceShowCode: Bool = false,
            startingPlayground: Bool = false
        ) {
            self.chatId = chatId
            self.session = session
            self.messages = messages
            self.harnessModels = harnessModels
            self.costs = costs
            self.codeReviews = codeReviews
            self.playgroundState = playgroundState
            self.canvases = canvases
            self.liveActivity = liveActivity
            self.open = open
            self.activeTabId = activeTabId
            self.activeDesignId = activeDesignId
            self.activeCanvasId = activeCanvasId
            self.designReviewing = designReviewing
            self.threadMessageId = threadMessageId
            self.forceShowCode = forceShowCode
            self.startingPlayground = startingPlayground
        }
    }

    /// Resolves human-friendly harness and model labels from the available model catalog.
    public static func modelLabels(
        harness: API.Harness?,
        model: String?,
        catalog: [API.ChatHarnessModels]
    ) -> (harness: String, model: String) {
        let matchedGroup = harness.flatMap { h in catalog.first { $0.harness == h } }
        let harnessName = matchedGroup?.label ?? harness?.rawValue.capitalized ?? "Default"
        let matchedModel = model.flatMap { id in
            matchedGroup?.models.first { $0.id == id }?.label
                ?? catalog.lazy.flatMap(\.models).first { $0.id == id }?.label
        }
        let modelName = matchedModel ?? (model?.isEmpty == false ? model! : "Default")
        return (harnessName, modelName)
    }

    public static func effortLabel(_ effort: API.ChatEffort) -> String {
        switch effort.rawValue.lowercased() {
        case "auto": return "Auto"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh", "max": return "Max"
        default: return effort.rawValue.capitalized
        }
    }

    public static func shortRepoName(_ repoUrl: String) -> String {
        let trimmed = repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let clean = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
        let parts = clean.split(separator: "/").map(String.init)
        if parts.count >= 2 {
            return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
        }
        return clean
    }

    public static func strippedPromptPreview(_ bodyMd: String, limit: Int = 90) -> String {
        var text = bodyMd
        for marker in ChatContextMarker.all {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !collapsed.isEmpty else { return "" }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Parses a `review` panel event payload (`{"on": true|false}`) emitted by `chat.design`.
    public static func parseDesignReviewToggle(from payloadJson: String?) -> Bool? {
        guard let payloadJson,
              let data = payloadJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let on = obj["on"] as? Bool else {
            return nil
        }
        return on
    }

    public static func buildActivitySections(
        session: API.ChatSession?,
        messages: [API.ChatMessage],
        harnessModels: [API.ChatHarnessModels],
        costs: API.CostReport?,
        liveActivity: ChatTurnActivity?
    ) -> [InspectorSection] {
        var sections: [InspectorSection] = []

        if let session {
            let labels = modelLabels(harness: session.harness, model: session.model, catalog: harnessModels)
            let modelText = session.autoModel == true ? "\(labels.model) (auto)" : labels.model
            var summaryItems: [InspectorItem] = [
                InspectorItem(id: "model", kind: .fact, label: "Model", value: modelText, mono: true),
                InspectorItem(id: "harness", kind: .fact, label: "Harness", value: labels.harness, mono: true),
            ]
            if let effort = session.effort {
                summaryItems.append(InspectorItem(id: "effort", kind: .fact, label: "Effort", value: effortLabel(effort)))
            }
            if let total = costs?.total, total.runs > 0 {
                let spend = ReportsLogic.spendLabel(micros: total.costMicros, unpricedRuns: costs?.unpricedRuns ?? 0)
                summaryItems.append(InspectorItem(id: "cost", kind: .fact, label: "Cost", value: spend, mono: true))
            }
            if let repoUrl = session.repoUrl, !repoUrl.isEmpty {
                summaryItems.append(InspectorItem(
                    id: "repo",
                    kind: .fact,
                    label: "Repository",
                    value: shortRepoName(repoUrl),
                    mono: true
                ))
            }
            let statusValue: String
            let statusTone: Tone
            switch session.state {
            case .running:
                statusValue = "Running"
                statusTone = .accent
            case .failed:
                statusValue = "Failed"
                statusTone = .danger
            default:
                statusValue = "Idle"
                statusTone = .neutral
            }
            summaryItems.append(InspectorItem(id: "state", kind: .fact, label: "Status", value: statusValue, tone: statusTone))
            sections.append(InspectorSection(id: "summary", title: "Session", items: summaryItems))

            if session.state == .running {
                let speakerName = session.speaker?.name ?? session.persona?.name ?? session.agent.name
                var liveItems: [InspectorItem] = []
                if let liveActivity {
                    var summary = "\(speakerName) is \(liveActivity.status.phrase)\u{2026}"
                    if let elapsed = liveActivity.elapsedMs {
                        summary += " (\(ChatTurnActivity.formatSpan(ms: elapsed)))"
                    }
                    liveItems.append(InspectorItem(id: "live_note", kind: .note, detail: summary, tone: .accent))
                    if !liveActivity.steps.isEmpty {
                        let steps = liveActivity.steps.map { step -> InspectorStep in
                            let state: InspectorStepState
                            switch step.state {
                            case .done: state = .done
                            case .active: state = .current
                            case .planned: state = .pending
                            case .failed: state = .failed
                            }
                            let text: String
                            if let detail = step.detail, !detail.isEmpty {
                                text = "\(step.title) \u{2014} \(detail)"
                            } else {
                                text = step.title
                            }
                            return InspectorStep(id: step.key, text: text, state: state)
                        }
                        liveItems.append(InspectorItem(id: "live_steps", kind: .checklist, steps: steps))
                    }
                } else {
                    liveItems.append(InspectorItem(
                        id: "live_note",
                        kind: .note,
                        detail: "\(speakerName) is working on a reply\u{2026}",
                        tone: .accent
                    ))
                }
                sections.append(InspectorSection(id: "live", title: "Current turn", items: liveItems))
            }
        }

        let fallbackLabels = modelLabels(harness: session?.harness, model: session?.model, catalog: harnessModels)
        var turnRows: [NavItem] = []
        var lastUserPrompt = ""
        for message in messages {
            if message.role == .user {
                lastUserPrompt = strippedPromptPreview(message.bodyMd)
            } else if message.role == .assistant {
                let labels = (message.harness != nil || message.model != nil)
                    ? modelLabels(harness: message.harness ?? session?.harness, model: message.model ?? session?.model, catalog: harnessModels)
                    : fallbackLabels
                var metaParts = ["\(labels.harness) \u{00B7} \(labels.model)"]
                if let changed = message.codeChanges, !changed.isEmpty {
                    let noun = changed.count == 1 ? "file" : "files"
                    metaParts.append("\(changed.count) \(noun)")
                }
                if let cost = ChatTurnActivity.replyCost(message.costUsd) {
                    metaParts.append(cost)
                }
                let title = lastUserPrompt.isEmpty ? "Reply" : lastUserPrompt
                turnRows.append(NavItem(
                    id: message.id,
                    title: title,
                    subtitle: metaParts.joined(separator: " \u{00B7} "),
                    status: .done
                ))
            }
        }

        let newestFirst = Array(turnRows.reversed())
        sections.append(InspectorSection(
            id: "turns",
            title: "Turns",
            aside: newestFirst.isEmpty ? nil : String(newestFirst.count),
            emptyText: "Tool calls, web searches and memory changes appear once the assistant replies.",
            items: newestFirst.isEmpty ? [] : [
                InspectorItem(id: "turn_rows", kind: .list, actionId: jumpTurnActionId, rows: newestFirst)
            ]
        ))

        return sections
    }

    public static func buildInspectorModel(_ input: Input) -> InspectorModel {
        guard let chatId = input.chatId, !chatId.isEmpty else {
            return InspectorModel(id: landingModelId, open: false, activeTabId: "", tabs: [])
        }

        let isRunning = input.session?.state == .running
        let speakerName = input.session?.persona?.name ?? input.session?.agent.name ?? "Assistant"
        let readOnly = input.session?.archived == true

        let designCanvases = input.canvases.filter { $0.kind == .design }
        let otherCanvases = input.canvases.filter { $0.kind != .design }
        let effectiveDesignId = input.activeDesignId ?? designCanvases.last?.id
        let effectiveCanvasId = input.activeCanvasId ?? otherCanvases.last?.id

        let hasCode = input.forceShowCode
            || !(input.session?.repoUrl ?? "").isEmpty
            || !(input.session?.repositories ?? []).isEmpty
            || !input.codeReviews.isEmpty
            || input.messages.contains(where: { !($0.codeChanges ?? []).isEmpty })
        let codeBusy = input.codeReviews.contains(where: \.live)
        let changedFileCount = input.codeReviews.reduce(0) { $0 + $1.files.count }

        let pg = input.playgroundState?.playground
        let hasPlayground = pg != nil || input.playgroundState?.savedSpec == true
        let pgBusy = input.startingPlayground || (pg.map { $0.state == .starting || $0.action?.value != nil } ?? false)
        let pgLabel: String = {
            guard let pg else {
                return input.startingPlayground ? "Starting playground\u{2026}" : "Start playground"
            }
            switch pg.state {
            case .running: return "Playground"
            case .starting: return "Playground (starting)"
            case .failed: return "Playground (failed)"
            case .stopped: return "Playground (stopped)"
            default: return "Playground"
            }
        }()

        var tabs: [InspectorTab] = []

        if let designId = effectiveDesignId {
            let props: [String: JSONValue] = [
                "tabId": .string(designTabId),
                "chatId": .string(chatId),
                "live": .bool(isRunning),
                "designId": .string(designId),
                "reviewing": .bool(input.designReviewing),
            ]
            tabs.append(InspectorTab(
                id: designTabId,
                label: "Design",
                icon: "designs",
                kind: .panel,
                width: input.designReviewing ? .max : .wide,
                busy: isRunning ? true : nil,
                headerActions: [
                    InspectorAction(
                        id: reviewActionId,
                        label: input.designReviewing ? "Exit review" : "Review changes",
                        icon: "compare",
                        active: input.designReviewing
                    )
                ],
                panel: InspectorLogic.makePanelSpec(
                    kind: "chat.design",
                    key: "chat.design:\(chatId)",
                    props: props
                )
            ))
        }

        if let canvasId = effectiveCanvasId {
            let props: [String: JSONValue] = [
                "tabId": .string(canvasTabId),
                "chatId": .string(chatId),
                "live": .bool(isRunning),
                "readOnly": .bool(readOnly),
                "agent": .string(speakerName),
                "canvasId": .string(canvasId),
            ]
            tabs.append(InspectorTab(
                id: canvasTabId,
                label: "Canvas",
                icon: "artifacts",
                kind: .panel,
                width: .wide,
                panel: InspectorLogic.makePanelSpec(
                    kind: "chat.canvas",
                    key: "chat.canvas:\(chatId)",
                    props: props
                )
            ))
        }

        if hasPlayground {
            let props: [String: JSONValue] = [
                "tabId": .string(playgroundTabId),
                "chatId": .string(chatId),
            ]
            tabs.append(InspectorTab(
                id: playgroundTabId,
                label: pgLabel,
                icon: "playLeft",
                kind: .panel,
                width: .wide,
                busy: pgBusy ? true : nil,
                panel: InspectorLogic.makePanelSpec(
                    kind: "chat.playground",
                    key: "chat.playground:\(chatId)",
                    props: props
                )
            ))
        }

        if hasCode {
            tabs.append(InspectorTab(
                id: codeTabId,
                label: "Code",
                icon: "code",
                kind: .native,
                width: .wide,
                busy: codeBusy ? true : nil,
                badge: changedFileCount > 0 ? NavBadge(text: "\(changedFileCount)", tone: .accent) : nil
            ))
        }

        if let threadId = input.threadMessageId, !threadId.isEmpty {
            tabs.append(InspectorTab(
                id: threadTabId,
                label: "Thread",
                icon: "branch",
                kind: .native,
                width: .regular,
                headerActions: [InspectorAction(id: closeActionId, label: "Close thread", icon: "x")]
            ))
        }

        let bookmarkedCount = input.messages.filter { $0.bookmarked == true }.count
        tabs.append(InspectorTab(
            id: outlineTabId,
            label: "Outline",
            icon: "outline",
            kind: .native,
            width: .regular,
            badge: bookmarkedCount > 0 ? NavBadge(text: "\(bookmarkedCount)", tone: .accent) : nil
        ))

        let activitySections = buildActivitySections(
            session: input.session,
            messages: input.messages,
            harnessModels: input.harnessModels,
            costs: input.costs,
            liveActivity: input.liveActivity
        )
        tabs.append(InspectorTab(
            id: activityTabId,
            label: "Activity",
            icon: "activity",
            kind: .native,
            width: .regular,
            busy: isRunning ? true : nil,
            sections: activitySections
        ))

        let resolvedActiveId = tabs.contains(where: { $0.id == input.activeTabId })
            ? input.activeTabId
            : activityTabId

        return InspectorModel(
            id: modelId,
            open: input.open,
            activeTabId: resolvedActiveId,
            tabs: tabs
        )
    }
}
