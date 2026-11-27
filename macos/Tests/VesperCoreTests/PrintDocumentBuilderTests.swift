import AppKit
import Foundation
import PDFKit
import Testing
@testable import VesperCore

@Suite("PrintDocumentBuilder")
struct PrintDocumentBuilderTests {

    @Test func stripDuplicateLeadingHeadingMatchesIgnoringCaseAndTrailingHashes() {
        let md = "\n# Project Plan ##\n\nBody text here."
        #expect(PrintDocumentBuilder.stripDuplicateLeadingHeading(md, title: "project plan") == "Body text here.")
        #expect(PrintDocumentBuilder.stripDuplicateLeadingHeading("# Different\n\nBody", title: "Project Plan") == "# Different\n\nBody")
        #expect(PrintDocumentBuilder.stripDuplicateLeadingHeading("## Project Plan\n\nBody", title: "Project Plan") == "## Project Plan\n\nBody")
    }

    @Test func embedFallbackLabelStripsLibraryUUIDPrefix() {
        #expect(PrintDocumentBuilder.embedFallbackLabel("![[library:11111111-2222-4333-8444-555555555555/Harbour map]]") == "Harbour map")
        #expect(PrintDocumentBuilder.embedFallbackLabel("![[library:Harbour map]]") == "Harbour map")
    }

    @Test func stripObsidianBlockIdsSkipsCodeBlocksAndInlineCode() {
        let md = """
        Regular paragraph ^abc-123
        Keep `inline ^keep-1` literal ^drop-2
        ```
        fenced ^keep-3
        ```
        """
        let got = PrintDocumentBuilder.stripObsidianBlockIds(md)
        #expect(got.contains("Regular paragraph"))
        #expect(!got.contains("^abc-123"))
        #expect(got.contains("`inline ^keep-1`"))
        #expect(!got.contains("^drop-2"))
        #expect(got.contains("fenced ^keep-3"))
    }

    @Test func prepareKnowledgePrintExtractsCalloutsAndEmbeds() {
        let body = """
        # Architecture

        Intro line with ![[attachment:abc/diagram.png]].

        > [!warning] Heads up
        > Watch out for `> [!note]` inside code.

        ![[Notes/Subpage]]
        """
        let embeds = [
            KnowledgeEmbed(ref: "![[attachment:abc/diagram.png]]", kind: "image", title: "Diagram", url: "/api/v1/files/diagram.png", contentType: "image/png", available: true),
            KnowledgeEmbed(ref: "![[Notes/Subpage]]", kind: "page", title: "Subpage", markdown: "Nested paragraph", available: true),
        ]
        let segments = PrintDocumentBuilder.prepareKnowledgePrint(body: body, title: "Architecture", embeds: embeds)
        #expect(segments.count == 3)
        if case .markdown(let first) = segments[0] {
            #expect(first.contains("![Diagram](/api/v1/files/diagram.png)"))
        } else {
            Issue.record("expected markdown segment first")
        }
        if case .callout(_, let tone, let title, let calloutBody) = segments[1] {
            #expect(tone == .warning)
            #expect(title == "Heads up")
            #expect(calloutBody.contains("Watch out"))
        } else {
            Issue.record("expected callout segment second")
        }
        if case .embed(_, let fallback, let embed) = segments[2] {
            #expect(fallback == "Subpage")
            #expect(embed?.title == "Subpage")
        } else {
            Issue.record("expected embed segment third")
        }
    }

    // MARK: Knowledge documents

    static let page = KnowledgePage(
        id: "p1",
        title: "Q4 Review",
        path: "Work/Plans/Q4 Review",
        audience: .private,
        kind: .document,
        bodyMd: """
        # Q4 Review

        Intro.

        > [!tip]
        > Ship it.

        ![[attachment:a/chart.png]]

        ![[Notes/Sub]]

        ![[spec.pdf]]

        ![[Gone]]
        """,
        properties: ["tags": .array([.string("release"), .string("q4")]), "owner": .string("[[People/Judy]]"), "_hidden": .string("x"), "zettel_id": .string("z")],
        embeds: [
            KnowledgeEmbed(ref: "![[attachment:a/chart.png]]", kind: "image", title: "Chart", url: "/api/v1/files/chart.png", contentType: "image/png", available: true),
            KnowledgeEmbed(ref: "![[Notes/Sub]]", kind: "page", title: "Sub", markdown: "", available: true),
            KnowledgeEmbed(ref: "![[spec.pdf]]", kind: "attachment", title: "Spec", url: "/api/v1/files/spec.pdf", contentType: "application/pdf", available: true),
            KnowledgeEmbed(ref: "![[Gone]]", kind: "page", available: false),
        ]
    )

