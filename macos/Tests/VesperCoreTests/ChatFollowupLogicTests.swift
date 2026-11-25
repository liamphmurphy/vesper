import XCTest
@testable import VesperCore

final class ChatFollowupLogicTests: XCTestCase {
    func testIsHeldReflectsRunningFailedAndStoppedStates() {
        XCTAssertFalse(ChatFollowupLogic.isHeld(state: .running, lastMessageRole: .user))
        XCTAssertFalse(ChatFollowupLogic.isHeld(state: .running, lastMessageRole: nil))
        XCTAssertTrue(ChatFollowupLogic.isHeld(state: .failed, lastMessageRole: .assistant))
        XCTAssertTrue(ChatFollowupLogic.isHeld(state: .failed, lastMessageRole: .user))
        XCTAssertTrue(ChatFollowupLogic.isHeld(state: .idle, lastMessageRole: .user))
        XCTAssertTrue(ChatFollowupLogic.isHeld(state: .idle, lastMessageRole: .system))
        XCTAssertTrue(ChatFollowupLogic.isHeld(state: .idle, lastMessageRole: nil))
        XCTAssertFalse(ChatFollowupLogic.isHeld(state: .idle, lastMessageRole: .assistant))
    }

    func testHeaderCopyMatchesRunningHeldAndIdleStates() {
        XCTAssertEqual(
            ChatFollowupLogic.header(speakerName: "Judy", running: true, held: false),
            "Queued \u{00B7} sends when Judy finishes, in order"
        )
        XCTAssertEqual(
            ChatFollowupLogic.header(speakerName: "Judy", running: false, held: true),
            "Held \u{00B7} Judy stopped, so these wait for you"
        )
        XCTAssertEqual(
            ChatFollowupLogic.header(speakerName: "Judy", running: false, held: false),
            "Queued \u{00B7} sends after Judy\u{2019}s next reply"
        )
    }

    func testSendNowTooltipDiffersWhileRunning() {
        XCTAssertEqual(
            ChatFollowupLogic.sendNowTooltip(speakerName: "Judy", running: true),
            "Stop Judy and send this now"
        )
        XCTAssertEqual(
            ChatFollowupLogic.sendNowTooltip(speakerName: "Judy", running: false),
            "Send this now"
        )
    }

    func testDisplayBodyAndPreviewStripDockedContextAndCollapseNewlines() {
        let raw = "First line\n\nSecond line\n\n<!-- vesper:knowledge-context -->\nViewing: Notes/Plan.md"
        XCTAssertEqual(ChatFollowupLogic.displayBody(raw), "First line\n\nSecond line")
        XCTAssertEqual(ChatFollowupLogic.previewText(raw), "First line Second line")
    }

    func testMergeIntoDraftPrependsEditedFollowupAheadOfCurrentDraft() {
        let raw = "Queued question\n\n<!-- vesper:custom-app-context -->\nApp: tracker"
        XCTAssertEqual(ChatFollowupLogic.mergeIntoDraft(raw, existingDraft: ""), "Queued question")
        XCTAssertEqual(ChatFollowupLogic.mergeIntoDraft(raw, existingDraft: "   \n "), "Queued question")
        XCTAssertEqual(
            ChatFollowupLogic.mergeIntoDraft(raw, existingDraft: "Newer thought"),
            "Queued question\n\nNewer thought"
        )
    }

    func testAppendingMaintainsOrderAndDeduplicates() {
        let first = API.ChatFollowup(body: "One", createdAt: "2026-11-25T00:00:01Z", id: "f1")
        let second = API.ChatFollowup(body: "Two", createdAt: "2026-11-25T00:00:02Z", id: "f2")

        let afterFirst = ChatFollowupLogic.appending(first, to: nil)
        XCTAssertEqual(afterFirst.followups, [first])

        let dup = ChatFollowupLogic.appending(first, to: afterFirst)
        XCTAssertEqual(dup.followups, [first])

        let afterSecond = ChatFollowupLogic.appending(second, to: dup)
        XCTAssertEqual(afterSecond.followups, [first, second])
    }

