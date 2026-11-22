import AppKit
import WebKit
import XCTest
@testable import VesperCore

/// The renderer page in a real WKWebView: KaTeX, mermaid and SVG draw under its CSP with nothing from
/// the network, and the stage exports as a PDF. Needs a GUI session, so it's opt-in:
/// `VESPER_WEBKIT_TESTS=1 swift test --filter EmbedRendererPageWebKitTests` (the macOS VM has one).
@MainActor
final class EmbedRendererPageWebKitTests: XCTestCase {
    private var window: NSWindow?

    private func loadedPage() async throws -> WKWebView {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VESPER_WEBKIT_TESTS"] == "1", "set VESPER_WEBKIT_TESTS=1 to run")
        let html = try XCTUnwrap(EmbedRendererPage.html())
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1024, height: 768), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        self.window = window
        let loaded = expectation(description: "page loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        withExtendedLifetime(delegate) {}
        return view
    }

    private func call(_ view: WKWebView, _ body: String, _ args: [String: Any]) async throws -> [String: Any] {
        let value = try await view.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
        return try XCTUnwrap(value as? [String: Any], "unexpected reply \(String(describing: value))")
    }

    private func pdf(_ view: WKWebView, _ reply: [String: Any]) async throws -> Data {
        let w = try XCTUnwrap((reply["width"] as? NSNumber)?.doubleValue)
        let h = try XCTUnwrap((reply["height"] as? NSNumber)?.doubleValue)
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: w, height: h)
        let data = try await view.pdf(configuration: config)
        let image = try XCTUnwrap(NSImage(data: data))
        XCTAssertTrue(image.representations.contains { $0 is NSPDFImageRep }, "the export must stay vector")
        XCTAssertEqual(image.size.width, w, accuracy: 1)
        XCTAssertEqual(image.size.height, h, accuracy: 1)
        return data
    }

    func testMathDrawsWithKaTeXAndReportsItsBaseline() async throws {
        let view = try await loadedPage()
        let reply = try await call(view, "return await VesperEmbeds.math(tex, display, color, fontSize, null)",
                                   ["tex": #"\frac{a}{b} + \sqrt{x}"#, "display": false, "color": "#112233", "fontSize": 15.0])
        XCTAssertNil(reply["error"])
        let height = try XCTUnwrap((reply["height"] as? NSNumber)?.doubleValue)
        let ascent = try XCTUnwrap((reply["ascent"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThan(ascent, 0)
        XCTAssertLessThan(ascent, height)
        // KaTeX's own fonts loaded from the inlined data: URLs, not a fallback.
        let fonts = try await view.callAsyncJavaScript("await document.fonts.ready; return [...document.fonts].filter(f => f.status === 'loaded').map(f => f.family).join(',')", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertTrue(fonts?.contains("KaTeX_Main") == true, "loaded fonts: \(fonts ?? "none")")
        _ = try await pdf(view, reply)

        let bad = try await call(view, "return await VesperEmbeds.math(tex, true, '#000000', 15, null)", ["tex": #"\frac{1}{"#])
        XCTAssertNotNil(bad["error"])
    }

    func testSVGDrawsThroughAnImageAndCantScript() async throws {
        let view = try await loadedPage()
        let svg = ##"<svg viewBox="0 0 200 100"><rect width="200" height="100" fill="#2A78D6"/><script>document.title="pwned"</script></svg>"##
        let size = ChatSVG.intrinsicSize(svg)
        let reply = try await call(view, "return await VesperEmbeds.svg(url, width, height, background)",
                                   ["url": ChatSVG.dataURL(svg), "width": size.width, "height": size.height, "background": "#FFFFFF"])
        XCTAssertEqual((reply["width"] as? NSNumber)?.doubleValue, 200)
        XCTAssertEqual((reply["height"] as? NSNumber)?.doubleValue, 100)
        let title = try await view.callAsyncJavaScript("return document.title", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(title, "")
        _ = try await pdf(view, reply)

        let broken = try await call(view, "return await VesperEmbeds.svg(url, 10, 10, null)", ["url": ChatSVG.dataURL("<svg><g></svg")])
        XCTAssertNotNil(broken["error"])
    }

    func testMermaidRendersUnderThePageCSP() async throws {
        let view = try await loadedPage()
        let script = try XCTUnwrap(EmbedRendererPage.mermaidScript())
        let loaded = try await view.evaluateJavaScript(script + "\n;typeof window.mermaid === 'object'") as? Bool
        XCTAssertEqual(loaded, true)
        let reply = try await call(view, "return await VesperEmbeds.mermaid(code, config, id)",
                                   ["code": "flowchart LR\n  A[Start] --> B{Cached?}\n  B -- yes --> C[Done]", "config": EmbedRendererPage.mermaidConfig(.dark), "id": "m1"])
        let svg = try XCTUnwrap(reply["svg"] as? String, "mermaid error: \(reply["error"] ?? "none")")
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains(VizPalette.dark.panel) || svg.contains(VizPalette.dark.panel.lowercased()), "themed with the palette")
        let size = ChatSVG.intrinsicSize(svg)
        let drawn = try await call(view, "return await VesperEmbeds.svg(url, width, height, background)",
                                   ["url": ChatSVG.dataURL(svg), "width": size.width, "height": size.height, "background": VizPalette.dark.surface])
        XCTAssertNil(drawn["error"])
        _ = try await pdf(view, drawn)

        let broken = try await call(view, "return await VesperEmbeds.mermaid(code, config, id)",
                                    ["code": "flowchart LR\n  A --> \n  (((", "config": EmbedRendererPage.mermaidConfig(.light), "id": "m2"])
        XCTAssertNotNil(broken["error"])
    }
}

/// The app sandbox's WebKit parts: the content rule list compiles (WebKit accepts only a regex subset)
/// and the CSP stops an app's fetch before it leaves.
@MainActor
final class ChatAppSandboxWebKitTests: XCTestCase {
    func testRuleListCompilesAndCSPBlocksFetch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VESPER_WEBKIT_TESTS"] == "1", "set VESPER_WEBKIT_TESTS=1 to run")
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "vesper-chat-app-sandbox-test", encodedContentRuleList: ChatApp.contentRuleList
        )
        let list = try XCTUnwrap(rules)
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(list)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let loaded = expectation(description: "app loaded")
        let delegate = LoadDelegate { loaded.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(ChatApp.document("""
        <script>
        document.addEventListener("securitypolicyviolation", (e) => { document.title = "csp:" + e.effectiveDirective });
        fetch("https://example.com/?leak=1").catch(() => {});
        </script>
        """), baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        var title = ""
        for _ in 0..<40 where title.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            title = try await view.evaluateJavaScript("document.title") as? String ?? ""
        }
        XCTAssertEqual(title, "csp:connect-src")
        withExtendedLifetime((delegate, window)) {}
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: "vesper-chat-app-sandbox-test")
    }
}

@MainActor
private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
