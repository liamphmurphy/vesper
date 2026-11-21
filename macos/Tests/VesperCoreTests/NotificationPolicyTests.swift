import XCTest
@testable import VesperCore

private let APPROVAL = "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
private let RUN = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b"

private func alert(_ edit: (inout DesktopAlert) -> Void = { _ in }) -> DesktopAlert {
    var a = DesktopAlert(title: "t", body: "b", href: "/inbox", signature: "s", kind: "approval", itemId: "approval:\(APPROVAL)")
    edit(&a)
    return a
}

private func at(_ hh: Int, _ mm: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: hh, minute: mm))!
}

final class NotificationPolicyTests: XCTestCase {
    func testCollectCarriesKindIdsTicketAndAgentHandle() {
        var seen = Set<String>()
        _ = NotificationLogic.collectNewNotifications(seen: &seen, items: [], baselineInitialized: false)
        let item = InboxItem(
            id: "question:\(RUN)", kind: "question", title: "Which DB?", href: "/runs/\(RUN)", ticketKey: "PAY-9",
            createdAt: "2026-11-17T00:00:00Z", needsYou: true, agent: AgentRef(name: "Pike", handle: "pike"), runId: RUN
        )
        let r = NotificationLogic.collectNewNotifications(seen: &seen, items: [item], baselineInitialized: true)
        XCTAssertEqual(r.alerts.count, 1)
        XCTAssertEqual(r.alerts[0].kind, "question")
        XCTAssertEqual(r.alerts[0].itemId, "question:\(RUN)")
        XCTAssertEqual(r.alerts[0].runId, RUN)
        XCTAssertEqual(r.alerts[0].ticketKey, "PAY-9")
        XCTAssertEqual(r.alerts[0].agentHandle, "pike")
    }

    func testCountNeedsYouAndBadge() {
        let items = [
            InboxItem(id: "1", kind: "approval", title: "Approve push", needsYou: true),
            InboxItem(id: "2", kind: "question", title: "Question", resolved: true, needsYou: true),
            InboxItem(id: "3", kind: "merged", title: "PR merged"),
            InboxItem(id: "4", kind: "review", title: "Review", read: true, needsYou: true),
        ]
        XCTAssertEqual(NotificationLogic.countNeedsYou(items), 1)
        XCTAssertEqual(NotificationLogic.formatDockBadge(0), "")
        XCTAssertEqual(NotificationLogic.formatDockBadge(-2), "")
        XCTAssertEqual(NotificationLogic.formatDockBadge(5), "5")
        XCTAssertEqual(NotificationLogic.formatDockBadge(99), "99")
        XCTAssertEqual(NotificationLogic.formatDockBadge(140), "99+")
    }

    func testBaselineSuppressesStartupFloodAndFiresOnNewItems() {
        var seen = Set<String>()
        let initial = [InboxItem(id: "item-1", kind: "approval", title: "Push feat/desktop", summary: "Needs approval", href: "/chat/1", createdAt: "2026-11-16T01:00:00Z", needsYou: true, agent: AgentRef(name: "Meow"))]
        let first = NotificationLogic.collectNewNotifications(seen: &seen, items: initial, baselineInitialized: false)
        XCTAssertEqual(first.badgeCount, 1)
        XCTAssertEqual(first.alerts.count, 0)
        let second = NotificationLogic.collectNewNotifications(
            seen: &seen,
            items: initial + [InboxItem(id: "item-2", kind: "question", title: "Which target arch?", summary: "arm64 or universal?", href: "/tickets/LAZYAGENTS-232", ticketKey: "LAZYAGENTS-232", createdAt: "2026-11-16T01:05:00Z", needsYou: true, agent: AgentRef(name: "Tech Lead"))],
            baselineInitialized: true
        )
        XCTAssertEqual(second.badgeCount, 2)
        XCTAssertEqual(second.alerts.count, 1)
        XCTAssertEqual(second.alerts[0].title, "Question: Which target arch?")
        XCTAssertEqual(second.alerts[0].body, "Tech Lead · LAZYAGENTS-232 · arm64 or universal?")
        XCTAssertEqual(second.alerts[0].href, "/tickets/LAZYAGENTS-232")
    }

