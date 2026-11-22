import AppKit
import SwiftUI
import VesperCore

/// Maps the web's icon names (web/components/ui/icon.tsx) to SF Symbols.
enum SidebarIcons {
    static let table: [String: String] = [
        "dashboard": "square.grid.2x2", "inbox": "tray", "tickets": "checkmark.circle", "slides": "play.rectangle",
        "designs": "pencil.and.ruler", "board": "rectangle.split.3x1", "epics": "square.stack.3d.up", "agents": "cpu",
        "artifacts": "doc", "wiki": "book", "learn": "graduationcap", "graph": "point.3.connected.trianglepath.dotted",
        "search": "magnifyingglass", "plus": "plus", "chev": "chevron.down", "chevr": "chevron.right", "x": "xmark",
        "expand": "arrow.up.left.and.arrow.down.right", "shrink": "arrow.down.right.and.arrow.up.left", "chevronUp": "chevron.up",
        "check": "checkmark", "gear": "gearshape", "branch": "arrow.triangle.branch", "pr": "arrow.triangle.pull",
        "lock": "lock", "key": "key", "code": "chevron.left.forwardslash.chevron.right", "terminal": "terminal",
        "msg": "bubble.left", "bolt": "bolt", "play": "play.fill", "playLeft": "arrowtriangle.left.fill", "dollar": "dollarsign.circle", "pause": "pause.fill",
        "download": "square.and.arrow.down", "upload": "square.and.arrow.up", "printer": "printer", "at": "at",
        "server": "server.rack", "users": "person.2", "sliders": "slider.horizontal.3", "folder": "folder", "github": "network",
        "shield": "shield", "refresh": "arrow.clockwise", "link": "link", "dots": "ellipsis", "alert": "exclamationmark.triangle",
        "plug": "powerplug", "clock": "clock", "activity": "waveform.path.ecg", "edit": "pencil", "history": "clock.arrow.circlepath",
        "sidebar": "sidebar.left", "briefcase": "briefcase", "bookmark": "bookmark", "trash": "trash", "sun": "sun.max",
        "moon": "moon", "bulb": "lightbulb", "dice": "dice", "gamepad": "gamecontroller", "compass": "safari",
        "dumbbell": "dumbbell", "audio": "waveform", "film": "film", "library": "photo.on.rectangle", "compare": "rectangle.split.2x1",
        // Names pages use that are not in icon.tsx yet.
        "doc": "doc.text", "pin": "pin", "more": "ellipsis", "panel-right": "sidebar.right", "star": "star", "home": "house",
        "compose": "square.and.pencil", "eye": "eye", "copy": "doc.on.doc", "external": "arrow.up.right.square",
        "outline": "list.bullet.indent", "table": "tablecells", "reviews": "checkmark.bubble", "calendar": "calendar",
    ]

    static func symbolName(_ icon: String) -> String { table[icon] ?? "circle" }

    static func image(_ icon: String) -> NSImage {
        NSImage(systemSymbolName: symbolName(icon), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .accent: .accentColor
        case .done: .green
        case .human: .purple
        case .blocked: .orange
        case .warning: .yellow
        case .danger: .red
        }
    }
}

extension Color {
    /// "#RRGGBB" or "#RGB"; nil for anything else (CSS color functions, names).
    init?(cssHex: String?) {
        guard var s = cssHex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
