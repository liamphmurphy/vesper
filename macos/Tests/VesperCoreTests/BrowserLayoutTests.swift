import Foundation
import Testing
@testable import VesperCore

@Suite("Browser layout & default zoom")
struct BrowserLayoutTests {
    @Test("Default layout config and zoom clamping")
    func defaultConfigAndZoomClamping() {
        let def = BrowserLayoutConfig.default
        #expect(def.autoHideOmnibox == false)
        #expect(def.hoverPeekSidebar == true)
        #expect(def.defaultZoom == 1.0)

        #expect(BrowserLayoutConfig.clampZoom(0.1) == BrowserLayoutConfig.minZoom)
        #expect(BrowserLayoutConfig.clampZoom(5.0) == BrowserLayoutConfig.maxZoom)
        #expect(BrowserLayoutConfig.clampZoom(.nan) == 1.0)
        #expect(BrowserLayoutConfig.clampZoom(0.9) == 0.9)
    }

    @Test("Effective zoom prefers per-site override over default zoom")
    func effectiveZoomResolution() {
        let cfg = BrowserLayoutConfig(defaultZoom: 0.9)
        let siteZooms = ["github.com": 1.15]

        #expect(cfg.effectiveZoom(for: "github.com", siteZooms: siteZooms) == 1.15)
        #expect(cfg.effectiveZoom(for: "GitHub.com", siteZooms: siteZooms) == 1.15)
        #expect(cfg.effectiveZoom(for: "example.com", siteZooms: siteZooms) == 0.9)
        #expect(cfg.effectiveZoom(for: nil, siteZooms: siteZooms) == 0.9)
    }

    @Test("Persisted state round-trips layoutConfig and decodes legacy JSON cleanly")
    func persistenceRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-layout-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        var state = BrowserPersistedState.empty
        state.layoutConfig = BrowserLayoutConfig(
            autoHideOmnibox: true,
            hoverPeekSidebar: false,
            defaultZoom: 0.85
        )
        try BrowserStorage.save(state, to: tmp)

        let loaded = BrowserStorage.load(from: tmp)
        #expect(loaded.layoutConfig == state.layoutConfig)

        // Legacy JSON without layout_config should decode with defaults.
        let legacy = Data("{\"ad_block_enabled\":true}".utf8)
        let decoded = try JSONDecoder().decode(BrowserPersistedState.self, from: legacy)
        #expect(decoded.layoutConfig == .default)
    }
}
