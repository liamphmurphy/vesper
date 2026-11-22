import AppKit
import SwiftUI
import VesperCore

/// The Settings window (⌘,): a sidebar of sections and a grouped form for the selected one.
@MainActor
final class SettingsWindowController {
    private weak var aux: AuxWindows?
    private var window: NSWindow?
    private let navigation = SettingsNavigation()

    init(aux: AuxWindows) { self.aux = aux }

    func show(destination: SettingsDestination? = nil) {
        if case .pane(let pane, _, _, _, _, _, _, _, _) = destination {
            show(section: pane.rawValue)
            return
        }
        show(section: nil)
    }

    func show(section: String? = nil) {
        guard let aux else { return }
        if let section, let s = SettingsSection(rawValue: section) { navigation.selection = s }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(aux: aux, navigation: navigation))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 620))
            window.minSize = NSSize(width: 700, height: 480)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.center()
            window.title = navigation.selection.title
            track({ [navigation] in navigation.selection.title }, apply: { [weak window] in window?.title = $0 })
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
