import AppKit
import Observation
import VesperCore
import WebKit

/// Live state and WebKit delegates for one internal Browser tab.
@MainActor
@Observable
final class BrowserTabSession: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    let isPrivate: Bool
    var isPinned: Bool
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
    var zoom: Double = 1.0

    /// Active live share for this tab (backed by `/api/v1/browser-extension/shares`).
    var activeShare: BrowserShare?
    var shareStartURL: String?
    var shareError: String?

    @ObservationIgnored let webView: BrowserWKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var popups: [BrowserPopupWindowController] = []
    @ObservationIgnored private var snapshotDebounceTask: Task<Void, Never>?

    @ObservationIgnored var onOpenNewTab: ((URL, Bool) -> Void)?
    @ObservationIgnored var onPageCommitted: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onPageFinished: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onTabShouldClose: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onSnapshotDue: ((BrowserTabSession) -> Void)?
    @ObservationIgnored var onStopShare: ((BrowserTabSession, String) -> Void)?
    @ObservationIgnored var neverShareProvider: (() -> BrowserNeverShareLists)?
    @ObservationIgnored var hostZoomProvider: ((String) -> Double?)?

    var hasLoadedPage: Bool { !urlString.isEmpty }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let host = BrowserURLResolver.displayHost(for: urlString)
        return host.isEmpty ? (isPrivate ? "Private Tab" : "New Tab") : host
    }

    var displayHost: String {
        BrowserURLResolver.displayHost(for: urlString)
    }

    var record: BrowserTabRecord {
        BrowserTabRecord(
            id: id,
            url: urlString,
            title: displayTitle,
            isPinned: isPinned,
            isPrivate: isPrivate,
            zoom: zoom
        )
    }

    init(record: BrowserTabRecord, contentRuleList: WKContentRuleList?) {
        self.id = record.id
        self.isPrivate = record.isPrivate
        self.isPinned = record.isPinned
        self.urlString = record.url
        self.title = record.title
        self.zoom = record.zoom
        self.webView = BrowserWebViewFactory.makeWebView(isPrivate: record.isPrivate, contentRuleList: contentRuleList)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        if zoom != 1.0 { webView.pageZoom = zoom }

        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let next = wv.url?.absoluteString, next != "about:blank" {
                        self.urlString = next
                        self.handleURLChanged(next)
                    }
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let next = wv.title, !next.isEmpty {
                        self.title = next
                        self.onStateChanged?()
                    }
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
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
        ]

        if let initialURL = URL(string: record.url), BrowserURLResolver.isWebURL(initialURL) {
            webView.load(URLRequest(url: initialURL))
        }
    }

    // MARK: Navigation

    func load(_ url: URL) {
        loadError = nil
        isReaderMode = false
        urlString = url.absoluteString
        if let host = url.host, let savedZoom = hostZoomProvider?(host) {
            zoom = savedZoom
            webView.pageZoom = savedZoom
        }
        webView.load(URLRequest(url: url))
        onStateChanged?()
    }

    func reload(fromOrigin: Bool = false) {
        loadError = nil
        isReaderMode = false
        if webView.url != nil {
            if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        } else if let url = URL(string: urlString), BrowserURLResolver.isWebURL(url) {
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
    }

    func applyContentRuleList(_ ruleList: WKContentRuleList?) {
        webView.configuration.userContentController.removeAllContentRuleLists()
        if let ruleList {
            webView.configuration.userContentController.add(ruleList)
        }
    }

    func toggleReaderMode(darkMode: Bool) async {
        guard hasLoadedPage else { return }
        let js = BrowserPageScripts.toggleReaderModeJS(darkMode: darkMode)
        if let active = (try? await webView.evaluateJavaScript(js)) as? Bool {
            isReaderMode = active
        }
    }

    func refreshMediaState() {
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                self?.isAudioPlaying = (state == .playing)
            }
        }
    }

    func teardown() {
        snapshotDebounceTask?.cancel()
        snapshotDebounceTask = nil
        for popup in popups { popup.window?.close() }
        popups.removeAll()
        observations.removeAll()
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

    /// Captures the visible viewport as a PNG using `WKWebView.takeSnapshot` (requires zero macOS
    /// Screen Recording permissions).
    func captureScreenshotPNG() async -> Data? {
        let config = WKSnapshotConfiguration()
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""

        if scheme == "mailto" || scheme == "tel" {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            return .allow
        }
        guard scheme == "http" || scheme == "https" else {
            return .cancel
        }
        // Middle-click / Cmd-click / target="_blank" links open in a new browser tab.
        if navigationAction.targetFrame == nil {
            onOpenNewTab?(url, isPrivate)
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command)
        {
            onOpenNewTab?(url, isPrivate)
            return .cancel
        }
        return .allow
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
        isReaderMode = false
        if let host = webView.url?.host, let savedZoom = hostZoomProvider?(host) {
            zoom = savedZoom
            webView.pageZoom = savedZoom
        }
        onPageCommitted?(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadError = nil
        refreshMediaState()
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
        if let url = navigationAction.request.url, BrowserURLResolver.isWebURL(url) {
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
        let kind: String = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        @unknown default: "media device"
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(origin.host) to use your \(kind)?"
        alert.informativeText = "Only allow sites you trust."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        let response = await presentAlert(alert)
        return response == .alertFirstButtonReturn ? .grant : .deny
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
