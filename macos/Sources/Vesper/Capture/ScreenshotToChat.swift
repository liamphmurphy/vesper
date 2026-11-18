import AppKit
import CoreGraphics
import VesperCore

/// Screenshot to Chat: macOS's region picker (`screencapture -i`), then the send picker. macOS asks
/// for Screen Recording permission the first time; Escape in the picker writes nothing.
@MainActor
final class ScreenshotToChat {
    private weak var aux: AuxWindows?
    private var running = false

    init(aux: AuxWindows) { self.aux = aux }

    func start() {
        guard !running, let aux else { return }
        guard ScreenRecordingAccess.ensure(what: "take screenshots") else { return }
        running = true
        Task {
            defer { running = false }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-shot-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return }
            let file = dir.appendingPathComponent(Screenshot.fileName(Date())).path
            guard let args = Screenshot.arguments(file: file) else { return }
            // A cancelled capture can exit non-zero; the file check below decides.
            _ = try? await ProcessRunner.run(executable: URL(fileURLWithPath: Screenshot.screencaptureBin), arguments: args, timeout: 5 * 60)
            let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber
            guard let size, size.intValue > 0 else {
                try? FileManager.default.removeItem(at: dir)
                if !CGPreflightScreenCaptureAccess() { ScreenRecordingAccess.showDenied(what: "take screenshots") }
                return
            }
            aux.files.offer([file], cleanup: { try? FileManager.default.removeItem(at: dir) })
        }
    }
}
