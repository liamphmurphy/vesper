import AppKit
import VesperCore
import WebKit

/// Draws chat embeds once, off-screen, into vector PDFs: mermaid diagrams (mermaid needs a DOM to
/// measure text), svg-image and svg-steps frames, and math. One hidden `WKWebView` runs
/// `EmbedRendererPage` (bundled KaTeX and mermaid, a CSP that loads nothing remote, no bridge, a
/// non-persistent data store); jobs run one at a time and every result lands in
/// `EmbedRenderCache.shared`, keyed per message, theme and source.
///
/// Security: agent text reaches the page only as `callAsyncJavaScript` arguments. SVG (the agent's,
/// or mermaid's output) is drawn through an `<img>` from a `data:` URL, as the web does, so it can't
/// script or load anything; mermaid runs with `securityLevel: "strict"` and KaTeX with `trust: false`.
/// The page can navigate nowhere (`decidePolicyFor` allows only its own `about:blank`).
@MainActor
final class EmbedRenderer {
    static let shared = EmbedRenderer()

    enum Job: Sendable {
        /// An SVG document drawn at its intrinsic size over `background` ("#RRGGBB", or nil for clear).
        case svg(String, background: String?)
        /// A mermaid fence themed with the palette; the result's `svg` is mermaid's output.
        case mermaid(String, palette: VizPalette)
        case math(MathRenderRequest)
    }

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private let navigation = RendererNavigationDelegate()
    private var mermaidLoaded = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [EmbedCacheKey: Task<RenderedEmbed?, Never>] = [:]
    private var renderCount = 0
    /// Why the renderer can't run (the bundle is missing), once a load has failed.
    private(set) var loadError: String?

    private static let pageTimeout: Duration = .seconds(10)
    private static let jobTimeout: Duration = .seconds(8)
    /// The hidden view's size; a larger render grows it for that job.
    private static let baseSize = CGSize(width: 1024, height: 768)

    private init() {}

    /// The cached render for `key`, without drawing anything.
    func cached(_ key: EmbedCacheKey) -> RenderedEmbed? { EmbedRenderCache.shared.value(for: key) }

