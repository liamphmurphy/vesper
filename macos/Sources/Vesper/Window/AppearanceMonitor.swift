import AppKit
import VesperCore

/// Watches macOS's accent colour and light/dark setting and calls `onChange` when either may have changed.
@MainActor
final class AppearanceMonitor: NSObject {
    private var observation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private let onChange: () -> Void
    private var last = ""

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        observation = NSApp?.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            Task { @MainActor in self?.fire() }
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        })
        for name in ["AppleColorPreferencesChangedNotification", "AppleInterfaceThemeChangedNotification"] {
            distributed.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.fire() }
            })
        }
        last = Self.signature()
    }

    /// Called when the owner closes.
    func stop() {
        observation = nil
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        for t in distributed { DistributedNotificationCenter.default().removeObserver(t) }
        tokens = []; distributed = []
    }

    private func fire() {
        let now = Self.signature()
        guard now != last else { return }
        last = now
        onChange()
    }

    private static func signature() -> String {
        let (accent, mode) = current()
        return "\(accent)/\(mode.rawValue)"
    }

    /// The system accent as "#RRGGBB" (resolved for the effective appearance) and the app's effective mode.
    static func current() -> (accent: String, mode: ColorMode) {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let mode: ColorMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        var hex = "#0A84FF"
        appearance.performAsCurrentDrawingAppearance {
            if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                hex = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
        }
        return (hex, mode)
    }
}