    func testShouldRefreshForSSEEventPrefixes() {
        for t in ["reset", "inbox.updated", "run.completed", "approval.requested", "ticket.updated", "workflow.x", "pr_feedback.updated"] {
            XCTAssertTrue(NotificationLogic.shouldRefreshInbox(forEvent: t), t)
        }
        XCTAssertFalse(NotificationLogic.shouldRefreshInbox(forEvent: "video.updated"))
        XCTAssertTrue(RunLogic.shouldRefreshRuns(forEvent: "run.updated"))
        XCTAssertTrue(RunLogic.shouldRefreshRuns(forEvent: "reset"))
        XCTAssertFalse(RunLogic.shouldRefreshRuns(forEvent: "inbox.updated"))
    }

    func testQuietHoursHandleSameDayAndOvernightWindows() {
        let overnight = QuietHours(enabled: true, start: "22:00", end: "08:00")
        XCTAssertTrue(NotificationLogic.isWithinQuietHours(at(23, 30), overnight))
        XCTAssertTrue(NotificationLogic.isWithinQuietHours(at(3, 0), overnight))
        XCTAssertFalse(NotificationLogic.isWithinQuietHours(at(8, 0), overnight), "end is exclusive")
        XCTAssertFalse(NotificationLogic.isWithinQuietHours(at(12, 0), overnight))
        let lunch = QuietHours(enabled: true, start: "12:00", end: "13:00")
        XCTAssertTrue(NotificationLogic.isWithinQuietHours(at(12, 30), lunch))
        XCTAssertFalse(NotificationLogic.isWithinQuietHours(at(13, 0), lunch))
        XCTAssertFalse(NotificationLogic.isWithinQuietHours(at(23, 30), QuietHours(enabled: false, start: "22:00", end: "08:00")))
        XCTAssertFalse(NotificationLogic.isWithinQuietHours(at(10, 0), QuietHours(enabled: true, start: "10:00", end: "10:00")), "empty window")
    }

    func testShouldShowAlertHonoursSwitches() {
        let policy = NativeSettings.defaults().notifications
        XCTAssertTrue(NotificationLogic.shouldShowAlert(alert(), policy, now: at(12, 0)))
        var off = policy; off.enabled = false
        XCTAssertFalse(NotificationLogic.shouldShowAlert(alert(), off, now: at(12, 0)))
        var noApproval = policy; noApproval.kinds["approval"] = false
        XCTAssertFalse(NotificationLogic.shouldShowAlert(alert(), noApproval, now: at(12, 0)))
        XCTAssertTrue(NotificationLogic.shouldShowAlert(alert { $0.kind = "merged" }, noApproval, now: at(12, 0)))
        var quiet = policy; quiet.quietHours = QuietHours(enabled: true, start: "11:00", end: "13:00")
        XCTAssertFalse(NotificationLogic.shouldShowAlert(alert(), quiet, now: at(12, 0)))
        var noRuns = policy; noRuns.runFinished = false
        XCTAssertFalse(NotificationLogic.shouldShowAlert(alert { $0.kind = "run_finished" }, noRuns, now: at(12, 0)))
        XCTAssertTrue(NotificationLogic.shouldShowAlert(alert { $0.kind = "run_finished" }, policy, now: at(12, 0)))
    }

    func testAlertGroupId() {
        XCTAssertEqual(NotificationLogic.alertGroupId(alert { $0.ticketKey = "PAY-1"; $0.runId = RUN }, groupByWork: true), "ticket:PAY-1")
        XCTAssertEqual(NotificationLogic.alertGroupId(alert { $0.runId = RUN }, groupByWork: true), "run:\(RUN)")
        XCTAssertNil(NotificationLogic.alertGroupId(alert(), groupByWork: true))
        XCTAssertNil(NotificationLogic.alertGroupId(alert { $0.ticketKey = "PAY-1" }, groupByWork: false))
    }

