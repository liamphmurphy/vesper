import Foundation

public enum AppearanceMode: String, Codable, Sendable, CaseIterable, Equatable {
    case system, dark, light
}

public enum AppearanceTextSize: String, Codable, Sendable, CaseIterable, Equatable {
    case xsmall, small, `default`, large, larger, xlarge, xxlarge, xxxlarge

    /// Type scale factor applied across native views (`ThemeTokens.typeScale`).
    public var scale: Double {
        switch self {
        case .xsmall: 0.80
        case .small: 0.92
        case .default: 1.0
        case .large: 1.12
        case .larger: 1.25
        case .xlarge: 1.40
        case .xxlarge: 1.55
        case .xxxlarge: 1.75
        }
    }

    /// Percentage label for settings and tooltips (e.g. "100%", "125%").
    public var percentLabel: String {
        "\(Int((scale * 100).rounded()))%"
    }

    public var canStepIn: Bool { self != Self.allCases.last }
    public var canStepOut: Bool { self != Self.allCases.first }

    /// Next larger step, clamped at the maximum.
    public func steppedIn() -> AppearanceTextSize {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx + 1 < all.count else { return self }
        return all[idx + 1]
    }

    /// Next smaller step, clamped at the minimum.
    public func steppedOut() -> AppearanceTextSize {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self), idx > 0 else { return self }
        return all[idx - 1]
    }
}

public struct CustomPaletteOverrides: Codable, Sendable, Equatable {
    public var base: String
    public var dark: [String: String]
    public var light: [String: String]

    public init(base: String = "neutral", dark: [String: String] = [:], light: [String: String] = [:]) {
        self.base = base
        self.dark = dark
        self.light = light
    }
}

/// Persisted appearance settings: mirrors `la-theme` + `la-appearance` in `web/components/shell/theme.tsx`.
public struct AppearancePreference: Codable, Sendable, Equatable {
    public static let contentTextScaleRange: ClosedRange<Double> = 0.80...1.75

    public var mode: AppearanceMode
    public var palette: String
    public var textSize: AppearanceTextSize
    /// Independent scale factor for page/document content (Knowledge, Docs, Markdown, Chat), 0.80–1.75.
    public var contentTextScale: Double
    public var custom: CustomPaletteOverrides

    public init(
        mode: AppearanceMode = .system,
        palette: String = "macos",
        textSize: AppearanceTextSize = .default,
        contentTextScale: Double = 1.0,
        custom: CustomPaletteOverrides = CustomPaletteOverrides()
    ) {
        self.mode = mode
        self.palette = palette
        self.textSize = textSize
        self.contentTextScale = Self.clampContentTextScale(contentTextScale)
        self.custom = custom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(AppearanceMode.self, forKey: .mode) ?? .system
        palette = try c.decodeIfPresent(String.self, forKey: .palette) ?? "macos"
        textSize = try c.decodeIfPresent(AppearanceTextSize.self, forKey: .textSize) ?? .default
        contentTextScale = Self.clampContentTextScale(try c.decodeIfPresent(Double.self, forKey: .contentTextScale) ?? 1.0)
        custom = try c.decodeIfPresent(CustomPaletteOverrides.self, forKey: .custom) ?? CustomPaletteOverrides()
    }

    public static func clampContentTextScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let clamped = min(max(value, contentTextScaleRange.lowerBound), contentTextScaleRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    /// Percentage label for `contentTextScale` (e.g. "100%", "125%").
    public var contentTextPercentLabel: String {
        "\(Int((Self.clampContentTextScale(contentTextScale) * 100).rounded()))%"
    }

    public static let macOSDefault = AppearancePreference()

    /// The resolved color mode for a given system color scheme.
    public func effectiveColorMode(system: ColorMode) -> ColorMode {
        switch mode {
        case .system: return system
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// Serializes the `la-appearance` localStorage JSON payload consumed by `web/lib/palettes.ts`.
    public func webAppearanceJSON() -> String {
        struct WebAppearancePayload: Encodable {
            let version: Int = 1
            let palette: String
            let custom: CustomPaletteOverrides
            let textSize: String
        }
        let payload = WebAppearancePayload(
            palette: palette,
            custom: custom,
            textSize: textSize.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// Exports palette settings (`{ version: 1, palette, custom }`) matching `appearance-section.tsx`.
    public func exportPaletteJSON() throws -> Data {
        struct ExportPayload: Encodable {
            let version: Int = 1
            let palette: String
            let custom: CustomPaletteOverrides
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ExportPayload(palette: palette, custom: custom))
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case tooLarge
        case invalidFormat

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "Use a palette JSON file smaller than 40 KB."
            case .invalidFormat: return "This file is not a Vesper palette."
            }
        }
    }

    /// Parses an imported `vesper-palette.json` file with the 40 KB cap, preserving `mode`
    /// and `textSize` from `preserving`.
    public static func importPaletteJSON(_ data: Data, preserving current: AppearancePreference) throws -> AppearancePreference {
        if data.count > 40_000 { throw ImportError.tooLarge }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["version"] as? NSNumber)?.intValue == 1,
              let rawPalette = obj["palette"] as? String,
              rawPalette == "custom" || PaletteTokens.palette(id: rawPalette) != nil
        else { throw ImportError.invalidFormat }
        var next = current
        next.palette = rawPalette
        next.custom = normalizeCustom(obj["custom"], fallback: CustomPaletteOverrides())
        return next
    }

    /// Normalizes a partial/untrusted dictionary (for `NativeSettings.normalize`).
    public static func normalize(_ raw: Any?, base: AppearancePreference = AppearancePreference()) -> AppearancePreference {
        guard let src = raw as? [String: Any] else { return base }
        var out = base
        if let m = src["mode"] as? String, let parsed = AppearanceMode(rawValue: m) { out.mode = parsed }
        if let p = src["palette"] as? String, p == "custom" || PaletteTokens.palette(id: p) != nil { out.palette = p }
        if let ts = src["textSize"] as? String, let parsed = AppearanceTextSize(rawValue: ts) { out.textSize = parsed }
        if let cs = (src["contentTextScale"] as? NSNumber)?.doubleValue {
            out.contentTextScale = clampContentTextScale(cs)
        }
        if src["custom"] != nil {
            out.custom = normalizeCustom(src["custom"], fallback: base.custom)
        }
        return out
    }

    private static func normalizeCustom(_ raw: Any?, fallback: CustomPaletteOverrides) -> CustomPaletteOverrides {
        guard let src = raw as? [String: Any] else { return fallback }
        var out = fallback
        if let b = src["base"] as? String, PaletteTokens.palette(id: b) != nil { out.base = b }
        if src["dark"] is [String: Any] { out.dark = PaletteTokens.cleanOverrides(src["dark"]) }
        if src["light"] is [String: Any] { out.light = PaletteTokens.cleanOverrides(src["light"]) }
        return out
    }
}

public struct PalettePreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String
    public let source: String?
    public let dark: [String: String]
    public let light: [String: String]
}

public struct ContrastWarning: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let ratio: Double

