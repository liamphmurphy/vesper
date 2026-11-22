import SwiftUI
import VesperCore

/// Changed & read files viewer (`Files` tab): grouped file list on the left and unified diff hunks
/// or line-numbered code viewer syntax-highlighted via native `CodeHighlighter` + `CodePalette`.
struct RunFilesView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let run: API.Run
    let files: [RunFilesLogic.RunFileEntry]

    @State private var selectedPath: String?
    @State private var highlightedLines: [String: [[CodeToken]]] = [:]

    private var selectedFile: RunFilesLogic.RunFileEntry? {
        if let selectedPath, let hit = files.first(where: { $0.path == selectedPath }) {
            return hit
        }
        return files.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metaStrip
            Divider()
            if files.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    fileListPane
                        .frame(width: 260)
                    Divider()
                    fileDetailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: files.map(\.path), initial: true) { _, paths in
            if let current = selectedPath, paths.contains(current) { return }
            selectedPath = paths.first
        }
    }

    // MARK: - Top Metadata Strip

    private var metaStrip: some View {
        HStack(spacing: 12) {
            if let workspace = run.workspacePath, !workspace.isEmpty {
                Button {
                    context.copyToClipboard(workspace)
                    context.showToast(ToastItemModel(id: "run.workspace.copy", title: "Copied workspace path", tone: .success))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(workspace)
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                }
                .buttonStyle(.plain)
                .help("Copy workspace path")
            }
            if let branch = run.branch, !branch.isEmpty {
                HStack(spacing: 4) {
                    Text("Branch")
                        .foregroundStyle(theme.palette.secondaryText)
                    Text(branch)
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.text)
                }
                .vesperText(.small, theme)
            }
            Spacer()
            Text("From the run\u{2019}s tool calls. The pull request has the full diff.")
                .font(.system(size: theme.pointSize(.micro) + 1))
                .foregroundStyle(theme.palette.tertiaryText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.tertiaryText)
            Text("No files yet")
                .vesperText(.heading, theme)
            Text("Files appear here as the agent reads and edits them.")
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - File Sidebar

    private var fileListPane: some View {
        let changed = files.filter(\.isChanged)
        let readOnly = files.filter { !$0.isChanged }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !changed.isEmpty {
                    fileSection(title: "Changed · \(changed.count)", entries: changed)
                }
                if !readOnly.isEmpty {
                    fileSection(title: "Read · \(readOnly.count)", entries: readOnly)
                }
            }
            .padding(12)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
    }

    private func fileSection(title: String, entries: [RunFilesLogic.RunFileEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.tertiaryText)
                .padding(.horizontal, 6)
            ForEach(entries) { entry in
                let isSelected = selectedFile?.path == entry.path
                Button {
                    selectedPath = entry.path
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.fileName)
                                .font(.system(size: theme.pointSize(.body), weight: isSelected ? .semibold : .regular, design: .monospaced))
                                .foregroundStyle(theme.palette.text)
                                .lineLimit(1)
                            if !entry.directory.isEmpty {
                                Text(entry.directory)
                                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                    .foregroundStyle(theme.palette.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            if entry.additions > 0 || entry.deletions > 0 {
                                HStack(spacing: 4) {
                                    if entry.additions > 0 {
                                        Text("+\(entry.additions)")
                                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                                    }
                                    if entry.deletions > 0 {
                                        Text("-\(entry.deletions)")
                                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                    }
                                }
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                            }
                            Text(fileCountSummary(entry))
                                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(isSelected ? theme.palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fileCountSummary(_ entry: RunFilesLogic.RunFileEntry) -> String {
        var parts: [String] = []
        if entry.writes > 0 { parts.append("\(entry.writes) edit\(entry.writes == 1 ? "" : "s")") }
        if entry.reads > 0 { parts.append("\(entry.reads) read\(entry.reads == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Diff & Code Pane

    @ViewBuilder
    private var fileDetailPane: some View {
        if let file = selectedFile {
            let palette = CodePalette(theme: theme)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(file.path)
                            .font(.system(size: theme.pointSize(.heading), weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.palette.text)
                            .textSelection(.enabled)
                        if let lang = file.language {
                            TonePill(label: lang, tone: "neutral")
                        }
                        Spacer()
                        Button("Copy path") {
                            context.copyToClipboard(file.path)
                            context.showToast(ToastItemModel(id: "run.file.copy", title: "Copied path", tone: .success))
                        }
                        .buttonStyle(.vesper(.outline))
                    }

                    if file.snippets.isEmpty {
                        Text("This file was touched by the run, but its tool call didn\u{2019}t capture a diff or file preview.")
                            .vesperText(.body, theme)
                            .foregroundStyle(theme.palette.secondaryText)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
                    } else {
                        ForEach(file.snippets) { snippet in
                            snippetView(snippet, file: file, palette: palette)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: "\(file.path)#\(file.snippets.count)") {
                await highlightSnippets(for: file)
            }
        }
    }

    private func snippetView(
        _ snippet: RunFilesLogic.FileChangeSnippet,
        file: RunFilesLogic.RunFileEntry,
        palette: CodePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(snippet.tool)
                    .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.palette.text)
                Text("event #\(snippet.eventSeq)")
                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                Spacer()
                if snippet.additions > 0 {
                    Text("+\(snippet.additions)")
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                }
                if snippet.deletions > 0 {
                    Text("-\(snippet.deletions)")
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))

            Divider()

            if !snippet.hunks.isEmpty {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(snippet.hunks) { hunk in
                            let tokenKey = "\(snippet.id):hunk:\(hunk.id)"
                            let tokenLines = highlightedLines[tokenKey]
                            let codeRows = hunk.rows.filter { $0.kind != .hunk && $0.kind != .meta }
                            let rowToTokenIdx = Dictionary(uniqueKeysWithValues: codeRows.enumerated().map { ($0.element.id, $0.offset) })

                            Text(hunk.header)
                                .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                .foregroundStyle(theme.palette.tertiaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))

                            ForEach(hunk.rows) { row in
                                let tokens = rowToTokenIdx[row.id].flatMap { idx in
                                    tokenLines != nil && idx < tokenLines!.count ? tokenLines![idx] : nil
                                }
                                diffRowView(row, tokens: tokens, palette: palette)
                            }
                        }
                    }
                    .frame(minWidth: 520, alignment: .leading)
                }
            } else if let code = snippet.code {
                let lines = code.components(separatedBy: "\n")
                let tokenLines = highlightedLines["\(snippet.id):code"]
                ScrollView(.horizontal) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            let tokens = tokenLines != nil && idx < tokenLines!.count ? tokenLines![idx] : nil
                            HStack(alignment: .top, spacing: 0) {
                                Text("\(idx + 1)")
                                    .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                    .foregroundStyle(theme.palette.tertiaryText)
                                    .frame(width: 44, alignment: .trailing)
                                    .padding(.trailing, 10)
                                highlightedText(line: line, tokens: tokens, palette: palette)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: 520, alignment: .leading)
                }
                .frame(maxHeight: 520)
            }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }

    private func diffRowView(
        _ row: RunFilesLogic.DiffRow,
        tokens: [CodeToken]?,
        palette: CodePalette
    ) -> some View {
        let prefix: String
        let bg: Color
        let gutterFg: Color
        switch row.kind {
        case .addition:
            prefix = "+"
            bg = theme.swiftUIColor("state-done", fallback: .green).opacity(0.11)
            gutterFg = theme.swiftUIColor("state-done", fallback: .green)
        case .deletion:
            prefix = "-"
            bg = theme.swiftUIColor("pill-blocked-fg", fallback: .red).opacity(0.11)
            gutterFg = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .meta:
            prefix = " "
            bg = Color.clear
            gutterFg = theme.palette.tertiaryText
        case .hunk, .context:
            prefix = " "
            bg = Color.clear
            gutterFg = theme.palette.tertiaryText
        }

        return HStack(alignment: .top, spacing: 0) {
            Text(row.oldLine.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(theme.palette.tertiaryText)
            Text(row.newLine.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(theme.palette.tertiaryText)
            Text(prefix)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(gutterFg)
            highlightedText(line: row.text, tokens: tokens, palette: palette)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .background(bg)
    }

    private func highlightedText(line: String, tokens: [CodeToken]?, palette: CodePalette) -> Text {
        guard let tokens, !tokens.isEmpty else {
            return Text(line.isEmpty ? " " : line)
                .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                .foregroundStyle(theme.palette.text)
        }
        var attributed = AttributedString()
        for token in tokens {
            var part = AttributedString(token.content)
            let rawHex = theme.mode == .dark ? token.dark : token.light
            let mappedHex = palette.color(for: rawHex)
            if let rgba = RGBA(hex: mappedHex) {
                part.foregroundColor = Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
            } else {
                part.foregroundColor = theme.palette.text
            }
            attributed.append(part)
        }
        return Text(attributed)
            .font(.system(size: theme.pointSize(.mono), design: .monospaced))
    }

    private func highlightSnippets(for file: RunFilesLogic.RunFileEntry) async {
        guard let language = file.language else { return }
        for snippet in file.snippets {
            for hunk in snippet.hunks {
                let key = "\(snippet.id):hunk:\(hunk.id)"
                if highlightedLines[key] != nil { continue }
                let snippetCode = hunk.rows
                    .filter { $0.kind != .hunk && $0.kind != .meta }
                    .map(\.text)
                    .joined(separator: "\n")
                if let tokens = await CodeHighlighter.shared.highlight(snippetCode, language: language) {
                    highlightedLines[key] = tokens
                }
            }
            if let code = snippet.code {
                let key = "\(snippet.id):code"
                if highlightedLines[key] != nil { continue }
                if let tokens = await CodeHighlighter.shared.highlight(code, language: language) {
                    highlightedLines[key] = tokens
                }
            }
        }
    }
}
