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

    @Test("pasteLibraryEmbed rewrites copied Library URLs at collapsed caret outside code")
    func pasteLibraryEmbedCases() {
        let id = "11111111-2222-4333-8444-555555555555"
        let url = "http://localhost:8000/api/v1/library/\(id)/content"

        let converted = KnowledgeMarkdownFormatting.pasteLibraryEmbed(
            text: "Map: ",
            selection: NSRange(location: 5, length: 0),
            pastedString: url,
            title: "Harbour map"
        )
        #expect(converted?.text == "Map: ![[library:\(id)/Harbour map]]")
        #expect(converted?.selection == NSRange(location: ("Map: ![[library:\(id)/Harbour map]]" as NSString).length, length: 0))

        // Non-empty selection returns nil so URL-over-selection link wrapping still works.
        #expect(KnowledgeMarkdownFormatting.pasteLibraryEmbed(
            text: "See map",
            selection: NSRange(location: 4, length: 3),
            pastedString: url
        ) == nil)

        // Inside inline code returns nil.
        #expect(KnowledgeMarkdownFormatting.pasteLibraryEmbed(
            text: "`code `",
            selection: NSRange(location: 6, length: 0),
            pastedString: url
        ) == nil)

        // Ordinary URLs are untouched.
        #expect(KnowledgeMarkdownFormatting.pasteLibraryEmbed(
            text: "See ",
            selection: NSRange(location: 4, length: 0),
            pastedString: "https://example.com"
        ) == nil)
    }

    @Test("embed completion matches library items by display name and library: prefix")
    func embedCompletionMatchesLibraryItems() {
        let id = "11111111-2222-4333-8444-555555555555"
        let candidates = [
            KnowledgeCompletionCandidate(kind: .embed, title: "map.png", insertRef: "attachment:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/map.png", detail: "Image"),
            KnowledgeCompletionCandidate(kind: .embed, title: "Harbour map", insertRef: "library:\(id)/Harbour map", detail: "Library · Image"),
        ]

        // Plain display-name query matches Library item directly.
        let nameTrigger = KnowledgeCompletionLogic.matchTrigger(in: "![[Harbour", caretUTF16: 10)!
        let byName = KnowledgeCompletionLogic.rankCandidates(candidates, for: nameTrigger)
        #expect(byName.map(\.title) == ["Harbour map"])

        // `![[library:` filters to Library items only.
        let prefixTrigger = KnowledgeCompletionLogic.matchTrigger(in: "![[library:", caretUTF16: 11)!
        let byPrefix = KnowledgeCompletionLogic.rankCandidates(candidates, for: prefixTrigger)
        #expect(byPrefix.map(\.title) == ["Harbour map"])

        // `![[library:Harbour` matches Library display name even when insertRef has `<uuid>/`.
        let scopedTrigger = KnowledgeCompletionLogic.matchTrigger(in: "![[library:Harbour", caretUTF16: 18)!
        let byScoped = KnowledgeCompletionLogic.rankCandidates(candidates, for: scopedTrigger)
        #expect(byScoped.map(\.title) == ["Harbour map"])
    }
}
