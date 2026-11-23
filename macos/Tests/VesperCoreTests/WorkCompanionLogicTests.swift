import XCTest
@testable import VesperCore

final class WorkCompanionLogicTests: XCTestCase {
    func testWorkContextAppendsViewingAndPinnedOnce() {
        let ticket = CompanionSubject(kind: .ticket, id: "PAY-42", title: "Fix billing")
        let run = CompanionSubject(kind: .run, id: "run-9", title: "Run tests", agent: "Pike", ticketKey: "PAY-7")

        let once = WorkCompanionLogic.withWorkContext("How does this look?", viewing: run, pinned: ticket)
        XCTAssertTrue(once.contains(WorkCompanionLogic.workContextMarker))
        XCTAssertTrue(once.contains("Pinned ticket PAY-42 (\u{201C}Fix billing\u{201D})."))
        XCTAssertTrue(once.contains("Viewing run run-9 (\u{201C}Run tests\u{201D}) by Pike for ticket PAY-7."))

        // Idempotent when called twice.
        let twice = WorkCompanionLogic.withWorkContext(once, viewing: run, pinned: ticket)
        XCTAssertEqual(once, twice)

        // Same viewing and pinned emits only a single Pinned line.
        let same = WorkCompanionLogic.withWorkContext("Ping", viewing: ticket, pinned: ticket)
        XCTAssertEqual(
            same,
            "Ping\(WorkCompanionLogic.workContextMarker)Pinned ticket PAY-42 (\u{201C}Fix billing\u{201D})."
        )

        // Neither viewing nor pinned leaves body untouched.
        XCTAssertEqual(WorkCompanionLogic.withWorkContext("Hello", viewing: nil, pinned: nil), "Hello")
    }

    func testMergeWorkContextRefsDedupesTicketKeys() {
        let ticket = CompanionSubject(kind: .ticket, id: "PAY-42", title: "Fix billing")
        let run = CompanionSubject(kind: .run, id: "run-9", title: "Run", agent: "Pike", ticketKey: "PAY-42")
        let refs = WorkCompanionLogic.mergeWorkContextRefs(existing: nil, viewing: run, pinned: ticket)
        XCTAssertEqual(refs, [API.ChatContextRef(key: "PAY-42", kind: .ticket)])
    }

    func testKnowledgeContextBodyIncludesPageAndUnsavedDraft() {
        let body = WorkCompanionLogic.knowledgeContextBody(
            "Check this",
            pagePath: "Notes/Design",
            pageTitle: "Design",
            screen: nil,
            unsavedDraft: "Draft line 1\nDraft line 2",
            savedBody: "Saved text"
        )
        XCTAssertTrue(body.contains(WorkCompanionLogic.knowledgeContextMarker))
        XCTAssertTrue(body.contains("Currently viewing Knowledge page [[Notes/Design]]."))
        XCTAssertTrue(body.contains("> Draft line 1\n> Draft line 2"))

        let screenBody = WorkCompanionLogic.knowledgeContextBody("What's new?", pagePath: nil, pageTitle: nil, screen: "Graph")
        XCTAssertTrue(screenBody.contains("On the Knowledge Graph screen, not viewing a page."))
    }
}
