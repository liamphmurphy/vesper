import Foundation

/// Which shell commands belong to the screen a tab shows: its toolbar, title menu and inspector.
/// While a native screen shows, these go to it instead of the page; everything else (navigation,
/// the sidebar's navigator, the rail, appearance) still goes to the page.
public enum NativeCommandRouting {
    public static func isScreenCommand(_ command: NativeCommand) -> Bool {
        switch command {
        case .toolbarAction, .titleAction, .inspectorVisibility, .inspectorSelectTab, .inspectorAction,
             .inspectorChange, .inspectorToggle:
            return true
        default:
            return false
        }
    }
}
