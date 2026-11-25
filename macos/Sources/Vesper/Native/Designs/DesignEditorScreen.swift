import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

// MARK: - Full-Page Route Screen (/apps/designs/:id)

struct DesignEditorScreen: View {
    @Environment(NativeScreenContext.self) private var context

    private var canvasId: String { context.match.params["id"] ?? "" }
    private var initialReviewing: Bool { context.match.query["review"] == "1" }

    var body: some View {
        DesignEditorView(canvasId: canvasId, embedded: false, initialReviewing: initialReviewing)
            .id(canvasId)
    }
}

// MARK: - Reusable Native Designs Editor View (Full-Page, Embedded Knowledge & Beside-Chat)

struct DesignEditorView: View {
    private enum SaveState: Equatable { case saved, unsaved, saving, conflict, error(String) }
    private enum ReviewViewMode: String, CaseIterable { case overlay = "Overlay", after = "After", before = "Before" }

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let canvasId: String
    let embedded: Bool
    var initialReviewing: Bool = false

    @State private var design: DesignDocument?
    @State private var savedDesign: DesignDocument?
    @State private var savedSeq: Int = 0
    @State private var past: [DesignDocument] = []
    @State private var future: [DesignDocument] = []
    @State private var saveState: SaveState = .saved
    @State private var conflictState: (theirs: DesignDocument, seq: Int)?
    @State private var autosaveTask: Task<Void, Never>?

    @State private var activePageId: String = ""
    @State private var selectedIds: [String] = []
    @State private var tool: DesignTool = .select
    @State private var camera: DesignCamera = .initial
    @State private var hasFittedCamera = false
    @State private var viewportSize: CGSize = CGSize(width: 1000, height: 700)
    @State private var editingNodeId: String?
    @State private var assetCache = DesignAssetCache()
    @State private var notice: String?

    // Inspector & Review
    @State private var inspectorOpen = true
    @State private var activeInspectorTab = "design"
    @State private var inspectTarget: DesignInspectTarget = .react
    @State private var reviewing = false
    @State private var reviewMode: ReviewViewMode = .after
    @State private var reviewDecisions: [Int: DesignOpDecision] = [:]
    @State private var resolvingProposal = false
    @State private var resolveError: String?

    private var refRequest: APIRequest<API.Design> { API.getDesign(canvasId: canvasId) }
    private func versionRequest(seq: Int) -> APIRequest<API.DesignVersion> { API.getDesignVersion(canvasId: canvasId, seq: seq) }
    private func chatRequest(_ chatId: String) -> APIRequest<API.ChatSession> { API.getChat(id: chatId) }
    private var proposalsRequest: APIRequest<API.ListDesignProposalsResponse> { API.listDesignProposals(canvasId: canvasId, status: .pending) }

    private var activePage: DesignPage? {
        guard let d = design else { return nil }
        return d.pages.first { $0.id == activePageId } ?? d.pages.first
    }

