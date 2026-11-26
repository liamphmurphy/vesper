import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

// MARK: - Find Bridge

/// Bridges `NativeFindModel.searcher` (window-level `⌘F`) to `KnowledgeEditorView`'s unified
/// prose + table `KnowledgeEditorDocument.findMatches(query:caseSensitive:)`.
@MainActor
final class KnowledgeEditorFindBridge: FindTarget {
    var onFind: ((String, Bool, Bool) -> Bool)?
    var onClear: (() -> Void)?

    func find(_ query: String, backwards: Bool, caseSensitive: Bool) async -> Bool {
        onFind?(query, backwards, caseSensitive) ?? false
    }

    func clearFind() {
        onClear?()
    }
}

// MARK: - Heading Jump Request

struct KnowledgeHeadingJumpRequest: Equatable {
    let token: Int
    let pageId: String
    let heading: KnowledgeOutlineHeading
}

// MARK: - Knowledge Editor View

/// Pure SwiftUI live-preview Knowledge markdown editor orchestrating `KnowledgeEditorDocument`.
///
/// Renders interleaved prose (`KnowledgeTextView`) and embedded GFM tables (`MarkdownTableGridView`),
/// inline image/PDF embed previews, floating `[[` / `![[` / `#` completion popover, unified `⌘F`
/// find across prose and tables, unified Undo/Redo, Copy Selection, and dirty-gated Save/Autosave.
struct KnowledgeEditorView: View {
    private enum SaveStatus: Equatable {
        case saved
        case dirty
        case saving
        case error(String)
    }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    /// Hands the screen a way to save unsaved edits now (for Print), and nil when the editor leaves.
    typealias RegisterSave = (_ save: (@MainActor () async -> Void)?) -> Void

    let page: KnowledgePage
    var headingJumpRequest: KnowledgeHeadingJumpRequest?
    var onHeadingsChange: (([KnowledgeOutlineHeading]) -> Void)?
    var onRegisterSave: RegisterSave?
    var onMoveToPersonal: (() -> Void)?

    @State private var document: KnowledgeEditorDocument
    @State private var lastSavedMarkdown: String
    @State private var currentVersionId: String
    @State private var resolvedEmbeds: [KnowledgeEmbed]
    @State private var embedLayoutVersion = 0
    @State private var saveStatus: SaveStatus = .saved
    @State private var autosaveTask: Task<Void, Never>?

    @State private var completionSession = KnowledgeCompletionSession()
    @State private var completionSegmentIndex: Int?
    @State private var remoteCandidates: [KnowledgeCompletionCandidate] = []
    @State private var selectionRequest: KnowledgeTextSelectionRequest?
    @State private var selectionToken = 0
    @State private var activeSelectionSegment = 0
    @State private var activeSelectionRange = NSRange(location: 0, length: 0)
    @State private var showLinkPopover = false
    @State private var linkURLDraft = "https://"
    @State private var requestedTableFocus: (segmentIndex: Int, coord: TableCellCoordinate)?

    @State private var showFindBar = false
    @State private var findQuery = ""
    @State private var findCaseSensitive = false
    @State private var findMatches: [DocumentFindMatch] = []
    @State private var activeFindIndex: Int?
    @FocusState private var findFieldFocused: Bool
    @State private var findBridge = KnowledgeEditorFindBridge()

    init(
        page: KnowledgePage,
        headingJumpRequest: KnowledgeHeadingJumpRequest? = nil,
        onHeadingsChange: (([KnowledgeOutlineHeading]) -> Void)? = nil,
        onRegisterSave: RegisterSave? = nil,
        onMoveToPersonal: (() -> Void)? = nil
    ) {
        self.page = page
        self.headingJumpRequest = headingJumpRequest
        self.onHeadingsChange = onHeadingsChange
        self.onRegisterSave = onRegisterSave
        self.onMoveToPersonal = onMoveToPersonal
        let initial = page.bodyMd ?? ""
        _document = State(initialValue: KnowledgeEditorDocument(markdown: initial))
        _lastSavedMarkdown = State(initialValue: initial)
        _currentVersionId = State(initialValue: page.versionId)
        _resolvedEmbeds = State(initialValue: page.embeds)
    }

