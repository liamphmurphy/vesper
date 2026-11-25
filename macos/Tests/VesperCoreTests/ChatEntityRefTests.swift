import XCTest
@testable import VesperCore

final class ChatEntityRefTests: XCTestCase {
    func testExtractsKnowledgePageEntityRefs() {
        let md = """
        See [[page:Architecture/Chat#Segments]] and [[Runbook/Deploy|Deploy guide]].
        Duplicate [[page:Architecture/Chat]] should only appear once.
        Legacy [[ticket:PAY-42]], [[run:01a20488-bd7d-7ce0-836c-fdcdea552bb3]], and [[epic:Work]] are ignored.
        """
        let refs = ChatEntityRefExtractor.extract(from: md)
        XCTAssertEqual(refs, [
            .page(ref: "Architecture/Chat"),
            .page(ref: "Runbook/Deploy"),
        ])
    }

    func testSkipsCodeFencesInlineCodeAndURLs() {
        let md = """
        Inline `[[Hidden/Page]]` and [link](https://example.com/wiki/Foo).
        ```
        [[Fenced/Page]]
        ```
        Real ref: [[Visible/Page]].
        """
        let refs = ChatEntityRefExtractor.extract(from: md)
        XCTAssertEqual(refs, [.page(ref: "Visible/Page")])
    }

    func testRejectsRemovedWorkPrefixesAndParsesFolders() {
        XCTAssertNil(ChatEntityRefExtractor.parseBracketRef("ticket:PAY-1"))
        XCTAssertNil(ChatEntityRefExtractor.parseBracketRef("run:01a20488-bd7d-7ce0-836c-fdcdea552bb3"))
        XCTAssertNil(ChatEntityRefExtractor.parseBracketRef("epic:Foo"))
        XCTAssertEqual(ChatEntityRefExtractor.folderPath(from: "Architecture/ADR/Chat"), "Architecture/ADR")
        XCTAssertNil(ChatEntityRefExtractor.folderPath(from: "Overview"))
    }
}
