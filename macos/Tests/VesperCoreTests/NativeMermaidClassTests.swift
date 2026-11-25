import CoreGraphics
import XCTest
@testable import VesperCore

/// Class diagrams: boxes with compartments, every UML relation, generics, namespaces and notes.
final class NativeMermaidClassTests: XCTestCase {
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

    static let animals = """
    ---
    title: Animal example
    ---
    classDiagram
      note "From Duck till Zebra"
      Animal <|-- Duck
      note for Duck "can fly\\ncan swim"
      Animal <|-- Fish
      Animal <|-- Zebra
      Animal : +int age
      Animal : +String gender
      Animal: +isMammal() bool
      Animal: +mate()
      class Duck{
        +String beakColor
        +swim()
        +quack()
      }
      class Fish{
        -int sizeInFeet
        -canEat()
      }
      class Zebra{
        +bool is_wild
        +run()
      }
    """

    static let relations = """
    classDiagram
      direction LR
      classA <|-- classB : Inheritance
      classC *-- classD : Composition
      classE o-- classF : Aggregation
      classG <-- classH : Association
      classI -- classJ : Link
      classK <.. classL : Dependency
      classM <|.. classN : Realization
      classO .. classP : Dashed
      classQ --|> classR
      classS --* classT
      classU --o classV
      classW ..> classX
      classY ..|> classZ
      Left <|--|> Right
      Port ()-- Plug
    """

    static let shop = """
    classDiagram
      namespace Orders {
        class Order~T~ {
          <<abstract>>
          -List~LineItem~T~~ items
          +String id$
          +total() Money
          +validate()* bool
          +apply(Map~String, int~ discounts)$
        }
        class LineItem~T~
      }
      namespace Billing {
        class Invoice["Tax invoice"]
        class `Payment Gateway`
      }
      <<interface>> Payable
      class Payable {
        +pay(amount) Receipt
      }
      class Customer:::vip
      classDef vip fill:#fde2e2,stroke:#c0392b,color:#7a1d14
      style Invoice stroke-dasharray:4 3
      Customer "1" --> "*" Order~T~ : places
      Order "1" *-- "1..*" LineItem : contains
      Invoice ..|> Payable
      Invoice --> `Payment Gateway` : charges via
      Order "0..1" -- "1" Invoice
    """

    func testAnimalsWithMembersNotesAndTitle() throws {
        let d = try assertRenders(Self.animals, labels: [
            "Animal example", "Animal", "Duck", "Fish", "Zebra", "+int age", "+String gender", "+isMammal() : bool", "+mate()",
            "+String beakColor", "+swim()", "+quack()", "-int sizeInFeet", "-canEat()", "+bool is_wild", "+run()",
            "From Duck till Zebra", "can fly", "can swim",
        ])
        // Four classes and two notes.
        XCTAssertEqual(d.nodeFrames.count, 6)
        XCTAssertTrue(d.svg.contains("stroke-dasharray=\"3 3\""), "the note is tied to its class with a dotted line")
    }

    func testEveryRelationMarkerAndLineStyle() throws {
        let d = try assertRenders(Self.relations, labels: [
            "Inheritance", "Composition", "Aggregation", "Association", "Link", "Dependency", "Realization", "Dashed",
        ] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { "class\($0)" } + ["Left", "Right", "Port", "Plug"])
        let c = try MermaidClass.parse(MermaidSource(Self.relations))
        let ends = c.relations.map { "\($0.fromEnd)-\($0.toEnd)-\($0.dashed)" }
        XCTAssertEqual(ends, [
            "inheritance-none-false", "composition-none-false", "aggregation-none-false", "arrow-none-false", "none-none-false",
            "arrow-none-true", "inheritance-none-true", "none-none-true", "none-inheritance-false", "none-composition-false",
            "none-aggregation-false", "none-arrow-true", "none-inheritance-true", "inheritance-inheritance-false", "lollipop-none-false",
        ])
        XCTAssertTrue(d.svg.contains("marker-start="))
        XCTAssertTrue(d.svg.contains("marker-end="))
        XCTAssertTrue(d.svg.contains("stroke-dasharray=\"6 4\""), "dotted relations are dashed")
        // Hollow triangle, filled and hollow diamonds, open arrow and lollipop circle all defined.
        XCTAssertEqual(d.svg.components(separatedBy: "<marker ").count - 1, 5)
    }

    func testGenericsNamespacesAnnotationsAndStyles() throws {
        let d = try assertRenders(Self.shop, labels: [
            "Orders", "Billing", "Order<T>", "«abstract»", "-List<LineItem<T>> items", "+String id", "+total() : Money",
            "+validate() : bool", "+apply(Map<String, int> discounts)", "LineItem<T>", "Tax invoice", "Payment Gateway",
            "«interface»", "Payable", "+pay(amount) : Receipt", "Customer", "1", "*", "1..*", "0..1", "places", "contains", "charges via",
        ])
        XCTAssertTrue(d.svg.contains("font-style=\"italic\""), "abstract members are italic")
        XCTAssertTrue(d.svg.contains("text-decoration=\"underline\""), "static members are underlined")
        XCTAssertTrue(d.svg.contains("#fde2e2"), "classDef via ::: applied")
        XCTAssertTrue(d.svg.contains("stroke-dasharray=\"4 3\""), "style applied")
        let c = try MermaidClass.parse(MermaidSource(Self.shop))
        XCTAssertEqual(c.boxes["Order"]?.namespace, "Orders")
        XCTAssertEqual(c.boxes["Payment Gateway"]?.namespace, "Billing")
        XCTAssertNil(c.boxes["Customer"]?.namespace)
        XCTAssertEqual(c.relations.first?.fromCardinality, "1")
        XCTAssertEqual(c.relations.first?.toCardinality, "*")
    }

