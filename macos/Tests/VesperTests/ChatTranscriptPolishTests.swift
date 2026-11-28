import AppKit
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("ChatTranscriptPolish")
struct ChatTranscriptPolishTests {
    @Test("inline code uses rounded pill attribute instead of raw selection background color")
    func inlineCodeUsesPillAttributeAndDrawsInsideBulletIndent() throws {
        let theme = ThemeTokens(mode: .dark)
        let doc = MarkdownParser.parse("- Update `ActivitySceneView.swift` and `origin/main`.", chat: true)
        let rendering = MarkdownRenderer.render(doc, theme: theme, options: MarkdownRenderOptions(textStyle: .chat))

        let ns = rendering.text.string as NSString
        let range = ns.range(of: "ActivitySceneView.swift")
        #expect(range.location != NSNotFound)

        // Must carry MarkdownInlineCodeStyle and NOT raw .backgroundColor (which looked like selection blue).
        let style = rendering.text.attribute(.markdownInlineCode, at: range.location, effectiveRange: nil) as? MarkdownInlineCodeStyle
        #expect(style != nil)
        #expect(rendering.text.attribute(.backgroundColor, at: range.location, effectiveRange: nil) == nil)

        // Verify TextKit 2 creates a MarkdownLayoutFragment and computes positive, in-bounds pill rects.
        let view = MarkdownTextView()
        view.show(rendering)
        _ = view.fittingHeight(width: 560)

        var pillRects: [CGRect] = []
        view.textLayoutManager?.enumerateTextLayoutFragments(
            from: view.textLayoutManager!.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let md = fragment as? MarkdownLayoutFragment {
                pillRects.append(contentsOf: md.inlineCodePillSpecs(at: .zero).map(\.rect))
            }
            return true
        }
        #expect(pillRects.count == 2)
        for rect in pillRects {
            #expect(rect.width > 20)
            #expect(rect.height > 10)
            #expect(rect.minX >= 0)
            #expect(rect.maxX <= 565)
        }
        // Second pill sits cleanly to the right of the first on this 560pt line.
        #expect(pillRects[1].minX > pillRects[0].maxX)
    }

    @Test("short user messages hug intrinsic width instead of stretching to maxWidth")
    func shortUserMessageHugsWidth() {
        let theme = ThemeTokens(mode: .dark)
        let shortDoc = MarkdownParser.parse("Yes, it's merged so a new PR please.", chat: true)
        let shortRendering = MarkdownRenderer.render(shortDoc, theme: theme, options: MarkdownRenderOptions(textStyle: .chat))

        let view = MarkdownTextView()
        view.show(shortRendering)
        let hugged = view.fittingSize(maxWidth: 640)
        #expect(hugged.width > 120)
        #expect(hugged.width < 380)
        #expect(hugged.height > 14)

        let longDoc = MarkdownParser.parse(
            "This is a deliberately long user message that should wrap across multiple lines and expand close to the 640pt maximum bubble width so multi-line prompts still use the full reading column comfortably.",
            chat: true
        )
        let longRendering = MarkdownRenderer.render(longDoc, theme: theme, options: MarkdownRenderOptions(textStyle: .chat))
        view.show(longRendering)
        let wrapped = view.fittingSize(maxWidth: 640)
        #expect(wrapped.width > 500)
        #expect(wrapped.width <= 640)
        #expect(wrapped.height > hugged.height)
    }

    @Test("width changes on prose and code-block messages reuse rendered text and adjust code-header tab stops in place")
    func proseAndCodeResizeAvoidFullRerender() throws {
        let theme = ThemeTokens(mode: .dark)
        let options = MarkdownRenderOptions(textStyle: .chat, codeBlocks: true)

        // Prose + inline code should render exactly once across an entire split-view resize sweep.
        let proseDoc = MarkdownParser.parse("Here is a reply referencing `MarkdownView.swift` and `ChatScreen.swift`.", chat: true)
        let proseView = MarkdownTextView()
        let proseCoordinator = MarkdownRenderCoordinator()
        proseCoordinator.latest = (proseDoc, theme, options)
        for width: CGFloat in stride(from: 860, through: 500, by: -20) {
            proseCoordinator.render(proseView, width: width)
        }
        #expect(proseCoordinator.fullRenderCount == 1)

        // Code-block message also avoids full rebuilds while keeping the header "Copy" tab stop aligned to width - 12.
        let codeDoc = MarkdownParser.parse("```swift\nlet answer = 42\n```", chat: true)
        let codeView = MarkdownTextView()
        let codeCoordinator = MarkdownRenderCoordinator()
        codeCoordinator.latest = (codeDoc, theme, options)
        for width: CGFloat in stride(from: 860, through: 500, by: -20) {
            codeCoordinator.render(codeView, width: width)
        }
        #expect(codeCoordinator.fullRenderCount == 1)
        let headerStyle = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(headerStyle.tabStops.first?.location == 488)

        // Tables genuinely depend on width and still re-render when container width changes.
        let tableDoc = MarkdownParser.parse("| Col A | Col B |\n| --- | --- |\n| one | two |", chat: true)
        let tableView = MarkdownTextView()
        let tableCoordinator = MarkdownRenderCoordinator()
        tableCoordinator.latest = (tableDoc, theme, options)
        tableCoordinator.render(tableView, width: 800)
        tableCoordinator.render(tableView, width: 520)
        #expect(tableCoordinator.fullRenderCount == 2)
    }

