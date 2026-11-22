import AppKit
import SwiftUI
import VesperCore
import WebKit

/// Hosts an internal Vesper web route inside a native screen for legacy views that are still migrating
/// (e.g., `/epics/list`, `/runs/:id/graph`, Tiptap pages and Docs/Slides/Designs inside Knowledge).
/// Isolated as a platform adapter so iOS can supply its own `UIViewRepresentable` without touching callers.
struct HostedWebPageView: View {
    let path: String
    var onBridgeMessage: ((PageMessage) -> Void)?

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var reloadToken = UUID()

    var body: some View {
        let targetURL = context.resolvedURL(path)
        ZStack(alignment: .top) {
            HostedWebViewRepresentable(
                path: path,
                targetURL: targetURL,
                reloadToken: reloadToken,
                context: context,
                onBridgeMessage: onBridgeMessage,
                onLoadingChange: { isLoading = $0 },
                onError: { loadError = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(theme.palette.secondaryText)
                    Text("Couldn\u{2019}t load page")
                        .font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(theme.palette.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        self.loadError = nil
                        reloadToken = UUID()
                    }
                    .buttonStyle(VesperButtonStyle(variant: .outline))
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.palette.background)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HostedWebViewRepresentable: NSViewRepresentable {
    let path: String
    let targetURL: URL?
    let reloadToken: UUID
    let context: NativeScreenContext
    let onBridgeMessage: ((PageMessage) -> Void)?
    let onLoadingChange: (Bool) -> Void
    let onError: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(context: context, onBridgeMessage: onBridgeMessage, onLoadingChange: onLoadingChange, onError: onError)
    }

    func makeNSView(context nsContext: Context) -> WKWebView {
        let coordinator = nsContext.coordinator
        let services = coordinator.services
        let webView = WebViewFactory.makeWebView(kind: .vesper, bridge: coordinator, services: services)
        coordinator.attach(webView: webView)
        coordinator.load(path: path, url: targetURL, reloadToken: reloadToken)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context nsContext: Context) {
        let coordinator = nsContext.coordinator
        coordinator.context = self.context
        coordinator.onBridgeMessage = onBridgeMessage
        coordinator.onLoadingChange = onLoadingChange
        coordinator.onError = onError
        coordinator.load(path: path, url: targetURL, reloadToken: reloadToken)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var context: NativeScreenContext
        var onBridgeMessage: ((PageMessage) -> Void)?
        var onLoadingChange: (Bool) -> Void
        var onError: (String?) -> Void
        let services = WebPageServices()

        private weak var webView: WKWebView?
        private var hostedPath: String = ""
        private var loadedURL: URL?
        private var lastReloadToken: UUID?
        private var ready = false
        private var loadingObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private var appearanceMonitor: AppearanceMonitor?

        init(
            context: NativeScreenContext,
            onBridgeMessage: ((PageMessage) -> Void)?,
            onLoadingChange: @escaping (Bool) -> Void,
            onError: @escaping (String?) -> Void
        ) {
            self.context = context
            self.onBridgeMessage = onBridgeMessage
            self.onLoadingChange = onLoadingChange
            self.onError = onError
            super.init()
            appearanceMonitor = AppearanceMonitor { [weak self] in self?.sendAppearance() }
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            services.webView = webView
            webView.navigationDelegate = self
            webView.uiDelegate = self
            loadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.onLoadingChange(wv.isLoading) }
            }
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.handleURLChange(wv.url) }
            }
        }

        func load(path: String, url: URL?, reloadToken: UUID) {
            hostedPath = path
            services.baseURL = context.baseURL()
            guard let url else { return }
            let needsReload = reloadToken != lastReloadToken || loadedURL != url
            guard needsReload else { return }
            lastReloadToken = reloadToken
            loadedURL = url
            ready = false
            onError(nil)
            webView?.load(URLRequest(url: url))
        }

        func teardown() {
            appearanceMonitor?.stop()
            appearanceMonitor = nil
            loadingObservation = nil
            urlObservation = nil
            if let controller = webView?.configuration.userContentController {
                controller.removeScriptMessageHandler(forName: WebViewFactory.handlerName)
                services.teardown(from: controller)
            }
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.stopLoading()
        }

        private func sendAppearance() {
            guard ready, let webView else { return }
            if let custom = context.window()?.app.currentAppearanceCommand() {
                ShellBridge.send(custom, to: webView)
                return
            }
            let (accent, mode) = AppearanceMonitor.current()
            ShellBridge.send(.appearance(accent: accent, mode: mode), to: webView)
        }

        private func handleURLChange(_ url: URL?) {
            guard let url, let base = context.baseURL(), BridgeOrigin.matches(url: url, base: base) else { return }
            let actual = relativePath(for: url)
            guard !isSameHostedDestination(expected: hostedPath, actual: actual) else { return }
            context.navigate(actual)
        }

        private func isSameHostedDestination(expected: String, actual: String) -> Bool {
            let expectedPath = Self.pathOnly(expected)
            let actualPath = Self.pathOnly(actual)
            if expectedPath == actualPath { return true }
            // Knowledge pages canonicalize `/knowledge/<uuid>` to `/knowledge/<uuid>/<slug>`.
            if expectedPath.hasPrefix("/knowledge/"), actualPath.hasPrefix(expectedPath + "/") { return true }
            return false
        }

        private static func pathOnly(_ pathWithQuery: String) -> String {
            let raw = pathWithQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathWithQuery
            return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        }

