import XCTest
@testable import VesperCore

final class ChatCodeReviewLogicTests: XCTestCase {
    func testRepoNameAndBaseName() {
        XCTAssertEqual(ChatCodeReviewLogic.repoName("https://github.com/liamphmurphy/Vesper.git"), "liamphmurphy/Vesper")
        XCTAssertEqual(ChatCodeReviewLogic.repoName("git@github.com:org/repo.git"), "org/repo")
        XCTAssertEqual(ChatCodeReviewLogic.baseName("macos/Sources/App.swift"), "App.swift")
        XCTAssertEqual(ChatCodeReviewLogic.baseName("README.md"), "README.md")
    }

    func testReviewMessageFormatsSortedAnchoredComments() {
        let comments = [
            ChatCodeReviewLogic.LineComment(path: "b.swift", line: 20, side: .old, code: "  let x = 1  ", body: "Why remove this?"),
            ChatCodeReviewLogic.LineComment(path: "a.swift", line: 5, side: .new, code: "func foo()", body: "Add docs\nwith examples"),
            ChatCodeReviewLogic.LineComment(path: "a.swift", line: 9, side: .new, code: "ignored", body: "   "),
        ]
        let msg = ChatCodeReviewLogic.reviewMessage(comments: comments, branch: "feat/demo")
        XCTAssertTrue(msg.hasPrefix("Review of `feat/demo` (2 comments). Please address each:\n\n"))
        XCTAssertTrue(msg.contains("- `a.swift:5`\n  > func foo()\n  Add docs\n  with examples"))
        XCTAssertTrue(msg.contains("- `b.swift:20` (removed line)\n  > let x = 1\n  Why remove this?"))
        XCTAssertFalse(msg.contains("a.swift:9"))
        XCTAssertEqual(ChatCodeReviewLogic.reviewMessage(comments: [], branch: nil), "")
    }

    func testGroupedFilesSortsDirectoriesAndPaths() {
        let f1 = API.ChatCodeChange(additions: 4, binary: false, deletions: 1, path: "src/b.ts", status: .modified, truncated: false)
        let f2 = API.ChatCodeChange(additions: 2, binary: false, deletions: 0, path: "README.md", status: .modified, truncated: false)
        let f3 = API.ChatCodeChange(additions: 1, binary: false, deletions: 0, path: "src/a.ts", status: .added, truncated: false)
        let groups = ChatCodeReviewLogic.groupedFiles([f1, f2, f3])
        XCTAssertEqual(groups.map(\.dir), ["", "src"])
        XCTAssertEqual(groups[1].files.map(\.path), ["src/a.ts", "src/b.ts"])
        let totals = ChatCodeReviewLogic.totals(for: [f1, f2, f3])
        XCTAssertEqual(totals.additions, 7)
        XCTAssertEqual(totals.deletions, 1)
    }

    func testFlattenHunksMapsTokenIndicesSkippingMetaRows() {
        let patch = """
        @@ -1,3 +1,3 @@
         let a = 1
        -let b = 2
        +let b = 3
        \\ No newline at end of file
        @@ -10,1 +10,2 @@
         return a
        +return b
        """
        let hunks = RunFilesLogic.parseHunks(patch)
        let items = ChatCodeReviewLogic.flattenHunks(hunks)
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)

        let rowTokens = items.compactMap { item -> Int? in
            if case .row(_, _, let tokenIdx) = item { return tokenIdx }
            return nil
        }
        // First hunk: 3 code rows (0, 1, 2) + 1 meta row (nil); second hunk: 2 code rows (0, 1)
        XCTAssertEqual(rowTokens, [0, 1, 2, 0, 1])
    }

    func testContentFingerprintDistinguishesEqualLengthPatches() {
        let a = ChatCodeReviewLogic.contentFingerprint("@@ -1 +1 @@\n-foo\n+bar\n")
        let b = ChatCodeReviewLogic.contentFingerprint("@@ -1 +1 @@\n-foo\n+baz\n")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(ChatCodeReviewLogic.contentFingerprint(nil), 0)
    }

    func testCodeHighlighterRejectsOversizedAndMinifiedInputs() async {
        XCTAssertFalse(CodeHighlighter.canHighlight(""))
        XCTAssertTrue(CodeHighlighter.canHighlight("let x = 1\nlet y = 2\n"))

        let tooManyBytes = String(repeating: "a\n", count: (CodeHighlighter.maxHighlightBytes / 2) + 10)
        XCTAssertFalse(CodeHighlighter.canHighlight(tooManyBytes))

        let tooManyLines = Array(repeating: "x", count: CodeHighlighter.maxHighlightLines + 1).joined(separator: "\n")
        XCTAssertFalse(CodeHighlighter.canHighlight(tooManyLines))

        let minifiedLine = String(repeating: "a", count: CodeHighlighter.maxLineLength + 1)
        XCTAssertFalse(CodeHighlighter.canHighlight(minifiedLine))

        let highlighter = CodeHighlighter(scriptURL: nil)
        let skipped = await highlighter.highlight(minifiedLine, language: "javascript")
        XCTAssertNil(skipped)

        // CodePalette with truncated series must fall back to ink instead of trapping
        let shortPalette = CodePalette(ink: "#111111", muted: "#666666", series: [])
        XCTAssertEqual(shortPalette.color(for: "#FF0000"), "#111111")
    }

    func testCompareSpecWeightedTotalsToleratesDuplicateOptionIDs() {
        let spec = ChatCompareSpec(
            options: [
                ChatCompareMatrixOption(id: "dup", name: "First"),
                ChatCompareMatrixOption(id: "dup", name: "Second"),
            ],
            criteria: [
                ChatCompareCriterion(id: 0, name: "Speed", weight: 2, scores: ["dup": 8])
            ]
        )
        let totals = spec.weightedTotals()
        XCTAssertEqual(totals["dup"] ?? 0, 8, accuracy: 0.001)
    }
}