    /// The render for `key`: cached, already in flight, or drawn now. nil when it can't be drawn
    /// (invalid SVG, a mermaid or TeX error, a timeout); the caller shows the source instead.
    func render(_ key: EmbedCacheKey, _ job: Job) async -> RenderedEmbed? {
        if let hit = EmbedRenderCache.shared.value(for: key) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task { @MainActor [weak self] () -> RenderedEmbed? in
            guard let self else { return nil }
            await self.acquire()
            defer { self.release() }
            if let hit = EmbedRenderCache.shared.value(for: key) { return hit }
            let result = await self.run(job)
            if let result { EmbedRenderCache.shared.insert(result, for: key, cost: result.pdf.count) }
            return result
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: Jobs

    private func run(_ job: Job) async -> RenderedEmbed? {
        guard let webView = await readyWebView() else { return nil }
        switch job {
        case .svg(let source, let background):
            return await drawSVG(source, background: background, in: webView)
        case .mermaid(let code, let palette):
            guard code.count <= EmbedRendererPage.mermaidMaxSource, await loadMermaid(into: webView) else { return nil }
            renderCount += 1
            let reply = await call(
                "return await VesperEmbeds.mermaid(code, config, id)",
                ["code": code, "config": EmbedRendererPage.mermaidConfig(palette), "id": "vesper-mermaid-\(renderCount)"],
                in: webView
            )
            guard let svg = reply?["svg"] as? String, !svg.isEmpty else {
                if let error = reply?["error"] as? String { vlog("embeds: mermaid: \(error)") }
                return nil
            }
            guard var drawn = await drawSVG(svg, background: palette.surface, in: webView) else { return nil }
            drawn.svg = ChatSVG.document(svg)
            return drawn
        case .math(let request):
            let reply = await call(
                "return await VesperEmbeds.math(tex, display, color, fontSize, null)",
                ["tex": request.tex, "display": request.display, "color": request.color, "fontSize": request.fontSize],
                in: webView
            )
            guard let size = Self.size(reply) else {
                if let error = reply?["error"] as? String { vlog("embeds: math: \(error)") }
                return nil
            }
            guard let pdf = await pdf(of: size, in: webView) else { return nil }
            return RenderedEmbed(pdf: pdf, width: size.width, height: size.height, ascent: reply?["ascent"] as? Double)
        }
    }

    private func drawSVG(_ source: String, background: String?, in webView: WKWebView) async -> RenderedEmbed? {
        let size = ChatSVG.intrinsicSize(source)
        let reply = await call(
            "return await VesperEmbeds.svg(url, width, height, background)",
            ["url": ChatSVG.dataURL(source), "width": size.width, "height": size.height, "background": background ?? "transparent"],
            in: webView
        )
        guard let drawn = Self.size(reply) else {
            if let error = reply?["error"] as? String { vlog("embeds: svg: \(error)") }
            return nil
        }
        guard let pdf = await pdf(of: drawn, in: webView) else { return nil }
        return RenderedEmbed(pdf: pdf, width: drawn.width, height: drawn.height, svg: ChatSVG.document(source))
    }

    private static func size(_ reply: [String: Any]?) -> CGSize? {
        guard let w = (reply?["width"] as? NSNumber)?.doubleValue, let h = (reply?["height"] as? NSNumber)?.doubleValue,
              w >= 1, h >= 1 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The stage's top-left `size` as a one-page PDF. The hidden view grows first when the content is
    /// larger than it, so nothing is clipped.
    private func pdf(of size: CGSize, in webView: WKWebView) async -> Data? {
        let needed = CGSize(width: max(Self.baseSize.width, size.width), height: max(Self.baseSize.height, size.height))
        if webView.frame.size != needed {
            hostWindow?.setContentSize(needed)
            webView.frame = CGRect(origin: .zero, size: needed)
            _ = await call("return document.body.getBoundingClientRect().height", [:], in: webView)
        }
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        do {
            return try await webView.pdf(configuration: config)
        } catch {
            vlog("embeds: pdf: \(error.localizedDescription)")
            return nil
        }
    }

    /// Runs `body` in the page with JSON-safe arguments; a job that doesn't answer in time takes the
    /// web view down with it (a fresh one serves the next job), so one pathological diagram can't wedge
    /// every other.
    private func call(_ body: String, _ arguments: [String: Any], in webView: WKWebView) async -> [String: Any]? {
        let reply = await withTimeout(Self.jobTimeout) {
            JSReply(value: try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page))
        }
        guard let reply else {
            vlog("embeds: a render timed out; restarting the renderer")
            reset()
            return nil
        }
        return reply.value as? [String: Any]
    }

    private func loadMermaid(into webView: WKWebView) async -> Bool {
        if mermaidLoaded { return true }
        guard let script = EmbedRendererPage.mermaidScript() else {
            vlog("embeds: mermaid bundle missing")
            return false
        }
        let loaded = await withTimeout(Self.pageTimeout) {
            (try? await webView.evaluateJavaScript(script + "\n;typeof window.mermaid === 'object'")) as? Bool ?? false
        }
        mermaidLoaded = loaded == true
        if !mermaidLoaded { vlog("embeds: mermaid didn't load") }
        return mermaidLoaded
    }

    // MARK: The hidden web view

    private func readyWebView() async -> WKWebView? {
        if let webView { return webView }
        if loadError != nil { return nil }
        guard let html = EmbedRendererPage.html() else {
            loadError = "Resources/embeds missing from VesperCore's bundle"
            vlog("embeds: \(loadError!)")
            return nil
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.baseSize), configuration: config)
        view.navigationDelegate = navigation
        hostOffscreen(view)
        let ok = await withTimeout(Self.pageTimeout) { [navigation] in
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                navigation.onFinish = { ok in
                    navigation.onFinish = nil
                    done.resume(returning: ok)
                }
                view.loadHTMLString(html, baseURL: nil)
            }
        }
        guard ok == true else {
            navigation.onFinish?(false)
            vlog("embeds: the renderer page didn't load")
            view.removeFromSuperview()
            return nil
        }
        webView = view
        mermaidLoaded = false
        return view
    }

    /// WebKit lays out and paints reliably only in a window; this one sits far off-screen, never shown.
    private func hostOffscreen(_ view: WKWebView) {
        let rect = NSRect(x: -20000, y: -20000, width: Self.baseSize.width, height: Self.baseSize.height)
        let window = hostWindow ?? {
            let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            return w
        }()
        window.setFrame(rect, display: false)
        window.contentView = view
        hostWindow = window
    }

    private func reset() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        hostWindow?.contentView = nil
        webView = nil
        mermaidLoaded = false
    }

    // MARK: One job at a time

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// What the page answered: plist-like values from `callAsyncJavaScript`, only ever read on the main actor.
private struct JSReply: @unchecked Sendable {
    var value: Any?
}

/// `body`'s result, or nil when it takes longer than `limit`. The work isn't cancelled (WebKit calls
/// can't be), only abandoned.
@MainActor
func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @MainActor () async -> T) async -> T? {
    await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce(done)
        Task { @MainActor in once.resume(await body()) }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            once.resume(nil)
        }
    }
}

/// Resumes a continuation with whichever answer comes first.
@MainActor
private final class ResumeOnce<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func resume(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The renderer page may load itself and nothing else.
@MainActor
private final class RendererNavigationDelegate: NSObject, WKNavigationDelegate {
    var onFinish: ((Bool) -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let ok = navigationAction.targetFrame?.isMainFrame == true && navigationAction.navigationType == .other
            && url?.absoluteString == "about:blank"
        return ok ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(true) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFinish?(false) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFinish?(false) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        vlog("embeds: the renderer's web content process ended")
        Task { @MainActor in EmbedRenderer.shared.webContentDidTerminate(webView) }
    }
}

extension EmbedRenderer {
    fileprivate func webContentDidTerminate(_ view: WKWebView) {
        if view === webView { reset() }
    }
}
