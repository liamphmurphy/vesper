import Foundation
import XCTest
@testable import VesperCore

/// The native renderer against the web's: each fixture in protocol/markdown/fixtures goes through
/// `MarkdownParser` and `CodeHighlighter`, and must match what web/scripts/markdown-fixtures.mjs
/// wrote from the web's own pipeline (remark + Shiki) into protocol/markdown/expected.
final class MarkdownSnapshotTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("protocol/markdown")
    static let shikiScript = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/VesperCore/Resources/shiki/shiki.js")

    struct Fixture: Decodable {
        var name: String
        var chat: Bool?
        var cites: [Int]?
    }

    func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.root.appendingPathComponent("fixtures.json")))
    }

    func expected(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("expected/\(name).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func document(_ fixture: Fixture) throws -> MarkdownDocument {
        let source = try String(contentsOf: Self.root.appendingPathComponent("fixtures/\(fixture.name).md"), encoding: .utf8)
        return MarkdownParser.parse(source, chat: fixture.chat ?? false, citations: fixture.cites ?? [])
    }

    /// Sorted, indented JSON, so a mismatch shows as a readable diff.
    func canonical(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    func testFixturesParseToTheWebStructure() throws {
        let all = try fixtures()
        XCTAssertGreaterThanOrEqual(all.count, 6)
        for fixture in all {
            let want = try canonical(try XCTUnwrap(try expected(fixture.name)["ast"]))
            let got = try canonical(try document(fixture).snapshot())
            XCTAssertEqual(got, want, "fixture \(fixture.name)")
        }
    }

    func testCodeTokensMatchShikiOnTheWeb() async throws {
        let highlighter = CodeHighlighter(scriptURL: Self.shikiScript)
        var languages = Set<String>()
        for fixture in try fixtures() {
            let expectedBlocks = try XCTUnwrap(try expected(fixture.name)["code"] as? [[String: Any]])
            let blocks = try document(fixture).codeBlocks.compactMap { block in block.language.map { (block.code, $0) } }
            XCTAssertEqual(blocks.count, expectedBlocks.count, "fixture \(fixture.name): highlighted blocks")
            for ((code, language), want) in zip(blocks, expectedBlocks) {
                XCTAssertEqual(language, want["lang"] as? String)
                languages.insert(language)
                let tokens = await highlighter.highlight(code, language: language)
                let loadError = await highlighter.loadError
                let lines = try XCTUnwrap(tokens, "\(language) didn't highlight: \(loadError ?? "")")
                let got: [[[Any]]] = lines.map { line in
                    line.map { t in
                        [t.content, t.light as Any? ?? NSNull(), t.dark as Any? ?? NSNull(),
                         CodePalette.light.color(for: t.light), CodePalette.dark.color(for: t.dark)]
                    }
                }
                XCTAssertEqual(try canonical(got), try canonical(want["lines"] as Any), "fixture \(fixture.name), \(language)")
            }
        }
        XCTAssertTrue(languages.isSuperset(of: ["go", "typescript", "python", "json", "shellscript"]), "\(languages)")
    }

    func testHighlighterKnowsTheWebsLanguages() async {
        let languages = await CodeHighlighter(scriptURL: Self.shikiScript).languages()
        XCTAssertEqual(languages.count, 26)
        XCTAssertTrue(languages.contains("tsx"))
        let unknown = await CodeHighlighter(scriptURL: Self.shikiScript).highlight("x", language: "cobol")
        XCTAssertNil(unknown)
    }

    func testTheShikiScriptShipsAsAPackageResource() throws {
        let url = try XCTUnwrap(CodeHighlighter.bundledScript())
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: Self.shikiScript))
    }

    func testAMissingScriptLeavesCodePlain() async {
        let highlighter = CodeHighlighter(scriptURL: URL(fileURLWithPath: "/nonexistent/shiki.js"))
        let tokens = await highlighter.highlight("let a = 1", language: "swift")
        XCTAssertNil(tokens)
        let error = await highlighter.loadError
        XCTAssertNotNil(error)
    }
}