    @Test func knowledgeDocumentOrdersHeaderQueryAndBodySegments() {
        let query = KnowledgePageTable(rows: [
            KnowledgePageRow(id: "r1", title: "Alpha", path: "A", audience: .shared, properties: ["status": .string("done"), "tags": .array([.string("a"), .string("b"), .string("c"), .string("d")])]),
            KnowledgePageRow(id: "r2", title: "Beta", path: "B", properties: ["status": .string(""), "owner": .string("Liam")]),
        ], hasMore: true)
        let doc = PrintDocumentBuilder.knowledgeDocument(page: Self.page, style: .technical, showMetadata: true, savedQuery: query)

        #expect(doc.title == "Q4 Review")
        #expect(doc.style == .technical)
        #expect(doc.header.folder == "Work / Plans")
        #expect(doc.header.title == "Q4 Review")
        // Hidden and underscore keys are dropped; the rest sort by key; wiki links print as their name.
        #expect(doc.header.properties == [
            PrintProperty(key: "owner", value: .text("Judy")),
            PrintProperty(key: "tags", value: .tags(["release", "q4"])),
        ])

        #expect(doc.query == PrintQueryTable(
            columns: ["Name", "status", "owner", "Tags", "Audience"],
            rows: [["Alpha", "done", "—", "#a #b #c", "Shared"], ["Beta", "—", "Liam", "", "Private"]],
            footnote: "Showing the first 2 pages."
        ))

        // The duplicate title heading is gone; each embed keeps its place in the body.
        #expect(doc.body.count == 6)
        guard doc.body.count == 6 else { return }
        #expect(doc.body[0] == .markdown(MarkdownParser.parse("Intro.")))
        #expect(doc.body[1] == .callout(tone: .tip, title: "Tip", body: MarkdownParser.parse("Ship it.")))
        #expect(doc.body[2] == .image(url: "/api/v1/files/chart.png", alt: "Chart"))
        #expect(doc.body[3] == .page(caption: "Sub", body: [.notice("Empty page")]))
        #expect(doc.body[4] == .reference(kind: "PDF", name: "Spec"))
        #expect(doc.body[5] == .notice("Embedded reference unavailable: Gone"))
    }

    @Test func knowledgeDocumentLeavesMetadataOutUnlessAsked() {
        let doc = PrintDocumentBuilder.knowledgeDocument(page: Self.page, style: .clean, savedQuery: KnowledgePageTable(rows: []))
        #expect(doc.header.folder == nil)
        #expect(doc.header.properties.isEmpty)
        // An empty saved query prints nothing.
        #expect(doc.query == nil)
    }

    @Test func imageURLsCollectsEmbedsAndInlineImagesOnce() {
        let doc = PrintDocument(title: "T", style: .clean, header: PrintHeader(title: "T"), body: [
            .markdown(MarkdownParser.parse("![a](/api/v1/files/one.png) ![b](file:///etc/passwd) ![c](https://x.test/two.png)")),
            .image(url: "/api/v1/files/one.png", alt: "again"),
            .page(caption: nil, body: [.callout(tone: .note, title: "N", body: MarkdownParser.parse("![d](/api/v1/files/three.png)"))]),
        ])
        #expect(doc.imageURLs == ["/api/v1/files/one.png", "https://x.test/two.png", "/api/v1/files/three.png"])
    }

    // MARK: Artifacts

    @Test func artifactDocumentUsesTheBodysOwnTitleHeading() {
        let own = PrintDocumentBuilder.artifactDocument(
            title: "Design Spec", versionLabel: "v2", authorName: "Judy", createdAt: "2026-11-25",
            summary: "  Final spec \n", bodyMarkdown: "# Design Spec\n\nHello **world**"
        )
        #expect(own.title == "Design Spec")
        #expect(own.style == .clean)
        #expect(own.header == PrintHeader(title: nil, metaLine: "v2 · Judy · 2026-11-25", summary: "Final spec"))
        #expect(own.body == [.markdown(MarkdownParser.parse("# Design Spec\n\nHello **world**"))])

        let plain = PrintDocumentBuilder.artifactDocument(title: " ", versionLabel: "", authorName: "", createdAt: "", summary: "", bodyMarkdown: "Body")
        #expect(plain.header == PrintHeader(title: "Untitled"))
    }

    @Test func printRoutesResolveNatively() {
        let reg = NativeRouteRegistry.standard(debug: false)
        #expect(reg.resolve("/print/knowledge/p1?style=editorial")?.screen == .printKnowledge)
        #expect(reg.resolve("/print/artifacts/a1?version=v2")?.screen == .printArtifact)
    }
}

