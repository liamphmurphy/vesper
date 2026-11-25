import Foundation

/// A ```mockup fence: one version of a mockup a persona made in the chat (agentapi `MockupCard`, the
/// `card` create_mockup returns), drawn natively with Approve and Request changes.
public struct ChatMockupCard: Sendable, Equatable {
    public var artifactID: String
    public var versionID: String
    public var title: String

    public init(artifactID: String, versionID: String, title: String) {
        self.artifactID = artifactID
        self.versionID = versionID
        self.title = title
    }

    private struct Body: Decodable {
        var artifact_id: String
        var version_id: String
        var title: String?
    }

    /// The card a fence body names, or nil when it isn't one: JSON with an `artifact_id` and a
    /// `version_id` that are UUIDs (a persona types the fence, so its ids go into API paths only
    /// once they're known to be ids). The title is optional.
    public static func parse(_ body: String) -> ChatMockupCard? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = try? JSONDecoder().decode(Body.self, from: Data(trimmed.utf8)),
              let artifact = UUID(uuidString: decoded.artifact_id),
              let version = UUID(uuidString: decoded.version_id) else { return nil }
        return ChatMockupCard(
            artifactID: artifact.uuidString.lowercased(),
            versionID: version.uuidString.lowercased(),
            title: (decoded.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Where the card's version stands, from the artifact's versions as (id, label, review state) and
    /// the current version's id.
    public static func standing(
        cardVersionID: String,
        currentVersionID: String,
        versions: [(id: String, label: String, review: String?)]
    ) -> Standing {
        let current = versions.first { $0.id == currentVersionID }
        guard let shown = versions.first(where: { $0.id == cardVersionID }) else { return .missing }
        if cardVersionID != currentVersionID {
            return .superseded(label: shown.label, currentLabel: current?.label ?? "")
        }
        return .current(label: shown.label, review: Review(state: shown.review))
    }

    public enum Standing: Equatable, Sendable {
        /// The card's version is the mockup's current one, so it can be decided here.
        case current(label: String, review: Review)
        /// A newer version exists: the server only takes a review of the current one.
        case superseded(label: String, currentLabel: String)
        /// The version isn't one of the mockup's (a mistyped fence).
        case missing
    }

    public enum Review: Equatable, Sendable {
        case pending, approved, changesRequested

        init(state: String?) {
            switch state {
            case "approved": self = .approved
            case "changes_requested": self = .changesRequested
            default: self = .pending
            }
        }

        public var isDecided: Bool { self != .pending }

        /// The status pill: its text and its `TonePill` tone, as the review screen colours versions.
        public var pill: (label: String, tone: String) {
            switch self {
            case .pending: ("Awaiting review", "review")
            case .approved: ("Approved", "done")
            case .changesRequested: ("Changes requested", "human")
            }
        }
    }

    /// Whether a decision can be sent: changes need a note saying what should change (the server
    /// refuses them without one), an approval doesn't.
    public static func canSend(changesRequested: Bool, note: String) -> Bool {
        !changesRequested || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
