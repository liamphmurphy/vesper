import Foundation
import Testing
@testable import VesperCore

@Suite("Browser Auto Dark Mode Logic & Scripts")
struct BrowserDarkModeTests {
    @Test("Global mode resolution follows system appearance in Auto mode, always on in Always, off in Off")
    func globalModeResolution() {
        let autoConfig = BrowserDarkModeConfig(mode: .auto)
        #expect(BrowserDarkModeLogic.isGloballyActive(config: autoConfig, systemIsDark: true))
        #expect(!BrowserDarkModeLogic.isGloballyActive(config: autoConfig, systemIsDark: false))

        let alwaysConfig = BrowserDarkModeConfig(mode: .always)
        #expect(BrowserDarkModeLogic.isGloballyActive(config: alwaysConfig, systemIsDark: true))
        #expect(BrowserDarkModeLogic.isGloballyActive(config: alwaysConfig, systemIsDark: false))

        let offConfig = BrowserDarkModeConfig(mode: .off)
        #expect(!BrowserDarkModeLogic.isGloballyActive(config: offConfig, systemIsDark: true))
        #expect(!BrowserDarkModeLogic.isGloballyActive(config: offConfig, systemIsDark: false))
    }

    @Test("Per-site overrides win over global mode and normalize hostnames")
    func perSiteOverrides() {
        var overrides: [String: BrowserDarkModeSiteOverride] = [:]
        overrides = BrowserDarkModeLogic.updatingSiteOverride(.off, for: "https://www.GitHub.com/liamphmurphy/vesper", in: overrides)
        overrides = BrowserDarkModeLogic.updatingSiteOverride(.on, for: "news.ycombinator.com", in: overrides)

        #expect(overrides["github.com"] == .off)
        #expect(overrides["news.ycombinator.com"] == .on)

        let autoConfig = BrowserDarkModeConfig(mode: .auto, theme: .midnight, respectNativeDarkMode: true, dimImages: false)

        // Allowlisted host stays off even when system is dark
        let ghState = BrowserDarkModeLogic.effectiveState(
            for: "https://github.com/pulls",
            config: autoConfig,
            systemIsDark: true,
            siteOverrides: overrides
        )
        #expect(!ghState.enabled)
        #expect(!ghState.forceOverride)

        // Forced host stays on with forceOverride=true even when system is light or global is off
        let hnState = BrowserDarkModeLogic.effectiveState(
            for: "https://news.ycombinator.com/newest",
            config: BrowserDarkModeConfig(mode: .off, theme: .sepia),
            systemIsDark: false,
            siteOverrides: overrides
        )
        #expect(hnState.enabled)
        #expect(hnState.forceOverride)
        #expect(hnState.theme == .sepia)

        // Resetting to .inherit removes the host entry
        let cleaned = BrowserDarkModeLogic.updatingSiteOverride(.inherit, for: "github.com", in: overrides)
        #expect(cleaned["github.com"] == nil)
        #expect(cleaned["news.ycombinator.com"] == .on)
    }

    @Test("Non-web URLs (webkit-extension, about:blank) never receive dark mode")
    func nonWebURLsAreExcluded() {
        let config = BrowserDarkModeConfig(mode: .always)
        let extState = BrowserDarkModeLogic.effectiveState(
            for: "webkit-extension://abc123/popup.html",
            config: config,
            systemIsDark: true,
            siteOverrides: [:]
        )
        #expect(!extState.enabled)

        let blankState = BrowserDarkModeLogic.effectiveState(
            for: "about:blank",
            config: config,
            systemIsDark: true,
            siteOverrides: [:]
        )
        #expect(!blankState.enabled)
    }

