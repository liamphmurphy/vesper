import AppKit
import XCTest
@testable import VesperCore

/// The attributed text the native renderer draws, checked against the web's markdown.tsx behaviour.
@MainActor
final class MarkdownRendererTests: XCTestCase {
    let theme = ThemeTokens(mode: .light, colors: ["accent": "#2A78D6", "text": "#111111", "text-tertiary": "#999999"])

    func render(_ md: String, chat: Bool = false, citations: [Int] = [], options: MarkdownRenderOptions = MarkdownRenderOptions()) -> MarkdownRendering {
        var options = options
        options.codeBlocks = options.codeBlocks || chat
        return MarkdownRenderer.render(MarkdownParser.parse(md, chat: chat, citations: citations), theme: theme, options: options)
    }

    func attribute(_ key: NSAttributedString.Key, of substring: String, in rendering: MarkdownRendering) -> Any? {
        let range = (rendering.text.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "\(substring) not rendered")
        guard range.location != NSNotFound else { return nil }
        return rendering.text.attribute(key, at: range.location, effectiveRange: nil)
    }

    /// Every fixture renders all of its text, in order: nothing the web shows goes missing.
    func testEveryFixtureRendersItsTextInOrder() throws {
        let tests = MarkdownSnapshotTests()
        for fixture in try tests.fixtures() {
            let expected = try tests.expected(fixture.name)
            var fragments: [String] = []
            func collect(_ node: Any) {
                guard let node = node as? [String: Any] else { return }
                if let type = node["type"] as? String, ["text", "inlineCode"].contains(type), let value = node["value"] as? String {
                    fragments += value.split(whereSeparator: \.isWhitespace).map(String.init)
                }
                (node["children"] as? [Any])?.forEach(collect)
                (node["footnotes"] as? [Any])?.forEach(collect)
            }
            collect(expected["ast"] as Any)
            let source = try String(contentsOf: MarkdownSnapshotTests.root.appendingPathComponent("fixtures/\(fixture.name).md"), encoding: .utf8)
            let rendering = MarkdownRenderer.render(MarkdownParser.parse(source, chat: fixture.chat ?? false, citations: fixture.cites ?? []), theme: theme, options: MarkdownRenderOptions(codeBlocks: fixture.chat ?? false))
            let text = rendering.text.string.replacingOccurrences(of: "\u{2028}", with: " ")
            var cursor = text.startIndex
            for fragment in fragments {
                guard let found = text.range(of: fragment, range: cursor..<text.endIndex) else {
                    XCTFail("fixture \(fixture.name): \"\(fragment)\" missing or out of order")
                    break
                }
                cursor = found.upperBound
            }
        }
    }

    func testSoftBreaksAreSpacesAndHardBreaksStayInTheParagraph() {
        let r = render("one\ntwo\\\nthree")
        XCTAssertEqual(r.text.string, "one two\u{2028}three")
    }

    func testWikiLinksFollowTheirResolution() {
        var options = MarkdownRenderOptions()
        let pending = render("See [[Roadmap]].", options: options)
        XCTAssertEqual(MarkdownParser.parse("See [[Roadmap]] and [[Roadmap]].").wikiRefs, ["Roadmap"])
        XCTAssertNil(attribute(.link, of: "Roadmap", in: pending))

        options.links = ["Roadmap": .resolved(href: "/knowledge/pages/roadmap", title: "Page · Roadmap")]
        let resolved = render("See [[Roadmap]].", options: options)
        XCTAssertEqual((attribute(.link, of: "Roadmap", in: resolved) as? URL)?.absoluteString, "/knowledge/pages/roadmap")
        XCTAssertEqual(attribute(.toolTip, of: "Roadmap", in: resolved) as? String, "Page · Roadmap")

        options.links = ["Roadmap": .unresolved]
        let ghost = render("See [[Roadmap]].", options: options)
        let url = attribute(.link, of: "Roadmap", in: ghost) as? URL
        XCTAssertEqual(url.flatMap(MarkdownLinkTarget.init(url:)), .ghost(target: "Roadmap"))
        XCTAssertNotNil(attribute(.underlineStyle, of: "Roadmap", in: ghost))
    }

