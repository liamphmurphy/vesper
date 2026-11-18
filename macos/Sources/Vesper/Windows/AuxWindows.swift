import AppKit
import VesperCore

/// The app's auxiliary windows and flows: Settings, Quick Capture, Screenshot to Chat, files in
/// (Dock/window drop, Open With, Quick Actions) and the send picker, Import Backup, scheduled
/// backups and Time Machine, the update check and open-at-login. One per app (`AppModel.aux`).
/// See docs/dev/native-mac-app.md.
///
/// The app calls these entry points; their bodies (and any helpers in Sources/Vesper/Windows/,
/// Settings/, Capture/, Files/) belong to this subsystem.
@MainActor
final class AuxWindows {
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    /// Called once after launch (before the stack is ready).
    func start() {}

    func quickCapture() {}
    func screenshotToChat() {}
    func importBackup() {}
    func openSettings() {}
    func checkForUpdates() {}

    /// Files opened with the app (Open With, Dock drop, Quick Actions) or dropped on a window.
    func openFiles(_ urls: [URL]) {}
}
