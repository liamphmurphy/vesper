import XCTest
@testable import VesperCore

final class ChatKeyboardAndExportTests: XCTestCase {
    private func makeMessage(
        id: String,
        seq: Int,
        role: API.ChatMessage.Role,
        body: String,
        runId: String? = nil,
        model: String? = nil
    ) -> API.ChatMessage {
        API.ChatMessage(
            bodyMd: body,
            createdAt: "2026-11-28T00:00:0\(seq)Z",
            id: id,
            model: model,
            role: role,
            runId: runId,
            seq: seq
        )
    }

    private func makeSession(title: String = "Architecture Review") -> API.ChatSession {
        API.ChatSession(
            agent: API.AgentRef(colorIndex: 0, handle: "judy", id: "a1", name: "Judy"),
            archived: false,
            createdAt: "2026-11-28T00:00:00Z",
            harness: .claudeCode,
            id: "chat-1",
            messageCount: 2,
            model: "claude-opus",
            persona: API.PersonaSummary(color: "#6366f1", id: "p1", name: "Judy"),
            revision: 1,
            state: .idle,
            title: title,
            unread: 0,
            updatedAt: "2026-11-28T00:00:00Z"
        )
    }

    func testKeyboardShortcutResolution() {
        XCTAssertEqual(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: ChatKeyboardNavLogic.upArrowKeyCode,
                charactersIgnoringModifiers: nil,
                command: false, shift: false, option: true, control: false
            ),
            .jumpPreviousTurn
        )
        XCTAssertEqual(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: ChatKeyboardNavLogic.downArrowKeyCode,
                charactersIgnoringModifiers: nil,
                command: false, shift: false, option: true, control: false
            ),
            .jumpNextTurn
        )
        XCTAssertEqual(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: 8,
                charactersIgnoringModifiers: "C",
                command: true, shift: true, option: false, control: false
            ),
            .copyLastReply
        )
        XCTAssertEqual(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: 31,
                charactersIgnoringModifiers: "o",
                command: true, shift: true, option: false, control: false
            ),
            .toggleOutline
        )
        XCTAssertEqual(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: 40,
                charactersIgnoringModifiers: "k",
                command: true, shift: true, option: false, control: false
            ),
            .openContextCompact
        )
        XCTAssertEqual(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: 37,
                charactersIgnoringModifiers: "l",
                command: true, shift: true, option: false, control: false
            ),
            .toggleLiveVoice
        )
        // Plain Cmd+C must not trigger copyLastReply
        XCTAssertNil(
            ChatKeyboardNavLogic.resolveAction(
                keyCode: 8,
                charactersIgnoringModifiers: "c",
                command: true, shift: false, option: false, control: false
            )
        )
    }

    func testStepTurnMessageIdSkipsSystemNoticesAndClamps() {
        let msgs = [
            makeMessage(id: "m1", seq: 1, role: .user, body: "Hi"),
            makeMessage(id: "sys", seq: 2, role: .system, body: "Compacted"),
            makeMessage(id: "m2", seq: 3, role: .assistant, body: "Hello!"),
            makeMessage(id: "m3", seq: 4, role: .user, body: "Next question"),
        ]
        XCTAssertEqual(ChatKeyboardNavLogic.stepTurnMessageId(messages: msgs, currentId: nil, direction: -1), "m3")
        XCTAssertEqual(ChatKeyboardNavLogic.stepTurnMessageId(messages: msgs, currentId: "m3", direction: -1), "m2")
        XCTAssertEqual(ChatKeyboardNavLogic.stepTurnMessageId(messages: msgs, currentId: "m2", direction: -1), "m1")
        XCTAssertEqual(ChatKeyboardNavLogic.stepTurnMessageId(messages: msgs, currentId: "m1", direction: -1), "m1")
        XCTAssertEqual(ChatKeyboardNavLogic.stepTurnMessageId(messages: msgs, currentId: "m1", direction: 1), "m2")
        XCTAssertEqual(ChatKeyboardNavLogic.lastAssistantReplyBody(in: msgs), "Hello!")
    }

    func testExportMarkdownAndPrintDocument() {
        let session = makeSession()
        let msgs = [
            makeMessage(id: "m1", seq: 1, role: .user, body: "How does WAL work?"),
            makeMessage(id: "m2", seq: 2, role: .assistant, body: "Write-ahead logging persists changes sequentially.", runId: "run-1", model: "claude-opus"),
        ]
        let md = ChatExportLogic.exportMarkdown(session: session, messages: msgs, includeToolTraces: false)
        XCTAssertTrue(md.contains("# Architecture Review"))
        XCTAssertTrue(md.contains("## You"))
        XCTAssertTrue(md.contains("## Judy (`claude-opus`)"))
        XCTAssertTrue(md.contains("Write-ahead logging persists changes sequentially."))

        let doc = ChatExportLogic.printDocument(session: session, messages: msgs, includeToolTraces: false)
        XCTAssertEqual(doc.title, "Architecture Review")
        XCTAssertEqual(doc.body.count, 1)
        XCTAssertEqual(ChatExportLogic.defaultFileName(title: "Architecture Review!", ext: "pdf"), "architecture-review.pdf")
    }
}
