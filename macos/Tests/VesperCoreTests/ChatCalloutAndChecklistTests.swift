import XCTest
@testable import VesperCore

final class ChatCalloutAndChecklistTests: XCTestCase {
    func testParsesAllCalloutTypesCollapsibleAndUnknownFallback() {
        let md = """
        Intro text.

        > [!note] Custom Note
        > Line one
        > Line two

        > [!tip]
        > Helpful hint

        > [!warning]- Collapsed warning
        > Hidden by default

        > [!caveat]+ Open collapsible
        > Visible by default

        > [!conflict] Conflicting Sources
        > Source A disagrees with Source B.

        > [!mystery] Unknown Type
        > Falls back to neutral note.

        > Ordinary blockquote should remain markdown.
        """

        let segments = ChatTranscriptLogic.parseSegments(md)
        let callouts: [ChatCalloutBlock] = segments.compactMap {
            if case .callout(let c) = $0 { return c }
            return nil
        }
        XCTAssertEqual(callouts.count, 6)

        XCTAssertEqual(callouts[0].kind, .note)
        XCTAssertEqual(callouts[0].title, "Custom Note")
        XCTAssertEqual(callouts[0].body, "Line one\nLine two")
        XCTAssertFalse(callouts[0].collapsible)

        XCTAssertEqual(callouts[1].kind, .tip)
        XCTAssertEqual(callouts[1].title, "Tip")

        XCTAssertEqual(callouts[2].kind, .warning)
        XCTAssertTrue(callouts[2].collapsible)
        XCTAssertTrue(callouts[2].defaultCollapsed)
        XCTAssertEqual(callouts[2].title, "Collapsed warning")

        XCTAssertEqual(callouts[3].kind, .caveat)
        XCTAssertTrue(callouts[3].collapsible)
        XCTAssertFalse(callouts[3].defaultCollapsed)

        XCTAssertEqual(callouts[4].kind, .conflict)
        XCTAssertEqual(callouts[4].title, "Conflicting Sources")

        XCTAssertEqual(callouts[5].kind, .note)
        XCTAssertEqual(callouts[5].rawType, "mystery")
        XCTAssertEqual(callouts[5].title, "Unknown Type")

        // Ordinary blockquote stayed markdown
        guard case .markdown(let tail) = segments.last else {
            return XCTFail("Expected trailing ordinary blockquote in markdown")
        }
        XCTAssertTrue(tail.contains("Ordinary blockquote"))
    }

    func testCalloutInsideCodeFenceIsIgnored() {
        let md = """
        ```markdown
        > [!warning] Not a real callout
        > Inside a fence
        ```
        """
        let segments = ChatTranscriptLogic.parseSegments(md)
        XCTAssertEqual(segments.count, 1)
        if case .callout = segments[0] {
            XCTFail("Callout inside code fence should not be parsed")
        }
    }

    func testInteractiveChecklistIndexingSkipsCodeFencesAndAppliesPersistedState() {
        let md = """
        Steps:
        - [ ] First item
        - [x] Second item

        ```md
        - [ ] Ignored in code fence
        ```

        More:
          * [ ] Third item
        1. [X] Fourth item
        """
        let segments = ChatTranscriptLogic.parseSegments(md, interactiveChecklists: true)
        let checklists: [ChatChecklistBlock] = segments.compactMap {
            if case .checklist(let c) = $0 { return c }
            return nil
        }
        XCTAssertEqual(checklists.count, 2)
        XCTAssertEqual(checklists[0].items.map(\.index), [0, 1])
        XCTAssertEqual(checklists[0].items.map(\.defaultChecked), [false, true])
        XCTAssertEqual(checklists[1].items.map(\.index), [2, 3])
        XCTAssertEqual(checklists[1].items[0].indentLevel, 1)
        XCTAssertEqual(checklists[1].items[1].defaultChecked, true)

        let state: [String: Bool] = ["0": true, "1": false]
        XCTAssertTrue(checklists[0].isChecked(checklists[0].items[0], state: state))
        XCTAssertFalse(checklists[0].isChecked(checklists[0].items[1], state: state))
        XCTAssertEqual(checklists[0].completedCount(state: state), 1)
    }
}
