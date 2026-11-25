import CoreGraphics
import XCTest
@testable import VesperCore

/// ER diagrams: entities as header-plus-table boxes laid out through ELK, crow's-foot ends.
final class NativeMermaidERTests: XCTestCase {
    /// Renders in both palettes: a profile-clean SVG the native renderer parses, every expected label
    /// drawn, byte-identical output on a re-run, and no two entity boxes overlapping.
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

    static let shop = """
    ---
    title: Shop schema
    ---
    erDiagram
      CUSTOMER ||--o{ ORDER : places
      ORDER ||--|{ LINE_ITEM : contains
      PRODUCT ||--o{ LINE_ITEM : "ordered in"
      CUSTOMER }|..|{ DELIVERY_ADDRESS : uses
      CUSTOMER {
        uuid id PK
        string name
        string email UK "login, lower-cased"
      }
      ORDER {
        uuid id PK
        uuid customer_id FK
        timestamp placed_at
        string status "pending, paid or shipped"
      }
      LINE_ITEM {
        uuid order_id PK, FK
        uuid product_id PK,FK
        int quantity
        decimal(10,2) unit_price
      }
      PRODUCT["Product catalogue"] {
        uuid id PK
        string sku UK
        string title
      }
    """

    /// Every left cardinality against every right one, both line kinds.
    static let cardinalities = """
    erDiagram
      direction LR
      A1 |o--o| B1 : zero-one
      A2 ||--|| B2 : exactly-one
      A3 }o..o{ B3 : zero-many
      A4 }|..|{ B4 : one-many
      A5 |o--|{ B5 : mixed
      A6 }o..|| B6 : "mixed back"
    """

    static let styled = """
    erDiagram
      classDef hot fill:#fde2e2,stroke:#c0392b,color:#7a1d14
      "Audit Log":::hot {
        timestamp at
        string actor
      }
      USER 1 to zero or more "Audit Log" : writes
      USER only one optionally to zero or one SESSION : opens
      SESSION
      style USER stroke:#008300
      EMPTY_TABLE
    """

    func testShopSchema() throws {
        let d = try assertRenders(Self.shop, labels: [
            "Shop schema", "CUSTOMER", "ORDER", "LINE_ITEM", "Product catalogue", "DELIVERY_ADDRESS",
            "places", "contains", "ordered in", "uses",
            "uuid", "id", "PK", "FK", "UK", "PK, FK", "email", "login, lower-cased", "pending, paid or shipped", "decimal(10,2)", "unit_price",
        ])
        XCTAssertEqual(d.nodeFrames.count, 5)
        // CUSTOMER ||--o{ ORDER: one bars at CUSTOMER (the path's start), crow's foot with a circle at ORDER.
        XCTAssertTrue(d.svg.contains("marker-start="))
        XCTAssertTrue(d.svg.contains("marker-end="))
        XCTAssertTrue(d.svg.contains("stroke-dasharray=\"6 4\""), "the non-identifying relationship is dashed")
        // Alternating row fills on the panel colour.
        XCTAssertTrue(d.svg.contains("fill=\"\(VizPalette.light.panel)\""))
    }

    func testEveryCardinalityPair() throws {
        let src = Self.cardinalities
        let d = try assertRenders(src, labels: ["A1", "B1", "B6", "zero-one", "exactly-one", "zero-many", "one-many", "mixed", "mixed back"])
        XCTAssertEqual(d.nodeFrames.count, 12)
        let er = try MermaidER.parse(MermaidSource(src))
        let pairs = er.relationships.map { "\($0.fromCardinality)-\($0.toCardinality)-\($0.identifying)" }
        XCTAssertEqual(pairs, [
            "zeroOrOne-zeroOrOne-true", "exactlyOne-exactlyOne-true", "zeroOrMore-zeroOrMore-false",
            "oneOrMore-oneOrMore-false", "zeroOrOne-oneOrMore-true", "zeroOrMore-exactlyOne-false",
        ])
        // Each end's marker is defined once per kind: one, zero-one, one-many and zero-many all appear.
        XCTAssertEqual(d.svg.components(separatedBy: "<marker ").count - 1, 4)
    }

    func testWordFormsAliasesAndStyles() throws {
        let d = try assertRenders(Self.styled, labels: ["Audit Log", "USER", "SESSION", "EMPTY_TABLE", "writes", "opens", "timestamp", "actor"])
        XCTAssertEqual(d.nodeFrames.count, 4)
        XCTAssertTrue(d.svg.contains("#fde2e2"), "classDef via ::: applied")
        // The class's text colour suits its header fill, not the surface the rows sit on.
        XCTAssertEqual(d.svg.components(separatedBy: "#7a1d14").count - 1, 1, "only the header takes the class's color")
        XCTAssertTrue(d.svg.contains("#008300"), "style applied")
        let er = try MermaidER.parse(MermaidSource(Self.styled))
        XCTAssertEqual(er.relationships.map(\.identifying), [true, false])
        XCTAssertEqual(er.relationships.map(\.toCardinality), [.zeroOrMore, .zeroOrOne])
    }

    func testOneLineBlocksAndSemicolons() throws {
        try assertRenders("erDiagram\n  A { string id PK }\n  A ||--o{ B : has; B ||--|| C : is", labels: ["A", "B", "C", "has", "is", "id"])
    }

    func testOnlyUsedColumnsAreLaidOut() throws {
        let er = try MermaidER.parse(MermaidSource("erDiagram\n  A {\n    int id\n    string name\n  }\n  B {\n    int id PK \"key\"\n  }"))
        XCTAssertEqual(er.box(try XCTUnwrap(er.entities["A"])).columns.map(\.column), [.type, .name])
        XCTAssertEqual(er.box(try XCTUnwrap(er.entities["B"])).columns.map(\.column), [.type, .name, .keys, .comment])
    }

    func testSyntaxErrors() {
        assertSyntaxError("erDiagram\n  A ||--o{ B : x\n  A {\n    string id\n", line: 3)
        assertSyntaxError("erDiagram\n  A ||--o{ B : x\n  }\n", line: 3)
        assertSyntaxError("erDiagram\n  A {\n    id\n  }\n", line: 3)
        assertSyntaxError("erDiagram\n  A {\n    string id XK\n  }\n", line: 3)
        assertSyntaxError("erDiagram\n  A ||--o{ B : x\n  A B C\n", line: 3)
        assertSyntaxError("erDiagram\n  A ||--o{ : x\n", line: 2)
        assertSyntaxError("erDiagram\n  A many to B : x\n", line: 2)
        assertSyntaxError("erDiagram\n", line: 1)
    }

    func testTooLarge() {
        let src = "erDiagram\n" + (0..<(NativeMermaid.maxNodes + 1)).map { "E\($0) ||--o{ E\($0 + 1) : x" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    // MARK: Visual check

    static var samples: [(String, String)] {
        [("er-shop", shop), ("er-cardinalities", cardinalities), ("er-styled", styled)]
    }

    /// Writes every sample as SVG and PNG under `.build/mermaid-png-er` for eyeballing, only when the
    /// `MERMAID_PNG` environment variable is set, so normal runs leave nothing behind.
    func testWritePNGsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MERMAID_PNG"] != nil else { throw XCTSkip("MERMAID_PNG not set") }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mermaid-png-er")
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
