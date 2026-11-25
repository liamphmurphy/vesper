import Foundation
import Testing
@testable import VesperCore

@Suite("PrintHTMLBuilder")
struct PrintHTMLBuilderTests {

    @Test func stripDuplicateLeadingHeadingMatchesIgnoringCaseAndTrailingHashes() {
        let md = "\n# Project Plan ##\n\nBody text here."
        #expect(PrintHTMLBuilder.stripDuplicateLeadingHeading(md, title: "project plan") == "Body text here.")
        #expect(PrintHTMLBuilder.stripDuplicateLeadingHeading("# Different\n\nBody", title: "Project Plan") == "# Different\n\nBody")
        #expect(PrintHTMLBuilder.stripDuplicateLeadingHeading("## Project Plan\n\nBody", title: "Project Plan") == "## Project Plan\n\nBody")
    }

    @Test func stripObsidianBlockIdsSkipsCodeBlocksAndInlineCode() {
        let md = """
        Regular paragraph ^abc-123
        Keep `inline ^keep-1` literal ^drop-2
        ```
        fenced ^keep-3
        ```
        """
        let got = PrintHTMLBuilder.stripObsidianBlockIds(md)
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
        let segments = PrintHTMLBuilder.prepareKnowledgePrint(body: body, title: "Architecture", embeds: embeds)
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

    @Test func buildKnowledgePrintHTMLRendersStylesEscapesAndMetadata() {
        let page = KnowledgePage(
            id: "p1",
            title: "Q4 <Review>",
            path: "Work/Q4 <Review>",
            audience: .private,
            kind: .document,
            bodyMd: "# Q4 <Review>\n\n- [x] Ship native print\n\n| Col |\n| --- |\n| Val |",
            properties: ["tags": .array([.string("release")]), "owner": .string("[[People/Judy]]")]
        )
        let html = PrintHTMLBuilder.buildKnowledgePrintHTML(page: page, style: .editorial, showMetadata: true, darkScreen: false)
        #expect(html.contains("data-print-style=\"editorial\""))
        #expect(html.contains("Q4 &lt;Review&gt;"))
        #expect(html.contains("#release"))
        #expect(html.contains("Judy"))
        #expect(html.contains("&#9745;"))
        #expect(html.contains("<table>"))
    }

    @Test func buildArtifactPrintHTMLRendersHeaderAndProse() {
        let html = PrintHTMLBuilder.buildArtifactPrintHTML(
            title: "Design Spec",
            versionLabel: "v2",
            authorName: "Judy",
            createdAt: "2026-11-25",
            summary: "Final spec",
            bodyMarkdown: "Hello **world**",
            darkScreen: true
        )
        #expect(html.contains("data-theme=\"dark\""))
        #expect(html.contains("Design Spec"))
        #expect(html.contains("v2 · Judy · 2026-11-25"))
        #expect(html.contains("<strong>world</strong>"))
    }

    @Test func printRoutesResolveNatively() {
        let reg = NativeRouteRegistry.standard(debug: false)
        #expect(reg.resolve("/print/knowledge/p1?style=editorial")?.screen == .printKnowledge)
        #expect(reg.resolve("/print/artifacts/a1?version=v2")?.screen == .printArtifact)
    }
}
