import XCTest
@testable import VesperCore

/// The Start ready sheet's checks (web components/domain/dispatch-dialog.tsx).
final class DispatchLogicTests: XCTestCase {
    func testKeylessRunsOnSandboxedRunnersAreStuck() {
        let keyless = DispatchCheck(ticketKey: "A-1", keyPresent: false, keySecret: "ANTHROPIC_API_KEY", harness: "claude",
                                    runnerBackends: ["microvm"])
        let s = DispatchLogic.summary([keyless, DispatchCheck(ticketKey: "A-2")])
        XCTAssertFalse(s.blocked)
        XCTAssertEqual(s.missingKey, "ANTHROPIC_API_KEY")
        XCTAssertEqual(s.stuckReasons, ["claude: no ANTHROPIC_API_KEY secret"])
    }

    func testALocalRunnerUsesTheMachinesLogin() {
        let local = DispatchCheck(ticketKey: "A-1", keyPresent: false, keySecret: "K", runnerBackends: ["fake"])
        XCTAssertEqual(DispatchLogic.summary([local]), DispatchLogic.Summary(blocked: false, missingKey: nil, stuckReasons: []))
        let mixed = DispatchCheck(ticketKey: "A-1", keyPresent: false, keySecret: "K", runnerBackends: ["fake", "docker"])
        XCTAssertEqual(DispatchLogic.summary([mixed]).missingKey, "K")
        XCTAssertEqual(DispatchLogic.summary([mixed]).stuckReasons, [])
        let noRunner = DispatchCheck(ticketKey: "A-1", keyPresent: false, keySecret: "K")
        XCTAssertEqual(DispatchLogic.summary([noRunner]).missingKey, "K")
        XCTAssertEqual(DispatchLogic.summary([noRunner]).stuckReasons, [], "no runner online yet: not stuck, it waits")
    }

    func testBlockedTicketsAreNotAlsoKeyless() {
        let blocked = DispatchCheck(ticketKey: "A-1", blockers: ["No agent"], keyPresent: false, keySecret: "K", runnerBackends: ["docker"])
        let s = DispatchLogic.summary([blocked])
        XCTAssertTrue(s.blocked)
        XCTAssertNil(s.missingKey)
        XCTAssertTrue(s.stuckReasons.isEmpty)
    }

    func testRowStatusAndStartsLine() {
        XCTAssertEqual(DispatchLogic.rowStatus(DispatchCheck(ticketKey: "A", blockers: ["x", "y"])).text, "x; y")
        XCTAssertEqual(DispatchLogic.rowStatus(DispatchCheck(ticketKey: "A", queuedBehind: ["A-0"])).tone, .human)
        XCTAssertEqual(DispatchLogic.rowStatus(DispatchCheck(ticketKey: "A", keyPresent: false, keySecret: "K")).text, "No K key")
        XCTAssertEqual(DispatchLogic.rowStatus(DispatchCheck(ticketKey: "A", scopesNeedingApproval: 2)).text, "2 scopes need approval")
        XCTAssertEqual(DispatchLogic.starts(online: true, starting: false, busy: 1, slots: 4, queued: 0).title, "Immediately")
        let busy = DispatchLogic.starts(online: true, starting: false, busy: 4, slots: 4, queued: 2)
        XCTAssertEqual(busy.title, "When a slot frees up")
        XCTAssertEqual(busy.detail, "4 of 4 runner slots in use · 2 queued")
        XCTAssertEqual(busy.tone, .human)
        XCTAssertEqual(DispatchLogic.starts(online: false, starting: true, busy: 0, slots: 0, queued: 0).tone, .human)
        XCTAssertEqual(DispatchLogic.starts(online: false, starting: false, busy: 0, slots: 0, queued: 0).tone, .blocked)
    }
}
