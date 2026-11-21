import XCTest
@testable import VesperCore

/// The web's markdown rewrites, with the cases from web/lib/wikilinks.test.mjs and
/// chat-sources.test.mjs.
final class MarkdownSourceTests: XCTestCase {
    func testWikiLinksRenderAsTitlesWithoutChangingTheirDestinations() {
        let ref = MarkdownSource.wikiRefs("[[Campaign/Sessions/Session 27#Summary]]")[0]
        XCTAssertEqual(MarkdownSource.defaultLabel(target: ref.target, anchor: ref.anchor, display: ref.display), "Session 27 › Summary")
        XCTAssertEqual(MarkdownSource.defaultLabel(target: ref.target, anchor: ref.anchor, display: "Recap"), "Recap")
        XCTAssertEqual(MarkdownSource.linkify("[[Campaign/Sessions/Session 27]]"), "[Session 27](wikilink:Campaign%2FSessions%2FSession%2027)")
        XCTAssertEqual(MarkdownSource.linkify("`[[Campaign/Note]]`\n```\n[[Campaign/Note]]\n```"), "`[[Campaign/Note]]`\n```\n[[Campaign/Note]]\n```")
    }

    func testWikiRefsSplitTargetAnchorAndDisplay() {
        let refs = MarkdownSource.wikiRefs("![[a/b#c|d]] and [[x\\|y]] and [[|]]")
        XCTAssertEqual(refs, [
            .init(ref: "a/b#c|d", target: "a/b", anchor: "c", display: "d", embed: true),
            .init(ref: "x|y", target: "x", anchor: "", display: "y", embed: false),
        ])
    }

    func testOnlyNumbersTheListDefinesBecomeCitationsAndNeverInCode() {
        XCTAssertEqual(MarkdownSource.linkCitations("See [1][2] and [9].", numbers: [1, 2]), "See [1](cite:1)[2](cite:2) and [9].")
        XCTAssertEqual(MarkdownSource.linkCitations("`[1]`\n```\n[1]\n```\n[[1]] [1](x) [1]: y", numbers: [1]), "`[1]`\n```\n[1]\n```\n[[1]] [1](x) [1]: y")
        XCTAssertEqual(MarkdownSource.linkCitations("[1]", numbers: []), "[1]")
    }

    func testBareTicketKeysBecomeWikiLinksOutsideCodeAndLinks() {
        XCTAssertEqual(MarkdownSource.linkTicketKeys("PAY-1 and [[PAY-2]] and `PAY-3`"), "[[PAY-1]] and [[PAY-2]] and `PAY-3`")
        XCTAssertEqual(MarkdownSource.linkTicketKeys("éPAY-1 xPAY-2 PAY-3x"), "é[[PAY-1]] xPAY-2 PAY-3x")
        XCTAssertEqual(MarkdownSource.linkTicketKeys("```\nPAY-1\n```"), "```\nPAY-1\n```")
    }

    func testEncodeURIComponentMatchesJavaScript() {
        XCTAssertEqual(MarkdownSource.encodeURIComponent("a b/c#d|é!*'()~"), "a%20b%2Fc%23d%7C%C3%A9!*'()~")
    }

    func testMathIsMarkedForTheParser() {
        let doc = MarkdownParser.parse("$$\nx^2\n$$\n\nCost $$a_1$$ and $5, `$$b$$` stays code.")
        XCTAssertEqual(doc.blocks, [
            .math("x^2"),
            .paragraph([.text("Cost "), .math("a_1"), .text(" and $5, "), .code("$$b$$"), .text(" stays code.")]),
        ])
    }

    func testFenceLanguagesFollowTheWeb() {
        XCTAssertEqual(MarkdownSource.language(fromFence: "TS title=x"), "typescript")
        XCTAssertEqual(MarkdownSource.language(fromFence: "bash"), "shellscript")
        XCTAssertNil(MarkdownSource.language(fromFence: "mermaid"))
        XCTAssertEqual(MarkdownSource.fenceLabel(""), "text")
        XCTAssertEqual(MarkdownSource.fenceLabel("go main.go"), "go")
    }
}
