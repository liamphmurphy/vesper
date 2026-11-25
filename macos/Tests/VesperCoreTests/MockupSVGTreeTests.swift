import XCTest
@testable import VesperCore

final class MockupSVGTreeTests: XCTestCase {
    func testRoundTripKeepsAttributeOrderCommentsAndWhitespace() throws {
        let src = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- header -->
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" width="10">
          <rect y="1" x="2" fill="#fff"/>
          <text x="1" y="2">a &amp; b &lt;c&gt; &#x41;</text>
        </svg>

        """
        let tree = try MockupSVGTree.parse(src)
        XCTAssertEqual(tree.serialized(), src.replacingOccurrences(of: "&#x41;", with: "A"))
        let rect = try XCTUnwrap(tree.node(at: "1"))
        XCTAssertEqual(rect.name, "rect")
        XCTAssertEqual(rect.attributes.map(\.name), ["y", "x", "fill"])
        XCTAssertEqual(tree.node(at: "3")?.textContent, "a & b <c> A")
    }

    func testPathsCountTextAndCommentNodes() throws {
        let tree = try MockupSVGTree.parse(#"<svg xmlns="http://www.w3.org/2000/svg"> <!--c--> <g><rect/></g></svg>"#)
        XCTAssertEqual(tree.elementPaths(), ["", "3", "3.0"])
        XCTAssertEqual(tree.node(at: "3.0")?.name, "rect")
        XCTAssertNil(tree.node(at: "9"))
        XCTAssertNil(tree.node(at: "x"))
        XCTAssertEqual(MockupSVGTree.parentPath(of: "3.0"), "3")
        XCTAssertEqual(MockupSVGTree.parentPath(of: "3"), "")
        XCTAssertNil(MockupSVGTree.parentPath(of: ""))
    }

    func testSetAttributeKeepsPositionAndRemoves() throws {
        var tree = try MockupSVGTree.parse(#"<svg><rect a="1" b="2" c="3"/></svg>"#)
        tree.update(at: "0") { n in
            n.setAttribute("b", "9")
            n.setAttribute("a", nil)
            n.setAttribute("d", "4")
        }
        XCTAssertEqual(tree.serialized(), #"<svg><rect b="9" c="3" d="4"/></svg>"#)
    }

    func testAttributeEscapingRoundTrips() throws {
        var tree = try MockupSVGTree.parse(#"<svg><text x="1">t</text></svg>"#)
        tree.update(at: "0") { $0.setAttribute("aria-label", #"a "q" & <b>"#) }
        let again = try MockupSVGTree.parse(tree.serialized())
        XCTAssertEqual(again.node(at: "0")?.attribute("aria-label"), #"a "q" & <b>"#)
    }

    func testRejectsMalformedAndUnsafeInput() {
        let bad = [
            "<svg><rect></svg>",
            "<svg a=1/>",
            "<svg a=\"1\" a=\"2\"/>",
            "<!DOCTYPE svg><svg/>",
            "<svg>&nope;</svg>",
            "<svg/><svg/>",
            "text<svg/>",
            "<svg><?php ?></svg>",
            "",
        ]
        for src in bad {
            XCTAssertThrowsError(try MockupSVGTree.parse(src), src)
        }
    }

    func testParseErrorReportsLine() {
        do {
            _ = try MockupSVGTree.parse("<svg>\n<g>\n</svg>")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.line, 3)
        }
    }
}