    var body: some View {
        let p = theme.palette
        let refEntry = context.store.entry(refRequest)
        let ref = refEntry.data
        let chatId = ref?.chatId ?? ""
        let chat = chatId.isEmpty ? nil : context.store.entry(chatRequest(chatId)).data
        let headSeq = ref?.seq ?? 0
        let versionEntry = headSeq > 0 ? context.store.entry(versionRequest(seq: headSeq)) : nil
        let proposals = (context.store.entry(proposalsRequest).data?.proposals ?? []).sorted { $0.createdAt < $1.createdAt }
        let activeProposal = proposals.first
        let personaName = chat?.speaker?.name ?? chat?.persona?.name ?? "Assistant"
        let live = chat?.state == .running
        let paused = ref?.settings.personaPaused ?? false
        let directEdit = ref?.settings.directEdit ?? false
        let readOnly = (chat?.archived ?? false) || reviewing
        let title = ref?.title ?? "Design"

        let reviewChanges: [DesignReviewChange] = {
            guard let base = design, let prop = activeProposal else { return [] }
            return DesignReviewLogic.classify(before: base, ops: prop.ops, deps: prop.deps)
        }()

        let shownDesign: DesignDocument? = {
            guard let base = design else { return nil }
            if reviewing, let prop = activeProposal, reviewMode != .before {
                return DesignReviewLogic.applyOps(base, ops: prop.ops) { i in
                    reviewDecisions[i]?.state != .rejected
                }
            }
            return base
        }()

        let shownPage: DesignPage? = {
            guard let sd = shownDesign else { return nil }
            return sd.pages.first { $0.id == activePageId } ?? sd.pages.first
        }()

        let laidPage: DesignLaidPage? = {
            guard let sd = shownDesign, let sp = shownPage else { return nil }
            return DesignLayoutEngine(design: sd).layoutPage(sp)
        }()

        VStack(spacing: 0) {
            if let err = refEntry.error ?? versionEntry?.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(p.tertiaryText)
                    Text("Couldn\u{2019}t open this design").font(.system(size: 14, weight: .semibold))
                    Text(err.userMessage).font(.system(size: 12)).foregroundStyle(p.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let shownDesign, let shownPage, let laidPage {
                topBar(
                    title: title,
                    seq: savedSeq,
                    design: shownDesign,
                    page: shownPage,
                    laid: laidPage,
                    proposalCount: proposals.count,
                    paused: paused,
                    live: live,
                    personaName: personaName,
                    readOnly: readOnly
                )
                Divider().overlay(p.border)

                if let notice {
                    HStack {
                        Text(notice).font(.system(size: 12))
                        Spacer()
                        Button("Dismiss") { self.notice = nil }.buttonStyle(.borderless).font(.system(size: 11))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6).background(p.surface)
                    Divider().overlay(p.border)
                }

                if saveState == .conflict, let c = conflictState {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("This design changed while you were editing.").font(.system(size: 12))
                        Spacer()
                        Button("Use latest") {
                            design = c.theirs
                            savedDesign = c.theirs
                            savedSeq = c.seq
                            conflictState = nil
                            saveState = .saved
                        }.buttonStyle(.vesper(.outline))
                        Button("Keep mine") {
                            savedSeq = c.seq
                            conflictState = nil
                            saveState = .unsaved
                            Task { await saveNow(forceSeq: c.seq) }
                        }.buttonStyle(.vesper(.primary))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Color.orange.opacity(0.1))
                    Divider().overlay(p.border)
                }

                HStack(spacing: 0) {
                    if embedded {
                        DesignLayersSidebarView(
                            design: shownDesign,
                            activePageId: shownPage.id,
                            selectedIds: $selectedIds,
                            readOnly: readOnly,
                            onSelectPage: { pid in activePageId = pid; selectedIds = []; hasFittedCamera = false },
                            onAddPage: { addPage() },
                            onToggleVisible: { id in toggleNodeVisible(id) },
                            onToggleLocked: { id in toggleNodeLocked(id) }
                        )
                        .frame(width: 200)
                        .background(p.surface)
                        Divider().overlay(p.border)
                    }

                    ZStack {
                        InteractiveDesignCanvas(
                            design: shownDesign,
                            page: shownPage,
                            laid: laidPage,
                            images: assetCache.images,
                            readOnly: readOnly,
                            showPrototypeWires: activeInspectorTab == "prototype",
                            reviewChanges: reviewing ? reviewChanges : [],
                            selectedIds: $selectedIds,
                            tool: $tool,
                            camera: $camera,
                            editingNodeId: $editingNodeId,
                            onCommitDesign: { nextDoc in commitDesign(nextDoc) },
                            onViewportChange: { sz in
                                viewportSize = sz
                                if !hasFittedCamera && sz.width > 40 {
                                    hasFittedCamera = true
                                    camera = DesignCamera.fit(box: laidPage.box, viewport: sz)
                                }
                            }
                        )

                        // Review mode pill at top
                        if reviewing, activeProposal != nil {
                            HStack(spacing: 8) {
                                Picker("", selection: $reviewMode) {
                                    ForEach(ReviewViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                                Button("Done") { reviewing = false }
                                    .buttonStyle(.vesper(.outline))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                        }

                        // Bottom floating tool dock + zoom pill
                        HStack {
                            Spacer(minLength: 0)
                            HStack(spacing: 2) {
                                ForEach(DesignTool.allCases) { t in
                                    Button {
                                        tool = t
                                    } label: {
                                        Image(systemName: t.systemImage)
                                            .font(.system(size: 12))
                                            .frame(width: 28, height: 28)
                                            .background(tool == t ? p.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                            .foregroundStyle(tool == t ? Color.white : p.text)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(readOnly && t != .select && t != .hand)
                                    .help(t.label)
                                }
                                Divider().frame(height: 16).padding(.horizontal, 2)
                                Button { pickAndUploadImage(pageId: shownPage.id) } label: {
                                    Image(systemName: "photo.badge.plus").font(.system(size: 12)).frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .disabled(readOnly)
                                .help("Add image")
                            }
                            .padding(4)
                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)

                            Spacer(minLength: 0)

                            HStack(spacing: 4) {
                                Button { zoomBy(0.8) } label: { Image(systemName: "minus").font(.system(size: 10)).frame(width: 20, height: 20) }.buttonStyle(.borderless)
                                Button("\(Int((camera.z * 100).rounded()))%") {
                                    camera = DesignCamera.fit(box: laidPage.box, viewport: viewportSize)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(minWidth: 42)
                                Button { zoomBy(1.25) } label: { Image(systemName: "plus").font(.system(size: 10)).frame(width: 20, height: 20) }.buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView("Loading design\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(p.background)
        .task(id: canvasId) {
            reviewing = initialReviewing
            context.store.observe(refRequest)
            context.store.observe(proposalsRequest)
            context.store.load(refRequest)
            context.store.load(proposalsRequest)
        }
        .task(id: headSeq) {
            guard headSeq > 0 else { return }
            context.store.load(versionRequest(seq: headSeq))
        }
        .task(id: chatId) {
            guard !chatId.isEmpty else { return }
            context.store.observe(chatRequest(chatId))
            context.store.load(chatRequest(chatId))
        }
        .onChange(of: versionEntry?.data?.seq) { _, _ in
            if let v = versionEntry?.data { syncFromServer(version: v) }
        }
        .onChange(of: design?.assets.keys.sorted().joined(separator: ",")) { _, _ in
            if let d = design { assetCache.ensureLoaded(canvasId: canvasId, assetIds: Array(d.assets.keys), client: context.store.client) }
        }
        .onChange(of: "\(title)|\(savedSeq)|\(activePageId)|\(selectedIds.joined(separator: ","))|\(proposals.count)|\(reviewing)|\(inspectorOpen)|\(activeInspectorTab)|\(inspectTarget.rawValue)|\(directEdit)|\(paused)") { _, _ in
            guard !embedded else { return }
            publishChrome(
                title: title, seq: savedSeq, chatId: chatId, personaName: personaName, live: live,
                readOnly: readOnly, directEdit: directEdit, paused: paused,
                shownDesign: shownDesign, shownPage: shownPage, laidPage: laidPage,
                activeProposal: activeProposal, reviewChanges: reviewChanges, proposalCount: proposals.count
            )
        }
        .onAppear {
            if let v = versionEntry?.data { syncFromServer(version: v) }
            if !embedded {
                publishChrome(
                    title: title, seq: savedSeq, chatId: chatId, personaName: personaName, live: live,
                    readOnly: readOnly, directEdit: directEdit, paused: paused,
                    shownDesign: shownDesign, shownPage: shownPage, laidPage: laidPage,
                    activeProposal: activeProposal, reviewChanges: reviewChanges, proposalCount: proposals.count
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
            context.store.stopObserving(proposalsRequest.key)
            if !chatId.isEmpty { context.store.stopObserving(chatRequest(chatId).key) }
        }
    }

    // MARK: - Top Action Bar

    @ViewBuilder
    private func topBar(
        title: String,
        seq: Int,
        design: DesignDocument,
        page: DesignPage,
        laid: DesignLaidPage,
        proposalCount: Int,
        paused: Bool,
        live: Bool,
        personaName: String,
        readOnly: Bool
    ) -> some View {
        let p = theme.palette
        HStack(spacing: 8) {
            if !readOnly {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 12)) }
                    .buttonStyle(.borderless).disabled(past.isEmpty).help("Undo")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 12)) }
                    .buttonStyle(.borderless).disabled(future.isEmpty).help("Redo")
                Divider().frame(height: 16)

                Menu {
                    ForEach(DesignEditLogic.presets) { preset in
                        Button("\(preset.label) (\(Int(preset.w))×\(Int(preset.h)))") {
                            let b = DesignBox(x: DesignSchema.round2(laid.box.x + laid.box.w + 80), y: DesignSchema.round2(laid.box.y), w: preset.w, h: preset.h)
                            let frame = DesignEditLogic.newFrame(b, preset: preset.id, name: preset.label)
                            commitDesign(DesignLayoutEngine.settle(DesignEditLogic.insertNodes(design, parent: page.id, nodes: [frame])))
                            selectedIds = [frame.id]
                        }
                    }
                } label: {
                    Label("Add Frame", systemImage: "iphone").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)

                if !selectedIds.isEmpty {
                    Divider().frame(height: 16)
                    Button { duplicateSelected() } label: { Image(systemName: "plus.square.on.square").font(.system(size: 12)) }.buttonStyle(.borderless).help("Duplicate")
                    if selectedIds.count >= 2 {
                        Button { groupSelected() } label: { Image(systemName: "rectangle.3.group").font(.system(size: 12)) }.buttonStyle(.borderless).help("Group")
                    }
                    Button { deleteSelected() } label: { Image(systemName: "trash").font(.system(size: 12)) }.buttonStyle(.borderless).help("Delete")
                }
            }

            Spacer(minLength: 8)

            if live {
                ProgressView().controlSize(.mini)
                Text("\(personaName) working\u{2026}").font(.system(size: 11)).foregroundStyle(p.secondaryText)
            }

            if proposalCount > 0 && !reviewing {
                Button("Review \(proposalCount)") {
                    reviewing = true
                    activeInspectorTab = "review"
                    inspectorOpen = true
                }
                .buttonStyle(.vesper(.primary))
            }

            Button {
                commitDesign(DesignDocument(
                    schema: design.schema,
                    mode: design.mode == .dark ? .light : .dark,
                    tokensRef: design.tokensRef,
                    tokenSets: design.tokenSets,
                    assets: design.assets,
                    pages: design.pages,
                    links: design.links
                ))
            } label: {
                Image(systemName: design.mode == .dark ? "moon.fill" : "sun.max.fill").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Toggle design dark/light mode")

            Text("v\(seq)").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.tertiaryText)

            Menu {
                Button("Export PNG (1×)\u{2026}") { Task { await exportPNG(page: page, scale: 1, title: title) } }
                Button("Export PNG (2×)\u{2026}") { Task { await exportPNG(page: page, scale: 2, title: title) } }
                Button("Export SVG\u{2026}") { exportSVG(laid: laid, title: title) }
                Button("Export PDF\u{2026}") { exportPDF(laid: laid, title: title) }
                Divider()
                Button("Save PDF to Library") { Task { await savePDFToLibrary(laid: laid, title: title) } }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)

            if embedded {
                Button("Open") {
                    context.navigate("/apps/designs/\(canvasId)\(reviewing ? "?review=1" : "")")
                }
                .buttonStyle(.vesper(.outline))
            }

            Button {
                Task {
                    await saveNow()
                    let startParam = selectedIds.first.map { "&start=\($0)" } ?? ""
                    context.navigate("/present/designs/\(canvasId)?page=\(page.id)\(startParam)")
                }
            } label: {
                Label("Present", systemImage: "play.fill").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.vesper(.primary))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(p.surface)
    }

    // MARK: - Chrome (Full-Page Sidebar + Right Inspector Tabs)

    private func publishChrome(
        title: String,
        seq: Int,
        chatId: String,
        personaName: String,
        live: Bool,
        readOnly: Bool,
        directEdit: Bool,
        paused: Bool,
        shownDesign: DesignDocument?,
        shownPage: DesignPage?,
        laidPage: DesignLaidPage?,
        activeProposal: API.DesignProposal?,
        reviewChanges: [DesignReviewChange],
        proposalCount: Int
    ) {
        var tabs: [InspectorTab] = [
            InspectorTab(id: "design", label: "Design", icon: "sliders", kind: .native),
            InspectorTab(id: "prototype", label: "Prototype", icon: "play", kind: .native),
            InspectorTab(id: "inspect", label: "Inspect", icon: "code", kind: .native),
            InspectorTab(id: "chat", label: "Chat", icon: "msg", kind: .native, busy: live),
        ]
        if proposalCount > 0 || reviewing {
            tabs.append(InspectorTab(id: "review", label: "Review", icon: "check", kind: .native, badge: proposalCount > 0 ? NavBadge(text: "\(proposalCount)") : nil))
        }
        let activeTab = tabs.contains(where: { $0.id == activeInspectorTab }) ? activeInspectorTab : "design"
        context.chrome = NativeChrome(
            title: title,
            subtitle: "Designs \u{00B7} v\(seq)",
            inspector: InspectorModel(id: "design-\(canvasId)", open: inspectorOpen, activeTabId: activeTab, tabs: tabs)
        )
        if let shownDesign, let shownPage {
            context.sidebarView = AnyView(
                DesignLayersSidebarView(
                    design: shownDesign,
                    activePageId: shownPage.id,
                    selectedIds: $selectedIds,
                    readOnly: readOnly,
                    onSelectPage: { pid in activePageId = pid; selectedIds = []; hasFittedCamera = false },
                    onAddPage: { addPage() },
                    onToggleVisible: { id in toggleNodeVisible(id) },
                    onToggleLocked: { id in toggleNodeLocked(id) }
                )
            )
        }
        context.inspectorView = { tabId in
            switch tabId {
            case "design":
                if let d = shownDesign, let lp = laidPage {
                    return AnyView(
                        DesignPropertiesInspectorView(
                            design: d,
                            selectedIds: selectedIds,
                            laid: lp,
                            readOnly: readOnly,
                            onCommit: { commitDesign($0) }
                        )
                    )
                }
            case "prototype":
                if let d = shownDesign {
                    return AnyView(
                        DesignPrototypeInspectorView(
                            design: d,
                            selectedId: selectedIds.first,
                            readOnly: readOnly,
                            onCommit: { commitDesign($0) }
                        )
                    )
                }
            case "inspect":
                if let d = shownDesign, let lp = laidPage {
                    return AnyView(
                        DesignInspectTabView(
                            design: d,
                            selectedId: selectedIds.first,
                            laid: lp,
                            target: $inspectTarget
                        )
                    )
                }
            case "review":
                if let prop = activeProposal {
                    return AnyView(
                        DesignReviewInspectorView(
                            proposal: prop,
                            changes: reviewChanges,
                            decisions: reviewDecisions,
                            personaName: personaName,
                            busy: resolvingProposal,
                            error: resolveError,
                            onDecide: { i, state in
                                let deps = prop.deps ?? DesignReviewLogic.dependencies(ops: prop.ops)
                                reviewDecisions = DesignReviewLogic.decide(deps: deps, decisions: reviewDecisions, index: i, state: state)
                            },
                            onAcceptAll: {
                                let deps = prop.deps ?? DesignReviewLogic.dependencies(ops: prop.ops)
                                var d = reviewDecisions
                                for i in prop.ops.indices { d = DesignReviewLogic.decide(deps: deps, decisions: d, index: i, state: .accepted) }
                                reviewDecisions = d
                                Task { await submitReviewResolution(proposal: prop) }
                            },
                            onRejectAll: {
                                let deps = prop.deps ?? DesignReviewLogic.dependencies(ops: prop.ops)
                                var d = reviewDecisions
                                for i in prop.ops.indices { d = DesignReviewLogic.decide(deps: deps, decisions: d, index: i, state: .rejected) }
                                reviewDecisions = d
                                Task { await submitReviewResolution(proposal: prop) }
                            },
                            onSubmit: { Task { await submitReviewResolution(proposal: prop) } }
                        )
                    )
                }
            case "chat":
                if !chatId.isEmpty {
                    let pageId = shownPage?.id
                    let sel = selectedIds
                    let vp = API.ChatDesignSelection.Viewport(h: viewportSize.height / camera.z, w: viewportSize.width / camera.z, x: camera.x, y: camera.y, zoom: camera.z)
                    return AnyView(
                        DockedChatView(
                            chatId: chatId,
                            sections: [],
                            newChatLabel: "New chat",
                            creating: false,
                            createError: nil,
                            emptyDescription: "Ask \(personaName) to iterate on this design.",
                            emptyButtonTitle: "Start a chat",
                            welcomeWhere: "Design chat",
                            welcomeIntro: "Select layers on the canvas or describe what to build.",
                            starters: [],
                            onSelectChat: { _ in },
                            onNewChat: { context.navigate("/knowledge") },
                            onOpenFullChat: { id in context.navigate("/chat/\(id)") },
                            prepareBody: { $0 },
                            prepareContextRefs: { existing in
                                var refs = existing ?? []
                                if let pageId, !pageId.isEmpty {
                                    refs.append(API.ChatContextRef(id: canvasId, kind: .canvas, selection: API.ChatDesignSelection(nodes: Array(sel.prefix(100)), page: pageId, viewport: vp)))
                                }
                                return refs.isEmpty ? nil : refs
                            },
                            onTurnCompleted: nil
                        ) {
                            HStack(spacing: 6) {
                                Button(directEdit ? "Direct" : "Suggests") {
                                    Task {
                                        _ = try? await context.store.mutate(API.updateDesignSettings(canvasId: canvasId, body: API.UpdateDesignSettingsBody(directEdit: !directEdit)))
                                        _ = await context.store.refetch(refRequest)
                                    }
                                }
                                .buttonStyle(.vesper(.outline))
                                Button(paused ? "Resume" : "Pause") {
                                    Task {
                                        _ = try? await context.store.mutate(API.updateDesignSettings(canvasId: canvasId, body: API.UpdateDesignSettingsBody(personaPaused: !paused)))
                                        _ = await context.store.refetch(refRequest)
                                    }
                                }
                                .buttonStyle(.vesper(.outline))
                                Spacer(minLength: 0)
                            }
                        }
                    )
                }
            default:
                break
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

    // MARK: - Sync, Save, Undo/Redo & Actions

    private func syncFromServer(version: API.DesignVersion) {
        guard let parsed = try? DesignSchema.parse(version.body) else { return }
        if design == nil {
            design = parsed
            savedDesign = parsed
            savedSeq = version.seq
            activePageId = parsed.pages.first?.id ?? ""
            saveState = .saved
            assetCache.ensureLoaded(canvasId: canvasId, assetIds: Array(parsed.assets.keys), client: context.store.client)
            return
        }
        guard version.seq > savedSeq else { return }
        if design == savedDesign {
            design = parsed
            savedDesign = parsed
            savedSeq = version.seq
            saveState = .saved
        } else if let base = savedDesign, let cur = design, let merged = DesignMergeLogic.mergeDesigns(base: base, mine: cur, theirs: parsed) {
            design = merged
            savedDesign = parsed
            savedSeq = version.seq
            saveState = .unsaved
        } else {
            conflictState = (parsed, version.seq)
            saveState = .conflict
        }
    }

    private func commitDesign(_ next: DesignDocument) {
        guard let cur = design, next != cur else { return }
        past.append(cur)
        if past.count > 80 { past.removeFirst() }
        future.removeAll()
        design = next
        scheduleAutosave()
    }

    private func undo() {
        guard let prev = past.popLast(), let cur = design else { return }
        future.append(cur)
        design = prev
        scheduleAutosave()
    }

    private func redo() {
        guard let next = future.popLast(), let cur = design else { return }
        past.append(cur)
        design = next
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        if saveState != .conflict { saveState = .unsaved }
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await saveNow()
        }
    }

    private func saveNow(forceSeq: Int? = nil) async {
        guard let cur = design else { return }
        guard saveState != .conflict || forceSeq != nil else { return }
        if cur == savedDesign && forceSeq == nil { saveState = .saved; return }
        let settled = DesignLayoutEngine.settle(cur)
        guard let body = try? DesignSchema.encodeCanonical(settled) else { return }
        let baseSeq = forceSeq ?? savedSeq
        saveState = .saving
        do {
            let v = try await context.store.mutate(API.saveDesign(canvasId: canvasId, body: API.ChatCanvasSave(baseSeq: baseSeq, body: body, note: "Edited")))
            savedSeq = v.seq
            savedDesign = settled
            saveState = design == cur ? .saved : .unsaved
            _ = await context.store.refetch(refRequest)
        } catch APIError.http(status: 409, _) {
            let latestRef = await context.store.refetch(refRequest).data
            if let seq = latestRef?.seq,
               let latestVer = await context.store.refetch(versionRequest(seq: seq)).data,
               let theirs = try? DesignSchema.parse(latestVer.body) {
                if let base = savedDesign, let merged = DesignMergeLogic.mergeDesigns(base: base, mine: settled, theirs: theirs) {
                    design = merged
                    savedDesign = theirs
                    savedSeq = seq
                    await saveNow(forceSeq: seq)
                    return
                }
                conflictState = (theirs, seq)
            }
            saveState = .conflict
        } catch APIError.http(status: 422, let msg) where msg.contains("changes nothing") {
            savedDesign = cur
            saveState = .saved
        } catch {
            saveState = .error((error as? APIError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func zoomBy(_ factor: Double) {
        let mid = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        camera = camera.zoomed(by: factor, around: mid)
    }

    private func addPage() {
        guard var d = design else { return }
        let page = DesignPage(id: DesignSchema.newId(prefix: "p"), name: "Page \(d.pages.count + 1)")
        d.pages.append(page)
        commitDesign(d)
        activePageId = page.id
        selectedIds = []
        hasFittedCamera = false
    }

    private func toggleNodeVisible(_ id: String) {
        guard let d = design else { return }
        commitDesign(DesignEditLogic.mapNode(d, id: id) { var m = $0; m.visible = (m.visible == false) ? nil : false; return m })
    }

    private func toggleNodeLocked(_ id: String) {
        guard let d = design else { return }
        commitDesign(DesignEditLogic.mapNode(d, id: id) { var m = $0; m.locked = (m.locked == true) ? nil : true; return m })
    }

    private func duplicateSelected() {
        guard let d = design else { return }
        let res = DesignEditLogic.duplicateNodes(d, ids: selectedIds)
        commitDesign(DesignLayoutEngine.settle(res.design))
        if !res.ids.isEmpty { selectedIds = res.ids }
    }

    private func groupSelected() {
        guard let d = design, let res = DesignEditLogic.groupNodes(d, ids: selectedIds) else { return }
        commitDesign(DesignLayoutEngine.settle(res.design))
        selectedIds = [res.id]
    }

    private func deleteSelected() {
        guard let d = design else { return }
        commitDesign(DesignLayoutEngine.settle(DesignEditLogic.removeNodes(d, ids: Set(selectedIds))))
        selectedIds = []
    }

    private func pickAndUploadImage(pageId: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let client = context.store.client else { return }
        let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        Task {
            do {
                var form = APIMultipartForm()
                form.addFile("file", filename: url.lastPathComponent, contentType: mime, data: data)
                let asset = try await client.send(API.uploadDesignAsset(canvasId: canvasId, body: form))
                assetCache.store(assetId: asset.id, data: data)
                guard var d = design else { return }
                d.assets[asset.id] = DesignAsset(mime: asset.mime.rawValue, w: asset.w, h: asset.h)
                let w = min(Double(asset.w), 480)
                let h = w * Double(asset.h) / max(1, Double(asset.w))
                let center = camera.screenToWorld(CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
                let img = DesignNode(id: DesignSchema.newId(prefix: "n"), type: .image, name: url.deletingPathExtension().lastPathComponent, x: DesignSchema.round2(center.x - w / 2), y: DesignSchema.round2(center.y - h / 2), w: DesignSchema.round2(w), h: DesignSchema.round2(h), asset: asset.id, fit: "cover")
                commitDesign(DesignLayoutEngine.settle(DesignEditLogic.insertNodes(d, parent: pageId, nodes: [img])))
                selectedIds = [img.id]
            } catch {
                notice = "Image upload failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
            }
        }
    }

    private func submitReviewResolution(proposal: API.DesignProposal) async {
        resolvingProposal = true
        resolveError = nil
        defer { resolvingProposal = false }
        let items: [API.ResolveDesignProposalBody.DecisionsItem] = proposal.ops.indices.map { i in
            let d = reviewDecisions[i] ?? DesignOpDecision(state: .accepted)
            return API.ResolveDesignProposalBody.DecisionsItem(i: i, reason: d.reason, state: d.state)
        }
        do {
            _ = try await context.store.mutate(API.resolveDesignProposal(canvasId: canvasId, proposalId: proposal.id, body: API.ResolveDesignProposalBody(decisions: items)))
            reviewDecisions = [:]
            reviewing = false
            _ = await context.store.refetch(proposalsRequest)
            let updatedRef = await context.store.refetch(refRequest).data
            if let seq = updatedRef?.seq { _ = await context.store.refetch(versionRequest(seq: seq)) }
        } catch {
            resolveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: - Exports

    private func exportPNG(page: DesignPage, scale: Double, title: String) async {
        await saveNow()
        guard let client = context.store.client else { return }
        do {
            let png = try await client.send(API.renderDesign(canvasId: canvasId, node: selectedIds.first, page: selectedIds.isEmpty ? page.id : nil, scale: scale))
            let panel = NSSavePanel()
            panel.nameFieldStringValue = DocEditorLogic.sanitizedFileName(title, ext: "png")
            panel.allowedContentTypes = [.png]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try png.write(to: url, options: .atomic)
            context.showToast(ToastItemModel(id: "design.png", title: "Saved \(url.lastPathComponent)", tone: .success))
        } catch {
            notice = "PNG export failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }

    private func exportSVG(laid: DesignLaidPage, title: String) {
        let svg = DesignExporters.exportSVG(box: laid.box, ops: laid.allOps, background: laid.background)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DocEditorLogic.sanitizedFileName(title, ext: "svg")
        panel.allowedContentTypes = [.svg]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(svg.utf8).write(to: url, options: .atomic)
        context.showToast(ToastItemModel(id: "design.svg", title: "Saved \(url.lastPathComponent)", tone: .success))
    }

    private func exportPDF(laid: DesignLaidPage, title: String) {
        let data = DesignExporters.exportPDF(items: [(laid.box, laid.allOps, laid.background)], images: assetCache.images)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DocEditorLogic.sanitizedFileName(title, ext: "pdf")
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
        context.showToast(ToastItemModel(id: "design.pdf", title: "Saved \(url.lastPathComponent)", tone: .success))
    }

    private func savePDFToLibrary(laid: DesignLaidPage, title: String) async {
        await saveNow()
        guard let client = context.store.client else { return }
        let pdf = DesignExporters.exportPDF(items: [(laid.box, laid.allOps, laid.background)], images: assetCache.images)
        let name = DocEditorLogic.sanitizedFileName(title, ext: "pdf")
        var form = APIMultipartForm()
        form.addFile("file", filename: name, contentType: "application/pdf", data: pdf)
        do {
            _ = try await client.send(API.saveDesignExportToLibrary(canvasId: canvasId, body: form))
            context.showToast(ToastItemModel(id: "design.lib", title: "Saved \(name) to Library", tone: .success))
        } catch {
            notice = "Saving to Library failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
        }
    }
}

// MARK: - Pages & Layers Sidebar

private struct DesignLayersSidebarView: View {
    @Environment(\.vesperTheme) private var theme
    let design: DesignDocument
    let activePageId: String
    @Binding var selectedIds: [String]
    let readOnly: Bool
    let onSelectPage: (String) -> Void
    let onAddPage: () -> Void
    let onToggleVisible: (String) -> Void
    let onToggleLocked: (String) -> Void

    var body: some View {
        let p = theme.palette
        let activePage = design.pages.first { $0.id == activePageId } ?? design.pages.first
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PAGES").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.tertiaryText)
                Spacer()
                if !readOnly {
                    Button(action: onAddPage) { Image(systemName: "plus").font(.system(size: 10)) }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            ForEach(design.pages) { page in
                Button {
                    onSelectPage(page.id)
                } label: {
                    HStack {
                        Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(p.tertiaryText)
                        Text(page.name).font(.system(size: 12, weight: page.id == activePage?.id ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(page.id == activePage?.id ? p.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }

            Divider().overlay(p.border).padding(.vertical, 6)

            Text("LAYERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.tertiaryText)
                .padding(.horizontal, 10).padding(.bottom, 4)

            if let page = activePage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(page.children.reversed()) { node in
                            layerRow(node: node, depth: 0)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func layerRow(node: DesignNode, depth: Int) -> AnyView {
        let p = theme.palette
        let isSel = selectedIds.contains(node.id)
        return AnyView(VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: iconName(node.type)).font(.system(size: 10)).foregroundStyle(node.type == .component ? .purple : p.tertiaryText)
                Text(DesignEditLogic.labelOf(node)).font(.system(size: 11)).lineLimit(1).foregroundStyle(node.visible == false ? p.tertiaryText : p.text)
                Spacer(minLength: 2)
                if !readOnly {
                    Button { onToggleVisible(node.id) } label: {
                        Image(systemName: node.visible == false ? "eye.slash" : "eye").font(.system(size: 9))
                    }.buttonStyle(.borderless).opacity(node.visible == false ? 1 : 0.45)
                    Button { onToggleLocked(node.id) } label: {
                        Image(systemName: node.locked == true ? "lock.fill" : "lock.open").font(.system(size: 9))
                    }.buttonStyle(.borderless).opacity(node.locked == true ? 1 : 0.35)
                }
            }
            .padding(.leading, CGFloat(8 + depth * 12))
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(isSel ? p.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { selectedIds = [node.id] }

            if let ch = node.children, !ch.isEmpty {
                ForEach(ch.reversed()) { child in
                    layerRow(node: child, depth: depth + 1)
                }
            }
        })
    }

    private func iconName(_ t: DesignNodeType) -> String {
        switch t {
        case .frame: "number"
        case .component: "diamond.fill"
        case .instance: "diamond"
        case .group: "folder"
        case .section: "rectangle.dashed"
        case .shape: "square"
        case .path: "scribble"
        case .text: "textformat"
        case .image: "photo"
        case .sticky: "note.text"
        case .connector: "arrow.right"
        }
    }
}

// MARK: - Inspector Tabs (Design, Prototype, Inspect, Review)

private struct DesignPropertiesInspectorView: View {
    @Environment(\.vesperTheme) private var theme
    let design: DesignDocument
    let selectedIds: [String]
    let laid: DesignLaidPage
    let readOnly: Bool
    let onCommit: (DesignDocument) -> Void

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = selectedIds.first, let found = DesignEditLogic.find(design, id: id) {
                    let n = found.node
                    Text(DesignEditLogic.labelOf(n)).font(.system(size: 13, weight: .semibold))
                    Text(n.type.rawValue.capitalized).font(.system(size: 11)).foregroundStyle(p.tertiaryText)

                    if n.type != .connector {
                        GroupBox("Layout") {
                            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                                GridRow {
                                    numField("X", value: n.x) { v in update(id) { $0.x = v } }
                                    numField("Y", value: n.y) { v in update(id) { $0.y = v } }
                                }
                                GridRow {
                                    numField("W", value: n.w) { v in update(id) { $0 = DesignEditLogic.resizeNode($0, to: DesignBox(x: $0.x, y: $0.y, w: max(1, v), h: $0.h)) } }
                                    numField("H", value: n.h) { v in update(id) { $0 = DesignEditLogic.resizeNode($0, to: DesignBox(x: $0.x, y: $0.y, w: $0.w, h: max(1, v))) } }
                                }
                                GridRow {
                                    numField("Rot", value: n.rotation ?? 0) { v in update(id) { $0.rotation = v == 0 ? nil : v } }
                                    numField("Op%", value: (n.opacity ?? 1) * 100) { v in update(id) { $0.opacity = max(0, min(1, v / 100)) } }
                                }
                            }
                            .padding(4)
                        }
                    }

                    if n.type == .frame || n.type == .component {
                        GroupBox("Auto Layout") {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Enabled", isOn: Binding(
                                    get: { n.autoLayout != nil },
                                    set: { on in update(id) { $0.autoLayout = on ? DesignAutoLayout(direction: "vertical", gap: 8, padding: [12, 12, 12, 12]) : nil } }
                                ))
                                .disabled(readOnly)
                                if let al = n.autoLayout {
                                    Picker("Direction", selection: Binding(
                                        get: { al.direction },
                                        set: { dir in update(id) { $0.autoLayout?.direction = dir } }
                                    )) {
                                        Text("Vertical").tag("vertical")
                                        Text("Horizontal").tag("horizontal")
                                    }
                                    .pickerStyle(.segmented)
                                    numField("Gap", value: al.gap ?? 0) { v in update(id) { $0.autoLayout?.gap = max(0, v) } }
                                }
                            }
                            .padding(4)
                        }
                    }

                    if n.type == .frame || n.type == .component || n.type == .shape || n.type == .path {
                        GroupBox("Appearance") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Fill").font(.system(size: 11)).frame(width: 44, alignment: .leading)
                                    TextField("#RRGGBB or $token", text: Binding(
                                        get: { if case .color(let c) = n.fill { return c }; return "" },
                                        set: { val in update(id) { $0.fill = val.isEmpty ? nil : .color(val) } }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .disabled(readOnly)
                                }
                                HStack {
                                    Text("Stroke").font(.system(size: 11)).frame(width: 44, alignment: .leading)
                                    TextField("#RRGGBB or $token", text: Binding(
                                        get: { n.stroke ?? "" },
                                        set: { val in update(id) { $0.stroke = val.isEmpty ? nil : val; if !val.isEmpty && $0.strokeWidth == nil { $0.strokeWidth = 1 } } }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .disabled(readOnly)
                                }
                                numField("Radius", value: n.radius ?? 0) { v in update(id) { $0.radius = v > 0 ? v : nil } }
                            }
                            .padding(4)
                        }
                    }

                    if n.type == .sticky {
                        GroupBox("Sticky Color") {
                            HStack(spacing: 6) {
                                ForEach(["yellow", "pink", "green", "blue", "violet", "grey"], id: \.self) { name in
                                    Circle()
                                        .fill(Color(cgColor: SlideCGDrawer.cgColor(DesignLayoutEngine.stickyColors[name] ?? "#FEF08A")))
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(n.stickyColor == name ? p.accent : p.border, lineWidth: n.stickyColor == name ? 2 : 1))
                                        .onTapGesture { if !readOnly { update(id) { $0.stickyColor = name } } }
                                }
                            }
                            .padding(4)
                        }
                    }

                    if n.type == .frame && !readOnly {
                        Button("Make Component") {
                            update(id) { $0.type = .component }
                        }
                        .buttonStyle(.vesper(.outline))
                    }
                } else {
                    Text("Select a layer on the canvas to inspect or edit its properties.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(12)
        }
    }

    private func numField(_ label: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            TextField("", value: Binding(get: { value }, set: onChange), format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disabled(readOnly)
        }
    }

    private func update(_ id: String, _ fn: (inout DesignNode) -> Void) {
        let next = DesignEditLogic.mapNode(design, id: id) { var m = $0; fn(&m); return m }
        onCommit(DesignLayoutEngine.settle(next))
    }
}

private struct DesignPrototypeInspectorView: View {
    @Environment(\.vesperTheme) private var theme
    let design: DesignDocument
    let selectedId: String?
    let readOnly: Bool
    let onCommit: (DesignDocument) -> Void

    var body: some View {
        let p = theme.palette
        let screens = DesignPrototypeLogic.screens(design)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let selectedId {
                    let links = design.links.filter { $0.from == selectedId }
                    HStack {
                        Text("Interactions").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if !readOnly && !screens.isEmpty {
                            Button("Add link") {
                                if let res = DesignPrototypeLogic.addLink(in: design, from: selectedId) { onCommit(res.design) }
                            }
                            .buttonStyle(.vesper(.outline))
                        }
                    }
                    if links.isEmpty {
                        Text("No prototype links on this layer.").font(.system(size: 11)).foregroundStyle(p.tertiaryText)
                    }
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Trigger", selection: Binding(
                                get: { link.trigger },
                                set: { v in updateLink(link.id) { $0.trigger = v; $0.delayMs = v == "after-delay" ? ($0.delayMs ?? 800) : nil } }
                            )) {
                                Text("On click").tag("click")
                                Text("On hover").tag("hover")
                                Text("After delay").tag("after-delay")
                            }
                            Picker("Destination", selection: Binding(
                                get: { link.to },
                                set: { v in updateLink(link.id) { $0.to = v } }
                            )) {
                                ForEach(screens) { s in Text(s.name).tag(s.id) }
                            }
                            Picker("Transition", selection: Binding(
                                get: { link.transition },
                                set: { v in updateLink(link.id) { $0.transition = v } }
                            )) {
                                Text("Instant").tag("instant")
                                Text("Dissolve").tag("dissolve")
                                Text("Slide left").tag("slide-left")
                                Text("Slide right").tag("slide-right")
                                Text("Slide up").tag("slide-up")
                                Text("Slide down").tag("slide-down")
                                Text("Smart animate").tag("smart-animate")
                            }
                            if !readOnly {
                                Button("Remove", role: .destructive) {
                                    var next = design
                                    next.links.removeAll { $0.id == link.id }
                                    onCommit(next)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                            }
                        }
                        .padding(8)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    }
                } else {
                    Text("Select any layer to wire interactive prototype links between frames.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(12)
        }
    }

    private func updateLink(_ id: String, _ fn: (inout DesignLink) -> Void) {
        var next = design
        for i in next.links.indices where next.links[i].id == id { fn(&next.links[i]) }
        onCommit(next)
    }
}

private struct DesignInspectTabView: View {
    @Environment(\.vesperTheme) private var theme
    let design: DesignDocument
    let selectedId: String?
    let laid: DesignLaidPage
    @Binding var target: DesignInspectTarget

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Target", selection: $target) {
                    ForEach(DesignInspectTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if let id = selectedId, let found = DesignEditLogic.find(design, id: id), let box = laid.boxes[id] {
                    let code = DesignInspectLogic.generateCode(design: design, node: found.node, box: box, target: target)
                    HStack {
                        Text("\(Int(box.w.rounded())) × \(Int(box.h.rounded())) px").font(.system(size: 11, design: .monospaced)).foregroundStyle(p.secondaryText)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        .buttonStyle(.vesper(.outline))
                    }
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                } else {
                    Text("Select a layer to inspect CSS, Tailwind, or React code.")
                        .font(.system(size: 12))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(12)
        }
    }
}

private struct DesignReviewInspectorView: View {
    @Environment(\.vesperTheme) private var theme
    let proposal: API.DesignProposal
    let changes: [DesignReviewChange]
    let decisions: [Int: DesignOpDecision]
    let personaName: String
    let busy: Bool
    let error: String?
    let onDecide: (Int, API.ResolveDesignProposalBody.DecisionsItem.State) -> Void
    let onAcceptAll: () -> Void
    let onRejectAll: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(personaName) suggested \(changes.count) \(changes.count == 1 ? "change" : "changes")")
                    .font(.system(size: 13, weight: .semibold))
                if !proposal.summary.isEmpty {
                    Text(proposal.summary).font(.system(size: 12)).foregroundStyle(p.secondaryText)
                }
                HStack(spacing: 8) {
                    Button("Reject all", action: onRejectAll).buttonStyle(.vesper(.outline)).disabled(busy)
                    Button("Accept all", action: onAcceptAll).buttonStyle(.vesper(.primary)).disabled(busy)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
                ForEach(changes) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(c.id + 1). \(c.title)").font(.system(size: 12, weight: .medium))
                        if !c.why.isEmpty {
                            Text(c.why).font(.system(size: 11)).foregroundStyle(p.secondaryText)
                        }
                        HStack(spacing: 6) {
                            let st = decisions[c.id]?.state
                            Button("Reject") { onDecide(c.id, .rejected) }
                                .buttonStyle(.vesper(st == .rejected ? .primary : .outline))
                                .disabled(busy)
                            Button("Accept") { onDecide(c.id, .accepted) }
                                .buttonStyle(.vesper(st == .accepted ? .primary : .outline))
                                .disabled(busy)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                }
                if decisions.count >= changes.count && !changes.isEmpty {
                    Button("Apply decisions", action: onSubmit)
                        .buttonStyle(.vesper(.primary))
                        .disabled(busy)
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Full-Screen Prototype Player (/present/designs/:id)

struct DesignPresentScreen: View {
    @Environment(NativeScreenContext.self) private var context

    @State private var player: DesignPrototypePlayer?
    @State private var showHints = false
    @State private var showHelp = false
    @State private var assetCache = DesignAssetCache()
    @State private var keyMonitor: Any?
    @State private var delayTask: Task<Void, Never>?

    private var canvasId: String { context.match.params["id"] ?? "" }
    private var refRequest: APIRequest<API.Design> { API.getDesign(canvasId: canvasId) }
    private func versionRequest(seq: Int) -> APIRequest<API.DesignVersion> { API.getDesignVersion(canvasId: canvasId, seq: seq) }

    var body: some View {
        let ref = context.store.entry(refRequest).data
        let ver = (ref.flatMap { $0.seq > 0 ? context.store.entry(versionRequest(seq: $0.seq)).data : nil })
        let design = ver.flatMap { try? DesignSchema.parse($0.body) }
        let start = design.flatMap { DesignPrototypeLogic.startScreen($0, wanted: context.match.query["start"], pageId: context.match.query["page"]) }
        let currentFrameId = player?.at ?? start?.id
        let activePage = design?.pages.first { p in p.children.contains { $0.id == currentFrameId } }
        let laid: DesignLaidPage? = {
            guard let design, let activePage else { return nil }
            return DesignLayoutEngine(design: design).layoutPage(activePage)
        }()
        let frameNode = laid?.nodes.first { $0.id == currentFrameId }
        let frameBox = currentFrameId.flatMap { laid?.boxes[$0] }
        let hotspots: [DesignLink] = {
            guard let design, let currentFrameId else { return [] }
            return DesignPrototypeLogic.hotspotsOf(design, frameId: currentFrameId)
        }()

        ZStack {
            Color(white: 0.07).ignoresSafeArea()
                .onTapGesture {
                    showHints = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        showHints = false
                    }
                }

            if let frameNode, let frameBox, let laid {
                GeometryReader { geo in
                    let k = max(0.01, min((geo.size.width - 32) / max(1, frameBox.w), (geo.size.height - 88) / max(1, frameBox.h)))
                    let w = max(1, frameBox.w * k)
                    let h = max(1, frameBox.h * k)
                    ZStack(alignment: .topLeading) {
                        DesignFrameCanvas(ops: frameNode.ops, box: frameBox, background: laid.background, images: assetCache.images)
                            .frame(width: w, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(color: .black.opacity(0.45), radius: 24)

                        ForEach(hotspots.filter { $0.trigger != "after-delay" }) { link in
                            if let hb = laid.boxes[link.from] {
                                Rectangle()
                                    .fill(showHints ? Color.accentColor.opacity(0.28) : Color.clear)
                                    .overlay(Rectangle().stroke(showHints ? Color.accentColor : Color.clear, lineWidth: 1.5))
                                    .frame(width: max(0, hb.w * k), height: max(0, hb.h * k))
                                    .offset(x: (hb.x - frameBox.x) * k, y: (hb.y - frameBox.y) * k)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if link.trigger == "click" { navigate(to: link.to, startId: start?.id) } }
                                    .onHover { over in if over && link.trigger == "hover" { navigate(to: link.to, startId: start?.id) } }
                            }
                        }
                    }
                    .frame(width: w, height: h)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            } else if design != nil {
                Text("This design has no frames to present.").foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }

            if showHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prototype Shortcuts").font(.system(size: 13, weight: .semibold))
                    Text("← / Backspace: Back · R: Restart · H: Show hotspots · F: Fullscreen · Esc: Exit")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(20)
            }

            HStack(spacing: 8) {
                Button { _ = player?.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(player?.back.isEmpty ?? true)
                Text(design.flatMap { d in DesignPrototypeLogic.screens(d).first { $0.id == currentFrameId }?.name } ?? "Prototype")
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 90)
                Button { player?.restart() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless)
                Divider().frame(height: 16)
                Button { showHints.toggle() } label: { Image(systemName: "scope") }.buttonStyle(.borderless).help("Show hotspots (H)")
                Button { context.window()?.window?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless)
                Button("Exit") { context.navigate("/apps/designs/\(canvasId)") }.buttonStyle(.vesper(.outline))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 18)
        }
        .task(id: canvasId) {
            context.chrome = NativeChrome(title: ref?.title ?? "Prototype")
            context.store.observe(refRequest)
            context.store.load(refRequest)
        }
        .task(id: ref?.seq ?? 0) {
            if let seq = ref?.seq, seq > 0 { context.store.load(versionRequest(seq: seq)) }
        }
        .onChange(of: design?.assets.keys.sorted().joined(separator: ",")) { _, _ in
            if let d = design { assetCache.ensureLoaded(canvasId: canvasId, assetIds: Array(d.assets.keys), client: context.store.client) }
        }
        .onChange(of: currentFrameId) { _, fid in
            delayTask?.cancel()
            guard let fid, let d = design else { return }
            let delayed = DesignPrototypeLogic.hotspotsOf(d, frameId: fid).filter { $0.trigger == "after-delay" }
            if let first = delayed.first {
                delayTask = Task {
                    try? await Task.sleep(for: .milliseconds(first.delayMs ?? 800))
                    guard !Task.isCancelled else { return }
                    navigate(to: first.to, startId: start?.id)
                }
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                if ev.keyCode == 53 { // Escape
                    if showHelp { showHelp = false } else { context.navigate("/apps/designs/\(canvasId)") }
                    return nil
                }
                if ev.keyCode == 123 || ev.keyCode == 51 { _ = player?.goBack(); return nil }
                switch ev.charactersIgnoringModifiers?.lowercased() {
                case "r": player?.restart(); return nil
                case "h": showHints.toggle(); return nil
                case "f": context.window()?.window?.toggleFullScreen(nil); return nil
                case "?": showHelp.toggle(); return nil
                default: return ev
                }
            }
        }
        .onDisappear {
            delayTask?.cancel()
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            context.store.stopObserving(refRequest.key)
        }
    }

    private func navigate(to targetId: String, startId: String?) {
        if player == nil, let startId { player = DesignPrototypePlayer(start: startId) }
        withAnimation(.easeInOut(duration: 0.25)) {
            player?.follow(to: targetId)
        }
    }
}
