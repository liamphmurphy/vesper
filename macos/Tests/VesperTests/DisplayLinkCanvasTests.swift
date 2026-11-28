import AppKit
import QuartzCore
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("DisplayLinkCanvasNSView", .serialized)
struct DisplayLinkCanvasTests {
    private func makeHostedView() -> (NSWindow, DisplayLinkCanvasNSView) {
        let view = DisplayLinkCanvasNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        window.contentView = root
        root.addSubview(view)
        return (window, view)
    }

    @Test("display link only runs while attached, visible, and animating, and applies ProMotion range")
    func lifecycleAndFrameRateRange() {
        let baseline = DisplayLinkCanvasMetrics.activeCount
        let (window, view) = makeHostedView()
        defer {
            view.teardown()
            window.close()
        }

        // Static mode: zero display link overhead.
        #expect(!view.hasActiveDisplayLink)
        #expect(DisplayLinkCanvasMetrics.activeCount == baseline)

        // Enabling animation attaches a CADisplayLink configured for the current screen's max refresh rate.
        view.frameRateProfile = AnimationPolicy.displayLinkFrameRate(working: true, lowPowerMode: false)
        view.isAnimating = true
        #expect(view.hasActiveDisplayLink)
        #expect(DisplayLinkCanvasMetrics.activeCount == baseline + 1)

        let screenMax = Float(max(window.screen?.maximumFramesPerSecond ?? 120, 30))
        let expectedMax = min(Float(120), screenMax)
        #expect(view.appliedFrameRateRange?.maximum == expectedMax)
        #expect(view.appliedFrameRateRange?.preferred == expectedMax)

        // Switching to Low Power Mode updates the range in place to 30–60Hz without leaking links.
        view.frameRateProfile = AnimationPolicy.displayLinkFrameRate(working: true, lowPowerMode: true)
        #expect(view.appliedFrameRateRange?.preferred == 30)
        #expect(DisplayLinkCanvasMetrics.activeCount == baseline + 1)

        // Hiding the view stops and invalidates its display link immediately.
        view.isHidden = true
        #expect(!view.hasActiveDisplayLink)
        #expect(DisplayLinkCanvasMetrics.activeCount == baseline)

        // Unhiding re-arms it, and removing from superview tears it down again.
        view.isHidden = false
        #expect(view.hasActiveDisplayLink)
        #expect(DisplayLinkCanvasMetrics.activeCount == baseline + 1)

        view.removeFromSuperview()
        #expect(!view.hasActiveDisplayLink)
        #expect(DisplayLinkCanvasMetrics.activeCount == baseline)
    }

    @Test("static redraws draw into a Y-down CGContext without attaching a display link")
    func staticRedrawDrawsYDownWithoutDisplayLink() {
        let (window, view) = makeHostedView()
        defer {
            view.teardown()
            window.close()
        }

        var recordedSizes: [CGSize] = []
        view.drawFrame = { _, size, _ in
            recordedSizes.append(size)
        }
        view.isAnimating = false
        #expect(view.isFlipped)
        #expect(!view.hasActiveDisplayLink)

        // Render into a bitmap offscreen rep via cacheDisplay to exercise draw(_:).
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(view.drawCallCount >= 1)
        #expect(!recordedSizes.isEmpty)
        #expect(recordedSizes.allSatisfy { $0 == CGSize(width: 120, height: 60) })
        #expect(!view.hasActiveDisplayLink)
    }
}
