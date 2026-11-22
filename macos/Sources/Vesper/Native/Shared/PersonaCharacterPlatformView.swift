import AppKit
import Observation
import SwiftUI
import VesperCore
import WebKit

/// A few pooled `WKWebView`s for live animated persona characters (`active: true`), plus a single
/// offscreen snapshotter and `NSCache` for all inactive character views (`active: false`).
/// Never creates per-row web views: only views that ask to be live get one, and at most
/// `maxLiveCharacters` at a time.
@MainActor
@Observable
final class PersonaCharacterPool {
    static let shared = PersonaCharacterPool()

    /// A chat shows at most its header and its live turn card (or its greeting) at once.
    static let maxLiveCharacters = 3

    /// Owners whose live `WKWebView` has loaded. Observed by `PersonaCharacterView` so its
    /// static snapshot hides only once the live web view is ready, avoiding both ghosting and
    /// blank frames.
    private(set) var displayedLiveOwnerIDs: Set<UUID> = []

    @ObservationIgnored private let snapshotCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var inFlightSnapshots: [String: Task<NSImage?, Never>] = [:]
    @ObservationIgnored private var snapshotQueueWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var isRenderingSnapshot = false
    @ObservationIgnored private var snapshotContinuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var snapshotTimeoutTask: Task<Void, Never>?

    @ObservationIgnored private var liveSlots: [UUID: LiveSlot] = [:]
    /// Web views of detached owners, kept for the next one instead of being rebuilt.
    @ObservationIgnored private var spareSlots: [LiveSlot] = []

    @ObservationIgnored private lazy var snapshotNavDelegate = CharacterNavigationDelegate()

    @ObservationIgnored private var snapshotWindow: NSWindow?
    @ObservationIgnored private lazy var snapshotWebView: ClickThroughCharacterWebView = {
        makeHardenedWebView(delegate: snapshotNavDelegate)
    }()

    private init() {
        snapshotCache.countLimit = 256
    }

    func isShowingLive(_ ownerID: UUID) -> Bool {
        displayedLiveOwnerIDs.contains(ownerID)
    }

    // MARK: - Live Pooled WebViews

    @MainActor
    private final class LiveSlot {
        let webView: ClickThroughCharacterWebView
        let delegate: CharacterNavigationDelegate
        var contentKey: String?
        var loaded = false

        init(webView: ClickThroughCharacterWebView, delegate: CharacterNavigationDelegate) {
            self.webView = webView
            self.delegate = delegate
        }
    }

    func attachLiveWebView(
        to container: NSView,
        ownerID: UUID,
        svg: String,
        color: String,
        state: CharacterState,
        clipped: Bool,
        reduceMotion: Bool
    ) {
        let isNewOwner = liveSlots[ownerID] == nil
        // A full pool leaves a new owner on its snapshot rather than taking another owner's
        // web view, which that owner would take back on its next update.
        guard let slot = liveSlots[ownerID] ?? claimSlot(for: ownerID) else { return }

        let effectiveState: CharacterState = reduceMotion ? .staticState : state
        let contentKey = "\(PersonaCharacterSanitizer.cacheKey(svg: svg, color: color, state: effectiveState, pixelSize: 0, clipped: clipped))|\(reduceMotion ? 1 : 0)"

        if slot.webView.superview !== container {
            slot.webView.removeFromSuperview()
            slot.webView.frame = container.bounds
            slot.webView.autoresizingMask = [.width, .height]
            container.addSubview(slot.webView)
        }

        let reuseAlreadyLoaded = slot.contentKey == contentKey
        if !reuseAlreadyLoaded {
            slot.contentKey = contentKey
            slot.loaded = false
            slot.delegate.onLoadComplete = { [weak self, weak slot] ok in
                guard let self, let slot, slot.contentKey == contentKey, self.liveSlots[ownerID] === slot else { return }
                slot.loaded = ok
                if ok {
                    self.displayedLiveOwnerIDs.insert(ownerID)
                } else {
                    self.displayedLiveOwnerIDs.remove(ownerID)
                }
            }
            let html = PersonaCharacterSanitizer.renderHTML(
                svg: svg,
                color: color,
                state: effectiveState,
                clipped: clipped,
                reduceMotion: reduceMotion
            ) ?? ""
            slot.webView.loadHTMLString(html, baseURL: nil)
        }

        if isNewOwner {
            let alreadyLoaded = reuseAlreadyLoaded && slot.loaded
            // Defer observable state mutations outside SwiftUI's updateNSView pass.
            Task { @MainActor [weak self] in
                guard let self, self.liveSlots[ownerID] === slot else { return }
                if alreadyLoaded {
                    self.displayedLiveOwnerIDs.insert(ownerID)
                } else {
                    self.displayedLiveOwnerIDs.remove(ownerID)
                }
            }
        }
    }

