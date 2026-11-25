import Foundation
import Testing
@testable import VesperCore

@Suite("MockupEditorLogic")
struct MockupEditorLogicTests {

    @Test func svgValidationRejectsEmptyBrokenAndNonSvgRoot() {
        #expect(MockupEditorLogic.svgValidationError("   ") == "The SVG is empty.")
        #expect(MockupEditorLogic.svgValidationError("<svg><rect></svg>") != nil)
        #expect(MockupEditorLogic.svgValidationError("<div>hello</div>") == "The root element must be <svg>.")
        #expect(MockupEditorLogic.svgValidationError("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>") == nil)
    }

    @Test func sourceHistoryUndoRedoAndCoalescing() {
        var h = MockupEditorLogic.SourceHistory(initial: "<svg/>")
        #expect(!h.canUndo && !h.canRedo)

        h.commit("<svg><rect/></svg>", key: "attr:0:x")
        h.commit("<svg><rect x=\"10\"/></svg>", key: "attr:0:x")
        #expect(h.current == "<svg><rect x=\"10\"/></svg>")

        // Same key coalesced into a single undo step back to initial.
        #expect(h.undo() == "<svg/>")
        #expect(!h.canUndo && h.canRedo)

        #expect(h.redo() == "<svg><rect x=\"10\"/></svg>")
        h.breakCoalesce()
        h.commit("<svg><rect x=\"20\"/></svg>", key: "attr:0:x")
        #expect(h.undo() == "<svg><rect x=\"10\"/></svg>")
    }

    @Test func visualCanvasHTMLIncludesStrictCSPAndDarkTheme() {
        let html = MockupEditorLogic.visualCanvasHTML(dark: true)
        #expect(html.contains("data-theme=\"dark\""))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("window.webkit.messageHandlers.vesperMockup"))
    }
}