    @Test("hugWidth double probes and single-line resizes reuse cached TextKit layout without thrashing")
    func hugWidthAndSingleLineReuseLayoutCache() {
        let theme = ThemeTokens(mode: .dark)
        let shortDoc = MarkdownParser.parse("Sounds great, ship it!", chat: true)
        let rendering = MarkdownRenderer.render(shortDoc, theme: theme, options: MarkdownRenderOptions(textStyle: .chat))

        let view = MarkdownTextView()
        view.show(rendering)
        let atMax = view.fittingSize(maxWidth: 640)
        let atHugged = view.fittingSize(maxWidth: atMax.width)
        let atMid = view.fittingSize(maxWidth: 480)
        let backAtMax = view.fittingSize(maxWidth: 640)
        #expect(atHugged == atMax)
        #expect(atMid == atMax)
        #expect(backAtMax == atMax)
        #expect(view.layoutPassCount == 1)

        // Shrinking narrower than natural width forces a single fresh layout that wraps cleanly.
        let narrowed = view.fittingSize(maxWidth: 90)
        #expect(view.layoutPassCount == 2)
        #expect(narrowed.height > atMax.height)

        // Single-line full-width assistant messages also skip TextKit layout across wider resize widths.
        let replyView = MarkdownTextView()
        replyView.show(rendering)
        let h1 = replyView.fittingHeight(width: 860)
        let h2 = replyView.fittingHeight(width: 720)
        let h3 = replyView.fittingHeight(width: 560)
        #expect(h1 == h2)
        #expect(h2 == h3)
        #expect(replyView.layoutPassCount == 1)
    }

    @Test("inline code pill geometry caches across repeated draws and skips code-fence fragments")
    func inlineCodePillGeometryCachesPerFragmentLayout() throws {
        let theme = ThemeTokens(mode: .dark)
        let doc = MarkdownParser.parse(
            """
            Check `ActivitySceneView.swift` and `MarkdownTextView.swift`.

            ```swift
            let x = 1
            ```
            """,
            chat: true
        )
        let rendering = MarkdownRenderer.render(doc, theme: theme, options: MarkdownRenderOptions(textStyle: .chat, codeBlocks: true))
        let view = MarkdownTextView()
        view.show(rendering)
        _ = view.fittingHeight(width: 600)

        var inlineFragments: [MarkdownLayoutFragment] = []
        var fenceFragments: [MarkdownLayoutFragment] = []
        view.textLayoutManager?.enumerateTextLayoutFragments(
            from: view.textLayoutManager!.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let md = fragment as? MarkdownLayoutFragment {
                if md.hasInlineCode {
                    inlineFragments.append(md)
                } else {
                    fenceFragments.append(md)
                }
            }
            return true
        }

        let inlineFrag = try #require(inlineFragments.first)
        let first = inlineFrag.inlineCodePillSpecs(at: .zero)
        let second = inlineFrag.inlineCodePillSpecs(at: .zero)
        let shifted = inlineFrag.inlineCodePillSpecs(at: CGPoint(x: 10, y: 20))
        #expect(first.count == 2)
        #expect(second.count == 2)
        #expect(inlineFrag.inlineCodePillComputationCount == 1)
        #expect(shifted[0].rect.minX == first[0].rect.minX + 10)
        #expect(shifted[0].rect.minY == first[0].rect.minY + 20)

        inlineFrag.invalidateLayout()
        _ = inlineFrag.inlineCodePillSpecs(at: .zero)
        #expect(inlineFrag.inlineCodePillComputationCount == 2)

        #expect(!fenceFragments.isEmpty)
        for fence in fenceFragments {
            #expect(fence.inlineCodePillSpecs(at: .zero).isEmpty)
            #expect(fence.inlineCodePillComputationCount == 0)
        }
    }
}