    func testMemberParsing() {
        XCTAssertEqual(MermaidClass.member("+getItems() List~Item~").text, "+getItems() : List<Item>")
        XCTAssertEqual(MermaidClass.member("~Map~K, List~V~~ index").text, "~Map<K, List<V>> index")
        let abstract = MermaidClass.member("#draw(Canvas c) void*")
        XCTAssertEqual(abstract.text, "#draw(Canvas c) : void")
        XCTAssertTrue(abstract.isAbstract)
        let stat = MermaidClass.member("+String count$")
        XCTAssertEqual(stat.text, "+String count")
        XCTAssertTrue(stat.isStatic)
        XCTAssertTrue(MermaidClass.member("+create()$ Foo").isStatic)
    }

    func testV2HeaderSemicolonsAndMinimalClass() throws {
        try assertRenders("classDiagram-v2\nclass Solo", labels: ["Solo"])
        try assertRenders("classDiagram\nA --> B; B --> C\nclass C { +x }", labels: ["A", "B", "C", "+x"])
    }

    /// A cardinality chip sits just off the box it belongs to and beside the edge, not on it or on
    /// the end marker, for an edge leaving each side of a box in either direction.
    func testCardinalitiesSitOffTheBoxAndLine() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 60)
        let leaving: [[CGPoint]] = [
            [CGPoint(x: 50, y: 60), CGPoint(x: 50, y: 160)],   // down from the bottom
            [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: -100)],   // up from the top
            [CGPoint(x: 100, y: 30), CGPoint(x: 200, y: 30)],  // right from the right side
            [CGPoint(x: 0, y: 30), CGPoint(x: -100, y: 30)],   // left from the left side
        ]
        for pts in leaving {
            for (route, atEnd) in [(pts, false), (Array(pts.reversed()), true)] {
                let chips = MermaidClass.cardinalityCandidates("0..*", at: route, atEnd: atEnd).rects
                XCTAssertEqual(chips.count, 4)
                for chip in chips {
                    XCTAssertFalse(chip.intersects(box), "\(chip) sits on the box for \(route)")
                    // Clear of the line and of the widest marker (the 16-unit triangle) around it.
                    let p = pts[0]
                    let line = pts[0].x == pts[1].x
                        ? CGRect(x: p.x - 8, y: min(pts[0].y, pts[1].y), width: 16, height: abs(pts[1].y - pts[0].y))
                        : CGRect(x: min(pts[0].x, pts[1].x), y: p.y - 8, width: abs(pts[1].x - pts[0].x), height: 16)
                    XCTAssertFalse(chip.intersects(line), "\(chip) crosses the edge \(route)")
                    XCTAssertLessThan(hypot(chip.midX - p.x, chip.midY - p.y), 80, "\(chip) strays from its end")
                }
            }
        }
    }

    func testCardinalitiesRenderInEveryDirection() throws {
        for dir in ["TB", "LR", "BT", "RL"] {
            try assertRenders("classDiagram\ndirection \(dir)\nOwner \"1\" --> \"0..*\" Pet : owns\nPet \"many\" o-- \"1\" Vet",
                              labels: ["1", "0..*", "many", "owns"])
        }
    }

    func testClassSyntaxErrors() {
        assertSyntaxError("classDiagram\n  A <|-- B\n  A B C\n", line: 3)
        assertSyntaxError("classDiagram\n  A <|-- B\n  class C {\n  +x\n", line: 3)
        assertSyntaxError("classDiagram\n  A <|-- B\n  }\n", line: 3)
        assertSyntaxError("classDiagram\n  A <|--\n", line: 2)
        assertSyntaxError("classDiagram\n  namespace N {\n  class A\n", line: 2)
        assertSyntaxError("classDiagram\n  A --> B\n  note for A missing quotes\n", line: 3)
        assertSyntaxError("classDiagram\n", line: 1)
    }

    func testClassTooLarge() {
        let src = "classDiagram\n" + (0..<(NativeMermaid.maxNodes + 1)).map { "C\($0) --> C\($0 + 1)" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    // MARK: Visual check

    static var samples: [(String, String)] {
        [("class-animals", animals), ("class-relations", relations), ("class-shop", shop),
         ("class-cardinality-tb", "classDiagram\nOwner \"1\" --> \"0..*\" Pet : owns\nPet \"many\" o-- \"1\" Vet\nOwner \"1\" *-- \"1..*\" Address"),
         ("class-cardinality-lr", "classDiagram\ndirection LR\nOwner \"1\" --> \"0..*\" Pet : owns\nPet \"many\" o-- \"1\" Vet\nOwner \"1\" *-- \"1..*\" Address")]
    }

    /// Writes every sample as SVG and PNG under `.build/mermaid-png-class` for eyeballing, only
    /// when the `MERMAID_PNG` environment variable is set, so normal runs leave nothing behind.
    func testWritePNGsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MERMAID_PNG"] != nil else { throw XCTSkip("MERMAID_PNG not set") }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mermaid-png-class")
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
