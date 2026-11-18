import AppKit
import VesperCore

/// Everything a menu, the Dock menu or the menu bar can ask the app to do. Later agents provide
/// real bodies (set `AppDelegate.actions` to their implementation or fill in `DefaultAppActions`).
@MainActor
protocol AppActions: AnyObject {
    func quickCapture()
    func screenshotToChat()
    func importBackup()
    func openSettings()
    func checkForUpdates()
    func restartStack()
    func showLogs()
}

@MainActor
final class DefaultAppActions: AppActions {
    private weak var app: AppModel?

    init(app: AppModel) { self.app = app }

    func quickCapture() { /* INTEGRATE: Quick Capture panel (capture.ts) */ }
    func screenshotToChat() { /* INTEGRATE: screencapture + send picker (screenshot.ts) */ }
    func importBackup() { /* INTEGRATE: file picker + `vesper app-import` */ }
    func openSettings() { /* INTEGRATE: Settings window */ }
    func checkForUpdates() { /* INTEGRATE: update check */ }

    func restartStack() {
        guard let stack = app?.stack else { return }
        Task { await stack.restart() }
    }

    func showLogs() {
        // INTEGRATE: replace with the Logs window (last 256 KB, Copy, Reveal in Finder, Restart Stack).
        guard let url = app?.stack?.logFileURL ?? app.map({ $0.dataDirectory.appendingPathComponent("logs/vesper-app.log") }) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
