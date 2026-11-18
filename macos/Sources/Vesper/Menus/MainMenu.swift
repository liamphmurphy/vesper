import AppKit

/// The application menu bar (desktop/src/menu.ts, minus "Change Server URL…"). Items with a nil
/// target go through the responder chain; the rest call `AppDelegate` (`@objc` actions below).
@MainActor
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                  target: AnyObject? = delegate, tag: Int = 0) -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if !key.isEmpty { mi.keyEquivalentModifierMask = mods }
            mi.target = target
            mi.tag = tag
            return mi
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        let sep = { NSMenuItem.separator() }

        // App
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        _ = add(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            sep(),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))),
            item("Settings…", #selector(AppDelegate.openSettings(_:)), ","),
            sep(),
            item("Restart Stack", #selector(AppDelegate.restartStack(_:))),
            item("Show Logs…", #selector(AppDelegate.showLogs(_:))),
            sep(),
            servicesItem,
            sep(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            sep(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])

        // File
        _ = add("File", [
            item("New Tab", #selector(AppDelegate.newWindowForTab(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindowAction(_:)), "n"),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
            // Display only: the global shortcut is registered in Settings.
            item("Quick Capture…", #selector(AppDelegate.quickCapture(_:))),
            item("Screenshot to Chat…", #selector(AppDelegate.screenshotToChat(_:))),
            sep(),
            item("Import Backup…", #selector(AppDelegate.importBackup(_:))),
            sep(),
            item("Close Tab", #selector(NSWindow.performClose(_:)), "w", target: nil),
            item("Close Window", #selector(AppDelegate.closeAllTabs(_:)), "w", [.command, .shift]),
        ])

        // Edit
        _ = add("Edit", [
            item("Undo", Selector(("undo:")), "z", target: nil),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil),
            sep(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil),
            item("Copy", #selector(NSText.copy(_:)), "c", target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift], target: nil),
            item("Delete", #selector(NSText.delete(_:)), target: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil),
            sep(),
            item("Find…", #selector(AppDelegate.find(_:)), "f"),
            item("Search…", #selector(AppDelegate.focusSearch(_:)), "f", [.command, .option]),
        ])

        // View
        _ = add("View", [
            item("Show Sidebar", #selector(AppDelegate.toggleSidebarAction(_:)), "s", [.command, .control]),
            sep(),
            item("Reload", #selector(AppDelegate.reload(_:)), "r"),
            item("Force Reload", #selector(AppDelegate.forceReload(_:)), "r", [.command, .shift]),
            item("Developer Tools", #selector(AppDelegate.showInspector(_:)), "i", [.command, .option]),
            sep(),
            item("Actual Size", #selector(AppDelegate.zoomReset(_:)), "0"),
            item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"),
            sep(),
            item("Show/Hide Tab Bar", #selector(NSWindow.toggleTabBar(_:)), target: nil),
            item("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:)), target: nil),
            sep(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil),
        ])

        // History
        _ = add("History", [
            item("Back", #selector(AppDelegate.goBack(_:)), "["),
            item("Forward", #selector(AppDelegate.goForward(_:)), "]"),
        ])

        // Window
        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
            sep(),
            item("Show Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift]),
            item("Show Next Tab", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift]),
            item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)), target: nil),
            item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)), target: nil),
            sep(),
        ]
        for n in 1...9 {
            windowItems.append(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(AppDelegate.selectTab(_:)), "\(n)", tag: n))
        }
        windowItems += [sep(), item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)]
        let windowMenu = add("Window", windowItems)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = add("Help", [
            item("Show Logs…", #selector(AppDelegate.showLogs(_:))),
            item("Vesper Repository & Docs", #selector(AppDelegate.openDocs(_:))),
        ])
        NSApp.helpMenu = helpMenu
        return main
    }
}
