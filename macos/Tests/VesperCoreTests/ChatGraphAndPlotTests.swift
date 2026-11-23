import XCTest
@testable import VesperCore

final class ChatGraphAndPlotTests: XCTestCase {
    func testGraphParsesGroupsNeighborsAnd40NodeLayoutNonOverlap() throws {
        // Build a 40-node graph with 4 groups and edges
        let nodes = (0..<40).map { i in
            "{\"id\":\"n\(i)\",\"label\":\"Node \(i)\",\"group\":\"G\(i % 4)\"}"
        }.joined(separator: ",")
        let edges = (0..<40).map { i in
            "{\"from\":\"n\(i)\",\"to\":\"n\((i + 1) % 40)\",\"directed\":true,\"label\":\"e\(i)\"}"
        }.joined(separator: ",")
        let json = "{\"title\":\"Web\",\"nodes\":[\(nodes)],\"edges\":[\(edges)]}"

        let spec = try ChatGraphSpec.parse(json).get()
        XCTAssertEqual(spec.nodes.count, 40)
        XCTAssertEqual(spec.groups.count, 4)
        XCTAssertEqual(spec.neighbors(of: "n0"), Set(["n0", "n1", "n39"]))

        let layout = spec.computeLayout(width: 720, height: 460)
        XCTAssertEqual(layout.count, 40)
        // Verify nodes are meaningfully separated (no two nodes collapsed onto the same point)
        let pts = Array(layout.values)
        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y)
                minDist = min(minDist, d)
            }
        }
        XCTAssertGreaterThan(minDist, 18.0, "40-node layout should separate nodes cleanly without collapsing labels")

        // Invalid specs
        XCTAssertThrowsError(try ChatGraphSpec.parse("{\"nodes\":[]}").get())
        XCTAssertThrowsError(try ChatGraphSpec.parse("{\"nodes\":[{\"id\":\"a\"}],\"edges\":[{\"from\":\"a\",\"to\":\"missing\"}]}").get())
    }

    func testMathParserEvaluatesSafeExpressionsAndRejectsJS() throws {
        let ast = try MathExpressionParser.parse("a*sin(b*x) + 2x^2 - 1").get()
        let y = ast.evaluate(variables: ["a": 2, "b": Double.pi / 2, "x": 1])
        // 2*sin(pi/2) + 2*1 - 1 = 3.0
        XCTAssertEqual(y, 3.0, accuracy: 1e-6)

        // Reject arbitrary JS / non-math syntax
        XCTAssertThrowsError(try MathExpressionParser.parse("process.exit(1);").get())
        XCTAssertThrowsError(try MathExpressionParser.parse("(() => 1)()").get())
        XCTAssertThrowsError(try MathExpressionParser.parse("eval(x)").get())
    }

    func testPlotIsolatesSingleBadExpressionAndRejectsAllBad() throws {
        let mixed = """
        {
          "title": "Waves",
          "xDomain": [-6, 6],
          "functions": [
            {"expr": "a*sin(x)", "label": "sine"},
            {"expr": "2 + * 3", "label": "broken"}
          ],
          "parameters": [
            {"name": "a", "value": 1.5, "min": 0, "max": 5, "step": 0.1}
          ]
        }
        """
        let spec = try ChatPlotSpec.parse(mixed).get()
        XCTAssertEqual(spec.functions.count, 2)
        XCTAssertNotNil(spec.functions[0].ast)
        XCTAssertNil(spec.functions[0].error)
        XCTAssertNil(spec.functions[1].ast)
        XCTAssertNotNil(spec.functions[1].error)
        XCTAssertEqual(spec.parameters.first?.name, "a")

        // All invalid fails the block
        XCTAssertThrowsError(try ChatPlotSpec.parse("{\"functions\":[{\"expr\":\"1 + ;\"}]}").get())
        XCTAssertThrowsError(try ChatPlotSpec.parse("not json").get())
    }
}
