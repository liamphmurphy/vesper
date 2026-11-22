import Foundation
import VesperCore

/// The shell's toolbar item, for files that import SwiftUI (which has its own `ToolbarItem`).
typealias ShellToolbarItem = ToolbarItem

/// What a native screen shows in the window around it: title, toolbar, inspector and, optionally,
/// the sidebar's list. It replaces the page's while the screen shows (`ShellState.native`); a screen
/// with no `navigator` keeps the page's.
struct NativeChrome: Equatable {
    var title: String?
    var subtitle: String?
    var titleMenu: [MenuItem]?
    var toolbarItems: [ToolbarItem] = []
    var inspector: InspectorModel?
    var navigator: NavModel?
}
