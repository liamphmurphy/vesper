import XCTest
@testable import VesperCore

final class LiveVoiceTurnTests: XCTestCase {
    func testAnUtteranceEndsOnlyAfterSpeechAndAPause() {
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(LiveVoiceTurn.utteranceEnded(transcript: "  ", lastChange: t0, now: t0.addingTimeInterval(10), settled: true), "silence alone sends nothing")
        XCTAssertFalse(LiveVoiceTurn.utteranceEnded(transcript: "hello", lastChange: t0, now: t0.addingTimeInterval(0.5), settled: true))
        XCTAssertTrue(LiveVoiceTurn.utteranceEnded(transcript: "hello", lastChange: t0, now: t0.addingTimeInterval(LiveVoiceTurn.endOfSettledUtterance), settled: true))
    }

    func testAVolatileTailWaitsLongerThanASettledOne() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let between = t0.addingTimeInterval((LiveVoiceTurn.endOfSettledUtterance + LiveVoiceTurn.endOfUtterance) / 2)
        XCTAssertTrue(LiveVoiceTurn.utteranceEnded(transcript: "I think", lastChange: t0, now: between, settled: true))
        XCTAssertFalse(LiveVoiceTurn.utteranceEnded(transcript: "I think", lastChange: t0, now: between, settled: false), "mid-thought pauses keep listening")
        XCTAssertTrue(LiveVoiceTurn.utteranceEnded(transcript: "I think", lastChange: t0, now: t0.addingTimeInterval(LiveVoiceTurn.endOfUtterance), settled: false))
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

    func testLateRevealOrVoiceStartPullsListeningBackToReplyingUnlessInterrupted() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: "r1")
        turn.sent()
        // Simulated view race: turnRunning=false and new reply ID observed one frame before
        // companion.observe sets revealing/speaking.
        turn.update(turnRunning: false, lastReplyId: "r2", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
        XCTAssertEqual(turn.resumeCooldown, LiveVoiceTurn.silentReplyCooldown)

        // When companion.observe starts revealing/speaking r2 on the next tick, phase must snap
        // back to .replying so the mic closes.
        turn.update(turnRunning: false, lastReplyId: "r2", revealing: true, speaking: true)
        XCTAssertEqual(turn.phase, .replying)

        // When playback finishes, speakerEchoCooldown keeps the mic closed for echo tail.
        turn.update(turnRunning: false, lastReplyId: "r2", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
        XCTAssertEqual(turn.resumeCooldown, LiveVoiceTurn.speakerEchoCooldown)

        // An explicit interrupt stays listening even if r2 keeps updating, until a brand-new r3 speaks.
        turn.send(lastReplyId: "r2")
        turn.sent()
        turn.update(turnRunning: false, lastReplyId: "r3", revealing: true, speaking: true)
        turn.interrupt()
        XCTAssertEqual(turn.phase, .listening)
        XCTAssertEqual(turn.resumeCooldown, 0)
        turn.update(turnRunning: false, lastReplyId: "r3", revealing: true, speaking: false)
        XCTAssertEqual(turn.phase, .listening, "interrupted reply stays listening")
        turn.update(turnRunning: false, lastReplyId: "r4", revealing: true, speaking: true)
        XCTAssertEqual(turn.phase, .replying, "new reply closes microphone again")
    }

    func testIdleTurnResumeUsesGraceCooldown() {
        var turn = LiveVoiceTurn()
        turn.send(lastReplyId: "r1")
        turn.sent()
        turn.update(turnRunning: true, lastReplyId: "r1", revealing: false, speaking: false)
        turn.update(turnRunning: false, lastReplyId: "r1", revealing: false, speaking: false)
        XCTAssertEqual(turn.phase, .listening)
        XCTAssertEqual(turn.resumeCooldown, LiveVoiceTurn.idleTurnCooldown)
    }
}
