import XCTest
@testable import VesperCore

final class KnowledgePrintLogicTests: XCTestCase {
    func testMenuOffersEveryPaperStyleThenAskAPersona() {
        let item = KnowledgePrintLogic.menuItem()
        XCTAssertEqual(item.label, "Print or save as PDF")
        let children = item.children ?? []
        XCTAssertEqual(children.compactMap(\.label), ["Clean", "Editorial", "Compact", "Technical", "Ask a Persona\u{2026}"])
        XCTAssertEqual(children.last?.id, KnowledgePrintLogic.askPersonaItemId)
        XCTAssertTrue(children.contains { $0.separator == true })
    }

    func testStyleRoundTripsThroughItsMenuItemId() {
        for style in KnowledgePrintStyle.allCases {
            XCTAssertEqual(KnowledgePrintLogic.style(fromMenuItemId: KnowledgePrintLogic.styleItemId(style)), style)
        }
        XCTAssertNil(KnowledgePrintLogic.style(fromMenuItemId: KnowledgePrintLogic.askPersonaItemId))
        XCTAssertNil(KnowledgePrintLogic.style(fromMenuItemId: "page.print.style:glossy"))
        XCTAssertNil(KnowledgePrintLogic.style(fromMenuItemId: "page.delete"))
    }

    func testPrintPathMatchesTheWebPrintRoute() {
        XCTAssertEqual(
            KnowledgePrintLogic.printPath(pageId: "01a1-page", style: .editorial),
            "/print/knowledge/01a1-page?style=editorial"
        )
        XCTAssertEqual(
            KnowledgePrintLogic.printPath(pageId: "a/b c", style: .clean),
            "/print/knowledge/a%2Fb%20c?style=clean"
        )
    }

    func testPersonaPromptLinksThePageByPathThenTitle() {
        XCTAssertEqual(
            KnowledgePrintLogic.personaPdfPrompt(path: " Notes/Plan ", title: "Plan"),
            "Export [[Notes/Plan]] as a polished, print-ready PDF using render_pdf. "
        )
        XCTAssertEqual(
            KnowledgePrintLogic.personaPdfPrompt(path: "", title: "Plan"),
            "Export [[Plan]] as a polished, print-ready PDF using render_pdf. "
        )
        XCTAssertEqual(
            KnowledgePrintLogic.personaPdfPrompt(path: nil, title: "  "),
            "Export [[Untitled]] as a polished, print-ready PDF using render_pdf. "
        )
    }

    func testPrefillFillsAnEmptyDraftKeepsARepeatAndAppendsOtherwise() {
        let prompt = "Export [[Plan]] as a PDF. "
        XCTAssertEqual(ChatComposerPrefill.merge(prompt, into: ""), prompt)
        XCTAssertEqual(ChatComposerPrefill.merge(prompt, into: "  \n"), prompt)
        XCTAssertEqual(ChatComposerPrefill.merge(prompt, into: "hi \(prompt)"), "hi \(prompt)")
        XCTAssertEqual(ChatComposerPrefill.merge(prompt, into: "Use serif."), "Use serif.\n\n\(prompt)")
    }
}
