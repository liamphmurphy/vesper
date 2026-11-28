import AppKit
import QuartzCore
import SwiftUI
import VesperCore

/// Live count of active `CADisplayLink` canvas drivers across the process, displayed in the
/// optional Performance HUD so developers can verify animations spin down cleanly when idle/hidden.
@MainActor
enum DisplayLinkCanvasMetrics {
    fileprivate(set) static var activeCount: Int = 0
}

/// Breaks the strong reference cycle between `CADisplayLink` and its target `NSView`.
/// If the owning view has already deallocated before invalidation, the trampoline invalidates the link.
@MainActor
private final class DisplayLinkTrampoline: NSObject {
    weak var owner: DisplayLinkCanvasNSView?

    init(owner: DisplayLinkCanvasNSView) {
        self.owner = owner
    }

    @objc func step(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.handleDisplayLinkTick(link)
    }
}

/// Hardware VSync-driven `NSView` that renders vector/bitmap frames directly into a Y-down
/// `CGContext` via `NSView.displayLink(target:selector:)` + `CAFrameRateRange`, completely
/// bypassing SwiftUI view-graph diffing on every frame.
///
/// - Requests 120 Hz on ProMotion panels (clamped automatically to the current screen's max refresh
///   rate, e.g. 60 Hz on external monitors) and updates dynamically when dragged between displays.
/// - Attaches to `RunLoop.Mode.common` so animations stay smooth during scrolling, popover/menu
///   tracking, and live split-view transitions.
/// - Tears down its `CADisplayLink` completely when `isAnimating == false`, hidden, or detached.
@MainActor
final class DisplayLinkCanvasNSView: NSView {
    var isAnimating: Bool = false {
        didSet {
            if isAnimating != oldValue {
                syncDisplayLink()
            }
        }
    }

    var frameRateProfile: AnimationPolicy.FrameRateProfile = AnimationPolicy.displayLinkFrameRate(working: true) {
        didSet {
            if frameRateProfile != oldValue {
                applyFrameRateRange()
            }
        }
    }

    /// Optional gate checked on each VSync tick before scheduling a redraw (e.g. frame-based WebP
    /// loops that only need to redraw when `frameIndex` advances). Nil means redraw every tick.
    var shouldDraw: ((_ timestamp: CFTimeInterval) -> Bool)?

    /// Renders one frame into a Y-down `CGContext` covering `size` at presentation time `timestamp`.
    var drawFrame: ((_ context: CGContext, _ size: CGSize, _ timestamp: CFTimeInterval) -> Void)?

    private var displayLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?
    private var latestTimestamp: CFTimeInterval = CACurrentMediaTime()
    private(set) var drawCallCount: Int = 0
    private(set) var appliedFrameRateRange: CAFrameRateRange?

    var hasActiveDisplayLink: Bool { displayLink != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebindScreenObserver()
        syncContentsScale()
        syncDisplayLink()
        if window != nil {
            needsDisplay = true
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncDisplayLink()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncDisplayLink()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            needsDisplay = true
        }
    }

    func requestStaticRedraw(at timestamp: CFTimeInterval = CACurrentMediaTime()) {
        latestTimestamp = timestamp
        needsDisplay = true
    }

    func teardown() {
        stopDisplayLink()
        removeScreenObserver()
        shouldDraw = nil
        drawFrame = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0,
              let cg = NSGraphicsContext.current?.cgContext,
              let drawFrame else { return }
        drawCallCount &+= 1
        let timestamp = displayLink != nil ? latestTimestamp : CACurrentMediaTime()
        drawFrame(cg, bounds.size, timestamp)
    }

    fileprivate func handleDisplayLinkTick(_ link: CADisplayLink) {
        guard isAnimating, window != nil, !isHiddenOrHasHiddenAncestor else {
            stopDisplayLink()
            return
        }
        let target = link.targetTimestamp > 0 ? link.targetTimestamp : CACurrentMediaTime()
        if let shouldDraw, !shouldDraw(target) {
            return
        }
        latestTimestamp = target
        needsDisplay = true
    }

    private func syncDisplayLink() {
        let shouldRun = isAnimating && window != nil && !isHiddenOrHasHiddenAncestor
        if shouldRun {
            if displayLink == nil {
                startDisplayLink()
            } else {
                applyFrameRateRange()
            }
        } else {
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard window != nil, displayLink == nil else { return }
        let trampoline = DisplayLinkTrampoline(owner: self)
        let link = self.displayLink(target: trampoline, selector: #selector(DisplayLinkTrampoline.step(_:)))
        displayLink = link
        DisplayLinkCanvasMetrics.activeCount += 1
        applyFrameRateRange()
        // `.common` keeps 120 Hz animation ticking smoothly during scrolling and menu/split tracking.
        link.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        displayLink = nil
        DisplayLinkCanvasMetrics.activeCount = max(0, DisplayLinkCanvasMetrics.activeCount - 1)
        link.invalidate()
    }

    private func applyFrameRateRange() {
        guard let link = displayLink else { return }
        let screenMax = window?.screen?.maximumFramesPerSecond ?? 120
        let clamped = frameRateProfile.clamped(toScreenMaxFPS: screenMax)
        let range = CAFrameRateRange(
            minimum: clamped.minimum,
            maximum: clamped.maximum,
            preferred: clamped.preferred
        )
        link.preferredFrameRateRange = range
        appliedFrameRateRange = range
    }

    private func syncContentsScale() {
        guard let scale = window?.backingScaleFactor, scale > 0 else { return }
        layer?.contentsScale = scale
    }

    private func rebindScreenObserver() {
        guard observedWindow !== window else { return }
        removeScreenObserver()
        observedWindow = window
        guard let window else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncContentsScale()
                if self.displayLink != nil {
                    // Recreate the link so it binds to the new screen's VSync source and max Hz.
                    self.stopDisplayLink()
                    self.syncDisplayLink()
                }
            }
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        observedWindow = nil
    }
}

/// SwiftUI bridge around `DisplayLinkCanvasNSView` for 120 Hz ProMotion vector/bitmap rendering
/// with zero SwiftUI view-graph diffing per frame.
struct DisplayLinkCanvasView: NSViewRepresentable {
    let isAnimating: Bool
    let frameRateProfile: AnimationPolicy.FrameRateProfile
    /// Bump to trigger a static redraw when `isAnimating == false` and visual inputs changed.
    var redrawToken: Int = 0
    var shouldDraw: ((_ timestamp: CFTimeInterval) -> Bool)? = nil
    let draw: (_ context: CGContext, _ size: CGSize, _ timestamp: CFTimeInterval) -> Void

    final class Coordinator {
        var lastRedrawToken: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DisplayLinkCanvasNSView {
        let view = DisplayLinkCanvasNSView()
        view.shouldDraw = shouldDraw
        view.drawFrame = draw
        view.frameRateProfile = frameRateProfile
        view.isAnimating = isAnimating
        context.coordinator.lastRedrawToken = redrawToken
        return view
    }

    func updateNSView(_ nsView: DisplayLinkCanvasNSView, context: Context) {
        nsView.shouldDraw = shouldDraw
        nsView.drawFrame = draw
        nsView.frameRateProfile = frameRateProfile
        let wasAnimating = nsView.isAnimating
        nsView.isAnimating = isAnimating
        if !isAnimating && (wasAnimating || context.coordinator.lastRedrawToken != redrawToken) {
            nsView.requestStaticRedraw()
        }
        context.coordinator.lastRedrawToken = redrawToken
    }

    static func dismantleNSView(_ nsView: DisplayLinkCanvasNSView, coordinator: Coordinator) {
        nsView.teardown()
    }
}
