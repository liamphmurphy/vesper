import Foundation

// MARK: - Auto Dark Mode Models

public enum BrowserDarkModeMode: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case auto
    case always
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .always: "Always"
        case .off: "Off"
        }
    }

    public var summary: String {
        switch self {
        case .auto: "Follows Vesper / macOS appearance"
        case .always: "Always darken light websites"
        case .off: "Disabled unless forced per site"
        }
    }
}

public enum BrowserDarkModeTheme: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case `default`
    case midnight
    case slate
    case sepia

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: "Default"
        case .midnight: "Midnight"
        case .slate: "Slate"
        case .sepia: "Warm"
        }
    }

    /// Background canvas hex used for root overscroll / transparent page canvas.
    public var backgroundHex: String {
        switch self {
        case .default: "#181a1b"
        case .midnight: "#0b0d10"
        case .slate: "#191e26"
        case .sepia: "#1d1a16"
        }
    }

    /// Swatch preview accent hex for UI chips.
    public var swatchBorderHex: String {
        switch self {
        case .default: "#3a3e42"
        case .midnight: "#242933"
        case .slate: "#374357"
        case .sepia: "#4a3f32"
        }
    }

    /// Base CSS filter multiplier applied on top of user brightness/contrast.
    public var baseBrightness: Double {
        switch self {
        case .default: 0.94
        case .midnight: 0.88
        case .slate: 0.92
        case .sepia: 0.92
        }
    }

    public var baseContrast: Double {
        switch self {
        case .default: 0.95
        case .midnight: 1.06
        case .slate: 0.96
        case .sepia: 0.94
        }
    }

    public var sepiaAmount: Double {
        switch self {
        case .default: 0.0
        case .midnight: 0.0
        case .slate: 0.0
        case .sepia: 0.18
        }
    }

    /// Optional subtle hue nudge (in degrees, relative to the 180° inversion rotation).
    public var hueOffsetDegrees: Double {
        switch self {
        case .default: 0
        case .midnight: 0
        case .slate: 8
        case .sepia: -4
        }
    }
}

public enum BrowserDarkModeSiteOverride: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case inherit
    case on
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inherit: "Auto"
        case .on: "Force Dark"
        case .off: "Off"
        }
    }
}

public enum BrowserDarkModePageStatus: String, Codable, Sendable, Equatable, Hashable {
    case inactive
    case applied
    case skippedNative = "skipped_native"
}

public struct BrowserDarkModeConfig: Codable, Sendable, Equatable, Hashable {
    public static let minBrightness: Double = 0.85
    public static let maxBrightness: Double = 1.15
    public static let minContrast: Double = 0.85
    public static let maxContrast: Double = 1.25

    public var mode: BrowserDarkModeMode
    public var theme: BrowserDarkModeTheme
    /// Automatically backs off on websites that already render a native dark theme.
    public var respectNativeDarkMode: Bool
    /// Slightly dims bright images and videos in dark mode (restores on hover).
    public var dimImages: Bool
    public var brightness: Double
    public var contrast: Double

    public static let `default` = BrowserDarkModeConfig()

    public init(
        mode: BrowserDarkModeMode = .auto,
        theme: BrowserDarkModeTheme = .default,
        respectNativeDarkMode: Bool = true,
        dimImages: Bool = true,
        brightness: Double = 1.0,
        contrast: Double = 1.0
    ) {
        self.mode = mode
        self.theme = theme
        self.respectNativeDarkMode = respectNativeDarkMode
        self.dimImages = dimImages
        self.brightness = Self.clampBrightness(brightness)
        self.contrast = Self.clampContrast(contrast)
    }

    public static func clampBrightness(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let clamped = min(maxBrightness, max(minBrightness, value))
        return (clamped * 100).rounded() / 100
    }

    public static func clampContrast(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let clamped = min(maxContrast, max(minContrast, value))
        return (clamped * 100).rounded() / 100
    }

    public var hasCustomAdjustments: Bool {
        abs(brightness - 1.0) >= 0.01 || abs(contrast - 1.0) >= 0.01
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case theme
        case respectNativeDarkMode = "respect_native_dark_mode"
        case dimImages = "dim_images"
        case brightness
        case contrast
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(BrowserDarkModeMode.self, forKey: .mode) ?? .auto
        theme = try c.decodeIfPresent(BrowserDarkModeTheme.self, forKey: .theme) ?? .default
        respectNativeDarkMode = try c.decodeIfPresent(Bool.self, forKey: .respectNativeDarkMode) ?? true
        dimImages = try c.decodeIfPresent(Bool.self, forKey: .dimImages) ?? true
        brightness = Self.clampBrightness(try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0)
        contrast = Self.clampContrast(try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0)
    }
}

