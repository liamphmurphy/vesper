import Foundation

/// Changed/read file extraction, unified diff hunk parsing, edit diff synthesis, and Shiki language
/// detection for `RunFilesView`. Foundation-only for iOS-over-Tailscale portability.
public enum RunFilesLogic {
    public enum DiffRowKind: String, Sendable, Equatable {
        case hunk
        case meta
        case addition
        case deletion
        case context
    }

    public struct DiffRow: Sendable, Equatable, Identifiable {
        public var id: Int
        public var kind: DiffRowKind
        public var text: String
        public var oldLine: Int?
        public var newLine: Int?

        public init(id: Int, kind: DiffRowKind, text: String, oldLine: Int? = nil, newLine: Int? = nil) {
            self.id = id
            self.kind = kind
            self.text = text
            self.oldLine = oldLine
            self.newLine = newLine
        }
    }

    public struct DiffHunk: Sendable, Equatable, Identifiable {
        public var id: Int
        public var header: String
        public var oldStart: Int
        public var newStart: Int
        public var rows: [DiffRow]

        public init(id: Int, header: String, oldStart: Int, newStart: Int, rows: [DiffRow]) {
            self.id = id
            self.header = header
            self.oldStart = oldStart
            self.newStart = newStart
            self.rows = rows
        }
    }

    public struct FileChangeSnippet: Sendable, Equatable, Identifiable {
        public var id: String
        public var eventSeq: Int
        public var tool: String
        public var isWrite: Bool
        public var hunks: [DiffHunk]
        public var code: String?
        public var additions: Int
        public var deletions: Int

        public init(
            id: String,
            eventSeq: Int,
            tool: String,
            isWrite: Bool,
            hunks: [DiffHunk] = [],
            code: String? = nil,
            additions: Int = 0,
            deletions: Int = 0
        ) {
            self.id = id
            self.eventSeq = eventSeq
            self.tool = tool
            self.isWrite = isWrite
            self.hunks = hunks
            self.code = code
            self.additions = additions
            self.deletions = deletions
        }
    }

    public struct RunFileEntry: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var fileName: String
        public var directory: String
        public var writes: Int
        public var reads: Int
        public var additions: Int
        public var deletions: Int
        public var language: String?
        public var snippets: [FileChangeSnippet]

        public var isChanged: Bool { writes > 0 }

