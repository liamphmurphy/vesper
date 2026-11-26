import AppKit
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

    func testGroupInlineEmbedsByParagraphPreservesDuplicatesLineKindsAndStableIDs() {
        let mapRef = "![[attachment:88888888-8888-4888-8888-888888888888/map.png]]"
        let pdfRef = "![[attachment:77777777-7777-4777-8777-777777777777/spec.pdf]]"
        let missingRef = "![[attachment:66666666-6666-4666-8666-666666666666/missing.png]]"
        let designRef = "![[design:55555555-5555-4555-8555-555555555555#frame1]]"

        let embeds = [
            KnowledgeEmbed(
                ref: mapRef,
                kind: "file",
                title: "map.png",
                url: "/api/v1/knowledge/assets/88888888-8888-4888-8888-888888888888",
                contentType: "image/png",
                available: true
            ),
            KnowledgeEmbed(
                ref: pdfRef,
                kind: "file",
                title: "spec.pdf",
                url: "/api/v1/knowledge/assets/77777777-7777-4777-8777-777777777777",
                contentType: "application/pdf",
                available: true
            ),
            KnowledgeEmbed(ref: missingRef, kind: "unresolved", available: false),
            KnowledgeEmbed(ref: designRef, kind: "design", title: "Flow", url: "/apps/designs/5555", available: true),
        ]

        let md = """
        Intro paragraph.

        \(mapRef)

        Inline with text: \(mapRef) and \(pdfRef)

        \(mapRef) \(missingRef)

        \(designRef)

        ```
        \(mapRef)
        ```

        Outro paragraph.
        """

        let groups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(in: md, embeds: embeds)
        // Line 1: standalone mapRef
        // Line 2: inline mapRef + pdfRef
        // Line 3: mapRef next to unresolved missingRef -> not standalone because unresolved stays visible
        // designRef has no inline preview card, fenced code block is skipped.
        XCTAssertEqual(groups.count, 3)

        XCTAssertTrue(groups[0].isStandaloneLine)
        XCTAssertFalse(groups[0].fillsContainerWidth)
        XCTAssertEqual(groups[0].placements.map(\.embed.ref), [mapRef])

        XCTAssertFalse(groups[1].isStandaloneLine)
        XCTAssertTrue(groups[1].fillsContainerWidth)
        XCTAssertEqual(groups[1].placements.map(\.embed.ref), [mapRef, pdfRef])

        XCTAssertFalse(groups[2].isStandaloneLine)
        XCTAssertEqual(groups[2].placements.map(\.embed.ref), [mapRef])

        // Typing text above the embeds keeps group IDs stable so mounted image views don't reload.
        let edited = "Added new intro line!\n\n" + md
        let editedGroups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(in: edited, embeds: embeds)
        XCTAssertEqual(editedGroups.map(\.id), groups.map(\.id))
        XCTAssertGreaterThan(editedGroups[0].lineRange.location, groups[0].lineRange.location)
    }

    func testShouldRevealEmbedSourceAndFittedImageSize() {
        let mapRef = "![[attachment:88888888-8888-4888-8888-888888888888/map.png]]"
        let embed = KnowledgeEmbed(
            ref: mapRef,
            kind: "file",
            title: "map.png",
            url: "/api/v1/knowledge/assets/88888888-8888-4888-8888-888888888888",
            contentType: "image/png",
            available: true
        )
        let md = "Before.\n\n  \(mapRef)  \n\nAfter."
        let placement = try! XCTUnwrap(KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: md, embeds: [embed]).first)
        XCTAssertTrue(placement.isStandaloneLine)

        // Unfocused: stays hidden even if selection happens to be inside.
        XCTAssertFalse(KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
            for: placement,
            selection: NSRange(location: placement.tokenRange.location, length: 0),
            isFocused: false
        ))
        // Focused elsewhere: hidden.
        XCTAssertFalse(KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
            for: placement,
            selection: NSRange(location: 0, length: 0),
            isFocused: true
        ))
        // Focused anywhere on the standalone line (including leading space): revealed.
        XCTAssertTrue(KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
            for: placement,
            selection: NSRange(location: placement.lineContentRange.location, length: 0),
            isFocused: true
        ))
        // Active Cmd+F match inside token: revealed even when editor isn't focused.
        XCTAssertTrue(KnowledgeMarkdownSyntax.shouldRevealEmbedSource(
            for: placement,
            selection: NSRange(location: 0, length: 0),
            isFocused: false,
            activeFindMatch: NSRange(location: placement.tokenRange.location + 5, length: 7)
        ))

        // Aspect-fit sizing: scales down large images, preserves small images without upscaling.
        let wide = KnowledgeMarkdownSyntax.fittedInlineImageSize(
            naturalSize: CGSize(width: 920, height: 460),
            maxWidth: 460,
            maxHeight: 320
        )
        XCTAssertEqual(wide, CGSize(width: 460, height: 230))

        let tall = KnowledgeMarkdownSyntax.fittedInlineImageSize(
            naturalSize: CGSize(width: 400, height: 800),
            maxWidth: 460,
            maxHeight: 320
        )
        XCTAssertEqual(tall, CGSize(width: 160, height: 320))

        let small = KnowledgeMarkdownSyntax.fittedInlineImageSize(
            naturalSize: CGSize(width: 120, height: 80),
            maxWidth: 460,
            maxHeight: 320
        )
        XCTAssertEqual(small, CGSize(width: 120, height: 80))
    }

    @MainActor
    func testTextKit2InlineEmbedLayoutPlacesImagesAtSourcePositionsNotBottom() {
        let img1Ref = "![[attachment:11111111-1111-4111-8111-111111111111/first.png]]"
        let img2Ref = "![[attachment:22222222-2222-4222-8222-222222222222/second.png]]"
        let embeds = [
            KnowledgeEmbed(
                ref: img1Ref,
                kind: "file",
                title: "first.png",
                url: "/api/v1/knowledge/assets/11111111-1111-4111-8111-111111111111",
                contentType: "image/png",
                available: true
            ),
            KnowledgeEmbed(
                ref: img2Ref,
                kind: "file",
                title: "second.png",
                url: "/api/v1/knowledge/assets/22222222-2222-4222-8222-222222222222",
                contentType: "image/png",
                available: true
            ),
        ]
        let md = "First paragraph.\n\n\(img1Ref)\n\nMiddle paragraph.\n\n\(img2Ref)\n\nFinal paragraph."
        let layout = runInlineEmbedTextKitLayout(
            markdown: md,
            embeds: embeds,
            measuredSizes: [
                "0:\(img1Ref)": CGSize(width: 400, height: 220),
                "1:\(img2Ref)": CGSize(width: 300, height: 180),
            ]
        )

        XCTAssertEqual(layout.frames.count, 2)
        let firstPara = try! XCTUnwrap(layout.fragmentFrame(forSubstring: "First paragraph."))
        let middlePara = try! XCTUnwrap(layout.fragmentFrame(forSubstring: "Middle paragraph."))
        let finalPara = try! XCTUnwrap(layout.fragmentFrame(forSubstring: "Final paragraph."))
        let img1Frame = layout.frames[0].frame
        let img2Frame = layout.frames[1].frame

        // First image sits strictly between First paragraph and Middle paragraph.
        XCTAssertGreaterThan(img1Frame.minY, firstPara.maxY)
        XCTAssertLessThanOrEqual(img1Frame.maxY, middlePara.minY)
        XCTAssertEqual(img1Frame.height, 220, accuracy: 0.5)

        // Second image sits strictly between Middle paragraph and Final paragraph (never at bottom).
        XCTAssertGreaterThan(img2Frame.minY, middlePara.maxY)
        XCTAssertLessThanOrEqual(img2Frame.maxY, finalPara.minY)
        XCTAssertEqual(img2Frame.height, 180, accuracy: 0.5)

        // Growing the first image (simulating async image load) pushes Middle and Final paragraphs down.
        let grown = runInlineEmbedTextKitLayout(
            markdown: md,
            embeds: embeds,
            measuredSizes: [
                "0:\(img1Ref)": CGSize(width: 400, height: 320),
                "1:\(img2Ref)": CGSize(width: 300, height: 180),
            ]
        )
        let grownMiddle = try! XCTUnwrap(grown.fragmentFrame(forSubstring: "Middle paragraph."))
        let grownFinal = try! XCTUnwrap(grown.fragmentFrame(forSubstring: "Final paragraph."))
        XCTAssertGreaterThan(grownMiddle.minY, middlePara.minY + 90)
        XCTAssertGreaterThan(grownFinal.minY, finalPara.minY + 90)
        XCTAssertGreaterThan(grown.fittingHeight, layout.fittingHeight + 90)
    }

    @MainActor
    func testTextKit2InlineEmbedAtStartEndAndRevealedLine() {
        let imgRef = "![[attachment:33333333-3333-4333-8333-333333333333/banner.png]]"
        let embed = KnowledgeEmbed(
            ref: imgRef,
            kind: "file",
            title: "banner.png",
            url: "/api/v1/knowledge/assets/33333333-3333-4333-8333-333333333333",
            contentType: "image/png",
            available: true
        )

        // 1. Image at the very top of the note appears above the following paragraph.
        let topDoc = "\(imgRef)\n\nCaption text below."
        let topLayout = runInlineEmbedTextKitLayout(
            markdown: topDoc,
            embeds: [embed],
            measuredSizes: ["0:\(imgRef)": CGSize(width: 360, height: 200)]
        )
        let belowPara = try! XCTUnwrap(topLayout.fragmentFrame(forSubstring: "Caption text below."))
        let topImg = try! XCTUnwrap(topLayout.frames.first?.frame)
        XCTAssertGreaterThanOrEqual(topImg.minY, 0)
        XCTAssertLessThanOrEqual(topImg.maxY, belowPara.minY)

        // 2. Trailing image with no trailing newline still expands fittingHeight to cover the image.
        let endDoc = "Intro text.\n\n\(imgRef)"
        let endLayout = runInlineEmbedTextKitLayout(
            markdown: endDoc,
            embeds: [embed],
            measuredSizes: ["0:\(imgRef)": CGSize(width: 360, height: 240)]
        )
        let endImg = try! XCTUnwrap(endLayout.frames.first?.frame)
        let introPara = try! XCTUnwrap(endLayout.fragmentFrame(forSubstring: "Intro text."))
        XCTAssertGreaterThan(endImg.minY, introPara.maxY)
        XCTAssertGreaterThanOrEqual(endLayout.fittingHeight, endImg.maxY + KnowledgeInlineEmbedLayout.bottomGap)

        // 3. Focusing the standalone embed line reveals the raw markdown above the image without overlap.
        let revealed = runInlineEmbedTextKitLayout(
            markdown: topDoc,
            embeds: [embed],
            measuredSizes: ["0:\(imgRef)": CGSize(width: 360, height: 200)],
            selection: NSRange(location: 5, length: 0),
            isFocused: true
        )
        let revealedImg = try! XCTUnwrap(revealed.frames.first?.frame)
        let revealedBelow = try! XCTUnwrap(revealed.fragmentFrame(forSubstring: "Caption text below."))
        XCTAssertGreaterThan(revealedImg.minY, topImg.minY + 8)
        XCTAssertLessThanOrEqual(revealedImg.maxY, revealedBelow.minY)

        // 4. Inline-in-paragraph embed sits below its sentence and above the next paragraph.
        let inlineDoc = "Look at \(imgRef) right here.\nNext paragraph."
        let inlineLayout = runInlineEmbedTextKitLayout(
            markdown: inlineDoc,
            embeds: [embed],
            measuredSizes: ["0:\(imgRef)": CGSize(width: 320, height: 150)]
        )
        let inlineImg = try! XCTUnwrap(inlineLayout.frames.first?.frame)
        let nextPara = try! XCTUnwrap(inlineLayout.fragmentFrame(forSubstring: "Next paragraph."))
        XCTAssertGreaterThan(inlineImg.minY, 12)
        XCTAssertLessThanOrEqual(inlineImg.maxY, nextPara.minY)

        // 5. Two consecutive embeds on adjacent lines with no blank line do not overlap.
        let adjacentDoc = "\(imgRef)\n\(imgRef)\nAfter both."
        let adjacentLayout = runInlineEmbedTextKitLayout(
            markdown: adjacentDoc,
            embeds: [embed],
            measuredSizes: [
                "0:\(imgRef)": CGSize(width: 300, height: 140),
                "1:\(imgRef)": CGSize(width: 300, height: 160),
            ]
        )
        XCTAssertEqual(adjacentLayout.frames.count, 2)
        let afterBoth = try! XCTUnwrap(adjacentLayout.fragmentFrame(forSubstring: "After both."))
        XCTAssertLessThanOrEqual(adjacentLayout.frames[0].frame.maxY, adjacentLayout.frames[1].frame.minY)
        XCTAssertLessThanOrEqual(adjacentLayout.frames[1].frame.maxY, afterBoth.minY)
    }

    @MainActor
    private struct InlineEmbedLayoutResult {
        let frames: [KnowledgeInlineEmbedFrame]
        let fittingHeight: CGFloat
        let markdown: String
        let contentStorage: NSTextContentStorage
        let layoutManager: NSTextLayoutManager
        let origin: CGPoint

        func fragmentFrame(forSubstring needle: String) -> CGRect? {
            let range = (markdown as NSString).range(of: needle)
            guard range.location != NSNotFound,
                  let loc = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
                  let frag = layoutManager.textLayoutFragment(for: loc) else {
                return nil
            }
            layoutManager.ensureLayout(for: frag.rangeInElement)
            return frag.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        }
    }

    @MainActor
    private func runInlineEmbedTextKitLayout(
        markdown: String,
        embeds: [KnowledgeEmbed],
        measuredSizes: [String: CGSize],
        selection: NSRange? = nil,
        isFocused: Bool = false
    ) -> InlineEmbedLayoutResult {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let containerWidth: CGFloat = 600
        let origin = CGPoint(x: 0, y: 4)
        let container = NSTextContainer(size: CGSize(width: containerWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)

        let baseStyle = NSMutableParagraphStyle()
        baseStyle.lineSpacing = 4
        let attr = NSMutableAttributedString(string: markdown, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .paragraphStyle: baseStyle,
        ])

        let groups = KnowledgeMarkdownSyntax.groupInlineEmbedsByParagraph(in: markdown, embeds: embeds)
        var metricsByID: [String: KnowledgeInlineEmbedMetrics] = [:]
        let hiddenAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 0.01),
            .foregroundColor: NSColor.clear,
        ]

        for group in groups {
            let anyRevealed = group.placements.contains {
                KnowledgeMarkdownSyntax.shouldRevealEmbedSource(for: $0, selection: selection, isFocused: isFocused)
            }
            let isCollapsedStandalone = group.isStandaloneLine && !anyRevealed
            let size = measuredSizes[group.id] ?? KnowledgeInlineEmbedLayout.defaultPlaceholderSize
            let metrics = KnowledgeInlineEmbedLayout.metrics(
                measuredSize: size,
                isCollapsedStandalone: isCollapsedStandalone
            )
            metricsByID[group.id] = metrics

            if isCollapsedStandalone {
                attr.addAttributes(hiddenAttrs, range: group.lineContentRange)
            }
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineSpacing = isCollapsedStandalone ? 0 : 4
            if isCollapsedStandalone {
                paraStyle.maximumLineHeight = KnowledgeInlineEmbedLayout.collapsedStandaloneLineHeight
            }
            paraStyle.paragraphSpacing = metrics.reservedSpacing
            attr.addAttribute(.paragraphStyle, value: paraStyle, range: group.lineRange)
        }

        contentStorage.attributedString = attr
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        let frames = KnowledgeInlineEmbedLayout.computeFrames(
            groups: groups,
            metricsByID: metricsByID,
            contentStorage: contentStorage,
            layoutManager: layoutManager,
            containerWidth: containerWidth,
            textContainerOrigin: origin
        )
        let height = KnowledgeInlineEmbedLayout.totalFittingHeight(
            usageBoundsHeight: layoutManager.usageBoundsForTextContainer.height,
            embedFrames: frames,
            verticalInset: origin.y
        )
        return InlineEmbedLayoutResult(
            frames: frames,
            fittingHeight: height,
            markdown: markdown,
            contentStorage: contentStorage,
            layoutManager: layoutManager,
            origin: origin
        )
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

    // MARK: - 6. Fast-Path Scanner, Code-Region & Diff Parity Tests

    func testScanHeadingsMatchesFullScanAcrossFrontmatterAndFences() {
        let md = """
        ---
        # Not a heading in frontmatter
        title: Spec
        ---

        # Title One
        Plain paragraph with #inline-tag and **bold**.
          ## Indented Two
        ```swift
        # Not a heading in backtick fence
        ```
        ~~~
        ## Not a heading in tilde fence
        ~~~
        ### Three
        #### Unclosed fence ahead
        ```
        # Still inside unclosed fence
        """
        let fullHeadings = KnowledgeMarkdownSyntax.scan(md).filter {
            if case .heading = $0.kind { return true }
            return false
        }
        let fastHeadings = KnowledgeMarkdownSyntax.scanHeadings(md)
        XCTAssertEqual(fastHeadings, fullHeadings)
    }

    func testIsInsideCodeOrFrontmatterMatchesFullScanAtEveryOffset() {
        let samples = [
            "---\ntitle: Demo\n---\n\n# Heading\nInline `code` here and [[link]].\n```swift\nlet x = 1\n```\nTail.\n",
            "Before\n```\nunclosed fence\n",
            "```\n",
            "No frontmatter\n---\nStill prose `tick` end",
            "Line 1\r\n```\r\ninside crlf\r\n```\r\nAfter\r\n",
        ]

        for md in samples {
            let tokens = KnowledgeMarkdownSyntax.scan(md)
            let len = (md as NSString).length
            for offset in 0...len {
                let expectedAll = tokens.contains { tok in
                    switch tok.kind {
                    case .fencedCodeBlock, .inlineCode, .frontmatter:
                        return offset > tok.range.location && offset < tok.range.location + tok.range.length
                    default:
                        return false
                    }
                }
                let expectedBlockOnly = tokens.contains { tok in
                    switch tok.kind {
                    case .fencedCodeBlock, .frontmatter:
                        return offset > tok.range.location && offset < tok.range.location + tok.range.length
                    default:
                        return false
                    }
                }
                XCTAssertEqual(
                    KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: offset, in: md),
                    expectedAll,
                    "Mismatch for includeInlineCode=true at offset \(offset) in sample"
                )
                XCTAssertEqual(
                    KnowledgeMarkdownSyntax.isInsideFencedCodeOrFrontmatter(utf16Offset: offset, in: md),
                    expectedBlockOnly,
                    "Mismatch for includeInlineCode=false at offset \(offset) in sample"
                )
            }
        }
    }

    func testMinimalEditDeltaAndLineSpanCoverExactChangedLines() {
        XCTAssertNil(KnowledgeMarkdownSyntax.minimalEditDelta(from: "same", to: "same"))

        let old = "First line\nSecond line\nThird line"
        let inserted = "First line\nSecond X line\nThird line"
        let delta = try! XCTUnwrap(KnowledgeMarkdownSyntax.minimalEditDelta(from: old, to: inserted))
        let oldNS = old as NSString
        let newNS = inserted as NSString
        let applied = oldNS.replacingCharacters(in: delta.oldRange, with: newNS.substring(with: delta.newRange))
        XCTAssertEqual(applied, inserted)
        XCTAssertEqual(delta.oldRange.length, 0)
        XCTAssertEqual(delta.newRange.length, 2)

        let span = KnowledgeMarkdownSyntax.lineSpan(covering: delta.newRange, in: inserted)
        XCTAssertEqual(newNS.substring(with: span), "Second X line\n")

        // Pre-matched trigger update on KnowledgeCompletionSession matches text-based update.
        let text = "Check [[Wat"
        let caret = (text as NSString).length
        let candidate = KnowledgeCompletionCandidate(kind: .page, title: "Watchtower", insertRef: "Watchtower")
        var sessionA = KnowledgeCompletionSession()
        sessionA.update(text: text, caretUTF16: caret, allCandidates: [candidate])
        var sessionB = KnowledgeCompletionSession()
        let trigger = KnowledgeCompletionLogic.matchTrigger(in: text, caretUTF16: caret)
        sessionB.update(trigger: trigger, allCandidates: [candidate])
        XCTAssertEqual(sessionA, sessionB)
        XCTAssertTrue(sessionB.isOpen)
    }
}
