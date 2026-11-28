import Foundation

/// A preserved assistant reply captured before regenerating the last turn so the user
/// can compare earlier tries via a `< 1 / N >` switcher without losing the original text.
public struct ChatReplyVariant: Sendable, Equatable, Identifiable {
    public let id: String
    public let bodyMd: String
    public let model: String?
    public let harness: String?
    public let createdAt: String

    public init(id: String, bodyMd: String, model: String? = nil, harness: String? = nil, createdAt: String = "") {
        self.id = id
        self.bodyMd = bodyMd
        self.model = model
        self.harness = harness
        self.createdAt = createdAt
    }
}

/// Pure in-memory store for regenerated reply variants keyed by `(chatId, userMessageId)`.
public struct ChatReplyVariantStore: Sendable, Equatable {
    private var archivedByTurn: [String: [ChatReplyVariant]] = [:]
    private var selectedIndexByTurn: [String: Int] = [:]

    public init() {}

    public static func turnKey(chatId: String, userMessageId: String) -> String {
        "\(chatId)::\(userMessageId)"
    }

    /// Saves a reply that is about to be replaced by regeneration, deduplicating by message id
    /// and resetting the selection to the newest (live) reply once it lands.
    public mutating func archiveBeforeRegenerate(
        chatId: String,
        userMessageId: String,
        reply: ChatReplyVariant
    ) {
        let key = Self.turnKey(chatId: chatId, userMessageId: userMessageId)
        var list = archivedByTurn[key] ?? []
        if !list.contains(where: { $0.id == reply.id }) {
            list.append(reply)
        }
        archivedByTurn[key] = list
        selectedIndexByTurn[key] = nil
    }

    /// Returns all variants in chronological order (archived tries followed by the current live reply)
    /// along with the active 0-based index.
    public func variants(
        chatId: String,
        userMessageId: String,
        liveReply: ChatReplyVariant
    ) -> (items: [ChatReplyVariant], activeIndex: Int) {
        let key = Self.turnKey(chatId: chatId, userMessageId: userMessageId)
        let archived = (archivedByTurn[key] ?? []).filter { $0.id != liveReply.id }
        let items = archived + [liveReply]
        let defaultIdx = items.count - 1
        let selected = selectedIndexByTurn[key] ?? defaultIdx
        let clamped = max(0, min(selected, items.count - 1))
        return (items, clamped)
    }

    public mutating func select(chatId: String, userMessageId: String, index: Int) {
        let key = Self.turnKey(chatId: chatId, userMessageId: userMessageId)
        selectedIndexByTurn[key] = max(0, index)
    }

    public mutating func clear(chatId: String) {
        let prefix = "\(chatId)::"
        archivedByTurn = archivedByTurn.filter { !$0.key.hasPrefix(prefix) }
        selectedIndexByTurn = selectedIndexByTurn.filter { !$0.key.hasPrefix(prefix) }
    }
}