    private final class FollowupsStub: @unchecked Sendable {
        private let lock = NSLock()
        private var followups: [[String: String]] = []
        private var listHits = 0
        private var deleteStatus = 204

        func setFollowups(_ next: [[String: String]]) {
            lock.withLock { followups = next }
        }

        func setDeleteStatus(_ status: Int) {
            lock.withLock { deleteStatus = status }
        }

        func hits() -> Int {
            lock.withLock { listHits }
        }

        var client: APIClient {
            APIClient(baseURL: URL(string: "http://localhost:8080")!, sessionToken: "tok") { [self] request in
                let path = request.url!.path
                let method = request.httpMethod ?? "GET"
                let (status, payload): (Int, Any?) = lock.withLock {
                    if path == "/api/v1/chats/c1/followups" && method == "GET" {
                        listHits += 1
                        return (200, ["followups": followups])
                    }
                    if path.hasPrefix("/api/v1/chats/c1/followups/") && method == "DELETE" {
                        if deleteStatus == 204 {
                            let id = String(path.split(separator: "/").last ?? "")
                            followups.removeAll { $0["id"] == id }
                            return (204, nil)
                        }
                        return (deleteStatus, ["message": "delete failed"])
                    }
                    return (404, ["message": "not found"])
                }
                let data = try payload.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    @MainActor
    func testFollowupsQueryInvalidatesOnChatUpdatedAndSupportsOptimisticDelete() async throws {
        let stub = FollowupsStub()
        let store = QueryStore(client: stub.client, staleAfter: 60)
        let req = API.listChatFollowups(id: "c1")
        store.observe(req)
        let entry = store.load(req)
        while let task = entry.task { await task.value }
        XCTAssertEqual(entry.data?.followups, [])

        // Simulate queueing a message and receiving chat.updated SSE hint.
        stub.setFollowups([
            ["id": "f1", "body": "Follow up after this", "created_at": "2026-11-25T00:00:01Z"],
            ["id": "f2", "body": "Second queued message", "created_at": "2026-11-25T00:00:02Z"],
        ])
        store.handle(ServerEvent(type: "chat.updated", ids: ["c1"]))
        while let task = entry.task { await task.value }
        XCTAssertEqual(entry.data?.followups.map(\.id), ["f1", "f2"])
        XCTAssertEqual(stub.hits(), 2)

        // Optimistic delete removes immediately and reconciles with one server refetch.
        let optimistic = OptimisticUpdate.update(req) { list in
            list.followups.removeAll { $0.id == "f1" }
        }
        _ = try await store.mutate(
            API.deleteChatFollowup(id: "c1", followupId: "f1"),
            optimistic: [optimistic]
        )
        while let task = entry.task { await task.value }
        XCTAssertEqual(entry.data?.followups.map(\.id), ["f2"])
        XCTAssertEqual(stub.hits(), 3)

        // Failed delete rolls back optimistic removal.
        stub.setDeleteStatus(500)
        let rollbackOptimistic = OptimisticUpdate.update(req) { list in
            list.followups.removeAll { $0.id == "f2" }
        }
        do {
            _ = try await store.mutate(
                API.deleteChatFollowup(id: "c1", followupId: "f2"),
                optimistic: [rollbackOptimistic]
            )
            XCTFail("expected delete to fail")
        } catch {
            XCTAssertEqual(entry.data?.followups.map(\.id), ["f2"])
        }

        // Simulate server draining the remaining follow-up and invalidating via chats resource.
        stub.setFollowups([])
        store.invalidate(QueryInvalidation(resources: ["chats"]))
        while let task = entry.task { await task.value }
        XCTAssertEqual(entry.data?.followups, [])

        store.stopObserving(req.key)
    }
}
