import AppKit
import Observation
import SwiftUI
import VesperCore
import WebKit

/// An ```app fence (app-fence.tsx): the assistant's HTML/JS running live in a sandboxed web view.
/// The view exists only while the block is on screen: it comes from `AppWebViewPool` when the block
/// scrolls into view and goes back (after a snapshot) when it scrolls off, and the snapshot stands in
/// until it's back. An app restarts when it gets a view again, as a remounted iframe does on the web.
struct AppEmbedView: View {
    let source: String
    let messageID: String
    let index: Int
    let info: String?

    @Environment(\.vesperTheme) private var theme
    @State private var view = "App"
    @State private var visible = false
    private var pool: AppWebViewPool { .shared }

    private var owner: String {
        EmbedCacheKey(kind: .app, messageID: messageID, theme: "", source: source, variant: String(index)).description
    }

    var body: some View {
        let owner = owner
        let height = ChatApp.height(pool.heights[owner])
        let live = pool.live.contains(owner)
        let wantsLive = view == "App" && visible && !pool.parked.contains(owner)
        EmbedFrame(icon: "play", label: "Interactive app", views: ["App", "Code"], view: $view) {
            if view == "App" {
                Button {
                    pool.reload(owner)
                } label: {
                    Image(systemName: "arrow.clockwise").imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Reload")
                .accessibilityLabel("Reload app")
                .disabled(!live)
            }
        } content: {
            if view == "App" {
                ZStack(alignment: .topLeading) {
                    Color.white
                    if let snapshot = pool.snapshot(owner) {
                        Image(nsImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .clipped()
                            .accessibilityLabel("Interactive app (paused)")
                    }
                    AppWebViewHost(owner: owner, document: ChatApp.document(source), active: wantsLive)
                    if !live {
                        parkedOverlay(owner)
                    }
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
            } else {
                EmbedSourceView(code: source, language: "html")
            }
        }
        .onAppear {
            visible = true
            pool.unpark(owner)
        }
        .onDisappear {
            visible = false
            pool.park(owner, snapshot: false)
        }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen in
            visible = onScreen
            if onScreen {
                pool.unpark(owner)
            } else {
                pool.park(owner, snapshot: true)
            }
        }
        .onChange(of: view) { _, now in
            if now != "App" { pool.park(owner, snapshot: true) } else { pool.unpark(owner) }
        }
    }

    /// While the view loads, nothing; when another app took it (more apps on screen than views), a
    /// button to run this one again.
    @ViewBuilder
    private func parkedOverlay(_ owner: String) -> some View {
        if pool.parked.contains(owner) && visible {
            Button {
                pool.unpark(owner)
            } label: {
                Label("Run app", systemImage: "play.fill")
            }
            .buttonStyle(.vesper())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pool.snapshot(owner) == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Where a pooled app web view sits while its block is live. The pool moves the web view in and out
/// of this container; SwiftUI only says whether it should be here.
private struct AppWebViewHost: NSViewRepresentable {
    let owner: String
    let document: String
    let active: Bool

    final class Coordinator {
        var owner: String
        init(owner: String) { self.owner = owner }
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }

    func makeNSView(context: Context) -> AppContainerView {
        let view = AppContainerView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ container: AppContainerView, context: Context) {
        context.coordinator.owner = owner
        // SwiftUI may update before the container is in a window; attach once it is.
        container.onWindow = active ? { [owner, document] view in AppWebViewPool.shared.attach(owner, document: document, to: view) } : nil
        if active, container.window != nil {
            AppWebViewPool.shared.attach(owner, document: document, to: container)
        }
    }

    static func dismantleNSView(_ container: AppContainerView, coordinator: Coordinator) {
        container.onWindow = nil
        AppWebViewPool.shared.release(coordinator.owner, from: container)
    }
}

/// The container a pooled app web view moves into; it says when it joins a window.
private final class AppContainerView: NSView {
    var onWindow: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?(self) }
    }
}

/// The app blocks' web views: at most `capacity` exist, each handed to the block that's on screen
/// and taken back (snapshot first) when it scrolls off, least recently used first when more blocks
/// want one than there are. Which block holds which view is `EmbedPoolLedger` (VesperCore); this
/// owns the views.
///
/// Every view is sandboxed as the web's iframe is: JavaScript on, but a fresh non-persistent data
/// store (no Vesper cookies or storage), no bridge or native-mode script, `ChatApp.csp` first in the
/// document, `ChatApp.contentRuleList` blocking every load but the CDNs, navigation limited to the
/// shell's own `about:blank` (`ChatApp.allowsNavigation`), no new windows, no dialogs, no camera or
/// microphone. The height comes from a script in an isolated content world the app can't reach.
@MainActor
@Observable
final class AppWebViewPool {
    static let shared = AppWebViewPool(capacity: 4)

    /// Owners whose app is loaded and showing.
    private(set) var live: Set<String> = []
    /// Owners that gave their view up while on screen (another app took it, or the Code view); they
    /// show their snapshot until scrolled back or clicked.
    private(set) var parked: Set<String> = []
    /// Each owner's last reported content height.
    private(set) var heights: [String: Double] = [:]
    /// Bumped when a snapshot is taken, so the blocks showing it redraw.
    private(set) var snapshotGeneration = 0

    @ObservationIgnored private var ledger: EmbedPoolLedger<String>
    @ObservationIgnored private var views: [Int: WKWebView] = [:]
    @ObservationIgnored private var documents: [String: String] = [:]
    @ObservationIgnored private let snapshots: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    @ObservationIgnored private var snapshotOwners: Set<String> = []
    @ObservationIgnored private var ruleList: WKContentRuleList?
    @ObservationIgnored private var ruleListTask: Task<WKContentRuleList?, Never>?
    @ObservationIgnored private lazy var delegate = AppWebViewDelegate(pool: self)
    @ObservationIgnored private lazy var heightHandler = AppHeightHandler(pool: self)
    /// The isolated world the height script runs in.
    private static let world = WKContentWorld.world(name: "VesperChatAppFrame")
    private static let heightHandlerName = "vesperAppHeight"

    init(capacity: Int) {
        ledger = EmbedPoolLedger(capacity: capacity)
    }

    // MARK: State for the debug screen

    var capacity: Int { ledger.capacity }
    var createdCount: Int { views.count }
    var idleCount: Int { ledger.idleCount }
    var snapshotCount: Int {
        _ = snapshotGeneration
        return snapshotOwners.count
    }

    func snapshot(_ owner: String) -> NSImage? {
        _ = snapshotGeneration
        return snapshots.object(forKey: owner as NSString)
    }

    // MARK: Lifecycle

    /// Gives `owner` a view in `container` (a no-op when it already has one there).
    func attach(_ owner: String, document: String, to container: NSView) {
        documents[owner] = document
        if let slot = ledger.slot(of: owner), let view = views[slot], view.superview === container {
            ledger.touch(owner)
            return
        }
        Task { await attachNow(owner, to: container) }
    }

    private func attachNow(_ owner: String, to container: NSView) async {
        guard let rules = await contentRules() else {
            vlog("embeds: app blocks are off: the content rule list didn't compile")
            return
        }
        // The block may have scrolled away or been parked while the rules compiled.
        guard container.window != nil, !parked.contains(owner), let document = documents[owner] else { return }
        let view: WKWebView
        var needsLoad = true
        switch ledger.acquire(owner) {
        case .existing(let slot):
            guard let held = views[slot] else { return }
            view = held
            // Moving to a new container: a view already loading or showing this app keeps it.
            needsLoad = delegate.owners[ObjectIdentifier(held)] != owner
        case .reuse(let slot):
            guard let idle = views[slot] else { return }
            view = idle
        case .create(let slot):
            view = makeWebView(rules: rules)
            views[slot] = view
        case .evict(let slot, let previous):
            guard let taken = views[slot] else { return }
            await takeSnapshot(of: taken, for: previous)
            live.remove(previous)
            parked.insert(previous)
            view = taken
        }
        if view.superview !== container {
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        if needsLoad {
            view.isHidden = true
            delegate.owners[ObjectIdentifier(view)] = owner
            view.loadHTMLString(document, baseURL: nil)
        }
    }

    /// The block scrolled off (or switched to Code): snapshot it, then give its view back, blanked so
    /// the app stops running. `snapshot: false` when the block is already gone from the window.
    func park(_ owner: String, snapshot: Bool) {
        guard let slot = ledger.slot(of: owner), let view = views[slot] else { return }
        Task {
            if snapshot, live.contains(owner) { await takeSnapshot(of: view, for: owner) }
            // Still this owner's? (It may have scrolled back while the snapshot was taken.)
            guard ledger.slot(of: owner) == slot else { return }
            parked.insert(owner)
            free(owner, view: view)
        }
    }

    /// Lets a parked block run again: it attaches on its next update.
    func unpark(_ owner: String) {
        parked.remove(owner)
    }

    /// The block's container is going away: give the view back without a snapshot.
    func release(_ owner: String, from container: NSView) {
        guard let slot = ledger.slot(of: owner), let view = views[slot], view.superview === container || view.superview == nil else { return }
        free(owner, view: view)
    }

    func reload(_ owner: String) {
        guard let slot = ledger.slot(of: owner), let view = views[slot], let document = documents[owner] else { return }
        live.remove(owner)
        view.isHidden = true
        view.loadHTMLString(document, baseURL: nil)
    }

    private func free(_ owner: String, view: WKWebView) {
        ledger.release(owner)
        live.remove(owner)
        delegate.owners[ObjectIdentifier(view)] = nil
        view.removeFromSuperview()
        view.loadHTMLString("", baseURL: nil)
    }

    private func takeSnapshot(of view: WKWebView, for owner: String) async {
        guard view.window != nil, !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return }
        guard let image = try? await view.takeSnapshot(configuration: nil) else { return }
        snapshots.setObject(image, forKey: owner as NSString)
        snapshotOwners.insert(owner)
        snapshotGeneration += 1
    }

    // MARK: Delegate callbacks

    fileprivate func didLoad(_ view: WKWebView) {
        guard let owner = delegate.owners[ObjectIdentifier(view)], ledger.slot(of: owner).flatMap({ views[$0] }) === view else { return }
        view.isHidden = false
        live.insert(owner)
        ledger.touch(owner)
    }

    fileprivate func didReportHeight(_ height: Double, from view: WKWebView) {
        guard let owner = delegate.owners[ObjectIdentifier(view)] else { return }
        if heights[owner] != height { heights[owner] = height }
    }

    fileprivate func contentProcessEnded(_ view: WKWebView) {
        guard let owner = delegate.owners[ObjectIdentifier(view)] else { return }
        vlog("embeds: an app's web content process ended")
        live.remove(owner)
        parked.insert(owner)
        free(owner, view: view)
    }

    // MARK: Sandbox

    private func contentRules() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        let task = ruleListTask ?? Task { @MainActor in
            do {
                return try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "vesper-chat-app-sandbox", encodedContentRuleList: ChatApp.contentRuleList
                )
            } catch {
                vlog("embeds: content rule list: \(error.localizedDescription)")
                return nil
            }
        }
        ruleListTask = task
        ruleList = await task.value
        if ruleList == nil { ruleListTask = nil }
        return ruleList
    }

    private func makeWebView(rules: WKContentRuleList) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let content = config.userContentController
        content.add(rules)
        content.addUserScript(WKUserScript(
            source: ChatApp.resizeScript(handler: Self.heightHandlerName),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world
        ))
        content.add(heightHandler, contentWorld: Self.world, name: Self.heightHandlerName)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.isInspectable = false
        return view
    }
}

