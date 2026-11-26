import AppKit
import Foundation
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("KnowledgeTextView incremental styling and height cache")
struct KnowledgeTextViewTests {
    private func makeEditor(
        text: String,
        findMatches: [NSRange] = [],
        activeFind: NSRange? = nil
    ) -> (KnowledgeTextView.Coordinator, LivePreviewNSTextView) {
        let theme = ThemeTokens(mode: .light)
        let rep = KnowledgeTextView(
            text: text,
            theme: theme,
            findMatches: findMatches,
            activeFindMatchRange: activeFind,
            onTextChange: { _, _ in },
            onSelectionChange: { _, _ in },
            onOpenLink: { _ in },
            onCompletionKey: { _ in false }
        )
        let coordinator = rep.makeCoordinator()
        let view = LivePreviewNSTextView()
        view.delegate = coordinator
        view.string = text
        coordinator.applyStyling(to: view)
        return (coordinator, view)
    }

    private func freshFullStorage(
        text: String,
        selection: NSRange,
        isFocused: Bool,
        findMatches: [NSRange] = [],
        activeFind: NSRange? = nil
    ) -> NSAttributedString {
        let theme = ThemeTokens(mode: .light)
        let rep = KnowledgeTextView(
            text: text,
            theme: theme,
            findMatches: findMatches,
            activeFindMatchRange: activeFind,
            onTextChange: { _, _ in },
            onSelectionChange: { _, _ in },
            onOpenLink: { _ in },
            onCompletionKey: { _ in false }
        )
        let coordinator = rep.makeCoordinator()
        let view = LivePreviewNSTextView()
        view.string = text
        view.setSelectedRange(selection)
        if isFocused {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            win.contentView?.addSubview(view)
            _ = win.makeFirstResponder(view)
        }
        coordinator.applyStyling(to: view)
        return NSAttributedString(attributedString: view.textStorage!)
    }

    private func assertAttributesMatch(
        _ actual: NSAttributedString,
        _ expected: NSAttributedString,
        context: String
    ) {
        #expect(actual.string == expected.string, "Text mismatch at \(context)")
        let len = actual.length
        #expect(len == expected.length, "Length mismatch at \(context)")
        let keys: [NSAttributedString.Key] = [
            .font, .foregroundColor, .backgroundColor,
            .strikethroughStyle, .underlineStyle, .underlineColor, .paragraphStyle,
        ]
        for i in 0..<len {
            let a = actual.attributes(at: i, effectiveRange: nil)
            let b = expected.attributes(at: i, effectiveRange: nil)
            for key in keys {
                let va = a[key] as? NSObject
                let vb = b[key] as? NSObject
                #expect(va == vb, "Attribute \(key.rawValue) diverged at UTF-16 offset \(i) during \(context)")
                if va != vb { return }
            }
        }
    }