    func testChatLinksTicketKeysAndCitations() {
        let r = render("PAY-214 shipped [1].", chat: true, citations: [1])
        XCTAssertEqual(MarkdownParser.parse("PAY-214 shipped [1].", chat: true, citations: [1]).wikiRefs, ["PAY-214"])
        let cite = attribute(.link, of: "\u{202F}1\u{202F}", in: r) as? URL
        XCTAssertEqual(cite.flatMap(MarkdownLinkTarget.init(url:)), .citation(1))
    }

    func testChatCodeFenceHasAHeaderAndPaletteColours() throws {
        var options = MarkdownRenderOptions(codeBlocks: true)
        let plain = render("```go\nfunc main() {}\n```", options: options)
        XCTAssertEqual(MarkdownParser.parse("```go\nfunc main() {}\n```").codeBlocks, [MarkdownCodeBlock(code: "func main() {}", language: "go")])
        XCTAssertTrue(plain.text.string.hasPrefix("go\tCopy\n"))
        XCTAssertEqual((attribute(.link, of: "Copy", in: plain) as? URL).flatMap(MarkdownLinkTarget.init(url:)), .copyCode(0))

        options.highlights = [0: [[CodeToken(content: "func", light: "#D73A49", dark: "#F97583"), CodeToken(content: " main() {}", light: "#24292E", dark: "#E1E4E8")]]]
        let colored = render("```go\nfunc main() {}\n```", options: options)
        let keyword = try XCTUnwrap(attribute(.foregroundColor, of: "func", in: colored) as? NSColor)
        let expected = try XCTUnwrap(RGBA(hex: CodePalette.light.series[7]))
        XCTAssertEqual(keyword.redComponent, expected.red, accuracy: 0.01)
        XCTAssertEqual(keyword.blueComponent, expected.blue, accuracy: 0.01)
    }

    func testLongChatCodeFoldsAfterTwentyLines() {
        let code = (1...25).map { "line \($0)" }.joined(separator: "\n")
        var options = MarkdownRenderOptions(codeBlocks: true)
        let folded = render("```\n\(code)\n```", options: options)
        XCTAssertTrue(folded.text.string.contains("line 20"))
        XCTAssertFalse(folded.text.string.contains("line 21"))
        XCTAssertEqual((attribute(.link, of: "Show 5 more lines", in: folded) as? URL).flatMap(MarkdownLinkTarget.init(url:)), .toggleCode(0))
        options.expandedCodeBlocks = [0]
        let open = render("```\n\(code)\n```", options: options)
        XCTAssertTrue(open.text.string.contains("line 25"))
        XCTAssertTrue(open.text.string.contains("Show less"))
    }

    func testOutsideTheChatCodeIsAPlainBox() throws {
        let r = render("```go\nfunc main() {}\n```")
        XCTAssertEqual(r.text.string, "func main() {}")
        let decoration = try XCTUnwrap(r.text.attribute(.markdownDecoration, at: 0, effectiveRange: nil) as? MarkdownDecoration)
        XCTAssertEqual(decoration.box?.isFirst, true)
        XCTAssertEqual(decoration.box?.isLast, true)
    }

    func testListsGetMarkersAndTaskListsCheckboxes() {
        XCTAssertEqual(render("- a\n- b").text.string, "\t•\ta\n\t•\tb")
        XCTAssertEqual(render("3. a\n4. b").text.string, "\t3.\ta\n\t4.\tb")
        let tasks = render("- [x] done\n- [ ] open").text.string
        XCTAssertTrue(tasks.contains("done") && tasks.contains("open"))
        XCTAssertFalse(tasks.contains("•"))
    }

    func testQuoteBarsSpanTheQuote() throws {
        let r = render("> one\n>\n> two\n\nafter")
        let ns = r.text.string as NSString
        let first = try XCTUnwrap(r.text.attribute(.markdownDecoration, at: ns.range(of: "one").location, effectiveRange: nil) as? MarkdownDecoration)
        let second = try XCTUnwrap(r.text.attribute(.markdownDecoration, at: ns.range(of: "two").location, effectiveRange: nil) as? MarkdownDecoration)
        XCTAssertEqual(first.quoteBars.map(\.isFirst), [true])
        XCTAssertEqual(first.quoteBars.map(\.isLast), [false])
        XCTAssertEqual(second.quoteBars.map(\.isLast), [true])
        XCTAssertNil(r.text.attribute(.markdownDecoration, at: ns.range(of: "after").location, effectiveRange: nil))
    }

