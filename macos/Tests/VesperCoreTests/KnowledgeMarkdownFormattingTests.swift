import Foundation
import Testing
@testable import VesperCore

@Suite("KnowledgeMarkdownFormatting")
struct KnowledgeMarkdownFormattingTests {
    @Test("wrapOrToggle wraps plain selection and toggles off when already wrapped")
    func wrapAndToggleBold() {
        let wrapped = KnowledgeMarkdownFormatting.wrapOrToggle(
            text: "hello world",
            selection: NSRange(location: 6, length: 5),
            prefix: "**",
            suffix: "**"
        )
        #expect(wrapped.text == "hello **world**")
        #expect(wrapped.selection == NSRange(location: 8, length: 5))

        // Toggling again with the inner selection unwraps it.
        let unwrappedInner = KnowledgeMarkdownFormatting.wrapOrToggle(
            text: wrapped.text,
            selection: wrapped.selection,
            prefix: "**",
            suffix: "**"
        )
        #expect(unwrappedInner.text == "hello world")
        #expect(unwrappedInner.selection == NSRange(location: 6, length: 5))

        // Toggling when the selection includes the delimiters also unwraps it.
        let unwrappedOuter = KnowledgeMarkdownFormatting.wrapOrToggle(
            text: "hello **world**",
            selection: NSRange(location: 6, length: 9),
            prefix: "**",
            suffix: "**"
        )
        #expect(unwrappedOuter.text == "hello world")
        #expect(unwrappedOuter.selection == NSRange(location: 6, length: 5))
    }

    @Test("wrapOrToggle places caret between delimiters on collapsed selection")
    func wrapCollapsed() {
        let res = KnowledgeMarkdownFormatting.wrapOrToggle(
            text: "abc",
            selection: NSRange(location: 1, length: 0),
            prefix: "*",
            suffix: "*"
        )
        #expect(res.text == "a**bc")
        #expect(res.selection == NSRange(location: 2, length: 0))
    }

    @Test("toggleLinePrefix adds, removes, and replaces heading levels")
    func toggleHeadingsAndLists() {
        let h1 = KnowledgeMarkdownFormatting.toggleLinePrefix(
            text: "Intro\nBody",
            selection: NSRange(location: 2, length: 0),
            prefix: "# "
        )
        #expect(h1.text == "# Intro\nBody")
        #expect(h1.selection == NSRange(location: 4, length: 0))

        // Switching H1 -> H2 replaces `# ` with `## ` instead of stacking.
        let h2 = KnowledgeMarkdownFormatting.toggleLinePrefix(
            text: h1.text,
            selection: h1.selection,
            prefix: "## "
        )
        #expect(h2.text == "## Intro\nBody")
        #expect(h2.selection == NSRange(location: 5, length: 0))

        // Toggling H2 again removes it.
        let plain = KnowledgeMarkdownFormatting.toggleLinePrefix(
            text: h2.text,
            selection: h2.selection,
            prefix: "## "
        )
        #expect(plain.text == "Intro\nBody")
        #expect(plain.selection == NSRange(location: 2, length: 0))
    }

    @Test("applyLink wraps selected text or inserts URL as label when collapsed")
    func applyLinkCases() {
        let withSelection = KnowledgeMarkdownFormatting.applyLink(
            text: "See docs here",
            selection: NSRange(location: 4, length: 4),
            url: "https://example.com"
        )
        #expect(withSelection.text == "See [docs](https://example.com) here")
        #expect(withSelection.selection == NSRange(location: 5, length: 4))

        let collapsed = KnowledgeMarkdownFormatting.applyLink(
            text: "See ",
            selection: NSRange(location: 4, length: 0),
            url: "https://example.com"
        )
        #expect(collapsed.text == "See [https://example.com](https://example.com)")
        #expect(collapsed.selection == NSRange(location: 5, length: 19))
    }

    @Test("insertBlock inserts after selection and moves caret to end of block")
    func insertBlockTest() {
        let res = KnowledgeMarkdownFormatting.insertBlock(
            text: "Line 1",
            selection: NSRange(location: 6, length: 0),
            block: "\n---\n"
        )
        #expect(res.text == "Line 1\n---\n")
        #expect(res.selection == NSRange(location: 11, length: 0))
    }
}