        private func relativePath(for url: URL) -> String {
            var out = url.path.isEmpty ? "/" : url.path
            if let q = url.query { out += "?" + q }
            if let f = url.fragment { out += "#" + f }
            return out
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let frame = message.frameInfo
            let origin = frame.securityOrigin
            guard frame.isMainFrame, let base = context.baseURL(),
                  BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: base) else {
                return
            }
            guard let decoded = try? PageMessage.decode(fromJSONObject: message.body) else { return }
            onBridgeMessage?(decoded)
            handle(decoded)
        }

        private func handle(_ message: PageMessage) {
            let win = webView?.window ?? context.window()?.window
            switch message {
            case .ready:
                ready = true
                sendAppearance()
            case .route(let path, _):
                if !isSameHostedDestination(expected: hostedPath, actual: path) {
                    context.navigate(path)
                }
            case .openInMain(let path, let newTab):
                if newTab { context.openInNewTab(path) } else { context.navigate(path) }
            case .appearance(_, let background, _):
                if let color = NSColor.fromCSS(background) {
                    webView?.underPageBackgroundColor = color
                }
            case .confirmApproval(let requestId, let scope):
                Task { [weak self] in
                    let ok = await ShellBridge.services?.confirmApproval(scope: scope) ?? false
                    ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self?.webView)
                }
            case .openWorkspaceMenu(let requestId, let folder):
                Task { [weak self] in
                    guard let view = self?.webView else { return }
                    let ok = await ShellBridge.services?.showWorkspaceMenu(folder: folder, in: view) ?? false
                    ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self?.webView)
                }
            case .contextMenu(let requestId, let items, let x, let y):
                guard let webView else { return }
                let selected = ShellBridge.showContextMenu(items: items, x: x, y: y, in: webView)
                ShellBridge.send(.reply(requestId: requestId, ok: true, selectedId: .some(selected)), to: webView)
            case .confirm(let requestId, let title, let body, let confirmLabel, let cancelLabel, let destructive):
                Task { [weak self] in
                    let ok = await ShellBridge.confirmSheet(
                        title: title, body: body, confirmLabel: confirmLabel,
                        cancelLabel: cancelLabel, destructive: destructive, window: win
                    )
                    ShellBridge.send(.reply(requestId: requestId, ok: ok), to: self?.webView)
                }
            case .prompt(let requestId, let title, let body, let label, let value, let placeholder, let confirmLabel, let cancelLabel, let maxLength):
                Task { [weak self] in
                    let entered = await ShellBridge.promptSheet(
                        title: title, body: body, label: label, value: value, placeholder: placeholder,
                        confirmLabel: confirmLabel, cancelLabel: cancelLabel, maxLength: maxLength, window: win
                    )
                    ShellBridge.send(.reply(requestId: requestId, ok: entered != nil, value: .some(entered)), to: self?.webView)
                }
            case .toastShow(let id, let title, let description, let tone, let actionLabel, let durationMs):
                let toast = ToastItemModel(id: id, title: title, description: description, tone: tone, actionLabel: actionLabel, durationMs: durationMs)
                context.window()?.showToast(toast, from: webView)
            case .toastDismiss(let id):
                context.window()?.dismissToast(id: id)
            case .showShortcuts:
                context.showShortcuts()
            case .commandPaletteOpen(let request):
                context.window()?.openCommandPalette(request)
            case .commandPaletteClose:
                context.window()?.closeCommandPalette()
            case .quickLook(let items, let index):
                context.showQuickLook(items, index: index)
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate & WKUIDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.shouldPerformDownload { return .download }
            guard let url = navigationAction.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased() ?? ""
            if ["blob", "data", "about"].contains(scheme) { return .allow }
            guard navigationAction.targetFrame?.isMainFrame ?? true else { return .allow }
            guard let base = context.baseURL() else { return .cancel }
            let ports = context.window()?.app.playgroundPorts ?? defaultPlaygroundPorts
            let openingTab = navigationAction.targetFrame == nil

            switch classifyNavigation(url.absoluteString, serverURL: base.absoluteString, playgroundPorts: ports) {
            case .vesper:
                let path = relativePath(for: url)
                if !openingTab && navigationAction.navigationType != .linkActivated && isSameHostedDestination(expected: hostedPath, actual: path) {
                    return .allow
                }
                if !openingTab && navigationAction.navigationType == .linkActivated && isSameHostedDestination(expected: hostedPath, actual: path) {
                    return .allow
                }
                if openingTab {
                    context.openInNewTab(path)
                } else {
                    context.navigate(path)
                }
                return .cancel
            case .playground:
                context.window()?.app.openPlayground(url: url, nextTo: webView.window ?? context.window()?.window)
                return .cancel
            case .external:
                context.openExternal(url.absoluteString)
                return .cancel
            case .ignore:
                return .cancel
            }
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

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased() ?? ""
            if url == nil || url?.absoluteString.isEmpty == true || ["about", "blob", "data"].contains(scheme) {
                return WebPopup.make(configuration: configuration, features: windowFeatures, parent: webView.window ?? context.window()?.window)
            }
            if let url, let base = context.baseURL() {
                let ports = context.window()?.app.playgroundPorts ?? defaultPlaygroundPorts
                switch classifyNavigation(url.absoluteString, serverURL: base.absoluteString, playgroundPorts: ports) {
                case .vesper: context.openInNewTab(relativePath(for: url))
                case .playground: context.window()?.app.openPlayground(url: url, nextTo: webView.window ?? context.window()?.window)
                case .external: context.openExternal(url.absoluteString)
                case .ignore: break
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                     type: WKMediaCaptureType) async -> WKPermissionDecision {
            guard frame.isMainFrame, let base = context.baseURL(),
                  BridgeOrigin.matches(scheme: origin.protocol, host: origin.host, port: origin.port, base: base) else {
                return .deny
            }
            return .prompt
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        private func fail(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
            onError(ns.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.reload()
        }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            return panel.runModal() == .OK ? panel.urls : nil
        }
    }
}
