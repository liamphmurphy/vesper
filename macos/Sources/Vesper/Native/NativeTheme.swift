import AppKit
import SwiftUI
import VesperCore

private struct VesperThemeKey: EnvironmentKey {
    static let defaultValue = ThemeTokens(mode: .light)
}

extension EnvironmentValues {
    /// The page's palette and text size, for native screens. Set by `NativeScreenRoot`.
    var vesperTheme: ThemeTokens {
        get { self[VesperThemeKey.self] }
        set { self[VesperThemeKey.self] = newValue }
    }
}

extension ThemeTokens {
    /// A palette colour by its CSS name ("text", "state-done"…), or `fallback` before the page has
    /// sent its palette.
    func swiftUIColor(_ name: String, fallback: Color) -> Color {
        guard let c = color(name) else { return fallback }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    /// A type token at the current text size.
    func font(_ style: TextStyle) -> Font {
        let weight: Font.Weight = style.metrics.weight >= 600 ? .semibold : .regular
        return .system(size: pointSize(style), weight: weight, design: style.isMonospaced ? .monospaced : .default)
    }

    /// The colours native screens use most, with system fallbacks.
    var palette: NativePalette { NativePalette(theme: self) }
}

struct NativePalette {
    let theme: ThemeTokens

    var background: Color { theme.swiftUIColor("bg", fallback: Color(nsColor: .windowBackgroundColor)) }
    var surface: Color { theme.swiftUIColor("surface", fallback: Color(nsColor: .controlBackgroundColor)) }
    var text: Color { theme.swiftUIColor("text", fallback: .primary) }
    var secondaryText: Color { theme.swiftUIColor("text-secondary", fallback: .secondary) }
    var tertiaryText: Color { theme.swiftUIColor("text-tertiary", fallback: Color(nsColor: .tertiaryLabelColor)) }
    var border: Color { theme.swiftUIColor("border", fallback: Color(nsColor: .separatorColor)) }
    var rowBorder: Color { theme.swiftUIColor("border-row", fallback: Color(nsColor: .separatorColor)) }
    var accent: Color { theme.swiftUIColor("accent", fallback: .accentColor) }
    var hover: Color { theme.swiftUIColor("hover", fallback: Color.primary.opacity(0.06)) }
    var selected: Color { theme.swiftUIColor("selected", fallback: Color.accentColor.opacity(0.14)) }
}

extension View {
    /// Font and line spacing of a type token, as the web's `--text-*` variables set them.
    func vesperText(_ style: ThemeTokens.TextStyle, _ theme: ThemeTokens) -> some View {
        font(theme.font(style)).lineSpacing(theme.lineSpacing(style))
    }
}
