import SwiftUI
import VesperCore

/// Native SwiftUI Code Review inspector for Chat (`chat.code`).
/// Supports multi-repo selection, Branch vs Last-turn diffing, syntax-highlighted diffs & full files,
/// commit history popover, and inline line comments submitted as a single review message.
struct ChatCodeInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String

    @State private var selectedRepo: String?
    @State private var mode: ChatCodeReviewLogic.Mode = .branch
    @State private var showAllTreeFiles = false
    @State private var selectedPathByRepo: [String: String] = [:]
    @State private var commentsByRepo: [String: [String: ChatCodeReviewLogic.LineComment]] = [:]
    @State private var editingKey: String?
    @State private var editingDraft = ""
    @State private var showCommitsPopover = false
    @State private var highlightedDetailKey = ""
    @State private var highlightedLines: [String: [[CodeToken]]] = [:]
    @State private var parseCache = ParsedCodeDetailCache()
    @State private var sendingReview = false
    @State private var sendError: String?
    @State private var watchedKeys: [QueryKey] = []

    @MainActor
    private final class ParsedCodeDetailCache {
        private var diffKey = ""
        private var diffHunks: [RunFilesLogic.DiffHunk] = []
        private var diffItems: [ChatCodeReviewLogic.DiffDisplayItem] = []

        private var fileKey = ""
        private var fileLines: [String] = []

        func diff(key: String, patch: String) -> (hunks: [RunFilesLogic.DiffHunk], items: [ChatCodeReviewLogic.DiffDisplayItem]) {
            if diffKey != key {
                diffKey = key
                diffHunks = RunFilesLogic.parseHunks(patch)
                diffItems = ChatCodeReviewLogic.flattenHunks(diffHunks)
            }
            return (diffHunks, diffItems)
        }

        func lines(key: String, content: String) -> [String] {
            if fileKey != key {
                fileKey = key
                fileLines = content.components(separatedBy: "\n")
            }
            return fileLines
        }
    }

    private var codeReviewRequest: APIRequest<API.CodeReviewList> {
        API.getChatCodeReview(id: chatId)
    }

    private var chatRequest: APIRequest<API.ChatSession> {
        API.getChat(id: chatId)
    }

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: chatId, limit: 200)
    }

    var body: some View {
        let p = theme.palette
        let reviews = context.store.entry(codeReviewRequest).data?.repositories ?? []
        let chat = context.store.entry(chatRequest).data
        // Only track messagesRequest in `.turn` mode so active-chat 1.5s polling does not force
        // full diff re-renders while inspecting branch changes.
        let messages = mode == .turn ? (context.store.entry(messagesRequest).data?.messages ?? []) : []
        let review: API.CodeReview? = reviews.first(where: { $0.repository == selectedRepo })
            ?? reviews.first(where: { $0.repository == chat?.repoUrl })
            ?? reviews.first

        Group {
            if let review {
                reviewContent(review: review, reviews: reviews, chat: chat, messages: messages, p: p)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 20))
                        .foregroundStyle(p.tertiaryText)
                    Text("No code yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.text)
                    Text("Once the persona works in a repository, its branch shows here, updating as it edits.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(chatId):\(mode.rawValue)") {
            syncWatches()
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
            highlightedDetailKey = ""
            highlightedLines = [:]
        }
    }

    private func reviewContent(
        review: API.CodeReview,
        reviews: [API.CodeReview],
        chat: API.ChatSession?,
        messages: [API.ChatMessage],
        p: NativePalette
    ) -> some View {
        let repoKey = review.repository
        let primaryRepo = chat?.repoUrl ?? reviews.first?.repository
        let files: [API.ChatCodeChange] = mode == .branch
            ? review.files
            : ChatCodeReviewLogic.lastTurnChanges(messages: messages, review: review, primaryRepo: primaryRepo)
        let treeFiles = review.tree ?? []
        let hasTree = !treeFiles.isEmpty && mode == .branch
        let totals = ChatCodeReviewLogic.totals(for: files)
        let repoComments = commentsByRepo[repoKey] ?? [:]
        let pendingComments = repoComments.values.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let chosenPath: String? = {
            if let picked = selectedPathByRepo[repoKey] {
                if files.contains(where: { $0.path == picked }) { return picked }
                if hasTree && showAllTreeFiles && treeFiles.contains(where: { $0.path == picked }) { return picked }
            }
            return files.first?.path ?? (hasTree && showAllTreeFiles ? treeFiles.first?.path : nil)
        }()
        let activeChange = chosenPath.flatMap { path in files.first(where: { $0.path == path }) }
        let activeTreeFile = chosenPath.flatMap { path in treeFiles.first(where: { $0.path == path }) }

        return VStack(spacing: 0) {
            // Top bar: repo selector, branch badge, commits, mode switcher
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if reviews.count > 1 {
                        Menu {
                            ForEach(Array(reviews.enumerated()), id: \.offset) { _, item in
                                Button {
                                    selectedRepo = item.repository
                                } label: {
                                    if item.repository == review.repository {
                                        Label(ChatCodeReviewLogic.repoName(item.repository), systemImage: "checkmark")
                                    } else {
                                        Text(ChatCodeReviewLogic.repoName(item.repository))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(ChatCodeReviewLogic.repoName(review.repository))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(p.text)
                        }
                        .menuStyle(.borderlessButton)
                    } else {
                        Text(ChatCodeReviewLogic.repoName(review.repository))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                    }

                    if let branch = review.branch, !branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                            Text(branch)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            if review.dirty {
                                Circle().fill(Color.orange).frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(p.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.border))
                    }

                    Spacer(minLength: 4)

                    if !review.commits.isEmpty {
                        Button {
                            showCommitsPopover.toggle()
                        } label: {
                            Text("\(review.commits.count) \(review.commits.count == 1 ? "commit" : "commits")")
                                .font(.system(size: 11))
                                .foregroundStyle(p.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showCommitsPopover) {
                            commitsPopoverView(commits: review.commits, p: p)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Picker("Diff mode", selection: $mode) {
                        ForEach(ChatCodeReviewLogic.Mode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 160)

                    if hasTree {
                        Toggle("All files", isOn: $showAllTreeFiles)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                            .foregroundStyle(p.tertiaryText)
                        if totals.additions > 0 {
                            Text("+\(totals.additions)")
                                .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                        }
                        if totals.deletions > 0 {
                            Text("-\(totals.deletions)")
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                }

                if !pendingComments.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(pendingComments.count) line \(pendingComments.count == 1 ? "comment" : "comments")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.text)
                        Spacer()
                        Button("Clear") {
                            commentsByRepo[repoKey] = [:]
                            editingKey = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(p.secondaryText)
                        .disabled(sendingReview)

                        Button(chat?.state == .running ? "Queue review" : "Send review") {
                            submitReview(
                                comments: Array(pendingComments),
                                branch: review.branch,
                                repoKey: repoKey,
                                isRunning: chat?.state == .running
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(sendingReview)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(p.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }

                if let sendError {
                    Text(sendError)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }
            .padding(10)

            Divider()

            // File list + Diff split
            if files.isEmpty && !(hasTree && showAllTreeFiles) {
                VStack(spacing: 6) {
                    Text(mode == .branch ? "No changes on this branch yet." : "No file changes in the last turn.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                VSplitView {
                    fileListView(
                        files: files,
                        treeFiles: (hasTree && showAllTreeFiles) ? treeFiles : [],
                        selectedPath: chosenPath,
                        repoKey: repoKey,
                        comments: repoComments,
                        p: p
                    )
                    .frame(minHeight: 110, idealHeight: 160, maxHeight: 280)

                    detailPane(
                        path: chosenPath,
                        change: activeChange,
                        treeFile: activeTreeFile,
                        repoKey: repoKey,
                        comments: repoComments,
                        p: p
                    )
                    .frame(minHeight: 180, maxHeight: .infinity)
                }
            }
        }
    }

    private func fileListView(
        files: [API.ChatCodeChange],
        treeFiles: [API.CodeReviewFile],
        selectedPath: String?,
        repoKey: String,
        comments: [String: ChatCodeReviewLogic.LineComment],
        p: NativePalette
    ) -> some View {
        let groups = ChatCodeReviewLogic.groupedFiles(files)
        let changedPaths = Set(files.map(\.path))
        let unchangedTree = treeFiles.filter { !changedPaths.contains($0.path) }.sorted { $0.path < $1.path }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(groups) { group in
                    if !group.dir.isEmpty {
                        Text(group.dir)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                    }
                    ForEach(Array(group.files.enumerated()), id: \.offset) { _, file in
                        let commentCount = comments.values.filter { $0.path == file.path && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                        let isSelected = file.path == selectedPath
                        Button {
                            selectedPathByRepo[repoKey] = file.path
                        } label: {
                            HStack(spacing: 6) {
                                Text(statusLetter(file.status))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(statusColor(file.status))
                                    .frame(width: 14)
                                Text(ChatCodeReviewLogic.baseName(file.path))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if commentCount > 0 {
                                    Text("\(commentCount)")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(p.accent, in: Capsule())
                                }
                                if file.additions > 0 {
                                    Text("+\(file.additions)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                                }
                                if file.deletions > 0 {
                                    Text("-\(file.deletions)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isSelected ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !unchangedTree.isEmpty {
                    Text("Unchanged (\(unchangedTree.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    ForEach(Array(unchangedTree.enumerated()), id: \.offset) { _, tf in
                        let isSelected = tf.path == selectedPath
                        Button {
                            selectedPathByRepo[repoKey] = tf.path
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10))
                                    .foregroundStyle(p.tertiaryText)
                                Text(tf.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(p.secondaryText)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isSelected ? p.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func detailPane(
        path: String?,
        change: API.ChatCodeChange?,
        treeFile: API.CodeReviewFile?,
        repoKey: String,
        comments: [String: ChatCodeReviewLogic.LineComment],
        p: NativePalette
    ) -> some View {
        let palette = CodePalette(theme: theme)
        if let path {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(path)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    if let old = change?.oldPath, !old.isEmpty, old != path {
                        Text("\u{2190} \(old)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        context.copyToClipboard(path)
                        context.showToast(ToastItemModel(id: "code.copyPath", title: "Copied path", tone: .success))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(p.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Copy path")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))

                Divider()

                let detailKey = "\(path):\(ChatCodeReviewLogic.contentFingerprint(change?.patch)):\(ChatCodeReviewLogic.contentFingerprint(treeFile?.content))"
                let activeHighlights = highlightedDetailKey == detailKey ? highlightedLines : [:]

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let change {
                            if change.binary {
                                Text("Binary file — no diff preview.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(14)
                            } else if let patch = change.patch, !patch.isEmpty {
                                let parsed = parseCache.diff(key: detailKey, patch: patch)
                                ForEach(parsed.items) { item in
                                    switch item {
                                    case .hunkHeader(_, let header):
                                        Text(header)
                                            .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                            .foregroundStyle(p.tertiaryText)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                                    case .row(let hunkId, let row, let tokenIndex):
                                        let tokenLines = activeHighlights["hunk:\(hunkId)"]
                                        let tokens = tokenIndex.flatMap { idx in
                                            tokenLines.flatMap { idx < $0.count ? $0[idx] : nil }
                                        }
                                        diffItemRow(
                                            row: row,
                                            tokens: tokens,
                                            path: path,
                                            repoKey: repoKey,
                                            comments: comments,
                                            palette: palette,
                                            p: p
                                        )
                                    }
                                }
                                if change.truncated {
                                    Text("Diff truncated to stay within review limits.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(p.tertiaryText)
                                        .padding(10)
                                }
                            } else {
                                Text("No textual diff available.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(14)
                            }
                        } else if let treeFile {
                            if treeFile.binary {
                                Text("Binary file (\(ChatCodeReviewLogic.formatBytes(treeFile.size))).")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(14)
                            } else if let content = treeFile.content {
                                let lines = parseCache.lines(key: detailKey, content: content)
                                let tokenLines = activeHighlights["file"]
                                ForEach(lines.indices, id: \.self) { idx in
                                    let line = lines[idx]
                                    let tokens = tokenLines.flatMap { idx < $0.count ? $0[idx] : nil }
                                    HStack(alignment: .top, spacing: 0) {
                                        Text("\(idx + 1)")
                                            .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                            .foregroundStyle(p.tertiaryText)
                                            .frame(width: 40, alignment: .trailing)
                                            .padding(.trailing, 10)
                                        highlightedText(line: line, tokens: tokens, palette: palette)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 1)
                                }
                            } else {
                                Text("File content not captured (\(ChatCodeReviewLogic.formatBytes(treeFile.size))).")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(14)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(minWidth: 360, alignment: .leading)
                }
                .task(id: detailKey) {
                    await highlight(detailKey: detailKey, path: path, change: change, treeFile: treeFile)
                }
            }
        } else {
            Text("Select a file to inspect its changes.")
                .font(.system(size: 12))
                .foregroundStyle(p.tertiaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func diffItemRow(
        row: RunFilesLogic.DiffRow,
        tokens: [CodeToken]?,
        path: String,
        repoKey: String,
        comments: [String: ChatCodeReviewLogic.LineComment],
        palette: CodePalette,
        p: NativePalette
    ) -> some View {
        let side: ChatCodeReviewLogic.CommentSide = row.newLine == nil ? .old : .new
        let lineNumber = row.newLine ?? row.oldLine ?? 0
        let cKey = ChatCodeReviewLogic.commentKey(path: path, line: lineNumber, side: side)
        let existingComment = comments[cKey]
        let isEditing = editingKey == "\(repoKey)::\(cKey)"

        VStack(alignment: .leading, spacing: 0) {
            diffRow(row: row, tokens: tokens, palette: palette, p: p, hasComment: existingComment != nil) {
                guard lineNumber > 0, row.kind != .meta, row.kind != .hunk else { return }
                editingKey = "\(repoKey)::\(cKey)"
                editingDraft = existingComment?.body ?? ""
            }

            if isEditing {
                inlineCommentEditor(
                    path: path,
                    line: lineNumber,
                    side: side,
                    code: row.text,
                    repoKey: repoKey,
                    cKey: cKey,
                    p: p
                )
            } else if let existingComment, !existingComment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(p.accent)
                        .padding(.top, 2)
                    Text(existingComment.body)
                        .font(.system(size: 12))
                        .foregroundStyle(p.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") {
                        editingKey = "\(repoKey)::\(cKey)"
                        editingDraft = existingComment.body
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    Button {
                        commentsByRepo[repoKey]?.removeValue(forKey: cKey)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(p.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    private func inlineCommentEditor(
        path: String,
        line: Int,
        side: ChatCodeReviewLogic.CommentSide,
        code: String,
        repoKey: String,
        cKey: String,
        p: NativePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comment on \(ChatCodeReviewLogic.baseName(path)):\(line)\(side == .old ? " (removed)" : "")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(p.secondaryText)
            TextField("Leave a review comment\u{2026}", text: $editingDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...5)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    editingKey = nil
                    editingDraft = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Save comment") {
                    let trimmed = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        commentsByRepo[repoKey]?.removeValue(forKey: cKey)
                    } else {
                        var map = commentsByRepo[repoKey] ?? [:]
                        map[cKey] = ChatCodeReviewLogic.LineComment(
                            path: path,
                            line: line,
                            side: side,
                            code: code,
                            body: trimmed
                        )
                        commentsByRepo[repoKey] = map
                    }
                    editingKey = nil
                    editingDraft = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.accent.opacity(0.5)))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func diffRow(
        row: RunFilesLogic.DiffRow,
        tokens: [CodeToken]?,
        palette: CodePalette,
        p: NativePalette,
        hasComment: Bool,
        onCommentTap: @escaping () -> Void
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
        case .meta, .hunk, .context:
            prefix = " "
            bg = Color.clear
            gutterFg = p.tertiaryText
        }

        return HStack(alignment: .top, spacing: 0) {
            Button(action: onCommentTap) {
                Image(systemName: hasComment ? "text.bubble.fill" : "plus.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(hasComment ? p.accent : p.tertiaryText.opacity(0.6))
                    .frame(width: 20, alignment: .center)
            }
            .buttonStyle(.plain)
            .help("Comment on line")

            Text(row.oldLine.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(p.tertiaryText)
            Text(row.newLine.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(p.tertiaryText)
            Text(prefix)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(gutterFg)
            highlightedText(line: row.text, tokens: tokens, palette: palette)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(bg)
    }

    private func commitsPopoverView(commits: [API.CodeCommit], p: NativePalette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Commits on branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(p.text)
                ForEach(Array(commits.enumerated()), id: \.offset) { _, commit in
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(commit.sha.prefix(7)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(p.accent)
                        Text(commit.subject)
                            .font(.system(size: 12))
                            .foregroundStyle(p.text)
                            .lineLimit(2)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(maxHeight: 280)
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

    private func highlight(detailKey: String, path: String, change: API.ChatCodeChange?, treeFile: API.CodeReviewFile?) async {
        if highlightedDetailKey == detailKey && !highlightedLines.isEmpty { return }
        highlightedDetailKey = detailKey
        highlightedLines = [:]
        guard let language = RunFilesLogic.language(forPath: path) else { return }

        if let patch = change?.patch, !patch.isEmpty {
            let hunks = parseCache.diff(key: detailKey, patch: patch).hunks
            var collected: [String: [[CodeToken]]] = [:]
            var pending = 0
            for hunk in hunks {
                guard !Task.isCancelled else { return }
                let code = hunk.rows
                    .filter { $0.kind != .hunk && $0.kind != .meta }
                    .map(\.text)
                    .joined(separator: "\n")
                if let tokens = await CodeHighlighter.shared.highlight(code, language: language) {
                    guard !Task.isCancelled else { return }
                    collected["hunk:\(hunk.id)"] = tokens
                    pending += 1
                    if pending >= 8 {
                        highlightedLines = collected
                        pending = 0
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if !collected.isEmpty {
                highlightedLines = collected
            }
        } else if let content = treeFile?.content {
            guard !Task.isCancelled else { return }
            if let tokens = await CodeHighlighter.shared.highlight(content, language: language) {
                guard !Task.isCancelled else { return }
                highlightedLines = ["file": tokens]
            }
        }
    }

    private func statusLetter(_ status: API.ChatCodeChange.Status) -> String {
        switch status {
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        default: "M"
        }
    }

    private func statusColor(_ status: API.ChatCodeChange.Status) -> Color {
        switch status {
        case .added: theme.swiftUIColor("state-done", fallback: .green)
        case .deleted: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .renamed: theme.palette.accent
        default: theme.swiftUIColor("pill-human-fg", fallback: .orange)
        }
    }

    private func submitReview(
        comments: [ChatCodeReviewLogic.LineComment],
        branch: String?,
        repoKey: String,
        isRunning: Bool
    ) {
        let body = ChatCodeReviewLogic.reviewMessage(comments: comments, branch: branch)
        guard !body.isEmpty, !sendingReview else { return }
        sendingReview = true
        sendError = nil
        Task {
            defer { sendingReview = false }
            do {
                if isRunning {
                    _ = try await context.store.mutate(
                        API.queueChatFollowup(id: chatId, body: API.ChatMessageEdit(body: body)),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                } else {
                    _ = try await context.store.mutate(
                        API.postChatMessage(id: chatId, body: API.NewChatMessage(body: body)),
                        invalidating: QueryInvalidation(resources: ["chats"])
                    )
                }
                commentsByRepo.removeValue(forKey: repoKey)
                editingKey = nil
                context.showToast(ToastItemModel(id: "code.review.sent", title: isRunning ? "Queued code review" : "Sent code review", tone: .success))
            } catch {
                sendError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func syncWatches() {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch<T: Decodable & Sendable>(_ req: APIRequest<T>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        watch(codeReviewRequest)
        watch(chatRequest)
        if mode == .turn {
            watch(messagesRequest)
        }
    }
}
