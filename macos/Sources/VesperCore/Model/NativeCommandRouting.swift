import Foundation

/// Which shell commands belong to the screen a tab shows: its toolbar, title menu and inspector, and
/// the sidebar's navigator when the screen publishes its own (`navigatorId`). While a native screen
/// shows, these go to it instead of the page; everything else (navigation, the page's navigator, the
/// rail, appearance) still goes to the page.
public enum NativeCommandRouting {
    public static func isScreenCommand(_ command: NativeCommand, navigatorId: String? = nil) -> Bool {
        switch command {
        case .toolbarAction, .titleAction, .inspectorVisibility, .inspectorSelectTab, .inspectorAction,
             .inspectorChange, .inspectorToggle:
            return true
        case .navActivate(let nav, _, _), .navAction(let nav, _, _, _), .navPicker(let nav, _, _),
             .navFilter(let nav, _, _, _), .navSearch(let nav, _, _), .navToggle(let nav, _, _):
            return navigatorId != nil && nav == navigatorId
        default:
            return false
        }
    }
}
