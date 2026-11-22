import Foundation

/// Turn-taking for Live Voice: the person speaks, a pause sends what they said, the persona works
/// and answers, and listening resumes once the answer has finished revealing and speaking. The
/// microphone is closed from the send until then, so the persona never hears itself.
public struct LiveVoiceTurn: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The microphone is open for the person's next utterance.
        case listening
        /// An utterance is on its way to the chat.
        case sending
        /// Sent; the turn hasn't produced an answer yet.
        case waiting
        /// The answer is revealing or being spoken.
        case replying
    }

    /// How long the transcript must stay unchanged after speech before it's sent.
    public static let endOfUtterance: TimeInterval = 1.6

    public private(set) var phase: Phase = .listening
    /// The latest reply when the utterance was sent; a different one is the answer.
    private var replyAtSend: String?
    /// The turn has been seen running, revealing or speaking since the send.
    private var sawBusy = false

    public init() {}

    /// Whether the transcript has settled long enough after speech to send it.
    public static func utteranceEnded(transcript: String, lastChange: Date, now: Date, silence: TimeInterval = endOfUtterance) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && now.timeIntervalSince(lastChange) >= silence
    }

    /// The person finished an utterance and it's being sent. `lastReplyId` is the chat's latest
    /// reply now, so the answer can be told apart from it.
    public mutating func send(lastReplyId: String?) {
        guard phase == .listening else { return }
        phase = .sending
        replyAtSend = lastReplyId
        sawBusy = false
    }

    /// The chat accepted the utterance.
    public mutating func sent() {
        guard phase == .sending else { return }
        phase = .waiting
    }

    /// The chat refused the utterance, so listen again.
    public mutating func sendFailed() {
        guard phase == .sending else { return }
        phase = .listening
    }

    /// The person cut the answer short: listen again now.
    public mutating func interrupt() {
        phase = .listening
    }

    /// Follows the chat after a send. Listening resumes once nothing is running, revealing or
    /// speaking and either an answer arrived or the turn was seen busy (a stopped or failed turn
    /// has no answer). Before then the turn has not visibly started, so keep waiting.
    public mutating func update(turnRunning: Bool, lastReplyId: String?, revealing: Bool, speaking: Bool) {
        guard phase == .waiting || phase == .replying else { return }
        if turnRunning || revealing || speaking { sawBusy = true }
        let answered = lastReplyId != nil && lastReplyId != replyAtSend
        if !turnRunning && !revealing && !speaking && (answered || sawBusy) {
            phase = .listening
        } else {
            phase = revealing || speaking ? .replying : .waiting
        }
    }
}