    func testTablesAreTabbedRowsInOneBox() throws {
        let r = render("| A | B |\n| - | -: |\n| 1 | 2 |\n| 3 | 4 |")
        XCTAssertEqual(r.text.string, "\tA\tB\n\t1\t2\n\t3\t4")
        let ns = r.text.string as NSString
        let boxes = try ["A", "1", "3"].map { try XCTUnwrap((r.text.attribute(.markdownDecoration, at: ns.range(of: $0).location, effectiveRange: nil) as? MarkdownDecoration)?.box) }
        XCTAssertEqual(boxes.map(\.isFirst), [true, false, false])
        XCTAssertEqual(boxes.map(\.isLast), [false, false, true])
        XCTAssertNotNil(boxes[0].fill)
        let style = try XCTUnwrap(r.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.map(\.alignment), [.left, .right])
    }

    func testFootnotesListAtTheEndWithBackLinks() {
        let r = render("Claim[^a].\n\n[^a]: The note.")
        XCTAssertEqual(r.text.string, "Claim1.\n\t1.\tThe note. ↩")
        XCTAssertEqual((attribute(.link, of: "↩", in: r) as? URL).flatMap(MarkdownLinkTarget.init(url:)), .footnoteReference(1))
        XCTAssertEqual(r.footnotes[1], ("Claim1.\n" as NSString).length)
        XCTAssertEqual(r.footnoteReferences[1], 0)
    }

    func testDocumentHeadingsGetAnchors() {
        let r = render("# Notes\n\ntext\n\n## Notes", options: MarkdownRenderOptions(anchors: true))
        XCTAssertEqual(r.anchors["notes"], 0)
        XCTAssertNotNil(r.anchors["notes-2"])
        XCTAssertEqual(MarkdownAnchors.slug("Hello, World 2!"), "hello-world-2")
        XCTAssertEqual(MarkdownAnchors.slug("¿?"), "section")
    }

    func testImagesShowTheirAltTextUntilLoaded() {
        let md = "![A cat](https://example.com/cat.png)"
        XCTAssertEqual(MarkdownParser.parse(md).imageURLs, ["https://example.com/cat.png"])
        XCTAssertEqual(render(md).text.string, "A cat")
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let loaded = render(md, options: MarkdownRenderOptions(images: ["https://example.com/cat.png": image]))
        XCTAssertNotNil(loaded.text.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testRawHTMLShowsAsText() {
        XCTAssertEqual(render("<b>hi</b> there").text.string, "<b>hi</b> there")
    }

    func testLinkTargets() {
        XCTAssertEqual(MarkdownLinkTarget(url: URL(string: "/tickets/PAY-1")!), .path("/tickets/PAY-1"))
        XCTAssertEqual(MarkdownLinkTarget(url: URL(string: "https://example.com")!), .external(URL(string: "https://example.com")!))
        XCTAssertEqual(MarkdownLinkTarget(url: URL(string: "#goals")!), .anchor("goals"))
        XCTAssertEqual(MarkdownLinkTarget(url: URL(string: "wikilink:notes%2FPlan%23Goals%7Cthe%20plan")!), .ghost(target: "notes/Plan"))
        XCTAssertNil(MarkdownLinkTarget(url: URL(string: "javascript:alert(1)")!))
    }

    func testFindRanges() {
        XCTAssertEqual(MarkdownFind.ranges(of: "ab", in: "Ab xab", caseSensitive: false), [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        XCTAssertEqual(MarkdownFind.ranges(of: "ab", in: "Ab xab", caseSensitive: true), [NSRange(location: 4, length: 2)])
        XCTAssertEqual(MarkdownFind.ranges(of: "", in: "abc", caseSensitive: false), [])
    }

    func testLinkStateFromResolvedTargets() {
        XCTAssertEqual(MarkdownLinkState(API.LinkTarget(displayId: "PAY-1", href: "/tickets/PAY-1", kind: .ticket, title: "Fix it")), .resolved(href: "/tickets/PAY-1", title: "Ticket · PAY-1 · Fix it"))
        XCTAssertEqual(MarkdownLinkState(API.LinkTarget(kind: .unresolved, title: "Nope")), .unresolved)
    }
}
