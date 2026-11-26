import AppKit
import Observation
import Security
import SecurityInterface
import VesperCore
import WebKit

/// Live state and WebKit delegates for one internal Browser tab.
@MainActor
@Observable
final class BrowserTabSession: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let profileID: UUID
    let isPrivate: Bool
    var isPinned: Bool
    var groupId: UUID?
    var isMuted: Bool
    var urlString: String
    var title: String
    var isLoading: Bool = false
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var hasOnlySecureContent: Bool = false
    var isReaderMode: Bool = false
    var isAudioPlaying: Bool = false
    var loadError: String?
    var tlsErrorMessage: String?
    var pendingHTTPSFallbackURL: URL?
    var passkeyFallbackSuggested: Bool = false
    var certificateSummary: BrowserCertificateSummary?
    var cameraCaptureState: WKMediaCaptureState = .none
    var microphoneCaptureState: WKMediaCaptureState = .none
    var trackingParamsStrippedCount: Int = 0
    var zoom: Double = 1.0
    var favicon: NSImage?
    var hasLoginForm: Bool = false
    var pendingCredentialSave: BrowserPendingCredentialSave?
    var adBlockInterventionsCount: Int = 0

    /// Active live share for this tab (backed by `/api/v1/browser-extension/shares`).
    var activeShare: BrowserShare?
    var shareStartURL: String?
    var shareError: String?

    @ObservationIgnored let webView: BrowserWKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var popups: [BrowserPopupWindowController] = []
    @ObservationIgnored private var snapshotDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var appliedRuleLists: [WKContentRuleList] = []
    @ObservationIgnored private var appliedAdBlockPageScript: WKUserScript?
    @ObservationIgnored private var isAdBlockAttached: Bool = false
    @ObservationIgnored private var inFlightHTTPSUpgradeOriginalURL: URL?
    @ObservationIgnored private var inFlightHTTPSUpgradeTargetURL: URL?
    @ObservationIgnored private var lastStrippedURL: String?

    @ObservationIgnored var onOpenNewTab: ((URL, Bool) -> Void)?
    @ObservationIgnored var onPageCommitted: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onPageFinished: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onTabShouldClose: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onSnapshotDue: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onStopShare: ((BrowserTabSession, String) -> Void)?
    @ObservationIgnored var onCredentialsSubmitted: ((BrowserTabSession, String, String, String) -> Void)?
    @ObservationIgnored var onExtensionPropertiesChanged: ((BrowserTabSession, WKWebExtension.TabChangedProperties) -> Void)?
    @ObservationIgnored var neverShareProvider: (() -> BrowserNeverShareLists)?
    @ObservationIgnored var hostZoomProvider: ((String) -> Double?)?
    @ObservationIgnored var adBlockActiveProvider: ((String) -> Bool)?
    @ObservationIgnored var securityConfigProvider: (() -> BrowserSecurityConfig)?
    @ObservationIgnored var httpsOnlyExceptionsProvider: (() -> [String])?
    @ObservationIgnored var lockdownActiveProvider: ((String) -> Bool)?
    @ObservationIgnored var javascriptAllowedProvider: ((String) -> Bool)?
    @ObservationIgnored var sitePermissionProvider: ((String, BrowserPermissionKind) -> BrowserPermissionSetting)?
    @ObservationIgnored var onSitePermissionChanged: ((String, BrowserPermissionKind, BrowserPermissionSetting) -> Void)?

    var hasLoadedPage: Bool { !urlString.isEmpty }

    var hostSecurityDisplay: BrowserHostSecurityDisplay {
        BrowserIDNGuard.inspect(urlString: urlString)
    }

    var connectionSecurity: BrowserConnectionSecurity {
        BrowserHTTPSGuard.connectionSecurity(
            urlString: urlString,
            hasOnlySecureContent: hasOnlySecureContent,
            tlsError: tlsErrorMessage
        )
    }

    var isCapturingMedia: Bool {
        cameraCaptureState == .active || microphoneCaptureState == .active
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let idn = hostSecurityDisplay
        if idn.isSuspiciousIDN && !idn.displayHost.isEmpty { return idn.displayHost }
        let host = BrowserURLResolver.displayHost(for: urlString)
        return host.isEmpty ? (isPrivate ? "Private Tab" : "New Tab") : host
    }

    var displayHost: String {
        if urlString.lowercased().hasPrefix("webkit-extension://") {
            return "Extension"
        }
        let idn = hostSecurityDisplay
        if idn.isSuspiciousIDN && !idn.displayHost.isEmpty {
            return idn.displayHost
        }
        return BrowserURLResolver.displayHost(for: urlString)
    }

    private static func isLoadableTabURL(_ url: URL) -> Bool {
        BrowserURLResolver.isWebURL(url) || url.scheme?.lowercased() == "webkit-extension"
    }

    var record: BrowserTabRecord {
        BrowserTabRecord(
            id: id,
            url: urlString,
            title: displayTitle,
            isPinned: isPinned,
            isPrivate: isPrivate,
            zoom: zoom,
            groupId: groupId,
            isMuted: isMuted
        )
    }

    init(
        record: BrowserTabRecord,
        profileID: UUID = BrowserProfile.defaultProfileID,
        profileDataStoreID: UUID = BrowserProfile.defaultDataStoreID,
        contentRuleLists: [WKContentRuleList] = [],
        adBlockPageScript: WKUserScript? = nil,
        adBlockActive: Bool = true,
        webExtensionController: WKWebExtensionController? = nil,
        lockdownModeEnabled: Bool = false,
        proxyConfig: BrowserProxyConfig = .none
    ) {
        self.id = record.id
        self.profileID = profileID
        self.isPrivate = record.isPrivate
        self.isPinned = record.isPinned
        self.groupId = record.groupId
        self.isMuted = record.isMuted
        self.urlString = record.url
        self.title = record.title
        self.zoom = record.zoom
        self.favicon = BrowserFaviconCache.shared.cachedIcon(for: record.url)
        self.appliedRuleLists = contentRuleLists
        self.appliedAdBlockPageScript = adBlockPageScript
        self.isAdBlockAttached = adBlockActive

        var weakSessionBox: WeakTabSessionBox?
        let box = WeakTabSessionBox()
        weakSessionBox = box
        let autofillProxy = BrowserScriptMessageProxy { message in
            weakSessionBox?.session?.handleAutofillMessage(message.body)
        }
        let adBlockMetricsProxy = BrowserScriptMessageProxy { _ in
            weakSessionBox?.session?.adBlockInterventionsCount += 1
        }
        let passkeyProxy = BrowserScriptMessageProxy { _ in
            weakSessionBox?.session?.passkeyFallbackSuggested = true
        }
        self.webView = BrowserWebViewFactory.makeWebView(
            isPrivate: record.isPrivate,
            profileDataStoreID: profileDataStoreID,
            contentRuleLists: adBlockActive ? contentRuleLists : [],
            adBlockPageScript: adBlockActive ? adBlockPageScript : nil,
            webExtensionController: webExtensionController,
            autofillMessageHandler: autofillProxy,
            adBlockMetricsHandler: adBlockMetricsProxy,
            passkeyMessageHandler: passkeyProxy,
            lockdownModeEnabled: lockdownModeEnabled,
            proxyConfig: proxyConfig
        )
        super.init()
        box.session = self

        webView.navigationDelegate = self
        webView.uiDelegate = self
        if zoom != 1.0 { webView.pageZoom = zoom }

        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let next = wv.url?.absoluteString, next != "about:blank" {
                        self.urlString = next
                        self.favicon = BrowserFaviconCache.shared.cachedIcon(for: next)
                        self.handleURLChanged(next)
                        self.onExtensionPropertiesChanged?(self, [.URL])
                    }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let next = wv.title, !next.isEmpty {
                        self.title = next
                        self.onStateChanged?()
                        self.onExtensionPropertiesChanged?(self, [.title])
                    }
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = wv.isLoading
                    self.onExtensionPropertiesChanged?(self, [.loading])
                }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = wv.hasOnlySecureContent }
            },
            webView.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.cameraCaptureState = wv.cameraCaptureState }
            },
            webView.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.microphoneCaptureState = wv.microphoneCaptureState }
            },
        ]

        if let initialURL = URL(string: record.url), Self.isLoadableTabURL(initialURL) {
            webView.load(URLRequest(url: initialURL))
        }
    }

    // MARK: Navigation

    func load(_ url: URL) {
        loadError = nil
        tlsErrorMessage = nil
        pendingHTTPSFallbackURL = nil
        passkeyFallbackSuggested = false
        inFlightHTTPSUpgradeOriginalURL = nil
        inFlightHTTPSUpgradeTargetURL = nil
        isReaderMode = false
        hasLoginForm = false
        adBlockInterventionsCount = 0

        var targetURL = url
        if securityConfigProvider?().stripTrackingParameters ?? true {
            let stripped = BrowserTrackingParamStripper.strip(from: targetURL)
            if stripped.removedCount > 0 {
                targetURL = stripped.url
                trackingParamsStrippedCount += stripped.removedCount
                lastStrippedURL = targetURL.absoluteString
            }
        }
        urlString = targetURL.absoluteString
        favicon = BrowserFaviconCache.shared.cachedIcon(for: targetURL.absoluteString)
        syncAdBlockForURL(targetURL.absoluteString)
        if let host = targetURL.host, let savedZoom = hostZoomProvider?(host) {
            zoom = savedZoom
            webView.pageZoom = savedZoom
        }
        webView.load(URLRequest(url: targetURL))
        onStateChanged?()
    }

    func stopMediaCapture() {
        webView.setCameraCaptureState(.none)
        webView.setMicrophoneCaptureState(.none)
    }

    func showSystemCertificatePanel() {
        guard let trust = webView.serverTrust else { return }
        if let window = webView.window {
            SFCertificatePanel.shared().beginSheet(
                for: window,
                modalDelegate: nil,
                didEnd: nil,
                contextInfo: nil,
                trust: trust,
                showGroup: true
            )
        } else {
            SFCertificatePanel.shared().runModal(for: trust, showGroup: true)
        }
    }

    func refreshCertificateSummary() {
        guard let trust = webView.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            certificateSummary = nil
            return
        }
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? displayHost
        var issuer = ""
        var validFrom: Date?
        var validUntil: Date?

        let keys: [CFString] = [
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
        ]
        if let values = SecCertificateCopyValues(leaf, keys as CFArray, nil) as? [String: Any] {
            if let issuerDict = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
               let entries = issuerDict[kSecPropertyKeyValue as String] as? [[String: Any]]
            {
                let cn = entries.first(where: { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDCommonName as String) })?[kSecPropertyKeyValue as String] as? String
                let org = entries.first(where: { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDOrganizationName as String) })?[kSecPropertyKeyValue as String] as? String
                issuer = cn ?? org ?? ""
            }
            if let fromDict = values[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any] {
                if let num = fromDict[kSecPropertyKeyValue as String] as? Double {
                    validFrom = Date(timeIntervalSinceReferenceDate: num)
                } else if let date = fromDict[kSecPropertyKeyValue as String] as? Date {
                    validFrom = date
                }
            }
            if let toDict = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any] {
                if let num = toDict[kSecPropertyKeyValue as String] as? Double {
                    validUntil = Date(timeIntervalSinceReferenceDate: num)
                } else if let date = toDict[kSecPropertyKeyValue as String] as? Date {
                    validUntil = date
                }
            }
        }
        certificateSummary = BrowserCertificateSummary(
            subject: subject,
            issuer: issuer,
            validFrom: validFrom,
            validUntil: validUntil,
            chainCount: chain.count,
            isTrusted: tlsErrorMessage == nil
        )
    }

    func reload(fromOrigin: Bool = false) {
        loadError = nil
        isReaderMode = false
        if webView.url != nil {
            if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        } else if let url = URL(string: urlString), Self.isLoadableTabURL(url) {
            webView.load(URLRequest(url: url))
        }
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        if webView.canGoBack {
            isReaderMode = false
            webView.goBack()
        }
    }

    func goForward() {
        if webView.canGoForward {
            isReaderMode = false
            webView.goForward()
        }
    }

    func setZoom(_ value: Double) {
        let clamped = min(3.0, max(0.3, (value * 100).rounded() / 100))
        zoom = clamped
        webView.pageZoom = clamped
        onStateChanged?()
        onExtensionPropertiesChanged?(self, [.zoomFactor])
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyMuteToPage()
        onStateChanged?()
        onExtensionPropertiesChanged?(self, [.muted])
    }

    private func applyMuteToPage() {
        guard hasLoadedPage else { return }
        let js = BrowserPageScripts.muteMediaJS(muted: isMuted)
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Applies compiled multi-list `WKContentRuleList`s and the Phase B page-world scriptlet runtime.
    /// Per-site allowlisting toggles attach/detach immediately with zero recompilation.
    func applyAdBlockState(
        ruleLists: [WKContentRuleList],
        pageScript: WKUserScript?,
        activeForCurrentURL: Bool
    ) {
        appliedRuleLists = ruleLists
        appliedAdBlockPageScript = pageScript
        isAdBlockAttached = activeForCurrentURL
        syncContentController(attachAdBlock: activeForCurrentURL)
    }

    /// Instantly attaches or detaches pre-compiled ad-block rules & scriptlets when navigating
    /// between protected and per-site allowlisted hosts.
    func syncAdBlockForURL(_ urlString: String) {
        let shouldAttach = adBlockActiveProvider?(urlString) ?? true
        guard shouldAttach != isAdBlockAttached else { return }
        isAdBlockAttached = shouldAttach
        syncContentController(attachAdBlock: shouldAttach)
    }

    private func syncContentController(attachAdBlock: Bool) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        if attachAdBlock {
            for ruleList in appliedRuleLists {
                ucc.add(ruleList)
            }
        }
        // Rebuild user scripts cleanly so AutoFill, passkey observer & metrics bridge scripts are always preserved.
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(
            source: BrowserAdBlockScripts.metricsBridgeScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
        ucc.addUserScript(WKUserScript(
            source: BrowserPasskeyBridgeScripts.bridgeScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        ucc.addUserScript(WKUserScript(
            source: BrowserPasskeyBridgeScripts.pageObserverScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        ucc.addUserScript(WKUserScript(
            source: BrowserAutofillScripts.detectorScriptSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
        if attachAdBlock, let pageScript = appliedAdBlockPageScript {
            ucc.addUserScript(pageScript)
        }
    }

    func toggleReaderMode(darkMode: Bool) async {
        guard hasLoadedPage else { return }
        let js = BrowserPageScripts.toggleReaderModeJS(darkMode: darkMode)
        if let active = (try? await webView.evaluateJavaScript(js)) as? Bool {
            isReaderMode = active
            onExtensionPropertiesChanged?(self, [.readerMode])
        }
    }

    func refreshMediaState() {
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                let playing = (state == .playing)
                if self.isAudioPlaying != playing {
                    self.isAudioPlaying = playing
                    self.onExtensionPropertiesChanged?(self, [.playingAudio])
                }
            }
        }
    }

    private func refreshFavicon() {
        guard hasLoadedPage else { return }
        let pageURL = urlString
        faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let rawIcon = (try? await self.webView.evaluateJavaScript(BrowserPageScripts.faviconURLJS)) as? String
            guard !Task.isCancelled, self.urlString == pageURL else { return }
            if let img = await BrowserFaviconCache.shared.fetch(iconURLString: rawIcon, pageURLString: pageURL) {
                guard !Task.isCancelled, self.urlString == pageURL else { return }
                self.favicon = img
            }
        }
    }

    private func handleAutofillMessage(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "formState":
            hasLoginForm = (dict["hasLoginForm"] as? Bool) ?? false
        case "credentialsSubmitted":
            let url = (dict["url"] as? String) ?? urlString
            let username = (dict["username"] as? String) ?? ""
            let password = (dict["password"] as? String) ?? ""
            guard !username.isEmpty, !password.isEmpty else { return }
            onCredentialsSubmitted?(self, url, username, password)
        default:
            break
        }
    }

    func teardown() {
        snapshotDebounceTask?.cancel()
        snapshotDebounceTask = nil
        faviconTask?.cancel()
        faviconTask = nil
        for popup in popups { popup.window?.close() }
        popups.removeAll()
        observations.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserAutofillScripts.messageHandlerName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserAdBlockScripts.metricsHandlerName,
            contentWorld: .defaultClient
        )
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserPasskeyBridgeScripts.handlerName,
            contentWorld: .defaultClient
        )
        webView.contextCallbacks = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    // MARK: Page Extraction & Permission-Free Snapshots

    struct ExtractedPage: Sendable {
        var url: String
        var title: String
        var text: String
        var selection: String
    }

    func extractPageContent() async -> ExtractedPage {
        let fallbackURL = webView.url?.absoluteString ?? urlString
        let fallbackTitle = webView.title ?? title
        guard let raw = (try? await webView.evaluateJavaScript(BrowserPageScripts.extractPageJS)) as? [String: Any] else {
            return ExtractedPage(url: fallbackURL, title: fallbackTitle, text: "", selection: "")
        }
        let url = (raw["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackURL
        let pageTitle = (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let rawText = raw["text"] as? String ?? ""
        let rawSelection = raw["selection"] as? String ?? ""
        return ExtractedPage(
            url: url,
            title: pageTitle,
            text: BrowserPageGuard.redactCardNumbers(rawText),
            selection: BrowserPageGuard.redactCardNumbers(rawSelection)
        )
    }

    func extractSelection() async -> String {
        let raw = (try? await webView.evaluateJavaScript(BrowserPageScripts.selectionOnlyJS)) as? String ?? ""
        return BrowserPageGuard.redactCardNumbers(raw)
    }

    /// Captures the visible viewport (or a cropped sub-rect) as a PNG using `WKWebView.takeSnapshot`
    /// (requires zero macOS Screen Recording permissions).
    func captureScreenshotPNG(rect: CGRect? = nil) async -> Data? {
        let config = WKSnapshotConfiguration()
        if let rect, rect.width > 1, rect.height > 1 {
            config.rect = rect
        }
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Captures the visible viewport as a base64 JPEG scaled to fit the server's share snapshot limit.
    func captureSnapshotJPEGBase64(maxWidth: CGFloat = 1280, maxBytes: Int = 1_400_000) async -> String? {
        let config = WKSnapshotConfiguration()
        let bounds = webView.bounds
        if bounds.width > maxWidth, bounds.width > 0 {
            config.snapshotWidth = NSNumber(value: Double(maxWidth))
        }
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }

        for quality in [0.7, 0.55, 0.4] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= maxBytes
            {
                return jpeg.base64EncodedString()
            }
        }
        return nil
    }

    /// Renders the full web page to PDF data via WebKit's native `createPDF`.
    func captureFullPagePDF() async -> Data? {
        try? await webView.pdf(configuration: WKPDFConfiguration())
    }

    // MARK: Share Lifecycle

    private func handleURLChanged(_ nextURL: String) {
        guard let share = activeShare else { return }
        let lists = neverShareProvider?() ?? BrowserNeverShareLists()
        let check = BrowserPageGuard.shareablePage(url: nextURL, isPrivate: isPrivate, neverShare: lists)
        if !check.ok {
            onStopShare?(self, "never_share")
            return
        }
        if share.until == "page", let start = shareStartURL, !BrowserPageGuard.samePage(start, nextURL) {
            onStopShare?(self, "left_page")
            return
        }
        scheduleSnapshotUpdate()
    }

    func scheduleSnapshotUpdate() {
        guard activeShare != nil else { return }
        snapshotDebounceTask?.cancel()
        snapshotDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.activeShare != nil else { return }
            self.onSnapshotDue?(self)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let secConfig = securityConfigProvider?() ?? .default

        if scheme == "mailto" || scheme == "tel" {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        if BrowserHTTPSGuard.shouldBlockNavigation(
            url: url,
            isMainFrame: isMainFrame,
            blockTopLevelData: secConfig.blockTopLevelDataNavigations
        ) {
            return (.cancel, preferences)
        }
        if scheme == "about" || scheme == "blob" || scheme == "data" || scheme == "webkit-extension" {
            return (.allow, preferences)
        }
        guard scheme == "http" || scheme == "https" else {
            return (.cancel, preferences)
        }

        // Apply per-site Lockdown Mode and JavaScript preferences on main-frame navigations.
        if isMainFrame {
            preferences.isLockdownModeEnabled = lockdownActiveProvider?(url.absoluteString) ?? secConfig.lockdownModeEnabled
            preferences.allowsContentJavaScript = javascriptAllowedProvider?(url.absoluteString) ?? true
        }

        // Middle-click / Cmd-click / target="_blank" links open in a new browser tab.
        if navigationAction.targetFrame == nil {
            onOpenNewTab?(url, isPrivate)
            return (.cancel, preferences)
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command)
        {
            onOpenNewTab?(url, isPrivate)
            return (.cancel, preferences)
        }

        // Strip cross-site tracking query parameters on top-level GET navigations.
        if isMainFrame,
           secConfig.stripTrackingParameters,
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           lastStrippedURL != url.absoluteString
        {
            let stripped = BrowserTrackingParamStripper.strip(from: url)
            if stripped.removedCount > 0 {
                trackingParamsStrippedCount += stripped.removedCount
                lastStrippedURL = stripped.url.absoluteString
                webView.load(URLRequest(url: stripped.url))
                return (.cancel, preferences)
            }
        }

        // Strict HTTPS-Only mode: upgrade remote HTTP main-frame navigations and track fallback URL.
        if isMainFrame,
           let upgraded = BrowserHTTPSGuard.upgradedHTTPSURL(
               for: url,
               httpsOnlyEnabled: secConfig.httpsOnlyMode,
               exceptions: httpsOnlyExceptionsProvider?() ?? []
           )
        {
            inFlightHTTPSUpgradeOriginalURL = url
            inFlightHTTPSUpgradeTargetURL = upgraded
            webView.load(URLRequest(url: upgraded))
            return (.cancel, preferences)
        }

        if isMainFrame {
            syncAdBlockForURL(url.absoluteString)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        WebNavigationPolicy.shouldDownload(navigationResponse) ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adoptDownloadWithConfirmation(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adoptDownloadWithConfirmation(download)
    }

    private func adoptDownloadWithConfirmation(_ download: WKDownload) {
        WebDownloads.shared.adopt(download, in: webView) { [weak self] filename, dataURL, originURL in
            guard let self else { return false }
            return await self.confirmDownload(filename: filename, dataURL: dataURL, originURL: originURL)
        }
    }

    private func confirmDownload(filename: String, dataURL: URL?, originURL: URL?) async -> Bool {
        let secConfig = securityConfigProvider?() ?? .default
        let host = BrowserPageGuard.normalizeHost(originURL?.absoluteString ?? dataURL?.absoluteString ?? urlString) ?? displayHost
        let isRisky = BrowserDownloadGuard.isRiskyFilename(filename)
        let savedSetting = host.isEmpty ? .ask : (sitePermissionProvider?(host, .downloads) ?? .ask)

        if savedSetting == .deny {
            return false
        }
        if !isRisky && (!secConfig.confirmDownloads || savedSetting == .allow) {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = isRisky ? .warning : .informational
        let hostLabel = host.isEmpty ? "This site" : host
        alert.messageText = isRisky
            ? "Download executable or installer “\(filename)” from \(hostLabel)?"
            : "Allow downloads from \(hostLabel)?"
        if let risk = BrowserDownloadGuard.riskWarning(for: filename) {
            alert.informativeText = risk
        } else {
            alert.informativeText = "File: \(filename)\nIt will be saved to ~/Downloads with macOS Gatekeeper quarantine."
        }
        alert.addButton(withTitle: "Allow Once")
        if !isRisky && !host.isEmpty {
            alert.addButton(withTitle: "Always Allow for \(host)")
        }
        alert.addButton(withTitle: "Cancel")

        let response = await presentAlert(alert)
        if response == .alertFirstButtonReturn {
            return true
        }
        if !isRisky && !host.isEmpty && response == .alertSecondButtonReturn {
            onSitePermissionChanged?(host, .downloads, .allow)
            return true
        }
        return false
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
        tlsErrorMessage = nil
        pendingHTTPSFallbackURL = nil
        passkeyFallbackSuggested = false
        inFlightHTTPSUpgradeOriginalURL = nil
        inFlightHTTPSUpgradeTargetURL = nil
        isReaderMode = false
        hasLoginForm = false
        adBlockInterventionsCount = 0
        refreshCertificateSummary()
        if let host = webView.url?.host, let savedZoom = hostZoomProvider?(host) {
            zoom = savedZoom
            webView.pageZoom = savedZoom
        }
        onPageCommitted?(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadError = nil
        tlsErrorMessage = nil
        refreshCertificateSummary()
        if isMuted { applyMuteToPage() }
        refreshMediaState()
        refreshFavicon()
        onPageFinished?(self)
        scheduleSnapshotUpdate()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }

        // If an automatic HTTPS-Only upgrade failed, surface an explicit fallback prompt instead of silently downgrading.
        if let originalHTTP = inFlightHTTPSUpgradeOriginalURL {
            inFlightHTTPSUpgradeOriginalURL = nil
            inFlightHTTPSUpgradeTargetURL = nil
            pendingHTTPSFallbackURL = originalHTTP
            loadError = nil
            tlsErrorMessage = nil
            return
        }

        if BrowserHTTPSGuard.isTLSError(domain: ns.domain, code: ns.code) {
            tlsErrorMessage = ns.localizedDescription
            loadError = nil
            certificateSummary = nil
            return
        }

        loadError = ns.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        vlog("browser tab web content process terminated; reloading")
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Explicit dimensions signal an OAuth / sign-in popup that expects window.opener.
        let isPopupDialog = (windowFeatures.width != nil || windowFeatures.height != nil)
        if isPopupDialog {
            var controller: BrowserPopupWindowController?
            controller = BrowserPopupWindowController(configuration: configuration, windowFeatures: windowFeatures) { [weak self] in
                guard let self, let controller else { return }
                self.popups.removeAll { $0 === controller }
            }
            if let controller {
                popups.append(controller)
                controller.showWindow(nil)
                return controller.webView
            }
        }
        if let url = navigationAction.request.url, Self.isLoadableTabURL(url) {
            onOpenNewTab?(url, isPrivate)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        onTabShouldClose?(self)
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let host = BrowserPageGuard.normalizeHost(origin.host) ?? origin.host.lowercased()
        let kinds: [BrowserPermissionKind] = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera]
        }

        let settings = kinds.map { sitePermissionProvider?(host, $0) ?? .ask }
        if settings.contains(.deny) { return .deny }
        if settings.allSatisfy({ $0 == .allow }) { return .grant }

        let kindLabel: String = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        @unknown default: "media device"
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use your \(kindLabel)?"
        alert.informativeText = "Only allow sites you trust. You can change this anytime from the address bar."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Deny")
        let response = await presentAlert(alert)
        switch response {
        case .alertFirstButtonReturn:
            return .grant
        case .alertSecondButtonReturn:
            for k in kinds { onSitePermissionChanged?(host, k, .allow) }
            return .grant
        default:
            for k in kinds { onSitePermissionChanged?(host, k, .deny) }
            return .deny
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = BrowserURLResolver.displayHost(for: urlString)
        alert.informativeText = message
        _ = await presentAlert(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = BrowserURLResolver.displayHost(for: urlString)
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await presentAlert(alert) == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await presentAlert(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            return panel.runModal() == .OK ? panel.urls : nil
        }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.urls : nil
    }

    private func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = webView.window {
            return await alert.beginSheetModal(for: window)
        }
        return alert.runModal()
    }
}

@MainActor
private final class WeakTabSessionBox {
    weak var session: BrowserTabSession?
}