    private var hasUnsavedChanges: Bool {
        document.isDirty && document.serialize() != lastSavedMarkdown
    }

    private var activeFindMatch: DocumentFindMatch? {
        guard let idx = activeFindIndex, idx >= 0, idx < findMatches.count else { return nil }
        return findMatches[idx]
    }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            editorToolbar
            Divider().overlay(p.border)
            if showFindBar {
                KnowledgeEditorFindBar(
                    query: $findQuery,
                    caseSensitive: $findCaseSensitive,
                    focus: $findFieldFocused,
                    matchCount: findMatches.count,
                    activeMatchIndex: activeFindIndex,
                    onSubmit: {
                        _ = runFind(query: findQuery, backwards: context.currentEventModifiers.contains(.shift), caseSensitive: findCaseSensitive)
                    },
                    onQueryChange: { next in
                        _ = runFind(query: next, backwards: false, caseSensitive: findCaseSensitive)
                    },
                    onCaseChange: { next in
                        _ = runFind(query: findQuery, backwards: false, caseSensitive: next)
                    },
                    onPrevious: { _ = runFind(query: findQuery, backwards: true, caseSensitive: findCaseSensitive) },
                    onNext: { _ = runFind(query: findQuery, backwards: false, caseSensitive: findCaseSensitive) },
                    onClose: {
                        showFindBar = false
                        clearFind()
                    }
                )
                Divider().overlay(p.border)
            }
            ZStack(alignment: .bottomLeading) {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            pageHeader
                            segmentsColumn
                        }
                        .frame(maxWidth: 740, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .onChange(of: headingJumpRequest) { _, req in
                        guard let req, req.pageId == page.id else { return }
                        let heading = req.heading
                        withAnimation(.easeOut(duration: 0.18)) {
                            scrollProxy.scrollTo("editor-segment-\(heading.segmentIndex)", anchor: .top)
                        }
                        selectionToken += 1
                        selectionRequest = KnowledgeTextSelectionRequest(
                            token: selectionToken,
                            segmentIndex: heading.segmentIndex,
                            range: NSRange(location: heading.utf16Location, length: heading.utf16Length)
                        )
                    }
                }
                if completionSession.isOpen {
                    KnowledgeCompletionPopoverView(session: completionSession) { idx in
                        acceptCompletion(at: idx)
                    }
                    .padding(.leading, 28)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(p.background)
        .task(id: page.id) {
            await loadCompletionCandidates()
        }
        .onChange(of: page.embeds) { _, nextEmbeds in
            resolvedEmbeds = nextEmbeds
        }
        .onChange(of: page.versionId) { _, nextVersion in
            guard nextVersion != currentVersionId else { return }
            currentVersionId = nextVersion
            if !hasUnsavedChanges {
                let fresh = page.bodyMd ?? ""
                document = KnowledgeEditorDocument(markdown: fresh)
                lastSavedMarkdown = fresh
                saveStatus = .saved
                emitHeadings()
            }
        }
        .onAppear {
            emitHeadings()
            findBridge.onFind = { query, backwards, caseSensitive in
                showFindBar = true
                return runFind(query: query, backwards: backwards, caseSensitive: caseSensitive)
            }
            findBridge.onClear = { clearFind() }
            context.find.searcher = findBridge
            onRegisterSave?({ await saveNow() })
        }
        .onDisappear {
            onRegisterSave?(nil)
            autosaveTask?.cancel()
            if context.find.searcher === findBridge {
                context.find.searcher = nil
            }
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            Group {
                Button { performUndo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 12)).frame(width: 22, height: 22) }
                    .buttonStyle(.borderless)
                    .disabled(!document.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo (\u{2318}Z)")

                Button { performRedo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 12)).frame(width: 22, height: 22) }
                    .buttonStyle(.borderless)
                    .disabled(!document.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo (\u{21E7}\u{2318}Z)")

                Divider().frame(height: 14).overlay(p.border)

                fmtTextBtn("H1", help: "Title") { toggleLinePrefix("# ") }
                fmtTextBtn("H2", help: "Heading") { toggleLinePrefix("## ") }
                fmtTextBtn("H3", help: "Subheading") { toggleLinePrefix("### ") }

                Divider().frame(height: 14).overlay(p.border)

                fmtTextBtn("B", bold: true, help: "Bold (\u{2318}B)") { wrapSelection("**", "**") }
                    .keyboardShortcut("b", modifiers: .command)
                fmtTextBtn("I", italic: true, help: "Italic (\u{2318}I)") { wrapSelection("*", "*") }
                    .keyboardShortcut("i", modifiers: .command)
                fmtTextBtn("S", strike: true, help: "Strikethrough (\u{21E7}\u{2318}X)") { wrapSelection("~~", "~~") }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                fmtIconBtn("chevron.left.forwardslash.chevron.right", help: "Inline code (\u{2318}E)") { wrapSelection("`", "`") }
                    .keyboardShortcut("e", modifiers: .command)
                Button {
                    linkURLDraft = "https://"
                    showLinkPopover = true
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("k", modifiers: .command)
                .help("Insert link (\u{2318}K)")
                .popover(isPresented: $showLinkPopover) {
                    HStack(spacing: 6) {
                        TextField("https://\u{2026}", text: $linkURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit { applyLink() }
                        Button("Apply") { applyLink() }
                            .buttonStyle(.vesper(.primary))
                    }
                    .padding(10)
                }

                Divider().frame(height: 14).overlay(p.border)

                fmtIconBtn("list.bullet", help: "Bulleted list") { toggleLinePrefix("- ") }
                fmtIconBtn("list.number", help: "Numbered list") { toggleLinePrefix("1. ") }
                fmtIconBtn("checklist", help: "Checklist") { toggleLinePrefix("- [ ] ") }
                fmtIconBtn("text.quote", help: "Quote") { toggleLinePrefix("> ") }
                fmtIconBtn("curlybraces", help: "Code block") { insertBlock("\n```\n\n```\n") }
                fmtIconBtn("tablecells", help: "Insert table") {
                    insertBlock("\n| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |\n")
                }
                fmtIconBtn("minus", help: "Divider") { insertBlock("\n---\n") }
            }

            Spacer(minLength: 8)

            saveIndicator

            if page.audience == .agent, let onMoveToPersonal {
                Button {
                    onMoveToPersonal()
                } label: {
                    Label("Move to Personal", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.vesper(.outline))
                .controlSize(.small)
                .help("Move this persona-created page into your personal Knowledge")
            }

            Menu {
                Button("Export Markdown (.md)") { exportMarkdown() }
                Button("Export Word (.docx)") { exportDocx() }
                Button("Copy Rich Text") { copyRichText() }
                Divider()
                Button("Copy Selection as Markdown") { copySelectionAsMarkdown() }
                    .disabled(document.selection?.isCollapsed ?? true)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export or copy")

            Button {
                showFindBar.toggle()
                if showFindBar { findFieldFocused = true } else { clearFind() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in Page (\u{2318}F)")

            Button("Save") { Task { await saveNow() } }
                .buttonStyle(.vesper(hasUnsavedChanges ? .primary : .outline))
                .disabled(!hasUnsavedChanges || saveStatus == .saving)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(p.surface)
    }

    private func fmtIconBtn(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func fmtTextBtn(
        _ label: String,
        bold: Bool = false,
        italic: Bool = false,
        strike: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: bold ? .bold : .semibold))
                .italic(italic)
                .strikethrough(strike)
                .frame(minWidth: 22, minHeight: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    @ViewBuilder
    private var saveIndicator: some View {
        let p = theme.palette
        HStack(spacing: 6) {
            switch saveStatus {
            case .saved:
                Circle().fill(theme.swiftUIColor("pill-done-fg", fallback: .green)).frame(width: 6, height: 6)
                Text("Saved").vesperText(.small, theme).foregroundStyle(p.tertiaryText)
            case .dirty:
                Circle().fill(p.accent).frame(width: 6, height: 6)
                Text("Unsaved changes").vesperText(.small, theme).foregroundStyle(p.secondaryText)
            case .saving:
                ProgressView().controlSize(.mini)
                Text("Saving\u{2026}").vesperText(.small, theme).foregroundStyle(p.secondaryText)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                Text(msg).vesperText(.small, theme).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red)).lineLimit(1)
            }
        }
    }

    // MARK: - Page Header & Interleaved Segments

    private var linkedSpacesForPage: [API.ChatSpace] {
        guard let pagePath = page.path, !pagePath.isEmpty else { return [] }
        let spaces = context.store.entry(API.listChatSpaces()).data?.spaces ?? []
        return spaces.filter { sp in
            guard (sp.knowledgeCount ?? 0) > 0 else { return false }
            let links = sp.knowledgeLinks ?? context.store.entry(API.listChatSpaceKnowledgeLinks(spaceId: sp.id)).data?.links ?? []
            return links.contains { link in
                if link.kind == .folder {
                    return pagePath == link.path || pagePath.hasPrefix(link.path + "/")
                }
                return pagePath == link.path
            }
        }
    }

    private var pageHeader: some View {
        let p = theme.palette
        let matchedSpaces = linkedSpacesForPage
        return VStack(alignment: .leading, spacing: 4) {
            if (page.path != nil && !(page.path ?? "").isEmpty) || !matchedSpaces.isEmpty {
                HStack(spacing: 8) {
                    if let path = page.path, !path.isEmpty {
                        Text(path)
                            .font(.system(size: theme.pointSize(.micro) + 1))
                            .foregroundStyle(p.tertiaryText)
                    }
                    ForEach(matchedSpaces, id: \.id) { sp in
                        Button {
                            context.navigate("/spaces/\(sp.id)")
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(cssHex: SpacesLogic.colorHex(for: sp.color)) ?? .green)
                                    .frame(width: 6, height: 6)
                                Text(sp.name)
                                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                    .foregroundStyle(p.secondaryText)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(p.surface, in: Capsule())
                            .overlay(Capsule().stroke(p.border))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(sp.name) Space")
                    }
                }
            }
            Text(page.title.isEmpty ? "Untitled" : page.title)
                .vesperText(.display, theme)
                .foregroundStyle(p.text)
        }
        .task(id: page.id) {
            let spacesReq = API.listChatSpaces()
            context.store.load(spacesReq)
            if let spaces = context.store.entry(spacesReq).data?.spaces {
                for sp in spaces where (sp.knowledgeCount ?? 0) > 0 && sp.knowledgeLinks == nil {
                    context.store.load(API.listChatSpaceKnowledgeLinks(spaceId: sp.id))
                }
            }
        }
    }

    private var segmentsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.segments.enumerated()), id: \.element.id) { index, segment in
                switch segment {
                case .prose(let prose):
                    proseSegmentView(prose: prose, index: index)
                        .id("editor-segment-\(index)")
                case .table(let table):
                    tableSegmentView(table: table, index: index)
                        .id("editor-segment-\(index)")
                }
            }
        }
    }

