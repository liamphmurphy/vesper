import XCTest
@testable import VesperCore

final class CompanionChatFilterTests: XCTestCase {
    func testListRequestUsesExplicitAllPersonaWhenUnfiltered() {
        let req = CompanionChatFilterLogic.listRequest(archived: false, personaId: "", spaceId: "")
        XCTAssertTrue(req.query.contains(URLQueryItem(name: "persona_id", value: "all")))
        XCTAssertTrue(req.query.contains(URLQueryItem(name: "archived", value: "false")))
        XCTAssertFalse(req.query.contains(where: { $0.name == "space" }))

        let scoped = CompanionChatFilterLogic.listRequest(archived: true, personaId: "p-1", spaceId: "s-2")
        XCTAssertTrue(scoped.query.contains(URLQueryItem(name: "persona_id", value: "p-1")))
        XCTAssertTrue(scoped.query.contains(URLQueryItem(name: "space", value: "s-2")))
        XCTAssertTrue(scoped.query.contains(URLQueryItem(name: "archived", value: "true")))
    }

    func testCleanSearchSnippetStripsHighlightMarkers() {
        let raw = "  Fix \u{E000}WebSocket\u{E001}\nreconnect loop  "
        XCTAssertEqual(CompanionChatFilterLogic.cleanSearchSnippet(raw), "Fix WebSocket reconnect loop")
    }

    func testLocalFilterMatchesTitlePersonaAndPreview() {
        let chats = [
            API.ChatSession(
                agent: API.AgentRef(colorIndex: 0, handle: "judy", id: "a1", name: "Judy"),
                archived: false,
                createdAt: "2026-11-28T00:00:00Z",
                harness: .claudeCode,
                id: "c1",
                messageCount: 1,
                model: "claude-opus",
                persona: API.PersonaSummary(color: "#6366f1", id: "p1", name: "Judy"),
                preview: "Refactor SQLite cache",
                revision: 1,
                state: .idle,
                title: "Storage tuning",
                unread: 0,
                updatedAt: "2026-11-28T00:00:00Z"
            ),
            API.ChatSession(
                agent: API.AgentRef(colorIndex: 1, handle: "elminster", id: "a2", name: "Elminster"),
                archived: false,
                createdAt: "2026-11-28T00:00:00Z",
                harness: .claudeCode,
                id: "c2",
                messageCount: 1,
                model: "claude-opus",
                persona: API.PersonaSummary(color: "#10b981", id: "p2", name: "Elminster"),
                preview: "Umbra boss encounter",
                revision: 1,
                state: .idle,
                title: "Campaign Prep",
                unread: 0,
                updatedAt: "2026-11-28T00:00:00Z"
            ),
        ]

        XCTAssertEqual(CompanionChatFilterLogic.localFilter(chats, query: "sqlite").map(\.id), ["c1"])
        XCTAssertEqual(CompanionChatFilterLogic.localFilter(chats, query: "elminster").map(\.id), ["c2"])
        XCTAssertEqual(CompanionChatFilterLogic.localFilter(chats, query: "").count, 2)
    }
}
