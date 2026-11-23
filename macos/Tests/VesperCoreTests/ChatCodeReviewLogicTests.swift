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
}
