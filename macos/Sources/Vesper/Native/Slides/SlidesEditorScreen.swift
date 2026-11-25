import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

// MARK: - Full-Page Route Screen (/apps/slides/:id)

struct SlidesEditorScreen: View {
    @Environment(NativeScreenContext.self) private var context

    private var canvasId: String { context.match.params["id"] ?? "" }
    private var initialSlide: Int { max(0, (Int(context.match.query["slide"] ?? "1") ?? 1) - 1) }

    var body: some View {
        SlidesEditorView(canvasId: canvasId, embedded: false, initialSlideIndex: initialSlide)
            .id(canvasId)
    }
}

// MARK: - Reusable Slides Editor View (Full-Page & Embedded in Knowledge / Chat)

struct SlidesEditorView: View {
    private enum SaveState: Equatable {
        case saved, unsaved, saving, conflict, error(String)
    }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let canvasId: String
    let embedded: Bool
    var initialSlideIndex: Int = 0

    @State private var deck: SlideDeck?
    @State private var savedDeck: SlideDeck?
    @State private var savedSeq: Int = 0
    @State private var past: [SlideDeck] = []
    @State private var future: [SlideDeck] = []
    @State private var saveState: SaveState = .saved
    @State private var conflictDeck: (deck: SlideDeck, seq: Int)?
    @State private var autosaveTask: Task<Void, Never>?

    @State private var activeSlideIndex: Int = 0
    @State private var selectedIds: Set<String> = []
    @State private var editingTextId: String?
    @State private var showNotes = true
    @State private var showThemeEditor = false
    @State private var customThemeDraft: SlideTheme?
    @State private var notice: String?
    @State private var assetCache = SlideAssetCache()

    // Review state
    @State private var reviewDecisions: [Int: DocReviewDecision] = [:]
    @State private var reviewBusy = false
    @State private var reviewError: String?

    // Chrome state
    @State private var inspectorOpen = true
    @State private var activeInspectorTab = "chat"

    private var refRequest: APIRequest<API.MyCanvas> { API.getMyCanvas(canvasId: canvasId) }
    private func chatRequest(_ chatId: String) -> APIRequest<API.ChatSession> { API.getChat(id: chatId) }
    private func canvasRequest(chatId: String, seq: Int? = nil) -> APIRequest<API.ChatCanvas> { API.getChatCanvas(id: chatId, canvasId: canvasId, seq: seq) }
    private var savedThemesRequest: APIRequest<API.ListSlideThemesResponse> { API.listSlideThemes() }

    private func clampedSlideIndex(_ index: Int, in deck: SlideDeck) -> Int {
        guard !deck.slides.isEmpty else { return 0 }
        return min(max(0, index), deck.slides.count - 1)
    }

    private var currentSlide: Slide? {
        guard let deck, !deck.slides.isEmpty else { return nil }
        return deck.slides[clampedSlideIndex(activeSlideIndex, in: deck)]
    }

