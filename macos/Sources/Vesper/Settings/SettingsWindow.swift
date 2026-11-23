import AppKit
import SwiftUI
import VesperCore

/// The Settings window (⌘,): grouped navigation sidebar and dedicated SwiftUI forms for every setting.
@MainActor
final class SettingsWindowController {
    private weak var aux: AuxWindows?
    private var window: NSWindow?
    let navigation = SettingsNavigation()

    init(aux: AuxWindows) { self.aux = aux }

    func show(destination: SettingsDestination? = nil) {
        if let destination {
            navigation.apply(destination)
        }
        presentWindow()
    }

    func show(section: String? = nil) {
        if let section, !section.isEmpty {
            if let resolved = SettingsRouteResolver.resolve("/settings?section=\(section)") {
                navigation.apply(resolved)
            } else if let pane = SettingsPane(rawValue: section) {
                navigation.apply(.pane(pane: pane))
            }
        }
        presentWindow()
    }

    private func presentWindow() {
        guard let aux else { return }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(aux: aux, navigation: navigation).vesperTrackHostVisibility())
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 680))
            window.minSize = NSSize(width: 780, height: 520)
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.center()
            window.title = navigation.selection.settingsTitle
            track({ [navigation] in navigation.selection.settingsTitle }, apply: { [weak window] in window?.title = $0 })
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
