import Foundation

// MARK: - Push Request Placement (`web/lib/code-review.ts` placePushRequests)

/// What placement needs from a push request.
public protocol ChatPlaceablePush {
    var id: String { get }
    var stateRaw: String { get }
    var error: String? { get }
    var createdAt: String { get }
    var runId: String? { get }
    var messageId: String? { get }
}

/// What placement needs from a chat message.
public protocol ChatPushAnchorMessage {
    var id: String { get }
    var isUser: Bool { get }
    var isAssistant: Bool { get }
    var createdAt: String { get }
    var runId: String? { get }
    var turnSeq: Int? { get }
}

extension API.PushRequest: ChatPlaceablePush {
    public var stateRaw: String { state.rawValue }
}

extension API.ChatMessage: ChatPushAnchorMessage {
    public var isUser: Bool { role == .user }
    public var isAssistant: Bool { role.rawValue == "assistant" }
}

/// Where each push request card sits in the transcript.
public struct ChatPlacedPushRequests<P: ChatPlaceablePush> {
    /// Shown under the message with this id: the turn that asked for the push.
    public var byMessage: [String: [P]] = [:]
    /// Shown right after this user message, for unlinked requests between two user messages.
    public var afterMessage: [String: [P]] = [:]
    /// Before the first loaded message.
    public var leading: [P] = []
    /// After the last message, for unlinked requests the running turn hasn't replied to yet.
    public var trailing: [P] = []
    /// With the running turn's live activity.
    public var live: [P] = []

    public init() {}
}

public enum ChatPushPlacement {
    /// Anchors each shown push request to its place in the chat log so open, pushed and failed
    /// cards stay with the turn that requested them instead of stacking at the bottom.
    public static func place<P: ChatPlaceablePush, M: ChatPushAnchorMessage>(
        _ requests: [P],
        messages: [M],
        running: Bool,
        currentRunId: String?,
        hasMore: Bool
    ) -> ChatPlacedPushRequests<P> {
        var placed = ChatPlacedPushRequests<P>()

        // Decided cards stay as a record only when they say something: a pull request, or why not.
        let shown = requests.filter { $0.stateRaw != "declined" || !($0.error ?? "").isEmpty }
        guard !shown.isEmpty else { return placed }

        let messageIds = Set(messages.map(\.id))
        let messageDates = messages.map { date($0.createdAt) }
        let firstAt = messageDates.first ?? nil
        let lastAt = messageDates.last ?? nil

        for request in shown {
            if let messageId = request.messageId, messageIds.contains(messageId) {
                placed.byMessage[messageId, default: []].append(request)
                continue
            }

            let requestAt = date(request.createdAt)
            // When earlier messages aren't loaded yet, requests linked before the window stay hidden with them.
            if request.messageId != nil, hasMore, let firstAt, let requestAt, requestAt < firstAt {
                continue
            }

            // Only an unlinked request of the active turn is live: a chat reuses current_run_id
            // across turns, so it must also come after the last message.
            let afterLast: Bool
            if let lastAt, !messages.isEmpty {
                afterLast = requestAt.map { $0 >= lastAt } ?? false
            } else {
                afterLast = true
            }
            if request.messageId == nil, running, request.runId == nil || request.runId == currentRunId, afterLast {
                placed.live.append(request)
                continue
            }

            // Legacy rows (and requests in the brief turn-end refetch gap) fall back to creation time.
            guard let requestAt,
                  let idx = messageDates.firstIndex(where: { $0.map { $0 >= requestAt } ?? false })
            else {
                placed.trailing.append(request)
                continue
            }
            let anchor = messages[idx]
            if !anchor.isUser {
                // Opening lines share a turn with the final reply; attach to the turn's last assistant message.
                var end = idx
                while anchor.isAssistant, let runId = anchor.runId, end + 1 < messages.count,
                      messages[end + 1].isAssistant, messages[end + 1].runId == runId,
                      messages[end + 1].turnSeq == anchor.turnSeq {
                    end += 1
                }
                placed.byMessage[messages[end].id, default: []].append(request)
                continue
            }
            if idx == 0 {
                placed.leading.append(request)
            } else if !messages[idx - 1].isUser {
                placed.byMessage[messages[idx - 1].id, default: []].append(request)
            } else {
                placed.afterMessage[messages[idx - 1].id, default: []].append(request)
            }
        }
        return placed
    }

    private static func date(_ raw: String) -> Date? {
        let date = parseISODate(raw)
        return date == .distantPast ? nil : date
    }
}