    public init(name: String, ratio: Double) {
        self.id = name
        self.name = name
        self.ratio = ratio
    }
}

/// Swift port of `web/lib/palettes.ts` and `web/lib/palette-defaults.ts`.
public enum PaletteTokens {
    private struct RGB {
        let r: Int, g: Int, b: Int
    }

    private struct Seed {
        let bg: String, surface: String, text: String, accent: String
        let series: [String] // [blue, orange, green, yellow, pink, cyan, purple, red]
    }

    /// Ordered entries from `DUSK.dark` (`web/lib/palette-defaults.ts`).
    public static let duskDarkEntries: [(String, String)] = [
        ("shadow-float", "0 16px 40px rgba(0, 0, 0, 0.5)"),
        ("brand-deep", "#2B2366"),
        ("brand-violet", "#7864D9"),
        ("brand-star", "#F2A97E"),
        ("bg", "#0C0B12"),
        ("bg-sidebar", "#100F18"),
        ("bg-panel", "#0E0D15"),
        ("surface", "#15141F"),
        ("surface-raised", "#1B1A27"),
        ("surface-sunken", "#110F19"),
        ("hover", "#1A1925"),
        ("selected", "#201E2C"),
        ("border", "#24222F"),
        ("border-subtle", "#1E1C29"),
        ("border-row", "#181722"),
        ("border-strong", "#2E2B3B"),
        ("track", "#262432"),
        ("text", "#EEEDF3"),
        ("text-2", "#CBC9D6"),
        ("text-secondary", "#A4A1B3"),
        ("text-tertiary", "#8C899C"),
        ("text-on-accent", "#120F24"),
        ("accent", "#9B8CFF"),
        ("accent-soft", "#9B8CFF26"),
        ("state-backlog", "#6B6B73"),
        ("state-todo", "#A1A1AA"),
        ("state-progress", "#F0BF4C"),
        ("state-review", "#4EA7FC"),
        ("state-done", "#4CB782"),
        ("state-human", "#F59E5B"),
        ("state-blocked", "#EF6461"),
        ("priority-urgent", "#F2994A"),
        ("pill-human-bg", "#F59E5B1F"),
        ("pill-human-fg", "#F7B07A"),
        ("pill-blocked-bg", "#EF64611F"),
        ("pill-blocked-fg", "#F48A87"),
        ("pill-review-bg", "#4EA7FC1F"),
        ("pill-review-fg", "#7CBEFD"),
        ("pill-done-bg", "#4CB7821F"),
        ("pill-done-fg", "#6FCF97"),
        ("pill-neutral-bg", "#24222F"),
        ("pill-neutral-fg", "#A4A1B3"),
        ("agent-atlas", "#A3A6FF"),
        ("agent-atlas-bg", "#8B8FFF26"),
        ("agent-quill", "#3FC1B0"),
        ("agent-quill-bg", "#3FC1B024"),
        ("agent-sentry", "#F48A98"),
        ("agent-sentry-bg", "#F27A8A24"),
        ("agent-juno", "#5EA8FF"),
        ("agent-juno-bg", "#5EA8FF24"),
        ("agent-nova", "#F0BF4C"),
        ("agent-nova-bg", "#F0BF4C24"),
        ("agent-relay", "#6FCF7F"),
        ("agent-relay-bg", "#6FCF7F24"),
        ("agent-pike", "#E8925A"),
        ("agent-pike-bg", "#E8925A24"),
        ("agent-echo", "#B98BF5"),
        ("agent-echo-bg", "#B98BF524"),
        ("human-avatar-bg", "#2A2836"),
        ("persona-ink", "100%"),
        ("persona-tint", "15%"),
        ("doc-prd", "#A3A6FF"),
        ("doc-prd-bg", "#8B8FFF1F"),
        ("doc-spec", "#7CBEFD"),
        ("doc-spec-bg", "#4EA7FC1F"),
        ("doc-adr", "#F0BF4C"),
        ("doc-adr-bg", "#F0BF4C1F"),
        ("doc-report", "#6FCF7F"),
        ("doc-report-bg", "#6FCF7F1F"),
        ("doc-design", "#F48A98"),
        ("doc-design-bg", "#F27A8A1F"),
        ("doc-mockup", "#5FD0C8"),
        ("doc-mockup-bg", "#3FC8BE1F"),
        ("doc-note", "#B9B9C3"),
        ("doc-note-bg", "#B9B9C31A"),
        ("row-hover", "#15141E"),
        ("border-hover", "#332F42"),
        ("border-float", "#2E2B3B"),
        ("kbd-border", "#2E2B3B"),
        ("btn-secondary-bg", "#201E2C"),
        ("btn-secondary-border", "#3A3650"),
        ("btn-outline-bg", "#15141F"),
        ("approve-fg", "#1A1206"),
        ("segment-on", "#24222F"),
        ("command-on", "#24222F"),
        ("search-bg", "#15141F"),
        ("priority-unlit", "#363345"),
        ("unassigned", "#48455A"),
        ("scrim", "rgba(6, 5, 12, 0.62)"),
        ("viz-surface", "#15141F"),
        ("viz-panel", "#1F1D2C"),
        ("viz-ink", "#EEEDF3"),
        ("viz-muted", "#A4A1B3"),
        ("viz-line", "#4A4658"),
        ("viz-grid", "#26242F"),
        ("viz-1", "#3987E5"),
        ("viz-2", "#D95926"),
        ("viz-3", "#199E70"),
        ("viz-4", "#C98500"),
        ("viz-5", "#D55181"),
        ("viz-6", "#008300"),
        ("viz-7", "#9085E9"),
        ("viz-8", "#E66767"),
    ]

