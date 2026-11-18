import AppKit
import VesperCore

/// The "open this run's workspace folder" menu (desktop/src/native.ts `showWorkspaceMenu`): Finder,
/// the terminal app, the editor. The folder comes from the page, so it is only offered when it
/// resolves strictly inside a runner's host workspaces directory.
@MainActor
final class WorkspaceMenu: NSObject {
    private var chosen: OpenTarget?

    /// The path to open, or nil when the folder isn't inside the runner's roots.
    static func allowedFolder(_ folder: String, client: APIClient) async -> String? {
        let roots = await client.workspaceRoots()
        return WorkspaceOpen.isAllowedWorkspace(folder, rootDirs: roots)
    }

    /// Shows the menu at the mouse and returns the chosen target (nil if dismissed).
    func pick(settings: NativeSettings.Workspaces, in view: NSView) async -> OpenTarget? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let editorName = settings.editor.kind == .app ? settings.editor.app : settings.editor.command
        for (title, target) in [
            ("Open in Finder", OpenTarget.finder),
            ("Open in \(settings.terminalApp)", .terminal),
            ("Open in \(editorName)", .editor),
        ] {
            let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.rawValue
            menu.addItem(item)
        }
        // popUp blocks until the menu closes; the action has run by then.
        let point = view.window.map { view.convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) } ?? .zero
        menu.popUp(positioning: nil, at: point, in: view)
        return chosen
    }

    @objc private func picked(_ sender: NSMenuItem) {
        chosen = (sender.representedObject as? String).flatMap(OpenTarget.init(rawValue:))
    }

    /// Opens `dir` in `target`. Throws a message for the person on failure.
    static func open(_ target: OpenTarget, dir: String, settings: NativeSettings.Workspaces) async throws {
        guard let command = try WorkspaceOpen.openCommand(target, dir: dir, workspaces: settings) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
            return
        }
        let message: String? = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.file)
            process.arguments = command.args
            let err = Pipe()
            process.standardError = err
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { p in
                let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: p.terminationStatus == 0 ? nil : (text.isEmpty ? "exit \(p.terminationStatus)" : String(text.prefix(200))))
            }
            do { try process.run() } catch { continuation.resume(returning: error.localizedDescription) }
        }
        if let message { throw WorkspaceOpenFailure(message: message) }
    }
}

struct WorkspaceOpenFailure: Error { var message: String }
