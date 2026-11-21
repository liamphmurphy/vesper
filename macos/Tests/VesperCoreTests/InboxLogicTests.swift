import XCTest
@testable import VesperCore

private struct Item: InboxListItem {
    var id: String
    var kindName: String
    var createdAt: String
    var resolved = false
    var read = false
}

private let base = Date(timeIntervalSince1970: 1_794_052_800) // 2026-11-07T12:00:00Z

private func at(_ minutesAgo: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: base.addingTimeInterval(-minutesAgo * 60))
}

private func item(_ id: String, _ kind: String, _ min: Double, resolved: Bool = false, read: Bool = false) -> Item {
    Item(id: id, kindName: kind, createdAt: at(min), resolved: resolved, read: read)
}

/// Ported from web/lib/inbox.test.mjs.
final class InboxLogicTests: XCTestCase {
    func testGroupsFollowUrgencyOrderAndLongestWaitFirst() {
        let items = [
            item("m1", "mention", 5), item("s1", "stalled", 40), item("q1", "question", 10), item("a2", "approval", 30),
            item("a1", "approval", 60), item("f1", "blocked", 300), item("old", "approval", 90, resolved: true),
        ]
        let groups = InboxLogic.group(items, view: .open, sort: .oldest)
        XCTAssertEqual(groups.map(\.label), ["Approvals", "Questions", "Failed & stalled runs", "Mentions"])
        XCTAssertEqual(groups[0].items.map(\.id), ["a1", "a2"])
        XCTAssertEqual(groups[2].items.map(\.id), ["f1", "s1"])
        XCTAssertEqual(InboxLogic.group(items, view: .open, sort: .newest)[0].items.map(\.id), ["a2", "a1"])
        XCTAssertEqual(InboxLogic.group(items, view: .done, sort: .oldest).flatMap { $0.items.map(\.id) }, ["old"])
    }

    func testDoneOrResolvedItemsAreNotOpen() {
        XCTAssertTrue(InboxLogic.isOpen(item("x", "approval", 1)))
        XCTAssertFalse(InboxLogic.isOpen(item("x", "approval", 1, read: true)))
        XCTAssertFalse(InboxLogic.isOpen(item("x", "approval", 1, resolved: true)))
    }

    func testFocusKeepsItsSlotWhenTheSelectedItemLeaves() {
        XCTAssertEqual(InboxLogic.nextSelection(["a", "b", "c"], selected: "b", lastIndex: 1), "b")
        XCTAssertEqual(InboxLogic.nextSelection(["a", "c"], selected: "b", lastIndex: 1), "c")
        XCTAssertEqual(InboxLogic.nextSelection(["a", "b"], selected: "c", lastIndex: 2), "b")
        XCTAssertNil(InboxLogic.nextSelection([], selected: "c", lastIndex: 2))
        XCTAssertEqual(InboxLogic.nextSelection(["a"], selected: nil, lastIndex: 0), "a")
    }

    func testJKWrapAround() {
        XCTAssertEqual(InboxLogic.step(["a", "b"], selected: "b", by: 1), "a")
        XCTAssertEqual(InboxLogic.step(["a", "b"], selected: "a", by: -1), "b")
        XCTAssertEqual(InboxLogic.step(["a", "b"], selected: nil, by: 1), "a")
        XCTAssertNil(InboxLogic.step([], selected: "a", by: 1))
    }

    func testWaitTimeReadsInMinutesHoursAndDays() {
        XCTAssertEqual(APIDate.waited(at(0), now: base), "now")
        XCTAssertEqual(APIDate.waited(at(42), now: base), "42m")
        XCTAssertEqual(APIDate.waited(at(65), now: base), "1h 5m")
        XCTAssertEqual(APIDate.waited(at(180), now: base), "3h")
        XCTAssertEqual(APIDate.waited(at(60 * 50), now: base), "2d")
        XCTAssertTrue(APIDate.longWait(at(60), now: base))
        XCTAssertFalse(APIDate.longWait(at(59), now: base))
    }

    func testIdsAndHrefs() {
        XCTAssertEqual(InboxLogic.approvalId("approval:abc"), "abc")
        XCTAssertNil(InboxLogic.approvalId("question:abc"))
        XCTAssertEqual(InboxLogic.pushRequestId("pr_review_comments:push:p1"), "p1")
        XCTAssertNil(InboxLogic.pushRequestId("pr_ci_failed:ticket:PAY-1"))
        XCTAssertTrue(InboxLogic.isExternalHref("https://github.com/o/r/pull/1"))
        XCTAssertFalse(InboxLogic.isExternalHref("/tickets/WEB-4"))
    }

    func testMentionIsAddedOnce() {
        XCTAssertEqual(InboxLogic.withMention("  yes, go ahead ", handle: "pike"), "@pike yes, go ahead")
        XCTAssertEqual(InboxLogic.withMention("thanks @Pike!", handle: "pike"), "thanks @Pike!")
        XCTAssertEqual(InboxLogic.withMention("ask @pike-2", handle: "pike"), "@pike ask @pike-2")
    }

    func testHeadlinesAndUnknownKinds() {
        XCTAssertEqual(InboxLogic.headline(kind: "approval", agent: "Pike"), "Pike is waiting for your approval")
        XCTAssertNil(InboxLogic.headline(kind: "scheduled", agent: "Pike"))
        XCTAssertEqual(InboxLogic.kind("brand_new").label, "brand_new")
        XCTAssertEqual(InboxLogic.kind("blocked").tone, .blocked)
    }
}

final class APIDateTests: XCTestCase {
    func testParsesGoTimestampsWithAnyFraction() {
        XCTAssertEqual(APIDate.parse("2026-11-07T12:00:00Z")?.timeIntervalSince1970, 1_794_052_800)
        XCTAssertEqual(APIDate.parse("2026-11-07T12:00:00.5Z")?.timeIntervalSince1970, 1_794_052_800.5)
        XCTAssertEqual(APIDate.parse("2026-11-07T04:00:00.123456789-08:00")!.timeIntervalSince1970, 1_794_052_800.123, accuracy: 0.001)
        XCTAssertNil(APIDate.parse("yesterday"))
        XCTAssertNil(APIDate.parse(""))
    }

    func testDurationMatchesTheWeb() {
        XCTAssertEqual(APIDate.duration(since: at(0.5), now: base), "30s")
        XCTAssertEqual(APIDate.duration(since: at(7), now: base), "7m")
        XCTAssertEqual(APIDate.duration(since: at(120), now: base), "2h 0m")
        XCTAssertEqual(APIDate.duration(since: at(60), until: at(30)), "30m")
    }
}
