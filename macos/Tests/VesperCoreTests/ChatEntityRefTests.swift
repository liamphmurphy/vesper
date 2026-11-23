import XCTest
@testable import VesperCore

final class ChatEntityRefTests: XCTestCase {
    func testExtractsExplicitAndAutoDetectedEntityRefs() {
        let md = """
        Working on LAZYAGENTS-317 and [[ticket:PAY-42]] now.
        Run [[run:01a20488-bd7d-7ce0-836c-fdcdea552bb3]] finished for [[epic:Richer chat visualizations]].
        See [[page:Architecture/Chat#Segments]] and [[Runbook/Deploy|Deploy guide]].
        Duplicate LAZYAGENTS-317 should only appear once.
        """
        let refs = ChatEntityRefExtractor.extract(from: md)
        XCTAssertEqual(refs, [
            .ticket(key: "LAZYAGENTS-317"),
            .ticket(key: "PAY-42"),
            .run(id: "01a20488-bd7d-7ce0-836c-fdcdea552bb3"),
            .epic(ref: "Richer chat visualizations"),
            .page(ref: "Architecture/Chat"),
            .page(ref: "Runbook/Deploy"),
        ])
    }

    func testSkipsCodeFencesInlineCodeAndURLs() {
        let md = """
        Inline `LAZYAGENTS-999` and [link](https://example.com/tickets/LAZYAGENTS-888) and https://example.com/LAZYAGENTS-777.
        ```
        LAZYAGENTS-666
        [[ticket:PAY-1]]
        ```
        Real ref: LAZYAGENTS-123.
        """
        let refs = ChatEntityRefExtractor.extract(from: md)
        XCTAssertEqual(refs, [.ticket(key: "LAZYAGENTS-123")])
    }

    func testRejectsMalformedExplicitTicketAndRunRefs() {
        XCTAssertNil(ChatEntityRefExtractor.parseBracketRef("ticket:bad"))
        XCTAssertNil(ChatEntityRefExtractor.parseBracketRef("run:not-a-uuid"))
        XCTAssertEqual(ChatEntityRefExtractor.parseBracketRef("LAZYAGENTS-10"), .ticket(key: "LAZYAGENTS-10"))
        XCTAssertEqual(ChatEntityRefExtractor.folderPath(from: "Architecture/ADR/Chat"), "Architecture/ADR")
        XCTAssertNil(ChatEntityRefExtractor.folderPath(from: "Overview"))
    }
}
