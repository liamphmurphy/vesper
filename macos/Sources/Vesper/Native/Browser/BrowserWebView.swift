import AppKit
import SwiftUI
import VesperCore
import WebKit

// MARK: - Isolated WebKit Factory & Content Blocker

/// Builds isolated `WKWebView` instances for the internal Browser.
///
/// Security boundary:
/// - Regular browser tabs use a dedicated persistent `WKWebsiteDataStore(forIdentifier:)` that is
///   completely separate from `WKWebsiteDataStore.default()` and `playgroundStore`, so Vesper's
///   `vesper_session` cookie (installed by `WebViewFactory.installSessionCookie`) never touches
///   arbitrary websites.
/// - Private tabs use `WKWebsiteDataStore.nonPersistent()`.
/// - Uses a standard Safari User-Agent (no `VesperMac/1` suffix) so OAuth providers and sites do
///   not reject it as an embedded webview.
@MainActor
enum BrowserWebViewFactory {
    static let browsingStoreID = UUID(uuidString: "9E6F2D4A-8B7C-4D3E-A1F2-5C8B9E0A4F11")!
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"

    static let persistentStore: WKWebsiteDataStore = WKWebsiteDataStore(forIdentifier: browsingStoreID)

    static func makeWebView(
        isPrivate: Bool,
        contentRuleList: WKContentRuleList?
    ) -> BrowserWKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = isPrivate ? WKWebsiteDataStore.nonPersistent() : persistentStore
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        if let contentRuleList {
            config.userContentController.add(contentRuleList)
        }
        let webView = BrowserWKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        return webView
    }
}

/// Compiles and caches the native WebKit `WKContentRuleList` for ad & tracker blocking.
@MainActor
final class BrowserContentBlockerManager {
    private static let ruleListIdentifier = "com.vesper.mac.browser.adblock.v1"
    private(set) var compiledRuleList: WKContentRuleList?
    private var lastJSON: String?

    func compile(enabled: Bool, disabledHosts: [String]) async -> WKContentRuleList? {
        guard enabled else {
            compiledRuleList = nil
            lastJSON = nil
            return nil
        }
        let json = BrowserContentBlockerRules.ruleListJSON(disabledHosts: disabledHosts)
        if json == lastJSON, let existing = compiledRuleList {
            return existing
        }
        do {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: Self.ruleListIdentifier,
                encodedContentRuleList: json
            )
            compiledRuleList = list
            lastJSON = json
            return list
        } catch {
            vlog("browser adblock compile failed: \(error)")
            return compiledRuleList
        }
    }
}

// MARK: - BrowserWKWebView (Native Context Menu Actions)

@MainActor
final class BrowserWKWebView: WKWebView {
    struct ContextCallbacks {
        var onAskPersona: () -> Void
        var onClipToKnowledge: () -> Void
        var onSaveLink: () -> Void
        var onCopyMarkdownQuote: () -> Void
        var onScreenshotToNotes: () -> Void
        var onOpenInSafari: () -> Void
    }

    var contextCallbacks: ContextCallbacks?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard contextCallbacks != nil else { return }

        menu.addItem(.separator())