    public static let duskDark: [String: String] = Dictionary(uniqueKeysWithValues: duskDarkEntries)

    public static let duskLight: [String: String] = [
        "brand-deep": "#2B2366",
        "brand-violet": "#7864D9",
        "brand-star": "#F2A97E",
        "bg": "#FCFBFE",
        "bg-sidebar": "#F4F2F9",
        "bg-panel": "#F9F8FC",
        "surface": "#FFFFFF",
        "surface-raised": "#FFFFFF",
        "surface-sunken": "#F6F5FA",
        "hover": "#F0EEF6",
        "selected": "#ECE8F7",
        "border": "#E5E2EE",
        "border-subtle": "#ECE9F3",
        "border-row": "#F1EFF6",
        "border-strong": "#DEDAEA",
        "track": "#ECE9F3",
        "text": "#17151F",
        "text-2": "#3A3747",
        "text-secondary": "#55526A",
        "text-tertiary": "#66637A",
        "text-on-accent": "#FFFFFF",
        "accent": "#5B4BD6",
        "accent-soft": "#5B4BD61F",
        "state-backlog": "#A8A8B0",
        "state-todo": "#8A8A93",
        "state-progress": "#D49A0A",
        "state-review": "#2F7FE0",
        "state-done": "#2E9E68",
        "state-human": "#E5832F",
        "state-blocked": "#D9424B",
        "priority-urgent": "#EB7A1E",
        "pill-human-bg": "#F59E5B26",
        "pill-human-fg": "#9A4A0E",
        "pill-blocked-bg": "#D9424B1A",
        "pill-blocked-fg": "#A82A33",
        "pill-review-bg": "#2F7FE01A",
        "pill-review-fg": "#1D5FB0",
        "pill-done-bg": "#2E9E681A",
        "pill-done-fg": "#1E7048",
        "pill-neutral-bg": "#F0EEF6",
        "pill-neutral-fg": "#55526A",
        "agent-atlas": "#4547C9",
        "agent-atlas-bg": "#5558E31F",
        "agent-quill": "#0B7A6E",
        "agent-quill-bg": "#0F8A7C1A",
        "agent-sentry": "#B42F48",
        "agent-sentry-bg": "#C2364F17",
        "agent-juno": "#1D5FB0",
        "agent-juno-bg": "#2F7FE01A",
        "agent-nova": "#8A6100",
        "agent-nova-bg": "#D49A0A1F",
        "agent-relay": "#277538",
        "agent-relay-bg": "#2E85401A",
        "agent-pike": "#A44A18",
        "agent-pike-bg": "#B5541F17",
        "agent-echo": "#6C3BB8",
        "agent-echo-bg": "#7A45C917",
        "human-avatar-bg": "#E5E1EE",
        "persona-ink": "50%",
        "persona-tint": "20%",
        "doc-prd": "#4547C9",
        "doc-prd-bg": "#5558E31A",
        "doc-spec": "#1D5FB0",
        "doc-spec-bg": "#2F7FE01A",
        "doc-adr": "#8A6100",
        "doc-adr-bg": "#D49A0A1F",
        "doc-report": "#1E7048",
        "doc-report-bg": "#2E9E681A",
        "doc-design": "#B42F48",
        "doc-design-bg": "#C2364F17",
        "doc-mockup": "#0E7C75",
        "doc-mockup-bg": "#14A8A01A",
        "doc-note": "#55555F",
        "doc-note-bg": "#6B6B751A",
        "row-hover": "#F7F5FB",
        "border-hover": "#D3CEE2",
        "border-float": "#DEDAEA",
        "kbd-border": "#DEDAEA",
        "btn-secondary-bg": "#FFFFFF",
        "btn-secondary-border": "#D3CEE2",
        "btn-outline-bg": "#FFFFFF",
        "approve-fg": "#1A1206",
        "segment-on": "#ECE8F7",
        "command-on": "#ECE8F7",
        "search-bg": "#FFFFFF",
        "priority-unlit": "#D4D4DA",
        "unassigned": "#B8B8C0",
        "scrim": "rgba(23, 23, 26, 0.32)",
        "shadow-float": "0 12px 32px rgba(23, 23, 26, 0.12), 0 0 0 1px rgba(23, 23, 26, 0.04)",
        "viz-surface": "#FFFFFF",
        "viz-panel": "#F3F1F8",
        "viz-ink": "#17151F",
        "viz-muted": "#55526A",
        "viz-line": "#B9B6C6",
        "viz-grid": "#ECE9F3",
        "viz-1": "#2A78D6",
        "viz-2": "#EB6834",
        "viz-3": "#1BAF7A",
        "viz-4": "#EDA100",
        "viz-5": "#E87BA4",
        "viz-6": "#008300",
        "viz-7": "#6250D6",
        "viz-8": "#E34948",
    ]