@Suite("PrintRenderer")
@MainActor
struct PrintRendererTests {

    static let markdown = """
    Some **bold** text, `inline code` and [a link](https://example.com).

    - [x] Done
    - [ ] Open

    ```swift
    let x = 1
    ```

    | Col | Num |
    | --- | --: |
    | Val | 42 |

    $$
    E = mc^2
    $$
    """

    @Test func rendersBoxesTablesAndMathForPaper() throws {
        let doc = PrintDocumentBuilder.artifactDocument(title: "Spec", versionLabel: "v1", authorName: "", createdAt: "", summary: "", bodyMarkdown: Self.markdown)
        let text = PrintRenderer.render(doc, width: 468)
        let string = text.string
        #expect(string.hasPrefix("Spec\nv1\n"))
        #expect(string.contains("bold"))
        #expect(string.contains("\u{2611}"))
        #expect(string.contains("\u{2610}"))
        #expect(!string.hasSuffix("\n"))

        func attributes(of needle: String) throws -> [NSAttributedString.Key: Any] {
            let range = (string as NSString).range(of: needle)
            try #require(range.location != NSNotFound, "\(needle) not rendered")
            return text.attributes(at: range.location, effectiveRange: nil)
        }
        // Code sits in a shaded box in a monospaced font.
        let code = try attributes(of: "let x = 1")
        let codeBlocks = (code[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks.first?.backgroundColor != nil)
        #expect((code[.font] as? NSFont)?.isFixedPitch == true)
        // Table cells are real table cells, right-aligned where the markdown said so.
        let cell = try attributes(of: "42")
        let cellStyle = try #require(cell[.paragraphStyle] as? NSParagraphStyle)
        #expect(cellStyle.textBlocks.last is NSTextTableBlock)
        #expect(cellStyle.alignment == .right)
        // Links stay clickable; display math is drawn, not left as TeX.
        #expect((try attributes(of: "a link"))[.link] as? URL == URL(string: "https://example.com"))
        #expect(!string.contains("mc^2"))
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        #expect(attachments == 1)
    }

    @Test func paginatesWithRunningTitleAndPageNumbers() throws {
        let long = (1...120).map { "Paragraph \($0) of a long printout that has to run onto more than one sheet of paper." }.joined(separator: "\n\n")
        let doc = PrintDocumentBuilder.artifactDocument(title: "Long Doc", versionLabel: "", authorName: "", createdAt: "", summary: "", bodyMarkdown: long + "\n\n" + Self.markdown)
        let info = PrintRenderer.printInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        let width = PrintRenderer.printableWidth(info)
        let view = PrintTextView(text: PrintRenderer.render(doc, width: width), title: doc.title, width: width)
        let pdf = try Self.printToPDF(view, info: info)

        #expect(pdf.pageCount > 2)
        let pages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
        #expect(pages.allSatisfy { $0.contains("Long Doc") })
        #expect(pages[1].contains("Page 2 of \(pdf.pageCount)"))
        // Every paragraph prints, none cut between pages.
        let all = pages.joined(separator: "\n")
        #expect((1...120).allSatisfy { all.contains("Paragraph \($0) of") })
    }

    @Test func rendersKnowledgePagesInEveryStyle() {
        var doc = PrintDocumentBuilder.knowledgeDocument(page: PrintDocumentBuilderTests.page, style: .clean, showMetadata: true, savedQuery: nil)
        doc.body.append(.markdown(MarkdownParser.parse("## Heading\n\n> quoted line\n\n1. one\n2. two\n")))
        for style in KnowledgePrintStyle.allCases {
            doc.style = style
            let string = PrintRenderer.render(doc, width: 468).string
            // The folder kicker may come first; the title must still lead the body.
            let title = string.range(of: doc.title), quote = string.range(of: "quoted line")
            #expect(title != nil && quote != nil && title!.lowerBound < quote!.lowerBound, "\(style)")
            #expect(string.contains("two"), "\(style)")
        }
    }

    /// Prints through the same `NSPrintOperation(view:printInfo:)` the dialog runs, saved to a file
    /// instead of a printer, so the pagination is the real one.
    static func printToPDF(_ view: NSView, info: NSPrintInfo) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        #expect(op.run())
        return try #require(PDFDocument(url: url))
    }
}
