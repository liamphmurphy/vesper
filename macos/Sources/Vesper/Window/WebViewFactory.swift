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

    static func makeWebView(kind: WebViewKind, bridge: WKScriptMessageHandler?, services: WebPageServices? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = userAgentSuffix
        // element.requestFullscreen (slides/designs present, video, dev terminal).
        config.preferences.isElementFullscreenEnabled = true
        switch kind {
        case .vesper:
            config.websiteDataStore = WKWebsiteDataStore.default()
            let script = WKUserScript(source: nativeModeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
            if let bridge { config.userContentController.add(bridge, name: handlerName) }
            if let services { WebPageServices.install(on: config.userContentController, services: services) }
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
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
        ]
        if baseURL.scheme == "https" { props[.secure] = "TRUE" }
        guard let cookie = HTTPCookie(properties: props) else { return }
        // Both stores: the playground gateway needs the session to let a window in, and strips
        // the cookie before proxying to the agent's app. Playground web views still get no
        // bridge, scripts or page services.
        for store in [WKWebsiteDataStore.default(), playgroundStore] {
            await store.httpCookieStore.setCookie(cookie)
            let stored = await store.httpCookieStore.allCookies().first { $0.name == StackSession.cookieName }
            vlog("session cookie set for host \(host): httpOnly=\(stored?.isHTTPOnly ?? false) sameSite=\(stored?.sameSitePolicy?.rawValue ?? "none")")
        }
    }
}
