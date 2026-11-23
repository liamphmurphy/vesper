import XCTest
@testable import VesperCore

final class ChatProductivityBlocksTests: XCTestCase {
    func testDataTableJSONCSVSortFilterAndInvalid() throws {
        let json = """
        {
          "title": "Services",
          "columns": [
            {"key": "name", "label": "Service", "type": "text"},
            {"key": "cost", "label": "Monthly", "type": "currency"},
            {"key": "p95", "label": "p95", "type": "duration"},
            {"key": "state", "label": "Status", "type": "status"}
          ],
          "rows": [
            {"name": "API", "cost": 120.5, "p95": 45, "state": "healthy"},
            {"name": "Worker", "cost": 35, "p95": 1800, "state": "degraded"}
          ]
        }
        """
        let table = try ChatDataTableSpec.parse(json).get()
        XCTAssertEqual(table.columns.count, 4)
        XCTAssertEqual(table.rows[0]["cost"]?.formatted(for: table.columns[1]), "$120.50")
        XCTAssertEqual(table.rows[1]["p95"]?.formatted(for: table.columns[2]), "1.80s")

        let sortedAsc = table.filteredAndSorted(query: "", sortKey: "cost", ascending: true)
        XCTAssertEqual(sortedAsc.first?["name"]?.rawText, "Worker")
        let filtered = table.filteredAndSorted(query: "api", sortKey: nil, ascending: true)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertTrue(table.csvText().contains("$120.50"))

        // CSV mode
        let csv = try ChatDataTableSpec.parse("Name,Score\nAlpha,10\nBeta,20").get()
        XCTAssertEqual(csv.rows.count, 2)

        // Invalid
        XCTAssertThrowsError(try ChatDataTableSpec.parse("{\"rows\":[]}").get())
        XCTAssertThrowsError(try ChatDataTableSpec.parse("only one line").get())
    }

    func testCodeGroupLineRangesAndValidation() throws {
        let json = """
        {
          "title": "Migration",
          "tabs": [
            {"label": "main.go", "code": "package main\\nfunc main() {}", "highlight": [1, "2-2"]},
            {"label": "App.swift", "language": "swift", "code": "let x = 1"}
          ]
        }
        """
        let spec = try ChatCodeGroupSpec.parse(json).get()
        XCTAssertEqual(spec.tabs.count, 2)
        XCTAssertEqual(spec.tabs[0].language, "go")
        XCTAssertEqual(spec.tabs[0].highlightedLines, Set([1, 2]))
        XCTAssertThrowsError(try ChatCodeGroupSpec.parse("{\"tabs\":[]}").get())
    }

    func testKVJSONAndPlainTextParsing() throws {
        let jsonSpec = try ChatKVSpec.parse("""
        {"title":"Run","items":[{"key":"Status","value":"done","tone":"success"},{"key":"SHA","value":"abc123","mono":true}]}
        """).get()
        XCTAssertEqual(jsonSpec.items.count, 2)
        XCTAssertTrue(jsonSpec.items[1].mono)

        let textSpec = try ChatKVSpec.parse("[Server]\nHost: localhost\nPort: 8000").get()
        XCTAssertEqual(textSpec.items.count, 2)
        XCTAssertEqual(textSpec.items[0].section, "Server")

        XCTAssertThrowsError(try ChatKVSpec.parse("no colons here").get())
    }

    func testJSONTreeAndHTTPBlocks() throws {
        let jt = try ChatJSONTreeSpec.parse("{\"user\":{\"name\":\"Judy\",\"roles\":[\"admin\"]}}", info: "json-tree Payload").get()
        XCTAssertEqual(jt.title, "Payload")
        XCTAssertEqual(jt.root.children.first?.path, "$.user")
        XCTAssertTrue(jt.root.matches(query: "judy"))
        XCTAssertFalse(jt.root.matches(query: "missing-key"))
        XCTAssertThrowsError(try ChatJSONTreeSpec.parse("{not json").get())

        let http = try ChatHTTPSpec.parse("""
        {"method":"post","url":"https://api.example.com/v1/items","status":201,"durationMs":42,"headers":{"Content-Type":"application/json"},"body":{"ok":true}}
        """).get()
        XCTAssertEqual(http.method, "POST")
        XCTAssertEqual(http.status, 201)
        XCTAssertNotNil(http.jsonBody)
        XCTAssertThrowsError(try ChatHTTPSpec.parse("{\"method\":\"GET\"}").get())
    }

    func testTabsAndDetailsBlocks() throws {
        let tabs = try ChatTabsSpec.parse("""
        {"title":"Install","tabs":[{"label":"macOS","body":"brew install foo"},{"label":"Linux","body":"apt install foo"}]}
        """).get()
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertThrowsError(try ChatTabsSpec.parse("{\"tabs\":[]}").get())

        let det = try ChatDetailsSpec.parse("{\"summary\":\"Full trace\",\"open\":true,\"body\":\"**Bold** trace\"}").get()
        XCTAssertEqual(det.summary, "Full trace")
        XCTAssertTrue(det.defaultOpen)

        let detHeader = try ChatDetailsSpec.parse("Body text", info: "details Show more").get()
        XCTAssertEqual(detHeader.summary, "Show more")

        XCTAssertThrowsError(try ChatDetailsSpec.parse("   ").get())
    }
}
