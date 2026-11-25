import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

// MARK: - Full-Page Route Screen (/apps/docs/:id)

/// Native full-page Docs editor for `/apps/docs/:id`.
struct DocEditorScreen: View {
    @Environment(NativeScreenContext.self) private var context

    private var canvasId: String {
        context.match.params["id"] ?? ""
    }

    var body: some View {
        DocEditorView(canvasId: canvasId, embedded: false)
            .id(canvasId)
    }
}

// MARK: - Reusable Native Docs Editor View (Full-Page & Embedded in Knowledge)

struct DocEditorView: View {
    private enum SaveState: Equatable {
        case saved
        case unsaved
        case saving
        case conflict
        case error(String)
    }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let canvasId: String
    let embedded: Bool

    @State private var document = KnowledgeEditorDocument(markdown: "")
    @State private var loadedSeq: Int = 0
    @State private var loadedBody: String = ""
    @State private var hasLoaded = false
    @State private var saveState: SaveState = .saved
    @State private var autosaveTask: Task<Void, Never>?
    @State private var notice: String?

    @State private var activeSelectionSegment: Int = 0
    @State private var activeSelectionRange: NSRange = NSRange(location: 0, length: 0)
    @State private var selectionRequest: KnowledgeTextSelectionRequest?
    @State private var selectionToken: Int = 0
    @State private var requestedTableFocus: (segmentIndex: Int, coord: TableCellCoordinate)?

    // Formatting link popover
    @State private var showLinkPopover = false
    @State private var linkURLDraft = "https://"

    // Inline ask-persona bar on selection
    @State private var showAskPopover = false
    @State private var askPromptDraft = ""

    // Suggestion review decisions
    @State private var reviewDecisions: [Int: DocReviewDecision] = [:]
    @State private var reviewRevisionKey: String = ""
    @State private var reviewBusy = false
    @State private var reviewError: String?

    // Comment rail
    @State private var showCommentsRail = false
    @State private var activeCommentId: String?
    @State private var pendingCommentAnchor: (quote: String, start: Int, end: Int, seq: Int)?
    @State private var newCommentBody = ""
    @State private var replyDrafts: [String: String] = [:]
    @State private var commentBusy = false

    // Inspector tab state (full-page mode)
    @State private var inspectorOpen = true
    @State private var activeInspectorTab = "chat"
    @State private var promoteReplaceAlertMessage: String?

    private var docRequest: APIRequest<API.MyCanvas> {
        API.getMyCanvas(canvasId: canvasId)
    }

    private func chatRequest(_ chatId: String) -> APIRequest<API.ChatSession> {
        API.getChat(id: chatId)
    }

    private func canvasRequest(chatId: String, seq: Int? = nil) -> APIRequest<API.ChatCanvas> {
        API.getChatCanvas(id: chatId, canvasId: canvasId, seq: seq)
    }

    private func commentsRequest(chatId: String) -> APIRequest<API.ChatCanvasComments> {
        API.listChatCanvasComments(id: chatId, canvasId: canvasId)
    }

    private var isDirty: Bool {
        hasLoaded && document.serialize() != loadedBody
    }

