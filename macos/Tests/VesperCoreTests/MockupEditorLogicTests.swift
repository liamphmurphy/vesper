import Foundation
import Testing
@testable import VesperCore

@Suite("MockupEditorLogic")
struct MockupEditorLogicTests {

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
}
