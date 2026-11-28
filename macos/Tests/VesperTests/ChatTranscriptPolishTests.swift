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
}
