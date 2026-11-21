import Foundation

/// A colour as the page wrote it, "#RRGGBB" or "#RRGGBBAA", in 0…1 components.
public struct RGBA: Sendable, Equatable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9,
              let value = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        let hasAlpha = hex.count == 9
        let rgb = hasAlpha ? value >> 8 : value
        red = Double((rgb >> 16) & 0xff) / 255
        green = Double((rgb >> 8) & 0xff) / 255
        blue = Double(rgb & 0xff) / 255
        alpha = hasAlpha ? Double(value & 0xff) / 255 : 1
    }
}

/// The page's resolved palette and text size (its `appearance` message), so native screens draw
/// with exactly the colours and type the web screens do and follow Settings live.
public struct ThemeTokens: Sendable, Equatable {
    public var mode: ColorMode
    /// CSS variable names without "--" ("text", "accent", "state-done"…) to "#RRGGBB(AA)".
    public var colors: [String: String]
    /// Settings → Text size: "small", "default", "large" or "larger".
    public var textSize: String?

    public init(mode: ColorMode, colors: [String: String] = [:], textSize: String? = nil) {
        self.mode = mode
        self.colors = colors
        self.textSize = textSize
    }

    /// globals.css `:root[data-text-size=…] { --type-scale }`.
    static let typeScales: [String: Double] = ["small": 0.92, "default": 1, "large": 1.12, "larger": 1.25]

    public var typeScale: Double { Self.typeScales[textSize ?? "default"] ?? 1 }

    /// A named colour, nil when the page hasn't sent it (or sent something that isn't a hex colour).
    public func color(_ name: String) -> RGBA? {
        colors[name].flatMap(RGBA.init(hex:))
    }

    /// globals.css's type tokens (`--text-display` … `--text-mono`).
    public enum TextStyle: String, Sendable, CaseIterable {
        case display, title, heading, body, reading, chat, small, micro, mono

        /// Size in px at type scale 1, CSS weight, and line-height multiple.
        public var metrics: (size: Double, weight: Int, lineHeight: Double) {
            switch self {
            case .display: (26, 600, 1.2)
            case .title: (19, 600, 1.3)
            case .heading: (14, 600, 1.45)
            case .body: (13, 400, 1.45)
            case .reading: (14, 400, 1.65)
            case .chat: (15, 400, 1.6)
            case .small: (12, 400, 1.45)
            case .micro: (10, 600, 1.2)
            case .mono: (12, 400, 1.45)
            }
        }

        public var isMonospaced: Bool { self == .mono }
    }

    /// The point size of a style at the current text size (a CSS px is a point on macOS).
    public func pointSize(_ style: TextStyle) -> Double { style.metrics.size * typeScale }

    /// Extra space between lines, in points, for a style's CSS line-height.
    public func lineSpacing(_ style: TextStyle) -> Double {
        let size = pointSize(style)
        return max(0, size * style.metrics.lineHeight - size * 1.2)
    }
}
