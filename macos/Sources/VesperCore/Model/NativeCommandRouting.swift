import Foundation

/// Which shell commands belong to the screen a tab shows: its toolbar, title menu and inspector, and
/// the sidebar navigator's commands when the screen publishes that navigator (`navigatorId`). While
/// a native screen shows, these go to it instead of the page; everything else (navigation, the
/// page's own navigator, the rail, appearance) still goes to the page.
public enum NativeCommandRouting {
    public static func isScreenCommand(_ command: NativeCommand, navigatorId: String? = nil) -> Bool {
        switch command {
        case .toolbarAction, .titleAction, .inspectorVisibility, .inspectorSelectTab, .inspectorAction,
             .inspectorChange, .inspectorToggle:
            return true
        case .navActivate(let id, _, _), .navAction(let id, _, _, _), .navPicker(let id, _, _), .navFilter(let id, _, _, _),
             .navSearch(let id, _, _), .navToggle(let id, _, _):
            return navigatorId != nil && id == navigatorId
        default:
            return false
        }
    }
}
