import Foundation
import Testing
@testable import VesperCore

struct DocEditorLogicTests {
    @Test func reviewBasePicksNewerOfUserEditAndReviewedSeq() {
        let versions = [
            API.ChatCanvasVersion(authorType: .agent, createdAt: "", note: "Init", seq: 1),
            API.ChatCanvasVersion(authorType: .user, createdAt: "", note: "Edit", seq: 3),
            API.ChatCanvasVersion(authorType: .agent, createdAt: "", note: "Polish", seq: 5),
        ]
        #expect(DocEditorLogic.reviewBase(versions: versions, reviewedSeq: 0) == 3)
        #expect(DocEditorLogic.reviewBase(versions: versions, reviewedSeq: 4) == 4)
        #expect(DocEditorLogic.reviewBase(versions: versions, reviewedSeq: 5) == 5)
    }

    @Test func reviewSegmentsAndResolutionKeepOrRevertChanges() {
        let base = "# Title\n\nFirst paragraph.\n\nSecond paragraph."
        let head = "# Title\n\nRewritten first.\n\nSecond paragraph.\n\nAdded closing."
        let segs = DocEditorLogic.reviewSegments(base: base, head: head)
        let changes = segs.compactMap { seg -> Int? in
            if case .change(let id, _, _) = seg { return id }
            return nil
        }
        #expect(changes.count == 2)

        let partial = DocEditorLogic.resolveReview(segments: segs, decisions: [0: .reject, 1: .accept])
        #expect(partial.contains("First paragraph."))
        #expect(!partial.contains("Rewritten first."))
        #expect(partial.contains("Added closing."))

        let note = DocEditorLogic.reviewNote(segments: segs, decisions: [0: .reject, 1: .accept], persona: "Judy")
        #expect(note == "Kept 1 of Judy's 2 changes, rejected 1")
    }

    @Test func outlineExtractsHeadingsWithLevels() {
        let md = "# Intro\n\nBody text\n\n## **Details** [link](https://example.com)\n\n### Deep"
        let outline = DocEditorLogic.outlineOf(md)
        #expect(outline.count == 3)
        #expect(outline[0].level == 1 && outline[0].text == "Intro")
        #expect(outline[1].level == 2 && outline[1].text == "Details link")
        #expect(outline[2].level == 3 && outline[2].text == "Deep")
    }

    @Test func locateQuoteSkipsInlineMarkdownSyntax() {
        let md = "Hello **bold world** and *italic* text."
        let range = DocEditorLogic.locateQuote(in: md, quote: "bold world and italic")
        #expect(range != nil)
        if let range {
            let sub = (md as NSString).substring(with: NSRange(location: range.start, length: range.end - range.start))
            #expect(sub.contains("bold world"))
            #expect(sub.contains("italic"))
        }
    }

    @Test func detectPersonaMentionOnStandaloneLine() {
        let md = "Opening paragraph.\n@Judy tighten this section"
        let mention = DocEditorLogic.detectPersonaMention(in: md, cursorUTF16: (md as NSString).length, personaName: "Judy Alvarez")
        #expect(mention?.instruction == "tighten this section")
        #expect(mention?.afterContext == "Opening paragraph.")
    }

    @Test func docxExportProducesValidZipWithWordEntries() {
        let md = """
        # Quarterly Plan

        Summary with **bold**, *italic*, `code`, and [link](https://example.com).

        - First item
        - [x] Done task

        | Metric | Value |
        | --- | --- |
        | Latency | 12ms |
        """
        let data = DocEditorLogic.exportDocx(markdown: md, title: "Quarterly Plan")
        #expect(data.count > 200)
        // ZIP local file header magic bytes PK\x03\x04
        #expect(data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04)
        // Archive bytes contain expected OpenXML part names in headers/central directory
        let ascii = String(decoding: data, as: UTF8.self)
        #expect(ascii.contains("[Content_Types].xml"))
        #expect(ascii.contains("word/document.xml"))
        #expect(ascii.contains("word/styles.xml"))
        #expect(ascii.contains("word/numbering.xml"))
    }

    @Test func docRouteResolvesToNativeDocEditor() {
        let reg = NativeRouteRegistry.standard(debug: false)
        let match = reg.resolve("/apps/docs/01abc-doc")
        #expect(match?.screen == .docEditor)
        #expect(match?.params["id"] == "01abc-doc")
        // Index route still redirects to Knowledge
        #expect(reg.resolve("/apps/docs")?.screen == .appsRedirect)
    }
}
