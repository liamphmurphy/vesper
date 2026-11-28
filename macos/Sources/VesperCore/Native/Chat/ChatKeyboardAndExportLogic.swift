import Foundation

// MARK: - Keyboard-First Transcript Navigation

public enum ChatKeyboardAction: Equatable, Sendable {
    case jumpPreviousTurn
    case jumpNextTurn
    case copyLastReply
    case toggleOutline
    case openContextCompact
    case toggleLiveVoice
}

public enum ChatKeyboardNavLogic {
    /// macOS virtual key codes for arrow keys.
    public static let upArrowKeyCode: UInt16 = 126
    public static let downArrowKeyCode: UInt16 = 125

    /// Maps a key event into a chat shortcut action when modifiers match exactly.
    public static func resolveAction(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> ChatKeyboardAction? {
        if option && !command && !shift && !control {
            if keyCode == upArrowKeyCode { return .jumpPreviousTurn }
            if keyCode == downArrowKeyCode { return .jumpNextTurn }
            return nil
        }
        if command && shift && !option && !control {
            switch charactersIgnoringModifiers?.lowercased() {
            case "c": return .copyLastReply
            case "o": return .toggleOutline
            case "k": return .openContextCompact
            case "l": return .toggleLiveVoice
            default: return nil
            }
        }
        return nil
    }

    /// Computes the next or previous conversational turn message ID (`direction` < 0 = older, > 0 = newer).
    public static func stepTurnMessageId(
        messages: [API.ChatMessage],
        currentId: String?,
        direction: Int
    ) -> String? {
        let turns = messages.filter { $0.role == .user || $0.role == .assistant }
        guard !turns.isEmpty, direction != 0 else { return nil }
        guard let currentId, let idx = turns.firstIndex(where: { $0.id == currentId }) else {
            return direction < 0 ? turns.last?.id : turns.first?.id
        }
        let nextIdx = max(0, min(turns.count - 1, idx + (direction < 0 ? -1 : 1)))
        return turns[nextIdx].id
    }

    /// Returns the markdown body of the most recent assistant reply in `messages`, if any.
    public static func lastAssistantReplyBody(in messages: [API.ChatMessage]) -> String? {
        messages.last(where: { $0.role == .assistant && !$0.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.bodyMd
    }
}

// MARK: - Full-Chat Export (Markdown, PDF via PrintDocument, Knowledge)

public enum ChatExportLogic {
    /// Builds a clean, portable Markdown export of a full chat transcript, optionally including
    /// folded tool traces per assistant turn.
    public static func exportMarkdown(
        session: API.ChatSession,
        messages: [API.ChatMessage],
        eventsByRunId: [String: [API.RunEvent]] = [:],
        includeToolTraces: Bool = false
    ) -> String {
        let title = ChatNav.chatTitle(session.title)
        var lines: [String] = ["# \(title)", ""]

        var meta: [String] = []
        let personaName = session.persona?.name ?? session.agent.name
        if !personaName.isEmpty { meta.append("Persona: \(personaName)") }
        if let spaceName = session.space?.name, !spaceName.isEmpty { meta.append("Space: \(spaceName)") }
        if !session.model.isEmpty { meta.append("Model: \(session.model)") }
        meta.append("\(messages.count) \(messages.count == 1 ? "message" : "messages")")
        lines.append("*\(meta.joined(separator: " · "))*")
        lines.append("")
        lines.append("---")
        lines.append("")

        let turnWindows = ChatTurnActivity.turnWindows(for: messages)

        for msg in messages {
            let speaker: String
            switch msg.role {
            case .user:
                speaker = "You"
            case .assistant:
                speaker = msg.persona?.name ?? session.persona?.name ?? session.agent.name
            default:
                speaker = "System"
            }

            var heading = "## \(speaker)"
            if let model = msg.model, !model.isEmpty, msg.role == .assistant {
                heading += " (`\(model)`)"
            }
            lines.append(heading)
            lines.append("")

            if includeToolTraces,
               msg.role == .assistant,
               let runId = msg.runId,
               let rawEvents = eventsByRunId[runId],
               !rawEvents.isEmpty {
                let win = turnWindows[msg.id]
                let activity = ChatTurnActivity.fold(
                    events: rawEvents.map(ChatRunEvent.init),
                    since: win?.since,
                    until: win?.until
                )
                if !activity.steps.isEmpty {
                    lines.append("<details>")
                    lines.append("<summary>Tool trace (\(activity.steps.count) \(activity.steps.count == 1 ? "step" : "steps"))</summary>")
                    lines.append("")
                    for step in activity.steps {
                        let icon = step.state == .failed ? "✗" : "✓"
                        lines.append("- \(icon) \(step.title)")
                    }
                    lines.append("")
                    lines.append("</details>")
                    lines.append("")
                }
            }

            let body = msg.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                lines.append(body)
                lines.append("")
            }
            if let attachments = msg.attachments, !attachments.isEmpty {
                let names = attachments.map(\.filename).joined(separator: ", ")
                lines.append("*Attachments: \(names)*")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Builds a `PrintDocument` for PDF export via `PrintRenderer`.
    public static func printDocument(
        session: API.ChatSession,
        messages: [API.ChatMessage],
        eventsByRunId: [String: [API.RunEvent]] = [:],
        includeToolTraces: Bool = false
    ) -> PrintDocument {
        let title = ChatNav.chatTitle(session.title)
        let personaName = session.persona?.name ?? session.agent.name
        var metaParts: [String] = []
        if !personaName.isEmpty { metaParts.append(personaName) }
        if !session.model.isEmpty { metaParts.append(session.model) }
        metaParts.append("\(messages.count) messages")

        let header = PrintHeader(
            folder: session.space?.name,
            title: title,
            metaLine: metaParts.joined(separator: " · ")
        )

        var bodySections: [String] = []
        let turnWindows = ChatTurnActivity.turnWindows(for: messages)
        for msg in messages {
            let speaker: String
            switch msg.role {
            case .user: speaker = "You"
            case .assistant: speaker = msg.persona?.name ?? personaName
            default: speaker = "System"
            }
            var section = "### \(speaker)\n\n"
            if includeToolTraces,
               msg.role == .assistant,
               let runId = msg.runId,
               let rawEvents = eventsByRunId[runId],
               !rawEvents.isEmpty {
                let win = turnWindows[msg.id]
                let activity = ChatTurnActivity.fold(
                    events: rawEvents.map(ChatRunEvent.init),
                    since: win?.since,
                    until: win?.until
                )
                if !activity.steps.isEmpty {
                    let traceLines = activity.steps.map { "- \($0.title)" }.joined(separator: "\n")
                    section += "> **Steps**\n>\n" + traceLines.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n"
                }
            }
            section += msg.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines)
            bodySections.append(section)
        }

        let bodyMd = bodySections.joined(separator: "\n\n---\n\n")
        return PrintDocument(
            title: title,
            style: .clean,
            header: header,
            body: [.markdown(MarkdownParser.parse(bodyMd))]
        )
    }

    /// Generates a safe default filename (e.g. `my-chat-title.md` or `.pdf`).
    public static func defaultFileName(title: String, ext: String) -> String {
        let slug = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "vesper-chat" : String(slug.prefix(64))
        return "\(base).\(ext)"
    }

    /// Prompt sent to the persona for "Summarize & Save to Knowledge".
    public static func summarizeToKnowledgePrompt(chatTitle: String) -> String {
        let title = chatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? "this conversation" : "\"\(title)\""
        return "Summarize the key decisions, takeaways, and open items from \(label) into a clean, well-structured Knowledge page using `create_page` (or `patch_page` if an existing page fits better), and link the page in your reply."
    }
}