    @Test("incremental edits and selection moves match full-document styling attribute-for-attribute")
    func incrementalStylingMatchesFullStyling() {
        let initial = """
        ---
        title: Spec
        ---

        # Heading One

        Plain paragraph with **bold**, _italic_, ~~strike~~, `code`, [[Page|Alias]], #tag ^blk-1.

        ```swift
        let answer = 42
        ```

        Another plain paragraph for typing edits.
        Final line here.
        """

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let (coordinator, view) = makeEditor(text: initial)
        window.contentView?.addSubview(view)
        _ = window.makeFirstResponder(view)

        func verify(_ step: String) {
            let expected = freshFullStorage(
                text: view.string,
                selection: view.selectedRange(),
                isFocused: view.isFocusedEditor,
                findMatches: coordinator.parent.findMatches,
                activeFind: coordinator.parent.activeFindMatchRange
            )
            assertAttributesMatch(view.textStorage!, expected, context: step)
        }

        verify("initial focus")

        // 1. Caret moves within plain prose should skip NSTextStorage edits entirely.
        let plainRange = (view.string as NSString).range(of: "Another plain")
        view.setSelectedRange(NSRange(location: plainRange.location, length: 0))
        _ = coordinator.applyStyling(to: view)
        let skipsBefore = coordinator.skippedSelectionRestyleCount
        view.setSelectedRange(NSRange(location: plainRange.location + 3, length: 0))
        _ = coordinator.applyStyling(to: view)
        #expect(coordinator.skippedSelectionRestyleCount == skipsBefore + 1)
        #expect(coordinator.lastStyledRanges.isEmpty)
        verify("plain caret move")

        // 2. Typing in plain prose only restyles the single edited line, not the whole document.
        let incBefore = coordinator.incrementalRestyleCount
        let fullBefore = coordinator.fullRestyleCount
        view.replaceCharacters(in: NSRange(location: plainRange.location + 7, length: 0), with: " fast")
        view.setSelectedRange(NSRange(location: plainRange.location + 12, length: 0))
        _ = coordinator.applyStyling(to: view)
        #expect(coordinator.incrementalRestyleCount == incBefore + 1)
        #expect(coordinator.fullRestyleCount == fullBefore)
        #expect(coordinator.lastStyledRanges.count == 1)
        #expect((coordinator.lastStyledRanges.first?.length ?? Int.max) < (view.string as NSString).length / 2)
        verify("plain line insert")

        // 3. Moving caret into **bold** reveals delimiters, moving back hides them.
        let boldRange = (view.string as NSString).range(of: "**bold**")
        view.setSelectedRange(NSRange(location: boldRange.location + 3, length: 0))
        _ = coordinator.applyStyling(to: view)
        verify("reveal bold")

        view.setSelectedRange(NSRange(location: plainRange.location, length: 0))
        _ = coordinator.applyStyling(to: view)
        verify("hide bold again")

        // 4. Editing inside an existing fenced code block restyles incrementally.
        let codeRange = (view.string as NSString).range(of: "42")
        view.replaceCharacters(in: codeRange, with: "99")
        view.setSelectedRange(NSRange(location: codeRange.location + 2, length: 0))
        _ = coordinator.applyStyling(to: view)
        verify("edit inside code fence")

        // 5. Opening an unclosed fence converts trailing prose to code, then closing restores it.
        let anotherPos = (view.string as NSString).range(of: "Another").location
        view.replaceCharacters(in: NSRange(location: anotherPos, length: 0), with: "```\n")
        view.setSelectedRange(NSRange(location: anotherPos + 4, length: 0))
        _ = coordinator.applyStyling(to: view)
        verify("open unclosed fence")

        let finalPos = (view.string as NSString).range(of: "Final").location
        view.replaceCharacters(in: NSRange(location: finalPos, length: 0), with: "```\n")
        view.setSelectedRange(NSRange(location: finalPos + 4, length: 0))
        _ = coordinator.applyStyling(to: view)
        verify("close fence")

        // 6. Smart edit uses minimal replacement and keeps attributes accurate.
        let endLoc = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: endLoc, length: 0))
        view.applySmartEdit(KnowledgeMarkdownFormatting.EditResult(
            text: view.string + "\n- [ ] Task",
            selection: NSRange(location: endLoc + 11, length: 0)
        ))
        _ = coordinator.applyStyling(to: view)
        verify("smart edit append checklist")

        // 7. Find match overlay + active match switching restyles affected lines accurately.
        let m1 = (view.string as NSString).range(of: "Heading")
        let m2 = (view.string as NSString).range(of: "Final")
        coordinator.parent.findMatches = [m1, m2]
        coordinator.parent.activeFindMatchRange = m1
        _ = coordinator.applyStyling(to: view)
        verify("find matches active 1")

        coordinator.parent.activeFindMatchRange = m2
        _ = coordinator.applyStyling(to: view)
        verify("find matches active 2")

        coordinator.parent.findMatches = []
        coordinator.parent.activeFindMatchRange = nil
        _ = coordinator.applyStyling(to: view)
        verify("clear find matches")
    }

    @Test("fittingHeight caches layout per width and invalidates on width or text change")
    func fittingHeightCacheBehavior() {
        let lines = (0..<40).map { "Paragraph \($0) with some text to wrap cleanly across lines." }.joined(separator: "\n\n")
        let (coordinator, view) = makeEditor(text: lines)

        let h1 = view.fittingHeight(width: 600)
        let h2 = view.fittingHeight(width: 600)
        let h3 = view.fittingHeight(width: 600.2)
        #expect(h1 > 200)
        #expect(h1 == h2)
        #expect(h1 == h3)
        #expect(view.layoutMeasurementCount == 1)

        // Changing width invalidates cache and re-measures once.
        let hNarrow = view.fittingHeight(width: 320)
        #expect(hNarrow > h1)
        #expect(view.layoutMeasurementCount == 2)
        _ = view.fittingHeight(width: 320)
        #expect(view.layoutMeasurementCount == 2)

        // Editing text invalidates cache on restyle.
        view.replaceCharacters(in: NSRange(location: 0, length: 0), with: "New line\n\n")
        _ = coordinator.applyStyling(to: view)
        let hAfterEdit = view.fittingHeight(width: 320)
        #expect(hAfterEdit > hNarrow)
        #expect(view.layoutMeasurementCount == 3)
    }
}
