import AppKit
import VesperCore

/// Files in: Open With, Dock drops, window drops and Quick Actions all arrive as `openFiles`.
/// macOS delivers a multi-file drop in one call, but Quick Actions and repeated drops can trickle
/// in, so paths are gathered for a moment and offered together (desktop native.ts handleOpenFile).
@MainActor
final class FilesIn {
    private weak var aux: AuxWindows?
    private var pending: [URL] = []
    private var timer: Timer?
    private(set) var picker: SendPickerController

    init(aux: AuxWindows) {
        self.aux = aux
        picker = SendPickerController(aux: aux)
    }

    func open(_ urls: [URL]) {
        guard let aux, aux.app?.settings.settings.files.dockDrop == true else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        pending.append(contentsOf: files.prefix(50 - min(pending.count, 50)))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
    }

    private func flush() {
        let urls = pending
        pending = []
        offer(urls.map(\.path))
    }

    /// Opens the picker for these paths (also used by Screenshot to Chat, with `cleanup`).
    func offer(_ paths: [String], cleanup: (() -> Void)? = nil) {
        guard let aux else { return }
        vlog("files: offering \(paths.count) path(s)")
        Task {
            await aux.whenConnected()
            let stats = paths.map { path -> DroppedFile in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                      let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                else { return DroppedFile(path: path, size: 0, isFile: false) }
                return DroppedFile(path: path, size: size.intValue, isFile: !isDir.boolValue)
            }
            let result = Drop.classifyDroppedFiles(stats)
            picker.present(accepted: result.accepted, rejected: result.rejected, cleanup: cleanup)
        }
    }
}
