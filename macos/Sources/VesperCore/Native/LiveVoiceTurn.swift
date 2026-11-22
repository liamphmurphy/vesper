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

    /// How long a settled transcript (the transcriber has finalized everything heard) must stay
    /// unchanged before it's sent. The transcriber only finalizes at a natural break, so this can
    /// be short.
    public static let endOfSettledUtterance: TimeInterval = 0.7
    /// How long a transcript still ending in a volatile guess must stay unchanged: the person may
    /// only be pausing mid-thought.
    public static let endOfUtterance: TimeInterval = 1.2
    /// Delay before reopening the microphone after spoken playback ends, so speaker output buffers
    /// and room echo finish decaying before listening resumes.
    public static let speakerEchoCooldown: TimeInterval = 0.35
    /// Brief grace window when a turn ends with no new reply ID yet (e.g. session state refetched
    /// ahead of the message list), giving `companion.observe` time to start playback.
    public static let idleTurnCooldown: TimeInterval = 0.45
    /// Brief grace window when a silent/unvoiced reply lands so `companion.observe` can claim the
    /// reply before the microphone opens.
    public static let silentReplyCooldown: TimeInterval = 0.15

    public private(set) var phase: Phase = .listening
    /// Cooldown to wait before opening the microphone after the last transition into `.listening`.
    public private(set) var resumeCooldown: TimeInterval = 0
    /// The latest reply when the utterance was sent; a different one is the answer.
    private var replyAtSend: String?
    /// Most recent `lastReplyId` observed in `send` or `update`.
    private var latestReplyId: String?
    /// Reply ID that the person explicitly interrupted, so late updates from it stay `.listening`.
    private var interruptedReplyId: String?
    /// The turn has been seen running, revealing or speaking since the send.
    private var sawBusy = false

    public init() {}

    /// Whether the person has finished speaking: something was said and the transcript has stayed
    /// unchanged for long enough, less when it's `settled` (no volatile tail).
    public static func utteranceEnded(transcript: String, lastChange: Date, now: Date, settled: Bool) -> Bool {
        let silence = settled ? endOfSettledUtterance : endOfUtterance
        return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && now.timeIntervalSince(lastChange) >= silence
    }

    /// The person finished an utterance and it's being sent. `lastReplyId` is the chat's latest
    /// reply now, so the answer can be told apart from it.
    public mutating func send(lastReplyId: String?) {
        guard phase == .listening else { return }
        phase = .sending
        resumeCooldown = 0
        replyAtSend = lastReplyId
        latestReplyId = lastReplyId
        interruptedReplyId = nil
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
        resumeCooldown = 0
        phase = .listening
    }

    /// The person cut the answer short: listen again now.
    public mutating func interrupt() {
        resumeCooldown = 0
        interruptedReplyId = latestReplyId
        phase = .listening
    }

    /// Follows the chat after a send. Listening resumes once nothing is running, revealing or
    /// speaking and either an answer arrived or the turn was seen busy (a stopped or failed turn
    /// has no answer). Before then the turn has not visibly started, so keep waiting.
    public mutating func update(turnRunning: Bool, lastReplyId: String?, revealing: Bool, speaking: Bool) {
        latestReplyId = lastReplyId
        if phase == .listening {
            // If a non-interrupted reply begins revealing or speaking (e.g. a view update arrived
            // before companion observation started playback), pull straight back to `.replying`
            // so the microphone never stays open while the persona speaks.
            if (revealing || speaking), lastReplyId != interruptedReplyId {
                resumeCooldown = 0
                sawBusy = true
                phase = .replying
            }
            return
        }
        guard phase == .waiting || phase == .replying else { return }
        let prev = phase
        if turnRunning || revealing || speaking { sawBusy = true }
        let answered = lastReplyId != nil && lastReplyId != replyAtSend
        if !turnRunning && !revealing && !speaking && (answered || sawBusy) {
            if prev == .replying {
                resumeCooldown = Self.speakerEchoCooldown
            } else if answered {
                resumeCooldown = Self.silentReplyCooldown
            } else {
                resumeCooldown = Self.idleTurnCooldown
            }
            phase = .listening
        } else {
            resumeCooldown = 0
            phase = revealing || speaking ? .replying : .waiting
        }
    }
}