    var body: some View {
        let p = theme.palette
        let refEntry = context.store.entry(refRequest)
        let ref = refEntry.data
        let chatId = ref?.chatId ?? ""
        let chat = chatId.isEmpty ? nil : context.store.entry(chatRequest(chatId)).data
        let headEntry = chatId.isEmpty ? nil : context.store.entry(canvasRequest(chatId: chatId))
        let head = headEntry?.data
        let live = chat?.state == .running
        let readOnly = (chat?.archived ?? false) || live
        let personaName = chat?.speaker?.name ?? chat?.persona?.name ?? "Assistant"
        let title = head?.title ?? ref?.title ?? "Slides"

        let reviewBaseSeq = head.map { DocEditorLogic.reviewBase(versions: $0.versions, reviewedSeq: ref?.reviewedSeq ?? 0) } ?? 0
        let wantsReview = head != nil && !live && reviewBaseSeq > 0 && (head?.seq ?? 0) > reviewBaseSeq
        let baseEntry = (wantsReview && !chatId.isEmpty) ? context.store.entry(canvasRequest(chatId: chatId, seq: reviewBaseSeq)) : nil
        let baseDeck: SlideDeck? = {
            guard wantsReview, let b = baseEntry?.data, b.viewingSeq == reviewBaseSeq else { return nil }
            return try? SlideSchema.parseDeck(b.body)
        }()
        let headDeck: SlideDeck? = head.flatMap { try? SlideSchema.parseDeck($0.body) }
        let reviewChanges: [SlideReviewChange] = {
            guard let baseDeck, let headDeck else { return [] }
            return SlideReviewLogic.deckChanges(base: baseDeck, head: headDeck)
        }()
        let isSuggesting = wantsReview && !reviewChanges.isEmpty

        VStack(spacing: 0) {
            if let err = refEntry.error ?? headEntry?.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(p.tertiaryText)
                    Text("Couldn\u{2019}t open this presentation").font(.system(size: 14, weight: .semibold))
                    Text(err.userMessage).font(.system(size: 12)).foregroundStyle(p.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let deck, let slide = currentSlide {
                toolbarStrip(
                    deck: deck,
                    slide: slide,
                    title: title,
                    seq: savedSeq,
                    readOnly: readOnly,
                    live: live,
                    personaName: personaName,
                    chatId: chatId
                )
                Divider().overlay(p.border)

                if let notice {
                    HStack {
                        Text(notice).font(.system(size: 12)).foregroundStyle(p.text)
                        Spacer()
                        Button("Dismiss") { self.notice = nil }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6).background(p.surface)
                    Divider().overlay(p.border)
                }

                if saveState == .conflict, let c = conflictDeck {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("This slide changed while you were editing.").font(.system(size: 12))
                        Spacer()
                        Button("Use latest") {
                            self.deck = c.deck
                            self.savedDeck = c.deck
                            self.savedSeq = c.seq
                            self.conflictDeck = nil
                            self.saveState = .saved
                            self.activeSlideIndex = clampedSlideIndex(activeSlideIndex, in: c.deck)
                        }.buttonStyle(.vesper(.outline))
                        Button("Keep mine") {
                            self.savedSeq = c.seq
                            self.conflictDeck = nil
                            self.saveState = .unsaved
                            Task { await saveNow(chatId: chatId, forceSeq: c.seq) }
                        }.buttonStyle(.vesper(.primary))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Color.orange.opacity(0.1))
                    Divider().overlay(p.border)
                }

                HStack(spacing: 0) {
                    if embedded {
                        slidesThumbnailsStrip(deck: deck, readOnly: readOnly, chatId: chatId)
                            .frame(width: 176)
                            .background(p.surface)
                        Divider().overlay(p.border)
                    }

                    VStack(spacing: 0) {
                        InteractiveSlideCanvas(
                            deck: deck,
                            slide: slide,
                            images: assetCache.images,
                            readOnly: readOnly,
                            selectedIds: $selectedIds,
                            editingTextId: $editingTextId,
                            onCommitSlide: { updatedSlide in
                                mutateDeck(chatId: chatId) { d in
                                    guard !d.slides.isEmpty else { return }
                                    let idx = clampedSlideIndex(activeSlideIndex, in: d)
                                    d.slides[idx] = updatedSlide
                                }
                            },
                            onUploadImageForSlot: { slotEl in
                                pickAndUploadImage(replacing: slotEl, chatId: chatId)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))

                        if showNotes {
                            Divider().overlay(p.border)
                            HStack(alignment: .top, spacing: 8) {
                                Text("Speaker notes")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(p.tertiaryText)
                                    .padding(.top, 4)
                                TextEditor(text: Binding(
                                    get: { slide.notes ?? "" },
                                    set: { val in
                                        mutateDeck(chatId: chatId) { d in
                                            guard !d.slides.isEmpty else { return }
                                            let idx = clampedSlideIndex(activeSlideIndex, in: d)
                                            d.slides[idx].notes = val.isEmpty ? nil : val
                                        }
                                    }
                                ))
                                .font(.system(size: 12))
                                .scrollContentBackground(.hidden)
                                .disabled(readOnly)
                                .frame(height: 54)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(p.surface)
                        }
                    }
                }
            } else {
                ProgressView("Loading presentation\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .sheet(isPresented: $showThemeEditor) {
            if let draft = customThemeDraft {
                SlideThemeEditorSheet(
                    initial: draft,
                    onApplyToDeck: { nextTheme in
                        mutateDeck(chatId: chatId) { $0.theme = nextTheme }
                        showThemeEditor = false
                    },
                    onSaveCustom: { nextTheme in
                        Task { await saveCustomTheme(nextTheme, chatId: chatId) }
                        showThemeEditor = false
                    },
                    onCancel: { showThemeEditor = false }
                )
            }
        }
        .task(id: canvasId) {
            if let deck {
                activeSlideIndex = clampedSlideIndex(initialSlideIndex, in: deck)
            } else {
                activeSlideIndex = max(0, initialSlideIndex)
            }
            context.store.observe(refRequest)
            context.store.load(refRequest)
            context.store.load(savedThemesRequest)
        }
        .task(id: chatId) {
            guard !chatId.isEmpty else { return }
            let cr = chatRequest(chatId)
            let hr = canvasRequest(chatId: chatId)
            context.store.observe(cr)
            context.store.observe(hr)
            context.store.load(cr)
            context.store.load(hr)
        }
        .task(id: "\(chatId):\(reviewBaseSeq):\(wantsReview)") {
            guard wantsReview, !chatId.isEmpty, reviewBaseSeq > 0 else { return }
            context.store.load(canvasRequest(chatId: chatId, seq: reviewBaseSeq))
        }
        .onChange(of: head?.seq) { _, _ in
            if let head { syncFromServer(head: head) }
        }
        .onChange(of: head?.body) { _, _ in
            if let head, deck == nil { syncFromServer(head: head) }
        }
        .onChange(of: deck?.assets.keys.sorted().joined(separator: ",")) { _, _ in
            if let deck {
                assetCache.ensureLoaded(canvasId: canvasId, assetIds: Array(deck.assets.keys), client: context.store.client)
            }
        }
        .onChange(of: isSuggesting) { _, suggesting in
            if suggesting {
                activeInspectorTab = "review"
                inspectorOpen = true
            }
        }
        .onChange(of: "\(title)|\(deck?.slides.count ?? 0)|\(activeSlideIndex)|\(savedSeq)|\(isSuggesting)|\(reviewChanges.count)|\(inspectorOpen)|\(activeInspectorTab)|\(chatId)") { _, _ in
            guard !embedded else { return }
            publishChrome(
                title: title,
                seq: savedSeq,
                chatId: chatId,
                personaName: personaName,
                live: live,
                readOnly: readOnly,
                baseDeck: baseDeck,
                headDeck: headDeck,
                headSeq: head?.seq ?? savedSeq,
                reviewChanges: reviewChanges
            )
        }
        .onAppear {
            if let head { syncFromServer(head: head) }
            if !embedded {
                publishChrome(
                    title: title,
                    seq: savedSeq,
                    chatId: chatId,
                    personaName: personaName,
                    live: live,
                    readOnly: readOnly,
                    baseDeck: baseDeck,
                    headDeck: headDeck,
                    headSeq: head?.seq ?? savedSeq,
                    reviewChanges: reviewChanges
                )
            }
        }
        .onDisappear {
            autosaveTask?.cancel()
            if !embedded {
                context.sidebarView = nil
                context.inspectorView = nil
                context.onCommand = nil
            }
            context.store.stopObserving(refRequest.key)
            if !chatId.isEmpty {
                context.store.stopObserving(chatRequest(chatId).key)
                context.store.stopObserving(canvasRequest(chatId: chatId).key)
            }
        }
    }

    // MARK: - Formatting & Action Toolbar

    @ViewBuilder
    private func toolbarStrip(
        deck: SlideDeck,
        slide: Slide,
        title: String,
        seq: Int,
        readOnly: Bool,
        live: Bool,
        personaName: String,
        chatId: String
    ) -> some View {
        let p = theme.palette
        let selected = slide.elements.filter { selectedIds.contains($0.id) }
        let single = selected.count == 1 ? selected.first : nil

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !readOnly {
                    iconBtn("arrow.uturn.backward", help: "Undo (⌘Z)", disabled: past.isEmpty) { undo(chatId: chatId) }
                    iconBtn("arrow.uturn.forward", help: "Redo (⇧⌘Z)", disabled: future.isEmpty) { redo(chatId: chatId) }
                    Divider().frame(height: 16)

                    // Insert controls
                    Button { insertTextBox(chatId: chatId) } label: { Label("Text", systemImage: "textformat").font(.system(size: 11)) }
                        .buttonStyle(.vesper(.outline))

                    Menu {
                        ForEach(["Basics", "Arrows & flow", "Callouts", "Accents"], id: \.self) { cat in
                            Section(cat) {
                                ForEach(SlideShapeKind.allCases.filter { $0.category == cat }, id: \.self) { kind in
                                    Button(kind.label) { insertShape(kind, chatId: chatId) }
                                }
                            }
                        }
                    } label: {
                        Label("Shape", systemImage: "square.on.circle").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)

                    Button { insertLine(chatId: chatId) } label: { Label("Line", systemImage: "line.diagonal").font(.system(size: 11)) }
                        .buttonStyle(.vesper(.outline))

                    Button { pickAndUploadImage(replacing: nil, chatId: chatId) } label: { Label("Image", systemImage: "photo").font(.system(size: 11)) }
                        .buttonStyle(.vesper(.outline))

                    Divider().frame(height: 16)

                    // Layout menu
                    Menu {
                        ForEach(SlideLayoutKind.allCases, id: \.self) { layout in
                            Button {
                                mutateDeck(chatId: chatId) { d in
                                    guard !d.slides.isEmpty else { return }
                                    let idx = clampedSlideIndex(activeSlideIndex, in: d)
                                    d.slides[idx] = SlideSchema.relayout(d.slides[idx], to: layout)
                                }
                            } label: {
                                if slide.layout == layout { Label(layout.label, systemImage: "checkmark") }
                                else { Text(layout.label) }
                            }
                        }
                    } label: {
                        Label("Layout", systemImage: "rectangle.3.group").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)

                    // Theme menu
                    Menu {
                        ForEach(SlideSchema.themeOrder, id: \.self) { key in
                            if let t = SlideSchema.builtInThemes[key] {
                                Button(t.name) {
                                    mutateDeck(chatId: chatId) { $0.theme = t }
                                }
                            }
                        }
                        let customThemes = context.store.entry(savedThemesRequest).data?.themes ?? []
                        if !customThemes.isEmpty {
                            Divider()
                            ForEach(customThemes, id: \.id) { ct in
                                Button(ct.name) {
                                    let mapped = SlideTheme(
                                        name: ct.name,
                                        fonts: SlideThemeFonts(
                                            heading: SlideFontSlot(rawValue: ct.fonts.heading.rawValue) ?? .sans,
                                            body: SlideFontSlot(rawValue: ct.fonts.body.rawValue) ?? .sans
                                        ),
                                        colors: SlideThemeColors(
                                            background: ct.colors.background, text: ct.colors.text, heading: ct.colors.heading,
                                            accent: ct.colors.accent, accent2: ct.colors.accent2, muted: ct.colors.muted, surface: ct.colors.surface
                                        )
                                    )
                                    mutateDeck(chatId: chatId) { $0.theme = mapped }
                                }
                            }
                        }
                        Divider()
                        Button("Customize theme\u{2026}") {
                            customThemeDraft = deck.theme
                            showThemeEditor = true
                        }
                    } label: {
                        Label(deck.theme.name, systemImage: "paintpalette").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)

                    if !selected.isEmpty {
                        Divider().frame(height: 16)

                        // Text formatting when a text/shape element is selected
                        if selected.contains(where: { $0.textBox != nil }) {
                            iconBtn("bold", help: "Bold") { toggleTextMark(\.bold, chatId: chatId) }
                            iconBtn("italic", help: "Italic") { toggleTextMark(\.italic, chatId: chatId) }
                            iconBtn("underline", help: "Underline") { toggleTextMark(\.underline, chatId: chatId) }
                            iconBtn("strikethrough", help: "Strikethrough") { toggleTextMark(\.strike, chatId: chatId) }
                            Menu {
                                ForEach([24, 32, 40, 48, 64, 80, 96, 128], id: \.self) { sz in
                                    Button("\(sz) pt") { updateSelectedRuns(chatId: chatId) { $0.size = Double(sz) } }
                                }
                            } label: {
                                let rawSize = single?.textBox?.paragraphs.first?.runs.first?.size ?? 44
                                let safeSize = rawSize.isFinite ? Int(min(max(rawSize, 1), 999).rounded()) : 44
                                Text("\(safeSize)").font(.system(size: 11, design: .monospaced))
                            }
                            .menuStyle(.borderlessButton)
                            Menu {
                                Button("Left") { updateSelectedParagraphs(chatId: chatId) { $0.align = nil } }
                                Button("Center") { updateSelectedParagraphs(chatId: chatId) { $0.align = "center" } }
                                Button("Right") { updateSelectedParagraphs(chatId: chatId) { $0.align = "right" } }
                                Button("Justify") { updateSelectedParagraphs(chatId: chatId) { $0.align = "justify" } }
                                Divider()
                                Button("No bullets") { updateSelectedParagraphs(chatId: chatId) { $0.bullet = nil; $0.level = nil } }
                                Button("Bulleted") { updateSelectedParagraphs(chatId: chatId) { $0.bullet = "disc"; $0.level = $0.level ?? 0 } }
                                Button("Numbered") { updateSelectedParagraphs(chatId: chatId) { $0.bullet = "number"; $0.level = $0.level ?? 0 } }
                            } label: {
                                Image(systemName: "text.alignleft").font(.system(size: 11))
                            }
                            .menuStyle(.borderlessButton)
                        }

                        // Shape / Line style menu
                        if case .shape = single {
                            Menu {
                                Section("Fill") {
                                    ForEach(SlideThemeColorKey.allCases, id: \.self) { key in
                                        Button(key.rawValue.capitalized) {
                                            updateSelectedElements(chatId: chatId) { el in
                                                if case .shape(var s) = el { s.fill = .solid(key.rawValue); return .shape(s) }
                                                return el
                                            }
                                        }
                                    }
                                    Button("Gradient (Accent)") {
                                        updateSelectedElements(chatId: chatId) { el in
                                            if case .shape(var s) = el { s.fill = .gradient(SlideGradient(angle: 135, stops: ["accent", "accent2"])); return .shape(s) }
                                            return el
                                        }
                                    }
                                    Button("No fill") {
                                        updateSelectedElements(chatId: chatId) { el in
                                            if case .shape(var s) = el { s.fill = nil; return .shape(s) }
                                            return el
                                        }
                                    }
                                }
                                Section("Stroke") {
                                    Button("None") {
                                        updateSelectedElements(chatId: chatId) { el in
                                            if case .shape(var s) = el { s.stroke = nil; s.strokeWidth = 0; return .shape(s) }
                                            return el
                                        }
                                    }
                                    Button("Accent 4px") {
                                        updateSelectedElements(chatId: chatId) { el in
                                            if case .shape(var s) = el { s.stroke = "accent"; s.strokeWidth = 4; return .shape(s) }
                                            return el
                                        }
                                    }
                                    Button("Muted 3px") {
                                        updateSelectedElements(chatId: chatId) { el in
                                            if case .shape(var s) = el { s.stroke = "muted"; s.strokeWidth = 3; return .shape(s) }
                                            return el
                                        }
                                    }
                                }
                            } label: {
                                Label("Style", systemImage: "paintbrush").font(.system(size: 11))
                            }
                            .menuStyle(.borderlessButton)
                        }

                        // Arrange menu
                        Menu {
                            Button("Bring to front") { reorderSelected(.front, chatId: chatId) }
                            Button("Bring forward") { reorderSelected(.forward, chatId: chatId) }
                            Button("Send backward") { reorderSelected(.backward, chatId: chatId) }
                            Button("Send to back") { reorderSelected(.back, chatId: chatId) }
                            Divider()
                            Button("Align left") { alignSelected(.left, chatId: chatId) }
                            Button("Align center") { alignSelected(.center, chatId: chatId) }
                            Button("Align right") { alignSelected(.right, chatId: chatId) }
                            Button("Align top") { alignSelected(.top, chatId: chatId) }
                            Button("Align middle") { alignSelected(.middle, chatId: chatId) }
                            Button("Align bottom") { alignSelected(.bottom, chatId: chatId) }
                            if selected.count >= 3 {
                                Divider()
                                Button("Distribute horizontally") { distributeSelected(horizontal: true, chatId: chatId) }
                                Button("Distribute vertically") { distributeSelected(horizontal: false, chatId: chatId) }
                            }
                            Divider()
                            if selected.count >= 2 {
                                Button("Group") { groupSelected(chatId: chatId) }
                            }
                            if selected.contains(where: { if case .group = $0 { return true }; return false }) {
                                Button("Ungroup") { ungroupSelected(chatId: chatId) }
                            }
                            Button("Duplicate") { duplicateSelected(chatId: chatId) }
                            Button("Delete", role: .destructive) { deleteSelected(chatId: chatId) }
                        } label: {
                            Label("Arrange", systemImage: "square.stack.3d.up").font(.system(size: 11))
                        }
                        .menuStyle(.borderlessButton)
                    }
                } else if live {
                    ProgressView().controlSize(.mini)
                    Text("\(personaName) is editing\u{2026}").font(.system(size: 12)).foregroundStyle(p.secondaryText)
                }

                Spacer(minLength: 10)

                iconBtn("note.text", help: "Toggle speaker notes") { showNotes.toggle() }

                Text("v\(seq)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.tertiaryText)

                Menu {
                    Button("Export PDF\u{2026}") { Task { await exportPDF(deck: deck, title: title, chatId: chatId) } }
                    Button("Export PowerPoint (.pptx)\u{2026}") { Task { await exportPPTX(deck: deck, title: title, chatId: chatId) } }
                    Divider()
                    Button("Save PDF to Library") { Task { await saveExportToLibrary(deck: deck, title: title, kind: "pdf", chatId: chatId) } }
                    Button("Save PPTX to Library") { Task { await saveExportToLibrary(deck: deck, title: title, kind: "pptx", chatId: chatId) } }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)

                Button {
                    Task {
                        await saveNow(chatId: chatId)
                        context.navigate("/present/slides/\(canvasId)?slide=\(activeSlideIndex + 1)")
                    }
                } label: {
                    Label("Present", systemImage: "play.fill").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.vesper(.primary))
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
        .background(p.surface)
    }

    private func iconBtn(_ name: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12)).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Slide Thumbnails Sidebar

    @ViewBuilder
    private func slidesThumbnailsStrip(deck: SlideDeck, readOnly: Bool, chatId: String) -> some View {
        let p = theme.palette
        VStack(spacing: 0) {
            HStack {
                Text("SLIDES (\(deck.slides.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                if !readOnly {
                    Menu {
                        ForEach(SlideLayoutKind.allCases, id: \.self) { layout in
                            Button(layout.label) { addSlide(layout: layout, chatId: chatId) }
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add slide")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().overlay(p.border)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(deck.slides.enumerated()), id: \.offset) { idx, s in
                        let isActive = idx == clampedSlideIndex(activeSlideIndex, in: deck)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(isActive ? p.accent : p.tertiaryText)
                                if s.hidden == true {
                                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(p.tertiaryText)
                                }
                                Spacer()
                            }
                            SlidePreviewCanvas(deck: deck, slide: s, images: assetCache.images)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(isActive ? p.accent : p.border, lineWidth: isActive ? 2 : 1)
                                )
                                .opacity(s.hidden == true ? 0.5 : 1)
                        }
                        .padding(4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingTextId = nil
                            selectedIds = []
                            activeSlideIndex = idx
                        }
                        .contextMenu {
                            if !readOnly {
                                Button("Duplicate slide") { duplicateSlide(at: idx, chatId: chatId) }
                                Button(s.hidden == true ? "Show in presentation" : "Hide in presentation") {
                                    mutateDeck(chatId: chatId) { d in
                                        guard d.slides.indices.contains(idx) else { return }
                                        let was = d.slides[idx].hidden ?? false
                                        d.slides[idx].hidden = was ? nil : true
                                    }
                                }
                                if idx > 0 {
                                    Button("Move up") { moveSlide(from: idx, to: idx - 1, chatId: chatId) }
                                }
                                if idx + 1 < deck.slides.count {
                                    Button("Move down") { moveSlide(from: idx, to: idx + 1, chatId: chatId) }
                                }
                                if deck.slides.count > 1 {
                                    Divider()
                                    Button("Delete slide", role: .destructive) { deleteSlide(at: idx, chatId: chatId) }
                                }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Chrome (Full-Page Mode)

    private func publishChrome(
        title: String,
        seq: Int,
        chatId: String,
        personaName: String,
        live: Bool,
        readOnly: Bool,
        baseDeck: SlideDeck?,
        headDeck: SlideDeck?,
        headSeq: Int,
        reviewChanges: [SlideReviewChange]
    ) {
        var tabs: [InspectorTab] = [
            InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .native, busy: live)
        ]
        if !reviewChanges.isEmpty {
            let left = reviewChanges.filter { reviewDecisions[$0.id] == nil }.count
            tabs.append(InspectorTab(id: "review", label: "Review", icon: "check", kind: .native, badge: left > 0 ? NavBadge(text: "\(left)") : nil))
        }
        let activeTab = tabs.contains(where: { $0.id == activeInspectorTab }) ? activeInspectorTab : "chat"
        context.chrome = NativeChrome(
            title: title,
            subtitle: "Slides \u{00B7} v\(seq)",
            inspector: InspectorModel(id: "slides-\(canvasId)", open: inspectorOpen, activeTabId: activeTab, tabs: tabs)
        )
        if let deck {
            context.sidebarView = AnyView(slidesThumbnailsStrip(deck: deck, readOnly: readOnly, chatId: chatId))
        }
        context.inspectorView = { tabId in
            if tabId == "review", let baseDeck, let headDeck {
                return AnyView(
                    SlidesReviewInspectorView(
                        baseDeck: baseDeck,
                        headDeck: headDeck,
                        changes: reviewChanges,
                        decisions: reviewDecisions,
                        images: assetCache.images,
                        personaName: personaName,
                        busy: reviewBusy || readOnly,
                        error: reviewError,
                        onDecide: { id, d in
                            reviewDecisions[id] = d
                            if reviewDecisions.count >= reviewChanges.count {
                                finishSlideReview(decisions: reviewDecisions, base: baseDeck, head: headDeck, changes: reviewChanges, headSeq: headSeq, chatId: chatId, personaName: personaName)
                            }
                        },
                        onAcceptAll: {
                            var all: [Int: DocReviewDecision] = [:]
                            for c in reviewChanges { all[c.id] = .accept }
                            reviewDecisions = all
                            finishSlideReview(decisions: all, base: baseDeck, head: headDeck, changes: reviewChanges, headSeq: headSeq, chatId: chatId, personaName: personaName)
                        },
                        onRejectAll: {
                            var all: [Int: DocReviewDecision] = [:]
                            for c in reviewChanges { all[c.id] = .reject }
                            reviewDecisions = all
                            finishSlideReview(decisions: all, base: baseDeck, head: headDeck, changes: reviewChanges, headSeq: headSeq, chatId: chatId, personaName: personaName)
                        }
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
                        emptyDescription: "Ask \(personaName) to edit slides, rewrite copy, or redesign layouts.",
                        emptyButtonTitle: "Start a chat",
                        welcomeWhere: "Slides chat",
                        welcomeIntro: "Ask for new slides, tighter bullet points, or a visual refresh.",
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
            case .inspectorVisibility(let open): inspectorOpen = open
            case .inspectorSelectTab(let id): activeInspectorTab = id; inspectorOpen = true
            default: break
            }
        }
    }

    // MARK: - Deck Mutations, Undo/Redo, Autosave & 3-Way Merge

    private func syncFromServer(head: API.ChatCanvas) {
        guard let parsed = try? SlideSchema.parseDeck(head.body) else { return }
        if deck == nil {
            deck = parsed
            savedDeck = parsed
            savedSeq = head.seq
            saveState = .saved
            activeSlideIndex = min(activeSlideIndex, max(0, parsed.slides.count - 1))
            assetCache.ensureLoaded(canvasId: canvasId, assetIds: Array(parsed.assets.keys), client: context.store.client)
            return
        }
        guard head.seq > savedSeq else { return }
        if deck == savedDeck {
            deck = parsed
            savedDeck = parsed
            savedSeq = head.seq
            saveState = .saved
            activeSlideIndex = min(activeSlideIndex, max(0, parsed.slides.count - 1))
        } else if let base = savedDeck, let cur = deck, let merged = SlideReviewLogic.mergeDecks(base: base, mine: cur, theirs: parsed) {
            deck = merged
            savedDeck = parsed
            savedSeq = head.seq
            saveState = .unsaved
            activeSlideIndex = clampedSlideIndex(activeSlideIndex, in: merged)
        } else {
            conflictDeck = (parsed, head.seq)
            saveState = .conflict
        }
    }

    private func mutateDeck(chatId: String, _ edit: (inout SlideDeck) -> Void) {
        guard var current = deck else { return }
        let before = current
        edit(&current)
        guard current != before else { return }
        past.append(before)
        if past.count > 80 { past.removeFirst() }
        future.removeAll()
        deck = current
        scheduleAutosave(chatId: chatId)
    }

    private func undo(chatId: String) {
        guard let prev = past.popLast(), let cur = deck else { return }
        future.append(cur)
        deck = prev
        activeSlideIndex = min(activeSlideIndex, max(0, prev.slides.count - 1))
        scheduleAutosave(chatId: chatId)
    }

    private func redo(chatId: String) {
        guard let next = future.popLast(), let cur = deck else { return }
        past.append(cur)
        deck = next
        activeSlideIndex = min(activeSlideIndex, max(0, next.slides.count - 1))
        scheduleAutosave(chatId: chatId)
    }

    private func scheduleAutosave(chatId: String) {
        guard !chatId.isEmpty else { return }
        if saveState != .conflict { saveState = .unsaved }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await saveNow(chatId: chatId)
        }
    }

    private func saveNow(chatId: String, forceSeq: Int? = nil) async {
        guard !chatId.isEmpty, let cur = deck else { return }
        guard saveState != .conflict || forceSeq != nil else { return }
        if cur == savedDeck && forceSeq == nil {
            saveState = .saved
            return
        }
        guard let encoded = try? SlideSchema.encodeDeck(cur) else { return }
        let baseSeq = forceSeq ?? savedSeq
        saveState = .saving
        do {
            let v = try await context.store.mutate(
                API.saveChatCanvas(id: chatId, canvasId: canvasId, body: API.ChatCanvasSave(baseSeq: baseSeq, body: encoded, note: "Edited"))
            )
            savedSeq = v.seq
            savedDeck = cur
            saveState = deck == cur ? .saved : .unsaved
            _ = await context.store.refetch(canvasRequest(chatId: chatId))
        } catch APIError.http(status: 409, _) {
            let refreshed = await context.store.refetch(canvasRequest(chatId: chatId))
            if let fresh = refreshed.data,
               let theirs = try? SlideSchema.parseDeck(fresh.body) {
                if let base = savedDeck, let merged = SlideReviewLogic.mergeDecks(base: base, mine: cur, theirs: theirs) {
                    deck = merged
                    savedDeck = theirs
                    savedSeq = fresh.seq
                    activeSlideIndex = clampedSlideIndex(activeSlideIndex, in: merged)
                    await saveNow(chatId: chatId, forceSeq: fresh.seq)
                    return
                }
                conflictDeck = (theirs, fresh.seq)
            }
            saveState = .conflict
        } catch {
            saveState = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    // MARK: - Element & Slide Helpers

    private func addSlide(layout: SlideLayoutKind, chatId: String) {
        let s = SlideSchema.newSlide(layout: layout)
        mutateDeck(chatId: chatId) { d in
            let at = min(max(0, activeSlideIndex + 1), d.slides.count)
            d.slides.insert(s, at: at)
            activeSlideIndex = at
        }
        selectedIds = []
    }

    private func duplicateSlide(at idx: Int, chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard d.slides.indices.contains(idx) else { return }
            var copy = d.slides[idx]
            copy.id = SlideSchema.newId(prefix: "s")
            copy.elements = SlideArrangeLogic.duplicate(copy.elements, ids: Set(copy.elements.map(\.id)), offset: 0).elements.suffix(copy.elements.count).map { $0 }
            d.slides.insert(copy, at: idx + 1)
            activeSlideIndex = idx + 1
        }
    }

    private func moveSlide(from: Int, to: Int, chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard d.slides.indices.contains(from), d.slides.indices.contains(to) else { return }
            let s = d.slides.remove(at: from)
            d.slides.insert(s, at: to)
            activeSlideIndex = to
        }
    }

    private func deleteSlide(at idx: Int, chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard d.slides.count > 1, d.slides.indices.contains(idx) else { return }
            d.slides.remove(at: idx)
            activeSlideIndex = min(activeSlideIndex, d.slides.count - 1)
        }
        selectedIds = []
    }

    private func insertTextBox(chatId: String) {
        let el = SlideElement.text(SlideTextElement(
            id: SlideSchema.newId(prefix: "e"),
            frame: SlideFrame(x: 360, y: 380, w: 720, h: 160),
            paragraphs: [SlideParagraph(runs: [SlideRun(text: "Text", size: 48, color: "text", font: "body")])],
            valign: "top"
        ))
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            d.slides[clampedSlideIndex(activeSlideIndex, in: d)].elements.append(el)
        }
        selectedIds = [el.id]
        editingTextId = el.id
    }

    private func insertShape(_ kind: SlideShapeKind, chatId: String) {
        let el = SlideElement.shape(SlideShapeElement(
            id: SlideSchema.newId(prefix: "e"),
            frame: SlideFrame(x: 710, y: 390, w: 500, h: 300),
            shape: kind,
            fill: .solid("accent"),
            radius: kind == .roundRect ? 24 : nil
        ))
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            d.slides[clampedSlideIndex(activeSlideIndex, in: d)].elements.append(el)
        }
        selectedIds = [el.id]
    }

    private func insertLine(chatId: String) {
        let el = SlideElement.line(SlideLineElement(
            id: SlideSchema.newId(prefix: "e"),
            frame: SlideFrame(x: 560, y: 540, w: 800, h: 0),
            stroke: "accent",
            strokeWidth: 6,
            endArrow: true
        ))
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            d.slides[clampedSlideIndex(activeSlideIndex, in: d)].elements.append(el)
        }
        selectedIds = [el.id]
    }

    private func pickAndUploadImage(replacing slot: SlideElement?, chatId: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let client = context.store.client else { return }
        let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        Task {
            do {
                var form = APIMultipartForm()
                form.addFile("file", filename: url.lastPathComponent, contentType: mime, data: data)
                let asset = try await client.send(API.uploadDeckAsset(canvasId: canvasId, body: form))
                assetCache.store(assetId: asset.id, data: data)
                let frame = slot?.frame ?? SlideFrame(x: 460, y: 200, w: 1000, h: 680)
                let imgEl = SlideElement.image(SlideImageElement(
                    id: slot?.id ?? SlideSchema.newId(prefix: "e"),
                    frame: frame,
                    placeholder: slot?.placeholder,
                    asset: asset.id
                ))
                mutateDeck(chatId: chatId) { d in
                    guard !d.slides.isEmpty else { return }
                    let slideIdx = clampedSlideIndex(activeSlideIndex, in: d)
                    d.assets[asset.id] = SlideAsset(mime: asset.mime.rawValue, w: asset.w, h: asset.h)
                    if let slot, let idx = d.slides[slideIdx].elements.firstIndex(where: { $0.id == slot.id }) {
                        d.slides[slideIdx].elements[idx] = imgEl
                    } else {
                        d.slides[slideIdx].elements.append(imgEl)
                    }
                }
                selectedIds = [imgEl.id]
            } catch {
                notice = "Image upload failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
            }
        }
    }

    private func updateSelectedElements(chatId: String, _ fn: (SlideElement) -> SlideElement) {
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            d.slides[idx].elements = SlideArrangeLogic.mapDeep(d.slides[idx].elements, ids: selectedIds, fn)
        }
    }

    private func updateSelectedParagraphs(chatId: String, _ fn: (inout SlideParagraph) -> Void) {
        updateSelectedElements(chatId: chatId) { el in
            guard let tb = el.textBox else { return el }
            let paras = tb.paragraphs.map { p -> SlideParagraph in
                var copy = p; fn(&copy); return copy
            }
            return el.withText(paras)
        }
    }

    private func updateSelectedRuns(chatId: String, _ fn: (inout SlideRun) -> Void) {
        updateSelectedParagraphs(chatId: chatId) { p in
            p.runs = p.runs.map { r in var copy = r; fn(&copy); return copy }
        }
    }

    private func toggleTextMark(_ kp: WritableKeyPath<SlideRun, Bool?>, chatId: String) {
        let firstVal = currentSlide?.elements
            .first(where: { selectedIds.contains($0.id) })?
            .textBox?.paragraphs.first?.runs.first?[keyPath: kp] ?? false
        let next: Bool? = firstVal ? nil : true
        updateSelectedRuns(chatId: chatId) { $0[keyPath: kp] = next }
    }

    private func reorderSelected(_ op: SlideZOrder, chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            d.slides[idx].elements = SlideArrangeLogic.reorder(d.slides[idx].elements, ids: selectedIds, op: op)
        }
    }

    private func alignSelected(_ op: SlideAlignOp, chatId: String) {
        guard let slide = currentSlide, let deck else { return }
        let frames = Dictionary(
            slide.elements.filter { selectedIds.contains($0.id) }.map { ($0.id, $0.frame) },
            uniquingKeysWith: { _, latest in latest }
        )
        let target: SlideBox = frames.count >= 2
            ? (SlideArrangeLogic.unionBox(Array(frames.values)) ?? SlideBox(l: 0, t: 0, r: deck.size.w, b: deck.size.h))
            : SlideBox(l: 0, t: 0, r: deck.size.w, b: deck.size.h)
        let aligned = SlideArrangeLogic.align(frames, op: op, to: target)
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            d.slides[idx].elements = d.slides[idx].elements.map { el in
                aligned[el.id].map { SlideArrangeLogic.withFrame(el, frame: $0) } ?? el
            }
        }
    }

    private func distributeSelected(horizontal: Bool, chatId: String) {
        guard let slide = currentSlide else { return }
        let frames = Dictionary(
            slide.elements.filter { selectedIds.contains($0.id) }.map { ($0.id, $0.frame) },
            uniquingKeysWith: { _, latest in latest }
        )
        let dist = SlideArrangeLogic.distribute(frames, horizontal: horizontal)
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            d.slides[idx].elements = d.slides[idx].elements.map { el in
                dist[el.id].map { SlideArrangeLogic.withFrame(el, frame: $0) } ?? el
            }
        }
    }

