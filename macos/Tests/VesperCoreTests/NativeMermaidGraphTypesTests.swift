import CoreGraphics
import XCTest
@testable import VesperCore

/// State, class and ER diagrams: the graph-shaped types laid out through ELK like flowcharts.
final class NativeMermaidGraphTypesTests: XCTestCase {
    /// Renders in both palettes: a profile-clean SVG the native renderer parses, every expected label
    /// drawn, byte-identical output on a re-run, and no two node frames overlapping.
    @discardableResult
    func assertRenders(_ source: String, labels: [String], file: StaticString = #filePath, line: UInt = #line) throws -> MermaidDrawing {
        var light: MermaidDrawing?
        for p in [VizPalette.light, VizPalette.dark] {
            let d = try NativeMermaid.render(source, palette: p)
            XCTAssertEqual(MockupSVGProfile.violations(d.svg), [], file: file, line: line)
            XCTAssertNoThrow(try MockupSVGDocument(source: d.svg), file: file, line: line)
            let again = try NativeMermaid.svg(source, palette: p)
            XCTAssertEqual(d.svg, again, "not deterministic", file: file, line: line)
            if light == nil { light = d }
        }
        let d = try XCTUnwrap(light)
        for l in labels {
            XCTAssertTrue(d.texts.contains(l), "missing label \(l) in \(d.texts)", file: file, line: line)
        }
        for i in d.nodeFrames.indices {
            for j in d.nodeFrames.indices where j > i {
                let a = d.nodeFrames[i].insetBy(dx: 1, dy: 1), b = d.nodeFrames[j].insetBy(dx: 1, dy: 1)
                XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)", file: file, line: line)
            }
        }
        return d
    }

    func assertSyntaxError(_ source: String, line expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try NativeMermaid.svg(source, palette: .light), file: file, line: line) { e in
            guard case let .syntax(l, _)? = e as? NativeMermaidError else { return XCTFail("\(e)", file: file, line: line) }
            XCTAssertEqual(l, expected, file: file, line: line)
        }
    }

    // MARK: Layout

    /// Two labelled edges running opposite ways between the same pair of nodes: ELK has to reserve
    /// room for both labels, side by side, rather than letting them land on top of each other.
    func testLayoutReservesRoomForEdgeLabels() throws {
        var g = MermaidGraphInput()
        g.add(MermaidGraphInput.Node(id: "a", size: CGSize(width: 56, height: 38)))
        g.add(MermaidGraphInput.Node(id: "b", size: CGSize(width: 208, height: 84)))
        g.edges = [MermaidGraphInput.Edge(id: "e0", source: "a", target: "b", label: CGSize(width: 90, height: 22)),
                   MermaidGraphInput.Edge(id: "e1", source: "b", target: "a", label: CGSize(width: 90, height: 22))]
        let l = try MermaidLayered.layout(g, diagram: "test")
        let a = try XCTUnwrap(l.nodes["a"]), b = try XCTUnwrap(l.nodes["b"])
        let first = try XCTUnwrap(l.labels["e0"]), second = try XCTUnwrap(l.labels["e1"])
        XCTAssertFalse(first.intersects(second), "\(first) overlaps \(second)")
        for label in [first, second] {
            XCTAssertFalse(label.intersects(a) || label.intersects(b), "\(label) sits on a node")
        }
    }
}
