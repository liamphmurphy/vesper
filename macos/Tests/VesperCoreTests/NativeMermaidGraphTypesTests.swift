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

    // MARK: State

    static let stateTurn = """
    stateDiagram-v2
      [*] --> Idle
      Idle --> Working: turn starts
      Working: thinking / reading / coding / creating
      Working --> NeedsYou: approval needed
      NeedsYou --> Working: approved
      Working --> Idle: turn ends
    """

    static let stateFull = """
    ---
    title: Order lifecycle
    ---
    stateDiagram-v2
      direction TB
      classDef bad fill:#fde2e2,stroke:#c0392b,color:#7a1d14
      state "Awaiting payment" as Awaiting
      [*] --> Awaiting
      Awaiting --> Paid : card charged
      Awaiting --> Cancelled:::bad : timeout
      state check <<choice>>
      Paid --> check
      check --> Fulfilment : in stock
      check --> Backorder : out of stock
      Backorder --> Fulfilment : restocked
      state Fulfilment {
        [*] --> Picking
        Picking --> Packing
        Packing --> [*]
        --
        [*] --> Invoicing
        Invoicing --> [*]
      }
      state split <<fork>>
      state merge <<join>>
      Fulfilment --> split
      split --> Shipped
      split --> Emailed
      Shipped --> merge
      Emailed --> merge
      merge --> Done
      Done : order closed
      Done : archived after 90 days
      Done --> [*]
      Cancelled --> [*]
      note right of Backorder : supplier ETA<br>shown to the shopper
      note left of Paid
        Receipt is sent
        from the payments service
      end note
    """

    func testStateTurnDiagramFromChat() throws {
        let d = try assertRenders(Self.stateTurn, labels: ["Idle", "Working", "thinking / reading / coding / creating", "NeedsYou",
                                                           "turn starts", "approval needed", "approved", "turn ends"])
        // Idle, Working, NeedsYou and the start dot.
        XCTAssertEqual(d.nodeFrames.count, 4)
        XCTAssertTrue(d.svg.contains("marker-end="))
        XCTAssertTrue(d.svg.contains("<circle"), "the start pseudo-state is a filled circle")
    }

    func testStateCompositeRegionsChoiceForkNotes() throws {
        let d = try assertRenders(Self.stateFull, labels: [
            "Order lifecycle", "Awaiting payment", "Paid", "Cancelled", "Fulfilment", "Backorder", "Picking", "Packing", "Invoicing",
            "Shipped", "Emailed", "Done", "order closed", "archived after 90 days", "card charged", "timeout", "in stock",
            "out of stock", "restocked", "supplier ETA", "shown to the shopper", "Receipt is sent", "from the payments service",
        ])
        XCTAssertTrue(d.svg.contains("#fde2e2"), "classDef via ::: applied")
        XCTAssertTrue(d.svg.contains("stroke-dasharray=\"5 4\""), "concurrent regions divided by a dashed line")
        XCTAssertTrue(d.svg.contains("<polygon"), "choice drawn as a diamond")
    }

    func testStateDiagramV1HeaderAndDirection() throws {
        try assertRenders("stateDiagram\ndirection LR\ns1 --> s2\ns2 --> s1 : back\nstate s3\nstate \"Three\" as s3",
                          labels: ["s1", "s2", "back", "Three"])
    }

    func testStateSyntaxErrors() {
        assertSyntaxError("stateDiagram-v2\n  A --> B\n  A B C\n", line: 3)
        assertSyntaxError("stateDiagram-v2\n  A --> B\n  state X {\n  B --> C\n", line: 3)
        assertSyntaxError("stateDiagram-v2\n  A --> B\n  }\n", line: 3)
        assertSyntaxError("stateDiagram-v2\n  A --> B\n  note left of A\n  text\n", line: 3)
        assertSyntaxError("stateDiagram-v2\n  A -->\n", line: 2)
    }

    func testStateTooLarge() {
        let src = "stateDiagram-v2\n" + (0..<(NativeMermaid.maxNodes + 1)).map { "s\($0) --> s\($0 + 1)" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    // MARK: Visual check

    static var samples: [(String, String)] {
        [("state-turn", stateTurn), ("state-full", stateFull)]
    }

    /// Writes every sample as SVG and PNG under `.build/mermaid-png` for eyeballing, only when the
    /// `MERMAID_PNG` environment variable is set, so normal runs leave nothing behind.
    func testWritePNGsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MERMAID_PNG"] != nil else { throw XCTSkip("MERMAID_PNG not set") }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mermaid-png")
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
