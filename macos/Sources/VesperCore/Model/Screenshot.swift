import Foundation

// Port of desktop/src/screenshot.ts: Screenshot to Chat uses the macOS region picker.

public enum Screenshot {
    public static let screencaptureBin = "/usr/sbin/screencapture"

    /// "Screenshot 2026-11-17 at 14.05.09.png", like macOS names its own.
    public static func fileName(_ now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        func p(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return "Screenshot \(String(format: "%04d", c.year ?? 0))-\(p(c.month))-\(p(c.day)) at \(p(c.hour)).\(p(c.minute)).\(p(c.second)).png"
    }

    /// Interactive region (Space switches to a window) capture, no shutter sound, PNG. Escape writes nothing.
    public static func arguments(file: String) -> [String]? {
        file.hasPrefix("/") ? ["-i", "-x", "-t", "png", file] : nil
    }

    /// System Settings pane for Screen & System Audio Recording.
    public static let privacyPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
