import CoreGraphics
import XCTest
@testable import VesperCore

final class MockupSVGEditingTests: XCTestCase {
    /// A wireframe as agents write them: declaration, comments, indentation, nested groups.
    /// Root children: 0 ws, 1 comment, 2 ws, 3 rect(bg), 4 ws, 5 comment, 6 ws, 7 g(header),
    /// 8 ws, 9 text(title), 10 ws, 11 rect(card), 12 ws, 13 path, 14 "\n".
    private let wireframe = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300" width="400" height="300">
      <!-- Background -->
      <rect id="bg" x="0" y="0" width="400" height="300" fill="#fff"/>
      <!-- Header -->
      <g id="header" data-vid="v1" transform="translate(10 20)">
        <rect id="bar" x="0" y="0" width="380" height="40" rx="4" fill="#eee"/>
        <text x="12" y="26" font-size="16">Menu</text>
      </g>
      <text x="20" y="100" font-size="20" font-family="sans-serif"><tspan x="20">Title &amp; more</tspan></text>
      <rect x="20" y="120" width="160" height="100" rx="6" fill="url(#bg)" stroke="#9CA3AF"/>
      <path d="M0 0 L10 10" stroke="#000"/>
    </svg>

    """

    private func tree(_ s: String) throws -> MockupSVGTree { try MockupSVGTree.parse(s) }

    /// The one span that differs between two sources (shortest, after the common prefix and suffix).
    private func changedSpan(_ before: String, _ after: String) -> (old: String, new: String) {
        let a = Array(before), b = Array(after)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        return (String(a[p..<(a.count - s)]), String(b[p..<(b.count - s)]))
    }

    func testFixtureRoundTripsAndPathsAreAsDocumented() throws {
        let t = try tree(wireframe)
        XCTAssertEqual(t.serialized(), wireframe)
        XCTAssertEqual(t.node(at: "7")?.attribute("id"), "header")
        XCTAssertEqual(t.node(at: "13")?.name, "path")
        XCTAssertEqual(t.node(at: "14")?.text, "\n")
    }

    // MARK: Numbers

    func testNumberFormatting() {
        XCTAssertEqual(MockupSVGEditing.number(16), "16")
        XCTAssertEqual(MockupSVGEditing.number(16.5), "16.5")
        XCTAssertEqual(MockupSVGEditing.number(1.0 / 3), "0.33")
        XCTAssertEqual(MockupSVGEditing.number(-2), "-2")
        XCTAssertEqual(MockupSVGEditing.number(-0.001), "0")
        XCTAssertEqual(MockupSVGEditing.number(-0.0), "0")
        XCTAssertEqual(MockupSVGEditing.number(1e21), "1000000000000000000000")
        XCTAssertEqual(MockupSVGEditing.number(0.10), "0.1")
        XCTAssertEqual(MockupSVGEditing.number(2.0 / 3, fractionDigits: 4), "0.6667")
    }

    // MARK: Translate

    func testTranslatePrependsMergesAndDrops() throws {
        // The background rect has no transform: one is added, and nothing else changes.
        let r1 = try XCTUnwrap(MockupSVGEditing.translate(wireframe, path: "3", dx: 5, dy: -2.5))
        XCTAssertEqual(r1.selection, "3")
        let span = changedSpan(wireframe, r1.source)
        XCTAssertEqual(span.old, "")
        XCTAssertEqual(span.new, #" transform="translate(5 -2.5)""#)

        // The header group's leading translate is merged into.
        let r2 = try XCTUnwrap(MockupSVGEditing.translate(wireframe, path: "7", dx: 1.004, dy: 0.5))
        XCTAssertEqual(try tree(r2.source).node(at: "7")?.attribute("transform"), "translate(11 20.5)")

        // Back to 0 0 removes the attribute.
        let r3 = try XCTUnwrap(MockupSVGEditing.translate(wireframe, path: "7", dx: -10, dy: -20))
        XCTAssertNil(try tree(r3.source).node(at: "7")?.attribute("transform"))
        XCTAssertFalse(r3.source.contains("transform"))
    }

    func testTranslateKeepsOtherTransforms() throws {
        let src = #"<svg viewBox="0 0 10 10"><rect transform="rotate(45 5 5)"/><rect transform="translate(3, 4) , scale(2)"/></svg>"#
        let a = try XCTUnwrap(MockupSVGEditing.translate(src, path: "0", dx: 2, dy: 0))
        XCTAssertEqual(try tree(a.source).node(at: "0")?.attribute("transform"), "translate(2 0) rotate(45 5 5)")
        let b = try XCTUnwrap(MockupSVGEditing.translate(src, path: "1", dx: -3, dy: -4))
        XCTAssertEqual(try tree(b.source).node(at: "1")?.attribute("transform"), "scale(2)")
        let single = #"<svg><rect transform="translate(3)"/></svg>"#
        let c = try XCTUnwrap(MockupSVGEditing.translate(single, path: "0", dx: 1, dy: 1))
        XCTAssertEqual(try tree(c.source).node(at: "0")?.attribute("transform"), "translate(4 1)")
    }

    func testTranslateRefusals() {
        XCTAssertNil(MockupSVGEditing.translate(wireframe, path: "", dx: 1, dy: 1))
        XCTAssertNil(MockupSVGEditing.translate(wireframe, path: "0", dx: 1, dy: 1), "text node")
        XCTAssertNil(MockupSVGEditing.translate(wireframe, path: "99", dx: 1, dy: 1))
        XCTAssertNil(MockupSVGEditing.translate(wireframe, path: "3", dx: 0.001, dy: 0))
        XCTAssertNil(MockupSVGEditing.translate(wireframe, path: "3", dx: .nan, dy: 0))
        XCTAssertNil(MockupSVGEditing.translate("<svg>", path: "0", dx: 1, dy: 1))
        XCTAssertNil(MockupSVGEditing.translate(#"<svg><rect transform="bogus"/></svg>"#, path: "0", dx: 1, dy: 1))
    }

    // MARK: Attributes and text

    func testSetAttributeKeepsPositionAndRemoves() throws {
        let r = try XCTUnwrap(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "width", value: "200"))
        XCTAssertEqual(r.selection, "3")
        XCTAssertEqual(changedSpan(wireframe, r.source).new, "2")
        XCTAssertEqual(try tree(r.source).node(at: "3")?.attributes.map(\.name), ["id", "x", "y", "width", "height", "fill"])

        let removed = try XCTUnwrap(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "fill", value: ""))
        XCTAssertEqual(changedSpan(wireframe, removed.source).old, ##" fill="#fff""##)
        XCTAssertNotNil(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "fill", value: nil))

        let added = try XCTUnwrap(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "opacity", value: "0.5"))
        XCTAssertEqual(try tree(added.source).node(at: "3")?.attributes.last?.name, "opacity")
        let escaped = try XCTUnwrap(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "aria-label", value: #"a "b" & <c>"#))
        XCTAssertTrue(escaped.source.contains(#"aria-label="a &quot;b&quot; &amp; &lt;c>""#))
        XCTAssertEqual(try tree(escaped.source).node(at: "3")?.attribute("aria-label"), #"a "b" & <c>"#)

        XCTAssertNil(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "fill", value: "#fff"), "no change")
        XCTAssertNil(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "opacity", value: nil), "nothing to remove")
        XCTAssertNil(MockupSVGEditing.setAttribute(wireframe, path: "3", name: "bad name", value: "1"))
        XCTAssertNil(MockupSVGEditing.setAttribute(wireframe, path: "2", name: "fill", value: "#000"))
        XCTAssertNotNil(MockupSVGEditing.setAttribute(wireframe, path: "", name: "viewBox", value: "0 0 800 600"))
    }

    func testSetTextEditsFirstTspanAndEscapes() throws {
        let r = try XCTUnwrap(MockupSVGEditing.setText(wireframe, path: "9", text: "New & <b>"))
        XCTAssertEqual(r.selection, "9")
        let span = changedSpan(wireframe, r.source)
        XCTAssertEqual(span.old, "Title &amp; more")
        XCTAssertEqual(span.new, "New &amp; &lt;b&gt;")
        XCTAssertEqual(try tree(r.source).node(at: "9.0")?.textContent, "New & <b>")
    }

    func testSetTextOnPlainTextKeepsElementChildren() throws {
        let src = #"<svg><text x="1">old <tspan>keep</tspan> tail<!--c--></text><rect/></svg>"#
        let r = try XCTUnwrap(MockupSVGEditing.setText(src, path: "0", text: "x"))
        XCTAssertEqual(r.source, #"<svg><text x="1">old <tspan>x</tspan> tail<!--c--></text><rect/></svg>"#)
        let plain = #"<svg><text>a<title>t</title>b</text></svg>"#
        let p = try XCTUnwrap(MockupSVGEditing.setText(plain, path: "0", text: "new"))
        XCTAssertEqual(p.source, #"<svg><text>new<title>t</title></text></svg>"#)
        XCTAssertEqual(MockupSVGEditing.setText(plain, path: "0", text: "")?.source, #"<svg><text><title>t</title></text></svg>"#)
        XCTAssertNil(MockupSVGEditing.setText(src, path: "1", text: "x"), "not text")
        XCTAssertNil(MockupSVGEditing.setText(src, path: "0", text: "keep"), "no change")
    }

    // MARK: Duplicate and delete

    func testDuplicateInsertsIndentedOffsetCopyWithoutIdentity() throws {
        let r = try XCTUnwrap(MockupSVGEditing.duplicate(wireframe, path: "7"))
        XCTAssertEqual(r.selection, "9")
        let t = try tree(r.source)
        let copy = try XCTUnwrap(t.node(at: "9"))
        XCTAssertEqual(copy.name, "g")
        XCTAssertEqual(copy.attribute("transform"), "translate(26 36)")
        XCTAssertNil(copy.attribute("id"))
        XCTAssertNil(copy.attribute("data-vid"))
        XCTAssertNil(copy.children[1].attribute("id"), "descendant ids are stripped too")
        XCTAssertEqual(t.node(at: "8")?.text, "\n  ")
        XCTAssertEqual(t.node(at: "7")?.attribute("id"), "header", "the original keeps its identity")
        XCTAssertTrue(r.source.contains("</g>\n  <g transform=\"translate(26 36)\">\n    <rect x=\"0\""))

        let back = try XCTUnwrap(MockupSVGEditing.delete(r.source, path: r.selection!))
        XCTAssertNil(back.selection)
        XCTAssertEqual(back.source, wireframe)
    }

    func testDuplicateWithoutLeadingWhitespaceAndRefusals() throws {
        let src = #"<svg><rect x="1"/><rect/></svg>"#
        let r = try XCTUnwrap(MockupSVGEditing.duplicate(src, path: "0"))
        XCTAssertEqual(r.source, #"<svg><rect x="1"/><rect x="1" transform="translate(16 16)"/><rect/></svg>"#)
        XCTAssertEqual(r.selection, "1")
        XCTAssertEqual(MockupSVGEditing.delete(r.source, path: "1")?.source, src)
        XCTAssertNil(MockupSVGEditing.duplicate(src, path: ""))
        XCTAssertNil(MockupSVGEditing.duplicate(src, path: "5"))
    }

    func testDeleteDropsIndentationAndRefusesRootAndReferencedIDs() throws {
        let r = try XCTUnwrap(MockupSVGEditing.delete(wireframe, path: "13"))
        XCTAssertNil(r.selection)
        XCTAssertEqual(r.source, wireframe.replacingOccurrences(of: "\n  <path d=\"M0 0 L10 10\" stroke=\"#000\"/>", with: ""))
        XCTAssertNil(MockupSVGEditing.delete(wireframe, path: ""))
        XCTAssertNil(MockupSVGEditing.delete(wireframe, path: "1"), "a comment isn't an element")
        // The card's fill is url(#bg): deleting #bg would leave a dangling reference.
        XCTAssertNil(MockupSVGEditing.delete(wireframe, path: "3"))
        let refs = ##"<svg><defs><linearGradient id="g"/></defs><g><use href="#u"/></g><rect id="u" fill="url( #g )"/></svg>"##
        XCTAssertNil(MockupSVGEditing.delete(refs, path: "0"))
        XCTAssertNil(MockupSVGEditing.delete(refs, path: "2"))
        XCTAssertNotNil(MockupSVGEditing.delete(refs, path: "1"))
    }

    // MARK: Z-order

    func testForwardThenBackwardRestores() throws {
        // The background rect carries its comment and indentation past the header group's unit.
        let f = try XCTUnwrap(MockupSVGEditing.bringForward(wireframe, path: "3"))
        let t = try tree(f.source)
        XCTAssertEqual(f.selection, "7")
        XCTAssertEqual(t.node(at: "7")?.attribute("id"), "bg")
        XCTAssertEqual(t.node(at: "3")?.attribute("id"), "header")
        XCTAssertEqual(t.node(at: "5")?.text, " Background ")
        let b = try XCTUnwrap(MockupSVGEditing.sendBackward(f.source, path: f.selection!))
        XCTAssertEqual(b.source, wireframe)
        XCTAssertEqual(b.selection, "3")
    }

    func testFrontAndBack() throws {
        let front = try XCTUnwrap(MockupSVGEditing.bringToFront(wireframe, path: "9"))
        XCTAssertEqual(front.selection, "13")
        let t = try tree(front.source)
        XCTAssertEqual(t.node(at: "13")?.name, "text")
        XCTAssertEqual(t.node(at: "14")?.text, "\n", "the root's closing whitespace stays last")
        XCTAssertTrue(front.source.hasSuffix("<path d=\"M0 0 L10 10\" stroke=\"#000\"/>\n  <text x=\"20\" y=\"100\" font-size=\"20\" font-family=\"sans-serif\"><tspan x=\"20\">Title &amp; more</tspan></text>\n</svg>\n"))
        XCTAssertEqual(try MockupSVGTree.parse(front.source).elementPaths().count, try tree(wireframe).elementPaths().count)

        let back = try XCTUnwrap(MockupSVGEditing.sendToBack(wireframe, path: "13"))
        XCTAssertEqual(back.selection, "1")
        XCTAssertTrue(back.source.contains("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 400 300\" width=\"400\" height=\"300\">\n  <path"))
        XCTAssertEqual(try tree(back.source).node(at: "3")?.kind, .comment)
    }

    func testReorderRefusals() {
        XCTAssertNil(MockupSVGEditing.bringForward(wireframe, path: "13"), "already frontmost")
        XCTAssertNil(MockupSVGEditing.bringToFront(wireframe, path: "13"))
        XCTAssertNil(MockupSVGEditing.sendBackward(wireframe, path: "3"), "already at the back")
        XCTAssertNil(MockupSVGEditing.sendToBack(wireframe, path: "3"))
        XCTAssertNil(MockupSVGEditing.bringForward(wireframe, path: ""))
        XCTAssertNil(MockupSVGEditing.bringForward(wireframe, path: "4"))
        XCTAssertNil(MockupSVGEditing.bringForward(wireframe, path: "7.9"))
    }

    func testReorderInsideGroup() throws {
        let r = try XCTUnwrap(MockupSVGEditing.bringForward(wireframe, path: "7.1"))
        XCTAssertEqual(r.selection, "7.3")
        XCTAssertEqual(try tree(r.source).node(at: "7.3")?.attribute("id"), "bar")
        XCTAssertTrue(r.source.contains("\">\n    <text x=\"12\" y=\"26\" font-size=\"16\">Menu</text>\n    <rect id=\"bar\""))
    }

    // MARK: Insert

    /// Attributes the profile allows (docs/dev/mockup-svg-profile.md, Attributes).
    private let profileAttributes: Set<String> = [
        "id", "x", "y", "width", "height", "rx", "ry", "cx", "cy", "r", "x1", "y1", "x2", "y2", "points", "d",
        "transform", "fill", "stroke", "stroke-width", "opacity", "font-family", "font-size", "font-weight",
        "text-anchor",
    ]

    func testInsertEachKind() throws {
        let expected: [MockupSVGShapeKind: String] = [
            .rect: ##"<rect x="120" y="100" width="160" height="100" rx="6" fill="#F3F4F6" stroke="#9CA3AF"/>"##,
            .ellipse: ##"<ellipse cx="200" cy="150" rx="80" ry="50" fill="#F3F4F6" stroke="#9CA3AF"/>"##,
            .line: ##"<line x1="120" y1="150" x2="280" y2="150" stroke="#9CA3AF" stroke-width="2"/>"##,
            .text: ##"<text x="176" y="150" fill="#111827" font-size="16" font-family="sans-serif">Text</text>"##,
        ]
        for kind in MockupSVGShapeKind.allCases {
            let r = try XCTUnwrap(MockupSVGEditing.insert(wireframe, kind: kind, center: nil))
            XCTAssertEqual(r.selection, "15")
            XCTAssertEqual(r.source, wireframe.replacingOccurrences(of: "\n</svg>", with: "\n  " + expected[kind]! + "\n</svg>"), "\(kind)")
            let node = try XCTUnwrap(try tree(r.source).node(at: "15"))
            XCTAssertEqual(node.name, kind.rawValue)
            XCTAssertTrue(Set(node.attributes.map(\.name)).isSubset(of: profileAttributes), "\(kind)")
        }
    }

    func testInsertAtCenterAndViewBoxFallbacks() throws {
        let r = try XCTUnwrap(MockupSVGEditing.insert(wireframe, kind: .ellipse, center: CGPoint(x: 10.5, y: 20.25)))
        XCTAssertEqual(try tree(r.source).node(at: "15")?.attribute("cx"), "10.5")
        XCTAssertEqual(try tree(r.source).node(at: "15")?.attribute("cy"), "20.25")

        let sized = #"<svg width="100px" height="50"/>"#
        let s = try XCTUnwrap(MockupSVGEditing.insert(sized, kind: .ellipse, center: nil))
        XCTAssertEqual(s.source, ##"<svg width="100px" height="50">"## + "\n  " + ##"<ellipse cx="50" cy="25" rx="80" ry="50" fill="#F3F4F6" stroke="#9CA3AF"/></svg>"##)
        XCTAssertEqual(s.selection, "1")

        let offset = #"<svg viewBox="-100,-50 200 101"></svg>"#
        let o = try XCTUnwrap(MockupSVGEditing.insert(offset, kind: .ellipse, center: nil))
        XCTAssertEqual(try tree(o.source).node(at: "1")?.attribute("cy"), "1", "0.5 rounds like Math.round")

        XCTAssertEqual(try tree(XCTUnwrap(MockupSVGEditing.insert("<svg/>", kind: .ellipse, center: nil)).source).root.children[1].attribute("cx"), "640")
        XCTAssertNil(MockupSVGEditing.insert("<svg>", kind: .rect, center: nil))
        XCTAssertNil(MockupSVGEditing.insert(wireframe, kind: .rect, center: CGPoint(x: CGFloat.infinity, y: 0)))
    }

    // MARK: Resize

    private func resized(_ src: String, _ path: String, _ old: CGRect, _ new: CGRect) throws -> MockupSVGNode {
        let r = try XCTUnwrap(MockupSVGEditing.resize(src, path: path, from: old, to: new))
        XCTAssertEqual(r.selection, path)
        return try XCTUnwrap(try tree(r.source).node(at: path))
    }

    func testResizeRectKeepsRadiusAndOnlyTouchesChangedAttributes() throws {
        let r = try XCTUnwrap(MockupSVGEditing.resize(wireframe, path: "11", from: CGRect(x: 20, y: 120, width: 160, height: 100), to: CGRect(x: 20, y: 120, width: 200, height: 100.5)))
        let t = try tree(r.source).node(at: "11")
        XCTAssertEqual(t?.attributes.map(\.value), ["20", "120", "200", "100.5", "6", "url(#bg)", "#9CA3AF"])
        // Flipped drags are normalized: no negative sizes.
        let flipped = try resized(wireframe, "11", CGRect(x: 20, y: 120, width: 160, height: 100), CGRect(x: 180, y: 220, width: -100, height: -50))
        XCTAssertEqual(["x", "y", "width", "height"].map { flipped.attribute($0) }, ["80", "170", "100", "50"])
        XCTAssertNil(MockupSVGEditing.resize(wireframe, path: "11", from: CGRect(x: 20, y: 120, width: 160, height: 100), to: CGRect(x: 20, y: 120, width: 160, height: 100)))
        XCTAssertNil(MockupSVGEditing.resize(wireframe, path: "", from: .zero, to: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    func testResizePercentLengthsOnlyConvertWhenChanged() throws {
        let src = #"<svg viewBox="0 0 200 100"><rect x="10%" y="10" width="50%" height="20px"/></svg>"#
        let n = try resized(src, "0", CGRect(x: 20, y: 10, width: 100, height: 20), CGRect(x: 20, y: 10, width: 150, height: 20))
        XCTAssertEqual(n.attributes.map(\.value), ["10%", "10", "150", "20px"])
    }

    func testResizeShapes() throws {
        let src = """
        <svg viewBox="0 0 100 100"><ellipse cx="50" cy="50" rx="10" ry="5"/><circle cx="10" cy="10" r="5"/>\
        <line x1="0" y1="0" x2="10" y2="20"/><polygon points="0,0 10,0 10,10"/><image x="1" y="1" width="2" height="2"/>\
        <use href="#a" x="5"/><use href="#a" width="4" height="4"/><path id="a" d="M0 0h10v10z"/></svg>
        """
        let e = try resized(src, "0", CGRect(x: 40, y: 45, width: 20, height: 10), CGRect(x: 0, y: 0, width: 30, height: 20))
        XCTAssertEqual(e.attributes.map(\.value), ["15", "10", "15", "10"])
        let c = try resized(src, "1", CGRect(x: 5, y: 5, width: 10, height: 10), CGRect(x: 0, y: 0, width: 30, height: 20))
        XCTAssertEqual(c.attributes.map(\.value), ["15", "10", "10"])
        let l = try resized(src, "2", CGRect(x: 0, y: 0, width: 10, height: 20), CGRect(x: 10, y: 10, width: 20, height: 10))
        XCTAssertEqual(l.attributes.map(\.value), ["10", "10", "30", "20"])
        let p = try resized(src, "3", CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 5, height: 30))
        XCTAssertEqual(p.attribute("points"), "0,0 5,0 5,30")
        let i = try resized(src, "4", CGRect(x: 1, y: 1, width: 2, height: 2), CGRect(x: 0, y: 0, width: 3, height: 3))
        XCTAssertEqual(i.attributes.map(\.value), ["0", "0", "3", "3"])
        let u = try resized(src, "5", CGRect(x: 5, y: 0, width: 10, height: 10), CGRect(x: 5, y: 0, width: 20, height: 5))
        XCTAssertEqual(u.attribute("transform"), "matrix(2 0 0 0.5 -5 0)")
        XCTAssertEqual(u.attribute("x"), "5")
        let sized = try resized(src, "6", CGRect(x: 0, y: 0, width: 4, height: 4), CGRect(x: 1, y: 2, width: 8, height: 8))
        XCTAssertEqual(sized.attributes.map(\.value), ["#a", "8", "8", "1", "2"])
    }

    func testResizeVerticalLineMovesWithoutDividingByZero() throws {
        let src = #"<svg><line x1="5" y1="0" x2="5" y2="10"/></svg>"#
        let l = try resized(src, "0", CGRect(x: 5, y: 0, width: 0, height: 10), CGRect(x: 7, y: 0, width: 4, height: 20))
        XCTAssertEqual(l.attributes.map(\.value), ["7", "0", "7", "20"])
    }

    func testResizeTextScalesFontAndTspans() throws {
        let t = try resized(wireframe, "9", CGRect(x: 20, y: 80, width: 100, height: 20), CGRect(x: 40, y: 80, width: 200, height: 40))
        XCTAssertEqual(t.attribute("font-size"), "40")
        XCTAssertEqual(t.attribute("x"), "40")
        XCTAssertEqual(t.attribute("y"), "120")
        XCTAssertEqual(t.children[0].attribute("x"), "40")
        // Without its own font-size the text's size is inherited, so it falls back to a transform.
        let inherited = #"<svg><text x="0" y="10">a</text></svg>"#
        let f = try resized(inherited, "0", CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(f.attribute("transform"), "matrix(2 0 0 2 0 0)")
    }

    func testResizePathAndGroupMergeTrailingMatrix() throws {
        let once = try XCTUnwrap(MockupSVGEditing.resize(wireframe, path: "7", from: CGRect(x: 0, y: 0, width: 380, height: 40), to: CGRect(x: 0, y: 0, width: 190, height: 80)))
        XCTAssertEqual(try tree(once.source).node(at: "7")?.attribute("transform"), "translate(10 20) matrix(0.5 0 0 2 0 0)")
        let twice = try XCTUnwrap(MockupSVGEditing.resize(once.source, path: "7", from: CGRect(x: 0, y: 0, width: 380, height: 40), to: CGRect(x: 10, y: 0, width: 380, height: 40)))
        XCTAssertEqual(try tree(twice.source).node(at: "7")?.attribute("transform"), "translate(10 20) matrix(0.5 0 0 2 5 0)")
        // A drag after a resize still merges into the leading translate.
        let moved = try XCTUnwrap(MockupSVGEditing.translate(twice.source, path: "7", dx: 1, dy: 1))
        XCTAssertEqual(try tree(moved.source).node(at: "7")?.attribute("transform"), "translate(11 21) matrix(0.5 0 0 2 5 0)")
        // Resizing back to identity drops the matrix.
        let undo = try XCTUnwrap(MockupSVGEditing.resize(once.source, path: "7", from: CGRect(x: 0, y: 0, width: 380, height: 40), to: CGRect(x: 0, y: 0, width: 760, height: 20)))
        XCTAssertEqual(try tree(undo.source).node(at: "7")?.attribute("transform"), "translate(10 20)")

        let path = try resized(wireframe, "13", CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 30, height: 30))
        XCTAssertEqual(path.attribute("transform"), "matrix(3 0 0 3 0 0)")
        XCTAssertEqual(path.attribute("d"), "M0 0 L10 10")
    }

    func testResizeRefusesBadInput() {
        let r = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertNil(MockupSVGEditing.resize(wireframe, path: "11", from: r, to: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
        XCTAssertNil(MockupSVGEditing.resize(wireframe, path: "12", from: r, to: r.insetBy(dx: -1, dy: -1)))
        XCTAssertNil(MockupSVGEditing.resize(#"<svg><polygon points="0,0 1"/></svg>"#, path: "0", from: r, to: r.insetBy(dx: -1, dy: -1)))
    }
}
