import XCTest
@testable import VesperCore

final class LiveVoiceTurnTests: XCTestCase {
    func testAnUtteranceEndsOnlyAfterSpeechAndASettledPause() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(LiveVoiceTurn.utteranceEnded(transcript: "  ", lastChange: t0, now: t0.addingTimeInterval(10)), "silence alone sends nothing")
        XCTAssertFalse(LiveVoiceTurn.utteranceEnded(transcript: "hello", lastChange: t0, now: t0.addingTimeInterval(1.0)))
        XCTAssertTrue(LiveVoiceTurn.utteranceEnded(transcript: "hello", lastChange: t0, now: t0.addingTimeInterval(LiveVoiceTurn.endOfUtterance)))
    }

    func testListensAgainOnlyAfterTheAnswerHasRevealedAndSpoken() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: "r1")
        XCTAssertEqual(turn.phase, .sending)
        turn.sent()
        // The old reply and an idle session from before the send don't count as the answer.
        turn.update(turnRunning: false, lastReplyId: "r1", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .waiting)
        turn.update(turnRunning: true, lastReplyId: "r1", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .waiting)
        turn.update(turnRunning: true, lastReplyId: "r2", revealing: true, speaking: false)
        XCTAssertEqual(turn.phase, .replying)
        turn.update(turnRunning: false, lastReplyId: "r2", revealing: false, speaking: true)
        XCTAssertEqual(turn.phase, .replying, "a reveal that ended naturally lets the voice play out")
        turn.update(turnRunning: false, lastReplyId: "r2", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
    }

    func testAnInstantSilentAnswerResumesListeningAtOnce() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: nil)
        turn.sent()
        turn.update(turnRunning: false, lastReplyId: "r1", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
    }

    func testAStoppedTurnWithNoAnswerResumesListening() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: "r1")
        turn.sent()
        turn.update(turnRunning: true, lastReplyId: "r1", revealing: false, speaking: false)
        turn.update(turnRunning: false, lastReplyId: "r1", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
    }

    func testAFailedSendListensAgainAndInterruptCutsTheAnswerShort() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: nil)
        turn.sendFailed()
        XCTAssertEqual(turn.phase, .listening)

        turn.send(lastReplyId: nil)
        turn.sent()
        turn.update(turnRunning: true, lastReplyId: "r1", revealing: true, speaking: true)
        turn.interrupt()
        XCTAssertEqual(turn.phase, .listening)
        // Late updates from the interrupted turn don't pull it back out of listening.
        turn.update(turnRunning: false, lastReplyId: "r1", revealing: true, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
    }

    func testSendingIsIgnoredOutsideListening() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: "r1")
        turn.sent()
        turn.send(lastReplyId: "r9")
        XCTAssertEqual(turn.phase, .waiting)
    }
}