    func detachLiveWebView(ownerID: UUID, from container: NSView) {
        guard let slot = liveSlots.removeValue(forKey: ownerID) else { return }
        if slot.webView.superview === container {
            slot.webView.removeFromSuperview()
        }
        slot.delegate.onLoadComplete = nil
        spareSlots.append(slot)
        Task { @MainActor [weak self] in
            guard let self, self.liveSlots[ownerID] == nil else { return }
            self.displayedLiveOwnerIDs.remove(ownerID)
        }
    }

    private func claimSlot(for ownerID: UUID) -> LiveSlot? {
        guard liveSlots.count < Self.maxLiveCharacters else { return nil }
        let slot: LiveSlot
        if let spare = spareSlots.popLast() {
            // A load still in flight reported to the previous owner, so start it again.
            if !spare.loaded { spare.contentKey = nil }
            slot = spare
        } else {
            let delegate = CharacterNavigationDelegate()
            slot = LiveSlot(webView: makeHardenedWebView(delegate: delegate), delegate: delegate)
        }
        liveSlots[ownerID] = slot
        return slot
    }

    // MARK: - Cached Offscreen Snapshot Pipeline

    func cachedSnapshot(
        svg: String,
        color: String,
        state: CharacterState,
        pixelSize: Int,
        clipped: Bool = false
    ) -> Image? {
        let key = PersonaCharacterSanitizer.cacheKey(
            svg: svg,
            color: color,
            state: state,
            pixelSize: pixelSize,
            clipped: clipped
        )
        return snapshotCache.object(forKey: key as NSString).map { Image(nsImage: $0) }
    }

    func snapshot(
        svg: String,
        color: String,
        state: CharacterState,
        pixelSize: Int,
        clipped: Bool = false
    ) async -> Image? {
        await snapshotNSImage(
            svg: svg,
            color: color,
            state: state,
            pixelSize: pixelSize,
            clipped: clipped
        ).map { Image(nsImage: $0) }
    }

    private func snapshotNSImage(
        svg: String,
        color: String,
        state: CharacterState,
        pixelSize: Int,
        clipped: Bool
    ) async -> NSImage? {
        let key = PersonaCharacterSanitizer.cacheKey(
            svg: svg,
            color: color,
            state: state,
            pixelSize: pixelSize,
            clipped: clipped
        )
        if let hit = snapshotCache.object(forKey: key as NSString) {
            return hit
        }
        if let running = inFlightSnapshots[key] {
            return await running.value
        }

        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            if let hit = self.snapshotCache.object(forKey: key as NSString) {
                return hit
            }
            await self.acquireSnapshotSlot()
            defer { self.releaseSnapshotSlot() }

            if let hit = self.snapshotCache.object(forKey: key as NSString) {
                return hit
            }
            guard let html = PersonaCharacterSanitizer.renderHTML(
                svg: svg,
                color: color,
                state: state,
                clipped: clipped,
                reduceMotion: true
            ) else {
                return nil
            }

            let logicalSize = max(24.0, CGFloat(pixelSize))
            self.prepareSnapshotHost(size: logicalSize)

            let loaded = await self.loadSnapshotHTML(html)
            guard loaded else { return nil }
            // Give WebKit one frame to commit layout/SVG paint before capturing the bitmap.
            try? await Task.sleep(for: .milliseconds(16))

            let config = WKSnapshotConfiguration()
            config.rect = CGRect(origin: .zero, size: CGSize(width: logicalSize, height: logicalSize))
            config.snapshotWidth = NSNumber(value: Double(logicalSize))
            config.afterScreenUpdates = true

            guard let image = try? await self.snapshotWebView.takeSnapshot(configuration: config) else {
                return nil
            }
            self.snapshotCache.setObject(image, forKey: key as NSString)
            return image
        }

