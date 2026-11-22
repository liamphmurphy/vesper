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

    // MARK: - Extracting Touched Files from Events

    private static let writeTools: Set<String> = [
        "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "write", "patch",
    ]
    private static let readTools: Set<String> = ["Read", "read", "view", "read_file"]

    /// Extracts files read or edited across the run and its delegated child runs.
    /// Changed files (`writes > 0`) sort first, then alphabetically by path.
    public static func extractFiles(from events: [API.RunEvent], childEvents: [[API.RunEvent]] = []) -> [RunFileEntry] {
        let streams = [events] + childEvents
        var builders: [String: FileBuilder] = [:]

        for stream in streams {
            let paired = RunThreadLogic.pairRows(stream, runId: "files")
            for row in paired {
                guard case .tool(let pair) = row else { continue }
                let bare = RunThreadLogic.bareTool(pair.call.payload["tool"]?.stringValue ?? "")
                let tool = RunThreadLogic.toolName(pair.call.payload["tool"]?.stringValue ?? "")
                let isWrite = writeTools.contains(tool) || writeTools.contains(bare)
                let isRead = readTools.contains(tool) || readTools.contains(bare)
                guard isWrite || isRead else { continue }

                let input = RunThreadLogic.jsonObject(pair.input)
                if bare == "apply_patch" || bare == "patch",
                   let rawPatch = input["patch"]?.stringValue ?? input["input"]?.stringValue ?? input["diff"]?.stringValue,
                   rawPatch.contains("*** Update File:") || rawPatch.contains("*** Add File:") || rawPatch.contains("diff --git") {
                    let parsedPatches = extractMultiFilePatch(rawPatch)
                    if !parsedPatches.isEmpty {
                        for (filePath, hunks, rawCode) in parsedPatches {
                            record(
                                path: filePath,
                                eventSeq: pair.call.seq,
                                tool: tool,
                                isWrite: true,
                                hunks: hunks,
                                code: rawCode,
                                into: &builders
                            )
                        }
                        continue
                    }
                }

                let rawPath = (input["file_path"]?.stringValue
                    ?? input["path"]?.stringValue
                    ?? input["notebook_path"]?.stringValue
                    ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawPath.isEmpty else { continue }

                var hunks: [DiffHunk] = []
                var code: String?
                if isWrite {
                    if let oldStr = input["old_string"]?.stringValue, let newStr = input["new_string"]?.stringValue {
                        hunks = [synthesizeEditDiff(oldString: oldStr, newString: newStr)]
                    } else if let edits = input["edits"], case .array(let editList) = edits {
                        hunks = editList.enumerated().compactMap { idx, item in
                            guard let oldS = item["old_string"]?.stringValue,
                                  let newS = item["new_string"]?.stringValue else { return nil }
                            var hunk = synthesizeEditDiff(oldString: oldS, newString: newS)
                            hunk.id = idx
                            return hunk
                        }
                    } else if let patchText = input["patch"]?.stringValue ?? input["diff"]?.stringValue {
                        hunks = parseHunks(patchText)
                    } else if let content = input["content"]?.stringValue ?? input["new_source"]?.stringValue {
                        code = content
                    }
                } else if !pair.output.isEmpty && !pair.isError {
                    code = pair.output
                }

                record(
                    path: rawPath,
                    eventSeq: pair.call.seq,
                    tool: tool,
                    isWrite: isWrite,
                    hunks: hunks,
                    code: code,
                    into: &builders
                )
            }
        }

        return builders.values.map { builder in
            RunFileEntry(
                path: builder.path,
                writes: builder.writes,
                reads: builder.reads,
                additions: builder.additions,
                deletions: builder.deletions,
                language: language(forPath: builder.path),
                snippets: builder.snippets
            )
        }.sorted { a, b in
            if a.isChanged != b.isChanged { return a.isChanged && !b.isChanged }
            return a.path < b.path
        }
    }

    private struct FileBuilder {
        var path: String
        var writes = 0
        var reads = 0
        var additions = 0
        var deletions = 0
        var snippets: [FileChangeSnippet] = []
    }

    private static func record(
        path: String,
        eventSeq: Int,
        tool: String,
        isWrite: Bool,
        hunks: [DiffHunk],
        code: String?,
        into builders: inout [String: FileBuilder]
    ) {
        var b = builders[path] ?? FileBuilder(path: path)
        if isWrite { b.writes += 1 } else { b.reads += 1 }

        var adds = 0
        var dels = 0
        for h in hunks {
            for r in h.rows {
                if r.kind == .addition { adds += 1 }
                else if r.kind == .deletion { dels += 1 }
            }
        }
        if isWrite && hunks.isEmpty, let code {
            adds = splitLines(code).count
        }
        b.additions += adds
        b.deletions += dels

        if !hunks.isEmpty || code != nil {
            b.snippets.append(FileChangeSnippet(
                id: "\(path)#\(eventSeq)#\(b.snippets.count)",
                eventSeq: eventSeq,
                tool: tool,
                isWrite: isWrite,
                hunks: hunks,
                code: code,
                additions: adds,
                deletions: dels
            ))
        }
        builders[path] = b
    }

    private static func extractMultiFilePatch(_ raw: String) -> [(path: String, hunks: [DiffHunk], code: String?)] {
        let lines = raw.components(separatedBy: "\n")
        var out: [(path: String, hunks: [DiffHunk], code: String?)] = []
        var currentPath: String?
        var isAddedFile = false
        var buffer: [String] = []

        func flush() {
            guard let path = currentPath, !path.isEmpty else { return }
            let body = buffer.joined(separator: "\n")
            if isAddedFile {
                let code = buffer.map { $0.hasPrefix("+") ? String($0.dropFirst()) : $0 }.joined(separator: "\n")
                out.append((path, [], code))
            } else {
                let hunks = parseHunks(body)
                out.append((path, hunks, hunks.isEmpty ? body : nil))
            }
            buffer = []
            isAddedFile = false
        }

        for line in lines {
            if line.hasPrefix("*** Update File: ") {
                flush()
                currentPath = String(line.dropFirst("*** Update File: ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("*** Add File: ") {
                flush()
                currentPath = String(line.dropFirst("*** Add File: ".count)).trimmingCharacters(in: .whitespaces)
                isAddedFile = true
            } else if line.hasPrefix("*** Delete File: ") {
                flush()
                currentPath = String(line.dropFirst("*** Delete File: ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("*** End Patch") || line.hasPrefix("*** Begin Patch") {
                continue
            } else if line.hasPrefix("+++ b/") {
                let p = String(line.dropFirst("+++ b/".count)).trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { currentPath = p }
            } else if line.hasPrefix("diff --git ") {
                flush()
                let parts = line.split(separator: " ")
                if let last = parts.last, last.hasPrefix("b/") {
                    currentPath = String(last.dropFirst(2))
                }
            } else if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file mode") {
                continue
            } else if currentPath != nil {
                buffer.append(line)
            }
        }
        flush()
        return out
    }
}
