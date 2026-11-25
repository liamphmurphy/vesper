import CoreGraphics
import XCTest
@testable import VesperCore

/// Pie and gantt charts: the mermaid types drawn by deterministic chart layouts rather than a graph
/// engine.
final class NativeMermaidChartTypesTests: XCTestCase {
    static let pieSample = """
    pie showData title Pets adopted by volunteers
        "Dogs" : 386
        "Cats" : 85.5
        "Rats" : 15
        "Fish" : 0
    """

    static let samples: [(String, String)] = [
        ("pie", pieSample),
        ("pie-single", "pie\n\"Everything\" : 1"),
        ("pie-many", "---\ntitle: Browser share\n---\npie\n" + ["Chrome": 64.2, "Safari": 18.6, "Edge": 5.2, "Firefox": 2.8, "Opera": 2.3,
                                                                    "Samsung Internet": 2.1, "UC Browser": 0.9, "Other": 3.9]
            .sorted { $0.key < $1.key }.map { "  \"\($0.key)\" : \($0.value)" }.joined(separator: "\n")),
    ]

    /// As `NativeMermaidTests.assertRenders`: profile-clean in both palettes, every label drawn,
    /// byte-identical on a re-run.
    @discardableResult
    func assertRenders(_ source: String, labels: [String], file: StaticString = #filePath, line: UInt = #line) throws -> MermaidDrawing {
        var light: MermaidDrawing?
        for p in [VizPalette.light, VizPalette.dark] {
            let d = try NativeMermaid.render(source, palette: p)
            XCTAssertEqual(MockupSVGProfile.violations(d.svg), [], file: file, line: line)
            XCTAssertNoThrow(try MockupSVGDocument(source: d.svg), file: file, line: line)
            XCTAssertEqual(d.svg, try NativeMermaid.svg(source, palette: p), "not deterministic", file: file, line: line)
            if light == nil { light = d }
        }
        let d = try XCTUnwrap(light)
        for l in labels {
            XCTAssertTrue(d.texts.contains(l), "missing label \(l) in \(d.texts)", file: file, line: line)
        }
        return d
    }

    func assertSyntax(_ source: String, line expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try NativeMermaid.svg(source, palette: .light), file: file, line: line) { e in
            guard case let .syntax(l, _)? = e as? NativeMermaidError else { return XCTFail("\(e)", file: file, line: line) }
            XCTAssertEqual(l, expected, file: file, line: line)
        }
    }

    // MARK: Pie

    func testPieWithShowDataAndTitle() throws {
        let d = try assertRenders(Self.pieSample, labels: ["Pets adopted by volunteers", "Dogs [386]", "Cats [85.5]", "Rats [15]", "79%", "18%"])
        XCTAssertFalse(d.texts.contains { $0.hasPrefix("Fish") }, "zero slices are left out")
        XCTAssertEqual(d.svg.components(separatedBy: "<path d=\"M").count - 1, 3, "one path per slice")
        // Largest first, so Dogs takes the first series colour.
        let dogs = try XCTUnwrap(d.svg.range(of: "Dogs [386]"))
        XCTAssertTrue(d.svg[..<dogs.lowerBound].contains(VizPalette.light.series[0]))
    }

    func testPieTitleOnItsOwnLineAndNoShowData() throws {
        let d = try assertRenders("pie\n  title Votes\n  \"Yes\" : 3\n  'No' : 1", labels: ["Votes", "Yes", "No", "75%", "25%"])
        XCTAssertFalse(d.texts.contains("Yes [3]"))
    }

    func testPieSingleSliceIsAFullCircle() throws {
        let d = try assertRenders("pie\n\"Everything\" : 1", labels: ["Everything", "100%"])
        XCTAssertTrue(d.svg.contains("<circle"))
        XCTAssertFalse(d.svg.contains(" A"), "no arc for a single slice")
    }

    func testPieSyntaxErrors() {
        assertSyntax("pie\n\"A\" : 1\n\"B\" : -2", line: 3)
        assertSyntax("pie\n\"A\" : 1\nB : 2", line: 3)
        assertSyntax("---\ntitle: T\n---\npie\n\"A\" : x", line: 5)
        assertSyntax("pie\n\"A\" : 0", line: 1)
    }

    func testPieTooManySlicesIsTooLarge() {
        let src = "pie\n" + (0...NativeMermaid.maxRows).map { "\"s\($0)\" : 1" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    // MARK: Visual check

    /// Writes every sample as SVG and PNG into `macos/.build/mermaid-chart-png` when
    /// `MERMAID_CHART_PNG` is set, for eyeballing; `.build` is ignored, so nothing is left in the tree.
    func testWritePNGsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MERMAID_CHART_PNG"] != nil else { throw XCTSkip("MERMAID_CHART_PNG isn't set") }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mermaid-chart-png")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, src) in Self.samples {
            for (mode, p) in [("light", VizPalette.light), ("dark", VizPalette.dark)] {
                let svg = try NativeMermaid.svg(src, palette: p)
                try svg.write(to: out.appendingPathComponent("\(name)-\(mode).svg"), atomically: true, encoding: .utf8)
                let png = try XCTUnwrap(MockupSVGRenderer.pngData(try MockupSVGDocument(source: svg), scale: 2, background: nil))
                try png.write(to: out.appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }
}
