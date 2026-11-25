import XCTest
@testable import VesperCore

final class ChatSVGNativeTests: XCTestCase {
    private let steps = """
    <svg viewBox="0 0 100 40" width="100" height="40">
      <rect width="100" height="40" fill="var(--viz-surface)"/>
      <circle data-step="1" cx="10" cy="20" r="5" fill="var(--viz-1)"/>
      <g data-step="2-3"><circle cx="50" cy="20" r="5" fill="var(--viz-2)"/></g>
      <circle data-step="3" cx="90" cy="20" r="5" fill="var(--viz-3)"/>
    </svg>
    """

    private func displays(_ source: String) throws -> [String: String] {
        let tree = try MockupSVGTree.parse(source)
        var out: [String: String] = [:]
        for node in tree.root.elementChildren {
            if let step = node.attribute("data-step") { out[step] = node.attribute("display") ?? "inline" }
        }
        return out
    }

    /// Each frame hides exactly the steps outside it, as the web's injected CSS does.
    func testStepFrameHidesStepsOutsideTheFrame() throws {
        XCTAssertEqual(try displays(ChatSVGNative.stepFrame(steps, step: 1)), ["1": "inline", "2-3": "none", "3": "none"])
        XCTAssertEqual(try displays(ChatSVGNative.stepFrame(steps, step: 2)), ["1": "inline", "2-3": "inline", "3": "none"])
        XCTAssertEqual(try displays(ChatSVGNative.stepFrame(steps, step: 3)), ["1": "inline", "2-3": "inline", "3": "inline"])
        XCTAssertEqual(try displays(ChatSVGNative.stepFrame(steps, step: 4)), ["1": "inline", "2-3": "none", "3": "inline"])
    }

    /// A themed step-through compiles natively in every frame: `var(--viz-*)` is resolved first, and
    /// the namespace an agent left out is added.
    func testThemedFramesCompile() throws {
        for step in 1...3 {
            let source = ChatSVGNative.frameSource(steps, palette: .dark, themed: true, step: step)
            XCTAssertFalse(source.contains("var(--viz"), "step \(step)")
            let frame = try XCTUnwrap(ChatSVGNative.compile(source), "step \(step)")
            XCTAssertEqual(frame.document.intrinsicSize, CGSize(width: 100, height: 40))
            XCTAssertTrue(frame.dropped.isEmpty)
        }
    }

    /// A frame hidden by its step draws nothing there: the renderer honours `display="none"`.
    func testHiddenStepDoesNotDraw() throws {
        let one = try XCTUnwrap(ChatSVGNative.compile(ChatSVGNative.frameSource(steps, palette: .light, themed: true, step: 1)))
        let three = try XCTUnwrap(ChatSVGNative.compile(ChatSVGNative.frameSource(steps, palette: .light, themed: true, step: 3)))
        // The step-3 circle at (90, 20) is only in frame 3.
        XCTAssertNil(one.document.hitTest(CGPoint(x: 90, y: 20)).flatMap { one.document.tree.node(at: $0)?.attribute("data-step") })
        XCTAssertEqual(three.document.hitTest(CGPoint(x: 90, y: 20)).flatMap { three.document.tree.node(at: $0)?.attribute("data-step") }, "3")
    }

    /// The cache hands back the same compiled frame rather than compiling again.
    func testFrameIsCached() throws {
        let key = EmbedCacheKey(kind: .svgSteps, messageID: "m-cache", theme: "t", source: steps, variant: "1")
        var compiles = 0
        func source() -> String { compiles += 1; return ChatSVGNative.frameSource(steps, palette: .light, themed: true, step: 1) }
        let a = try XCTUnwrap(ChatSVGNative.frame(key, source: source()))
        let b = try XCTUnwrap(ChatSVGNative.frame(key, source: source()))
        XCTAssertTrue(a.document === b.document)
        XCTAssertEqual(compiles, 1)
    }

    /// Agents style chat SVGs with CSS and add drop shadows; the frame still draws natively, with
    /// the CSS turned into attributes and what the profile can't draw reported, not silently lost.
    func testAgentSVGWithCSSAndFilterIsSimplified() throws {
        let agent = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="200" height="100">
          <style>.card { fill: #ffffff; stroke: #e5e7eb } .label { font-size: 14px; fill: #111827 }</style>
          <defs><filter id="shadow"><feDropShadow dx="0" dy="2" stdDeviation="3"/></filter></defs>
          <rect class="card" x="10" y="10" width="180" height="80" rx="8" filter="url(#shadow)"/>
          <text class="label" x="24" y="56">Runs</text>
        </svg>
        """
        let frame = try XCTUnwrap(ChatSVGNative.compile(ChatSVGNative.frameSource(agent, palette: .light, themed: false, step: nil)))
        XCTAssertFalse(frame.dropped.isEmpty, "the filter can't be drawn, so it's reported")
        let card = try XCTUnwrap(frame.document.hitTest(CGPoint(x: 100, y: 30)).flatMap { frame.document.tree.node(at: $0) })
        XCTAssertEqual(card.localName, "rect")
        XCTAssertEqual(card.attribute("fill"), "#ffffff")
        XCTAssertNil(card.attribute("class"))
    }

    func testUnparseableSourceDoesNotCompile() {
        XCTAssertNil(ChatSVGNative.compile("<svg><rect></svg>"))
        XCTAssertEqual(ChatSVGNative.stepFrame("<svg><rect data-step=\"1\"></svg>", step: 2), "<svg><rect data-step=\"1\"></svg>")
    }
}
