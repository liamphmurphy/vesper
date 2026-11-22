import XCTest
@testable import VesperCore

/// Native chat embeds (VesperCore ChatEmbeds/). Expected strings come from running the web's
/// lib/chat-svg.ts and lib/chat-app.ts on the same inputs, so the ports can't drift silently.
final class ChatEmbedsTests: XCTestCase {
    // MARK: Classification

    func testClassifyMatchesTheWebsFenceWords() {
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "mermaid"), .mermaid)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "  Mermaid title=x"), .mermaid)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "svg-image"), .svgImage)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "SVG-STEPS"), .svgSteps)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "app"), .app)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "html-app extra"), .app)
        XCTAssertEqual(EmbeddedBlockKind.classify(info: "math"), .math)
        XCTAssertNil(EmbeddedBlockKind.classify(info: "html"))
        XCTAssertNil(EmbeddedBlockKind.classify(info: "svg"))
        XCTAssertNil(EmbeddedBlockKind.classify(info: "application"))
        XCTAssertNil(EmbeddedBlockKind.classify(info: ""))
        XCTAssertNil(EmbeddedBlockKind.classify(info: nil))
    }

    func testOnlyDiagramsSaveToLibraryAndOnlyAppsStayLive() {
        XCTAssertEqual(EmbeddedBlockKind.allCases.filter(\.savesToLibrary), [.mermaid, .svgImage, .svgSteps])
        XCTAssertEqual(EmbeddedBlockKind.allCases.filter { !$0.isRenderedOnce }, [.app])
    }

    // MARK: Cache keys

    func testCacheKeySeparatesMessageThemeSourceAndVariant() {
        let base = EmbedCacheKey(kind: .mermaid, messageID: "m1", theme: "light", source: "graph TD; a-->b")
        XCTAssertEqual(base, EmbedCacheKey(kind: .mermaid, messageID: "m1", theme: "light", source: "graph TD; a-->b"))
        XCTAssertNotEqual(base, EmbedCacheKey(kind: .mermaid, messageID: "m2", theme: "light", source: "graph TD; a-->b"))
        XCTAssertNotEqual(base, EmbedCacheKey(kind: .mermaid, messageID: "m1", theme: "dark", source: "graph TD; a-->b"))
        XCTAssertNotEqual(base, EmbedCacheKey(kind: .mermaid, messageID: "m1", theme: "light", source: "graph TD; a-->c"))
        XCTAssertNotEqual(base, EmbedCacheKey(kind: .mermaid, messageID: "m1", theme: "light", source: "graph TD; a-->b", variant: "2"))
        XCTAssertNotEqual(base, EmbedCacheKey(kind: .svgImage, messageID: "m1", theme: "light", source: "graph TD; a-->b"))
        XCTAssertEqual(base.sourceHash, "\(EmbedCacheKey.hash("graph TD; a-->b"))")
        XCTAssertEqual(EmbedCacheKey.hash("").count, 64)
        XCTAssertEqual(base.description, "mermaid|m1|light|\(base.sourceHash)|")
    }

    func testMathRequestKeyCoversColourSizeAndDisplay() {
        let a = MathRenderRequest(tex: " x^2 ", display: true, color: "#112233", fontSize: 15)
        XCTAssertEqual(a.tex, "x^2")
        XCTAssertEqual(a.cacheKey(messageID: "m"), MathRenderRequest(tex: "x^2", display: true, color: "#112233", fontSize: 15).cacheKey(messageID: "m"))
        XCTAssertNotEqual(a.cacheKey(), MathRenderRequest(tex: "x^2", display: false, color: "#112233", fontSize: 15).cacheKey())
        XCTAssertNotEqual(a.cacheKey(), MathRenderRequest(tex: "x^2", display: true, color: "#112234", fontSize: 15).cacheKey())
        XCTAssertNotEqual(a.cacheKey(), MathRenderRequest(tex: "x^2", display: true, color: "#112233", fontSize: 16).cacheKey())
        // A colour that isn't hex never reaches the page's style.
        XCTAssertEqual(MathRenderRequest(tex: "x", display: false, color: "red;}", fontSize: 1).color, "#000000")
        XCTAssertEqual(MathRenderRequest(tex: "x", display: false, color: "#fff", fontSize: 1000).fontSize, 96)
    }

    func testVizPaletteFingerprintFollowsTokensAndMode() {
        XCTAssertEqual(VizPalette(theme: ThemeTokens(mode: .light)), .light)
        XCTAssertEqual(VizPalette(theme: ThemeTokens(mode: .dark)), .dark)
        let custom = VizPalette(theme: ThemeTokens(mode: .dark, colors: ["viz-ink": "#ABCDEF", "viz-3": "#010203", "viz-panel": "nope"]))
        XCTAssertEqual(custom.ink, "#ABCDEF")
        XCTAssertEqual(custom.series[2], "#010203")
        XCTAssertEqual(custom.panel, VizPalette.dark.panel)
        XCTAssertNotEqual(custom.fingerprint, VizPalette.dark.fingerprint)
        XCTAssertTrue(VizPalette.dark.isDark)
        XCTAssertFalse(VizPalette.light.isDark)
    }

    // MARK: lib/chat-svg.ts

    private let steps = """
    <svg viewBox="0 0 10 10"><title> Build up </title><rect data-step="1"/><circle data-step="2-3"/><path data-step='3'/><g data-step="x"/></svg>
    1. First
    2) Second

    Third
    """

    func testStepsFenceParsesCaptionsCountAndFrames() {
        let (svg, captions) = ChatSVG.parseStepsFence(steps)
        XCTAssertEqual(captions, ["First", "Second", "Third"])
        XCTAssertEqual(svg, #"<svg viewBox="0 0 10 10"><title> Build up </title><rect data-step="1"/><circle data-step="2-3"/><path data-step='3'/><g data-step="x"/></svg>"#)
        XCTAssertEqual(ChatSVG.stepCount(svg, captions: captions), 3)
        XCTAssertEqual(ChatSVG.stepCount(svg, captions: []), 3)
        XCTAssertEqual(ChatSVG.stepCount("<svg/>", captions: Array(repeating: "c", count: 20)), 12)
        XCTAssertEqual(
            ChatSVG.stepFrame(svg, step: 1),
            #"<svg viewBox="0 0 10 10"><style>[data-step="2-3"],[data-step="3"]{display:none}</style><title> Build up </title><rect data-step="1"/><circle data-step="2-3"/><path data-step='3'/><g data-step="x"/></svg>"#
        )
        XCTAssertEqual(
            ChatSVG.stepFrame(svg, step: 4),
            #"<svg viewBox="0 0 10 10"><style>[data-step="2-3"]{display:none}</style><title> Build up </title><rect data-step="1"/><circle data-step="2-3"/><path data-step='3'/><g data-step="x"/></svg>"#
        )
        XCTAssertEqual(ChatSVG.title(svg), "Build up")
        XCTAssertEqual(ChatSVG.parseStepsFence("no svg here").captions, [])
    }

    func testThemingExportAndDataURLMatchTheWeb() {
        XCTAssertEqual(
            ChatSVG.theme(#"<rect fill="var(--viz-2-soft)" stroke="var( --viz-INK )" x="var(--viz-grid)"/>"#, palette: .dark),
            ##"<rect fill="#D9592626" stroke="#EEEDF3" x="var(--viz-grid)"/>"##
        )
        XCTAssertEqual(
            ChatSVG.export(#"<svg viewBox="0 0 1 1"><rect fill="var(--viz-panel)"/></svg>"#, palette: .dark),
            ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><style>:root{background:#15141F}</style><rect fill="#1F1D2C"/></svg>"##
        )
        XCTAssertEqual(ChatSVG.document(#"  <svg width="2"><g/></svg> "#), #"<svg xmlns="http://www.w3.org/2000/svg" width="2"><g/></svg>"#)
        XCTAssertEqual(ChatSVG.document(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#), #"<svg xmlns="http://www.w3.org/2000/svg"/>"#)
        XCTAssertEqual(
            ChatSVG.dataURL(#"<svg>é & "x" (a)*~!'</svg>"#),
            "data:image/svg+xml;charset=utf-8,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%C3%A9%20%26%20%22x%22%20(a)*~!'%3C%2Fsvg%3E"
        )
        XCTAssertTrue(ChatSVG.isThemed("fill=\"var(--viz-1)\""))
        XCTAssertFalse(ChatSVG.isThemed("fill=\"#fff\""))
    }

    func testIntrinsicSizeFromAttributesAndViewBox() {
        XCTAssertTrue(ChatSVG.intrinsicSize(#"<svg width="200" height="100px"/>"#) == (200, 100))
        XCTAssertTrue(ChatSVG.intrinsicSize(#"<svg viewBox="0 0 680 340"><g/></svg>"#) == (680, 340))
        XCTAssertTrue(ChatSVG.intrinsicSize(#"<svg width="340" viewBox="0,0,680,340"/>"#) == (340, 170))
        XCTAssertTrue(ChatSVG.intrinsicSize(#"<svg width="100%" style="max-width: 500px" viewBox="0 0 500 250"/>"#) == (500, 250))
        XCTAssertTrue(ChatSVG.intrinsicSize("<svg/>") == (300, 150))
        XCTAssertTrue(ChatSVG.intrinsicSize(#"<svg viewBox="0 0 100000 1000"/>"#, limit: 4096) == (4096, 41))
    }

    // MARK: lib/chat-app.ts

    func testAppCSPAndDocumentMatchTheWeb() {
        XCTAssertEqual(
            ChatApp.csp,
            "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com; style-src 'unsafe-inline' https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com; font-src data: https://cdn.jsdelivr.net https://unpkg.com https://cdnjs.cloudflare.com; img-src data: blob:; media-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'"
        )
        let doc = ChatApp.document("<!DOCTYPE html><p>hi</p>")
        // The policy is the first thing in the document, ahead of all of the app's markup.
        XCTAssertTrue(doc.hasPrefix("<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(ChatApp.csp)\">"))
        XCTAssertTrue(doc.hasSuffix("sans-serif}</style><p>hi</p>"))
        XCTAssertFalse(doc.contains("<!DOCTYPE"))
        XCTAssertEqual(ChatApp.escapeAttribute(#"a&"b"#), "a&amp;&quot;b")
    }

    func testAppHeightClampsLikeTheWeb() {
        XCTAssertEqual(ChatApp.height(nil), 120)
        XCTAssertEqual(ChatApp.height(50), 120)
        XCTAssertEqual(ChatApp.height(300.2), 301)
        XCTAssertEqual(ChatApp.height(10_000), 720)
        XCTAssertEqual(ChatApp.height(.nan), 120)
        XCTAssertEqual(ChatApp.height(.infinity), 120)
    }

    func testAppNavigationOnlyAllowsTheShellsBlankDocument() {
        XCTAssertTrue(ChatApp.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, isUserInitiatedLink: false))
        XCTAssertFalse(ChatApp.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: false, isUserInitiatedLink: false))
        XCTAssertFalse(ChatApp.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, isUserInitiatedLink: true))
        XCTAssertFalse(ChatApp.allowsNavigation(to: URL(string: "about:srcdoc"), isMainFrame: true, isUserInitiatedLink: false))
        XCTAssertFalse(ChatApp.allowsNavigation(to: URL(string: "https://evil.example/?typed=secret"), isMainFrame: true, isUserInitiatedLink: false))
        XCTAssertFalse(ChatApp.allowsNavigation(to: URL(string: "https://cdn.jsdelivr.net/npm/x"), isMainFrame: true, isUserInitiatedLink: false))
        XCTAssertFalse(ChatApp.allowsNavigation(to: URL(string: "data:text/html,hi"), isMainFrame: true, isUserInitiatedLink: false))
        XCTAssertFalse(ChatApp.allowsNavigation(to: nil, isMainFrame: true, isUserInitiatedLink: false))
    }

    func testAppContentRuleListBlocksAllButTheCDNsAndInlineURLs() throws {
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ChatApp.contentRuleList.utf8)) as? [[String: [String: String]]])
        XCTAssertEqual(rules.first?["trigger"]?["url-filter"], ".*")
        XCTAssertEqual(rules.first?["action"]?["type"], "block")
        let allowed = rules.dropFirst().map { $0["trigger"]?["url-filter"] ?? "" }
        XCTAssertEqual(allowed, [#"^https://cdn\.jsdelivr\.net/"#, #"^https://unpkg\.com/"#, #"^https://cdnjs\.cloudflare\.com/"#, "^data:", "^blob:", "^about:"])
        XCTAssertTrue(rules.dropFirst().allSatisfy { $0["action"]?["type"] == "ignore-previous-rules" })
        // The allow filters really are anchored: a look-alike host doesn't match.
        for filter in allowed {
            let re = try NSRegularExpression(pattern: filter)
            for url in ["https://cdn.jsdelivr.net.evil.example/x", "https://evil.example/https://unpkg.com/"] {
                XCTAssertNil(re.firstMatch(in: url, range: NSRange(location: 0, length: url.utf16.count)), "\(filter) matched \(url)")
            }
        }
    }

    func testResizeScriptNamesTheHandlerAsJSON() {
        let script = ChatApp.resizeScript(handler: "vesperAppHeight")
        XCTAssertTrue(script.contains(#"messageHandlers["vesperAppHeight"]"#))
        XCTAssertEqual(ChatApp.jsonString(#"a"b"#), #""a\"b""#)
    }

    // MARK: Renderer page

    func testRendererPageLoadsNothingRemote() throws {
        XCTAssertTrue(EmbedRendererPage.csp.hasPrefix("default-src 'none'"))
        XCTAssertTrue(EmbedRendererPage.csp.contains("connect-src 'none'"))
        XCTAssertFalse(EmbedRendererPage.csp.contains("http"))
        let dir = try XCTUnwrap(EmbedRendererPage.bundledDirectory(), "Resources/embeds missing from VesperCore's bundle")
        let html = try XCTUnwrap(EmbedRendererPage.html(resources: dir))
        XCTAssertTrue(html.contains("window.VesperEmbeds"))
        XCTAssertFalse(html.contains("url(fonts/"), "KaTeX's fonts must be inlined")
        XCTAssertNil(html.range(of: #"(src|href)\s*=\s*["']?https?:"#, options: .regularExpression), "the renderer page must not reference the network")
        let mermaid = try XCTUnwrap(EmbedRendererPage.mermaidScript(resources: dir))
        XCTAssertTrue(mermaid.hasPrefix("/* mermaid "))
    }

    func testMermaidConfigMatchesTheWebsInitialize() throws {
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(EmbedRendererPage.mermaidConfig(.dark).utf8)) as? [String: Any])
        XCTAssertEqual(config["securityLevel"] as? String, "strict")
        XCTAssertEqual(config["theme"] as? String, "base")
        XCTAssertEqual(config["htmlLabels"] as? Bool, false)
        let vars = try XCTUnwrap(config["themeVariables"] as? [String: Any])
        XCTAssertEqual(vars["darkMode"] as? Bool, true)
        XCTAssertEqual(vars["primaryColor"] as? String, VizPalette.dark.panel)
        XCTAssertEqual(vars["pie8"] as? String, VizPalette.dark.series[7])
        let light = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(EmbedRendererPage.mermaidConfig(.light).utf8)) as? [String: Any])
        XCTAssertEqual((light["themeVariables"] as? [String: Any])?["darkMode"] as? Bool, false)
    }

    // MARK: Cache

    func testLRUCacheEvictsLeastRecentlyUsedByCountAndCost() {
        let cache = EmbedLRUCache<String, Int>(countLimit: 3, costLimit: 100)
        cache.insert(1, for: "a", cost: 10)
        cache.insert(2, for: "b", cost: 10)
        cache.insert(3, for: "c", cost: 10)
        XCTAssertEqual(cache.value(for: "a"), 1)  // a is now the most recent
        cache.insert(4, for: "d", cost: 10)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.keys, ["c", "a", "d"])
        cache.insert(5, for: "e", cost: 85)  // over the cost: drops c and a
        XCTAssertEqual(cache.keys, ["d", "e"])
        cache.insert(6, for: "huge", cost: 101)
        XCTAssertNil(cache.value(for: "huge"))
        cache.insert(7, for: "d", cost: 5)  // replacing keeps one entry
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: "d"), 7)
        cache.removeValue(for: "d")
        XCTAssertEqual(cache.keys, ["e"])
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: Pool

    func testPoolLedgerCreatesThenReusesThenEvictsLeastRecent() {
        var pool = EmbedPoolLedger<String>(capacity: 2)
        XCTAssertEqual(pool.acquire("a"), .create(0))
        XCTAssertEqual(pool.acquire("b"), .create(1))
        XCTAssertEqual(pool.acquire("a"), .existing(0))
        // Every slot is busy: b is the least recently used.
        XCTAssertEqual(pool.acquire("c"), .evict(1, previous: "b"))
        XCTAssertEqual(pool.liveOwners, ["a", "c"])
        pool.touch("a")
        XCTAssertEqual(pool.liveOwners, ["c", "a"])
        XCTAssertEqual(pool.release("c"), 1)
        XCTAssertEqual(pool.idleCount, 1)
        XCTAssertNil(pool.release("c"))
        // An idle view is reused before anything is evicted, and no more than capacity are made.
        XCTAssertEqual(pool.acquire("d"), .reuse(1))
        XCTAssertEqual(pool.slots.count, 2)
        XCTAssertEqual(pool.acquire("e"), .evict(0, previous: "a"))
        XCTAssertEqual(pool.slot(of: "e"), 0)
        XCTAssertNil(pool.slot(of: "a"))
        XCTAssertEqual(EmbedPoolLedger<String>(capacity: 0).capacity, 1)
    }
}
