import AppKit
import VesperCore

/// The app's always-on system integration: menu bar extra, notifications, Dock badge/menu/progress,
/// power and thermal handling, Touch ID, the workspace folder menu, the Logs window, quit and
/// last-window policy. One per app (`AppModel.system`). See docs/dev/native-mac-app.md.
///
/// The app calls these entry points; their bodies (and any helpers in Sources/Vesper/System/,
/// MenuBar/, Notifications/, Dock/, Power/, Logs/) belong to this subsystem.
@MainActor
final class SystemServices {
    private weak var app: AppModel?

    init(app: AppModel) {
        self.app = app
    }

    /// Called once after launch (before the stack is ready).
    func start() {}

    /// The page asked to confirm an approval (`confirmApproval`). true = go ahead.
    /// Fails closed: while Touch ID is on for the scope and can't be confirmed, refuse.
    func confirmApproval(scope: ApprovalScope) async -> Bool {
        guard let settings = app?.settings.settings else { return false }
        let mapped = TouchIdScope(rawValue: scope.rawValue)
        if settings.touchId.enabled, mapped.map(settings.touchId.isOn) ?? true {
            return false // Touch ID not wired yet: refuse rather than skip the check.
        }
        return true
    }

    /// The page asked for the workspace folder menu (`openWorkspaceMenu`) at the mouse location.
    /// true when the person picked something and it opened.
    func showWorkspaceMenu(folder: String, in view: NSView) async -> Bool { false }

    /// Before quitting: false cancels the quit (e.g. runs are active and the person said no).
    func confirmQuit() async -> Bool { true }

    /// `tray.onLastWindowClose`: whether closing the last window quits the app.
    func shouldTerminateAfterLastWindowClosed() -> Bool { false }

    /// View › Show Logs… and the menu bar's Show Logs….
    func showLogs() {
        guard let url = app?.stack?.logFileURL ?? app.map({ $0.dataDirectory.appendingPathComponent("logs/vesper-app.log") }) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
