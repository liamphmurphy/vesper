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
        populate(menu, items, onAction: onAction)
        return menu
    }

    /// Replaces `menu`'s items in place, so a menu that something else holds (a status item) keeps
    /// its identity.
    static func populate(_ menu: NSMenu, _ items: [TrayMenuItem], onAction: @escaping (TrayAction) -> Void) {
        menu.removeAllItems()
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

    /// Builds an NSMenu from a native `MenuItem` tree.
    static func menu(from items: [MenuItem], onSelect: @escaping (String) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separator == true { menu.addItem(.separator()); continue }
            let mi = ClosureMenuItem(title: item.label ?? "", handler: onSelect, id: item.id)
            mi.isEnabled = item.disabled != true
            if item.checked == true { mi.state = .on }
            if let icon = item.icon { mi.image = SidebarIcons.image(icon) }
            if item.destructive == true {
                mi.attributedTitle = NSAttributedString(string: item.label ?? "", attributes: [.foregroundColor: NSColor.systemRed])
            }
            if let children = item.children, !children.isEmpty {
                mi.submenu = Self.menu(from: children, onSelect: onSelect)
                mi.target = nil
                mi.action = nil
            }
            menu.addItem(mi)
        }
        return menu
    }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: (String) -> Void
    private let itemId: String

    init(title: String, handler: @escaping (String) -> Void, id: String) {
        self.handler = handler
        self.itemId = id
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler(itemId) }
}
