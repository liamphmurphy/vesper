import XCTest
@testable import VesperCore

final class MockupSVGSimplifierTests: XCTestCase {
    func testValidCorpusIsUnchanged() throws {
        let files = try MockupSVGProfileTests.files("valid")
        XCTAssertGreaterThan(files.count, 5)
        for f in files {
            let source = try String(contentsOf: f, encoding: .utf8)
            let s = try XCTUnwrap(MockupSVGSimplifier.simplify(source), f.lastPathComponent)
            XCTAssertTrue(s.isUnchanged, f.lastPathComponent)
            XCTAssertEqual(s.svg, source, f.lastPathComponent)
            XCTAssertEqual(s.dropped, [], f.lastPathComponent)
        }
    }

    /// Files that can't be made to conform: no usable size, or limits the profile sets on the whole
    /// document. Every other invalid file must simplify to a conforming one.
    static let unfixable: Set<String> = ["no-viewbox-or-size", "percent-size-without-viewbox", "too-deep",
                                         "too-many-elements", "zero-viewbox"]

    func testInvalidCorpusSimplifiesOrRefuses() throws {
        let files = try MockupSVGProfileTests.files("invalid")
        XCTAssertGreaterThan(files.count, 20)
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            let s = MockupSVGSimplifier.simplify(try String(contentsOf: f, encoding: .utf8))
            if Self.unfixable.contains(name) {
                XCTAssertNil(s, "\(name) should be refused")
                continue
            }
            let got = try XCTUnwrap(s, "\(name) should simplify")
            XCTAssertFalse(got.isUnchanged, name)
            XCTAssertEqual(MockupSVGProfile.violations(got.svg), [], name)
        }
    }

    func testAgentSVGKeepsShapesAndText() throws {
        let source = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="200" height="100">
          <style>
            .card { fill: #fff; stroke: #ccc; }
            .label { font-size: 14px; fill: #333; }
            .card:hover { fill: #eee; }
            #dot { fill: red; animation: pulse 1s infinite; }
          </style>
          <defs>
            <filter id="shadow"><feDropShadow dx="0" dy="2" stdDeviation="2"/></filter>
          </defs>
          <rect class="card" x="10" y="10" width="180" height="80" rx="6" filter="url(#shadow)" data-step="1"/>
          <text class="label" x="20" y="40" data-step="2">Hello</text>
          <circle id="dot" cx="170" cy="30" r="5">
            <animate attributeName="r" values="5;8;5" dur="1s" repeatCount="indefinite"/>
          </circle>
        </svg>
        """
        XCTAssertFalse(MockupSVGProfile.violations(source).isEmpty)
        let s = try XCTUnwrap(MockupSVGSimplifier.simplify(source))
        XCTAssertFalse(s.isUnchanged)
        XCTAssertEqual(MockupSVGProfile.violations(s.svg), [])
        for gone in ["<style", "<filter", "<animate", "filter=", " class="] {
            XCTAssertFalse(s.svg.contains(gone), "still contains \(gone)")
        }
        let tree = try MockupSVGTree.parse(s.svg)
        let rect = try XCTUnwrap(tree.root.children.first { $0.localName == "rect" })
        XCTAssertEqual(rect.attribute("fill"), "#fff")
        XCTAssertEqual(rect.attribute("stroke"), "#ccc")
        XCTAssertEqual(rect.attribute("data-step"), "1")
        let text = try XCTUnwrap(tree.root.children.first { $0.localName == "text" })
        XCTAssertEqual(text.textContent, "Hello")
        XCTAssertEqual(text.attribute("fill"), "#333")
        XCTAssertEqual(text.attribute("data-step"), "2")
        let dot = try XCTUnwrap(tree.root.children.first { $0.localName == "circle" })
        XCTAssertEqual(dot.attribute("fill"), "red")
        XCTAssertFalse(s.dropped.isEmpty)
        XCTAssertTrue(s.dropped.contains("<filter>"), "\(s.dropped)")
        XCTAssertTrue(s.dropped.contains("<animate>"), "\(s.dropped)")
    }

    func testUnparseableIsNil() {
        XCTAssertNil(MockupSVGSimplifier.simplify("<svg"))
    }
}
