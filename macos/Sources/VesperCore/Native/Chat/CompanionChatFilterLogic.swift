import Foundation

/// Shared filtering, search-hit routing, and mid-turn send mode helpers for the iOS Companion chat UI.
public enum CompanionChatFilterLogic {
    public struct NavigationTarget: Hashable, Sendable {
        public let chatId: String
        public let initialTitle: String
        public let focusMessageId: String?

        public init(chatId: String, initialTitle: String, focusMessageId: String? = nil) {
            self.chatId = chatId
            self.initialTitle = initialTitle
            self.focusMessageId = focusMessageId
        }
    }

    public enum MidTurnSendMode: String, CaseIterable, Sendable, Identifiable {
        case queue
        case steer

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .queue: "Queue"
            case .steer: "Steer"
            }
        }

        public var placeholder: String {
            switch self {
            case .queue: "Queue follow-up for after this turn…"
            case .steer: "Steer this reply mid-turn…"
            }
        }
    }

    /// Builds a typed `GET /chats` request using `ChatNav.listPersonaQuery` so "All" sends `persona_id=all`.
    public static func listRequest(
        archived: Bool,
        personaId: String,
        spaceId: String
    ) -> APIRequest<API.ListChatsResponse> {
        API.listChats(
            archived: archived,
            personaId: ChatNav.listPersonaQuery(personaId),
            space: spaceId.isEmpty ? nil : spaceId
        )
    }

    /// Fast client-side filter for short search queries (< 2 chars) or instant narrowing.
    public static func localFilter(_ chats: [API.ChatSession], query: String) -> [API.ChatSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return chats }
        return chats.filter { chat in
            chat.title.lowercased().contains(q)
                || (chat.persona?.name.lowercased().contains(q) ?? false)
                || chat.agent.name.lowercased().contains(q)
                || (chat.space?.name.lowercased().contains(q) ?? false)
                || (chat.preview?.lowercased().contains(q) ?? false)
        }
    }

    /// Strips server highlight sentinel markers (`\u{E000}` / `\u{E001}`) from search hit snippets.
    public static func cleanSearchSnippet(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{E000}", with: "")
            .replacingOccurrences(of: "\u{E001}", with: "")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