    private func groupSelected(chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            if let res = SlideArrangeLogic.groupElements(d.slides[idx].elements, ids: selectedIds) {
                d.slides[idx].elements = res.elements
                selectedIds = [res.id]
            }
        }
    }

    private func ungroupSelected(chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            let res = SlideArrangeLogic.ungroupElements(d.slides[idx].elements, ids: selectedIds)
            d.slides[idx].elements = res.elements
            if !res.ids.isEmpty { selectedIds = Set(res.ids) }
        }
    }

    private func duplicateSelected(chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            let res = SlideArrangeLogic.duplicate(d.slides[idx].elements, ids: selectedIds)
            d.slides[idx].elements = res.elements
            if !res.ids.isEmpty { selectedIds = Set(res.ids) }
        }
    }

    private func deleteSelected(chatId: String) {
        mutateDeck(chatId: chatId) { d in
            guard !d.slides.isEmpty else { return }
            let idx = clampedSlideIndex(activeSlideIndex, in: d)
            d.slides[idx].elements = SlideArrangeLogic.removeDeep(d.slides[idx].elements, ids: selectedIds)
        }
        selectedIds = []
    }

    private func saveCustomTheme(_ nextTheme: SlideTheme, chatId: String) async {
        mutateDeck(chatId: chatId) { $0.theme = nextTheme }
        let input = API.SlideThemeInput(
            colors: API.SlideThemeColors(
                accent: nextTheme.colors.accent,
                accent2: nextTheme.colors.accent2,
                background: nextTheme.colors.background,
                heading: nextTheme.colors.heading,
                muted: nextTheme.colors.muted,
                surface: nextTheme.colors.surface,
                text: nextTheme.colors.text
            ),
            fonts: API.SlideThemeFonts(
                body: API.SlideThemeFonts.Body(rawValue: nextTheme.fonts.body.rawValue),
                heading: API.SlideThemeFonts.Heading(rawValue: nextTheme.fonts.heading.rawValue)
            ),
            name: nextTheme.name
        )
        _ = try? await context.store.mutate(API.createSlideTheme(body: input))
        _ = await context.store.refetch(savedThemesRequest)
    }

    // MARK: - Review Resolution

    private func finishSlideReview(
        decisions: [Int: DocReviewDecision],
        base: SlideDeck,
        head: SlideDeck,
        changes: [SlideReviewChange],
        headSeq: Int,
        chatId: String,
        personaName: String
    ) {
        let allAccepted = changes.allSatisfy { decisions[$0.id] == .accept }
        Task {
            reviewBusy = true
            reviewError = nil
            defer { reviewBusy = false }
            do {
                if allAccepted {
                    _ = try await context.store.mutate(API.markDocReviewed(canvasId: canvasId, body: API.MarkDocReviewedBody(seq: headSeq)))
                } else {
                    let resolved = SlideReviewLogic.resolveDeck(base: base, head: head, changes: changes, decisions: decisions)
                    let encoded = try SlideSchema.encodeDeck(resolved)
                    let kept = changes.filter { decisions[$0.id] != .reject }.count
                    let note = kept == 0 ? "Rejected \(personaName)'s changes" : "Kept \(kept) of \(personaName)'s \(changes.count) changes"
                    let v = try await context.store.mutate(
                        API.saveChatCanvas(id: chatId, canvasId: canvasId, body: API.ChatCanvasSave(baseSeq: headSeq, body: encoded, note: note))
                    )
                    self.deck = resolved
                    self.savedDeck = resolved
                    self.savedSeq = v.seq
                    self.activeSlideIndex = clampedSlideIndex(activeSlideIndex, in: resolved)
                }
                reviewDecisions = [:]
                _ = await context.store.refetch(refRequest)
                if !chatId.isEmpty { _ = await context.store.refetch(canvasRequest(chatId: chatId)) }
            } catch {
                reviewError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    // MARK: - Exports

    private func exportPDF(deck: SlideDeck, title: String, chatId: String) async {
        await saveNow(chatId: chatId)
        let data = SlideExporters.exportPDF(deck: deck, images: assetCache.images)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DocEditorLogic.sanitizedFileName(title, ext: "pdf")
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
        context.showToast(ToastItemModel(id: "slides.pdf", title: "Saved \(url.lastPathComponent)", tone: .success))
    }

    private func exportPPTX(deck: SlideDeck, title: String, chatId: String) async {
        await saveNow(chatId: chatId)
        let data = SlideExporters.exportPPTX(deck: deck, assetBytes: assetCache.rawBytes)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DocEditorLogic.sanitizedFileName(title, ext: "pptx")
        panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
        context.showToast(ToastItemModel(id: "slides.pptx", title: "Saved \(url.lastPathComponent)", tone: .success))
    }

    private func saveExportToLibrary(deck: SlideDeck, title: String, kind: String, chatId: String) async {
        await saveNow(chatId: chatId)
        guard let client = context.store.client else { return }
        let isPdf = kind == "pdf"
        let bytes = isPdf
            ? SlideExporters.exportPDF(deck: deck, images: assetCache.images)
            : SlideExporters.exportPPTX(deck: deck, assetBytes: assetCache.rawBytes)
        let name = DocEditorLogic.sanitizedFileName(title, ext: kind)
        let mime = isPdf ? "application/pdf" : "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        var form = APIMultipartForm()
        form.addFile("file", filename: name, contentType: mime, data: bytes)
        do {
            _ = try await client.send(API.saveDeckExportToLibrary(canvasId: canvasId, body: form))
            context.showToast(ToastItemModel(id: "slides.lib", title: "Saved \(name) to Library", tone: .success))
        } catch {
            notice = "Saving to Library failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }
}

// MARK: - Theme Editor Sheet

private struct SlideThemeEditorSheet: View {
    @State var themeDraft: SlideTheme
    let onApplyToDeck: (SlideTheme) -> Void
    let onSaveCustom: (SlideTheme) -> Void
    let onCancel: () -> Void

    init(initial: SlideTheme, onApplyToDeck: @escaping (SlideTheme) -> Void, onSaveCustom: @escaping (SlideTheme) -> Void, onCancel: @escaping () -> Void) {
        _themeDraft = State(initialValue: initial)
        self.onApplyToDeck = onApplyToDeck
        self.onSaveCustom = onSaveCustom
        self.onCancel = onCancel
    }

    var body: some View {
        let issues = SlideSchema.contrastIssues(in: themeDraft)
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Slide Theme").font(.system(size: 15, weight: .semibold))
            TextField("Theme name", text: $themeDraft.name).textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Picker("Heading font", selection: $themeDraft.fonts.heading) {
                    ForEach(SlideFontSlot.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Body font", selection: $themeDraft.fonts.body) {
                    ForEach(SlideFontSlot.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(SlideThemeColorKey.allCases, id: \.self) { key in
                    GridRow {
                        Text(key.rawValue.capitalized).font(.system(size: 12))
                        TextField("#RRGGBB", text: Binding(
                            get: { themeDraft.colors[key] },
                            set: { themeDraft.colors[key] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 110)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(cgColor: SlideCGDrawer.cgColor(themeDraft.colors[key])))
                            .frame(width: 24, height: 20)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
                    }
                }
            }

            if !issues.isEmpty {
                Label("\(issues.count) colour pair(s) below WCAG AA (4.5:1) contrast.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel", action: onCancel).buttonStyle(.vesper(.outline))
                Spacer()
                Button("Apply to deck") { onApplyToDeck(themeDraft) }.buttonStyle(.vesper(.outline))
                Button("Save as reusable theme") { onSaveCustom(themeDraft) }.buttonStyle(.vesper(.primary))
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: - Slides Review Inspector

private struct SlidesReviewInspectorView: View {
    @Environment(\.vesperTheme) private var theme
    let baseDeck: SlideDeck
    let headDeck: SlideDeck
    let changes: [SlideReviewChange]
    let decisions: [Int: DocReviewDecision]
    let images: [String: CGImage]
    let personaName: String
    let busy: Bool
    let error: String?
    let onDecide: (Int, DocReviewDecision) -> Void
    let onAcceptAll: () -> Void
    let onRejectAll: () -> Void

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(personaName) suggested \(changes.count) \(changes.count == 1 ? "change" : "changes")")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Button("Reject all", action: onRejectAll).buttonStyle(.vesper(.outline)).disabled(busy)
                    Button("Accept all", action: onAcceptAll).buttonStyle(.vesper(.primary)).disabled(busy)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                ForEach(changes) { c in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(c.kind == .theme ? "Theme" : "Slide \(c.position)") \u{00B7} \(c.title)")
                            .font(.system(size: 12, weight: .semibold))
                        if let after = c.after {
                            SlidePreviewCanvas(deck: headDeck, slide: after, images: images)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.border))
                        }
                        ForEach(c.details, id: \.self) { line in
                            Text("\u{2022} \(line)").font(.system(size: 11)).foregroundStyle(p.secondaryText)
                        }
                        HStack(spacing: 6) {
                            if let d = decisions[c.id] {
                                Text(d == .accept ? "Accepted" : "Rejected").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                            } else {
                                Button("Reject") { onDecide(c.id, .reject) }.buttonStyle(.vesper(.outline)).disabled(busy)
                                Button("Accept") { onDecide(c.id, .accept) }.buttonStyle(.vesper(.primary)).disabled(busy)
                            }
                        }
                    }
                    .padding(10)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Full-Screen Native Slides Presenter (/present/slides/:id)

struct SlidesPresentScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var index: Int = 0
    @State private var showControls = true
    @State private var showHelp = false
    @State private var showNotes = false
    @State private var digitBuffer = ""
    @State private var assetCache = SlideAssetCache()
    @State private var keyMonitor: Any?

    private var canvasId: String { context.match.params["id"] ?? "" }
    private var refRequest: APIRequest<API.MyCanvas> { API.getMyCanvas(canvasId: canvasId) }
    private func canvasRequest(chatId: String) -> APIRequest<API.ChatCanvas> { API.getChatCanvas(id: chatId, canvasId: canvasId) }

    var body: some View {
        let ref = context.store.entry(refRequest).data
        let chatId = ref?.chatId ?? ""
        let canvas = chatId.isEmpty ? nil : context.store.entry(canvasRequest(chatId: chatId)).data
        let deck = canvas.flatMap { try? SlideSchema.parseDeck($0.body) }
        let shown = deck?.slides.filter { !($0.hidden ?? false) } ?? []
        let clamped = min(max(0, index), max(0, shown.count - 1))
        let slide = shown.indices.contains(clamped) ? shown[clamped] : nil

        ZStack {
            Color.black.ignoresSafeArea()

            if let deck, let slide {
                SlidePreviewCanvas(deck: deck, slide: slide, images: assetCache.images)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .onTapGesture {
                        if clamped + 1 < shown.count { index = clamped + 1 }
                    }
            } else if deck != nil {
                Text("Every slide in this deck is hidden.").foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }

            if showHelp {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keyboard").font(.system(size: 14, weight: .semibold))
                    ForEach([
                        ("→ ↓ Space PgDn", "Next slide"),
                        ("← ↑ PgUp", "Previous slide"),
                        ("Home / End", "First / last"),
                        ("3 then Enter", "Go to slide 3"),
                        ("N", "Speaker notes"),
                        ("F", "Toggle fullscreen"),
                        ("Esc", "Exit to editor"),
                    ], id: \.0) { k, d in
                        HStack {
                            Text(k).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer(minLength: 16)
                            Text(d).font(.system(size: 12))
                        }
                    }
                }
                .padding(16)
                .frame(width: 280)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(20)
            }

            if showNotes, let notes = slide?.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SPEAKER NOTES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView { Text(notes).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 140)
                }
                .padding(14)
                .frame(width: 440)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(20)
            }

            if showControls || showHelp {
                HStack(spacing: 8) {
                    Button { index = max(0, clamped - 1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .disabled(clamped == 0)
                    Text(shown.isEmpty ? "–" : "\(clamped + 1) / \(shown.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 54)
                    Button { index = min(max(0, shown.count - 1), clamped + 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                        .disabled(clamped + 1 >= shown.count)
                    Divider().frame(height: 16)
                    Button { showNotes.toggle() } label: { Image(systemName: "note.text") }.buttonStyle(.borderless)
                    Button { context.window()?.window?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless)
                    Button { showHelp.toggle() } label: { Text("?").font(.system(size: 12, weight: .semibold)) }.buttonStyle(.borderless)
                    Button("Exit") {
                        exitPresenter(deck: deck, currentSlide: slide)
                    }
                    .buttonStyle(.vesper(.outline))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
            }
        }
        .onHover { _ in showControls = true }
        .task(id: canvasId) {
            index = max(0, (Int(context.match.query["slide"] ?? "1") ?? 1) - 1)
            context.chrome = NativeChrome(title: ref?.title ?? "Present")
            context.store.observe(refRequest)
            context.store.load(refRequest)
        }
        .task(id: chatId) {
            guard !chatId.isEmpty else { return }
            context.store.observe(canvasRequest(chatId: chatId))
            context.store.load(canvasRequest(chatId: chatId))
        }
        .onChange(of: deck?.assets.keys.sorted().joined(separator: ",")) { _, _ in
            if let deck { assetCache.ensureLoaded(canvasId: canvasId, assetIds: Array(deck.assets.keys), client: context.store.client) }
        }
        .onAppear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                handleKey(ev, deck: deck, shown: shown, clamped: clamped)
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            context.store.stopObserving(refRequest.key)
            if !chatId.isEmpty { context.store.stopObserving(canvasRequest(chatId: chatId).key) }
        }
    }

    private func exitPresenter(deck: SlideDeck?, currentSlide: Slide?) {
        let editorIdx = (deck?.slides.firstIndex(where: { $0.id == currentSlide?.id }) ?? 0) + 1
        context.navigate("/apps/slides/\(canvasId)?slide=\(editorIdx)")
    }

    private func handleKey(_ ev: NSEvent, deck: SlideDeck?, shown: [Slide], clamped: Int) -> NSEvent? {
        if ev.modifierFlags.contains(.command) || ev.modifierFlags.contains(.control) || ev.modifierFlags.contains(.option) {
            return ev
        }
        showControls = true
        if let chars = ev.charactersIgnoringModifiers, chars.count == 1, let ch = chars.first, ch.isNumber {
            digitBuffer = String((digitBuffer + chars).suffix(3))
            return nil
        }
        if ev.keyCode == 36, !digitBuffer.isEmpty, let target = Int(digitBuffer) { // Return
            index = max(0, min(max(0, shown.count - 1), target - 1))
            digitBuffer = ""
            return nil
        }
        digitBuffer = ""
        switch ev.keyCode {
        case 124, 125, 121, 49: // Right, Down, PgDn, Space
            index = min(max(0, shown.count - 1), clamped + 1)
            return nil
        case 123, 126, 116: // Left, Up, PgUp
            index = max(0, clamped - 1)
            return nil
        case 115: // Home
            index = 0
            return nil
        case 119: // End
            index = max(0, shown.count - 1)
            return nil
        case 53: // Escape
            if showHelp { showHelp = false }
            else { exitPresenter(deck: deck, currentSlide: shown.indices.contains(clamped) ? shown[clamped] : nil) }
            return nil
        default:
            break
        }
        switch ev.charactersIgnoringModifiers?.lowercased() {
        case "f": context.window()?.window?.toggleFullScreen(nil); return nil
        case "n": showNotes.toggle(); return nil
        case "?": showHelp.toggle(); return nil
        default: return ev
        }
    }
}
