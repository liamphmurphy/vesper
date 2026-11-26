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
            // Terminal.app's item: reaches the focused Dev terminal through the responder chain.
            item("Secure Keyboard Entry", DevSecureKeyboardEntry.toggleAction, target: nil),
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
            item("Close Tab", #selector(AppDelegate.closeTab(_:)), "w"),
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
            item("Find Next", #selector(AppDelegate.findNext(_:)), "g"),
            item("Find Previous", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift]),
            item("Use Selection for Find", #selector(AppDelegate.useSelectionForFind(_:)), "e"),
            sep(),
            item("Command Palette…", #selector(AppDelegate.openCommandPalette(_:)), "k"),
            item("Quick Switcher…", #selector(AppDelegate.openQuickSwitcher(_:)), "o"),
            item("Search Current View…", #selector(AppDelegate.openScopedCommandPalette(_:)), "k", [.command, .shift]),
            item("Search…", #selector(AppDelegate.focusSearch(_:)), "f", [.command, .option]),
        ])

        // View
        _ = add("View", [
            item("Show Sidebar", #selector(AppDelegate.toggleSidebarAction(_:)), "s", [.command, .control]),
            item("Show Inspector", #selector(AppDelegate.toggleInspectorAction(_:)), "\\", [.command]),
            sep(),
            item("Reload", #selector(AppDelegate.reload(_:)), "r"),
            item("Force Reload", #selector(AppDelegate.forceReload(_:)), "r", [.command, .shift]),
            item("Developer Tools", #selector(AppDelegate.showInspector(_:)), "i", [.command, .option]),
            sep(),
            item("Actual Size", #selector(AppDelegate.zoomReset(_:)), "0"),
            item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"),
            sep(),
            item("Use Compact Tab Layout", #selector(AppDelegate.toggleCompactLayout(_:))),
            sep(),
            item("Show/Hide Tab Bar", #selector(AppDelegate.toggleTabBarAction(_:))),
            item("Show All Tabs", #selector(AppDelegate.showAllTabsAction(_:))),
            sep(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil),
        ])

        // History
        _ = add("History", [
            item("Back", #selector(AppDelegate.goBack(_:)), "["),
            item("Forward", #selector(AppDelegate.goForward(_:)), "]"),
        ])

        // Browser
        var browserItems: [NSMenuItem] = [
            item("Focus Address Bar", #selector(AppDelegate.focusBrowserAddressBar(_:)), "l"),
            item("New Private Web Tab", #selector(AppDelegate.newPrivateBrowserTab(_:)), "p", [.command, .shift]),
            item("New Tab Group", #selector(AppDelegate.newBrowserTabGroup(_:)), "g", [.command, .control]),
            sep(),
            item("Toggle Split View", #selector(AppDelegate.toggleBrowserSplitView(_:)), "\\", [.command, .control]),
            item("Swap Split Panes", #selector(AppDelegate.swapBrowserSplitPanes(_:))),
            item("Toggle Focus Mode", #selector(AppDelegate.toggleBrowserFocusMode(_:)), "f", [.command, .shift]),
            item("Mute / Unmute Tab", #selector(AppDelegate.toggleBrowserTabMute(_:)), "m", [.command, .option]),
            item("Toggle Reader Mode", #selector(AppDelegate.toggleBrowserReaderMode(_:)), "r", [.command, .option]),
            item("Bookmark Page", #selector(AppDelegate.toggleBrowserBookmark(_:)), "b", [.command, .shift]),
            item("Capture Region Screenshot…", #selector(AppDelegate.captureBrowserRegionScreenshot(_:))),
            item("Open Page in Safari", #selector(AppDelegate.openBrowserPageInSafari(_:)), "o", [.command, .option]),
            sep(),
            item("AutoFill from Keychain…", #selector(AppDelegate.openBrowserAutofill(_:)), "a", [.command, .shift]),
            item("Manage WebExtensions…", #selector(AppDelegate.openBrowserExtensions(_:)), "e", [.command, .control]),
            sep(),
            item("Next Web Tab", #selector(AppDelegate.nextBrowserTab(_:)), "]", [.command, .control]),
            item("Previous Web Tab", #selector(AppDelegate.previousBrowserTab(_:)), "[", [.command, .control]),
            sep(),
        ]
        for n in 1...9 {
            browserItems.append(
                item(
                    n == 9 ? "Last Web Tab" : "Web Tab \(n)",
                    #selector(AppDelegate.selectBrowserTab(_:)),
                    "\(n)",
                    [.command, .control],
                    tag: n
                )
            )
        }
        _ = add("Browser", browserItems)

        // Window
        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
            sep(),
            item("Show Next Tab", #selector(AppDelegate.nextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift]),
            item("Show Next Tab", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift]),
            item("Show Previous Tab", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift]),
            item("Move Tab to New Window", #selector(AppDelegate.moveTabToNewWindowAction(_:))),
            item("Merge All Windows", #selector(AppDelegate.mergeAllWindowsAction(_:))),
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
            item("Keyboard Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/"),
            sep(),
            item("Show Logs…", #selector(AppDelegate.showLogs(_:))),
            item("Vesper Repository & Docs", #selector(AppDelegate.openDocs(_:))),
        ])
        NSApp.helpMenu = helpMenu
        return main
    }
}