    func testDecisionRequestMapsEachApprovalKindAndRefusesMismatches() {
        XCTAssertEqual(NotificationLogic.decisionRequest(alert(), .approve), APICall(path: "/api/v1/approvals/\(APPROVAL)/approve", body: [:]))
        XCTAssertEqual(NotificationLogic.decisionRequest(alert(), .deny), APICall(path: "/api/v1/approvals/\(APPROVAL)/deny", body: [:]))
        XCTAssertEqual(
            NotificationLogic.decisionRequest(alert { $0.kind = "connector_approval"; $0.itemId = "connector_approval:\(APPROVAL)" }, .approve),
            APICall(path: "/api/v1/connector-approvals/\(APPROVAL)", body: ["decision": "allow"])
        )
        XCTAssertEqual(
            NotificationLogic.decisionRequest(alert { $0.kind = "secret_approval"; $0.itemId = "secret_approval:\(APPROVAL)" }, .deny),
            APICall(path: "/api/v1/api-secret-approvals/\(APPROVAL)", body: ["decision": "deny"])
        )
        let bad: [DesktopAlert] = [
            alert { $0.itemId = "approval:not-a-uuid" },
            alert { $0.itemId = "approval:\(APPROVAL):extra" },
            alert { $0.itemId = "approval:\(APPROVAL)/../../runs" },
            alert { $0.kind = "question"; $0.itemId = "approval:\(APPROVAL)" },
            alert { $0.kind = "workflow_gate"; $0.itemId = "workflow_gate:\(APPROVAL)" },
            alert { $0.itemId = "" },
        ]
        for b in bad { XCTAssertNil(NotificationLogic.decisionRequest(b, .approve), b.itemId) }
    }

    func testReplyRequestPostsTicketCommentMentioningAgentOnce() {
        let q = alert { $0.kind = "question"; $0.itemId = "question:\(RUN)"; $0.ticketKey = "PAY-9"; $0.agentHandle = "pike" }
        XCTAssertEqual(NotificationLogic.replyRequest(q, "  use Postgres  "), APICall(path: "/api/v1/tickets/PAY-9/comments", body: ["body_md": "@pike use Postgres"]))
        XCTAssertEqual(NotificationLogic.replyRequest(q, "@pike use Postgres")?.body["body_md"], "@pike use Postgres", "no double mention")
        XCTAssertNil(NotificationLogic.replyRequest(q, "   "))
        var badKey = q; badKey.ticketKey = "../x"
        XCTAssertNil(NotificationLogic.replyRequest(badKey, "hi"))
        var badHandle = q; badHandle.agentHandle = "pi ke"
        XCTAssertNil(NotificationLogic.replyRequest(badHandle, "hi"))
        var notQuestion = q; notQuestion.kind = "approval"
        XCTAssertNil(NotificationLogic.replyRequest(notQuestion, "hi"))
    }

    func testAlertActionFor() {
        XCTAssertEqual(NotificationLogic.alertActionFor(alert(), actionsEnabled: true), .decide(approve: "Approve", decline: "Decline"))
        let q = alert { $0.kind = "question"; $0.itemId = "question:\(RUN)"; $0.ticketKey = "PAY-9"; $0.agentHandle = "pike" }
        XCTAssertEqual(NotificationLogic.alertActionFor(q, actionsEnabled: true), .reply(placeholder: "Reply to pike"))
        XCTAssertEqual(NotificationLogic.alertActionFor(alert { $0.kind = "question"; $0.itemId = "question:\(RUN)" }, actionsEnabled: true), .none, "no ticket to comment on")
        XCTAssertEqual(NotificationLogic.alertActionFor(alert { $0.kind = "merged"; $0.itemId = "merged:x" }, actionsEnabled: true), .none)
        XCTAssertEqual(NotificationLogic.alertActionFor(alert(), actionsEnabled: false), .none)
    }

    func testTouchIdScopeForKind() {
        XCTAssertEqual(NotificationLogic.touchIdScopeForKind("approval"), .runApprovals)
        XCTAssertEqual(NotificationLogic.touchIdScopeForKind("connector_approval"), .connectorApprovals)
        XCTAssertEqual(NotificationLogic.touchIdScopeForKind("secret_approval"), .secretApprovals)
        XCTAssertNil(NotificationLogic.touchIdScopeForKind("question"))
    }

    func testInboxItemDecodesAPIJSONWithMissingFields() throws {
        let json = #"{"items":[{"id":"a","kind":"approval","title":"T","href":"/x","created_at":"2026-11-17T00:00:00Z","needs_you":true,"ticket_key":"PAY-1","agent":{"name":"N","handle":"n"},"run_id":"r"},{"id":"b"}]}"#
        struct R: Decodable { var items: [InboxItem] }
        let r = try JSONDecoder().decode(R.self, from: Data(json.utf8))
        XCTAssertEqual(r.items[0].ticketKey, "PAY-1")
        XCTAssertTrue(r.items[0].needsYou)
        XCTAssertEqual(r.items[0].agent?.handle, "n")
        XCTAssertFalse(r.items[1].needsYou)
        XCTAssertEqual(r.items[1].title, "")
    }
}
