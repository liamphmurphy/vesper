import XCTest
@testable import VesperCore

final class WorkCompanionLogicTests: XCTestCase {
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
