import AppKit
import Observation
import QuartzCore
import VesperCore

/// Global toggle for the opt-in Performance HUD (`VESPER_PERF_HUD=1` or View ▸ Show Performance HUD).
/// Off by default so normal sessions attach zero HUD display links and perform zero HUD redraws.
@MainActor
@Observable
final class PerfHUDSettings {
    static let envKey = "VESPER_PERF_HUD"
    static let defaultsKey = "VesperPerfHUDEnabled"
    static let shared = PerfHUDSettings()

    private(set) var isEnabled: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.isEnabled = environment[Self.envKey] == "1" || defaults.bool(forKey: Self.defaultsKey)
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}

/// Weak trampoline breaking `CADisplayLink`'s strong retain of its target.
@MainActor
private final class PerfHUDDisplayLinkTrampoline: NSObject {
    weak var owner: PerfHUDView?

    init(owner: PerfHUDView) {
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

/// Lightweight, opaque, click-through AppKit overlay pill displaying live FPS, 1% low FPS,
/// average frame time, display refresh rate, active DisplayLink canvas count, and a 60-frame
/// color-coded frame-time sparkline.
///
/// Samples VSync delivery intervals on `RunLoop.Mode.common` in O(1) with zero heap allocations
/// and redraws only at 4 Hz (every 250ms) without any `NSVisualEffectView` backdrop blur so the
/// HUD itself never distorts the frame rate it measures.
@MainActor
final class PerfHUDView: NSView {
    private static let pillSize = NSSize(width: 236, height: 48)
    private static let redrawInterval: CFTimeInterval = 0.25
    private static let sparklineCeilingMs: Double = 33.33

    private static let bgColor = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.90)
    private static let borderColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15)
    private static let smoothColor = NSColor(srgbRed: 0.22, green: 0.84, blue: 0.56, alpha: 1)
    private static let cautionColor = NSColor(srgbRed: 0.98, green: 0.75, blue: 0.20, alpha: 1)
    private static let hitchColor = NSColor(srgbRed: 0.97, green: 0.42, blue: 0.42, alpha: 1)
    private static let mutedTextColor = NSColor(srgbRed: 0.78, green: 0.81, blue: 0.86, alpha: 0.92)
    private static let badgeTextColor = NSColor(srgbRed: 0.62, green: 0.67, blue: 0.75, alpha: 0.92)
    private static let splitBadgeFill = NSColor(srgbRed: 0.36, green: 0.56, blue: 0.98, alpha: 0.26)
    private static let splitBadgeText = NSColor(srgbRed: 0.68, green: 0.82, blue: 1.0, alpha: 1)
    private static let budgetLineColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18)

    private static let fpsFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    var isEnabled: Bool = false {
        didSet {
            isHidden = !isEnabled
            if !isEnabled {
                metrics.reset()
                latestSnapshot = metrics.snapshot()
                lastRedrawAt = 0
            }
            syncDisplayLink()
            if isEnabled {
                needsDisplay = true
            }
        }
    }

    /// Production views pause while minimized/occluded; unit tests may disable window visibility
    /// gating when hosting in an off-screen `NSWindow`.
    var requireWindowVisibility: Bool = true

    private var metrics = PerfHUDMetrics(capacity: 60, targetFPS: 120)
    private var latestSnapshot: PerfHUDMetrics.Snapshot
    private var latestCanvasCount: Int = 0
    private var latestSplitAnimating: Bool = false
    private var lastRedrawAt: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var windowObservers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?

    var hasActiveDisplayLink: Bool { displayLink != nil }

    override init(frame frameRect: NSRect) {
        self.latestSnapshot = metrics.snapshot()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { Self.pillSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebindWindowObservers()
        updateTargetFPSFromScreen()
        syncDisplayLink()
    }

    override func viewDidHide() {
        super.viewDidHide()
        syncDisplayLink()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncDisplayLink()
    }

    func teardown() {
        stopDisplayLink()
        removeWindowObservers()
    }

    fileprivate func handleDisplayLinkTick(_ link: CADisplayLink) {
        guard shouldRunDisplayLink else {
            stopDisplayLink()
            return
        }
        let ts = link.timestamp > 0 ? link.timestamp : CACurrentMediaTime()
        metrics.recordTick(timestamp: ts)
        if lastRedrawAt == 0 || (ts - lastRedrawAt) >= Self.redrawInterval {
            lastRedrawAt = ts
            latestSnapshot = metrics.snapshot()
            latestCanvasCount = DisplayLinkCanvasMetrics.activeCount
            latestSplitAnimating = SplitAnimationCoordinator.shared.hasActiveAnimation
            needsDisplay = true
        }
    }

    private var shouldRunDisplayLink: Bool {
        guard isEnabled, let window, !isHiddenOrHasHiddenAncestor else { return false }
        guard requireWindowVisibility else { return true }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func syncDisplayLink() {
        if shouldRunDisplayLink {
            if displayLink == nil {
                startDisplayLink()
            }
        } else {
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard window != nil, displayLink == nil else { return }
        updateTargetFPSFromScreen()
        let trampoline = PerfHUDDisplayLinkTrampoline(owner: self)
        let link = self.displayLink(target: trampoline, selector: #selector(PerfHUDDisplayLinkTrampoline.step(_:)))
        let screenMax = Float(max(window?.screen?.maximumFramesPerSecond ?? 120, 30))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: screenMax, preferred: screenMax)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        displayLink = nil
        link.invalidate()
    }

    private func updateTargetFPSFromScreen() {
        let maxFPS = window?.screen?.maximumFramesPerSecond ?? 120
        metrics.setTargetFPS(maxFPS)
        if let scale = window?.backingScaleFactor, scale > 0 {
            layer?.contentsScale = scale
        }
    }

    private func rebindWindowObservers() {
        guard observedWindow !== window else { return }
        removeWindowObservers()
        observedWindow = window
        guard let window else { return }

        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateTargetFPSFromScreen()
                if self.displayLink != nil {
                    self.stopDisplayLink()
                    self.syncDisplayLink()
                }
            }
        })
        let visibilityNotifications: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        for name in visibilityNotifications {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncDisplayLink() }
            })
        }
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopDisplayLink() }
        })
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        for token in windowObservers {
            center.removeObserver(token)
        }
        windowObservers.removeAll()
        observedWindow = nil
    }

    private func color(for health: PerfHUDMetrics.FrameHealth) -> NSColor {
        switch health {
        case .smooth: Self.smoothColor
        case .caution: Self.cautionColor
        case .hitch: Self.hitchColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else { return }

        // Opaque dark rounded pill + 1pt hairline border (zero backdrop blur cost).
        let pillRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)
        cg.setFillColor(Self.bgColor.cgColor)
        cg.addPath(pillPath)
        cg.fillPath()
        cg.setStrokeColor(Self.borderColor.cgColor)
        cg.setLineWidth(1)
        cg.addPath(pillPath)
        cg.strokePath()

        let snap = latestSnapshot
        let healthColor = color(for: snap.health)

        // Status dot
        cg.setFillColor(healthColor.cgColor)
        cg.fillEllipse(in: CGRect(x: 9, y: 9.5, width: 6, height: 6))

        // Live FPS + 1% low + avg ms
        let fpsText = snap.fps > 0 ? String(format: "%3.0f FPS", snap.fps) : " -- FPS"
        (fpsText as NSString).draw(
            at: NSPoint(x: 18, y: 5.5),
            withAttributes: [.font: Self.fpsFont, .foregroundColor: healthColor]
        )

        let detailText: String = if snap.avgFrameTimeMs > 0 {
            String(format: "1%% %2.0f · %.1fms", snap.onePercentLowFPS, snap.avgFrameTimeMs)
        } else {
            "sampling…"
        }
        (detailText as NSString).draw(
            at: NSPoint(x: 72, y: 6.5),
            withAttributes: [.font: Self.detailFont, .foregroundColor: Self.mutedTextColor]
        )

        // Trailing badge: SPLIT indicator during transitions, else refresh rate + active canvas count.
        let badgeString: String
        let badgeFg: NSColor
        if latestSplitAnimating {
            badgeString = "SPLIT"
            badgeFg = Self.splitBadgeText
        } else if latestCanvasCount > 0 {
            badgeString = "\(snap.targetFPS)Hz·\(latestCanvasCount)c"
            badgeFg = Self.badgeTextColor
        } else {
            badgeString = "\(snap.targetFPS)Hz"
            badgeFg = Self.badgeTextColor
        }
        let badgeAttrs: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: badgeFg]
        let badgeSize = (badgeString as NSString).size(withAttributes: badgeAttrs)
        let badgeX = bounds.width - 9 - badgeSize.width
        if latestSplitAnimating {
            let tagRect = CGRect(x: badgeX - 4, y: 5.5, width: badgeSize.width + 8, height: 13)
            let tagPath = CGPath(roundedRect: tagRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
            cg.setFillColor(Self.splitBadgeFill.cgColor)
            cg.addPath(tagPath)
            cg.fillPath()
        }
        (badgeString as NSString).draw(at: NSPoint(x: badgeX, y: 6.5), withAttributes: badgeAttrs)

        // 60-bar frame-time sparkline along the bottom.
        let graphRect = CGRect(x: 9, y: 24, width: bounds.width - 18, height: 18)
        let budgetFraction = min(1.0, snap.targetFrameTimeMs / Self.sparklineCeilingMs)
        let budgetY = graphRect.maxY - CGFloat(budgetFraction) * graphRect.height
        cg.setStrokeColor(Self.budgetLineColor.cgColor)
        cg.setLineWidth(0.75)
        cg.strokeLineSegments(between: [
            CGPoint(x: graphRect.minX, y: budgetY),
            CGPoint(x: graphRect.maxX, y: budgetY),
        ])

        let samples = snap.recentFrameTimesMs
        guard !samples.isEmpty else { return }
        let slotCount = CGFloat(metrics.capacity)
        let step = graphRect.width / slotCount
        let barWidth = max(1.5, step - 0.8)
        let startSlot = metrics.capacity - samples.count
        for (idx, ms) in samples.enumerated() {
            let fraction = min(1.0, max(0.0, ms / Self.sparklineCeilingMs))
            let barHeight = max(2.0, CGFloat(fraction) * graphRect.height)
            let x = graphRect.minX + CGFloat(startSlot + idx) * step
            let barRect = CGRect(x: x, y: graphRect.maxY - barHeight, width: barWidth, height: barHeight)
            cg.setFillColor(color(for: metrics.classify(frameTimeMs: ms)).cgColor)
            cg.fill(barRect)
        }
    }
}
