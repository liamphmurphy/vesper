import Foundation

/// What aside placement needs from a chat session; `API.ChatSession` conforms.
public protocol ChatAsideLike {
    var createdAt: String { get }
    var anchorMessageId: String? { get }
    var secondOpinion: Bool? { get }
}

extension API.ChatSession: ChatAsideLike {}

/// What an aside card needs from one of its messages; `API.ChatMessage` conforms.
public protocol ChatAsideMessageLike {
    var roleName: String { get }
    var bodyMd: String { get }
}

extension API.ChatMessage: ChatAsideMessageLike {
    public var roleName: String { role.rawValue }
}

/// The text an aside card shows: the question, and its answer, failure or progress.
public struct ChatAsideContent: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case answered(String)
        case failed(String)
        case answering
        case stopped
    }

    public var question: String
    public var status: Status
}

/// Asides under the chat's replies (`asidesInWindow` and `asides.tsx` in web).
public enum ChatAsideLogic {
    /// The generic asides asked between `since` and `until` (open-ended when nil). Threads and
    /// second opinions belong to their anchor or card, not the turn's aside rail.
    public static func asidesInWindow<A: ChatAsideLike>(_ asides: [A], since: String?, until: String?) -> [A] {
        guard !asides.isEmpty, let since, let from = APIDate.parse(since) else { return [] }
        let to = until.flatMap(APIDate.parse) ?? .distantFuture
        return asides.filter { aside in
            if aside.anchorMessageId != nil || aside.secondOpinion == true { return false }
            guard let at = APIDate.parse(aside.createdAt) else { return false }
            return at >= from && at < to
        }
    }

    /// Asides grouped under each finished reply. The last reply's window stays open while the
    /// next turn runs, so that turn's asides show live below its status card instead.
    public static func asidesByReply<A: ChatAsideLike>(
        _ asides: [A],
        turnWindows: [String: ChatTurnWindow],
        running: Bool,
        runningSince: String?
    ) -> [String: [A]] {
        guard !asides.isEmpty else { return [:] }
        var out: [String: [A]] = [:]
        for (replyId, window) in turnWindows {
            let asked = asidesInWindow(asides, since: window.since, until: window.until ?? (running ? runningSince : nil))
            if !asked.isEmpty { out[replyId] = asked }
        }
        return out
    }

    /// "2 asides", "1 aside".
    public static func countLabel(_ n: Int) -> String {
        "\(n) aside\(n == 1 ? "" : "s")"
    }

    /// The card's question and answer from the aside's own messages, falling back to its title
    /// ("Aside: …") before they load.
    public static func content<M: ChatAsideMessageLike>(
        messages: [M],
        title: String,
        running: Bool,
        failed: Bool,
        error: String?
    ) -> ChatAsideContent {
        let question = messages.first(where: { $0.roleName == "user" })?.bodyMd
            ?? (title.hasPrefix("Aside: ") ? String(title.dropFirst("Aside: ".count)) : title)
        let status: ChatAsideContent.Status
        if let answer = messages.last(where: { $0.roleName == "assistant" }) {
            status = .answered(answer.bodyMd)
        } else if failed {
            let reason = messages.last(where: { $0.roleName == "system" })?.bodyMd
                ?? (error?.isEmpty == false ? error : nil)
                ?? "The aside couldn\u{2019}t answer."
            status = .failed(reason)
        } else if running {
            status = .answering
        } else {
            status = .stopped
        }
        return ChatAsideContent(question: question, status: status)
    }
}
