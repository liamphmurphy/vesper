import Foundation

/// Ports of lib/chat-app.ts: an ```app fence's sandbox. The web runs the document in an iframe with
/// `sandbox="allow-scripts"`; natively it runs in a WKWebView with no bridge, a non-persistent data
/// store, a content rule list and a navigation policy that keep it off the network the same way.
/// Keep `csp` in step with `APP_CSP`.
public enum ChatApp {
    /// CDNs an app may load scripts and styles from (`APP_CDNS`). Nothing else on the network is reachable.
    public static let cdns = ["https://cdn.jsdelivr.net", "https://unpkg.com", "https://cdnjs.cloudflare.com"]

    /// The app's Content-Security-Policy (`APP_CSP`): no fetch, XHR, WebSocket, form posts or remote
    /// images, so an app can't send what the person types anywhere; inline code and the CDNs are allowed
    /// so apps can use libraries like Chart.js.
    public static let csp = [
        "default-src 'none'",
        "script-src 'unsafe-inline' 'unsafe-eval' \(cdns.joined(separator: " "))",
        "style-src 'unsafe-inline' \(cdns.joined(separator: " "))",
        "font-src data: \(cdns.joined(separator: " "))",
        "img-src data: blob:",
        "media-src data: blob:",
        "connect-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    /// `APP_MIN_HEIGHT` / `APP_MAX_HEIGHT`: the frame grows to fit its content up to 720px.
    public static let minHeight: Double = 120
    public static let maxHeight: Double = 720

    /// A reported content height clamped to the frame's bounds (`appHeight`).
    public static func height(_ h: Double?) -> Double {
        guard let h, h.isFinite else { return minHeight }
        return min(maxHeight, max(minHeight, h.rounded(.up)))
    }

    private static let baseStyle = "<style>:root{color-scheme:light}html,body{margin:0;background:#fff;color:#111}body{padding:12px;font:14px/1.45 system-ui,-apple-system,sans-serif}</style>"

    /// The document for an app's source (`appDocument`). The CSP meta comes first, before any of the
    /// app's own markup, so it applies to every script the app runs (a later policy the app adds can
    /// only narrow it). A leading doctype is dropped and re-added ahead of it, so the document stays in
    /// standards mode. Unlike the web there's no resize script in the page: the shell measures the
    /// height from an isolated content world the app's scripts can't reach.
    public static func document(_ source: String) -> String {
        let body = source.replacingOccurrences(of: "^\\s*<!doctype[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        return "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(escapeAttribute(csp))\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\(baseStyle)\(body)"
    }

    static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A WebKit content rule list (JSON) that blocks every load except the CDNs and inline `data:`,
    /// `blob:` and `about:` URLs: a second wall behind the CSP, which a page can't loosen and which also
    /// covers what CSP doesn't (prefetches, pings, a navigation the policy below somehow misses).
    public static var contentRuleList: String {
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        // WebKit's rule regexes are a small subset: only the dots need escaping in these origins.
        let allowed = cdns.map { "^" + $0.replacingOccurrences(of: ".", with: "\\.") + "/" } + ["^data:", "^blob:", "^about:"]
        for filter in allowed {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the app's web view may follow a navigation: only the document the shell loads
    /// (`about:blank`, as `loadHTMLString(_:baseURL: nil)` gives it). Links, `location = …`, form
    /// submissions and frames all stay where they are, so typed text can't leave by a URL either; the
    /// web's sandboxed iframe can't navigate the page out from under the chat for the same reason.
    public static func allowsNavigation(to url: URL?, isMainFrame: Bool, isUserInitiatedLink: Bool) -> Bool {
        guard isMainFrame, !isUserInitiatedLink, let url else { return false }
        return url.scheme?.lowercased() == "about" && url.absoluteString.lowercased() == "about:blank"
    }

    /// A script for an isolated content world: it reports the document's height to the shell whenever
    /// it changes (the web's RESIZE_SCRIPT). The app's own scripts run in the page world, where the
    /// message handler doesn't exist.
    public static func resizeScript(handler: String) -> String {
        """
        (() => {
          let last = 0;
          const post = () => {
            const root = document.documentElement;
            if (!root) return;
            const h = Math.ceil(root.getBoundingClientRect().height);
            if (h !== last) { last = h; window.webkit.messageHandlers[\(jsonString(handler))].postMessage(h); }
          };
          addEventListener("load", post);
          if (document.documentElement) new ResizeObserver(post).observe(document.documentElement);
          post();
        })();
        """
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
