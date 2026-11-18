import Foundation

// Port of desktop/src/workspace-open.ts. Open a run's or chat's host-folder workspace in Finder, a
// terminal or an editor. The folder comes from the web page, so it's only opened when it resolves
// inside a runner's host workspaces directory.

public enum OpenTarget: String, Sendable, CaseIterable { case finder, terminal, editor }

public struct OpenCommand: Sendable, Equatable {
    public var file: String
    public var args: [String]
}

public enum WorkspaceOpen {
    private static func normalize(_ path: String) -> String {
        // Collapses "." / ".." / duplicate slashes lexically, as path.normalize does.
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(part)
        }
        return "/" + out.joined(separator: "/")
    }

    /// Whether `realDir` (already realpath'd) is strictly inside one of the (realpath'd) workspace
    /// roots. The roots themselves don't count.
    public static func isInsideRoots(_ realDir: String, roots: [String]) -> Bool {
        guard realDir.hasPrefix("/") else { return false }
        let dir = normalize(realDir)
        return roots.contains { root in
            guard root.hasPrefix("/") else { return false }
            var r = normalize(root)
            while r.hasSuffix("/") { r.removeLast() }
            return dir.hasPrefix("\(r)/") && dir.count > r.count + 1
        }
    }

    /// `realpath(3)` of a folder that exists, or nil.
    public static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Resolves `folder` and the runner's roots with realpath and checks containment.
    public static func isAllowedWorkspace(_ folder: String, rootDirs: [String]) -> String? {
        guard folder.hasPrefix("/"), folder.utf16.count <= 2048, let real = realPath(folder) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        let roots = rootDirs.filter { $0.hasPrefix("/") }.compactMap(realPath)
        return isInsideRoots(real, roots: roots) ? real : nil
    }

    /// Escapes a string for an AppleScript double-quoted literal.
    public static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The process to run for a target. Finder is nil (the caller opens the folder with NSWorkspace).
    /// A terminal-kind editor runs its command in Terminal via AppleScript `do script`: the folder
    /// is shell-quoted, the whole line is an AppleScript string literal, and the command itself was
    /// validated as plain words.
    public static func openCommand(_ target: OpenTarget, dir: String, workspaces ws: NativeSettings.Workspaces) throws -> OpenCommand? {
        guard dir.hasPrefix("/") else { throw WorkspaceOpenError.relativePath }
        switch target {
        case .finder:
            return nil
        case .terminal:
            let app = isValidAppName(ws.terminalApp) ? ws.terminalApp : "Terminal"
            return OpenCommand(file: "/usr/bin/open", args: ["-a", app, dir])
        case .editor:
            if ws.editor.kind == .app {
                let app = isValidAppName(ws.editor.app) ? ws.editor.app : "Visual Studio Code"
                return OpenCommand(file: "/usr/bin/open", args: ["-a", app, dir])
            }
            let command = isValidTerminalCommand(ws.editor.command) ? ws.editor.command : "nvim"
            let line = "cd \(shQuote(dir)) && \(command) ."
            return OpenCommand(
                file: "/usr/bin/osascript",
                args: ["-e", "tell application \"Terminal\" to do script \(appleScriptString(line))", "-e", "tell application \"Terminal\" to activate"]
            )
        }
    }
}

public enum WorkspaceOpenError: Error { case relativePath }
