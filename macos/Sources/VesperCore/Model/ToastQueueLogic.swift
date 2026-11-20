import Foundation

public struct ToastItemModel: Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var description: String?
    public var tone: ToastTone
    public var actionLabel: String?
    public var durationMs: Int

    public init(id: String, title: String, description: String? = nil, tone: ToastTone = .neutral,
                actionLabel: String? = nil, durationMs: Int = 4500) {
        self.id = id
        self.title = title
        self.description = description
        self.tone = tone
        self.actionLabel = actionLabel
        self.durationMs = durationMs
    }
}

/// Pure bounded queue logic for window-level native toast HUD pills.
public enum ToastQueueLogic: Sendable {
    public static let maxVisible = 3

    /// Inserts or updates a toast by `id`, returning the bounded visible list and any evicted oldest items.
    public static func upsert(
        _ item: ToastItemModel,
        into existing: [ToastItemModel],
        maxVisible: Int = maxVisible
    ) -> (visible: [ToastItemModel], evicted: [ToastItemModel]) {
        let limit = max(1, maxVisible)
        var updated: [ToastItemModel]
        if let index = existing.firstIndex(where: { $0.id == item.id }) {
            updated = existing
            updated[index] = item
        } else {
            updated = existing + [item]
        }
        var evicted: [ToastItemModel] = []
        if updated.count > limit {
            let overflow = updated.count - limit
            evicted = Array(updated.prefix(overflow))
            updated.removeFirst(overflow)
        }
        return (updated, evicted)
    }

    public static func remove(id: String, from existing: [ToastItemModel]) -> (visible: [ToastItemModel], removed: ToastItemModel?) {
        guard let index = existing.firstIndex(where: { $0.id == id }) else {
            return (existing, nil)
        }
        var next = existing
        let removed = next.remove(at: index)
        return (next, removed)
    }
}
