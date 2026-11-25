import CoreGraphics
import XCTest
@testable import VesperCore

final class NativeMermaidTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testdata/mermaid")

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name + ".mmd"), encoding: .utf8)
    }

    /// Renders in both palettes and checks what every diagram must satisfy: a profile-clean SVG the
    /// native renderer parses, every expected label drawn, and byte-identical output on a re-run.
    @discardableResult
    func assertRenders(_ source: String, labels: [String], file: StaticString = #filePath, line: UInt = #line) throws -> MermaidDrawing {
        var light: MermaidDrawing?
        for p in [VizPalette.light, VizPalette.dark] {
            let d = try NativeMermaid.render(source, palette: p)
            XCTAssertEqual(MockupSVGProfile.violations(d.svg), [], file: file, line: line)
            XCTAssertNoThrow(try MockupSVGDocument(source: d.svg), file: file, line: line)
            XCTAssertTrue(d.svg.contains("viewBox=\"0 0 "), file: file, line: line)
            let again = try NativeMermaid.svg(source, palette: p)
            XCTAssertEqual(d.svg, again, "not deterministic", file: file, line: line)
            if light == nil { light = d }
        }
        let d = try XCTUnwrap(light)
        for l in labels {
            XCTAssertTrue(d.texts.contains(l), "missing label \(l) in \(d.texts)", file: file, line: line)
        }
        return d
    }

    func assertNoOverlap(_ frames: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].insetBy(dx: 1, dy: 1).intersects(frames[j].insetBy(dx: 1, dy: 1))
                XCTAssertFalse(overlap, "\(frames[i]) overlaps \(frames[j])", file: file, line: line)
            }
        }
    }

    // MARK: Flowchart

    func testFlowchartBasic() throws {
        let d = try assertRenders(try Self.fixture("flowchart-basic"),
                                  labels: ["Christmas", "Go shopping", "Let me think", "Laptop", "iPhone", "Get money", "One", "Two", "Three"])
        XCTAssertEqual(d.nodeFrames.count, 6)
        assertNoOverlap(d.nodeFrames)
        XCTAssertTrue(d.svg.contains("<marker"))
        XCTAssertTrue(d.svg.contains("marker-end="))
    }

    func testFlowchartSubgraphsStylesAndTitle() throws {
        let d = try assertRenders(try Self.fixture("flowchart-subgraphs"),
                                  labels: ["Deploy pipeline", "Developer", "Git repo", "Continuous integration", "Delivery",
                                           "Tests pass?", "Package artifact", "Monitoring", "push", "yes", "no"])
        assertNoOverlap(d.nodeFrames)
        XCTAssertTrue(d.svg.contains("#fde2e2"), "classDef fill applied")
        XCTAssertTrue(d.svg.contains("#2A78D6"), "linkStyle applied")
        XCTAssertTrue(d.svg.contains("stroke-dasharray"), "dotted link drawn dashed")
    }

    func testFlowchartChainsGroupsAndInlineForms() throws {
        let src = """
        graph LR; A & B --> C --> D
        C -- label text --> E
        E -. dotted .-> F
        F == thick ==> G
        G <--> H
        H o--o I
        I x--x J
        J ~~~ K
        K["Quoted #quot;label#quot;<br>two lines"]
        """
        let d = try assertRenders(src, labels: ["label text", "dotted", "thick", "Quoted \"label\"", "two lines"])
        XCTAssertEqual(d.nodeFrames.count, 11)
        assertNoOverlap(d.nodeFrames)
    }

    func testFlowchartAllShapes() throws {
        let src = """
        flowchart TB
          a[rect] --> b(round) --> c([stadium]) --> d[[sub]] --> e[(db)]
          e --> f((circle)) --> g(((double))) --> h{rhombus} --> i{{hex}}
          i --> j[/lean r/] --> k[\\lean l\\] --> l[/trap\\] --> m[\\trapalt/] --> n>odd]
          n --> o@{ shape: diam, label: "new syntax" }
        """
        let d = try assertRenders(src, labels: ["rect", "round", "stadium", "sub", "db", "circle", "double", "rhombus", "hex",
                                                "lean r", "lean l", "trap", "trapalt", "odd", "new syntax"])
        assertNoOverlap(d.nodeFrames)
    }

    // MARK: Sequence

    func testSequenceCheckout() throws {
        let d = try assertRenders(try Self.fixture("sequence-checkout"),
                                  labels: ["Checkout", "Shopper", "Web app", "API", "Orders DB", "Place order", "POST /orders",
                                           "validates the cart", "loop", "[every item]", "[card declined]", "render receipt",
                                           "[timeout]", "done", "thanks", "Confirmation", "1", "14"])
        XCTAssertEqual(d.nodeFrames.count, 4)
        assertNoOverlap(d.nodeFrames)
        XCTAssertTrue(d.svg.contains("marker-end="))
        XCTAssertTrue(d.svg.contains("marker-start="), "<<->> draws both heads")
    }

    func testSequenceImplicitParticipantsAndSyntaxErrors() throws {
        let d = try assertRenders("sequenceDiagram\nAlice->>John: Hello John\nJohn-->>Alice: Great!", labels: ["Alice", "John", "Hello John", "Great!"])
        XCTAssertEqual(d.nodeFrames.count, 2)
        XCTAssertThrowsError(try NativeMermaid.svg("sequenceDiagram\nA->>B: hi\nA B C\n", palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .syntax(line: 3, message: "expected a message like A->>B: text"))
        }
        XCTAssertThrowsError(try NativeMermaid.svg("sequenceDiagram\nloop x\nA->>B: hi\n", palette: .light)) { e in
            guard case .syntax(line: 2, _)? = e as? NativeMermaidError else { return XCTFail("\(e)") }
        }
    }

    // MARK: Errors

    func testUnsupportedDiagram() {
        XCTAssertThrowsError(try NativeMermaid.svg("journey\n  title My day", palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .unsupportedDiagram("journey"))
        }
    }

    func testSyntaxErrorReportsLineIncludingFrontMatter() {
        let src = "---\ntitle: T\n---\nflowchart TD\n  A --> B\n  A --> [oops\n"
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            guard case let .syntax(line, _)? = e as? NativeMermaidError else { return XCTFail("\(e)") }
            XCTAssertEqual(line, 6)
        }
    }

    func testUnclosedSubgraphIsASyntaxError() {
        XCTAssertThrowsError(try NativeMermaid.svg("flowchart TD\nsubgraph one\nA-->B\n", palette: .light)) { e in
            guard case .syntax? = e as? NativeMermaidError else { return XCTFail("\(e)") }
        }
    }

    func testOversizedSourceIsTooLarge() {
        let src = "flowchart TD\n" + String(repeating: "A --> B\n", count: NativeMermaid.maxSource / 8 + 1)
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    func testTooManyNodesIsTooLarge() {
        let src = "flowchart TD\n" + (0..<(NativeMermaid.maxNodes + 1)).map { "n\($0)" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    func testInitDirectiveAndCommentsAreIgnored() throws {
        try assertRenders("%%{init: {'theme':'forest'}}%%\nflowchart LR\n%% comment\nA-->B", labels: ["A", "B"])
    }

    // MARK: Visual check

    /// Writes every fixture as SVG and PNG for eyeballing, only when `macos/.build-mermaid-png`
    /// exists, so normal runs leave nothing behind.
    func testWritePNGsWhenRequested() throws {
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-mermaid-png")
        guard FileManager.default.fileExists(atPath: out.path) else { throw XCTSkip("no .build-mermaid-png directory") }
        let files = try FileManager.default.contentsOfDirectory(at: Self.fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mmd" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            for (name, p) in [("light", VizPalette.light), ("dark", VizPalette.dark)] {
                let svg = try NativeMermaid.svg(src, palette: p)
                let base = f.deletingPathExtension().lastPathComponent + "-\(name)"
                try svg.write(to: out.appendingPathComponent(base + ".svg"), atomically: true, encoding: .utf8)
                let png = try XCTUnwrap(MockupSVGRenderer.pngData(try MockupSVGDocument(source: svg), scale: 2, background: nil))
                try png.write(to: out.appendingPathComponent(base + ".png"))
            }
        }
    }
}
