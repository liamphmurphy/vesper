import AppKit
import Testing
import VesperCore
@testable import Vesper

@MainActor
@Suite("PerfHUD")
struct PerfHUDTests {
    @Test("PerfHUDSettings respects VESPER_PERF_HUD env var and UserDefaults persistence")
    func settingsEnvAndTogglePersistence() {
        let suiteName = "com.vesper.tests.perfhud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let offByDefault = PerfHUDSettings(environment: [:], defaults: defaults)
        #expect(!offByDefault.isEnabled)

        offByDefault.toggle()
        #expect(offByDefault.isEnabled)
        #expect(defaults.bool(forKey: PerfHUDSettings.defaultsKey))

        let reloaded = PerfHUDSettings(environment: [:], defaults: defaults)
        #expect(reloaded.isEnabled)

        reloaded.setEnabled(false)
        #expect(!reloaded.isEnabled)

        let envEnabled = PerfHUDSettings(environment: [PerfHUDSettings.envKey: "1"], defaults: defaults)
        #expect(envEnabled.isEnabled)
    }

    @Test("PerfHUDView is click-through, runs zero display links when disabled, and toggles cleanly")
    func viewLifecycleAndClickThrough() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = root

        let hud = PerfHUDView(frame: NSRect(x: 150, y: 20, width: 236, height: 48))
        hud.requireWindowVisibility = false
        root.addSubview(hud)
        defer {
            hud.teardown()
            window.close()
        }

        // Disabled by default: hidden, click-through, no display link.
        #expect(hud.isHidden)
        #expect(!hud.hasActiveDisplayLink)
        #expect(hud.hitTest(NSPoint(x: 200, y: 40)) == nil)

        // Enabling unhides and attaches its CADisplayLink.
        hud.isEnabled = true
        #expect(!hud.isHidden)
        #expect(hud.hasActiveDisplayLink)
        #expect(hud.hitTest(NSPoint(x: 200, y: 40)) == nil)

        // Exercise draw(_:) cleanly via bitmap capture.
        let rep = hud.bitmapImageRepForCachingDisplay(in: hud.bounds)!
        hud.cacheDisplay(in: hud.bounds, to: rep)

        // Disabling hides and tears down the display link completely.
        hud.isEnabled = false
        #expect(hud.isHidden)
        #expect(!hud.hasActiveDisplayLink)
    }
}