        public init(
            path: String,
            writes: Int,
            reads: Int,
            additions: Int,
            deletions: Int,
            language: String?,
            snippets: [FileChangeSnippet]
        ) {
            self.path = path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            self.fileName = parts.last.map(String.init) ?? path
            self.directory = parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
            self.writes = writes
            self.reads = reads
            self.additions = additions
            self.deletions = deletions
            self.language = language
            self.snippets = snippets
        }
    }

    // MARK: - Language Detection (`web/lib/code-diff.ts`)

    private static let byExt: [String: String] = [
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "tsx",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "jsx",
        "json": "json", "go": "go", "py": "python", "rb": "ruby", "rs": "rust",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "swift": "swift",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "hpp": "cpp",
        "cs": "csharp", "php": "php", "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript",
        "yaml": "yaml", "yml": "yaml", "toml": "toml", "md": "markdown",
        "html": "html", "css": "css", "scss": "scss", "sql": "sql", "mk": "make",
    ]

    private static let byName: [String: String] = [
        "dockerfile": "docker",
        "makefile": "make",
        "gnumakefile": "make",
    ]

    /// Shiki language id for a file path, or nil when plain text.
    public static func language(forPath path: String) -> String? {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let mapped = byName[name] { return mapped }
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let ext = String(name[name.index(after: dot)...])
        return byExt[ext]
    }

    // MARK: - Unified Diff Hunk Parsing

    /// Starting old/new line numbers from a `@@ -a,b +c,d @@` header, or nil if not a hunk header.
    public static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        guard let match = line.wholeMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@.*$/) else {
            return nil
        }
        guard let oldStart = Int(match.1), let newStart = Int(match.2) else { return nil }
        return (oldStart: oldStart, newStart: newStart)
    }

    /// Splits a unified diff into flat rows with old/new line numbers; prefix `+`/`-`/` ` is removed.
    public static func parsePatch(_ patch: String) -> [DiffRow] {
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var rows: [DiffRow] = []
        var oldLine = 0
        var newLine = 0
        var id = 0

        for line in lines {
            if let hunk = parseHunkHeader(line) {
                oldLine = hunk.oldStart
                newLine = hunk.newStart
                rows.append(DiffRow(id: id, kind: .hunk, text: line))
            } else if line.hasPrefix("\\") {
                rows.append(DiffRow(id: id, kind: .meta, text: line))
            } else if line.hasPrefix("+") {
                rows.append(DiffRow(id: id, kind: .addition, text: String(line.dropFirst()), newLine: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                rows.append(DiffRow(id: id, kind: .deletion, text: String(line.dropFirst()), oldLine: oldLine))
                oldLine += 1
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(DiffRow(id: id, kind: .context, text: text, oldLine: oldLine, newLine: newLine))
                oldLine += 1
                newLine += 1
            }
            id += 1
        }
        return rows
    }

    /// Groups parsed rows into structured `DiffHunk` blocks.
    public static func parseHunks(_ patch: String) -> [DiffHunk] {
        let rows = parsePatch(patch)
        var hunks: [DiffHunk] = []
        var currentRows: [DiffRow] = []
        var currentHeader = ""
        var currentOldStart = 1
        var currentNewStart = 1
        var hunkID = 0

        func flush() {
            guard !currentRows.isEmpty || !currentHeader.isEmpty else { return }
            hunks.append(DiffHunk(
                id: hunkID,
                header: currentHeader.isEmpty ? "@@ -\(currentOldStart) +\(currentNewStart) @@" : currentHeader,
                oldStart: currentOldStart,
                newStart: currentNewStart,
                rows: currentRows
            ))
            hunkID += 1
            currentRows = []
        }

        for row in rows {
            if row.kind == .hunk {
                flush()
                currentHeader = row.text
                if let parsed = parseHunkHeader(row.text) {
                    currentOldStart = parsed.oldStart
                    currentNewStart = parsed.newStart
                }
            } else {
                currentRows.append(row)
            }
        }
        flush()
        return hunks
    }

    /// Builds a unified hunk from an `Edit` tool's `old_string` -> `new_string` replacement,
    /// trimming common prefix/suffix lines into context rows around the changed middle.
    public static func synthesizeEditDiff(oldString: String, newString: String, startLine: Int = 1) -> DiffHunk {
        let oldLines = splitLines(oldString)
        let newLines = splitLines(newString)

        var prefix = 0
        while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < (oldLines.count - prefix)
                && suffix < (newLines.count - prefix)
                && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let contextLead = Array(oldLines.prefix(prefix).suffix(3))
        let leadSkipped = max(0, prefix - contextLead.count)
        let oldMid = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let newMid = Array(newLines[prefix..<(newLines.count - suffix)])
        let contextTrail = Array(oldLines.suffix(suffix).prefix(3))

        let oldStart = startLine + leadSkipped
        let newStart = startLine + leadSkipped
        var oldNo = oldStart
        var newNo = newStart
        var rowID = 0
        var rows: [DiffRow] = []

        for line in contextLead {
            rows.append(DiffRow(id: rowID, kind: .context, text: line, oldLine: oldNo, newLine: newNo))
            oldNo += 1
            newNo += 1
            rowID += 1
        }
        for line in oldMid {
            rows.append(DiffRow(id: rowID, kind: .deletion, text: line, oldLine: oldNo))
            oldNo += 1
            rowID += 1
        }
        for line in newMid {
            rows.append(DiffRow(id: rowID, kind: .addition, text: line, newLine: newNo))
            newNo += 1
            rowID += 1
        }
        for line in contextTrail {
            rows.append(DiffRow(id: rowID, kind: .context, text: line, oldLine: oldNo, newLine: newNo))
            oldNo += 1
            newNo += 1
            rowID += 1
        }

        let oldCount = contextLead.count + oldMid.count + contextTrail.count
        let newCount = contextLead.count + newMid.count + contextTrail.count
        let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return DiffHunk(id: 0, header: header, oldStart: oldStart, newStart: newStart, rows: rows)
    }

    private static func splitLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" && lines.count > 1 { lines.removeLast() }
        return lines
    }
}
