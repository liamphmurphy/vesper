import AppKit
import Network
import SwiftUI
import VesperCore
import WebKit

// MARK: - Isolated WebKit Factory & Content Blocker

/// Builds isolated `WKWebView` instances for the internal Browser.
///
/// Security boundary:
/// - Each Browser profile uses its own dedicated persistent `WKWebsiteDataStore(forIdentifier:)`,
///   completely separate from `WKWebsiteDataStore.default()` (which carries Vesper's session
///   cookie), `playgroundStore`, and every other profile.
/// - Private tabs use `WKWebsiteDataStore.nonPersistent()`.
/// - Uses a standard Safari User-Agent aligned with the host macOS WebKit version so OAuth
///   providers accept it without introducing a stale UA fingerprint mismatch.
/// - Enables `upgradeKnownHostsToHTTPS`, `isFraudulentWebsiteWarningEnabled`, optional Lockdown
///   Mode, and optional per-profile `proxyConfigurations`.
@MainActor
enum BrowserWebViewFactory {
    static let browsingStoreID = BrowserProfile.defaultDataStoreID
    static var safariUserAgent: String { BrowserUserAgent.safariUserAgent() }

    private static var profileStores: [UUID: WKWebsiteDataStore] = [:]

    /// Returns the cached persistent `WKWebsiteDataStore` isolated to a specific profile UUID.
    static func store(forProfileID id: UUID) -> WKWebsiteDataStore {
        if let existing = profileStores[id] {
            return existing
        }
        let created = WKWebsiteDataStore(forIdentifier: id)
        profileStores[id] = created
        return created
    }

    /// Default ("Personal") profile persistent store.
    static var persistentStore: WKWebsiteDataStore {
        store(forProfileID: browsingStoreID)
    }

