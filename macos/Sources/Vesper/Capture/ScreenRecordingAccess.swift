import AppKit
import CoreGraphics
import VesperCore

/// macOS Screen Recording permission, shared by Screenshot to Chat and the page's getDisplayMedia.
@MainActor
enum ScreenRecordingAccess {
    /// True when capture is allowed. Otherwise asks macOS to prompt (first time only) and shows the
    /// explanation with a button to the Screen Recording pane.
    static func ensure(what: String) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        showDenied(what: what)
        return false
    }

    static func showDenied(what: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Vesper can't \(what)"
        alert.informativeText = "Allow Vesper under System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: Screenshot.privacyPaneURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
