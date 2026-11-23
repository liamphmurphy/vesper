import XCTest
@testable import VesperCore

final class ChatDiffAndCompareTests: XCTestCase {
    func testDiffParsesBeforeAfterProseWordSpansAndCollapsedChunks() throws {
        let json = """
        {
          "title": "Chapter 1 Edit",
          "mode": "prose",
          "before": "The quick brown fox jumps over the lazy dog.",
          "after": "The swift brown fox leaps over the lazy dog."
        }
        """
        let spec = try ChatDiffSpec.parse(json).get()
        XCTAssertEqual(spec.mode, .prose)
        XCTAssertEqual(spec.additions, 1)
        XCTAssertEqual(spec.deletions, 1)
        let removed = spec.lines.first { $0.kind == .removed }
        let added = spec.lines.first { $0.kind == .added }
        XCTAssertTrue(removed?.wordSpans.contains(where: { $0.changed && $0.text.contains("quick") }) == true)
        XCTAssertTrue(added?.wordSpans.contains(where: { $0.changed && $0.text.contains("swift") }) == true)

        // Long unchanged region collapses
        let unchanged = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let big = ChatDiffSpec.buildFromPair(
            before: "a\n" + unchanged + "\nz",
            after: "b\n" + unchanged + "\nz",
            title: nil, filename: nil, language: "go", mode: .code
        )
        let chunks = big.collapsedChunks(threshold: 6, keepContext: 2)
        XCTAssertTrue(chunks.contains { if case .collapsed = $0 { return true }; return false })
    }

    func testDiffParsesUnifiedAndRejectsInvalid() throws {
        let unified = """
        --- a/main.go
        +++ b/main.go
        @@ -1,2 +1,2 @@
        -old()
        +new()
         keep()
        """
        let spec = try ChatDiffSpec.parse(unified, info: "diff go").get()
        XCTAssertEqual(spec.filename, "main.go")
        XCTAssertEqual(spec.language, "go")
        XCTAssertEqual(spec.additions, 1)
        XCTAssertEqual(spec.deletions, 1)

        XCTAssertThrowsError(try ChatDiffSpec.parse("not a diff at all").get())
        XCTAssertThrowsError(try ChatDiffSpec.parse("{bad json").get())
    }

    func testCompareWeightedTotalsAndValidation() throws {
        let json = """
        {
          "title": "Database Pick",
          "options": [
            {"id": "pg", "name": "Postgres", "recommended": true},
            {"id": "sq", "name": "SQLite"}
          ],
          "criteria": [
            {"name": "Concurrency", "weight": 3, "dealbreaker": true, "winner": "pg", "values": {"pg": "MVCC", "sq": "Single writer"}, "scores": {"pg": 10, "sq": 4}},
            {"name": "Simplicity", "weight": 1, "winner": "sq", "values": {"pg": "Server", "sq": "File"}, "scores": {"pg": 6, "sq": 10}}
          ]
        }
        """
        let spec = try ChatCompareSpec.parse(json).get()
        XCTAssertEqual(spec.recommendedOption?.id, "pg")
        XCTAssertTrue(spec.hasWeightsAndScores)
        let baseTotals = spec.weightedTotals()
        // pg: (10*3 + 6*1)/4 = 9.0; sq: (4*3 + 10*1)/4 = 5.5
        XCTAssertEqual(baseTotals["pg"] ?? 0, 9.0, accuracy: 0.001)
        XCTAssertEqual(baseTotals["sq"] ?? 0, 5.5, accuracy: 0.001)

        // Flip weights so simplicity dominates
        let flipped = spec.weightedTotals(weights: [0: 1.0, 1: 9.0])
        XCTAssertGreaterThan(flipped["sq"] ?? 0, flipped["pg"] ?? 0)

        // Invalid compare specs
        XCTAssertThrowsError(try ChatCompareSpec.parse("{\"options\":[{\"name\":\"OnlyOne\"}],\"criteria\":[{\"name\":\"A\"}]}").get())
        XCTAssertThrowsError(try ChatCompareSpec.parse("not json").get())
    }
}