        let askItem = NSMenuItem(title: "Ask Persona about Selection / Page", action: #selector(handleAskPersona), keyEquivalent: "")
        askItem.target = self
        askItem.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        menu.addItem(askItem)

        let clipItem = NSMenuItem(title: "Clip to Knowledge", action: #selector(handleClipToKnowledge), keyEquivalent: "")
        clipItem.target = self
        clipItem.image = NSImage(systemSymbolName: "book", accessibilityDescription: nil)
        menu.addItem(clipItem)

        let shotItem = NSMenuItem(title: "Screenshot to Knowledge Note", action: #selector(handleScreenshotToNotes), keyEquivalent: "")
        shotItem.target = self
        shotItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: nil)
        menu.addItem(shotItem)

        let quoteItem = NSMenuItem(title: "Copy Markdown Quote", action: #selector(handleCopyMarkdownQuote), keyEquivalent: "")
        quoteItem.target = self
        quoteItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        menu.addItem(quoteItem)

        let saveLinkItem = NSMenuItem(title: "Save Link to Reading List", action: #selector(handleSaveLink), keyEquivalent: "")
        saveLinkItem.target = self
        saveLinkItem.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        menu.addItem(saveLinkItem)

        let safariItem = NSMenuItem(title: "Open Page in Safari", action: #selector(handleOpenInSafari), keyEquivalent: "")
        safariItem.target = self
        safariItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        menu.addItem(safariItem)
    }

    @objc private func handleAskPersona() { contextCallbacks?.onAskPersona() }
    @objc private func handleClipToKnowledge() { contextCallbacks?.onClipToKnowledge() }
    @objc private func handleScreenshotToNotes() { contextCallbacks?.onScreenshotToNotes() }
    @objc private func handleCopyMarkdownQuote() { contextCallbacks?.onCopyMarkdownQuote() }
    @objc private func handleSaveLink() { contextCallbacks?.onSaveLink() }
    @objc private func handleOpenInSafari() { contextCallbacks?.onOpenInSafari() }
}

// MARK: - OAuth / JS Popup Window Controller

/// Hosts small JavaScript popups (e.g. Google/GitHub OAuth sign-in flows) using the exact
/// `WKWebViewConfiguration` WebKit provides so cookies and `window.opener` stay intact.
@MainActor
final class BrowserPopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    private let onClose: () -> Void

    init(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let width = max(420, min(960, CGFloat(windowFeatures.width?.doubleValue ?? 560)))
        let height = max(480, min(840, CGFloat(windowFeatures.height?.doubleValue ?? 680)))
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        wv.customUserAgent = BrowserWebViewFactory.safariUserAgent
        wv.isInspectable = true
        self.webView = wv

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sign In"
        panel.isReleasedWhenClosed = false
        panel.contentView = wv
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        wv.uiDelegate = self
        wv.navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let title = webView.title, !title.isEmpty {
            window?.title = title
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        onClose()
    }
}

// MARK: - Page Extraction & Reader Mode Scripts

enum BrowserPageScripts {
    /// Extracts visible page text and selection without reading form inputs, passwords,
    /// editable regions, scripts, or hidden elements (mirrors `SafariExtension/Resources/lib.js`).
    static let extractPageJS = """
    (() => {
      const SKIP = new Set([
        "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "INPUT", "TEXTAREA",
        "SELECT", "OPTION", "BUTTON", "SVG", "CANVAS", "IFRAME", "OBJECT", "EMBED"
      ]);
      const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DIV|DL|DT|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TR|UL|BR)$/;
      const hidden = (el) => {
        if (el.hidden || el.getAttribute("aria-hidden") === "true" || el.isContentEditable) return true;
        if (typeof el.checkVisibility === "function") {
          return !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
        }
        const s = getComputedStyle(el);
        return s.display === "none" || s.visibility === "hidden";
      };
      const parts = [];
      const walk = (node) => {
        for (let child = node.firstChild; child; child = child.nextSibling) {
          if (child.nodeType === Node.TEXT_NODE) {
            const t = child.nodeValue.replace(/\\s+/g, " ");
            if (t.trim()) parts.push(t);
          } else if (child.nodeType === Node.ELEMENT_NODE) {
            if (SKIP.has(child.tagName.toUpperCase()) || hidden(child)) continue;
            const block = BLOCK.test(child.tagName.toUpperCase());
            if (block) parts.push("\\n");
            walk(child.shadowRoot || child);
            if (block) parts.push("\\n");
          }
        }
      };
      if (document.body) walk(document.body);
      const text = parts.join("").replace(/[ \\t]+\\n/g, "\\n").replace(/\\n{3,}/g, "\\n\\n").trim();
      return {
        url: location.href,
        title: document.title || "",
        text: text.slice(0, 200000),
        selection: String(getSelection() || "").slice(0, 20000)
      };
    })();
    """

    static let selectionOnlyJS = "String(window.getSelection() || '').slice(0, 20000)"

    /// Toggles a clean, Vesper-themed Reader Mode overlay inside the active page.
    /// Returns true when Reader Mode is now active, false when dismissed.
    static func toggleReaderModeJS(darkMode: Bool) -> String {
        let bg = darkMode ? "#16171a" : "#faf9f7"
        let fg = darkMode ? "#e6e7ea" : "#1c1d20"
        let muted = darkMode ? "#9ca0aa" : "#646873"
        let border = darkMode ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.12)"
        let codeBg = darkMode ? "#202228" : "#f0eee9"
        let link = darkMode ? "#7aa2f7" : "#2563eb"

        return """
        (() => {
          const OVERLAY_ID = "__vesper_reader_overlay__";
          const existing = document.getElementById(OVERLAY_ID);
          if (existing) {
            existing.remove();
            document.documentElement.style.overflow = "";
            return false;
          }
          const score = (el) => {
            if (!el) return 0;
            const ps = el.querySelectorAll("p, pre, blockquote, li");
            let chars = 0;
            ps.forEach((p) => { chars += (p.innerText || "").trim().length; });
            return chars;
          };
          const candidates = Array.from(document.querySelectorAll("article, main, [role='main'], .post-content, .article-content, .entry-content"));
          let best = candidates.sort((a, b) => score(b) - score(a))[0];
          if (!best || score(best) < 200) best = document.body;
          if (!best) return false;

          const clone = best.cloneNode(true);
          clone.querySelectorAll("script, style, noscript, iframe, nav, aside, footer, form, button, svg, [aria-hidden='true']").forEach((n) => n.remove());
          clone.querySelectorAll("*").forEach((el) => {
            el.removeAttribute("style");
            el.removeAttribute("class");
          });

          const host = document.createElement("div");
          host.id = OVERLAY_ID;
          host.style.cssText = "position:fixed;inset:0;z-index:2147483647;overflow-y:auto;background:\(bg);color:\(fg);font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',Georgia,serif;-webkit-font-smoothing:antialiased;";

          const style = document.createElement("style");
          style.textContent = `
            #${OVERLAY_ID} .vr-wrap { max-width: 700px; margin: 0 auto; padding: 48px 28px 96px; font-size: 17px; line-height: 1.72; }
            #${OVERLAY_ID} h1.vr-title { font-size: 30px; line-height: 1.25; margin: 0 0 8px; font-weight: 700; letter-spacing: -0.02em; }
            #${OVERLAY_ID} .vr-meta { font-size: 13px; color: \(muted); margin-bottom: 28px; padding-bottom: 16px; border-bottom: 1px solid \(border); }
            #${OVERLAY_ID} a { color: \(link); text-decoration: underline; text-underline-offset: 2px; }
            #${OVERLAY_ID} img { max-width: 100%; height: auto; border-radius: 6px; margin: 16px 0; }
            #${OVERLAY_ID} pre, #${OVERLAY_ID} code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: \(codeBg); border-radius: 5px; }
            #${OVERLAY_ID} pre { padding: 14px 16px; overflow-x: auto; font-size: 13.5px; line-height: 1.5; }
            #${OVERLAY_ID} code { padding: 2px 5px; font-size: 0.9em; }
            #${OVERLAY_ID} blockquote { margin: 18px 0; padding: 4px 16px; border-left: 3px solid \(border); color: \(muted); }
            #${OVERLAY_ID} h2, #${OVERLAY_ID} h3 { margin-top: 28px; line-height: 1.3; }
            #${OVERLAY_ID} p { margin: 0 0 16px; }
          `;
          host.appendChild(style);

          const wrap = document.createElement("div");
          wrap.className = "vr-wrap";
          const h1 = document.createElement("h1");
          h1.className = "vr-title";
          h1.textContent = document.title || location.hostname;
          const meta = document.createElement("div");
          meta.className = "vr-meta";
          meta.textContent = location.hostname.replace(/^www\\./, "");
          wrap.appendChild(h1);
          wrap.appendChild(meta);
          wrap.appendChild(clone);
          host.appendChild(wrap);

          document.body.appendChild(host);
          document.documentElement.style.overflow = "hidden";
          return true;
        })();
        """
    }
}

// MARK: - SwiftUI WebView Host Container

/// Hosts the active `BrowserWKWebView` without recreating or tearing down background tabs.
struct BrowserWebViewContainer: NSViewRepresentable {
    let webView: BrowserWKWebView

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true
        attach(webView, to: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.subviews.first !== webView {
            for sub in nsView.subviews {
                sub.removeFromSuperview()
            }
            attach(webView, to: nsView)
        }
    }

    private func attach(_ wv: WKWebView, to host: NSView) {
        wv.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: host.topAnchor),
            wv.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}
