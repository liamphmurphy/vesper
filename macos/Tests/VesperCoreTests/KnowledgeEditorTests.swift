import Foundation
import XCTest
@testable import VesperCore

final class KnowledgeEditorTests: XCTestCase {

    // MARK: - 1. Live-Preview Syntax & Hit Testing

    func testLivePreviewHidesAndRevealsSyntaxAroundCursor() {
        let md = "See [[Architecture/ADR 1|ADR 1]] and ![[diagram.png]] #design/v2 ^blk-42\n"
        let tokens = KnowledgeMarkdownSyntax.scan(md)
        XCTAssertTrue(tokens.contains { if case .wikiLink = $0.kind { return true }; return false })
        XCTAssertTrue(tokens.contains { if case .embed = $0.kind { return true }; return false })
        XCTAssertTrue(tokens.contains { if case .tag = $0.kind { return true }; return false })
        XCTAssertTrue(tokens.contains { if case .blockID = $0.kind { return true }; return false })

        // Caret at offset 0: wikilink delimiters should be hidden.
        let away = KnowledgeMarkdownSyntax.livePreview(in: md, selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(away.hiddenRanges.isEmpty)

        // Caret inside [[Architecture/ADR 1|ADR 1]]: that token's delimiters reveal.
        let linkToken = try! XCTUnwrap(tokens.first { if case .wikiLink = $0.kind { return true }; return false })
        let inside = KnowledgeMarkdownSyntax.livePreview(in: md, selection: NSRange(location: linkToken.range.location + 2, length: 0))
        XCTAssertLessThan(inside.hiddenRanges.count, away.hiddenRanges.count)

        // Cmd-click hit-test resolves link target.
        let target = KnowledgeMarkdownSyntax.hitTestLink(at: linkToken.range.location + 5, in: md)
        XCTAssertEqual(target?.target, "Architecture/ADR 1")
        XCTAssertEqual(target?.alias, "ADR 1")
    }

    func testResolveInlineEmbedsMatchesServerRawRefsAndDeduplicates() {
        let assetRef = "![[attachment:88888888-8888-4888-8888-888888888888/map.png]]"
        let libraryRef = "![[library:99999999-9999-4999-8999-999999999999]]"
        let aliasedRef = "![[attachment:77777777-7777-4777-8777-777777777777/plan.webp|Floor Plan]]"
        let missingRef = "![[attachment:66666666-6666-4666-8666-666666666666/missing.png]]"
        let md = """
        Intro
        \(assetRef)
        Repeat \(assetRef)
        \(libraryRef)
        \(aliasedRef)
        \(missingRef)
        """
        let embeds = [
            KnowledgeEmbed(
                ref: libraryRef,
                kind: "image",
                title: "Portrait",
                url: "/api/v1/library/99999999-9999-4999-8999-999999999999/content",
                contentType: "image/png",
                available: true
            ),
            KnowledgeEmbed(
                ref: assetRef,
                kind: "file",
                title: "map.png",
                url: "/api/v1/knowledge/assets/88888888-8888-4888-8888-888888888888",
                contentType: "image/png",
                available: true
            ),
            KnowledgeEmbed(
                ref: aliasedRef,
                kind: "file",
                title: "plan.webp",
                url: "/api/v1/knowledge/assets/77777777-7777-4777-8777-777777777777",
                contentType: "image/webp",
                available: true
            ),
            KnowledgeEmbed(
                ref: missingRef,
                kind: "unresolved",
                available: false
            ),
        ]

        let resolved = KnowledgeMarkdownSyntax.resolveInlineEmbeds(in: md, embeds: embeds)
        XCTAssertEqual(resolved.map(\.ref), [assetRef, libraryRef, aliasedRef])
        XCTAssertEqual(resolved.map(\.title), ["map.png", "Portrait", "plan.webp"])
    }

    // MARK: - 2. Completion (`[[`, `![[`, `#`)

    func testWikiEmbedAndTagCompletion() {
        let wikiText = "Check [[Arch"
        let wikiTrigger = KnowledgeCompletionLogic.matchTrigger(in: wikiText, caretUTF16: (wikiText as NSString).length)
        XCTAssertEqual(wikiTrigger?.kind, .page)
        XCTAssertEqual(wikiTrigger?.query, "Arch")

        let candidates = [
            KnowledgeCompletionCandidate(kind: .page, title: "Old Archive", insertRef: "Old Archive", detail: "Old"),
            KnowledgeCompletionCandidate(kind: .page, title: "Architecture", insertRef: "Architecture", detail: "Docs"),
        ]
        if let trigger = wikiTrigger {
            let ranked = KnowledgeCompletionLogic.rankCandidates(candidates, for: trigger)
            XCTAssertEqual(ranked.first?.title, "Architecture")

            if let first = ranked.first {
                let insertion = KnowledgeCompletionLogic.insertion(for: first, trigger: trigger)
                let applied = KnowledgeCompletionLogic.apply(insertion, to: wikiText)
                XCTAssertTrue(applied.contains("[[Architecture]]"))
            }
        }

        let embedText = "Image ![[hero"
        let embedTrigger = KnowledgeCompletionLogic.matchTrigger(in: embedText, caretUTF16: (embedText as NSString).length)
        XCTAssertEqual(embedTrigger?.kind, .embed)
        XCTAssertEqual(embedTrigger?.query, "hero")

        let tagText = "Tagged #eng"
        let tagTrigger = KnowledgeCompletionLogic.matchTrigger(in: tagText, caretUTF16: (tagText as NSString).length)
        XCTAssertEqual(tagTrigger?.kind, .tag)
        XCTAssertEqual(tagTrigger?.query, "eng")
    }

    // MARK: - 3. Table Grid Editing & Tiptap Padded Serialization

    func testTableGridEditingTabNavigationResizeAndTiptapSerialization() {
        let md = """
        | Name | Status |
        | --- | --- |
        | Alpha | Done |
        """
        let tables = MarkdownTableModel.parseTables(in: md)
        XCTAssertEqual(tables.count, 1)
        var table = tables[0]
        XCTAssertFalse(table.isDirty)
        XCTAssertEqual(table.serialize(), md)

        // Cell edit + Tab navigation + Tab at last cell adds a row.
        table.setCellText("Beta Release", at: TableCellCoordinate(row: 1, column: 0))
        XCTAssertTrue(table.isDirty)
        let next1 = table.navigateTab(from: TableCellCoordinate(row: 0, column: 0))
        XCTAssertEqual(next1, TableCellCoordinate(row: 0, column: 1))
        let back = table.navigateTab(from: next1, backwards: true)
        XCTAssertEqual(back, TableCellCoordinate(row: 0, column: 0))

        let lastCell = TableCellCoordinate(row: 1, column: 1)
        let appended = table.navigateTab(from: lastCell)
        XCTAssertEqual(appended, TableCellCoordinate(row: 2, column: 0))
        XCTAssertEqual(table.rows.count, 2)

        // Add/remove columns & resize.
        table.addColumn(header: "Owner")
        XCTAssertEqual(table.columnCount, 3)
        table.resizeColumn(at: 0, width: 240)
        XCTAssertEqual(table.columnWidths[0], 240)
        XCTAssertTrue(table.removeColumn(at: 2))
        XCTAssertEqual(table.columnCount, 2)

        // Tiptap-compatible column-padded serialization.
        let serialized = table.serializeTiptapFormatted()
        XCTAssertTrue(serialized.contains("| Beta Release | Done   |"))
        XCTAssertTrue(serialized.contains("| ------------ | ------ |"))

        // Edit as Markdown round-trip.
        let editedRaw = "| Key | Val |\n| --- | --- |\n| k1  | v1  |"
        XCTAssertTrue(table.applyRawMarkdown(editedRaw))
        XCTAssertEqual(table.headers, ["Key", "Val"])
        XCTAssertEqual(table.cellText(at: TableCellCoordinate(row: 1, column: 1)), "v1")
    }

    // MARK: - 4. Hard Cases: Cross-Boundary Selection, Find, Undo Ordering, Copy

    func testSelectionSpanningProseAndTableCopyAndFind() {
        let md = """
        Intro mentions target here.

        | Col A | Col B |
        | --- | --- |
        | target cell | other |

        Outro also mentions target.
        """
        let doc = KnowledgeEditorDocument(markdown: md)
        let tableIndex = try! XCTUnwrap(doc.tableSegmentIndices.first)
        XCTAssertGreaterThan(tableIndex, 0)

        // Selection spanning prose before table into prose after table.
        let selection = DocumentSelection(
            anchor: .prose(segmentIndex: 0, utf16Offset: 0),
            focus: .prose(segmentIndex: tableIndex + 1, utf16Offset: 10)
        )
        XCTAssertTrue(selection.spansProseAndTable)
        let copied = doc.selectedMarkdown(for: selection)
        XCTAssertTrue(copied.contains("Intro mentions target"))
        XCTAssertTrue(copied.contains("| target cell | other |"))

        // Find matches across BOTH prose and table cells in document order.
        let matches = doc.findMatches(query: "target", caseSensitive: false)
        XCTAssertEqual(matches.count, 3)
        XCTAssertFalse(matches[0].position.isInTable)
        XCTAssertTrue(matches[1].position.isInTable)
        XCTAssertFalse(matches[2].position.isInTable)
    }

    func testInterleavedUndoAndRedoOrderingAcrossProseAndTable() {
        let md = "Header\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\nFooter"
        var doc = KnowledgeEditorDocument(markdown: md)
        let tableIdx = try! XCTUnwrap(doc.tableSegmentIndices.first)

        // Edit 1: prose
        XCTAssertTrue(doc.replaceProse(in: 0, range: NSRange(location: 0, length: 6), with: "Title"))
        let after1 = doc.serialize()
        XCTAssertTrue(after1.hasPrefix("Title"))

        // Edit 2: table cell
        XCTAssertTrue(doc.editTableCell(at: tableIdx, row: 1, column: 0, text: "99"))
        let after2 = doc.serialize()
        XCTAssertTrue(after2.contains("99"))

        // Edit 3: trailing prose
        let tailIdx = tableIdx + 1
        XCTAssertTrue(doc.replaceProse(in: tailIdx, range: NSRange(location: 2, length: 6), with: "End"))
        let after3 = doc.serialize()
        XCTAssertTrue(after3.hasSuffix("End"))

        // Undo in strict reverse chronological order.
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.serialize(), after2)
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.serialize(), after1)
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.serialize(), md)

        // Redo restores exact steps.
        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.serialize(), after1)
        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.serialize(), after2)
        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.serialize(), after3)
    }

    // MARK: - 5. Mandatory Byte-for-Byte Round-Trip Corpus Test (Epic Criterion 4)

    func testRoundTripCorpusIsByteForByteUnchangedWithoutEdits() {
        let corpus: [(name: String, content: String)] = [
            ("empty", ""),
            ("single-line-no-newline", "Hello [[World]] #tag"),
            ("frontmatter-and-wikilinks", "---\ntitle: Umbra Session 12\ntags: [dnd, campaign/umbra]\ndate: 2026-11-20\n---\n\n# Session 12\n\nMet [[Elminster|The Sage]] at [[Waterdeep#Yawning Portal]] ^intro-1\n"),
            ("obsidian-embeds-and-callouts", "> [!NOTE] Important\n> Embedded diagram: ![[maps/tavern.png]] and ![[handout.pdf]]\n\nNormal paragraph with **bold**, _italic_, and `[[not-a-link]]`.\n"),
            ("uneven-pipe-table", "Before\n\n|a|b|\n|-|-|\n|1|2|\n\nAfter\n"),
            ("aligned-table", "| Left | Center | Right |\n| :--- | :----: | ----: |\n| foo  |  bar   |   baz |\n"),
            ("multiple-tables", "Intro\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nMiddle text ^mid\n\n| X | Y | Z |\n| --- | --- | --- |\n| p | q | r |\n"),
            ("fenced-code-with-pipes", "```md\n| Not | A Table |\n| --- | --- |\n[[NotALink]] #NotATag\n```\n"),
            ("crlf-endings", "Line one\r\n\r\n| H1 | H2 |\r\n| --- | --- |\r\n| v1 | v2 |\r\n\r\nLine two\r\n"),
            ("trailing-spaces-and-blanks", "Line with two trailing spaces  \n\n\n   \nEnd"),
            ("unicode-and-emoji", "# Café & 日本語 🗺️\n\n| Item | Cost |\n| --- | --- |\n| Potion 🧪 | 50 gp |\n"),
            ("nested-lists-and-block-ids", "- Parent #top\n  - Child [[Sub Page]] ^child-1\n    1. Numbered step\n"),
        ]

        for sample in corpus {
            let doc = KnowledgeEditorDocument(markdown: sample.content)
            XCTAssertFalse(doc.isDirty, "Untouched document \(sample.name) should not be dirty")
            let saved = doc.serialize()
            XCTAssertEqual(
                Data(saved.utf8),
                Data(sample.content.utf8),
                "Round-trip byte mismatch for corpus page '\(sample.name)'"
            )
        }
    }
}