    @Test("Smart 1-click toggle handles applied, native-dark skipped, and off states")
    func smartToggleSiteOverride() {
        let autoConfig = BrowserDarkModeConfig(mode: .auto)

        // Currently applied via Auto -> toggle disables for this site
        let fromApplied = BrowserDarkModeLogic.toggledSiteOverride(
            for: "https://example.com",
            config: autoConfig,
            systemIsDark: true,
            siteOverrides: [:],
            currentStatus: .applied
        )
        #expect(fromApplied == .off)

        // Currently skipped because of native dark mode -> toggle forces dark
        let fromNative = BrowserDarkModeLogic.toggledSiteOverride(
            for: "https://dark-site.example",
            config: autoConfig,
            systemIsDark: true,
            siteOverrides: [:],
            currentStatus: .skippedNative
        )
        #expect(fromNative == .on)

        // Currently disabled per-site while global is active -> toggle returns to Auto (.inherit)
        let fromOff = BrowserDarkModeLogic.toggledSiteOverride(
            for: "https://example.com",
            config: autoConfig,
            systemIsDark: true,
            siteOverrides: ["example.com": .off],
            currentStatus: .inactive
        )
        #expect(fromOff == .inherit)
    }

    @Test("Brightness and contrast values clamp to safe ranges")
    func brightnessAndContrastClamping() {
        let config = BrowserDarkModeConfig(brightness: 5.0, contrast: 0.1)
        #expect(config.brightness == BrowserDarkModeConfig.maxBrightness)
        #expect(config.contrast == BrowserDarkModeConfig.minContrast)
        #expect(config.hasCustomAdjustments)

        let nanConfig = BrowserDarkModeConfig(brightness: .nan, contrast: .infinity)
        #expect(nanConfig.brightness == 1.0)
        #expect(nanConfig.contrast == 1.0)
        #expect(!nanConfig.hasCustomAdjustments)
    }

    @Test("User script and live update JS embed theme, native detection, and media preservation")
    func scriptGeneration() {
        let state = BrowserDarkModeEffectiveState(
            enabled: true,
            forceOverride: false,
            theme: .sepia,
            respectNativeDarkMode: true,
            dimImages: true,
            brightness: 1.05,
            contrast: 1.1
        )
        let script = BrowserDarkModeScripts.makeUserScriptSource(for: state)
        #expect(script.contains("__vesper_dark_mode_style__"))
        #expect(script.contains("__vesperDarkModeApply"))
        #expect(script.contains(BrowserDarkModeScripts.handlerName))
        #expect(script.contains("sepia(0.18)"))
        #expect(script.contains("brightness(0.88)"))
        #expect(script.contains("#__vesper_reader_overlay__"))
        #expect(script.contains(BrowserDarkModeTheme.sepia.backgroundHex))

        let liveJS = BrowserDarkModeScripts.makeLiveUpdateJS(for: .disabled)
        #expect(liveJS.contains("__vesperDarkModeApply"))
        #expect(liveJS.contains("\"enabled\":false"))
    }

    @Test("BrowserStorage round-trips dark mode config and per-profile site overrides")
    func persistenceRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-browser-darkmode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = BrowserStorage.fileURL(dataDirectory: tempDir)

        var profile = BrowserProfile.defaultPersonal()
        profile.darkModeSiteOverrides = [
            "github.com": .off,
            "news.ycombinator.com": .on,
        ]
        let config = BrowserDarkModeConfig(
            mode: .always,
            theme: .slate,
            respectNativeDarkMode: false,
            dimImages: false,
            brightness: 0.95,
            contrast: 1.15
        )
        let state = BrowserPersistedState(
            profiles: [profile],
            activeProfileId: profile.id,
            darkModeConfig: config
        )
        try BrowserStorage.save(state, to: fileURL)
        let loaded = BrowserStorage.load(from: fileURL)

        #expect(loaded.darkModeConfig == config)
        let loadedProfile = try #require(loaded.profiles.first)
        #expect(loadedProfile.darkModeSiteOverrides == [
            "github.com": .off,
            "news.ycombinator.com": .on,
        ])
    }
}