    /// Converts a `BrowserProxyConfig` into WebKit/Network `ProxyConfiguration` entries.
    static func makeProxyConfigurations(for config: BrowserProxyConfig) -> [ProxyConfiguration] {
        guard config.isConfigured,
              let port = NWEndpoint.Port(rawValue: UInt16(config.port))
        else { return [] }
        let trimmedHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: port)
        switch config.mode {
        case .none:
            return []
        case .httpConnect:
            return [ProxyConfiguration(httpCONNECTProxy: endpoint)]
        case .socks5:
            return [ProxyConfiguration(socksv5Proxy: endpoint)]
        }
    }

    /// Applies (or clears) per-profile proxy routing on the profile's `WKWebsiteDataStore`.
    static func applyProxy(_ config: BrowserProxyConfig, toProfileID id: UUID) {
        let dataStore = store(forProfileID: id)
        dataStore.proxyConfigurations = makeProxyConfigurations(for: config)
    }

    static func makeWebView(
        isPrivate: Bool,
        profileDataStoreID: UUID = browsingStoreID,
        contentRuleLists: [WKContentRuleList] = [],
        adBlockPageScript: WKUserScript? = nil,
        webExtensionController: WKWebExtensionController? = nil,
        autofillMessageHandler: (any WKScriptMessageHandler)? = nil,
        adBlockMetricsHandler: (any WKScriptMessageHandler)? = nil,
        passkeyMessageHandler: (any WKScriptMessageHandler)? = nil,
        lockdownModeEnabled: Bool = false,
        proxyConfig: BrowserProxyConfig = .none
    ) -> BrowserWKWebView {
        let config = WKWebViewConfiguration()
        if isPrivate {
            let ephemeral = WKWebsiteDataStore.nonPersistent()
            if proxyConfig.applyToPrivateTabs {
                ephemeral.proxyConfigurations = makeProxyConfigurations(for: proxyConfig)
            }
            config.websiteDataStore = ephemeral
        } else {
            let persistent = store(forProfileID: profileDataStoreID)
            if proxyConfig.isConfigured {
                persistent.proxyConfigurations = makeProxyConfigurations(for: proxyConfig)
            }
            config.websiteDataStore = persistent
        }
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.isLockdownModeEnabled = lockdownModeEnabled
        if let webExtensionController {
            config.webExtensionController = webExtensionController
        }
        for ruleList in contentRuleLists {
            config.userContentController.add(ruleList)
        }
        if let adBlockMetricsHandler {
            let bridge = WKUserScript(
                source: BrowserAdBlockScripts.metricsBridgeScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            )
            config.userContentController.addUserScript(bridge)
            config.userContentController.add(
                adBlockMetricsHandler,
                contentWorld: .defaultClient,
                name: BrowserAdBlockScripts.metricsHandlerName
            )
        }
        if let passkeyMessageHandler {
            config.userContentController.addUserScript(WKUserScript(
                source: BrowserPasskeyBridgeScripts.bridgeScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            config.userContentController.addUserScript(WKUserScript(
                source: BrowserPasskeyBridgeScripts.pageObserverScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
            config.userContentController.add(
                passkeyMessageHandler,
                contentWorld: .defaultClient,
                name: BrowserPasskeyBridgeScripts.handlerName
            )
        }
        if let adBlockPageScript {
            config.userContentController.addUserScript(adBlockPageScript)
        }
        if let autofillMessageHandler {
            let script = WKUserScript(
                source: BrowserAutofillScripts.detectorScriptSource,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false,
                in: .defaultClient
            )
            config.userContentController.addUserScript(script)
            config.userContentController.add(
                autofillMessageHandler,
                contentWorld: .defaultClient,
                name: BrowserAutofillScripts.messageHandlerName
            )
        }
        let webView = BrowserWKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        return webView
    }
}

/// Detects WebAuthn / Passkey ceremonies that fail inside embedded `WKWebView` so the tab can offer
/// a one-click "Open in Safari" handoff, without exposing `webkit.messageHandlers` to page scripts.
enum BrowserPasskeyBridgeScripts {
    static let handlerName = "vesperPasskey"

    static let bridgeScriptSource = """
    (() => {
      if (window.__vesperPasskeyBridgeInstalled) return;
      window.__vesperPasskeyBridgeInstalled = true;
      window.addEventListener("__vesper_passkey_failed__", () => {
        try {
          window.webkit?.messageHandlers?.vesperPasskey?.postMessage({ type: "passkeyFailed" });
        } catch (_) {}
      }, true);
    })();
    """

    static let pageObserverScriptSource = """
    (() => {
      if (window.__vesperPasskeyObserverInstalled) return;
      window.__vesperPasskeyObserverInstalled = true;
      try {
        const creds = navigator.credentials;
        if (!creds) return;
        for (const method of ["get", "create"]) {
          const orig = creds[method];
          if (typeof orig !== "function") continue;
          creds[method] = function(options) {
            const p = orig.apply(this, arguments);
            if (options && options.publicKey && p && typeof p.catch === "function") {
              p.catch((err) => {
                const name = err && err.name ? String(err.name) : "";
                if (name === "NotAllowedError" || name === "SecurityError" || name === "NotSupportedError") {
                  try { window.dispatchEvent(new Event("__vesper_passkey_failed__")); } catch (_) {}
                }
              });
            }
            return p;
          };
        }
      } catch (_) {}
    })();
    """
}

// MARK: - Weak Script Message Proxy (Prevents WKUserContentController Retain Cycles)

@MainActor
final class BrowserScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let handler: @MainActor (WKScriptMessage) -> Void

    init(handler: @escaping @MainActor (WKScriptMessage) -> Void) {
        self.handler = handler
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler(message)
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
        var onCaptureRegionScreenshot: () -> Void
        var onAutofillKeychain: () -> Void
        var onGeneratePassword: () -> Void
        var onOpenInSplitView: () -> Void
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

        let regionItem = NSMenuItem(title: "Capture Region Screenshot…", action: #selector(handleCaptureRegion), keyEquivalent: "")
        regionItem.target = self
        regionItem.image = NSImage(systemSymbolName: "crop", accessibilityDescription: nil)
        menu.addItem(regionItem)

        let quoteItem = NSMenuItem(title: "Copy Markdown Quote", action: #selector(handleCopyMarkdownQuote), keyEquivalent: "")
        quoteItem.target = self
        quoteItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        menu.addItem(quoteItem)

        let saveLinkItem = NSMenuItem(title: "Save Link to Reading List", action: #selector(handleSaveLink), keyEquivalent: "")
        saveLinkItem.target = self
        saveLinkItem.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        menu.addItem(saveLinkItem)

        menu.addItem(.separator())

        let autofillItem = NSMenuItem(title: "AutoFill from Keychain…", action: #selector(handleAutofill), keyEquivalent: "")
        autofillItem.target = self
        autofillItem.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        menu.addItem(autofillItem)

        let genPwItem = NSMenuItem(title: "Generate Strong Password", action: #selector(handleGeneratePassword), keyEquivalent: "")
        genPwItem.target = self
        genPwItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        menu.addItem(genPwItem)

        let splitItem = NSMenuItem(title: "Open in Split View", action: #selector(handleOpenInSplit), keyEquivalent: "")
        splitItem.target = self
        splitItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        menu.addItem(splitItem)

        let safariItem = NSMenuItem(title: "Open Page in Safari", action: #selector(handleOpenInSafari), keyEquivalent: "")
        safariItem.target = self
        safariItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        menu.addItem(safariItem)
    }

    @objc private func handleAskPersona() { contextCallbacks?.onAskPersona() }
    @objc private func handleClipToKnowledge() { contextCallbacks?.onClipToKnowledge() }
    @objc private func handleScreenshotToNotes() { contextCallbacks?.onScreenshotToNotes() }
    @objc private func handleCaptureRegion() { contextCallbacks?.onCaptureRegionScreenshot() }
    @objc private func handleCopyMarkdownQuote() { contextCallbacks?.onCopyMarkdownQuote() }
    @objc private func handleSaveLink() { contextCallbacks?.onSaveLink() }
    @objc private func handleAutofill() { contextCallbacks?.onAutofillKeychain() }
    @objc private func handleGeneratePassword() { contextCallbacks?.onGeneratePassword() }
    @objc private func handleOpenInSplit() { contextCallbacks?.onOpenInSplitView() }
    @objc private func handleOpenInSafari() { contextCallbacks?.onOpenInSafari() }
}

// MARK: - OAuth / JS Popup Window Controller

/// Hosts small JavaScript popups (e.g. Google/GitHub OAuth sign-in flows) using the exact
/// `WKWebViewConfiguration` WebKit provides so cookies and `window.opener` stay intact,
/// while displaying a read-only origin + TLS security header bar so popups cannot spoof their host.
@MainActor
final class BrowserPopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    private let onClose: () -> Void
    private let securityIconView = NSImageView()
    private let originLabel = NSTextField(labelWithString: "")
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures, onClose: @escaping () -> Void) {
        self.onClose = onClose
        configuration.upgradeKnownHostsToHTTPS = true
        let width = max(420, min(960, CGFloat(windowFeatures.width?.doubleValue ?? 560)))
        let height = max(480, min(840, CGFloat(windowFeatures.height?.doubleValue ?? 680)))
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.customUserAgent = BrowserWebViewFactory.safariUserAgent
        wv.isInspectable = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.webView = wv

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let originBar = NSVisualEffectView()
        originBar.material = .titlebar
        originBar.state = .active
        originBar.translatesAutoresizingMaskIntoConstraints = false

        securityIconView.translatesAutoresizingMaskIntoConstraints = false
        securityIconView.imageScaling = .scaleProportionallyDown

        originLabel.translatesAutoresizingMaskIntoConstraints = false
        originLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        originLabel.textColor = .secondaryLabelColor
        originLabel.lineBreakMode = .byTruncatingMiddle

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        originBar.addSubview(securityIconView)
        originBar.addSubview(originLabel)
        originBar.addSubview(divider)
        container.addSubview(originBar)
        container.addSubview(wv)

        NSLayoutConstraint.activate([
            originBar.topAnchor.constraint(equalTo: container.topAnchor),
            originBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            originBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            originBar.heightAnchor.constraint(equalToConstant: 28),

            securityIconView.leadingAnchor.constraint(equalTo: originBar.leadingAnchor, constant: 10),
            securityIconView.centerYAnchor.constraint(equalTo: originBar.centerYAnchor),
            securityIconView.widthAnchor.constraint(equalToConstant: 13),
            securityIconView.heightAnchor.constraint(equalToConstant: 13),

            originLabel.leadingAnchor.constraint(equalTo: securityIconView.trailingAnchor, constant: 6),
            originLabel.trailingAnchor.constraint(lessThanOrEqualTo: originBar.trailingAnchor, constant: -10),
            originLabel.centerYAnchor.constraint(equalTo: originBar.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: originBar.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: originBar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: originBar.bottomAnchor),

            wv.topAnchor.constraint(equalTo: originBar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sign In"
        panel.isReleasedWhenClosed = false
        panel.contentView = container
        panel.center()
        super.init(window: panel)
        panel.delegate = self
        wv.uiDelegate = self
        wv.navigationDelegate = self

        observations = [
            wv.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateOriginBar() }
            },
            wv.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateOriginBar() }
            },
        ]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateOriginBar() {
        let urlString = webView.url?.absoluteString ?? ""
        let idn = BrowserIDNGuard.inspect(urlString: urlString)
        let sec = BrowserHTTPSGuard.connectionSecurity(
            urlString: urlString,
            hasOnlySecureContent: webView.hasOnlySecureContent,
            tlsError: nil
        )
        let scheme = webView.url?.scheme?.lowercased() ?? ""
        if idn.displayHost.isEmpty {
            originLabel.stringValue = urlString.isEmpty ? "Loading…" : urlString
        } else {
            originLabel.stringValue = scheme.isEmpty ? idn.displayHost : "\(scheme)://\(idn.displayHost)"
        }
        if idn.isSuspiciousIDN || sec.isWarning {
            securityIconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Security Warning")
            securityIconView.contentTintColor = .systemOrange
            originLabel.textColor = .systemOrange
        } else if sec == .secure {
            securityIconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Connection")
            securityIconView.contentTintColor = .secondaryLabelColor
            originLabel.textColor = .secondaryLabelColor
        } else {
            securityIconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            securityIconView.contentTintColor = .tertiaryLabelColor
            originLabel.textColor = .secondaryLabelColor
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateOriginBar()
        if let title = webView.title, !title.isEmpty {
            window?.title = title
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        observations.removeAll()
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        onClose()
    }
}

// MARK: - Ephemeral In-Memory Favicon Cache

/// Fetches site favicons over an ephemeral cookie-free `URLSession` and caches decoded `NSImage`s
/// per host in memory so tabs, bookmarks, and the Start Page show crisp site icons.
@MainActor
final class BrowserFaviconCache {
    static let shared = BrowserFaviconCache()

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    private let maxEntries = 180

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 8
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    func cachedIcon(for urlString: String) -> NSImage? {
        guard let host = BrowserPageGuard.normalizeHost(urlString) else { return nil }
        return cache[host]
    }

    func fetch(iconURLString: String?, pageURLString: String) async -> NSImage? {
        guard let host = BrowserPageGuard.normalizeHost(pageURLString) else { return nil }
        if let existing = cache[host] { return existing }
        guard !inFlight.contains(host) else { return nil }

        guard let pageURL = URL(string: pageURLString), BrowserURLResolver.isWebURL(pageURL) else { return nil }
        var candidates: [URL] = []
        if let iconURLString, !iconURLString.isEmpty,
           let parsed = URL(string: iconURLString, relativeTo: pageURL)?.absoluteURL,
           BrowserURLResolver.isWebURL(parsed)
        {
            candidates.append(parsed)
        }
        if var comps = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) {
            comps.path = "/favicon.ico"
            comps.query = nil
            comps.fragment = nil
            if let fallback = comps.url, !candidates.contains(fallback) {
                candidates.append(fallback)
            }
        }
        guard !candidates.isEmpty else { return nil }

        inFlight.insert(host)
        defer { inFlight.remove(host) }

        for candidate in candidates {
            var req = URLRequest(url: candidate)
            req.setValue(BrowserWebViewFactory.safariUserAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty, data.count <= 262_144,
                  let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0
            else { continue }

            store(image, for: host)
            return image
        }
        return nil
    }

    private func store(_ image: NSImage, for host: String) {
        if cache[host] == nil {
            order.append(host)
            if order.count > maxEntries {
                let oldest = order.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        cache[host] = image
    }
}

// MARK: - Page Extraction, Media Mute, Favicon & Reader Mode Scripts

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

    /// Extracts the highest-priority favicon URL declared in `<head>`.
    static let faviconURLJS = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel*="icon"]'));
      if (!links.length) return "";
      const scored = links
        .filter((l) => l.href)
        .sort((a, b) => {
          const score = (el) => {
            const rel = (el.rel || "").toLowerCase();
            if (rel.includes("apple-touch-icon")) return 2;
            if (rel === "icon" || rel === "shortcut icon") return 3;
            return 1;
          };
          return score(b) - score(a);
        });
      return scored[0] ? scored[0].href : "";
    })();
    """

    /// Mutes or unmutes all `<audio>` and `<video>` elements in the document and watches for new
    /// media elements while muted.
    static func muteMediaJS(muted: Bool) -> String {
        let flag = muted ? "true" : "false"
        return """
        (() => {
          window.__vesperTabMuted = \(flag);
          const apply = () => {
            document.querySelectorAll("audio, video").forEach((el) => {
              el.muted = window.__vesperTabMuted;
            });
          };
          apply();
          if (window.__vesperTabMuted && !window.__vesperMuteObserver && document.documentElement) {
            window.__vesperMuteObserver = new MutationObserver(() => {
              if (window.__vesperTabMuted) apply();
            });
            window.__vesperMuteObserver.observe(document.documentElement, { childList: true, subtree: true });
          } else if (!window.__vesperTabMuted && window.__vesperMuteObserver) {
            window.__vesperMuteObserver.disconnect();
            window.__vesperMuteObserver = null;
          }
          return true;
        })();
        """
    }

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

// MARK: - SwiftUI WebView Host & Extension Popup Anchor

/// Hosts a `BrowserWKWebView` without recreating or tearing down background tabs.
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

/// Invisible NSView bridge used to anchor `WKWebExtension.Action.popupPopover` to the omnibox bar.
struct BrowserExtensionPopupAnchor: NSViewRepresentable {
    let onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onAttach(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onAttach(nsView) }
    }
}

// MARK: - Permission-Free Region-Crop Screenshot Overlay

enum BrowserRegionCaptureDestination {
    case knowledge
    case chat
    case clipboard
}

/// Interactive drag-to-crop overlay placed directly over the active `WKWebView` to capture a
/// cropped region via `WKSnapshotConfiguration.rect` without macOS Screen Recording permissions.
struct BrowserRegionCaptureOverlay: View {
    let onCapture: (CGRect, BrowserRegionCaptureDestination) -> Void
    let onCancel: () -> Void

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var finalizedRect: CGRect?

    private var activeRect: CGRect? {
        if let finalizedRect { return finalizedRect }
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        return (rect.width >= 12 && rect.height >= 12) ? rect : nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Dimmed scrim with cutout around the selected region.
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.42)))
                    if let rect = activeRect {
                        ctx.blendMode = .destinationOut
                        ctx.fill(Path(rect), with: .color(.white))
                    }
                }
                .compositingGroup()
                .allowsHitTesting(false)

                if let rect = activeRect {
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .background(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)

                    Text("\(Int(rect.width)) × \(Int(rect.height))")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .offset(x: rect.minX, y: max(8, rect.minY - 24))
                        .allowsHitTesting(false)
                }

                // Instruction banner at top center.
                HStack(spacing: 10) {
                    Image(systemName: "crop")
                        .font(.system(size: 12))
                    Text(finalizedRect == nil ? "Drag to select a region to capture" : "Choose where to send this capture")
                        .font(.system(size: 12, weight: .medium))
                    if let rect = finalizedRect {
                        Button("To Knowledge") { onCapture(rect, .knowledge) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("To Chat") { onCapture(rect, .chat) }
                            .controlSize(.small)
                        Button("Copy") { onCapture(rect, .clipboard) }
                            .controlSize(.small)
                        Button("Retake") {
                            finalizedRect = nil
                            dragStart = nil
                            dragCurrent = nil
                        }
                        .controlSize(.small)
                    }
                    Button("Cancel") { onCancel() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if finalizedRect != nil { finalizedRect = nil }
                        dragStart = clampPoint(value.startLocation, in: geo.size)
                        dragCurrent = clampPoint(value.location, in: geo.size)
                    }
                    .onEnded { value in
                        let start = clampPoint(value.startLocation, in: geo.size)
                        let end = clampPoint(value.location, in: geo.size)
                        let rect = CGRect(
                            x: min(start.x, end.x),
                            y: min(start.y, end.y),
                            width: abs(end.x - start.x),
                            height: abs(end.y - start.y)
                        )
                        if rect.width >= 12 && rect.height >= 12 {
                            finalizedRect = rect
                        } else {
                            dragStart = nil
                            dragCurrent = nil
                        }
                    }
            )
        }
        .onExitCommand(perform: onCancel)
    }

    private func clampPoint(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), size.width), y: min(max(0, p.y), size.height))
    }
}