    /// Ordered color token keys editable/exportable as `#RRGGBB(AA)` colors (`COLOR_KEYS`).
    public static let colorKeys: [String] = duskDarkEntries
        .filter { isHex($0.1) }
        .map(\.0)

    public static let editorGroups: [(label: String, keys: [String])] = [
        ("Backgrounds and surfaces", ["bg", "bg-sidebar", "bg-panel", "surface", "surface-raised", "surface-sunken", "border", "border-strong"]),
        ("Text and buttons", ["text", "text-2", "text-secondary", "text-tertiary", "accent", "text-on-accent", "btn-secondary-bg", "btn-secondary-border", "btn-outline-bg"]),
        ("Status colors", ["state-backlog", "state-todo", "state-progress", "state-review", "state-done", "state-human", "state-blocked"]),
        ("Charts and SVGs", ["viz-surface", "viz-panel", "viz-ink", "viz-muted", "viz-line", "viz-grid"] + (1...8).map { "viz-\($0)" }),
    ]

    public static let advancedColorKeys: [String] = {
        let basic = Set(editorGroups.flatMap(\.keys))
        return colorKeys.filter { !basic.contains($0) }
    }()

    public static func tokenTitle(_ key: String) -> String {
        var s = key
        if s.hasPrefix("viz-") { s = "Diagram " + s.dropFirst(4) }
        else if s == "bg" { return "Background" }
        s = s.replacingOccurrences(of: "-", with: " ")
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    public static func isHex(_ value: String) -> Bool {
        guard value.hasPrefix("#"), value.count == 7 || value.count == 9 else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    public static func isOpaqueHex(_ value: String) -> Bool {
        guard value.hasPrefix("#"), value.count == 7 else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    public static func colorTokens(_ tokens: [String: String]) -> [String: String] {
        tokens.filter { isHex($0.value) }
    }

    static func cleanOverrides(_ input: Any?) -> [String: String] {
        guard let dict = input as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for key in colorKeys {
            if let value = dict[key] as? String, isOpaqueHex(value) {
                out[key] = value.lowercased()
            }
        }
        return out
    }

    private static func parseRGB(_ hex: String) -> RGB {
        let chars = Array(hex.dropFirst())
        let r = Int(String(chars[0..<2]), radix: 16) ?? 0
        let g = Int(String(chars[2..<4]), radix: 16) ?? 0
        let b = Int(String(chars[4..<6]), radix: 16) ?? 0
        return RGB(r: r, g: g, b: b)
    }

    public static func mix(_ a: String, _ b: String, weight: Double) -> String {
        let ca = parseRGB(a)
        let cb = parseRGB(b)
        func ch(_ x: Int, _ y: Int) -> String {
            let v = max(0, min(255, Int(floor(Double(x) * (1 - weight) + Double(y) * weight + 0.5))))
            return String(format: "%02x", v)
        }
        return "#" + ch(ca.r, cb.r) + ch(ca.g, cb.g) + ch(ca.b, cb.b)
    }

    public static func luminance(_ hex: String) -> Double {
        let rgb = parseRGB(hex)
        func comp(_ c: Int) -> Double {
            let n = Double(c) / 255.0
            return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
        }
        return comp(rgb.r) * 0.2126 + comp(rgb.g) * 0.7152 + comp(rgb.b) * 0.0722
    }

    public static func contrast(_ a: String, _ b: String) -> Double {
        let x = luminance(a)
        let y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    public static func readable(_ color: String, against backgrounds: [String], minimum: Double = 4.5) -> String {
        let target = contrast("#ffffff", backgrounds[0]) > contrast("#000000", backgrounds[0]) ? "#ffffff" : "#000000"
        for i in 0...100 {
            let candidate = mix(color, target, weight: Double(i) / 100.0)
            if backgrounds.allSatisfy({ contrast(candidate, $0) >= minimum }) {
                return candidate
            }
        }
        return target
    }

    private static func deriveTokens(_ seed: Seed, mode: ColorMode) -> [String: String] {
        let dark = mode == .dark
        var t = dark ? duskDark : duskLight
        let raised = mix(seed.surface, seed.text, weight: dark ? 0.035 : 0)
        let grounds = [seed.bg, seed.surface, raised]
        let s = seed.series

        t["bg"] = seed.bg
        t["bg-sidebar"] = mix(seed.bg, seed.surface, weight: 0.6)
        t["bg-panel"] = mix(seed.bg, seed.surface, weight: 0.35)
        t["surface"] = seed.surface
        t["surface-raised"] = raised
        t["surface-sunken"] = mix(seed.bg, seed.surface, weight: 0.4)
        t["hover"] = mix(seed.surface, seed.text, weight: 0.065)
        t["selected"] = mix(seed.surface, seed.accent, weight: 0.14)
        t["border"] = mix(seed.surface, seed.text, weight: 0.13)
        t["border-subtle"] = mix(seed.surface, seed.text, weight: 0.09)
        t["border-row"] = mix(seed.surface, seed.text, weight: 0.055)
        t["border-strong"] = mix(seed.surface, seed.text, weight: 0.22)
        t["track"] = mix(seed.surface, seed.text, weight: 0.14)
        t["text"] = readable(seed.text, against: grounds)
        t["text-2"] = readable(mix(seed.text, seed.bg, weight: 0.12), against: grounds)
        t["text-secondary"] = readable(mix(seed.text, seed.bg, weight: 0.28), against: grounds)
        t["text-tertiary"] = readable(mix(seed.text, seed.bg, weight: 0.42), against: grounds)
        t["accent"] = readable(seed.accent, against: grounds, minimum: 3)
        t["accent-soft"] = seed.accent + "26"
        t["brand-deep"] = mix(seed.bg, s[6], weight: 0.35)
        t["brand-violet"] = s[6]
        t["brand-star"] = s[1]
        t["human-avatar-bg"] = mix(seed.surface, seed.text, weight: 0.12)
        t["text-on-accent"] = readable(seed.bg, against: [t["accent"]!])

        let states: [(String, String)] = [
            ("backlog", t["text-tertiary"]!),
            ("todo", t["text-secondary"]!),
            ("progress", s[3]),
            ("review", s[0]),
            ("done", s[2]),
            ("human", s[1]),
            ("blocked", s[7]),
        ]
        for (state, color) in states {
            t["state-\(state)"] = readable(color, against: grounds)
        }
        for state in ["human", "blocked", "review", "done", "neutral"] {
            let color = state == "neutral" ? t["text-secondary"]! : t["state-\(state)"]!
            let pillBg = mix(seed.surface, color, weight: 0.12)
            t["pill-\(state)-bg"] = pillBg
            t["pill-\(state)-fg"] = readable(color, against: [pillBg])
        }
        let agentIndices = [6, 5, 4, 0, 3, 2, 1, 7]
        for (i, name) in ["atlas", "quill", "sentry", "juno", "nova", "relay", "pike", "echo"].enumerated() {
            let color = s[agentIndices[i]]
            let bg = mix(seed.surface, color, weight: 0.14)
            t["agent-\(name)-bg"] = bg
            t["agent-\(name)"] = readable(color, against: [bg])
        }
        let docIndices = [6, 0, 3, 2, 4, 5, 6]
        for (i, name) in ["prd", "spec", "adr", "report", "design", "mockup", "note"].enumerated() {
            let color = s[docIndices[i]]
            let bg = mix(seed.surface, color, weight: 0.12)
            t["doc-\(name)-bg"] = bg
            t["doc-\(name)"] = readable(color, against: [bg])
        }

        t["priority-urgent"] = t["state-human"]!
        t["row-hover"] = t["hover"]!
        t["border-hover"] = t["border-strong"]!
        t["border-float"] = t["border-strong"]!
        t["kbd-border"] = t["border-strong"]!
        t["btn-secondary-bg"] = seed.surface
        t["btn-secondary-border"] = t["border-strong"]!
        t["btn-outline-bg"] = seed.surface
        t["approve-fg"] = readable(seed.bg, against: [t["state-human"]!])
        t["segment-on"] = t["selected"]!
        t["command-on"] = t["selected"]!
        t["search-bg"] = seed.surface
        t["priority-unlit"] = t["border"]!
        t["unassigned"] = t["text-tertiary"]!
        t["scrim"] = seed.bg + "b3"
        t["shadow-float"] = "0 16px 40px \(seed.bg)\(dark ? "cc" : "26")"
        t["viz-surface"] = seed.surface
        t["viz-panel"] = raised
        t["viz-ink"] = t["text"]!
        t["viz-muted"] = t["text-secondary"]!
        t["viz-line"] = mix(seed.surface, seed.text, weight: 0.4)
        t["viz-grid"] = t["border"]!

        var used = Set<String>()
        for (i, color) in s.enumerated() {
            var resolved = readable(color, against: grounds)
            var step = 1
            while used.contains(resolved) && step <= 10 {
                resolved = readable(mix(color, s[(i + 1) % s.count], weight: Double(step) / 12.0), against: grounds)
                step += 1
            }
            used.insert(resolved)
            t["viz-\(i + 1)"] = resolved
        }
        return t
    }

    private static func preset(
        _ id: String, _ name: String, _ description: String, _ source: String?,
        dark: Seed, light: Seed
    ) -> PalettePreset {
        PalettePreset(
            id: id, name: name, description: description, source: source,
            dark: deriveTokens(dark, mode: .dark),
            light: deriveTokens(light, mode: .light)
        )
    }

    private static func macosPreset() -> PalettePreset {
        var dark = deriveTokens(
            Seed(
                bg: "#1e1e1e", surface: "#262626", text: "#e8e8e8", accent: "#0a84ff",
                series: ["#0a84ff", "#ff9f0a", "#30d158", "#ffd60a", "#ff375f", "#64d2ff", "#bf5af2", "#ff453a"]
            ),
            mode: .dark
        )
        for (k, v) in ["border": "#3a3a3a", "border-subtle": "#303030", "border-row": "#2b2b2b", "border-strong": "#4d4d4d", "bg-sidebar": "#232323", "bg-panel": "#222222"] {
            dark[k] = v
        }
        var light = deriveTokens(
            Seed(
                bg: "#ffffff", surface: "#f5f5f5", text: "#262626", accent: "#007aff",
                series: ["#007aff", "#ff9500", "#34c759", "#ffcc00", "#ff2d55", "#32ade6", "#af52de", "#ff3b30"]
            ),
            mode: .light
        )
        for (k, v) in ["border": "#d9d9d9", "border-subtle": "#e4e4e4", "border-row": "#ececec", "border-strong": "#c4c4c4", "bg-sidebar": "#f7f7f7", "bg-panel": "#fafafa"] {
            light[k] = v
        }
        return PalettePreset(
            id: "macos",
            name: "macOS",
            description: "Matches your Mac · follows its accent in the Mac app",
            source: nil,
            dark: dark,
            light: light
        )
    }

    public static let presets: [PalettePreset] = [
        preset(
            "neutral", "Neutral", "Balanced grays · Vesper default", nil,
            dark: Seed(bg: "#18181b", surface: "#222226", text: "#f4f4f5", accent: "#9b8cff", series: ["#60a5fa", "#fb923c", "#4ade80", "#facc15", "#f472b6", "#22d3ee", "#a78bfa", "#f87171"]),
            light: Seed(bg: "#f5f5f7", surface: "#ffffff", text: "#18181b", accent: "#5b4bd6", series: ["#2563eb", "#ea580c", "#16a34a", "#ca8a04", "#db2777", "#0891b2", "#7c3aed", "#dc2626"])
        ),
        PalettePreset(id: "dusk", name: "Dusk", description: "Vesper’s original violet", source: nil, dark: duskDark, light: duskLight),
        preset(
            "catppuccin", "Catppuccin", "Soft pastel · Mocha / Latte", "https://catppuccin.com/palette/?flavor=latte",
            dark: Seed(bg: "#1e1e2e", surface: "#313244", text: "#cdd6f4", accent: "#cba6f7", series: ["#89b4fa", "#fab387", "#a6e3a1", "#f9e2af", "#f5c2e7", "#94e2d5", "#cba6f7", "#f38ba8"]),
            light: Seed(bg: "#eff1f5", surface: "#ffffff", text: "#4c4f69", accent: "#8839ef", series: ["#1e66f5", "#fe640b", "#40a02b", "#df8e1d", "#ea76cb", "#179299", "#8839ef", "#d20f39"])
        ),
        preset(
            "nord", "Nord", "Cool arctic blues", "https://www.nordtheme.com/",
            dark: Seed(bg: "#2e3440", surface: "#3b4252", text: "#eceff4", accent: "#88c0d0", series: ["#81a1c1", "#d08770", "#a3be8c", "#ebcb8b", "#b48ead", "#8fbcbb", "#b48ead", "#bf616a"]),
            light: Seed(bg: "#eceff4", surface: "#e5e9f0", text: "#2e3440", accent: "#5e81ac", series: ["#5e81ac", "#d08770", "#a3be8c", "#ebcb8b", "#b48ead", "#8fbcbb", "#b48ead", "#bf616a"])
        ),
        preset(
            "dracula", "Dracula", "Purple nights · Alucard-inspired light", "https://draculatheme.com/contribute",
            dark: Seed(bg: "#282a36", surface: "#343746", text: "#f8f8f2", accent: "#bd93f9", series: ["#8be9fd", "#ffb86c", "#50fa7b", "#f1fa8c", "#ff79c6", "#8be9fd", "#bd93f9", "#ff5555"]),
            light: Seed(bg: "#fffbeb", surface: "#ffffff", text: "#1f1f1f", accent: "#644ac9", series: ["#036a96", "#a34d14", "#14710a", "#846e15", "#a3144d", "#036a96", "#644ac9", "#cb3a2a"])
        ),
        preset(
            "gruvbox", "Gruvbox", "Warm retro earth tones", "https://github.com/morhetz/gruvbox",
            dark: Seed(bg: "#282828", surface: "#3c3836", text: "#ebdbb2", accent: "#fabd2f", series: ["#83a598", "#fe8019", "#b8bb26", "#fabd2f", "#d3869b", "#8ec07c", "#d3869b", "#fb4934"]),
            light: Seed(bg: "#fbf1c7", surface: "#f2e5bc", text: "#3c3836", accent: "#af3a03", series: ["#076678", "#af3a03", "#79740e", "#b57614", "#8f3f71", "#427b58", "#8f3f71", "#9d0006"])
        ),
        preset(
            "solarized", "Solarized", "Balanced blue and cream", "https://ethanschoonover.com/solarized/",
            dark: Seed(bg: "#002b36", surface: "#073642", text: "#fdf6e3", accent: "#2aa198", series: ["#268bd2", "#cb4b16", "#859900", "#b58900", "#d33682", "#2aa198", "#6c71c4", "#dc322f"]),
            light: Seed(bg: "#fdf6e3", surface: "#eee8d5", text: "#073642", accent: "#268bd2", series: ["#268bd2", "#cb4b16", "#859900", "#b58900", "#d33682", "#2aa198", "#6c71c4", "#dc322f"])
        ),
        preset(
            "rose-pine", "Rosé Pine", "Muted rose · Main / Dawn", "https://rosepinetheme.com/palette/",
            dark: Seed(bg: "#191724", surface: "#1f1d2e", text: "#e0def4", accent: "#c4a7e7", series: ["#9ccfd8", "#ebbcba", "#31748f", "#f6c177", "#eb6f92", "#9ccfd8", "#c4a7e7", "#eb6f92"]),
            light: Seed(bg: "#faf4ed", surface: "#fffaf3", text: "#575279", accent: "#907aa9", series: ["#56949f", "#d7827e", "#286983", "#ea9d34", "#b4637a", "#56949f", "#907aa9", "#b4637a"])
        ),
        preset(
            "tokyo-night", "Tokyo Night", "City blues · Night / Day", "https://github.com/folke/tokyonight.nvim",
            dark: Seed(bg: "#1a1b26", surface: "#24283b", text: "#c0caf5", accent: "#7aa2f7", series: ["#7aa2f7", "#ff9e64", "#9ece6a", "#e0af68", "#bb9af7", "#7dcfff", "#bb9af7", "#f7768e"]),
            light: Seed(bg: "#e1e2e7", surface: "#e9e9ed", text: "#3760bf", accent: "#2e7de9", series: ["#2e7de9", "#b15c00", "#587539", "#8c6c3e", "#9854f1", "#007197", "#9854f1", "#f52a65"])
        ),
        preset(
            "everforest", "Everforest", "Soft forest greens", "https://github.com/sainnhe/everforest/blob/master/README.md",
            dark: Seed(bg: "#2d353b", surface: "#343f44", text: "#d3c6aa", accent: "#a7c080", series: ["#7fbbb3", "#e69875", "#a7c080", "#dbbc7f", "#d699b6", "#83c092", "#d699b6", "#e67e80"]),
            light: Seed(bg: "#fdf6e3", surface: "#f4f0d9", text: "#5c6a72", accent: "#8da101", series: ["#3a94c5", "#f57d26", "#8da101", "#dfa000", "#df69ba", "#35a77c", "#df69ba", "#f85552"])
        ),
        preset(
            "ayu", "Ayu", "Clean neutrals and amber", "https://github.com/ayu-theme/ayu-colors",
            dark: Seed(bg: "#0b0e14", surface: "#131721", text: "#bfbdb6", accent: "#e6b450", series: ["#59c2ff", "#ff8f40", "#aad94c", "#e6b450", "#d2a6ff", "#95e6cb", "#d2a6ff", "#f07178"]),
            light: Seed(bg: "#fafafa", surface: "#ffffff", text: "#5c6166", accent: "#ff9940", series: ["#399ee6", "#fa8d3e", "#86b300", "#f2ae49", "#a37acc", "#4cbf99", "#a37acc", "#f07171"])
        ),
        preset(
            "flexoki", "Flexoki", "Printing inks on warm paper", "https://github.com/kepano/flexoki",
            dark: Seed(bg: "#100f0f", surface: "#1c1b1a", text: "#cecdc3", accent: "#da702c", series: ["#4385be", "#da702c", "#879a39", "#d0a215", "#ce5d97", "#3aa99f", "#8b7ec8", "#d14d41"]),
            light: Seed(bg: "#fffcf0", surface: "#f2f0e5", text: "#100f0f", accent: "#bc5215", series: ["#205ea6", "#bc5215", "#66800b", "#ad8301", "#a02f6f", "#24837b", "#5e409d", "#af3029"])
        ),
        preset(
            "github", "GitHub", "Crisp neutral · Dark / Light Default", "https://primer.style/primitives",
            dark: Seed(bg: "#0d1117", surface: "#161b22", text: "#e6edf3", accent: "#58a6ff", series: ["#58a6ff", "#f0883e", "#3fb950", "#d29922", "#f778ba", "#39c5cf", "#bc8cff", "#f85149"]),
            light: Seed(bg: "#f6f8fa", surface: "#ffffff", text: "#1f2328", accent: "#0969da", series: ["#0969da", "#bc4c00", "#1a7f37", "#9a6700", "#bf3989", "#1b7c83", "#8250df", "#cf222e"])
        ),
        preset(
            "one", "One", "Balanced slate · One Dark / Light", "https://github.com/atom/one-dark-ui",
            dark: Seed(bg: "#21252b", surface: "#282c34", text: "#abb2bf", accent: "#61afef", series: ["#61afef", "#d19a66", "#98c379", "#e5c07b", "#c678dd", "#56b6c2", "#c678dd", "#e06c75"]),
            light: Seed(bg: "#f0f0f3", surface: "#ffffff", text: "#383a42", accent: "#4078f2", series: ["#4078f2", "#c18401", "#50a14f", "#986801", "#a626a4", "#0184bc", "#a626a4", "#e45649"])
        ),
        preset(
            "kanagawa", "Kanagawa", "Ink and parchment · Wave / Lotus", "https://github.com/rebelot/kanagawa.nvim",
            dark: Seed(bg: "#1f1f28", surface: "#2a2a37", text: "#dcd7ba", accent: "#7e9cd8", series: ["#7e9cd8", "#ffa066", "#76946a", "#dca561", "#d27e99", "#7aa89f", "#957fb8", "#e46876"]),
            light: Seed(bg: "#f2ecbc", surface: "#f7f3d4", text: "#545464", accent: "#4d699b", series: ["#4d699b", "#cc6d00", "#6f894e", "#77713f", "#b35b79", "#597b75", "#624c83", "#c84053"])
        ),
        preset(
            "monokai-pro", "Monokai Pro", "Warm charcoal and vivid accents", "https://monokai.pro/",
            dark: Seed(bg: "#2d2a2e", surface: "#383539", text: "#fcfcfa", accent: "#ffd866", series: ["#78dce8", "#fc9867", "#a9dc76", "#ffd866", "#ff6188", "#78dce8", "#ab9df2", "#ff6188"]),
            light: Seed(bg: "#faf4f2", surface: "#ffffff", text: "#29242a", accent: "#e16032", series: ["#1c8ca8", "#e16032", "#569c31", "#b58900", "#d6336c", "#1c8ca8", "#7a5af5", "#d6336c"])
        ),
        macosPreset(),
        preset(
            "high-contrast", "High Contrast", "Maximum contrast · Dark / Light", nil,
            dark: Seed(bg: "#000000", surface: "#141416", text: "#ffffff", accent: "#6cb6ff", series: ["#6cb6ff", "#ffb757", "#56d364", "#f2cc60", "#ff9bce", "#76e3ea", "#d2a8ff", "#ff7b72"]),
            light: Seed(bg: "#f2f2f5", surface: "#ffffff", text: "#000000", accent: "#0055cc", series: ["#0055cc", "#b34700", "#116329", "#7a5200", "#9e1c64", "#006875", "#5e2ca5", "#b91c1c"])
        ),
    ]

    public static func palette(id: String) -> PalettePreset? {
        presets.first { $0.id == id }
    }

    public static func withSystemAccent(_ tokens: [String: String], accent: String, mode: ColorMode) -> [String: String] {
        guard isOpaqueHex(accent),
              let bg = tokens["bg"], let surface = tokens["surface"], let raised = tokens["surface-raised"]
        else { return tokens }
        let grounds = [bg, surface, raised]
        let a = readable(accent, against: grounds, minimum: 3)
        let selected = mix(surface, accent, weight: mode == .dark ? 0.2 : 0.14)
        var out = tokens
        out["accent"] = a
        out["accent-soft"] = a + "26"
        out["selected"] = selected
        out["segment-on"] = selected
        out["command-on"] = selected
        out["text-on-accent"] = readable(bg, against: [a])
        return out
    }

    public static func resolvedRawTokens(
        for preference: AppearancePreference,
        mode: ColorMode,
        systemAccent: String? = nil
    ) -> [String: String] {
        let baseId = preference.palette == "custom" ? preference.custom.base : preference.palette
        let base = palette(id: baseId) ?? presets[0]
        var t = mode == .dark ? base.dark : base.light

        if preference.palette == "macos", let systemAccent, isOpaqueHex(systemAccent) {
            return withSystemAccent(t, accent: systemAccent, mode: mode)
        }
        guard preference.palette == "custom" else { return t }

        let overrides = mode == .dark ? preference.custom.dark : preference.custom.light
        for (k, v) in overrides { t[k] = v }

        let surface = t["surface"] ?? ""
        let text = t["text"] ?? ""
        let accent = t["accent"] ?? ""
        let bg = t["bg"] ?? ""
        let raised = t["surface-raised"] ?? ""
        let secondary = t["text-secondary"] ?? ""
        let stateHuman = t["state-human"] ?? ""
        let border = t["border"] ?? ""

        let selected = overrides["selected"] ?? mix(surface, accent, weight: 0.14)
        var derived: [String: String] = [
            "accent-soft": accent + "26",
            "row-hover": mix(surface, text, weight: 0.065),
            "hover": mix(surface, text, weight: 0.065),
            "selected": mix(surface, accent, weight: 0.14),
            "segment-on": selected,
            "command-on": selected,
            "text-on-accent": readable(bg, against: [accent]),
            "approve-fg": readable(bg, against: [stateHuman]),
            "viz-surface": surface,
            "viz-panel": raised,
            "viz-ink": text,
            "viz-muted": secondary,
            "viz-grid": border,
            "btn-secondary-bg": surface,
            "btn-outline-bg": surface,
            "search-bg": surface,
        ]
        var dependencies: [String: [String]] = [
            "accent-soft": ["accent"],
            "row-hover": ["surface", "text"],
            "hover": ["surface", "text"],
            "selected": ["surface", "accent"],
            "segment-on": ["surface", "accent", "selected"],
            "command-on": ["surface", "accent", "selected"],
            "text-on-accent": ["bg", "accent"],
            "approve-fg": ["bg", "state-human"],
            "viz-surface": ["surface"],
            "viz-panel": ["surface-raised"],
            "viz-ink": ["text"],
            "viz-muted": ["text-secondary"],
            "viz-grid": ["border"],
            "btn-secondary-bg": ["surface"],
            "btn-outline-bg": ["surface"],
            "search-bg": ["surface"],
        ]
        for state in ["human", "blocked", "review", "done", "neutral"] {
            let color = state == "neutral" ? secondary : (t["state-\(state)"] ?? "")
            let bgKey = "pill-\(state)-bg"
            let fgKey = "pill-\(state)-fg"
            let pillBg = mix(surface, color, weight: 0.12)
            derived[bgKey] = pillBg
            derived[fgKey] = readable(color, against: [overrides[bgKey] ?? pillBg])
            let deps = ["surface", state == "neutral" ? "text-secondary" : "state-\(state)"]
            dependencies[bgKey] = deps
            dependencies[fgKey] = deps + [bgKey]
        }

        for (key, value) in derived {
            if dependencies[key]?.contains(where: { overrides[$0] != nil }) == true {
                t[key] = value
            }
        }
        for (k, v) in overrides { t[k] = v }
        return t
    }

    public static func themeTokens(
        for preference: AppearancePreference,
        systemColorMode: ColorMode,
        systemAccent: String? = nil
    ) -> ThemeTokens {
        let mode = preference.effectiveColorMode(system: systemColorMode)
        let raw = resolvedRawTokens(for: preference, mode: mode, systemAccent: systemAccent)
        return ThemeTokens(
            mode: mode,
            colors: colorTokens(raw),
            textSize: preference.textSize.rawValue,
            contentTextScale: preference.contentTextScale
        )
    }

    public static func contrastWarnings(for tokens: [String: String]) -> [ContrastWarning] {
        var pairs: [(String, String, String)] = []
        for bg in ["bg", "surface", "surface-raised", "btn-secondary-bg", "btn-outline-bg"] {
            for fg in ["text", "text-2", "text-secondary", "text-tertiary"] {
                pairs.append(("\(tokenTitle(fg)) on \(tokenTitle(bg))", fg, bg))
            }
        }
        pairs.append(("Button text on accent", "text-on-accent", "accent"))
        pairs.append(("Approval button text", "approve-fg", "state-human"))
        pairs.append(("Diagram text", "viz-ink", "viz-panel"))
        pairs.append(("Diagram secondary text", "viz-muted", "viz-surface"))

        var warnings: [ContrastWarning] = []
        for (name, fgKey, bgKey) in pairs {
            guard let fg = tokens[fgKey], let bg = tokens[bgKey], isOpaqueHex(fg), isOpaqueHex(bg) else { continue }
            let ratio = contrast(fg, bg)
            if ratio < 4.5 {
                warnings.append(ContrastWarning(name: name, ratio: ratio))
            }
        }
        return warnings
    }
}
