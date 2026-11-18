import Foundation

// Port of desktop/src/login.ts. SMAppService.mainApp registers the app as a login item; a login
// launch can't be told from the arguments, so the app reads the launch Apple event (see AuxWindows).

public enum LoginItemStatus: String, Sendable { case enabled, notRegistered, requiresApproval, notFound, unknown }

public enum Login {
    /// Whether this launch should start without a window. Needs the menu bar icon, or the person
    /// would have no way to reach the app.
    public static func shouldStartHidden(_ login: NativeSettings.Login, trayEnabled: Bool, launchedAtLogin: Bool) -> Bool {
        launchedAtLogin && login.openAtLogin && login.startHidden && trayEnabled
    }

    /// A sentence for Settings explaining the login item's state, or nil when nothing needs saying.
    public static func statusMessage(wanted: Bool, status: LoginItemStatus) -> String? {
        guard wanted else { return nil }
        switch status {
        case .requiresApproval: return "macOS needs your OK: open System Settings › General › Login Items and allow Vesper."
        case .notFound: return "macOS couldn't find Vesper to register it. Move Vesper.app to Applications and try again."
        case .notRegistered: return "Vesper isn't registered as a login item yet. Toggle the setting off and on again."
        case .enabled, .unknown: return nil
        }
    }
}
