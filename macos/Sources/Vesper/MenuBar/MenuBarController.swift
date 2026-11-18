import AppKit
import VesperCore

/// The menu bar extra (desktop/src/native-tray.ts): a template icon per stack state, the Needs-you
/// count beside it, and the menu from `TrayModel`.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var icons: [String: NSImage] = [:]
    private let onAction: (TrayAction) -> Void

    init(onAction: @escaping (TrayAction) -> Void) {
        self.onAction = onAction
    }

    var isActive: Bool { statusItem != nil }
    var statusItemForTesting: NSStatusItem? { statusItem }

    func ensure() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = icon(.running)
        item.button?.imagePosition = .imageLeading
        statusItem = item
    }

    func destroy() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func render(_ input: TrayMenuInput, count: Int, showCount: Bool) {
        guard let statusItem, let button = statusItem.button else { return }
        button.image = icon(TrayModel.iconState(input.health.phase))
        let title = TrayModel.trayTitle(count: count, showCount: showCount)
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " " + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        button.toolTip = TrayModel.trayTooltip(input.health, count: count)
        statusItem.menu = MenuBuilder.build(TrayModel.buildTrayMenu(input), onAction: onAction)
    }

    // MARK: Icons

    private func icon(_ state: TrayModel.IconState) -> NSImage? {
        let name = switch state {
        case .running: "trayTemplate"
        case .starting: "trayStartingTemplate"
        case .error: "trayError"
        }
        if let cached = icons[name] { return cached }
        guard let image = Self.loadIcon(name) else { return nil }
        icons[name] = image
        return image
    }

    /// <bundle>/Resources/tray, or <repo>/desktop/renderer/tray when running unbundled.
    static func iconDirectory() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("tray")) }
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() } // MenuBar, Vesper, Sources, macos, <repo>
        candidates.append(repo.appendingPathComponent("desktop/renderer/tray"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("trayTemplate.png").path) }
    }

    /// `<name>.png` plus `<name>@2x.png` as one image; names ending in "Template" are tinted by macOS.
    static func loadIcon(_ name: String) -> NSImage? {
        guard let dir = iconDirectory() else { return nil }
        let image = NSImage()
        for file in ["\(name).png", "\(name)@2x.png"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)), let rep = NSBitmapImageRep(data: data) else { continue }
            if file.contains("@2x") {
                rep.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
            } else if image.size == .zero {
                image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        if let first = image.representations.first, first.size != .zero { image.size = first.size }
        image.isTemplate = name.hasSuffix("Template")
        return image
    }
}
