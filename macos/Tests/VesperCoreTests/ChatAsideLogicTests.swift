import XCTest
@testable import VesperCore

/// Mirrors `asidesInWindow` in web/lib/send-mode.ts and the aside rail in web's conversation.tsx.
final class ChatAsideLogicTests: XCTestCase {
    private struct Aside: ChatAsideLike, Equatable {
        var id: String
        var createdAt: String
        var anchorMessageId: String? = nil
        var secondOpinion: Bool? = nil
    }

    private struct Message: ChatAsideMessageLike {
        var roleName: String
        var bodyMd: String
    }

    private let asides = [
        Aside(id: "before", createdAt: "2026-11-15T09:59:59Z"),
        Aside(id: "turn1", createdAt: "2026-11-15T10:00:30.123456789Z"),
        Aside(id: "thread", createdAt: "2026-11-15T10:00:31Z", anchorMessageId: "m2"),
        Aside(id: "opinion", createdAt: "2026-11-15T10:00:32Z", secondOpinion: true),
        Aside(id: "turn2", createdAt: "2026-11-15T10:02:30Z"),
        Aside(id: "live", createdAt: "2026-11-15T10:04:30Z"),
    ]

    func testWindowKeepsOnlyGenericAsidesInRange() {
        let got = ChatAsideLogic.asidesInWindow(asides, since: "2026-11-15T10:00:00Z", until: "2026-11-15T10:02:00Z")
        XCTAssertEqual(got.map(\.id), ["turn1"])
    }

    func testWindowIsOpenEndedWithoutUntilAndEmptyWithoutSince() {
        XCTAssertEqual(ChatAsideLogic.asidesInWindow(asides, since: "2026-11-15T10:04:00Z", until: nil).map(\.id), ["live"])
        XCTAssertTrue(ChatAsideLogic.asidesInWindow(asides, since: nil, until: nil).isEmpty)
    }

    func testFinishedRepliesGetTheirAsidesAndTheRunningTurnKeepsItsOwn() {
        let windows: [String: ChatTurnWindow] = [
            "m2": ChatTurnWindow(since: "2026-11-15T10:00:00Z", until: "2026-11-15T10:02:00Z", followup: false),
            "m5": ChatTurnWindow(since: "2026-11-15T10:02:00Z", until: nil, followup: false),
        ]
        let running = ChatAsideLogic.asidesByReply(asides, turnWindows: windows, running: true, runningSince: "2026-11-15T10:04:00Z")
        XCTAssertEqual(running["m2"]?.map(\.id), ["turn1"])
        XCTAssertEqual(running["m5"]?.map(\.id), ["turn2"], "the live turn's aside stays out of the last reply's chip")

        let idle = ChatAsideLogic.asidesByReply(asides, turnWindows: windows, running: false, runningSince: nil)
        XCTAssertEqual(idle["m5"]?.map(\.id), ["turn2", "live"], "once idle, the last reply's window is open-ended")
    }

    func testContentPrefersAnswerThenFailureThenProgress() {
        let q = Message(roleName: "user", bodyMd: "What is it doing?")
        let a = Message(roleName: "assistant", bodyMd: "Running tests.")
        let s = Message(roleName: "system", bodyMd: "Harness crashed")

        XCTAssertEqual(
            ChatAsideLogic.content(messages: [q, a], title: "Aside: x", running: false, failed: false, error: nil),
            ChatAsideContent(question: "What is it doing?", status: .answered("Running tests."))
        )
        XCTAssertEqual(
            ChatAsideLogic.content(messages: [q, s], title: "Aside: x", running: false, failed: true, error: "e").status,
            .failed("Harness crashed")
        )
        XCTAssertEqual(
            ChatAsideLogic.content(messages: [Message](), title: "Aside: Why so slow?", running: true, failed: false, error: nil),
            ChatAsideContent(question: "Why so slow?", status: .answering)
        )
        XCTAssertEqual(
            ChatAsideLogic.content(messages: [q], title: "Aside: x", running: false, failed: false, error: nil).status,
            .stopped
        )
    }

    func testCountLabel() {
        XCTAssertEqual(ChatAsideLogic.countLabel(1), "1 aside")
        XCTAssertEqual(ChatAsideLogic.countLabel(3), "3 asides")
    }
}
