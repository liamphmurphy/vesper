import XCTest
@testable import VesperCore

/// The shared corpus keeps this port and the server's `NormalizeMockupSVG` in step.
final class MockupSVGNormalizerTests: XCTestCase {
    static func canonical(_ svg: String) throws -> String { try MockupSVGTree.parse(svg).serialized() }

    /// Outputs are compared after both pass through `MockupSVGTree`, which spells quotes and empty
    /// elements one way; where a fixture is already in that spelling, the text must match exactly.
    func testNormalizeCorpus() throws {
        let inputs = try MockupSVGProfileTests.files("normalize").filter { $0.lastPathComponent.hasSuffix(".in.svg") }
        XCTAssertGreaterThan(inputs.count, 10)
        for f in inputs {
            let name = f.lastPathComponent
            let want = try String(contentsOf: f.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: ".in.svg", with: ".out.svg")), encoding: .utf8)
            let got = try MockupSVGNormalizer.normalize(try String(contentsOf: f, encoding: .utf8))
            XCTAssertEqual(try Self.canonical(got), try Self.canonical(want), name)
            if try Self.canonical(want) == want { XCTAssertEqual(got, want, "\(name) exact text") }
            for bad in ["<style", " class=", " style="] {
                XCTAssertFalse(got.contains(bad), "\(name) still contains \(bad)")
            }
            XCTAssertEqual(MockupSVGProfile.violations(got), [], name)
        }
    }

    func testRejectCorpusNamesTheRule() throws {
        let mentions = [
            "attribute-selector": #""rect[width]" uses an attribute selector"#,
            "child-combinator": #""g > rect" uses a child combinator"#,
            "descendant-selector": #""g rect" uses a descendant selector"#,
            "media-query": #"at-rule "@media""#,
            "pseudo-class": #""rect:hover" uses the pseudo-class ":hover""#,
            "unknown-property": #"the property "filter""#,
            "var-value": #""var(--accent)""#,
        ]
        let files = try MockupSVGProfileTests.files("normalize-reject")
        XCTAssertGreaterThan(files.count, 5)
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            let want = try XCTUnwrap(mentions[name], "add the expected message for \(name) to the table")
            XCTAssertThrowsError(try MockupSVGNormalizer.normalize(try String(contentsOf: f, encoding: .utf8)), name) { error in
                let message = (error as? MockupSVGNormalizeError)?.message ?? ""
                XCTAssertTrue(message.contains(want), "\(name): \(message) doesn't mention \(want)")
            }
        }
    }

    func testPassThrough() throws {
        for body in [#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect  width='1'   height="1"/></svg>"#,
                     #"<svg xmlns="http://www.w3.org/2000/svg"><style>g rect{}</style><rect class="x">"#] {
            XCTAssertEqual(try MockupSVGNormalizer.normalize(body), body)
        }
    }

    /// The server's `TestCascadeOrder`, case for case.
    func testCascadeOrder() throws {
        let cases: [(String, String, String, String)] = [
            ("css beats presentation attribute", "rect{fill:red}", #"fill="blue""#, #"fill="red""#),
            ("class beats type", ".c{fill:red} rect{fill:blue}", "", #"fill="red""#),
            ("id beats class", "#r{fill:red} .c{fill:blue}", "", #"fill="red""#),
            ("compound beats single", ".c{fill:blue} rect.c{fill:red}", "", #"fill="red""#),
            ("later rule wins at equal specificity", ".c{fill:blue} .c{fill:red}", "", #"fill="red""#),
            ("later declaration in a rule wins", ".c{fill:blue;fill:red}", "", #"fill="red""#),
            ("most specific matching selector of a list", "#r, rect{fill:red} .c{fill:blue}", "", #"fill="red""#),
            ("style beats id", "#r{fill:blue}", #"style="fill:red""#, #"fill="red""#),
            ("sheet important beats style", "rect{fill:red!important}", #"style="fill:blue""#, #"fill="red""#),
            ("important type beats id", "rect{fill:red !IMPORTANT} #r{fill:blue}", "", #"fill="red""#),
            ("style important beats sheet important", "#r{fill:blue!important}", #"style="fill:red!important""#, #"fill="red""#),
            ("later style declaration wins", "", #"style="fill:blue;fill:red""#, #"fill="red""#),
            ("universal applies", "*{fill:red}", "", #"fill="red""#),
            ("value escaped", #"rect{font-family:"A&lt;B"&amp;x}"#, "", #"font-family="&quot;A&lt;B&quot;&amp;x""#),
        ]
        for (name, css, attrs, want) in cases {
            let got = try MockupSVGNormalizer.normalize(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><style>"# + css
                + #"</style><rect id="r" class="c" "# + attrs + "/></svg>")
            let rect = try XCTUnwrap(got.range(of: "<rect[^>]*>", options: .regularExpression).map { String(got[$0]) }, name)
            XCTAssertEqual(rect, #"<rect id="r" "# + want + "/>", name)
        }
    }

    func testSelectorErrors() {
        let cases = [
            "g rect": "descendant selector", "g>rect": "child combinator", "a + b": "sibling combinator (+)",
            "a ~ b": "sibling combinator (~)", "rect::before": #"pseudo-element "::before""#, "a:not(.b)": #"pseudo-class ":not""#,
            ".a[x=y]": "attribute selector", "&.a": "nesting", "svg|rect": "namespace selector", ".": "malformed selector",
            "rect,": "empty selector",
        ]
        for (sel, want) in cases {
            var css = MockupSVGCSS(strict: true)
            XCTAssertThrowsError(try css.parseSelectorList(sel), sel) { error in
                XCTAssertTrue((error as? MockupSVGNormalizeError)?.message.contains(want) == true, "\(sel): \(error)")
            }
        }
    }

    func testStylesheetErrors() {
        let cases = [
            "@import url(a.css);": #"at-rule "@import""#, "@font-face { font-family: x }": #"at-rule "@font-face""#,
            ".a { .b { fill: red } }": "nests rules", ".a { fill: red": "missing its closing }", ".a { fill: calc(1 + 2) }": "calc()",
            ".a { --accent: red }": #"the property "--accent""#, ".a { fill }": "without a colon", ".a { fill: }": "no value",
            "/* open": "unterminated /* comment", ".a { fill: \\72 ed }": "CSS escape",
        ]
        for (sheet, want) in cases {
            var css = MockupSVGCSS(strict: true)
            XCTAssertThrowsError(try css.parseStylesheet(sheet), sheet) { error in
                XCTAssertTrue((error as? MockupSVGNormalizeError)?.message.contains(want) == true, "\(sheet): \(error)")
            }
        }
    }
}