    var body: some View {
        let p = theme.palette
        let docEntry = context.store.entry(docRequest)
        let docMeta = docEntry.data
        let chatId = docMeta?.chatId ?? ""
        let chat = chatId.isEmpty ? nil : context.store.entry(chatRequest(chatId)).data
        let headEntry = chatId.isEmpty ? nil : context.store.entry(canvasRequest(chatId: chatId))
        let head = headEntry?.data
        let live = chat?.state == .running
        let readOnly = (chat?.archived ?? false) || live
        let personaName = chat?.speaker?.name ?? chat?.persona?.name ?? "Assistant"
        let title = head?.title ?? docMeta?.title ?? "Document"

        let reviewBaseSeq = head.map { DocEditorLogic.reviewBase(versions: $0.versions, reviewedSeq: docMeta?.reviewedSeq ?? 0) } ?? 0
        let wantsReview = head != nil && !live && reviewBaseSeq > 0 && (head?.seq ?? 0) > reviewBaseSeq
        let baseEntry = (wantsReview && !chatId.isEmpty) ? context.store.entry(canvasRequest(chatId: chatId, seq: reviewBaseSeq)) : nil
        let baseBody = (baseEntry?.data?.viewingSeq == reviewBaseSeq) ? baseEntry?.data?.body : nil
        let segments: [DocReviewSegment] = {
            guard let baseBody, let headBody = head?.body else { return [] }
            return DocEditorLogic.reviewSegments(base: baseBody, head: headBody)
        }()
        let changeSegments = segments.compactMap { seg -> (id: Int, before: [String], after: [String])? in
            if case .change(let id, let b, let a) = seg { return (id, b, a) }
            return nil
        }
        let isSuggesting = wantsReview && baseBody != nil && !changeSegments.isEmpty
        let comments = chatId.isEmpty ? [] : (context.store.entry(commentsRequest(chatId: chatId)).data?.comments ?? [])
        let openThreads = comments.filter { $0.parentId?.value == nil && $0.status != "resolved" }
        let resolvedThreads = comments.filter { $0.parentId?.value == nil && $0.status == "resolved" }
        let repliesByParent = Dictionary(grouping: comments.filter { $0.parentId?.value != nil }) { $0.parentId?.value ?? "" }
        let outline = DocEditorLogic.outlineOf(hasLoaded ? document.serialize() : (head?.body ?? ""))

        VStack(spacing: 0) {
            if let err = docEntry.error ?? headEntry?.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(p.tertiaryText)
                    Text("Couldn\u{2019}t open this document")
                        .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                    Text(err.userMessage)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if head == nil {
                ProgressView("Loading document\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                topActionStrip(
                    title: title,
                    seq: head?.seq ?? 0,
                    personaName: personaName,
                    live: live,
                    readOnly: readOnly,
                    isSuggesting: isSuggesting,
                    openCommentCount: openThreads.count,
                    chatId: chatId
                )
                Divider().overlay(p.border)

                if let notice {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(p.accent)
                        Text(notice).font(.system(size: 12)).foregroundStyle(p.text)
                        Spacer()
                        Button("Dismiss") { self.notice = nil }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(p.surface)
                    Divider().overlay(p.border)
                }

                if saveState == .conflict, let latest = head {
                    conflictBanner(latest: latest, chatId: chatId)
                    Divider().overlay(p.border)
                }

                HStack(spacing: 0) {
                    if isSuggesting {
                        docReviewBody(
                            segments: segments,
                            changeCount: changeSegments.count,
                            personaName: personaName,
                            chatId: chatId,
                            headSeq: head?.seq ?? 0,
                            readOnly: readOnly
                        )
                    } else {
                        editorBody(
                            readOnly: readOnly,
                            personaName: personaName,
                            chatId: chatId,
                            headSeq: head?.seq ?? 0
                        )
                    }

                    if !isSuggesting && (showCommentsRail || pendingCommentAnchor != nil) {
                        Divider().overlay(p.border)
                        commentsRail(
                            openThreads: openThreads,
                            resolvedThreads: resolvedThreads,
                            repliesByParent: repliesByParent,
                            chatId: chatId,
                            headSeq: head?.seq ?? 0,
                            personaName: personaName,
                            readOnly: readOnly
                        )
                        .frame(width: 280)
                        .background(p.surface)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .task(id: canvasId) {
            context.store.observe(docRequest)
            context.store.load(docRequest)
        }
        .task(id: chatId) {
            guard !chatId.isEmpty else { return }
            let cr = chatRequest(chatId)
            let hr = canvasRequest(chatId: chatId)
            let cmr = commentsRequest(chatId: chatId)
            context.store.observe(cr)
            context.store.observe(hr)
            context.store.observe(cmr)
            context.store.load(cr)
            context.store.load(hr)
            context.store.load(cmr)
        }
        .task(id: "\(chatId):\(reviewBaseSeq):\(wantsReview)") {
            guard wantsReview, !chatId.isEmpty, reviewBaseSeq > 0 else { return }
            context.store.load(canvasRequest(chatId: chatId, seq: reviewBaseSeq))
        }
        .onChange(of: head?.seq) { _, _ in
            guard let head else { return }
            syncFromServer(head: head)
        }
        .onChange(of: head?.body) { _, _ in
            guard let head, !hasLoaded else { return }
            syncFromServer(head: head)
        }
        .onChange(of: wantsReview && baseBody != nil && changeSegments.isEmpty) { _, isEmptyDiff in
            if isEmptyDiff, let seq = head?.seq, !reviewBusy {
                Task { await markReviewed(seq: seq) }
            }
        }
        .onChange(of: "\(baseBody ?? "")|\(head?.body ?? "")") { _, key in
            if key != reviewRevisionKey {
                reviewRevisionKey = key
                reviewDecisions = [:]
            }
        }
        .onChange(of: isSuggesting) { _, suggesting in
            if suggesting {
                activeInspectorTab = "review"
                inspectorOpen = true
            }
        }
        .onChange(of: "\(title)|\(saveState)|\(isSuggesting)|\(changeSegments.count)|\(outline.count)|\(inspectorOpen)|\(activeInspectorTab)|\(chatId)") { _, _ in
            guard !embedded else { return }
            publishChrome(
                title: title,
                seq: head?.seq ?? 0,
                chatId: chatId,
                personaName: personaName,
                live: live,
                isSuggesting: isSuggesting,
                segments: segments,
                changeCount: changeSegments.count,
                outline: outline,
                readOnly: readOnly
            )
        }
        .onAppear {
            if let head { syncFromServer(head: head) }
            if !embedded {
                publishChrome(
                    title: title,
                    seq: head?.seq ?? 0,
                    chatId: chatId,
                    personaName: personaName,
                    live: live,
                    isSuggesting: isSuggesting,
                    segments: segments,
                    changeCount: changeSegments.count,
                    outline: outline,
                    readOnly: readOnly
                )
            }
        }
        .onDisappear {
            autosaveTask?.cancel()
            if isDirty && !chatId.isEmpty {
                let text = document.serialize()
                let seq = loadedSeq
                Task { _ = try? await context.store.mutate(API.saveChatCanvas(id: chatId, canvasId: canvasId, body: API.ChatCanvasSave(baseSeq: seq, body: text, note: "Edited"))) }
            }
            if !embedded {
                context.sidebarView = nil
                context.inspectorView = nil
                context.onCommand = nil
            }
            context.store.stopObserving(docRequest.key)
            if !chatId.isEmpty {
                context.store.stopObserving(chatRequest(chatId).key)
                context.store.stopObserving(canvasRequest(chatId: chatId).key)
                context.store.stopObserving(commentsRequest(chatId: chatId).key)
            }
        }
        .alert("Replace wiki page?", isPresented: Binding(
            get: { promoteReplaceAlertMessage != nil },
            set: { if !$0 { promoteReplaceAlertMessage = nil } }
        )) {
            Button("Cancel", role: .cancel) { promoteReplaceAlertMessage = nil }
            Button("Replace", role: .destructive) {
                promoteReplaceAlertMessage = nil
                Task { await promoteToWiki(replace: true, chatId: chatId) }
            }
        } message: {
            Text(promoteReplaceAlertMessage ?? "A wiki page with this title already exists. Replace it?")
        }
    }

    // MARK: - Top Formatting & Action Strip

    @ViewBuilder
    private func topActionStrip(
        title: String,
        seq: Int,
        personaName: String,
        live: Bool,
        readOnly: Bool,
        isSuggesting: Bool,
        openCommentCount: Int,
        chatId: String
    ) -> some View {
        let p = theme.palette
        HStack(spacing: 6) {
            if !isSuggesting && !readOnly {
                Group {
                    fmtBtn("arrow.uturn.backward", help: "Undo", disabled: !document.canUndo) {
                        _ = document.undo()
                        scheduleAutosave(chatId: chatId)
                    }
                    fmtBtn("arrow.uturn.forward", help: "Redo", disabled: !document.canRedo) {
                        _ = document.redo()
                        scheduleAutosave(chatId: chatId)
                    }
                    Divider().frame(height: 16)
                    fmtTextBtn("H1", help: "Title") { prefixCurrentLine("# ", chatId: chatId) }
                    fmtTextBtn("H2", help: "Heading") { prefixCurrentLine("## ", chatId: chatId) }
                    fmtTextBtn("H3", help: "Subheading") { prefixCurrentLine("### ", chatId: chatId) }
                    Divider().frame(height: 16)
                    fmtTextBtn("B", bold: true, help: "Bold") { wrapSelection("**", "**", chatId: chatId) }
                    fmtTextBtn("I", italic: true, help: "Italic") { wrapSelection("*", "*", chatId: chatId) }
                    fmtTextBtn("S", strike: true, help: "Strikethrough") { wrapSelection("~~", "~~", chatId: chatId) }
                    fmtBtn("chevron.left.forwardslash.chevron.right", help: "Inline code") { wrapSelection("`", "`", chatId: chatId) }
                    Button {
                        linkURLDraft = "https://"
                        showLinkPopover = true
                    } label: {
                        Image(systemName: "link").font(.system(size: 12))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Insert link")
                    .popover(isPresented: $showLinkPopover) {
                        HStack(spacing: 6) {
                            TextField("https://…", text: $linkURLDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onSubmit { applyLink(chatId: chatId) }
                            Button("Apply") { applyLink(chatId: chatId) }
                                .buttonStyle(.vesper(.primary))
                        }
                        .padding(10)
                    }
                    Divider().frame(height: 16)
                    fmtBtn("list.bullet", help: "Bulleted list") { prefixCurrentLine("- ", chatId: chatId) }
                    fmtBtn("list.number", help: "Numbered list") { prefixCurrentLine("1. ", chatId: chatId) }
                    fmtBtn("checklist", help: "Checklist") { prefixCurrentLine("- [ ] ", chatId: chatId) }
                    fmtBtn("text.quote", help: "Quote") { prefixCurrentLine("> ", chatId: chatId) }
                    fmtBtn("curlybraces", help: "Code block") { insertBlock("\n```\n\n```\n", chatId: chatId) }
                    fmtBtn("tablecells", help: "Insert table") {
                        insertBlock("\n| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |\n", chatId: chatId)
                    }
                    fmtBtn("minus", help: "Divider") { insertBlock("\n---\n", chatId: chatId) }
                }
            } else if isSuggesting {
                Image(systemName: "sparkles")
                    .foregroundStyle(p.accent)
                Text("Reviewing \(personaName)\u{2019}s suggestions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.text)
            } else if live {
                ProgressView().controlSize(.mini)
                Text("\(personaName) is editing\u{2026}")
                    .font(.system(size: 12))
                    .foregroundStyle(p.secondaryText)
            }

            Spacer(minLength: 8)

            saveBadge(seq: seq)

            if !isSuggesting {
                Button {
                    showCommentsRail.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 11))
                        if openCommentCount > 0 {
                            Text("\(openCommentCount)")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(showCommentsRail ? p.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Toggle comments rail")
            }

            Menu {
                Button("Export as PDF\u{2026}") { Task { await exportPDF(title: title, chatId: chatId) } }
                Button("Export as Word (.docx)\u{2026}") { Task { await exportDocx(title: title, chatId: chatId) } }
                Button("Export as Markdown (.md)\u{2026}") { Task { await exportMarkdown(title: title, chatId: chatId) } }
                Divider()
                Button("Copy with formatting") { Task { await copyRich(title: title, chatId: chatId) } }
                Divider()
                Button("Save copy to Library") { Task { await saveToLibrary(chatId: chatId) } }
                Button("Publish to Wiki") { Task { await promoteToWiki(replace: false, chatId: chatId) } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                    Text("Export")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(p.surface)
    }

    @ViewBuilder
    private func saveBadge(seq: Int) -> some View {
        let p = theme.palette
        HStack(spacing: 5) {
            switch saveState {
            case .saved:
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("v\(seq)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.tertiaryText)
            case .unsaved:
                Circle().fill(p.accent).frame(width: 6, height: 6)
                Text("Unsaved").font(.system(size: 11)).foregroundStyle(p.secondaryText)
            case .saving:
                ProgressView().controlSize(.mini)
                Text("Saving\u{2026}").font(.system(size: 11)).foregroundStyle(p.secondaryText)
            case .conflict:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                Text("Conflict").font(.system(size: 11)).foregroundStyle(.orange)
            case .error(let msg):
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red)
                Text(msg).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            }
        }
    }

    private func fmtBtn(_ systemName: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    private func fmtTextBtn(_ label: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: bold ? .bold : .medium, design: italic ? .serif : .default))
                .italic(italic)
                .strikethrough(strike)
                .frame(minWidth: 22, minHeight: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - Conflict Banner

    @ViewBuilder
    private func conflictBanner(latest: API.ChatCanvas, chatId: String) -> some View {
        let p = theme.palette
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This document changed while you were typing. Your latest edits aren\u{2019}t saved yet.")
                .font(.system(size: 12))
                .foregroundStyle(p.text)
            Spacer()
            Button("Use latest version") {
                autosaveTask?.cancel()
                document = KnowledgeEditorDocument(markdown: latest.body)
                loadedSeq = latest.seq
                loadedBody = latest.body
                saveState = .saved
            }
            .buttonStyle(.vesper(.outline))
            Button("Keep mine") {
                loadedSeq = latest.seq
                saveState = .unsaved
                Task { await saveNow(chatId: chatId, forceSeq: latest.seq) }
            }
            .buttonStyle(.vesper(.primary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Main Editor Body

    @ViewBuilder
    private func editorBody(readOnly: Bool, personaName: String, chatId: String, headSeq: Int) -> some View {
        let p = theme.palette
        let selectedQuote = currentSelectedText()
        let firstPersona = personaName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? personaName

        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(document.segments.enumerated()), id: \.element.id) { index, segment in
                        switch segment {
                        case .prose(let prose):
                            KnowledgeTextView(
                                text: prose.text,
                                theme: theme,
                                selectionRequest: selectionRequest,
                                segmentIndex: index,
                                minHeight: index == 0 ? 320 : 28,
                                onTextChange: { updated, range in
                                    guard !readOnly else { return }
                                    handleProseChange(updated, range: range, at: index, personaName: personaName, chatId: chatId)
                                },
                                onSelectionChange: { range, isFocused in
                                    if isFocused {
                                        activeSelectionSegment = index
                                        activeSelectionRange = range
                                    }
                                },
                                onOpenLink: { target in
                                    if target.raw.hasPrefix("http://") || target.raw.hasPrefix("https://") {
                                        context.openExternal(target.raw)
                                    } else {
                                        context.navigate("/wiki/\(target.raw)")
                                    }
                                },
                                onCompletionKey: { _ in false }
                            )
                            .allowsHitTesting(!readOnly)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        case .table(let table):
                            MarkdownTableGridView(
                                table: table,
                                segmentIndex: index,
                                requestedFocusCell: requestedTableFocus?.segmentIndex == index ? requestedTableFocus?.coord : nil,
                                onEditCell: { row, col, text in
                                    guard !readOnly else { return }
                                    if document.editTableCell(at: index, row: row, column: col, text: text) {
                                        scheduleAutosave(chatId: chatId)
                                    }
                                },
                                onNavigateTab: { coord, backwards in
                                    document.navigateTableTab(at: index, from: coord, backwards: backwards)
                                },
                                onAddRow: { bodyIndex in
                                    guard !readOnly else { return }
                                    if document.editTable(at: index, description: "Add row", { $0.addRow(at: bodyIndex) }) {
                                        scheduleAutosave(chatId: chatId)
                                    }
                                },
                                onRemoveRow: { bodyIndex in
                                    guard !readOnly else { return }
                                    if document.editTable(at: index, description: "Remove row", { _ = $0.removeRow(at: bodyIndex) }) {
                                        scheduleAutosave(chatId: chatId)
                                    }
                                },
                                onAddColumn: { colIndex in
                                    guard !readOnly else { return }
                                    if document.editTable(at: index, description: "Add column", { $0.addColumn(at: colIndex) }) {
                                        scheduleAutosave(chatId: chatId)
                                    }
                                },
                                onRemoveColumn: { colIndex in
                                    guard !readOnly else { return }
                                    if document.editTable(at: index, description: "Remove column", { _ = $0.removeColumn(at: colIndex) }) {
                                        scheduleAutosave(chatId: chatId)
                                    }
                                },
                                onCycleAlignment: { colIndex in
                                    guard !readOnly else { return }
                                    let changed = document.editTable(at: index, description: "Align column") { model in
                                        let cur = colIndex < model.alignments.count ? model.alignments[colIndex] : .none
                                        let next: MarkdownTableAlignment = switch cur {
                                        case .none: .left
                                        case .left: .center
                                        case .center: .right
                                        case .right: .none
                                        }
                                        model.setAlignment(next, forColumn: colIndex)
                                    }
                                    if changed { scheduleAutosave(chatId: chatId) }
                                },
                                onResizeColumn: { colIndex, width in
                                    guard !readOnly else { return }
                                    _ = document.editTable(at: index, description: "Resize column") { $0.resizeColumn(at: colIndex, width: width) }
                                },
                                onToggleRawMode: { raw in
                                    _ = document.editTable(at: index, description: "Toggle raw") { $0.isEditingRawMarkdown = raw }
                                },
                                onApplyRawMarkdown: { raw in
                                    guard !readOnly else { return false }
                                    let ok = document.applyRawTableMarkdown(raw, at: index)
                                    if ok { scheduleAutosave(chatId: chatId) }
                                    return ok
                                },
                                onFocusCell: { coord in
                                    requestedTableFocus = (index, coord)
                                }
                            )
                            .allowsHitTesting(!readOnly)
                        }
                    }
                }
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if !readOnly && !selectedQuote.isEmpty {
                HStack(spacing: 6) {
                    Button("Comment") {
                        Task { await startComment(quote: selectedQuote, chatId: chatId, fallbackSeq: headSeq) }
                    }
                    .buttonStyle(.vesper(.outline))
                    Button("Shorter") {
                        Task { await askSelection(quote: selectedQuote, message: "Make this shorter.", chatId: chatId, fallbackSeq: headSeq) }
                    }
                    .buttonStyle(.vesper(.outline))
                    Button("Rewrite") {
                        Task { await askSelection(quote: selectedQuote, message: "Rewrite this passage.", chatId: chatId, fallbackSeq: headSeq) }
                    }
                    .buttonStyle(.vesper(.outline))
                    Button("\u{2726} Ask \(firstPersona)\u{2026}") {
                        askPromptDraft = ""
                        showAskPopover = true
                    }
                    .buttonStyle(.vesper(.primary))
                    .popover(isPresented: $showAskPopover) {
                        HStack(spacing: 6) {
                            TextField("Ask \(firstPersona) to\u{2026}", text: $askPromptDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit {
                                    let prompt = askPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !prompt.isEmpty else { return }
                                    showAskPopover = false
                                    Task { await askSelection(quote: selectedQuote, message: prompt, chatId: chatId, fallbackSeq: headSeq) }
                                }
                            Button("Send") {
                                let prompt = askPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !prompt.isEmpty else { return }
                                showAskPopover = false
                                Task { await askSelection(quote: selectedQuote, message: prompt, chatId: chatId, fallbackSeq: headSeq) }
                            }
                            .buttonStyle(.vesper(.primary))
                        }
                        .padding(10)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Inline Suggestion Review Body

    @ViewBuilder
    private func docReviewBody(
        segments: [DocReviewSegment],
        changeCount: Int,
        personaName: String,
        chatId: String,
        headSeq: Int,
        readOnly: Bool
    ) -> some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("\(personaName) suggested \(changeCount == 1 ? "1 change" : "\(changeCount) changes")")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reject all") {
                        applyAllDecisions(.reject, segments: segments, personaName: personaName, chatId: chatId, headSeq: headSeq)
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(reviewBusy || readOnly)
                    Button("Accept all") {
                        applyAllDecisions(.accept, segments: segments, personaName: personaName, chatId: chatId, headSeq: headSeq)
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(reviewBusy || readOnly)
                }
                .padding(12)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))

                if let reviewError {
                    Text(reviewError).font(.system(size: 12)).foregroundStyle(.red)
                }

                ForEach(segments) { seg in
                    switch seg {
                    case .same(_, let blocks):
                        MarkdownView(markdown: blocks.joined(separator: "\n\n"))
                    case .change(let id, let before, let after):
                        let decision = reviewDecisions[id]
                        VStack(alignment: .leading, spacing: 8) {
                            if !before.isEmpty && decision != .accept {
                                MarkdownView(markdown: before.joined(separator: "\n\n"))
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(decision == .reject ? Color.clear : Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(decision == .reject ? 0 : 0.35)))
                            }
                            if !after.isEmpty && decision != .reject {
                                MarkdownView(markdown: after.joined(separator: "\n\n"))
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(decision == .accept ? Color.clear : Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(decision == .accept ? 0 : 0.35)))
                            }
                            HStack(spacing: 8) {
                                Text("Change \(id + 1) of \(changeCount)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(p.tertiaryText)
                                Spacer()
                                if let d = decision {
                                    Button("\(d == .accept ? "Accepted" : "Rejected") \u{00B7} Undo") {
                                        reviewDecisions.removeValue(forKey: id)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 11))
                                    .disabled(reviewBusy || readOnly)
                                } else {
                                    Button("Reject") {
                                        decideChange(id, decision: .reject, segments: segments, changeCount: changeCount, personaName: personaName, chatId: chatId, headSeq: headSeq)
                                    }
                                    .buttonStyle(.vesper(.outline))
                                    .disabled(reviewBusy || readOnly)
                                    Button("Accept") {
                                        decideChange(id, decision: .accept, segments: segments, changeCount: changeCount, personaName: personaName, chatId: chatId, headSeq: headSeq)
                                    }
                                    .buttonStyle(.vesper(.primary))
                                    .disabled(reviewBusy || readOnly)
                                }
                            }
                        }
                        .padding(10)
                        .background(p.surface.opacity(decision == nil ? 0.65 : 0.3), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                        .opacity(decision == nil ? 1 : 0.7)
                    }
                }
            }
            .frame(maxWidth: 740, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Margin Comments Rail

    @ViewBuilder
    private func commentsRail(
        openThreads: [API.ChatCanvasComment],
        resolvedThreads: [API.ChatCanvasComment],
        repliesByParent: [String: [API.ChatCanvasComment]],
        chatId: String,
        headSeq: Int,
        personaName: String,
        readOnly: Bool
    ) -> some View {
        let p = theme.palette
        VStack(spacing: 0) {
            HStack {
                Text("Comments")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    showCommentsRail = false
                    pendingCommentAnchor = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().overlay(p.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let anchor = pendingCommentAnchor {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\u{201C}\(anchor.quote)\u{201D}")
                                .font(.system(size: 11))
                                .italic()
                                .foregroundStyle(p.secondaryText)
                                .lineLimit(3)
                            TextEditor(text: $newCommentBody)
                                .font(.system(size: 12))
                                .frame(minHeight: 60, maxHeight: 110)
                                .padding(4)
                                .background(p.background, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                            HStack(spacing: 6) {
                                Button("Cancel") {
                                    pendingCommentAnchor = nil
                                    newCommentBody = ""
                                }
                                .buttonStyle(.vesper(.outline))
                                Spacer()
                                Button("Comment") {
                                    Task { await submitNewComment(anchor: anchor, sendToPersona: false, chatId: chatId) }
                                }
                                .buttonStyle(.vesper(.outline))
                                .disabled(commentBusy || newCommentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("Ask \(personaName)") {
                                    Task { await submitNewComment(anchor: anchor, sendToPersona: true, chatId: chatId) }
                                }
                                .buttonStyle(.vesper(.primary))
                                .disabled(commentBusy || newCommentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(10)
                        .background(p.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.accent.opacity(0.6)))
                    }

                    if openThreads.isEmpty && resolvedThreads.isEmpty && pendingCommentAnchor == nil {
                        Text("Select text in the document to leave a comment or ask \(personaName) about a passage.")
                            .font(.system(size: 12))
                            .foregroundStyle(p.tertiaryText)
                            .padding(.top, 8)
                    }

                    ForEach(openThreads, id: \.id) { thread in
                        commentThreadCard(
                            thread: thread,
                            replies: repliesByParent[thread.id] ?? [],
                            chatId: chatId,
                            headSeq: headSeq,
                            personaName: personaName,
                            readOnly: readOnly
                        )
                    }

                    if !resolvedThreads.isEmpty {
                        DisclosureGroup("Resolved (\(resolvedThreads.count))") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(resolvedThreads, id: \.id) { thread in
                                    commentThreadCard(
                                        thread: thread,
                                        replies: repliesByParent[thread.id] ?? [],
                                        chatId: chatId,
                                        headSeq: headSeq,
                                        personaName: personaName,
                                        readOnly: readOnly
                                    )
                                    .opacity(0.7)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(p.secondaryText)
                    }
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func commentThreadCard(
        thread: API.ChatCanvasComment,
        replies: [API.ChatCanvasComment],
        chatId: String,
        headSeq: Int,
        personaName: String,
        readOnly: Bool
    ) -> some View {
        let p = theme.palette
        let isResolved = thread.status == "resolved"
        VStack(alignment: .leading, spacing: 6) {
            if let quote = thread.anchor.quote, !quote.isEmpty {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(2)
            }
            Text(thread.body)
                .font(.system(size: 12))
                .foregroundStyle(p.text)
            ForEach(replies, id: \.id) { reply in
                VStack(alignment: .leading, spacing: 2) {
                    Text(reply.authorType == "agent" ? personaName : "You")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                    Text(reply.body)
                        .font(.system(size: 12))
                        .foregroundStyle(p.text)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(p.border).frame(width: 2)
                }
            }
            if !readOnly {
                HStack(spacing: 6) {
                    TextField("Reply\u{2026}", text: Binding(
                        get: { replyDrafts[thread.id] ?? "" },
                        set: { replyDrafts[thread.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { Task { await submitReply(parentId: thread.id, chatId: chatId) } }

                    Button(isResolved ? "Reopen" : "Resolve") {
                        Task { await setCommentStatus(id: thread.id, status: isResolved ? "open" : "resolved", chatId: chatId) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    Button {
                        Task { await deleteComment(id: thread.id, chatId: chatId) }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(p.tertiaryText)
                }
            }
        }
        .padding(8)
        .background(p.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(activeCommentId == thread.id ? p.accent : p.border))
        .onTapGesture { activeCommentId = thread.id }
    }

    // MARK: - Full-Page Chrome (Sidebar Outline + Inspector Chat/Review)

    private func publishChrome(
        title: String,
        seq: Int,
        chatId: String,
        personaName: String,
        live: Bool,
        isSuggesting: Bool,
        segments: [DocReviewSegment],
        changeCount: Int,
        outline: [DocHeadingItem],
        readOnly: Bool
    ) {
        var tabs: [InspectorTab] = [
            InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .native, busy: live)
        ]
        if isSuggesting {
            let left = segments.compactMap { seg -> Int? in
                if case .change(let id, _, _) = seg, reviewDecisions[id] == nil { return id }
                return nil
            }.count
            tabs.append(InspectorTab(id: "review", label: "Review", icon: "check", kind: .native, badge: left > 0 ? NavBadge(text: "\(left)") : nil))
        }
        let activeTab = tabs.contains(where: { $0.id == activeInspectorTab }) ? activeInspectorTab : "chat"
        context.chrome = NativeChrome(
            title: title,
            subtitle: "Doc \u{00B7} v\(seq)",
            inspector: InspectorModel(id: "doc-\(canvasId)", open: inspectorOpen, activeTabId: activeTab, tabs: tabs)
        )
        context.sidebarView = AnyView(
            DocOutlineSidebarView(outline: outline) { item in
                jumpToHeading(item)
            }
        )
        context.inspectorView = { tabId in
            if tabId == "review" {
                return AnyView(
                    DocReviewInspectorView(
                        segments: segments,
                        decisions: reviewDecisions,
                        personaName: personaName,
                        busy: reviewBusy || readOnly,
                        error: reviewError,
                        onAcceptAll: { applyAllDecisions(.accept, segments: segments, personaName: personaName, chatId: chatId, headSeq: seq) },
                        onRejectAll: { applyAllDecisions(.reject, segments: segments, personaName: personaName, chatId: chatId, headSeq: seq) },
                        onDecide: { id, d in decideChange(id, decision: d, segments: segments, changeCount: changeCount, personaName: personaName, chatId: chatId, headSeq: seq) },
                        onUndo: { id in reviewDecisions.removeValue(forKey: id) }
                    )
                )
            }
            if !chatId.isEmpty {
                return AnyView(
                    DockedChatView(
                        chatId: chatId,
                        sections: [],
                        newChatLabel: "New chat",
                        creating: false,
                        createError: nil,
                        emptyDescription: "Ask \(personaName) to review or edit this document.",
                        emptyButtonTitle: "Start a chat",
                        welcomeWhere: "Document chat",
                        welcomeIntro: "Ask for edits, suggestions, or a review.",
                        starters: [],
                        onSelectChat: { _ in },
                        onNewChat: { context.navigate("/knowledge") },
                        onOpenFullChat: { id in context.navigate("/chat/\(id)") },
                        prepareBody: { $0 },
                        prepareContextRefs: { $0 },
                        onTurnCompleted: nil
                    ) { EmptyView() }
                )
            }
            return nil
        }
        context.onCommand = { cmd in
            switch cmd {
            case .inspectorVisibility(let open):
                inspectorOpen = open
            case .inspectorSelectTab(let tabId):
                activeInspectorTab = tabId
                inspectorOpen = true
            default:
                break
            }
        }
    }

    // MARK: - Editing, Autosave & Actions

    private func syncFromServer(head: API.ChatCanvas) {
        if !hasLoaded {
            document = KnowledgeEditorDocument(markdown: head.body)
            loadedSeq = head.seq
            loadedBody = head.body
            hasLoaded = true
            saveState = .saved
            return
        }
        guard head.seq != loadedSeq else { return }
        if isDirty {
            if head.seq > loadedSeq {
                saveState = .conflict
            }
            return
        }
        document = KnowledgeEditorDocument(markdown: head.body)
        loadedSeq = head.seq
        loadedBody = head.body
        saveState = .saved
    }

    private func handleProseChange(_ updated: String, range: NSRange, at index: Int, personaName: String, chatId: String) {
        // Detect `@Persona <instruction>\n` entered on a standalone line.
        if let prev = document.proseText(at: index),
           updated.count == prev.count + 1,
           range.location > 0,
           (updated as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == "\n",
           let mention = DocEditorLogic.detectPersonaMention(in: prev, cursorUTF16: range.location - 1, personaName: personaName) {
            let cleaned = (prev as NSString).replacingCharacters(in: mention.lineRange, with: "")
            document.setProse(cleaned, in: index)
            scheduleAutosave(chatId: chatId)
            Task { await sendMention(mention, chatId: chatId) }
            return
        }
        document.setProse(updated, in: index)
        scheduleAutosave(chatId: chatId)
    }

    private func scheduleAutosave(chatId: String) {
        guard !chatId.isEmpty else { return }
        if saveState != .conflict { saveState = .unsaved }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await saveNow(chatId: chatId)
        }
    }

    private func saveNow(chatId: String, forceSeq: Int? = nil) async {
        guard !chatId.isEmpty, hasLoaded else { return }
        guard saveState != .conflict || forceSeq != nil else { return }
        let body = document.serialize()
        if body == loadedBody && forceSeq == nil {
            saveState = .saved
            return
        }
        let baseSeq = forceSeq ?? loadedSeq
        saveState = .saving
        do {
            let version = try await context.store.mutate(
                API.saveChatCanvas(id: chatId, canvasId: canvasId, body: API.ChatCanvasSave(baseSeq: baseSeq, body: body, note: "Edited"))
            )
            loadedSeq = version.seq
            loadedBody = body
            saveState = document.serialize() == body ? .saved : .unsaved
            _ = await context.store.refetch(canvasRequest(chatId: chatId))
        } catch APIError.http(status: 409, _) {
            saveState = .conflict
            _ = await context.store.refetch(canvasRequest(chatId: chatId))
        } catch {
            saveState = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func currentSelectedText() -> String {
        guard activeSelectionRange.length > 0,
              let text = document.proseText(at: activeSelectionSegment) else { return "" }
        let ns = text as NSString
        guard activeSelectionRange.location + activeSelectionRange.length <= ns.length else { return "" }
        return ns.substring(with: activeSelectionRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wrapSelection(_ prefix: String, _ suffix: String, chatId: String) {
        guard let text = document.proseText(at: activeSelectionSegment) else { return }
        let ns = text as NSString
        let loc = max(0, min(activeSelectionRange.location, ns.length))
        let len = max(0, min(activeSelectionRange.length, ns.length - loc))
        let r = NSRange(location: loc, length: len)
        let selected = ns.substring(with: r)
        let replacement = "\(prefix)\(selected)\(suffix)"
        let next = ns.replacingCharacters(in: r, with: replacement)
        let caret = NSRange(location: loc + (prefix as NSString).length, length: len)
        document.setProse(next, in: activeSelectionSegment)
        selectionToken += 1
        selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: activeSelectionSegment, range: caret)
        scheduleAutosave(chatId: chatId)
    }

    private func prefixCurrentLine(_ prefix: String, chatId: String) {
        guard let text = document.proseText(at: activeSelectionSegment) else { return }
        let ns = text as NSString
        let loc = max(0, min(activeSelectionRange.location, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)
        let nextLine = line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : prefix + line
        let next = ns.replacingCharacters(in: lineRange, with: nextLine)
        let caret = NSRange(location: min((next as NSString).length, lineRange.location + (nextLine as NSString).length), length: 0)
        document.setProse(next, in: activeSelectionSegment)
        selectionToken += 1
        selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: activeSelectionSegment, range: caret)
        scheduleAutosave(chatId: chatId)
    }

    private func insertBlock(_ block: String, chatId: String) {
        let idx = min(activeSelectionSegment, max(0, document.segments.count - 1))
        guard let text = document.proseText(at: idx) else {
            document = KnowledgeEditorDocument(markdown: document.serialize() + block)
            scheduleAutosave(chatId: chatId)
            return
        }
        let ns = text as NSString
        let loc = max(0, min(activeSelectionRange.location + activeSelectionRange.length, ns.length))
        let next = ns.replacingCharacters(in: NSRange(location: loc, length: 0), with: block)
        let caret = NSRange(location: loc + (block as NSString).length, length: 0)
        document.setProse(next, in: idx)
        selectionToken += 1
        selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: idx, range: caret)
        scheduleAutosave(chatId: chatId)
    }

    private func applyLink(chatId: String) {
        let href = linkURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        showLinkPopover = false
        guard !href.isEmpty else { return }
        wrapSelection("[", "](\(href))", chatId: chatId)
    }

    private func jumpToHeading(_ heading: DocHeadingItem) {
        for (idx, seg) in document.segments.enumerated() {
            if case .prose(let prose) = seg {
                let ns = prose.text as NSString
                let range = ns.range(of: heading.text)
                if range.location != NSNotFound {
                    selectionToken += 1
                    selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: idx, range: range)
                    return
                }
            }
        }
    }

    // MARK: - Review Actions

    private func markReviewed(seq: Int) async {
        reviewBusy = true
        reviewError = nil
        defer { reviewBusy = false }
        do {
            _ = try await context.store.mutate(API.markDocReviewed(canvasId: canvasId, body: API.MarkDocReviewedBody(seq: seq)))
            _ = await context.store.refetch(docRequest)
        } catch {
            reviewError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func finishReview(
        decisions: [Int: DocReviewDecision],
        segments: [DocReviewSegment],
        personaName: String,
        chatId: String,
        headSeq: Int
    ) {
        let changeIds = segments.compactMap { seg -> Int? in
            if case .change(let id, _, _) = seg { return id }
            return nil
        }
        let allAccepted = changeIds.allSatisfy { decisions[$0] == .accept }
        Task {
            reviewBusy = true
            reviewError = nil
            defer { reviewBusy = false }
            do {
                if allAccepted {
                    _ = try await context.store.mutate(API.markDocReviewed(canvasId: canvasId, body: API.MarkDocReviewedBody(seq: headSeq)))
                } else {
                    let resolvedBody = DocEditorLogic.resolveReview(segments: segments, decisions: decisions)
                    let note = DocEditorLogic.reviewNote(segments: segments, decisions: decisions, persona: personaName)
                    let saved = try await context.store.mutate(
                        API.saveChatCanvas(id: chatId, canvasId: canvasId, body: API.ChatCanvasSave(baseSeq: headSeq, body: resolvedBody, note: note))
                    )
                    document = KnowledgeEditorDocument(markdown: resolvedBody)
                    loadedSeq = saved.seq
                    loadedBody = resolvedBody
                }
                _ = await context.store.refetch(docRequest)
                if !chatId.isEmpty { _ = await context.store.refetch(canvasRequest(chatId: chatId)) }
            } catch {
                reviewError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func decideChange(
        _ id: Int,
        decision: DocReviewDecision,
        segments: [DocReviewSegment],
        changeCount: Int,
        personaName: String,
        chatId: String,
        headSeq: Int
    ) {
        reviewDecisions[id] = decision
        if reviewDecisions.count >= changeCount {
            finishReview(decisions: reviewDecisions, segments: segments, personaName: personaName, chatId: chatId, headSeq: headSeq)
        }
    }

    private func applyAllDecisions(
        _ decision: DocReviewDecision,
        segments: [DocReviewSegment],
        personaName: String,
        chatId: String,
        headSeq: Int
    ) {
        var all: [Int: DocReviewDecision] = [:]
        for seg in segments {
            if case .change(let id, _, _) = seg { all[id] = decision }
        }
        reviewDecisions = all
        finishReview(decisions: all, segments: segments, personaName: personaName, chatId: chatId, headSeq: headSeq)
    }

    // MARK: - Comments & Persona Mentions

    private func startComment(quote: String, chatId: String, fallbackSeq: Int) async {
        await saveNow(chatId: chatId)
        let body = document.serialize()
        if let loc = DocEditorLogic.locateQuote(in: body, quote: quote, nearUTF16: activeSelectionRange.location) {
            pendingCommentAnchor = (String(quote.prefix(140)), loc.start, loc.end, max(loadedSeq, fallbackSeq))
            showCommentsRail = true
        } else {
            notice = "Couldn\u{2019}t place a comment on that selection. Try a shorter one."
        }
    }

    private func askSelection(quote: String, message: String, chatId: String, fallbackSeq: Int) async {
        guard !chatId.isEmpty else { return }
        await saveNow(chatId: chatId)
        let body = document.serialize()
        do {
            if let loc = DocEditorLogic.locateQuote(in: body, quote: quote, nearUTF16: activeSelectionRange.location) {
                let made = try await context.store.mutate(
                    API.createChatCanvasComment(
                        id: chatId,
                        canvasId: canvasId,
                        body: API.NewChatCanvasComment(body: message, end: loc.end, seq: max(loadedSeq, fallbackSeq), start: loc.start)
                    )
                )
                _ = try await context.store.mutate(
                    API.sendChatCanvasComments(
                        id: chatId,
                        canvasId: canvasId,
                        body: API.SendChatCanvasCommentsBody(commentIds: [made.id], message: message)
                    )
                )
            } else {
                let quoted = quote.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
                _ = try await context.store.mutate(
                    API.postChatMessage(id: chatId, body: API.NewChatMessage(body: "\(message)\n\nThe passage, in the document:\n\(quoted)"))
                )
            }
            activeInspectorTab = "chat"
            inspectorOpen = true
            _ = await context.store.refetch(commentsRequest(chatId: chatId))
        } catch {
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func sendMention(_ mention: DocPersonaMention, chatId: String) async {
        guard !chatId.isEmpty else { return }
        await saveNow(chatId: chatId)
        let whereText = mention.afterContext.isEmpty
            ? "at the start"
            : "right after the passage \u{201C}\(String(mention.afterContext.prefix(160)))\u{201D}"
        do {
            _ = try await context.store.mutate(
                API.postChatMessage(
                    id: chatId,
                    body: API.NewChatMessage(body: "\(mention.instruction)\n\n(Asked from inside the document, \(whereText). Write it into the document there.)")
                )
            )
            activeInspectorTab = "chat"
            inspectorOpen = true
        } catch {
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func submitNewComment(anchor: (quote: String, start: Int, end: Int, seq: Int), sendToPersona: Bool, chatId: String) async {
        let text = newCommentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatId.isEmpty else { return }
        commentBusy = true
        defer { commentBusy = false }
        do {
            let made = try await context.store.mutate(
                API.createChatCanvasComment(
                    id: chatId,
                    canvasId: canvasId,
                    body: API.NewChatCanvasComment(body: text, end: anchor.end, seq: anchor.seq, start: anchor.start)
                )
            )
            if sendToPersona {
                _ = try await context.store.mutate(
                    API.sendChatCanvasComments(
                        id: chatId,
                        canvasId: canvasId,
                        body: API.SendChatCanvasCommentsBody(commentIds: [made.id], message: text)
                    )
                )
            }
            pendingCommentAnchor = nil
            newCommentBody = ""
            _ = await context.store.refetch(commentsRequest(chatId: chatId))
        } catch {
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func submitReply(parentId: String, chatId: String) async {
        let text = (replyDrafts[parentId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chatId.isEmpty else { return }
        commentBusy = true
        defer { commentBusy = false }
        do {
            _ = try await context.store.mutate(
                API.createChatCanvasComment(
                    id: chatId,
                    canvasId: canvasId,
                    body: API.NewChatCanvasComment(body: text, parentId: parentId)
                )
            )
            replyDrafts[parentId] = ""
            _ = await context.store.refetch(commentsRequest(chatId: chatId))
        } catch {
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func setCommentStatus(id: String, status: String, chatId: String) async {
        guard !chatId.isEmpty else { return }
        do {
            _ = try await context.store.mutate(
                API.updateChatCanvasComment(id: chatId, canvasId: canvasId, commentId: id, body: API.UpdateChatCanvasCommentBody(status: status))
            )
            _ = await context.store.refetch(commentsRequest(chatId: chatId))
        } catch {
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func deleteComment(id: String, chatId: String) async {
        guard !chatId.isEmpty else { return }
        do {
            _ = try await context.store.mutate(API.deleteChatCanvasComment(id: chatId, canvasId: canvasId, commentId: id))
            _ = await context.store.refetch(commentsRequest(chatId: chatId))
        } catch {
            notice = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Exports

    private func exportMarkdown(title: String, chatId: String) async {
        await saveNow(chatId: chatId)
        let data = Data(document.serialize().utf8)
        presentSavePanel(defaultName: DocEditorLogic.sanitizedFileName(title, ext: "md"), data: data, contentTypes: [.plainText])
    }

    private func exportDocx(title: String, chatId: String) async {
        await saveNow(chatId: chatId)
        let data = DocEditorLogic.exportDocx(markdown: document.serialize(), title: title)
        let docxType = UTType(filenameExtension: "docx") ?? .data
        presentSavePanel(defaultName: DocEditorLogic.sanitizedFileName(title, ext: "docx"), data: data, contentTypes: [docxType])
    }

    private func exportPDF(title: String, chatId: String) async {
        await saveNow(chatId: chatId)
        let html = DocEditorLogic.renderHTML(markdown: document.serialize(), title: title)
        guard let htmlData = html.data(using: .utf8),
              let attr = try? NSAttributedString(
                  data: htmlData,
                  options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else {
            notice = "PDF export failed: couldn\u{2019}t render HTML."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DocEditorLogic.sanitizedFileName(title, ext: "pdf")
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = dest

        let textWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 1000))
        tv.textStorage?.setAttributedString(attr)
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: printInfo)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if op.run() {
            context.showToast(ToastItemModel(id: "doc.pdf", title: "Exported PDF", tone: .success))
        } else {
            notice = "PDF export failed."
        }
    }

    private func copyRich(title: String, chatId: String) async {
        await saveNow(chatId: chatId)
        let md = document.serialize()
        let html = DocEditorLogic.renderHTML(markdown: md, title: title)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(md, forType: .string)
        context.showToast(ToastItemModel(id: "doc.copy", title: "Copied with formatting", tone: .success))
    }

    private func saveToLibrary(chatId: String) async {
        await saveNow(chatId: chatId)
        do {
            _ = try await context.store.mutate(API.saveDocToLibrary(canvasId: canvasId))
            context.showToast(ToastItemModel(id: "doc.library", title: "Saved to your Library", tone: .success))
        } catch {
            notice = "Saving to Library failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }

    private func promoteToWiki(replace: Bool, chatId: String) async {
        await saveNow(chatId: chatId)
        do {
            let res = try await context.store.mutate(API.promoteDocToWiki(canvasId: canvasId, body: API.PromoteDocToWikiBody(replace: replace)))
            context.showToast(ToastItemModel(id: "doc.wiki", title: "Published to wiki as \(res.path)", tone: .success))
        } catch APIError.http(status: 409, let msg) where !replace {
            promoteReplaceAlertMessage = "\(msg) Replace it with this version?"
        } catch {
            notice = "Publishing to wiki failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }

    private func presentSavePanel(defaultName: String, data: Data, contentTypes: [UTType]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = contentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            context.showToast(ToastItemModel(id: "doc.export", title: "Saved \(url.lastPathComponent)", tone: .success))
        } catch {
            notice = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sidebar Outline & Review Inspector

private struct DocOutlineSidebarView: View {
    @Environment(\.vesperTheme) private var theme
    let outline: [DocHeadingItem]
    let onSelect: (DocHeadingItem) -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            Text("OUTLINE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(p.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if outline.isEmpty {
                Text("Add headings to build an outline.")
                    .font(.system(size: 12))
                    .foregroundStyle(p.tertiaryText)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(outline) { h in
                            Button {
                                onSelect(h)
                            } label: {
                                Text(h.text)
                                    .font(.system(size: 12, weight: h.level <= 2 ? .medium : .regular))
                                    .foregroundStyle(h.level == 1 ? p.text : p.secondaryText)
                                    .lineLimit(1)
                                    .padding(.leading, CGFloat(max(0, h.level - 1) * 10))
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DocReviewInspectorView: View {
    @Environment(\.vesperTheme) private var theme
    let segments: [DocReviewSegment]
    let decisions: [Int: DocReviewDecision]
    let personaName: String
    let busy: Bool
    let error: String?
    let onAcceptAll: () -> Void
    let onRejectAll: () -> Void
    let onDecide: (Int, DocReviewDecision) -> Void
    let onUndo: (Int) -> Void

    var body: some View {
        let p = theme.palette
        let changes = segments.compactMap { seg -> (id: Int, before: [String], after: [String])? in
            if case .change(let id, let b, let a) = seg { return (id, b, a) }
            return nil
        }
        let left = changes.filter { decisions[$0.id] == nil }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(personaName) suggested \(changes.count == 1 ? "1 change" : "\(changes.count) changes")")
                    .font(.system(size: 13, weight: .semibold))
                Text(left == changes.count ? "Accept or reject each change, or all at once." : "\(left) left to decide.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.secondaryText)
                HStack(spacing: 8) {
                    Button("Reject all", action: onRejectAll).buttonStyle(.vesper(.outline)).disabled(busy)
                    Button("Accept all", action: onAcceptAll).buttonStyle(.vesper(.primary)).disabled(busy)
                }
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
                ForEach(changes, id: \.id) { c in
                    let preview = c.after.isEmpty
                        ? "Removes \u{201C}\(String(DocEditorLogic.stripInlineMarkdown(c.before.joined(separator: " ")).prefix(60)))\u{201D}"
                        : "\u{201C}\(String(DocEditorLogic.stripInlineMarkdown(c.after.joined(separator: " ")).prefix(60)))\u{201D}"
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Change \(c.id + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.tertiaryText)
                        Text(preview).font(.system(size: 12)).foregroundStyle(p.text).lineLimit(3)
                        HStack(spacing: 6) {
                            if let d = decisions[c.id] {
                                Button("\(d == .accept ? "Accepted" : "Rejected") \u{00B7} Undo") { onUndo(c.id) }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 11))
                                    .disabled(busy)
                            } else {
                                Button("Reject") { onDecide(c.id, .reject) }.buttonStyle(.vesper(.outline)).disabled(busy)
                                Button("Accept") { onDecide(c.id, .accept) }.buttonStyle(.vesper(.primary)).disabled(busy)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
            }
            .padding(12)
        }
    }
}