/// Navigation and UI policy for every app web view.
@MainActor
private final class AppWebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var pool: AppWebViewPool?
    /// Which owner each view is loaded for.
    var owners: [ObjectIdentifier: String] = [:]

    init(pool: AppWebViewPool) { self.pool = pool }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let allowed = ChatApp.allowsNavigation(
            to: navigationAction.request.url,
            isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
            isUserInitiatedLink: navigationAction.navigationType == .linkActivated
        )
        return allowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A blanked (released) view finishes too; only a view with an owner goes live.
        if webView.url?.absoluteString == "about:blank", owners[ObjectIdentifier(webView)] != nil {
            pool?.didLoad(webView)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pool?.contentProcessEnded(webView)
    }

    // No window.open, dialogs, or media capture: the iframe's sandbox has no allow-popups or allow-modals.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? { nil }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? { nil }
}

/// Hears the isolated world's height reports. Registered only in that world, so the app's own
/// scripts can't post to it.
@MainActor
private final class AppHeightHandler: NSObject, WKScriptMessageHandler {
    weak var pool: AppWebViewPool?

    init(pool: AppWebViewPool) { self.pool = pool }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView, let height = (message.body as? NSNumber)?.doubleValue else { return }
        pool?.didReportHeight(height, from: view)
    }
}
