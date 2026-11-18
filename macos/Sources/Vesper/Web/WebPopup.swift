import AppKit
import WebKit

/// A real popup window for `window.open("", "_blank", ...)` and blob:/data: targets, where the
/// opener keeps the returned window (the connector sign-in flow writes to it later). It carries
/// no shell bridge and may navigate to any http(s) page, like a browser popup.
@MainActor
final class WebPopup: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static var open: Set<WebPopup> = []
    private let window: NSWindow
    private let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    /// `configuration` is the one WebKit hands to createWebViewWith (it ties the popup to its
    /// opener); its content controller is replaced so the popup never reaches the bridge.
    static func make(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?) -> WKWebView {
        configuration.userContentController = WKUserContentController()
        let popup = WebPopup(configuration: configuration, features: features)
        open.insert(popup)
        popup.window.center()
        if let parent {
            let f = parent.frame
            popup.window.setFrameOrigin(NSPoint(x: f.midX - popup.window.frame.width / 2, y: f.midY - popup.window.frame.height / 2))
        }
        popup.window.makeKeyAndOrderFront(nil)
        return popup.webView
    }

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        let w = CGFloat(truncating: features.width ?? 560)
        let h = CGFloat(truncating: features.height ?? 720)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: max(w, 320), height: max(h, 240)), configuration: configuration)
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            MainActor.assumeIsolated { self?.window.title = wv.title ?? "" }
        }
        // The page's host is always visible, so an untrusted page can't pose as Vesper.
        urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
            MainActor.assumeIsolated { self?.window.subtitle = wv.url?.host ?? "" }
        }
    }

    private func close() {
        titleObservation = nil
        urlObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        window.delegate = nil
        window.orderOut(nil)
        Self.open.remove(self)
    }

    func windowWillClose(_ notification: Notification) { close() }
    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .cancel }
        return ["http", "https", "blob", "data", "about"].contains(scheme) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        WebNavigationPolicy.shouldDownload(navigationResponse) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        WebDownloads.shared.adopt(download, in: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        WebDownloads.shared.adopt(download, in: webView)
    }
}

enum WebNavigationPolicy {
    /// Content-Disposition: attachment, or a type WebKit can't display, becomes a download.
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        if let http = response.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           cd.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") { return true }
        return !response.canShowMIMEType
    }
}
