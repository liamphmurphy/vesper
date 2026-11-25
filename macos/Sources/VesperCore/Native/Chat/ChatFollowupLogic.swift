import Foundation

/// Pure state and formatting helpers for queued chat follow-ups (`followups.tsx` in web).
public enum ChatFollowupLogic {
    /// Whether queued follow-ups are held rather than draining automatically after the current turn.
    /// After a stopped turn (`idle` with no assistant reply at the tail) or a failed turn, the server
    /// holds the queue until the person sends a message or clicks "Send now".
    public static func isHeld(
        state: API.ChatState?,
        lastMessageRole: API.ChatMessage.Role?
    ) -> Bool {
        if state == .running { return false }
        if state == .failed { return true }
        return lastMessageRole != .assistant
    }

    /// Header shown at the top of the queued follow-up tray.
    public static func header(speakerName: String, running: Bool, held: Bool) -> String {
        if running {
            return "Queued \u{00B7} sends when \(speakerName) finishes, in order"
        }
        if held {
            return "Held \u{00B7} \(speakerName) stopped, so these wait for you"
        }
        return "Queued \u{00B7} sends after \(speakerName)\u{2019}s next reply"
    }

    /// Tooltip for the per-row "Send now" button.
    public static func sendNowTooltip(speakerName: String, running: Bool) -> String {
        running ? "Stop \(speakerName) and send this now" : "Send this now"
    }

    /// Clean user-facing text for editing or re-sending, stripping appended dock context blocks
    /// (such as `<!-- vesper:knowledge-context -->` or `<!-- vesper:custom-app-context -->`).
    public static func displayBody(_ rawBody: String) -> String {
        let stripped = ChatTranscriptLogic.stripContext(rawBody)
            .typedBody
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? rawBody.trimmingCharacters(in: .whitespacesAndNewlines) : stripped
    }

    /// Single-line preview for a tray row, collapsing line breaks so multi-line messages read cleanly.
    public static func previewText(_ rawBody: String) -> String {
        displayBody(rawBody)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Merges a follow-up removed for editing back into the composer draft. Because the follow-up was
    /// queued earlier than anything currently typed, it goes ahead of an existing draft.
    public static func mergeIntoDraft(_ body: String, existingDraft: String) -> String {
        let clean = displayBody(body)
        if existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return clean
        }
        return "\(clean)\n\n\(existingDraft)"
    }

    /// Returns a `ChatFollowupList` with `followup` appended (deduplicated by `id`), used to seed
    /// the cache immediately when `queueChatFollowup` succeeds while a turn is running.
    public static func appending(
        _ followup: API.ChatFollowup,
        to existing: API.ChatFollowupList?
    ) -> API.ChatFollowupList {
        var items = existing?.followups ?? []
        if !items.contains(where: { $0.id == followup.id }) {
            items.append(followup)
        }
        return API.ChatFollowupList(followups: items)
    }
}