    @ViewBuilder
    private func proseSegmentView(prose: KnowledgeProseSegment, index: Int) -> some View {
        KnowledgeTextView(
            text: prose.text,
            theme: theme,
            embeds: resolvedEmbeds,
            embedLayoutVersion: embedLayoutVersion,
            isCompletionOpen: completionSession.isOpen && completionSegmentIndex == index,
            findMatches: proseMatchRanges(forSegment: index),
            activeFindMatchRange: activeProseMatchRange(forSegment: index),
            selectionRequest: selectionRequest,
            segmentIndex: index,
            onTextChange: { updated, range in handleProseEdit(updated, selection: range, at: index) },
            onSelectionChange: { range, isFocused in handleProseSelection(range, isFocused: isFocused, at: index) },
            onOpenLink: { target in openWikiLink(target) },
            onCompletionKey: { action in handleCompletionKey(action) },
            onEmbedLayoutChange: { embedLayoutVersion &+= 1 }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableSegmentView(table: MarkdownTableModel, index: Int) -> some View {
        let tableMatches = findMatches.filter { $0.isInTable && $0.position.segmentIndex == index }
        let requested = (requestedTableFocus?.segmentIndex == index) ? requestedTableFocus?.coord : nil
        return MarkdownTableGridView(
            table: table,
            segmentIndex: index,
            requestedFocusCell: requested,
            findMatches: tableMatches,
            activeFindMatch: activeFindMatch,
            onEditCell: { row, col, text in
                if document.editTableCell(at: index, row: row, column: col, text: text) { noteDocumentEdited() }
            },
            onNavigateTab: { coord, backwards in
                let beforeDirty = document.isDirty
                let next = document.navigateTableTab(at: index, from: coord, backwards: backwards)
                if document.isDirty != beforeDirty || document.serialize() != lastSavedMarkdown { noteDocumentEdited() }
                return next
            },
            onAddRow: { bodyIndex in
                let changed = document.editTable(at: index, description: "Add row") { $0.addRow(at: bodyIndex) }
                if changed { noteDocumentEdited() }
            },
            onRemoveRow: { bodyIndex in
                let changed = document.editTable(at: index, description: "Remove row") { _ = $0.removeRow(at: bodyIndex) }
                if changed { noteDocumentEdited() }
            },
            onAddColumn: { colIndex in
                let changed = document.editTable(at: index, description: "Add column") { $0.addColumn(at: colIndex) }
                if changed { noteDocumentEdited() }
            },
            onRemoveColumn: { colIndex in
                let changed = document.editTable(at: index, description: "Remove column") { _ = $0.removeColumn(at: colIndex) }
                if changed { noteDocumentEdited() }
            },
            onCycleAlignment: { colIndex in
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
                if changed { noteDocumentEdited() }
            },
            onResizeColumn: { colIndex, width in
                _ = document.editTable(at: index, description: "Resize column") { $0.resizeColumn(at: colIndex, width: width) }
            },
            onToggleRawMode: { rawMode in
                _ = document.editTable(at: index, description: "Toggle Markdown table") { $0.isEditingRawMarkdown = rawMode }
            },
            onApplyRawMarkdown: { raw in
                let ok = document.applyRawTableMarkdown(raw, at: index)
                if ok { noteDocumentEdited() }
                return ok
            },
            onFocusCell: { coord in
                document.selection = DocumentSelection(collapsedAt: .tableCell(
                    segmentIndex: index, row: coord.row, column: coord.column, utf16Offset: 0
                ))
            }
        )
    }

    // MARK: - Editing, Completion, Undo/Redo, Find, Save & Links

    private func handleProseEdit(_ newText: String, selection: NSRange, at segmentIndex: Int) {
        activeSelectionSegment = segmentIndex
        activeSelectionRange = selection
        let docSel = documentSelection(for: selection, in: segmentIndex)
        if document.setProse(newText, in: segmentIndex, newSelection: docSel) { noteDocumentEdited() }
        updateCompletion(text: newText, selection: selection, segmentIndex: segmentIndex)
    }

    private func handleProseSelection(_ selection: NSRange, isFocused: Bool, at segmentIndex: Int) {
        activeSelectionSegment = segmentIndex
        activeSelectionRange = selection
        document.selection = documentSelection(for: selection, in: segmentIndex)
        if isFocused, let prose = document.proseText(at: segmentIndex) {
            updateCompletion(text: prose, selection: selection, segmentIndex: segmentIndex)
        } else if completionSegmentIndex == segmentIndex {
            completionSession.close()
        }
    }

    // MARK: - Formatting & Export Actions

    private func applyProseTransform(_ transform: (String, NSRange) -> KnowledgeMarkdownFormatting.EditResult) {
        let idx = min(activeSelectionSegment, max(0, document.segments.count - 1))
        guard let text = document.proseText(at: idx) else { return }
        let res = transform(text, activeSelectionRange)
        let docSel = documentSelection(for: res.selection, in: idx)
        if document.setProse(res.text, in: idx, newSelection: docSel) {
            noteDocumentEdited()
        }
        activeSelectionSegment = idx
        activeSelectionRange = res.selection
        selectionToken += 1
        selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: idx, range: res.selection)
    }

    private func wrapSelection(_ prefix: String, _ suffix: String) {
        applyProseTransform { text, range in
            KnowledgeMarkdownFormatting.wrapOrToggle(text: text, selection: range, prefix: prefix, suffix: suffix)
        }
    }

    private func toggleLinePrefix(_ prefix: String) {
        applyProseTransform { text, range in
            KnowledgeMarkdownFormatting.toggleLinePrefix(text: text, selection: range, prefix: prefix)
        }
    }

    private func insertBlock(_ block: String) {
        let idx = min(activeSelectionSegment, max(0, document.segments.count - 1))
        guard document.proseText(at: idx) != nil else {
            document = KnowledgeEditorDocument(markdown: document.serialize() + block)
            noteDocumentEdited()
            return
        }
        applyProseTransform { text, range in
            KnowledgeMarkdownFormatting.insertBlock(text: text, selection: range, block: block)
        }
    }

    private func applyLink() {
        let href = linkURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        showLinkPopover = false
        guard !href.isEmpty else { return }
        applyProseTransform { text, range in
            KnowledgeMarkdownFormatting.applyLink(text: text, selection: range, url: href)
        }
    }

    private func exportMarkdown() {
        let data = Data(document.serialize().utf8)
        saveExportPanel(data: data, defaultName: DocEditorLogic.sanitizedFileName(page.title, ext: "md"), contentType: UTType(filenameExtension: "md") ?? .plainText)
    }

    private func exportDocx() {
        let data = DocEditorLogic.exportDocx(markdown: document.serialize(), title: page.title)
        saveExportPanel(data: data, defaultName: DocEditorLogic.sanitizedFileName(page.title, ext: "docx"), contentType: UTType(filenameExtension: "docx") ?? .data)
    }

    private func copyRichText() {
        let html = DocEditorLogic.renderHTML(markdown: document.serialize(), title: page.title)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(document.serialize(), forType: .string)
        context.showToast(ToastItemModel(id: "knowledge.copy.rich", title: "Copied rich text", tone: .success))
    }

    private func saveExportPanel(data: Data, defaultName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                context.showToast(ToastItemModel(id: "knowledge.export.ok", title: "Saved \(url.lastPathComponent)", tone: .success))
            } catch {
                context.showToast(ToastItemModel(id: "knowledge.export.err", title: "Export failed: \(error.localizedDescription)", tone: .error))
            }
        }
    }

    private func documentSelection(for range: NSRange, in segmentIndex: Int) -> DocumentSelection {
        DocumentSelection(
            anchor: .prose(segmentIndex: segmentIndex, utf16Offset: range.location),
            focus: .prose(segmentIndex: segmentIndex, utf16Offset: range.location + range.length)
        )
    }

    private func updateCompletion(text: String, selection: NSRange, segmentIndex: Int) {
        guard selection.length == 0 else {
            completionSession.close()
            return
        }
        completionSegmentIndex = segmentIndex
        let combined = remoteCandidates + currentDocumentCandidates()
        completionSession.update(text: text, caretUTF16: selection.location, allCandidates: combined, limit: 20)
    }

    private func handleCompletionKey(_ action: KnowledgeTextKeyAction) -> Bool {
        guard completionSession.isOpen else { return false }
        switch action {
        case .moveUp:
            completionSession.moveSelection(delta: -1)
            return true
        case .moveDown:
            completionSession.moveSelection(delta: 1)
            return true
        case .dismiss:
            completionSession.dismiss()
            return true
        case .accept:
            guard let insertion = completionSession.acceptActive() else { return false }
            applyCompletionInsertion(insertion)
            return true
        }
    }

    private func acceptCompletion(at index: Int) {
        guard let trigger = completionSession.trigger,
              index >= 0, index < completionSession.candidates.count else { return }
        let insertion = KnowledgeCompletionLogic.insertion(for: completionSession.candidates[index], trigger: trigger)
        completionSession.close()
        applyCompletionInsertion(insertion)
    }

    private func applyCompletionInsertion(_ insertion: KnowledgeCompletionInsertion) {
        guard let segIdx = completionSegmentIndex else { return }
        let newCaret = NSRange(location: insertion.newCaretUTF16, length: 0)
        let newSel = DocumentSelection(collapsedAt: .prose(segmentIndex: segIdx, utf16Offset: insertion.newCaretUTF16))
        if document.replaceProse(in: segIdx, range: insertion.replacementRange, with: insertion.insertedText, newSelection: newSel) {
            noteDocumentEdited()
            selectionToken += 1
            selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: segIdx, range: newCaret)
        }
    }

    private func currentDocumentCandidates() -> [KnowledgeCompletionCandidate] {
        let md = document.serialize()
        let ns = md as NSString
        var out: [KnowledgeCompletionCandidate] = []
        var seenHeadings = Set<String>()
        var seenBlocks = Set<String>()
        for token in KnowledgeMarkdownSyntax.scan(md) {
            switch token.kind {
            case .heading(let level):
                guard token.contentRange.location + token.contentRange.length <= ns.length else { continue }
                let text = ns.substring(with: token.contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, seenHeadings.insert(text.lowercased()).inserted {
                    out.append(KnowledgeCompletionCandidate(kind: .heading, title: text, insertRef: text, detail: "H\(level)"))
                }
            case .blockID(let id):
                if !id.isEmpty, seenBlocks.insert(id.lowercased()).inserted {
                    out.append(KnowledgeCompletionCandidate(kind: .blockID, title: "^\(id)", insertRef: id, detail: "Block ID"))
                }
            default:
                continue
            }
        }
        return out
    }

    private func loadCompletionCandidates() async {
        guard let client = context.store.client else { return }
        var candidates: [KnowledgeCompletionCandidate] = []
        var seenTags = Set<String>()

        if let table = try? await client.send(KnowledgeAPI.listPages(includeAgent: true, limit: 200)) {
            for row in table.rows {
                let ref = row.path.isEmpty ? row.title : row.path
                let title = row.title.isEmpty ? ref : row.title
                candidates.append(KnowledgeCompletionCandidate(kind: .page, title: title, insertRef: ref, detail: row.path))
                if case .array(let tags) = row.properties["tags"] {
                    for val in tags {
                        if let raw = val.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !raw.isEmpty, seenTags.insert(raw.lowercased()).inserted {
                            candidates.append(KnowledgeCompletionCandidate(kind: .tag, title: "#\(raw)", insertRef: raw, detail: "Tag"))
                        }
                    }
                }
            }
        }

        if let assets = try? await client.send(KnowledgeAPI.listAssets()) {
            for asset in assets.images {
                candidates.append(KnowledgeCompletionCandidate(
                    kind: .embed,
                    title: asset.title.isEmpty ? asset.ref : asset.title,
                    insertRef: asset.ref,
                    detail: asset.contentType
                ))
            }
        }
        remoteCandidates = candidates
    }

    private func performUndo() {
        guard document.undo() else { return }
        refreshFindAfterEdit()
        syncDirtyStateAfterHistoryChange()
    }

    private func performRedo() {
        guard document.redo() else { return }
        refreshFindAfterEdit()
        syncDirtyStateAfterHistoryChange()
    }

    private func syncDirtyStateAfterHistoryChange() {
        if hasUnsavedChanges {
            saveStatus = .dirty
            scheduleAutosave()
        } else {
            autosaveTask?.cancel()
            saveStatus = .saved
        }
    }

    private func copySelectionAsMarkdown() {
        guard let sel = document.selection, !sel.isCollapsed else { return }
        let md = document.selectedMarkdown(for: sel)
        guard !md.isEmpty else { return }
        context.copyToClipboard(md)
        context.showToast(ToastItemModel(id: "knowledge.copy.selection", title: "Copied Markdown selection", tone: .success))
    }

    @discardableResult
    private func runFind(query: String, backwards: Bool, caseSensitive: Bool) -> Bool {
        let queryChanged = query != findQuery || caseSensitive != findCaseSensitive
        findQuery = query
        findCaseSensitive = caseSensitive
        findMatches = document.findMatches(query: query, caseSensitive: caseSensitive)

        guard !findMatches.isEmpty else {
            activeFindIndex = nil
            return false
        }
        let nextIndex: Int
        if queryChanged || activeFindIndex == nil {
            nextIndex = backwards ? findMatches.count - 1 : 0
        } else {
            let cur = activeFindIndex ?? 0
            nextIndex = (backwards ? cur - 1 + findMatches.count : cur + 1) % findMatches.count
        }
        activeFindIndex = nextIndex
        switch findMatches[nextIndex].position {
        case .prose(let segIdx, _):
            selectionToken += 1
            selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: segIdx, range: findMatches[nextIndex].range)
        case .tableCell(let segIdx, let row, let col, _):
            requestedTableFocus = (segIdx, TableCellCoordinate(row: row, column: col))
        }
        return true
    }

    private func refreshFindAfterEdit() {
        guard showFindBar, !findQuery.isEmpty else { return }
        findMatches = document.findMatches(query: findQuery, caseSensitive: findCaseSensitive)
        activeFindIndex = findMatches.isEmpty ? nil : activeFindIndex.map { min($0, findMatches.count - 1) }
    }

    private func clearFind() {
        findQuery = ""
        findMatches = []
        activeFindIndex = nil
    }

    private func proseMatchRanges(forSegment index: Int) -> [NSRange] {
        findMatches.compactMap { !$0.isInTable && $0.position.segmentIndex == index ? $0.range : nil }
    }

    private func activeProseMatchRange(forSegment index: Int) -> NSRange? {
        guard let active = activeFindMatch, !active.isInTable, active.position.segmentIndex == index else { return nil }
        return active.range
    }

    private func emitHeadings() {
        onHeadingsChange?(KnowledgeInspectorLogic.extractHeadings(from: document.segments))
    }

    private func noteDocumentEdited() {
        refreshFindAfterEdit()
        emitHeadings()
        guard hasUnsavedChanges else {
            saveStatus = .saved
            return
        }
        saveStatus = .dirty
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    private func saveNow() async {
        guard document.isDirty else { return }
        autosaveTask?.cancel()
        let serialized = document.serialize()
        guard serialized != lastSavedMarkdown else {
            saveStatus = .saved
            return
        }
        saveStatus = .saving
        do {
            let updated = try await context.store.mutate(
                KnowledgeAPI.updatePage(
                    id: page.id,
                    body: KnowledgePageInput(bodyMd: serialized, baseVersionId: currentVersionId)
                ),
                invalidating: KnowledgeAPI.invalidation
            )
            lastSavedMarkdown = serialized
            currentVersionId = updated.versionId
            resolvedEmbeds = updated.embeds
            saveStatus = .saved
        } catch {
            saveStatus = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func openWikiLink(_ target: KnowledgeWikiTarget) {
        guard let client = context.store.client else { return }
        Task {
            do {
                let response = try await client.send(API.resolveLinks(ref: [target.ref]))
                guard let first = response.links.first else { return }
                switch MarkdownLinkState(first.target) {
                case .resolved(let href, _):
                    context.navigate(href)
                case .unresolved:
                    context.showToast(ToastItemModel(
                        id: "knowledge.link.unresolved",
                        title: "Linked page isn\u{2019}t available",
                        description: target.displayLabel(),
                        tone: .error
                    ))
                }
            } catch {
                context.showToast(ToastItemModel(
                    id: "knowledge.link.err",
                    title: "Couldn\u{2019}t open link",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }
}
