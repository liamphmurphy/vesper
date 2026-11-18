import AppKit
import VesperCore
import WebKit

enum WebViewKind { case vesper, playground }

/// Builds the web views. Vesper pages share the default (persistent) data store and get the native
/// bridge; playground pages get a separate non-persistent store (so the session cookie, which is
/// not port-scoped, never reaches them) and neither the bridge nor the native-mode script.
@MainActor
enum WebViewFactory {
    static let userAgentSuffix = "VesperMac/1"
    static let handlerName = "vesper"

    private static let playgroundStore = WKWebsiteDataStore.nonPersistent()

    private static let nativeModeScript = """
    window.__VESPER_NATIVE__ = {v:1, platform:"macos"};
    document.documentElement.classList.add("native-mac");
    """

    static func makeWebView(kind: WebViewKind, bridge: WKScriptMessageHandler?) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = userAgentSuffix
        switch kind {
        case .vesper:
            config.websiteDataStore = WKWebsiteDataStore.default()
            let script = WKUserScript(source: nativeModeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
            if let bridge { config.userContentController.add(bridge, name: handlerName) }
        case .playground:
            config.websiteDataStore = playgroundStore
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }

    /// Puts the session cookie into the data store and waits until it is stored.
    static func installSessionCookie(baseURL: URL, token: String) async {
        guard let host = baseURL.host else { return }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: StackSession.cookieName,
            .value: token,
            .domain: host,
            .path: "/",
            .expires: Date().addingTimeInterval(365 * 24 * 3600),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if baseURL.scheme == "https" { props[.secure] = "TRUE" }
        guard let cookie = HTTPCookie(properties: props) else { return }
        await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        vlog("session cookie set for host \(host)")
    }
}
