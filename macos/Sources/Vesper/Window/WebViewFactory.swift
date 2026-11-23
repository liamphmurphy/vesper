import AppKit
import ObjectiveC
import VesperCore
import WebKit

enum WebViewKind { case vesper, inspectorPanel, playground }

/// Builds the web views. Vesper and inspector-panel pages share the default
/// (persistent) data store and get the native bridge; playground pages get a separate
/// non-persistent store (so the session cookie, which is not port-scoped, never reaches them)
/// and neither the bridge nor the native-mode script.
@MainActor
enum WebViewFactory {
    static let userAgentSuffix = "VesperMac/1"
    static let handlerName = "vesper"

    private static let playgroundStore = WKWebsiteDataStore.nonPersistent()

    /// The Vesper page's own background colour, last reported by any tab. WebKit draws it past the
    /// page's edges (overscroll), so a new tab starts with it rather than white until its page reports.
    static var lastPageBackground: NSColor?

    private static let nativeModeScript = """
    window.__VESPER_NATIVE__ = {v:1, platform:"macos"};
    document.documentElement.classList.add("native-mac");
    """

    private static let inspectorPanelModeScript = """
    window.__VESPER_NATIVE__ = {v:1, platform:"macos"};
    document.documentElement.classList.add("native-mac", "native-inspector-panel", "native-inspector-glass");
    """

    static func makeWebView(kind: WebViewKind, bridge: WKScriptMessageHandler?, services: WebPageServices? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = userAgentSuffix
        // element.requestFullscreen (slides/designs present, video, dev terminal).
        config.preferences.isElementFullscreenEnabled = true
        switch kind {
        case .vesper, .inspectorPanel:
            config.websiteDataStore = WKWebsiteDataStore.default()
            let source: String = switch kind {
            case .inspectorPanel: inspectorPanelModeScript
            case .vesper, .playground: nativeModeScript
            }
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
            if let bridge { config.userContentController.add(bridge, name: handlerName) }
            enablePrivateMediaPreferences(config.preferences)
            disable60FPSCap(config.preferences)
            if let services { WebPageServices.install(on: config.userContentController, services: services) }
        case .playground:
            config.websiteDataStore = playgroundStore
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = kind == .vesper || kind == .playground
        webView.allowsMagnification = true
        if kind == .inspectorPanel {
            disableBackground(webView)
        } else if kind != .playground, let background = lastPageBackground {
            webView.underPageBackgroundColor = background
        }
        return webView
    }

    /// Lets the native inspector backdrop's vibrancy / Liquid Glass shine through `/inspector-panel`.
    private static func disableBackground(_ webView: WKWebView) {
        webView.underPageBackgroundColor = .clear
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:"))
            || webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
    }

    /// Unlocks 120Hz ProMotion frame pacing for page animations inside Vesper web views by disabling
    /// WebKit's `PreferPageRenderingUpdatesNear60FPS` feature when the private SPI is present; skips
    /// safely otherwise.
    private static func disable60FPSCap(_ prefs: WKPreferences) {
        let featuresSel = NSSelectorFromString("_features")
        let keySel = NSSelectorFromString("key")
        let setEnabledSel = NSSelectorFromString("_setEnabled:forFeature:")
        let prefsClass: AnyClass = WKPreferences.self
        let rawFeatures: [Any]?
        if let method = class_getClassMethod(prefsClass, featuresSel) {
            typealias FeaturesFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
            let fn = unsafeBitCast(method_getImplementation(method), to: FeaturesFn.self)
            rawFeatures = fn(prefsClass, featuresSel)?.takeUnretainedValue() as? [Any]
        } else if prefs.responds(to: featuresSel) {
            rawFeatures = prefs.perform(featuresSel)?.takeUnretainedValue() as? [Any]
        } else {
            rawFeatures = nil
        }
        guard let features = rawFeatures, prefs.responds(to: setEnabledSel) else {
            vlog("private WebKit 60fps feature toggle unavailable; skipped")
            return
        }
        guard let feature = features.first(where: { obj in
            guard let nsObj = obj as? NSObject, nsObj.responds(to: keySel),
                  let key = nsObj.perform(keySel)?.takeUnretainedValue() as? String else { return false }
            return key == "PreferPageRenderingUpdatesNear60FPS" || key == "PreferPageRenderingUpdatesNear60FPSEnabled"
        }) as? NSObject else {
            vlog("private WebKit feature PreferPageRenderingUpdatesNear60FPS not found; skipped")
            return
        }
        guard let imp = class_getMethodImplementation(type(of: prefs), setEnabledSel) else { return }
        typealias SetEnabledFn = @convention(c) (AnyObject, Selector, ObjCBool, AnyObject) -> Void
        let setEnabled = unsafeBitCast(imp, to: SetEnabledFn.self)
        setEnabled(prefs, setEnabledSel, ObjCBool(false), feature)
        vlog("disabled WebKit PreferPageRenderingUpdatesNear60FPS")
    }

    /// Private WebKit preferences without which this macOS exposes no navigator.mediaDevices (so no
    /// getDisplayMedia). Vesper pages only. Each is set only if WKPreferences answers its private
    /// setter, so a WebKit that drops one is logged and skipped rather than raising
    /// NSUndefinedKeyException.
    private static func enablePrivateMediaPreferences(_ prefs: WKPreferences) {
        for (key, setter) in [("mediaDevicesEnabled", "_setMediaDevicesEnabled:"), ("screenCaptureEnabled", "_setScreenCaptureEnabled:")] {
            guard WKPreferences.instancesRespond(to: NSSelectorFromString(setter)) else {
                vlog("private WebKit preference \(key) unavailable; skipped")
                continue
            }
            prefs.setValue(true, forKey: key)
        }
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
