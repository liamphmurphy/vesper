import XCTest
@testable import VesperCore

/// Mirrors `placePushRequests` in web/lib/code-review.test.mjs; keep the cases in step.
final class ChatPushPlacementTests: XCTestCase {
    private struct Message: ChatPushAnchorMessage {
        var id: String
        var role: String
        var createdAt: String
        var runId: String? = nil
        var turnSeq: Int? = nil
        var isUser: Bool { role == "user" }
        var isAssistant: Bool { role == "assistant" }
    }

    private struct Push: ChatPlaceablePush {
        var id: String
        var stateRaw = "pending"
        var error: String? = nil
        var createdAt = "2026-11-15T10:00:30Z"
        var runId: String? = "r1"
        var messageId: String? = nil
    }

    private let messages = [
        Message(id: "m1", role: "user", createdAt: "2026-11-15T10:00:00Z"),
        Message(id: "m2", role: "assistant", createdAt: "2026-11-15T10:00:05Z", runId: "r1", turnSeq: 1),
        Message(id: "m3", role: "assistant", createdAt: "2026-11-15T10:01:00Z", runId: "r1", turnSeq: 1),
        Message(id: "m4", role: "user", createdAt: "2026-11-15T10:02:00Z"),
        Message(id: "m5", role: "assistant", createdAt: "2026-11-15T10:03:00Z", runId: "r1", turnSeq: 2),
        Message(id: "m6", role: "user", createdAt: "2026-11-15T10:04:00Z"),
        Message(id: "m7", role: "user", createdAt: "2026-11-15T10:05:00Z"),
    ]

    func testAnchorsLinkedLiveAndLegacyCardsToTheirTurns() {
        let placed = ChatPushPlacement.place(
            [
                Push(id: "linked-t1", stateRaw: "pushed", createdAt: "2026-11-15T10:00:40Z", messageId: "m3"),
                Push(id: "linked-t2", createdAt: "2026-11-15T10:02:30Z", messageId: "m5"),
                Push(id: "declined-clean", stateRaw: "declined", messageId: "m3"),
                Push(id: "declined-err", stateRaw: "declined", error: "Replaced by newer request", messageId: "m5"),
                Push(id: "legacy-t1", stateRaw: "pushed", createdAt: "2026-11-15T10:00:20Z"),
                Push(id: "legacy-between-users", stateRaw: "failed", createdAt: "2026-11-15T10:04:30Z"),
                Push(id: "legacy-first", stateRaw: "pushed", createdAt: "2026-11-15T09:59:00Z"),
                Push(id: "live-staging", stateRaw: "staging", createdAt: "2026-11-15T10:05:10Z"),
                Push(id: "older-window", stateRaw: "pushed", createdAt: "2026-11-15T09:00:00Z", messageId: "m0"),
            ],
            messages: messages, running: true, currentRunId: "r1", hasMore: true
        )

        XCTAssertEqual(placed.byMessage["m3"]?.map(\.id), ["linked-t1", "legacy-t1"])
        XCTAssertEqual(placed.byMessage["m5"]?.map(\.id), ["linked-t2", "declined-err"])
        XCTAssertEqual(placed.afterMessage["m6"]?.map(\.id), ["legacy-between-users"])
        XCTAssertEqual(placed.leading.map(\.id), ["legacy-first"])
        XCTAssertEqual(placed.live.map(\.id), ["live-staging"])
        XCTAssertEqual(placed.trailing.map(\.id), [])
    }

    func testUnlinkedRequestAfterLastMessageTrailsWhenIdle() {
        let placed = ChatPushPlacement.place(
            [Push(id: "unlinked-end", createdAt: "2026-11-15T10:05:10Z")],
            messages: messages, running: false, currentRunId: "r1", hasMore: false
        )
        XCTAssertEqual(placed.trailing.map(\.id), ["unlinked-end"])
        XCTAssertEqual(placed.live.map(\.id), [])
    }
}