        inFlightSnapshots[key] = task
        let result = await task.value
        inFlightSnapshots.removeValue(forKey: key)
        return result
    }

    // MARK: - Private Snapshot Serialization & Hardened WebView

    private func acquireSnapshotSlot() async {
        if !isRenderingSnapshot {
            isRenderingSnapshot = true
            return
        }
        await withCheckedContinuation { continuation in
            snapshotQueueWaiters.append(continuation)
        }
    }

    private func releaseSnapshotSlot() {
        if let next = snapshotQueueWaiters.first {
            snapshotQueueWaiters.removeFirst()
            next.resume()
        } else {
            isRenderingSnapshot = false
        }
    }

    private func prepareSnapshotHost(size: CGFloat) {
        let rect = NSRect(x: -10000, y: -10000, width: size, height: size)
        if let window = snapshotWindow {
            window.setFrame(rect, display: false)
        } else {
            let window = NSWindow(
                contentRect: rect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            snapshotWebView.frame = NSRect(origin: .zero, size: rect.size)
            snapshotWebView.autoresizingMask = [.width, .height]
            window.contentView = snapshotWebView
            snapshotWindow = window
        }
        snapshotWebView.frame = NSRect(origin: .zero, size: rect.size)
    }

    private func loadSnapshotHTML(_ html: String) async -> Bool {
        finishSnapshotLoad(false)
        return await withCheckedContinuation { continuation in
            snapshotContinuation = continuation
            snapshotNavDelegate.onLoadComplete = { [weak self] ok in
                self?.finishSnapshotLoad(ok)
            }
            snapshotWebView.loadHTMLString(html, baseURL: nil)
            snapshotTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.finishSnapshotLoad(false)
            }
        }
    }

    private func finishSnapshotLoad(_ ok: Bool) {
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        snapshotNavDelegate.onLoadComplete = nil
        guard let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        continuation.resume(returning: ok)
    }

    private func makeHardenedWebView(delegate: WKNavigationDelegate) -> ClickThroughCharacterWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true

        let webView = ClickThroughCharacterWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = delegate
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .clear
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:"))
            || webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        return webView
    }
}

private final class ClickThroughCharacterWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class CharacterNavigationDelegate: NSObject, WKNavigationDelegate {
    var onLoadComplete: ((Bool) -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let allowed = scheme == "about" && navigationAction.navigationType == .other
        return allowed ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadComplete?(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isCancelled(error) { return }
        onLoadComplete?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isCancelled(error) { return }
        onLoadComplete?(false)
    }

    private func isCancelled(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            || (ns.domain == "WebKitErrorDomain" && ns.code == 102)
    }
}

/// AppKit host attaching a pooled live `WKWebView` while `PersonaCharacterView` is `active`.
struct PersonaCharacterPlatformHost: NSViewRepresentable {
    let ownerID: UUID
    let svg: String
    let color: String
    let state: CharacterState
    let clipped: Bool
    let reduceMotion: Bool

    final class Coordinator {
        var ownerID: UUID
        init(ownerID: UUID) { self.ownerID = ownerID }
    }

    func makeCoordinator() -> Coordinator { Coordinator(ownerID: ownerID) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.ownerID = ownerID
        PersonaCharacterPool.shared.attachLiveWebView(
            to: nsView,
            ownerID: ownerID,
            svg: svg,
            color: color,
            state: state,
            clipped: clipped,
            reduceMotion: reduceMotion
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        PersonaCharacterPool.shared.detachLiveWebView(ownerID: coordinator.ownerID, from: nsView)
    }
}
