import AppKit
import SwiftUI

extension NSColor {
    /// A page's "#RRGGBB" colour (the same parsing the sidebar's avatars use), nil for anything else.
    static func fromCSS(_ css: String?) -> NSColor? {
        Color(cssHex: css).map { NSColor($0) }
    }
}
