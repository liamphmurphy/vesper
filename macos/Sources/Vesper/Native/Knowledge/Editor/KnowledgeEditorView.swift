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

    private struct LinksRefreshKey: Equatable {
        var pageId: String
        var title: String
        var aliases: JSONValue?
        var networkUpdatedAt: Date?
        var mentionsUpdatedAt: Date?
    }

    /// Non-observable box for hot-path caret tracking so arrow-key navigation and typing don't
    /// trigger SwiftUI view invalidations for state that `body` never reads.
    @MainActor
    private final class LiveSelectionState {
        var segmentIndex = 0
        var range = NSRange(location: 0, length: 0)
    }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// Hands the screen a way to save unsaved edits now (for Print), and nil when the editor leaves.
    typealias RegisterSave = (_ save: (@MainActor () async -> Void)?) -> Void

    let page: KnowledgePage
    var headingJumpRequest: KnowledgeHeadingJumpRequest?
    var onHeadingsChange: (([KnowledgeOutlineHeading]) -> Void)?
    var onRegisterSave: RegisterSave?
    var onMoveToPersonal: (() -> Void)?
    var onSelectedEmbedChange: ((KnowledgeEmbed?, [KnowledgeEmbed]) -> Void)?

    @State private var document: KnowledgeEditorDocument
    @State private var lastSavedMarkdown: String
    @State private var currentVersionId: String
    @State private var resolvedEmbeds: [KnowledgeEmbed]
    @State private var embedLayoutVersion = 0
    @State private var saveStatus: SaveStatus = .saved
    @State private var hasUnsavedChanges = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var headingsDebounceTask: Task<Void, Never>?

    @State private var cachedHeadings: [KnowledgeOutlineHeading]
    @State private var cachedBacklinks: [KnowledgeBacklinkItem] = []
    @State private var cachedOutgoingLinks: (resolved: [KnowledgeBacklinkItem], unresolved: [String]) = ([], [])
    @State private var cachedUnlinkedMentions: [KnowledgeUnlinkedMention] = []

    @State private var completionSession = KnowledgeCompletionSession()
    @State private var completionSegmentIndex: Int?
    @State private var remoteCandidates: [KnowledgeCompletionCandidate] = []
    @State private var selectionRequest: KnowledgeTextSelectionRequest?
    @State private var selectionToken = 0
    @State private var liveSelection = LiveSelectionState()
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
    @State private var isFileDropTargeted = false
    @State private var draggedKnowledgeItem: KnowledgeDragItem?
    @State private var uploadingFileCount = 0
    @State private var selectedEmbedID: String?
    @State private var selectedEmbedSegmentIndex: Int?
    @State private var embedKeyMonitor: Any?
    @State private var removedEmbedCache: [KnowledgeEmbed] = []
    @State private var deletingAttachment: KnowledgeAttachment?
    @State private var inlineDrawerMode: KnowledgeInlineDrawerMode?
    @State private var localHeadingJumpRequest: KnowledgeHeadingJumpRequest?
    @State private var localHeadingJumpToken = 0
    @State private var linkingMentionId: String?

    init(
        page: KnowledgePage,
        headingJumpRequest: KnowledgeHeadingJumpRequest? = nil,
        onHeadingsChange: (([KnowledgeOutlineHeading]) -> Void)? = nil,
        onRegisterSave: RegisterSave? = nil,
        onMoveToPersonal: (() -> Void)? = nil,
        onSelectedEmbedChange: ((KnowledgeEmbed?, [KnowledgeEmbed]) -> Void)? = nil
    ) {
        self.page = page
        self.headingJumpRequest = headingJumpRequest
        self.onHeadingsChange = onHeadingsChange
        self.onRegisterSave = onRegisterSave
        self.onMoveToPersonal = onMoveToPersonal
        self.onSelectedEmbedChange = onSelectedEmbedChange
        let initial = page.bodyMd ?? ""
        let initialDoc = KnowledgeEditorDocument(markdown: initial)
        _document = State(initialValue: initialDoc)
        _cachedHeadings = State(initialValue: KnowledgeInspectorLogic.extractHeadings(from: initialDoc.segments))
        _lastSavedMarkdown = State(initialValue: initial)
        _currentVersionId = State(initialValue: page.versionId)
        _resolvedEmbeds = State(initialValue: page.embeds)
    }

    private var networkRequest: APIRequest<KnowledgeNetwork> {
        KnowledgeAPI.getNetwork(includeAgent: page.audience == .agent)
    }

    private var mentionCandidatesRequest: APIRequest<KnowledgePageTable> {
        KnowledgeAPI.listPages(includeAgent: page.audience == .agent, limit: 200)
    }

    private var activeFindMatch: DocumentFindMatch? {
        guard let idx = activeFindIndex, idx >= 0, idx < findMatches.count else { return nil }
        return findMatches[idx]
    }

    var body: some View {
        let p = theme.palette
        let linksRefreshKey = LinksRefreshKey(
            pageId: page.id,
            title: page.title,
            aliases: page.properties["aliases"],
            networkUpdatedAt: context.store.entry(networkRequest).updatedAt,
            mentionsUpdatedAt: context.store.entry(mentionCandidatesRequest).updatedAt
        )
        VStack(spacing: 0) {
            editorToolbar
                .zIndex(20)
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
            HStack(spacing: 0) {
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
                            jumpToHeading(req.heading, scrollProxy: scrollProxy)
                        }
                        .onChange(of: localHeadingJumpRequest) { _, req in
                            guard let req, req.pageId == page.id else { return }
                            jumpToHeading(req.heading, scrollProxy: scrollProxy)
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

                    if isFileDropTargeted || draggedKnowledgeItem != nil {
                        dropOverlay
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [.fileURL, .utf8PlainText], isTargeted: $isFileDropTargeted) { providers in
                    handleEditorPaneDrop(providers)
                }

                if inlineDrawerMode != nil {
                    Divider().overlay(p.border)
                    KnowledgeInlineDrawerView(
                        page: page,
                        mode: $inlineDrawerMode,
                        headings: cachedHeadings,
                        backlinks: cachedBacklinks,
                        outgoingResolved: cachedOutgoingLinks.resolved,
                        outgoingUnresolved: cachedOutgoingLinks.unresolved,
                        unlinkedMentions: cachedUnlinkedMentions,
                        onJumpHeading: { heading in
                            localHeadingJumpToken += 1
                            localHeadingJumpRequest = KnowledgeHeadingJumpRequest(
                                token: localHeadingJumpToken,
                                pageId: page.id,
                                heading: heading
                            )
                        },
                        onLinkMention: { mention in
                            linkUnlinkedMention(mention)
                        },
                        linkingMentionId: linkingMentionId
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(p.background)
        .onChange(of: linksRefreshKey, initial: true) { _, _ in
            refreshDerivedLinksAndMentions()
        }
        .task(id: page.id) {
            context.store.load(networkRequest)
            context.store.load(mentionCandidatesRequest)
            context.store.load(KnowledgeShellController.attachmentsRequest)
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
                hasUnsavedChanges = false
                saveStatus = .saved
                emitHeadings(immediately: true)
            }
        }
        .onAppear {
            emitHeadings(immediately: true)
            findBridge.onFind = { query, backwards, caseSensitive in
                showFindBar = true
                return runFind(query: query, backwards: backwards, caseSensitive: caseSensitive)
            }
            findBridge.onClear = { clearFind() }
            context.find.searcher = findBridge
            onRegisterSave?({ await saveNow() })
        }
        .onDisappear {
            removeEmbedKeyMonitor()
            onRegisterSave?(nil)
            onSelectedEmbedChange?(nil, [])
            autosaveTask?.cancel()
            headingsDebounceTask?.cancel()
            if context.find.searcher === findBridge {
                context.find.searcher = nil
            }
        }
        .onChange(of: selectedEmbedID) { _, next in
            syncEmbedKeyMonitor(active: next != nil)
        }
        .sheet(item: $deletingAttachment) { attachment in
            KnowledgeDeleteSheet(target: .attachment(attachment)) {
                try await deleteInlineAttachment(attachment)
            }
            .environment(context)
            .environment(\.vesperTheme, theme)
            .environment(\.colorScheme, colorScheme)
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        let p = theme.palette
        return HStack(spacing: 4) {
            Group {
                Button { performUndo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 12)).frame(width: 24, height: 24) }
                    .buttonStyle(.borderless)
                    .disabled(!document.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .knowledgeToolbarTooltip("Undo", hint: "\u{2318}Z", alignment: .bottomLeading)

                Button { performRedo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 12)).frame(width: 24, height: 24) }
                    .buttonStyle(.borderless)
                    .disabled(!document.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .knowledgeToolbarTooltip("Redo", hint: "\u{21E7}\u{2318}Z", alignment: .bottomLeading)

                Divider().frame(height: 14).overlay(p.border).padding(.horizontal, 2)

                fmtTextBtn("H1", title: "Heading 1", hint: "#") { toggleLinePrefix("# ") }
                fmtTextBtn("H2", title: "Heading 2", hint: "##") { toggleLinePrefix("## ") }
                fmtTextBtn("H3", title: "Heading 3", hint: "###") { toggleLinePrefix("### ") }

                Divider().frame(height: 14).overlay(p.border).padding(.horizontal, 2)

                fmtTextBtn("B", bold: true, title: "Bold", hint: "\u{2318}B") { wrapSelection("**", "**") }
                    .keyboardShortcut("b", modifiers: .command)
                fmtTextBtn("I", italic: true, title: "Italic", hint: "\u{2318}I") { wrapSelection("*", "*") }
                    .keyboardShortcut("i", modifiers: .command)
                fmtTextBtn("S", strike: true, title: "Strikethrough", hint: "\u{21E7}\u{2318}X") { wrapSelection("~~", "~~") }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                fmtIconBtn("chevron.left.forwardslash.chevron.right", title: "Inline code", hint: "\u{2318}E") { wrapSelection("`", "`") }
                    .keyboardShortcut("e", modifiers: .command)
                Button {
                    linkURLDraft = "https://"
                    showLinkPopover = true
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("k", modifiers: [.command, .option])
                .knowledgeToolbarTooltip("Insert link", hint: "\u{2325}\u{2318}K")
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

                Divider().frame(height: 14).overlay(p.border).padding(.horizontal, 2)

                fmtIconBtn("list.bullet", title: "Bulleted list", hint: "-") { toggleLinePrefix("- ") }
                fmtIconBtn("list.number", title: "Numbered list", hint: "1.") { toggleLinePrefix("1. ") }
                fmtIconBtn("checklist", title: "Checklist", hint: "- [ ]") { toggleLinePrefix("- [ ] ") }
                fmtIconBtn("text.quote", title: "Quote", hint: ">") { toggleLinePrefix("> ") }
                fmtIconBtn("curlybraces", title: "Code block", hint: "```") { insertBlock("\n```\n\n```\n") }
                fmtIconBtn("tablecells", title: "Insert table") {
                    insertBlock("\n| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |\n")
                }
                fmtIconBtn("minus", title: "Divider", hint: "---") { insertBlock("\n---\n") }
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
                .knowledgeToolbarTooltip("Move to Personal", hint: "Yours", alignment: .bottomTrailing, highlightHover: false)
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
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .knowledgeToolbarTooltip("Export or copy", alignment: .bottomTrailing)

            let headingCount = cachedHeadings.count
            let linksBadgeCount = cachedBacklinks.count + cachedUnlinkedMentions.count

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    inlineDrawerMode = inlineDrawerMode == .outline ? nil : .outline
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 11.5))
                    if headingCount > 0 {
                        Text("\(headingCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(inlineDrawerMode == .outline ? p.accent : p.secondaryText)
                .padding(.horizontal, 5)
                .frame(height: 24)
                .background(
                    inlineDrawerMode == .outline ? theme.swiftUIColor("accent-soft", fallback: p.selected) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("o", modifiers: [.command, .option])
            .knowledgeToolbarTooltip("Heading Outline (TOC)", hint: "\u{2325}\u{2318}O", alignment: .bottomTrailing)

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    inlineDrawerMode = inlineDrawerMode == .backlinks ? nil : .backlinks
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11.5))
                    if linksBadgeCount > 0 {
                        Text("\(linksBadgeCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(inlineDrawerMode == .backlinks ? p.accent : p.secondaryText)
                .padding(.horizontal, 5)
                .frame(height: 24)
                .background(
                    inlineDrawerMode == .backlinks ? theme.swiftUIColor("accent-soft", fallback: p.selected) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("b", modifiers: [.command, .option])
            .knowledgeToolbarTooltip("Backlinks & Unlinked Mentions", hint: "\u{2325}\u{2318}B", alignment: .bottomTrailing)

            Divider().frame(height: 14).overlay(p.border).padding(.horizontal, 2)

            Button {
                showFindBar.toggle()
                if showFindBar { findFieldFocused = true } else { clearFind() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .knowledgeToolbarTooltip("Find in Page", hint: "\u{2318}F", alignment: .bottomTrailing)

            Button("Save") { Task { await saveNow() } }
                .buttonStyle(.vesper(hasUnsavedChanges ? .primary : .outline))
                .disabled(!hasUnsavedChanges || saveStatus == .saving)
                .keyboardShortcut("s", modifiers: .command)
                .knowledgeToolbarTooltip("Save changes", hint: "\u{2318}S", alignment: .bottomTrailing, highlightHover: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(p.surface)
    }

    private func fmtIconBtn(_ symbol: String, title: String, hint: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .knowledgeToolbarTooltip(title, hint: hint)
    }

    private func fmtTextBtn(
        _ label: String,
        bold: Bool = false,
        italic: Bool = false,
        strike: Bool = false,
        title: String,
        hint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: bold ? .bold : .semibold))
                .italic(italic)
                .strikethrough(strike)
                .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.borderless)
        .knowledgeToolbarTooltip(title, hint: hint)
    }

    @ViewBuilder
    private var saveIndicator: some View {
        let p = theme.palette
        HStack(spacing: 6) {
            if uploadingFileCount > 0 {
                ProgressView().controlSize(.mini)
                Text(uploadingFileCount == 1 ? "Attaching file\u{2026}" : "Attaching \(uploadingFileCount) files\u{2026}")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.accent)
            } else {
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
        let backlinksCount = cachedBacklinks.count
        let mentionsCount = cachedUnlinkedMentions.count
        return VStack(alignment: .leading, spacing: 4) {
            if (page.path != nil && !(page.path ?? "").isEmpty) || !matchedSpaces.isEmpty || backlinksCount > 0 || mentionsCount > 0 {
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
                    if backlinksCount > 0 || mentionsCount > 0 {
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                inlineDrawerMode = inlineDrawerMode == .backlinks ? nil : .backlinks
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(p.accent)
                                Text(backlinksPillLabel(backlinks: backlinksCount, mentions: mentionsCount))
                                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                    .foregroundStyle(p.secondaryText)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                inlineDrawerMode == .backlinks ? theme.swiftUIColor("accent-soft", fallback: p.selected) : p.surface,
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(inlineDrawerMode == .backlinks ? p.accent : p.border))
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Backlinks & Unlinked Mentions")
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

    private func backlinksPillLabel(backlinks: Int, mentions: Int) -> String {
        var parts: [String] = []
        if backlinks > 0 {
            parts.append("\(backlinks) \(backlinks == 1 ? "backlink" : "backlinks")")
        }
        if mentions > 0 {
            parts.append("\(mentions) unlinked")
        }
        return parts.joined(separator: " \u{00B7} ")
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

    private var deletableEmbedURLs: Set<String> {
        guard !resolvedEmbeds.isEmpty else { return [] }
        let attachments = context.store.entry(KnowledgeShellController.attachmentsRequest).data?.attachments ?? []
        return Set(attachments.filter(\.isOwner).map(\.url))
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
            selectedEmbedID: selectedEmbedSegmentIndex == index ? selectedEmbedID : nil,
            deletableEmbedURLs: deletableEmbedURLs,
            onTextChange: { updated, range in handleProseEdit(updated, selection: range, at: index) },
            onSelectionChange: { range, isFocused in handleProseSelection(range, isFocused: isFocused, at: index) },
            onOpenLink: { target in openWikiLink(target) },
            onCompletionKey: { action in handleCompletionKey(action) },
            onEmbedLayoutChange: { embedLayoutVersion &+= 1 },
            onDropFiles: { urls, offset in
                handleDroppedFiles(urls, segmentIndex: index, utf16Offset: offset, replacementRange: nil)
            },
            onFileDragActiveChange: { active in
                isFileDropTargeted = active
            },
            onPasteFiles: { urls, range in
                handleDroppedFiles(urls, segmentIndex: index, utf16Offset: range.location, replacementRange: range)
            },
            onPasteImageData: { data, filename, range in
                handlePastedImageData(data, filename: filename, segmentIndex: index, replacementRange: range)
            },
            onDropKnowledgeItem: { item, offset, optionHeld in
                handleDroppedKnowledgeItem(item, segmentIndex: index, utf16Offset: offset, optionHeld: optionHeld)
            },
            onKnowledgeDragActiveChange: { item in
                draggedKnowledgeItem = item
            },
            onResizeImage: { placement, width in
                handleResizeImage(placement: placement, newWidth: width, segmentIndex: index)
            },
            onSelectEmbed: { placement in
                if let placement {
                    selectedEmbedID = placement.id
                    selectedEmbedSegmentIndex = index
                } else {
                    selectedEmbedID = nil
                    selectedEmbedSegmentIndex = nil
                }
                let allEmbeds = resolvedEmbeds.filter { $0.available && ($0.url?.isEmpty == false) }
                onSelectedEmbedChange?(placement?.embed, allEmbeds)
            },
            onRemoveEmbed: { placement in
                handleRemoveEmbed(placement: placement, segmentIndex: index)
            },
            onDeleteAttachment: { placement in
                requestDeleteInlineAttachment(for: placement)
            }
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
        liveSelection.segmentIndex = segmentIndex
        liveSelection.range = selection
        let docSel = documentSelection(for: selection, in: segmentIndex)
        if document.setProse(newText, in: segmentIndex, newSelection: docSel) {
            noteDocumentEdited(debounceHeadings: true)
        }
        updateCompletion(text: newText, selection: selection, segmentIndex: segmentIndex)
    }

    private func handleProseSelection(_ selection: NSRange, isFocused: Bool, at segmentIndex: Int) {
        liveSelection.segmentIndex = segmentIndex
        liveSelection.range = selection
        let nextSel = documentSelection(for: selection, in: segmentIndex)
        let wasCollapsed = document.selection?.isCollapsed ?? true
        // Avoid mutating `@State document` (and re-evaluating `body`) on every collapsed caret move.
        if !nextSel.isCollapsed || !wasCollapsed {
            document.selection = nextSel
        }
        if isFocused, let prose = document.proseText(at: segmentIndex) {
            updateCompletion(text: prose, selection: selection, segmentIndex: segmentIndex)
        } else if completionSegmentIndex == segmentIndex, completionSession.isOpen {
            completionSession.close()
        }
    }

    // MARK: - Formatting & Export Actions

    private func applyProseTransform(_ transform: (String, NSRange) -> KnowledgeMarkdownFormatting.EditResult) {
        let idx = min(liveSelection.segmentIndex, max(0, document.segments.count - 1))
        guard let text = document.proseText(at: idx) else { return }
        let res = transform(text, liveSelection.range)
        let docSel = documentSelection(for: res.selection, in: idx)
        if document.setProse(res.text, in: idx, newSelection: docSel) {
            noteDocumentEdited()
        }
        liveSelection.segmentIndex = idx
        liveSelection.range = res.selection
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
        let idx = min(liveSelection.segmentIndex, max(0, document.segments.count - 1))
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
            if completionSession.isOpen { completionSession.close() }
            return
        }
        // Check current-line trigger syntax before building any completion candidate lists.
        guard let trigger = KnowledgeCompletionLogic.matchTrigger(in: text, caretUTF16: selection.location) else {
            if completionSession.isOpen || completionSession.dismissedAtOffset != nil {
                completionSession.dismissedAtOffset = nil
                completionSession.close()
            }
            return
        }
        completionSegmentIndex = segmentIndex
        let candidates: [KnowledgeCompletionCandidate]
        switch trigger.kind {
        case .page, .tag:
            candidates = remoteCandidates
        case .embed:
            candidates = liveAttachmentCandidates()
        case .heading, .blockID:
            candidates = currentDocumentCandidates()
        }
        completionSession.update(trigger: trigger, allCandidates: candidates, limit: 24)
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
            let acceptedCandidate = (completionSession.activeIndex >= 0 && completionSession.activeIndex < completionSession.candidates.count)
                ? completionSession.candidates[completionSession.activeIndex]
                : nil
            guard let insertion = completionSession.acceptActive() else { return false }
            if let acceptedCandidate, acceptedCandidate.kind == .embed {
                preloadInlineEmbed(forRef: acceptedCandidate.insertRef)
            }
            applyCompletionInsertion(insertion)
            return true
        }
    }

    private func acceptCompletion(at index: Int) {
        guard let trigger = completionSession.trigger,
              index >= 0, index < completionSession.candidates.count else { return }
        let candidate = completionSession.candidates[index]
        let insertion = KnowledgeCompletionLogic.insertion(for: candidate, trigger: trigger)
        completionSession.close()
        if candidate.kind == .embed {
            preloadInlineEmbed(forRef: candidate.insertRef)
        }
        applyCompletionInsertion(insertion)
    }

    private func preloadInlineEmbed(forRef insertRef: String) {
        let storeAttachments = context.store.entry(KnowledgeShellController.attachmentsRequest).data?.attachments ?? []
        if let att = storeAttachments.first(where: { $0.ref == insertRef }) {
            let embed = att.asKnowledgeEmbed()
            if !resolvedEmbeds.contains(where: { $0.ref == embed.ref }) {
                resolvedEmbeds.append(embed)
                embedLayoutVersion &+= 1
            }
        }
    }

    private func liveAttachmentCandidates() -> [KnowledgeCompletionCandidate] {
        let storeAttachments = context.store.entry(KnowledgeShellController.attachmentsRequest).data?.attachments ?? []
        return storeAttachments.map { att in
            let typeText = KnowledgeAttachmentActions.typeLabel(for: att.contentType, filename: att.filename)
            let sizeText = KnowledgeAttachmentActions.formattedSize(att.sizeBytes)
            let detailParts = [typeText, sizeText.isEmpty ? nil : sizeText, att.usageSummary, att.path].compactMap { $0 }
            return KnowledgeCompletionCandidate(
                kind: .embed,
                title: att.filename.isEmpty ? att.ref : att.filename,
                insertRef: att.ref,
                detail: detailParts.joined(separator: " \u{00B7} "),
                symbolName: KnowledgeAttachmentActions.sfSymbol(for: att.contentType, filename: att.filename)
            )
        }
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
        let req = KnowledgeAPI.listPages(includeAgent: true, limit: 200)
        let entry = context.store.load(req)
        let table: KnowledgePageTable?
        if let cached = entry.data {
            table = cached
        } else {
            table = await context.store.refetch(req).data
        }
        var candidates: [KnowledgeCompletionCandidate] = []
        var seenTags = Set<String>()

        if let table {
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

        if context.store.entry(KnowledgeShellController.attachmentsRequest).data == nil {
            _ = await context.store.refetch(KnowledgeShellController.attachmentsRequest)
        }
        remoteCandidates = candidates
    }

    // MARK: - Finder File Drop, Clipboard Paste, Sidebar Drops & Image Resize

    private var dropOverlay: some View {
        let p = theme.palette
        let isOptionHeld = NSEvent.modifierFlags.contains(.option)
        let titleText: String
        let subtitleText: String
        let symbolName: String
        if let item = draggedKnowledgeItem {
            switch item.kind {
            case .page:
                symbolName = isOptionHeld ? "doc.richtext" : "link.circle.fill"
                titleText = isOptionHeld ? "Drop to embed \u{201C}\(item.title)\u{201D}" : "Drop to link \u{201C}\(item.title)\u{201D}"
                subtitleText = isOptionHeld ? "Inserts ![[embed]] (release Option for [[wikilink]])" : "Inserts [[wikilink]] (hold Option for ![[embed]])"
            case .attachment:
                symbolName = "paperclip.circle.fill"
                titleText = "Drop to embed \u{201C}\(item.title)\u{201D}"
                subtitleText = "Inserts ![[...]] inline preview"
            case .folder:
                symbolName = "paperclip.circle.fill"
                titleText = "Drop files to attach"
                subtitleText = "Saved in attachments/ and displayed inline"
            }
        } else {
            symbolName = "paperclip.circle.fill"
            titleText = "Drop files to attach"
            subtitleText = "Saved in attachments/ and displayed inline"
        }

        return ZStack {
            p.background.opacity(0.75)
            VStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 34))
                    .foregroundStyle(p.accent)
                Text(titleText)
                    .vesperText(.heading, theme)
                    .foregroundStyle(p.text)
                Text(subtitleText)
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(p.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleEditorPaneDrop(_ providers: [NSItemProvider]) -> Bool {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await loadFileURL(from: provider) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty {
                    handleDroppedFiles(urls, segmentIndex: nil, utf16Offset: nil, replacementRange: nil)
                }
            }
            return true
        }

        let textProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) }
        if let first = textProviders.first {
            Task { @MainActor in
                if let raw = await loadPlainString(from: first),
                   let item = KnowledgeDragItem.decodeDragPayload(raw) {
                    handleDroppedKnowledgeItem(item, segmentIndex: nil, utf16Offset: nil, optionHeld: optionHeld)
                }
            }
            return true
        }
        return false
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url.isFileURL ? url : nil)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url.isFileURL ? url : nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadPlainString(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { item, _ in
                if let s = item as? String {
                    continuation.resume(returning: s)
                } else if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: s)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func handleDroppedKnowledgeItem(
        _ item: KnowledgeDragItem,
        segmentIndex: Int?,
        utf16Offset: Int?,
        optionHeld: Bool
    ) {
        guard let markdown = KnowledgeShellLogic.droppedMarkdown(for: item, optionHeld: optionHeld) else { return }

        if item.kind == .attachment {
            if let embed = item.asKnowledgeEmbed(), !resolvedEmbeds.contains(where: { $0.ref == embed.ref }) {
                resolvedEmbeds.append(embed)
            }
            insertDroppedEmbedBlock(markdown, preferredSegmentIndex: segmentIndex, preferredUTF16Offset: utf16Offset, replacementRange: nil)
            embedLayoutVersion &+= 1
            noteDocumentEdited()
            Task { @MainActor in
                await saveNow()
                context.store.invalidate(KnowledgeAPI.invalidation)
            }
            return
        }

        // Page drop: inline `[[link]]` by default, or standalone `![[embed]]` when Option is held.
        if optionHeld {
            insertDroppedEmbedBlock(markdown, preferredSegmentIndex: segmentIndex, preferredUTF16Offset: utf16Offset, replacementRange: nil)
            noteDocumentEdited()
            Task { @MainActor in
                await saveNow()
            }
        } else {
            let targetSeg = segmentIndex ?? min(liveSelection.segmentIndex, max(0, document.segments.count - 1))
            if let text = document.proseText(at: targetSeg) {
                let ns = text as NSString
                let offset = max(0, min(utf16Offset ?? (liveSelection.range.location + liveSelection.range.length), ns.length))
                let caretAfter = offset + (markdown as NSString).length
                let newSel = DocumentSelection(collapsedAt: .prose(segmentIndex: targetSeg, utf16Offset: caretAfter))
                if document.replaceProse(in: targetSeg, range: NSRange(location: offset, length: 0), with: markdown, newSelection: newSel) {
                    liveSelection.segmentIndex = targetSeg
                    liveSelection.range = NSRange(location: caretAfter, length: 0)
                    selectionToken += 1
                    selectionRequest = KnowledgeTextSelectionRequest(
                        token: selectionToken,
                        segmentIndex: targetSeg,
                        range: NSRange(location: caretAfter, length: 0)
                    )
                    noteDocumentEdited()
                }
            } else {
                insertDroppedEmbedBlock(markdown, preferredSegmentIndex: segmentIndex, preferredUTF16Offset: utf16Offset, replacementRange: nil)
                noteDocumentEdited()
            }
        }
    }

    private func handlePastedImageData(_ data: Data, filename: String, segmentIndex: Int, replacementRange: NSRange) {
        guard let client = context.store.client, !data.isEmpty else { return }
        let maxBytes = 512 * 1024 * 1024
        guard data.count <= maxBytes else {
            context.showToast(ToastItemModel(id: "knowledge.paste.size", title: "Image exceeds 512 MB limit", tone: .error))
            return
        }
        uploadingFileCount += 1
        Task { @MainActor in
            defer { uploadingFileCount = max(0, uploadingFileCount - 1) }
            do {
                let uploaded = try await client.send(KnowledgeAPI.uploadAsset(data: data, filename: filename))
                let embed = uploaded.asKnowledgeEmbed()
                if !resolvedEmbeds.contains(where: { $0.ref == embed.ref }) {
                    resolvedEmbeds.append(embed)
                }
                let block = KnowledgeShellLogic.markdownEmbedBlock(for: [uploaded.ref])
                insertDroppedEmbedBlock(
                    block,
                    preferredSegmentIndex: segmentIndex,
                    preferredUTF16Offset: replacementRange.location,
                    replacementRange: replacementRange
                )
                embedLayoutVersion &+= 1
                noteDocumentEdited()
                await saveNow()
                context.store.invalidate(KnowledgeAPI.invalidation)
                _ = await context.store.refetch(KnowledgeShellController.attachmentsRequest)
                context.showToast(ToastItemModel(
                    id: "knowledge.paste.image.ok",
                    title: "Saved \(uploaded.filename ?? filename) to attachments/",
                    tone: .success
                ))
            } catch {
                context.showToast(ToastItemModel(
                    id: "knowledge.paste.image.err",
                    title: "Couldn\u{2019}t paste image",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }

    private func handleResizeImage(placement: KnowledgeInlineEmbedPlacement, newWidth: Int?, segmentIndex: Int) {
        guard let prose = document.proseText(at: segmentIndex) else { return }
        let ns = prose as NSString
        guard placement.tokenRange.location >= 0,
              placement.tokenRange.location + placement.tokenRange.length <= ns.length else { return }
        let currentToken = ns.substring(with: placement.tokenRange)
        let updatedToken = KnowledgeMarkdownSyntax.updatingEmbedWidth(in: currentToken, width: newWidth)
        guard updatedToken != currentToken else { return }
        let newSel = DocumentSelection(collapsedAt: .prose(segmentIndex: segmentIndex, utf16Offset: liveSelection.range.location))
        if document.replaceProse(in: segmentIndex, range: placement.tokenRange, with: updatedToken, newSelection: newSel) {
            embedLayoutVersion &+= 1
            noteDocumentEdited()
        }
    }

    private func resolveCurrentPlacement(
        matching placement: KnowledgeInlineEmbedPlacement,
        in prose: String
    ) -> KnowledgeInlineEmbedPlacement? {
        let ns = prose as NSString
        if placement.tokenRange.location >= 0,
           placement.tokenRange.location + placement.tokenRange.length <= ns.length,
           ns.substring(with: placement.tokenRange) == placement.target.raw {
            return placement
        }
        let current = KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: prose, embeds: resolvedEmbeds)
        return current.first(where: { $0.id == placement.id })
            ?? current.first(where: { $0.target.raw == placement.target.raw })
    }

    @discardableResult
    private func handleRemoveEmbed(placement: KnowledgeInlineEmbedPlacement, segmentIndex: Int) -> Bool {
        guard let prose = document.proseText(at: segmentIndex),
              let livePlacement = resolveCurrentPlacement(matching: placement, in: prose),
              let edit = KnowledgeMarkdownSyntax.removingEmbed(livePlacement, in: prose) else {
            return false
        }
        if !removedEmbedCache.contains(where: { $0.ref == livePlacement.embed.ref }) {
            removedEmbedCache.append(livePlacement.embed)
        }
        let caret = NSRange(location: edit.caretUTF16, length: 0)
        let newSel = DocumentSelection(collapsedAt: .prose(segmentIndex: segmentIndex, utf16Offset: edit.caretUTF16))
        guard document.replaceProse(in: segmentIndex, range: edit.replacementRange, with: edit.replacement, newSelection: newSel) else {
            return false
        }
        clearSelectedEmbed()
        liveSelection.segmentIndex = segmentIndex
        liveSelection.range = caret
        selectionToken += 1
        selectionRequest = KnowledgeTextSelectionRequest(token: selectionToken, segmentIndex: segmentIndex, range: caret)
        embedLayoutVersion &+= 1
        noteDocumentEdited()
        return true
    }

    private func clearSelectedEmbed() {
        selectedEmbedID = nil
        selectedEmbedSegmentIndex = nil
        let allEmbeds = resolvedEmbeds.filter { $0.available && ($0.url?.isEmpty == false) }
        onSelectedEmbedChange?(nil, allEmbeds)
    }

    private func removeSelectedEmbed() -> Bool {
        guard let id = selectedEmbedID,
              let segIdx = selectedEmbedSegmentIndex,
              let prose = document.proseText(at: segIdx) else {
            return false
        }
        let placements = KnowledgeMarkdownSyntax.resolveInlineEmbedPlacements(in: prose, embeds: resolvedEmbeds)
        guard let placement = placements.first(where: { $0.id == id }) else {
            clearSelectedEmbed()
            return false
        }
        return handleRemoveEmbed(placement: placement, segmentIndex: segIdx)
    }

    private func syncEmbedKeyMonitor(active: Bool) {
        removeEmbedKeyMonitor()
        guard active else { return }
        embedKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedEmbedID != nil,
                  context.isActiveTab,
                  let window = context.window()?.window,
                  event.window === window,
                  window.isKeyWindow,
                  window.attachedSheet == nil,
                  deletingAttachment == nil else {
                return event
            }
            let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
                return event
            }
            if let responder = window.firstResponder, responder is NSText {
                return event
            }
            // Backspace (51) or Forward Delete (117) removes the selected inline embed from the note.
            if event.keyCode == 51 || event.keyCode == 117 {
                return removeSelectedEmbed() ? nil : event
            }
            // Escape (53) deselects the inline embed.
            if event.keyCode == 53 {
                clearSelectedEmbed()
                return nil
            }
            return event
        }
    }

    private func removeEmbedKeyMonitor() {
        if let embedKeyMonitor {
            NSEvent.removeMonitor(embedKeyMonitor)
            self.embedKeyMonitor = nil
        }
    }

    private func requestDeleteInlineAttachment(for placement: KnowledgeInlineEmbedPlacement) {
        guard let url = placement.embed.url, !url.isEmpty else { return }
        let attachments = context.store.entry(KnowledgeShellController.attachmentsRequest).data?.attachments ?? []
        guard let match = attachments.first(where: { $0.isOwner && $0.url == url }) else { return }
        deletingAttachment = match
    }

    private func deleteInlineAttachment(_ attachment: KnowledgeAttachment) async throws {
        _ = try await context.store.mutate(
            KnowledgeAPI.deleteAttachment(id: attachment.id),
            invalidating: KnowledgeAPI.invalidation
        )
        let matchingResolved = resolvedEmbeds.filter { $0.url == attachment.url }
        let targetEmbeds = matchingResolved.isEmpty ? [attachment.asKnowledgeEmbed()] : matchingResolved
        var removedAny = false
        for segIdx in document.segments.indices {
            while let prose = document.proseText(at: segIdx),
                  let placement = KnowledgeMarkdownSyntax
                      .resolveInlineEmbedPlacements(in: prose, embeds: targetEmbeds)
                      .first,
                  let edit = KnowledgeMarkdownSyntax.removingEmbed(placement, in: prose) {
                let newSel = DocumentSelection(collapsedAt: .prose(segmentIndex: segIdx, utf16Offset: edit.caretUTF16))
                guard document.replaceProse(in: segIdx, range: edit.replacementRange, with: edit.replacement, newSelection: newSel) else {
                    break
                }
                removedAny = true
            }
        }
        resolvedEmbeds.removeAll { $0.url == attachment.url }
        removedEmbedCache.removeAll { $0.url == attachment.url }
        clearSelectedEmbed()
        if removedAny {
            embedLayoutVersion &+= 1
            noteDocumentEdited()
            await saveNow()
        }
        _ = await context.store.refetch(KnowledgeShellController.attachmentsRequest)
        context.showToast(ToastItemModel(
            id: "knowledge.att.delete.\(attachment.id)",
            title: "Deleted \(attachment.filename)",
            tone: .success
        ))
    }

    private func restoreCachedEmbedsForCurrentDocument() {
        let md = document.serialize()
        let storeAttachments = context.store.entry(KnowledgeShellController.attachmentsRequest).data?.attachments ?? []
        let candidatePool = removedEmbedCache + storeAttachments.map { $0.asKnowledgeEmbed() }
        let needed = KnowledgeMarkdownSyntax.resolveInlineEmbeds(in: md, embeds: candidatePool)
        var added = false
        for embed in needed where !resolvedEmbeds.contains(where: { $0.ref == embed.ref }) {
            resolvedEmbeds.append(embed)
            added = true
        }
        if added {
            embedLayoutVersion &+= 1
        }
    }

    private func jumpToHeading(_ heading: KnowledgeOutlineHeading, scrollProxy: ScrollViewProxy) {
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

    private func linkUnlinkedMention(_ mention: KnowledgeUnlinkedMention) {
        guard let client = context.store.client else { return }
        linkingMentionId = mention.id
        Task { @MainActor in
            defer { linkingMentionId = nil }
            do {
                let sourcePage = try await client.send(KnowledgeAPI.getPage(id: mention.pageId))
                guard let body = sourcePage.bodyMd,
                      let patched = KnowledgePanelsLogic.linkFirstMention(
                        in: body,
                        term: mention.matchedTerm,
                        targetTitle: page.title
                      ) else {
                    context.showToast(ToastItemModel(
                        id: "knowledge.mention.miss",
                        title: "Couldn\u{2019}t find unlinked mention in \(mention.pageTitle)",
                        tone: .error
                    ))
                    return
                }
                _ = try await context.store.mutate(
                    KnowledgeAPI.updatePage(
                        id: sourcePage.id,
                        body: KnowledgePageInput(
                            bodyMd: patched,
                            baseVersionId: sourcePage.versionId,
                            note: "Linked mention to \(page.title)"
                        )
                    ),
                    invalidating: KnowledgeAPI.invalidation
                )
                context.showToast(ToastItemModel(
                    id: "knowledge.mention.linked",
                    title: "Linked mention in \(mention.pageTitle)",
                    tone: .success
                ))
            } catch {
                context.showToast(ToastItemModel(
                    id: "knowledge.mention.err",
                    title: "Couldn\u{2019}t link mention",
                    description: (error as? APIError)?.userMessage ?? error.localizedDescription,
                    tone: .error
                ))
            }
        }
    }

    private func handleDroppedFiles(_ urls: [URL], segmentIndex: Int?, utf16Offset: Int?, replacementRange: NSRange?) {
        guard let client = context.store.client else { return }
        let maxBytes = 512 * 1024 * 1024
        var validFiles: [URL] = []
        var skippedReasons: [String] = []
        var seen = Set<String>()

        for url in urls where url.isFileURL {
            let path = url.path
            guard seen.insert(path).inserted else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                skippedReasons.append("\(url.lastPathComponent) (folders can\u{2019}t be attached)")
                continue
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            if size <= 0 {
                skippedReasons.append("\(url.lastPathComponent) (empty file)")
                continue
            }
            if size > maxBytes {
                skippedReasons.append("\(url.lastPathComponent) (over 512 MB limit)")
                continue
            }
            validFiles.append(url)
        }

        if !skippedReasons.isEmpty {
            context.showToast(ToastItemModel(
                id: "knowledge.drop.skipped",
                title: "Skipped \(skippedReasons.count) item(s)",
                description: skippedReasons.prefix(3).joined(separator: ", "),
                tone: .error
            ))
        }

        guard !validFiles.isEmpty else { return }
        uploadingFileCount += validFiles.count

        Task { @MainActor in
            defer { uploadingFileCount = max(0, uploadingFileCount - validFiles.count) }
            var uploadedRefs: [String] = []
            var newEmbeds: [KnowledgeEmbed] = []
            var failedNames: [String] = []

            for fileURL in validFiles {
                let filename = fileURL.lastPathComponent
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: fileURL)
                    }.value
                    let uploaded = try await client.send(KnowledgeAPI.uploadAsset(data: data, filename: filename))
                    uploadedRefs.append(uploaded.ref)
                    newEmbeds.append(uploaded.asKnowledgeEmbed())
                } catch {
                    failedNames.append(filename)
                }
            }

            if !failedNames.isEmpty {
                context.showToast(ToastItemModel(
                    id: "knowledge.drop.failed",
                    title: "Couldn\u{2019}t attach \(failedNames.count) file(s)",
                    description: failedNames.prefix(3).joined(separator: ", "),
                    tone: .error
                ))
            }

            guard !uploadedRefs.isEmpty else { return }

            for embed in newEmbeds where !resolvedEmbeds.contains(where: { $0.ref == embed.ref }) {
                resolvedEmbeds.append(embed)
            }

            let block = KnowledgeShellLogic.markdownEmbedBlock(for: uploadedRefs)
            insertDroppedEmbedBlock(
                block,
                preferredSegmentIndex: segmentIndex,
                preferredUTF16Offset: utf16Offset,
                replacementRange: replacementRange
            )
            embedLayoutVersion &+= 1
            noteDocumentEdited()
            await saveNow()
            context.store.invalidate(KnowledgeAPI.invalidation)
            _ = await context.store.refetch(KnowledgeShellController.attachmentsRequest)
            await loadCompletionCandidates()

            context.showToast(ToastItemModel(
                id: "knowledge.drop.ok",
                title: uploadedRefs.count == 1
                    ? "Attached to attachments/"
                    : "Attached \(uploadedRefs.count) files to attachments/",
                tone: .success
            ))
        }
    }

    private func insertDroppedEmbedBlock(
        _ block: String,
        preferredSegmentIndex: Int?,
        preferredUTF16Offset: Int?,
        replacementRange: NSRange?
    ) {
        let targetSeg = preferredSegmentIndex ?? min(liveSelection.segmentIndex, max(0, document.segments.count - 1))
        if let text = document.proseText(at: targetSeg) {
            let ns = text as NSString
            let replaceRange: NSRange
            if let replacementRange {
                let loc = max(0, min(replacementRange.location, ns.length))
                let len = max(0, min(replacementRange.length, ns.length - loc))
                replaceRange = NSRange(location: loc, length: len)
            } else {
                let offset: Int
                if let preferredUTF16Offset {
                    offset = max(0, min(preferredUTF16Offset, ns.length))
                } else if targetSeg == liveSelection.segmentIndex {
                    offset = max(0, min(liveSelection.range.location + liveSelection.range.length, ns.length))
                } else {
                    offset = ns.length
                }
                replaceRange = NSRange(location: offset, length: 0)
            }
            let offset = replaceRange.location
            let prefix = (offset > 0 && ns.substring(with: NSRange(location: offset - 1, length: 1)) != "\n") ? "\n" : ""
            let inserted = "\(prefix)\(block)\n"
            let caretAfter = offset + (inserted as NSString).length
            let newSel = DocumentSelection(collapsedAt: .prose(segmentIndex: targetSeg, utf16Offset: caretAfter))
            if document.replaceProse(in: targetSeg, range: replaceRange, with: inserted, newSelection: newSel) {
                liveSelection.segmentIndex = targetSeg
                liveSelection.range = NSRange(location: caretAfter, length: 0)
                selectionToken += 1
                selectionRequest = KnowledgeTextSelectionRequest(
                    token: selectionToken,
                    segmentIndex: targetSeg,
                    range: NSRange(location: caretAfter, length: 0)
                )
            }
        } else {
            let existing = document.serialize()
            let sep = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            document = KnowledgeEditorDocument(markdown: "\(existing)\(sep)\(block)\n")
        }
    }

    private func performUndo() {
        guard document.undo() else { return }
        restoreCachedEmbedsForCurrentDocument()
        refreshFindAfterEdit()
        emitHeadings(immediately: true)
        syncDirtyStateAfterHistoryChange()
    }

    private func performRedo() {
        guard document.redo() else { return }
        restoreCachedEmbedsForCurrentDocument()
        refreshFindAfterEdit()
        emitHeadings(immediately: true)
        syncDirtyStateAfterHistoryChange()
    }

    private func syncDirtyStateAfterHistoryChange() {
        let dirty = document.serialize() != lastSavedMarkdown
        hasUnsavedChanges = dirty
        if dirty {
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

    private func refreshDerivedLinksAndMentions() {
        let network = context.store.entry(networkRequest).data ?? KnowledgeNetwork()
        let backlinks = KnowledgePanelsLogic.backlinks(for: page.id, in: network)
        cachedBacklinks = backlinks
        cachedOutgoingLinks = KnowledgePanelsLogic.outgoingLinks(for: page.id, in: network)
        let candidates = context.store.entry(mentionCandidatesRequest).data?.rows ?? []
        cachedUnlinkedMentions = KnowledgePanelsLogic.findUnlinkedMentions(
            of: page,
            in: candidates,
            linkedSourceIds: Set(backlinks.map(\.id))
        )
    }

    private func emitHeadings(immediately: Bool) {
        headingsDebounceTask?.cancel()
        if immediately {
            let next = KnowledgeInspectorLogic.extractHeadings(from: document.segments)
            if next != cachedHeadings {
                cachedHeadings = next
            }
            onHeadingsChange?(next)
            return
        }
        headingsDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let next = KnowledgeInspectorLogic.extractHeadings(from: document.segments)
            if next != cachedHeadings {
                cachedHeadings = next
                onHeadingsChange?(next)
            }
        }
    }

    private func noteDocumentEdited(debounceHeadings: Bool = false) {
        refreshFindAfterEdit()
        emitHeadings(immediately: !debounceHeadings)
        let dirty = document.serialize() != lastSavedMarkdown
        if hasUnsavedChanges != dirty {
            hasUnsavedChanges = dirty
        }
        guard dirty else {
            saveStatus = .saved
            return
        }
        if saveStatus != .dirty {
            saveStatus = .dirty
        }
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
        guard hasUnsavedChanges || document.isDirty else { return }
        autosaveTask?.cancel()
        let serialized = document.serialize()
        guard serialized != lastSavedMarkdown else {
            hasUnsavedChanges = false
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
            hasUnsavedChanges = false
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

// MARK: - Toolbar Hover Tooltip

private struct KnowledgeToolbarTooltipModifier: ViewModifier {
    @Environment(\.vesperTheme) private var theme

    let title: String
    let hint: String?
    let alignment: Alignment
    let highlightHover: Bool

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    private var accessibilityHelpText: String {
        if let hint, !hint.isEmpty {
            return "\(title) (\(hint))"
        }
        return title
    }

    func body(content: Content) -> some View {
        let p = theme.palette
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlightHover && isHovered ? theme.swiftUIColor("surface-sunken", fallback: p.selected) : .clear)
            )
            .contentShape(Rectangle())
            .help(accessibilityHelpText)
            .accessibilityLabel(title)
            .onHover { hovering in
                isHovered = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(220))
                        guard !Task.isCancelled else { return }
                        showTooltip = true
                    }
                } else {
                    showTooltip = false
                }
            }
            .onDisappear {
                hoverTask?.cancel()
                showTooltip = false
            }
            .overlay(alignment: alignment) {
                if showTooltip {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(p.text)
                        if let hint, !hint.isEmpty {
                            Text(hint)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(p.secondaryText)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    theme.swiftUIColor("surface-sunken", fallback: p.surface),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        theme.swiftUIColor("surface-elevated", fallback: p.surface),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(p.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .offset(y: 30)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .zIndex(showTooltip ? 100 : 0)
    }
}

private extension View {
    func knowledgeToolbarTooltip(
        _ title: String,
        hint: String? = nil,
        alignment: Alignment = .bottom,
        highlightHover: Bool = true
    ) -> some View {
        modifier(KnowledgeToolbarTooltipModifier(
            title: title,
            hint: hint,
            alignment: alignment,
            highlightHover: highlightHover
        ))
    }
}