/// Resolved per-page dark mode parameters passed to the WebKit user script and live-update bridge.
public struct BrowserDarkModeEffectiveState: Codable, Sendable, Equatable, Hashable {
    public var enabled: Bool
    /// True when the user explicitly selected `.on` for this host, bypassing native dark detection.
    public var forceOverride: Bool
    public var theme: BrowserDarkModeTheme
    public var respectNativeDarkMode: Bool
    public var dimImages: Bool
    public var brightness: Double
    public var contrast: Double

    public static let disabled = BrowserDarkModeEffectiveState(
        enabled: false,
        forceOverride: false,
        theme: .default,
        respectNativeDarkMode: true,
        dimImages: true,
        brightness: 1.0,
        contrast: 1.0
    )

    public init(
        enabled: Bool,
        forceOverride: Bool,
        theme: BrowserDarkModeTheme,
        respectNativeDarkMode: Bool,
        dimImages: Bool,
        brightness: Double,
        contrast: Double
    ) {
        self.enabled = enabled
        self.forceOverride = forceOverride
        self.theme = theme
        self.respectNativeDarkMode = respectNativeDarkMode
        self.dimImages = dimImages
        self.brightness = BrowserDarkModeConfig.clampBrightness(brightness)
        self.contrast = BrowserDarkModeConfig.clampContrast(contrast)
    }
}

// MARK: - Pure Resolution Logic

public enum BrowserDarkModeLogic {
    /// Looks up the per-site dark mode override for a URL or host string.
    public static func siteOverride(
        for urlString: String,
        overrides: [String: BrowserDarkModeSiteOverride]
    ) -> BrowserDarkModeSiteOverride {
        guard let host = BrowserPageGuard.normalizeHost(urlString) else { return .inherit }
        return overrides[host] ?? .inherit
    }

    /// Computes whether dark mode is globally active for the given config and app appearance.
    public static func isGloballyActive(
        config: BrowserDarkModeConfig,
        systemIsDark: Bool
    ) -> Bool {
        switch config.mode {
        case .auto: systemIsDark
        case .always: true
        case .off: false
        }
    }

    /// Resolves the exact dark mode state to apply to a given URL.
    public static func effectiveState(
        for urlString: String,
        config: BrowserDarkModeConfig,
        systemIsDark: Bool,
        siteOverrides: [String: BrowserDarkModeSiteOverride]
    ) -> BrowserDarkModeEffectiveState {
        // Non-web pages (empty, about:blank, webkit-extension) are never darkened.
        if !urlString.isEmpty,
           let url = URL(string: urlString),
           !BrowserURLResolver.isWebURL(url)
        {
            return .disabled
        }

        let override = siteOverride(for: urlString, overrides: siteOverrides)
        let enabled: Bool
        let forceOverride: Bool
        switch override {
        case .on:
            enabled = true
            forceOverride = true
        case .off:
            enabled = false
            forceOverride = false
        case .inherit:
            enabled = isGloballyActive(config: config, systemIsDark: systemIsDark)
            forceOverride = false
        }

        return BrowserDarkModeEffectiveState(
            enabled: enabled,
            forceOverride: forceOverride,
            theme: config.theme,
            respectNativeDarkMode: config.respectNativeDarkMode,
            dimImages: config.dimImages,
            brightness: config.brightness,
            contrast: config.contrast
        )
    }

    /// Updates a per-site overrides dictionary cleanly, removing `.inherit` entries.
    public static func updatingSiteOverride(
        _ override: BrowserDarkModeSiteOverride,
        for rawHost: String,
        in overrides: [String: BrowserDarkModeSiteOverride]
    ) -> [String: BrowserDarkModeSiteOverride] {
        guard let host = BrowserPageGuard.normalizeHost(rawHost) else { return overrides }
        var next = overrides
        if override == .inherit {
            next.removeValue(forKey: host)
        } else {
            next[host] = override
        }
        return next
    }

    /// Computes the next per-site override when the user triggers a 1-click toggle (e.g. `⌥⌘D`).
    public static func toggledSiteOverride(
        for urlString: String,
        config: BrowserDarkModeConfig,
        systemIsDark: Bool,
        siteOverrides: [String: BrowserDarkModeSiteOverride],
        currentStatus: BrowserDarkModePageStatus
    ) -> BrowserDarkModeSiteOverride {
        let current = siteOverride(for: urlString, overrides: siteOverrides)
        let globalActive = isGloballyActive(config: config, systemIsDark: systemIsDark)

        switch current {
        case .on:
            return globalActive ? .off : .inherit
        case .off:
            return globalActive ? .inherit : .on
        case .inherit:
            if currentStatus == .applied {
                return .off
            }
            if currentStatus == .skippedNative {
                return .on
            }
            return globalActive ? .off : .on
        }
    }
}
