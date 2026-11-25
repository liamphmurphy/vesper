import AppKit
import VesperCore
import WebKit

/// Builds playground web views and installs the session cookie into WebKit's cookie stores.
/// Playground pages use a dedicated non-persistent store so browser state stays isolated, while
/// still carrying the session cookie so the playground gateway lets the window through (the
/// gateway strips the cookie before proxying to the agent's app).
@MainActor
enum WebViewFactory {
    static let userAgentSuffix = "VesperMac/1"

    private static let playgroundStore = WKWebsiteDataStore.nonPersistent()

    static func makePlaygroundWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = userAgentSuffix
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = playgroundStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }

    /// Puts the session cookie into the data stores and waits until it is stored.
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
        // Both stores: Custom Apps / Print views use the default store for authenticated media,
        // and the playground gateway needs the session cookie in playgroundStore (stripping it
        // before proxying to the agent's app).
        for store in [WKWebsiteDataStore.default(), playgroundStore] {
            await store.httpCookieStore.setCookie(cookie)
            let stored = await store.httpCookieStore.allCookies().first { $0.name == StackSession.cookieName }
            vlog("session cookie set for host \(host): httpOnly=\(stored?.isHTTPOnly ?? false) sameSite=\(stored?.sameSitePolicy?.rawValue ?? "none")")
        }
    }
}
