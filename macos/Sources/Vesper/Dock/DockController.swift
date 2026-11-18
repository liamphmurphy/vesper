import AppKit
import VesperCore

private struct PersonasResponse: Decodable {
    struct Persona: Decodable { var id: String?; var name: String? }
    var personas: [Persona]?
}

/// The Dock tile: badge, menu and run-image download progress (desktop/src/dock-model.ts and the
/// Dock parts of native.ts).
@MainActor
final class DockController {
    private(set) var personas: [PersonaSummary] = []
    private var personaTask: Task<Void, Never>?
    private var lastProgress: Double = -1
    private let progressBar = NSProgressIndicator()
    private var tileView: NSView?

    // MARK: Badge

    func setBadge(_ text: String) {
        NSApp.dockTile.badgeLabel = text.isEmpty ? nil : text
    }

    // MARK: Progress

    /// `fraction` 0...1 shows a bar over the icon; anything negative removes it.
    func setProgress(_ fraction: Double) {
        guard fraction != lastProgress else { return }
        lastProgress = fraction
        let tile = NSApp.dockTile
        if fraction < 0 {
            tile.contentView = nil
            tileView = nil
        } else {
            if tileView == nil {
                let size = tile.size == .zero ? NSSize(width: 128, height: 128) : tile.size
                let container = NSView(frame: NSRect(origin: .zero, size: size))
                let icon = NSImageView(frame: container.bounds)
                icon.image = NSApp.applicationIconImage
                icon.imageScaling = .scaleProportionallyUpOrDown
                container.addSubview(icon)
                progressBar.style = .bar
                progressBar.isIndeterminate = false
                progressBar.minValue = 0
                progressBar.maxValue = 1
                progressBar.frame = NSRect(x: size.width * 0.1, y: size.height * 0.08, width: size.width * 0.8, height: 14)
                container.addSubview(progressBar)
                tileView = container
                tile.contentView = container
            }
            progressBar.doubleValue = fraction
        }
        tile.display()
    }

    // MARK: Menu

    func menu(items: [InboxItem], onAction: @escaping (TrayAction) -> Void) -> NSMenu? {
        let model = DockModel.buildDockMenu(DockMenuInput(items: items, personas: personas, screenshot: true))
        return MenuBuilder.build(model, onAction: onAction)
    }

    // MARK: Personas (New Chat with …)

    func startPersonaRefresh(client: APIClient) {
        stopPersonaRefresh()
        personaTask = Task { [weak self] in
            while !Task.isCancelled {
                if let response: PersonasResponse = try? await client.get("/api/v1/personas", timeout: 5) {
                    self?.personas = (response.personas ?? []).compactMap {
                        guard let id = $0.id, let name = $0.name else { return nil }
                        return PersonaSummary(id: id, name: name)
                    }
                }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func stopPersonaRefresh() {
        personaTask?.cancel()
        personaTask = nil
        personas = []
    }
}
