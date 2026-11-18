import AppKit
import VesperCore

/// Maps a menu model (the menu bar's or the Dock's `[TrayMenuItem]`) onto an NSMenu
/// (desktop/src/native-tray.ts `menuTemplate`).
@MainActor
enum MenuBuilder {
    /// Keeps a click's closure alive for the item (NSMenuItem.target is not retained).
    private final class Target: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func build(_ items: [TrayMenuItem], onAction: @escaping (TrayAction) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for model in items {
            switch model {
            case .separator:
                menu.addItem(.separator())
            case .header(let label):
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .item(let label, let action, let enabled, let accelerator):
                let target = Target { onAction(action) }
                let item = NSMenuItem(title: label, action: #selector(Target.fire), keyEquivalent: "")
                item.target = target
                item.representedObject = target
                item.isEnabled = enabled
                if let accelerator, let (key, mask) = keyEquivalent(accelerator) {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = mask
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    /// "Alt+Shift+Space" as a key and modifiers, for display beside the item.
    static func keyEquivalent(_ accelerator: String) -> (String, NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        var key: String?
        for part in accelerator.split(separator: "+").map(String.init) {
            switch part.lowercased() {
            case "alt", "option": mask.insert(.option)
            case "shift": mask.insert(.shift)
            case "cmd", "command", "cmdorctrl", "commandorcontrol", "super", "meta": mask.insert(.command)
            case "ctrl", "control": mask.insert(.control)
            case "space": key = " "
            case let k where k.count == 1: key = k
            default: return nil
            }
        }
        guard let key else { return nil }
        return (key, mask)
    }
}
