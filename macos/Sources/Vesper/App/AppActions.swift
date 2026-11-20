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
    func showShortcuts()
    func checkForUpdates()
    func restartStack()
    func showLogs()
}

@MainActor
final class DefaultAppActions: AppActions {
    private weak var app: AppModel?

    init(app: AppModel) { self.app = app }

    func quickCapture() { app?.aux.quickCapture() }
    func screenshotToChat() { app?.aux.screenshotToChat() }
    func importBackup() { app?.aux.importBackup() }
    func openSettings() { app?.aux.openSettings() }
    func showShortcuts() { app?.aux.showShortcuts() }
    func checkForUpdates() { app?.aux.checkForUpdates() }

    func restartStack() {
        guard let stack = app?.stack else { return }
        Task { await stack.restart() }
    }

    func showLogs() { app?.system.showLogs() }
}
