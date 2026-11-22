import XCTest
@testable import VesperCore

final class ChatInspectorLogicTests: XCTestCase {
    private func sampleSession(
        id: String = "chat-1",
        state: API.ChatState = .idle,
        repoUrl: String? = nil,
        autoModel: Bool? = nil,
        effort: API.ChatEffort? = nil
    ) -> API.ChatSession {
        API.ChatSession(
            agent: API.AgentRef(colorIndex: 0, handle: "meow", id: "a1", name: "Meow"),
            archived: false,
            autoModel: autoModel,
            createdAt: "2026-11-22T00:00:00Z",
            effort: effort,
            harness: API.Harness(rawValue: "claude-code"),
            id: id,
            messageCount: 2,
            model: "claude-sonnet",
            repoUrl: repoUrl,
            revision: 1,
            state: state,
            title: "Fix right rail",
            unread: 0,
            updatedAt: "2026-11-22T00:01:00Z"
        )
    }

    private func sampleMessage(
        id: String,
        role: API.ChatMessage.Role,
        body: String,
        seq: Int,
        costUsd: Double? = nil,
        codeChanges: [API.ChatCodeChange]? = nil
    ) -> API.ChatMessage {
        API.ChatMessage(
            bodyMd: body,
            codeChanges: codeChanges,
            costUsd: costUsd,
            createdAt: "2026-11-22T00:00:00Z",
            id: id,
            role: role,
            seq: seq
        )
    }

    func testLandingChatHasEmptyInspectorTabs() {
        let model = ChatInspectorLogic.buildInspectorModel(ChatInspectorLogic.Input(chatId: nil))
        XCTAssertEqual(model.id, ChatInspectorLogic.landingModelId)
        XCTAssertFalse(model.open)
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testActiveChatAlwaysHasActivityAndConditionallyAddsCodePlaygroundCanvasesAndThread() {
        let session = sampleSession(
            state: .running,
            repoUrl: "https://github.com/liamphmurphy/Vesper.git",
            autoModel: true,
            effort: .high
        )
        let messages = [
            sampleMessage(id: "u1", role: .user, body: "Inspect the right rail\n\n<!-- vesper:work-context -->\nViewing ticket LAZYAGENTS-1", seq: 1),
            sampleMessage(id: "a1", role: .assistant, body: "Found the root cause.", seq: 2, costUsd: 0.04),
        ]
        let codeReview = API.CodeReview(
            commits: [],
            dirty: true,
            files: [
                API.ChatCodeChange(additions: 10, binary: false, deletions: 2, path: "foo.swift", status: .modified, truncated: false),
            ],
            live: true,
            repository: "https://github.com/liamphmurphy/Vesper",
            updatedAt: "2026-11-22T00:01:00Z"
        )
        let playground = API.Playground(
            branch: "feat/test",
            chatId: "chat-1",
            errorLog: "",
            id: "pg-1",
            openapi: "",
            openapiCommit: "",
            openapiInferred: false,
            processes: [],
            routes: [],
            services: [],
            state: .starting,
            step: "Building",
            stopReason: "",
            updatedAt: "2026-11-22T00:01:00Z"
        )
        let canvases = [
            API.ChatCanvasSummary(createdAt: "2026-11-22T00:00:00Z", id: "des-1", kind: .design, seq: 1, title: "Mockup", updatedAt: "2026-11-22T00:00:00Z"),
            API.ChatCanvasSummary(createdAt: "2026-11-22T00:00:00Z", id: "can-1", kind: .text, seq: 1, title: "Notes", updatedAt: "2026-11-22T00:00:00Z"),
        ]
        let liveActivity = ChatTurnActivity(
            status: ChatStatusInfo(kind: .searchingCode, phrase: "searching the code"),
            steps: [
                ChatTurnStep(key: "1", title: "Reading the code", state: .done),
                ChatTurnStep(key: "2", title: "Searching the code", state: .active),
            ],
            elapsedMs: 12_000
        )

        let model = ChatInspectorLogic.buildInspectorModel(ChatInspectorLogic.Input(
            chatId: "chat-1",
            session: session,
            messages: messages,
            codeReviews: [codeReview],
            playgroundState: API.ChatPlaygroundState(playground: playground, savedSpec: false),
            canvases: canvases,
            liveActivity: liveActivity,
            open: true,
            activeTabId: ChatInspectorLogic.codeTabId,
            threadMessageId: "a1"
        ))

        XCTAssertEqual(model.tabs.map(\.id), ["design", "canvas", "playground", "code", "thread", "activity"])
        XCTAssertEqual(model.activeTabId, "code")

        let codeTab = model.tabs.first { $0.id == "code" }
        XCTAssertEqual(codeTab?.kind, .panel)
        XCTAssertEqual(codeTab?.width, .wide)
        XCTAssertEqual(codeTab?.busy, true)
        XCTAssertEqual(codeTab?.badge?.text, "1")
        XCTAssertEqual(codeTab?.panel?.kind, "chat.code")
        XCTAssertEqual(codeTab?.panel?.key, "chat.code:chat-1")

        let pgTab = model.tabs.first { $0.id == "playground" }
        XCTAssertEqual(pgTab?.label, "Playground (starting)")
        XCTAssertEqual(pgTab?.busy, true)
        XCTAssertEqual(pgTab?.panel?.kind, "chat.playground")

        let threadTab = model.tabs.first { $0.id == "thread" }
        XCTAssertEqual(threadTab?.kind, .native)
        XCTAssertNil(threadTab?.panel)

        let activityTab = model.tabs.first { $0.id == "activity" }
        XCTAssertEqual(activityTab?.kind, .native)
        XCTAssertEqual(activityTab?.busy, true)
        XCTAssertEqual(activityTab?.sections?.map(\.id), ["summary", "live", "turns"])
        let summaryFacts = activityTab?.sections?.first?.items ?? []
        XCTAssertTrue(summaryFacts.contains(where: { $0.id == "repo" && $0.value == "liamphmurphy/Vesper" }))
        let liveSteps = activityTab?.sections?[1].items.first(where: { $0.id == "live_steps" })?.steps ?? []
        XCTAssertEqual(liveSteps.map(\.state), [.done, .current])
        let turnRow = activityTab?.sections?[2].items.first?.rows?.first
        XCTAssertEqual(turnRow?.id, "a1")
        XCTAssertEqual(turnRow?.title, "Inspect the right rail")
    }

    func testPlainChatOnlyShowsActivityTabAndFallsBackWhenSelectedTabDisappears() {
        let model = ChatInspectorLogic.buildInspectorModel(ChatInspectorLogic.Input(
            chatId: "chat-2",
            session: sampleSession(id: "chat-2"),
            open: false,
            activeTabId: ChatInspectorLogic.codeTabId
        ))
        XCTAssertEqual(model.tabs.map(\.id), ["activity"])
        XCTAssertEqual(model.activeTabId, "activity")
    }
}
