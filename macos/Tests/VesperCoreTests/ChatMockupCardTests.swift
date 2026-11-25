import XCTest
@testable import VesperCore

/// The ```mockup fence create_mockup hands a chat persona (agentapi `mockupCardFence`).
final class ChatMockupCardTests: XCTestCase {
    private let artifact = "0193a1c2-7d4e-7f00-8a11-2b3c4d5e6f70"
    private let version = "0193a1c2-7d4e-7f00-8a11-2b3c4d5e6f71"

    func testMockupFenceIsAnEmbed() {
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "mockup"), .mockup)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: " Mockup "), .mockup)
        XCTAssertFalse(EmbeddedBlockKind.mockup.isRenderedOnce)
        XCTAssertFalse(EmbeddedBlockKind.mockup.savesToLibrary)
    }

    func testParsesTheServersCard() {
        let body = "{\"artifact_id\":\"\(artifact)\",\"version_id\":\"\(version)\",\"title\":\"Checkout\"}"
        XCTAssertEqual(ChatMockupCard.parse(body), ChatMockupCard(artifactID: artifact, versionID: version, title: "Checkout"))
        // Whitespace around it, a missing title and upper-case ids are fine.
        XCTAssertEqual(ChatMockupCard.parse("\n  {\"version_id\":\"\(version.uppercased())\",\"artifact_id\":\"\(artifact)\"}\n"),
                       ChatMockupCard(artifactID: artifact, versionID: version, title: ""))
    }

    func testRefusesWhatIsNotACard() {
        XCTAssertNil(ChatMockupCard.parse(""))
        XCTAssertNil(ChatMockupCard.parse(artifact))
        XCTAssertNil(ChatMockupCard.parse("{\"artifact_id\":\"\(artifact)\"}"))
        // Ids go into API paths, so anything but a UUID is refused.
        XCTAssertNil(ChatMockupCard.parse("{\"artifact_id\":\"../inbox\",\"version_id\":\"\(version)\"}"))
        XCTAssertNil(ChatMockupCard.parse("{\"artifact_id\":\"\(artifact)\",\"version_id\":42}"))
    }

    func testStanding() {
        let versions: [(id: String, label: String, review: String?)] = [
            (id: "v2", label: "v2", review: "pending"), (id: "v1", label: "v1", review: "changes_requested"),
        ]
        XCTAssertEqual(ChatMockupCard.standing(cardVersionID: "v2", currentVersionID: "v2", versions: versions),
                       .current(label: "v2", review: .pending))
        XCTAssertEqual(ChatMockupCard.standing(cardVersionID: "v1", currentVersionID: "v2", versions: versions),
                       .superseded(label: "v1", currentLabel: "v2"))
        XCTAssertEqual(ChatMockupCard.standing(cardVersionID: "v9", currentVersionID: "v2", versions: versions), .missing)
        let decided: [(id: String, label: String, review: String?)] = [(id: "v1", label: "v1", review: "approved")]
        XCTAssertEqual(ChatMockupCard.standing(cardVersionID: "v1", currentVersionID: "v1", versions: decided),
                       .current(label: "v1", review: .approved))
        // A version with no review yet is waiting for one.
        let fresh: [(id: String, label: String, review: String?)] = [(id: "v1", label: "v1", review: nil)]
        XCTAssertEqual(ChatMockupCard.standing(cardVersionID: "v1", currentVersionID: "v1", versions: fresh),
                       .current(label: "v1", review: .pending))
    }

    func testReviewPillAndNoteRule() {
        XCTAssertEqual(ChatMockupCard.Review.pending.pill.label, "Awaiting review")
        XCTAssertEqual(ChatMockupCard.Review.approved.pill.tone, "done")
        XCTAssertEqual(ChatMockupCard.Review.changesRequested.pill.tone, "human")
        XCTAssertFalse(ChatMockupCard.Review.pending.isDecided)
        XCTAssertTrue(ChatMockupCard.Review.changesRequested.isDecided)
        XCTAssertTrue(ChatMockupCard.canSend(changesRequested: false, note: ""))
        XCTAssertFalse(ChatMockupCard.canSend(changesRequested: true, note: "  \n"))
        XCTAssertTrue(ChatMockupCard.canSend(changesRequested: true, note: "Bigger button"))
    }
}
