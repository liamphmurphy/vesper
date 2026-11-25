import AppKit
import SwiftUI
import VesperCore

/// Native SwiftUI implementation of `/artifacts/:id/review` (port of
/// `web/app/(app)/artifacts/[id]/review/review-screen.tsx`): full pan/zoom mockup canvas with
/// single, side-by-side and swipe comparison modes, pinned review comments, attached ticket
/// acceptance criteria checklist, and Approve / Request changes workflow.
struct ArtifactReviewScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    private enum CameraMode: Equatable {
        case fit
        case actual
        case free(ArtifactDetailLogic.MockupCamera)
    }

    private struct RenderedMockup {
        let image: NSImage
        let size: ArtifactDetailLogic.MockupSize
        let label: String
        let versionId: String
        /// What drew it, for the snapshot a decision records.
        let drawing: MockupRendering.Drawing?
        let source: String?
    }

    @State private var primaryVersionId: String?
    @State private var compareVersionId: String?
    @State private var mode: ArtifactDetailLogic.MockupReviewMode = .single
    @State private var tool: ArtifactDetailLogic.MockupReviewTool = .pan
    @State private var showPins = true
    @State private var swipeFraction: Double = 0.5
    @State private var cameraMode: CameraMode = .fit
    @State private var viewportSize: CGSize = CGSize(width: 800, height: 600)

    @State private var primaryDrawing: RenderedMockup?
    @State private var compareDrawing: RenderedMockup?
    @State private var dragStartCamera: ArtifactDetailLogic.MockupCamera?
    @State private var magnifyStartCamera: ArtifactDetailLogic.MockupCamera?

    @State private var draftPins: [API.MockupPin] = []
    @State private var composingPinAt: ArtifactDetailLogic.MockupFraction?
    @State private var composingPinText = ""
    @State private var activePinIndex: Int?
    @State private var note = ""
    @State private var deciding = false
    @State private var reviewError: String?
    @State private var savedDecision: API.ReviewArtifactVersionBody.Decision?

    private var artifactId: String { context.match.params["id"] ?? "" }
    private var queryVersion: String? { context.match.query["version"] }

    var body: some View {
        let req = API.getArtifact(id: artifactId)
        let entry = context.store.entry(req)

        Group {
            if let error = entry.error {
                QueryErrorView(message: error.userMessage) {
                    Task { await context.store.refetch(req) }
                }
                .padding(32)
            } else if let artifact = entry.data {
                workspace(artifact: artifact)
            } else {
                ProgressView("Loading mockup\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.palette.background)
        .onAppear {
            context.store.load(req)
            context.store.observe(req)
            syncChrome(artifact: entry.data)
            bindCommands(artifact: entry.data)
        }
        .onDisappear {
            context.store.stopObserving(req.key)
            context.onCommand = nil
        }
        .onChange(of: entry.data) { _, artifact in
            if let artifact {
                if primaryVersionId == nil {
                    primaryVersionId = artifact.versions.contains(where: { $0.id == queryVersion })
                        ? queryVersion
                        : artifact.currentVersion.id
                }
            }
            syncChrome(artifact: artifact)
            bindCommands(artifact: artifact)
        }
        .onChange(of: primaryVersionId) { _, _ in
            syncChrome(artifact: entry.data)
        }
    }

    private func primaryVersion(for artifact: API.Artifact) -> API.ArtifactVersion {
        if let id = primaryVersionId, let found = artifact.versions.first(where: { $0.id == id }) {
            return found
        }
        return artifact.currentVersion
    }

    private func compareVersion(for artifact: API.Artifact, primary: API.ArtifactVersion) -> API.ArtifactVersion? {
        guard mode != .single else { return nil }
        return ArtifactDetailLogic.compareVersion(primary: primary, versions: artifact.versions, chosenId: compareVersionId)
    }

    private func syncChrome(artifact: API.Artifact?) {
        let title = artifact.map { LibraryLogic.artifactTitle(title: $0.title, displayId: $0.displayId) } ?? "Mockup"
        context.chrome = NativeChrome(
            title: title,
            subtitle: "Review",
            toolbarItems: [
                ShellToolbarItem(id: "review.close", label: "Close", icon: "xmark", kind: .button, showsLabel: true),
            ],
            navigator: ArtifactDetailLogic.navModel(
                artifact: artifact,
                selectedVersionId: primaryVersionId
            )
        )
    }

    private func bindCommands(artifact: API.Artifact?) {
        context.onCommand = { cmd in
            if let navAction = ArtifactDetailLogic.navAction(for: cmd) {
                switch navAction {
                case .backToLibrary:
                    context.navigate("/library")
                case .selectVersion(let versionId):
                    primaryVersionId = versionId
                case .openLink(let href, let newTab):
                    if newTab { context.openInNewTab(href) } else { context.navigate(href) }
                }
                return
            }
            guard case .toolbarAction(itemId: "review.close", _) = cmd else { return }
            context.navigate("/artifacts/\(artifactId)")
        }
    }

    private func workspace(artifact: API.Artifact) -> some View {
        let primary = primaryVersion(for: artifact)
        let editable = primary.id == artifact.currentVersion.id
        let compare = compareVersion(for: artifact, primary: primary)
        let activeMode: ArtifactDetailLogic.MockupReviewMode = compare != nil ? mode : .single
        let canPin = editable && primaryDrawing != nil
        let activeTool: ArtifactDetailLogic.MockupReviewTool = canPin ? tool : .pan
        let savedPins = (primary.review != nil && primary.review?.state != .pending) ? (primary.review?.pins ?? []) : []
        let showingSavedPins = !editable || (draftPins.isEmpty && composingPinAt == nil && !savedPins.isEmpty)
        let visiblePins = showingSavedPins ? savedPins : draftPins
        let drawingSize = primaryDrawing?.size ?? compareDrawing?.size ?? ArtifactDetailLogic.defaultSize
        let paneSize = ArtifactDetailLogic.MockupSize(
            width: activeMode == .side ? max(1, (Double(viewportSize.width) - 1) / 2) : max(1, Double(viewportSize.width)),
            height: max(1, Double(viewportSize.height))
        )
        let camera = resolveCamera(drawing: drawingSize, pane: paneSize)

        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                topCompareBar(artifact: artifact, primary: primary, compare: compare)
                Divider().overlay(theme.palette.border)
                ZStack(alignment: .bottom) {
                    GeometryReader { geo in
                        let currentPane = ArtifactDetailLogic.MockupSize(
                            width: activeMode == .side ? max(1, (Double(geo.size.width) - 1) / 2) : max(1, Double(geo.size.width)),
                            height: max(1, Double(geo.size.height))
                        )
                        let cam = resolveCamera(drawing: drawingSize, pane: currentPane)
                        HStack(spacing: 0) {
                            mockupPane(
                                drawing: primaryDrawing,
                                swipeDrawing: activeMode == .swipe ? compareDrawing : nil,
                                camera: cam,
                                drawingSize: drawingSize,
                                paneSize: currentPane,
                                pins: visiblePins,
                                isSavedPins: showingSavedPins,
                                activeTool: activeTool,
                                canPin: canPin
                            )
                            if activeMode == .side {
                                Divider().overlay(theme.palette.border)
                                mockupPane(
                                    drawing: compareDrawing,
                                    swipeDrawing: nil,
                                    camera: cam,
                                    drawingSize: drawingSize,
                                    paneSize: currentPane,
                                    pins: [],
                                    isSavedPins: true,
                                    activeTool: .pan,
                                    canPin: false
                                )
                            }
                        }
                        .onAppear { viewportSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in viewportSize = newSize }
                    }

                    floatingCanvasToolbar(
                        scale: camera.scale,
                        canPin: canPin,
                        activeTool: activeTool,
                        drawing: drawingSize,
                        pane: paneSize
                    )
                    .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(theme.palette.border)

            reviewSidebar(
                artifact: artifact,
                primary: primary,
                editable: editable,
                pins: visiblePins,
                showingSavedPins: showingSavedPins
            )
            .frame(width: 340)
            .background(theme.palette.surface)
        }
        .task(id: "\(artifact.id)|\(primary.id)") {
            primaryDrawing = await loadDrawing(artifact: artifact, version: primary)
        }
        .task(id: "\(artifact.id)|\(compare?.id ?? "none")") {
            if let compare {
                compareDrawing = await loadDrawing(artifact: artifact, version: compare)
            } else {
                compareDrawing = nil
            }
        }
    }

    private func resolveCamera(drawing: ArtifactDetailLogic.MockupSize, pane: ArtifactDetailLogic.MockupSize) -> ArtifactDetailLogic.MockupCamera {
        switch cameraMode {
        case .fit:
            return ArtifactDetailLogic.fitView(drawing: drawing, viewport: pane)
        case .actual:
            return ArtifactDetailLogic.actualView(drawing: drawing, viewport: pane)
        case .free(let cam):
            return cam
        }
    }

    private func topCompareBar(artifact: API.Artifact, primary: API.ArtifactVersion, compare: API.ArtifactVersion?) -> some View {
        let others = artifact.versions.filter { $0.id != primary.id }
        return HStack(spacing: 12) {
            if primaryDrawing?.drawing?.isLegacy == true {
                MockupLegacyLabel()
            }
            Picker("Version", selection: Binding(
                get: { primary.id },
                set: { next in
                    primaryVersionId = next
                    composingPinAt = nil
                    activePinIndex = nil
                    cameraMode = .fit
                    if compareVersionId == next { compareVersionId = nil }
                }
            )) {
                ForEach(artifact.versions, id: \.id) { v in
                    Text("\(v.label)\(v.id == artifact.currentVersion.id ? " (current)" : "")").tag(v.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)

            if artifact.versions.count > 1 {
                Picker("Compare mode", selection: $mode) {
                    ForEach(ArtifactDetailLogic.MockupReviewMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                if mode != .single, let compare {
                    Text("vs")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                    Picker("Compare with", selection: Binding(
                        get: { compare.id },
                        set: { compareVersionId = $0 }
                    )) {
                        ForEach(others, id: \.id) { v in
                            Text(v.label).tag(v.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
            }

            Spacer()

            Button("Open detail") {
                context.navigate("/artifacts/\(artifact.id)")
            }
            .buttonStyle(.vesper(.outline))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.palette.surface)
    }

    private func mockupPane(
        drawing: RenderedMockup?,
        swipeDrawing: RenderedMockup?,
        camera: ArtifactDetailLogic.MockupCamera,
        drawingSize: ArtifactDetailLogic.MockupSize,
        paneSize: ArtifactDetailLogic.MockupSize,
        pins: [API.MockupPin],
        isSavedPins: Bool,
        activeTool: ArtifactDetailLogic.MockupReviewTool,
        canPin: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            theme.swiftUIColor("surface-sunken", fallback: theme.palette.background)

            if let drawing {
                let w = drawing.size.width * camera.scale
                let h = drawing.size.height * camera.scale

                Image(nsImage: drawing.image)
                    .resizable()
                    .frame(width: w, height: h)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
                    .offset(x: camera.x, y: camera.y)

                if let swipeDrawing {
                    let clipW = paneSize.width * swipeFraction
                    Image(nsImage: swipeDrawing.image)
                        .resizable()
                        .frame(width: w, height: h)
                        .background(Color.white)
                        .offset(x: camera.x, y: camera.y)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: clipW, height: paneSize.height)
                        }

                    // Draggable swipe divider
                    Rectangle()
                        .fill(theme.palette.accent)
                        .frame(width: 2, height: paneSize.height)
                        .offset(x: clipW)
                        .overlay(alignment: .center) {
                            Circle()
                                .fill(theme.palette.accent)
                                .frame(width: 22, height: 22)
                                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                                .offset(x: clipW, y: 0)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    swipeFraction = min(1, max(0, Double(value.location.x) / max(1, paneSize.width)))
                                }
                        )
                }

                // Numbered pins
                if showPins {
                    ForEach(Array(pins.enumerated()), id: \.offset) { idx, pin in
                        let pos = ArtifactDetailLogic.fromFraction(
                            camera: camera,
                            drawing: drawingSize,
                            fraction: ArtifactDetailLogic.MockupFraction(x: pin.x, y: pin.y)
                        )
                        let active = activePinIndex == idx
                        Button {
                            activePinIndex = (activePinIndex == idx) ? nil : idx
                        } label: {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: active ? 26 : 22, height: active ? 26 : 22)
                                .background(isSavedPins ? theme.palette.secondaryText : theme.palette.accent, in: Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(radius: 3)
                        }
                        .buttonStyle(.plain)
                        .help(pin.text)
                        .position(x: pos.x, y: pos.y)
                    }
                }

                // Active pin composer
                if let composing = composingPinAt, canPin {
                    let pos = ArtifactDetailLogic.fromFraction(camera: camera, drawing: drawingSize, fraction: composing)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pin #\(draftPins.count + 1)")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                        TextField("Comment on this spot\u{2026}", text: $composingPinText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitPin(at: composing) }
                        HStack {
                            Button("Cancel") {
                                composingPinAt = nil
                                composingPinText = ""
                            }
                            .buttonStyle(.vesper(.outline))
                            Spacer()
                            Button("Add pin") { commitPin(at: composing) }
                                .buttonStyle(.vesper(.primary))
                                .disabled(composingPinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(10)
                    .frame(width: 240)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                    .shadow(radius: 6)
                    .position(
                        x: min(max(130, pos.x), max(130, paneSize.width - 130)),
                        y: min(max(70, pos.y + 64), max(70, paneSize.height - 70))
                    )
                }

                // Version label chip
                Text(drawing.label)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.palette.surface.opacity(0.92), in: Capsule())
                    .overlay(Capsule().stroke(theme.palette.border))
                    .padding(12)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onCanvasScrollWheel { action in
            switch action {
            case .zoom(let factor, let ax, let ay):
                let current = resolveCamera(drawing: drawingSize, pane: paneSize)
                cameraMode = .free(ArtifactDetailLogic.zoomAt(current, factor: factor, px: ax, py: ay))
                return true
            case .pan(let dx, let dy):
                let current = resolveCamera(drawing: drawingSize, pane: paneSize)
                cameraMode = .free(ArtifactDetailLogic.panBy(current, dx: dx, dy: dy))
                return true
            case .ignore:
                return false
            }
        }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = magnifyStartCamera ?? resolveCamera(drawing: drawingSize, pane: paneSize)
                    if magnifyStartCamera == nil { magnifyStartCamera = base }
                    cameraMode = .free(
                        ArtifactDetailLogic.zoomAt(
                            base,
                            factor: Double(value.magnification),
                            px: Double(value.startLocation.x),
                            py: Double(value.startLocation.y)
                        )
                    )
                }
                .onEnded { _ in
                    magnifyStartCamera = nil
                }
        )
        .gesture(
            SpatialTapGesture()
                .onEnded { value in
                    guard activeTool == .pin, canPin else { return }
                    if let frac = ArtifactDetailLogic.toFraction(
                        camera: camera,
                        drawing: drawingSize,
                        px: Double(value.location.x),
                        py: Double(value.location.y)
                    ) {
                        composingPinAt = ArtifactDetailLogic.MockupFraction(
                            x: ArtifactDetailLogic.round4(frac.x),
                            y: ArtifactDetailLogic.round4(frac.y)
                        )
                        composingPinText = ""
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard activeTool == .pan else { return }
                    if dragStartCamera == nil { dragStartCamera = camera }
                    if let start = dragStartCamera {
                        cameraMode = .free(ArtifactDetailLogic.panBy(start, dx: Double(value.translation.width), dy: Double(value.translation.height)))
                    }
                }
                .onEnded { _ in
                    dragStartCamera = nil
                }
        )
    }

    private func commitPin(at frac: ArtifactDetailLogic.MockupFraction) {
        let trimmed = composingPinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftPins.append(API.MockupPin(text: trimmed, x: frac.x, y: frac.y))
        composingPinAt = nil
        composingPinText = ""
        showPins = true
    }

    private func floatingCanvasToolbar(
        scale: Double,
        canPin: Bool,
        activeTool: ArtifactDetailLogic.MockupReviewTool,
        drawing: ArtifactDetailLogic.MockupSize,
        pane: ArtifactDetailLogic.MockupSize
    ) -> some View {
        HStack(spacing: 4) {
            Button("\u{2212}") {
                let current = resolveCamera(drawing: drawing, pane: pane)
                cameraMode = .free(ArtifactDetailLogic.zoomAt(current, factor: 1 / ArtifactDetailLogic.zoomStep, px: pane.width / 2, py: pane.height / 2))
            }
            .buttonStyle(.vesper(.outline))
            .help("Zoom out")

            Text("\(Int((scale * 100).rounded()))%")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .frame(width: 44)

            Button("+") {
                let current = resolveCamera(drawing: drawing, pane: pane)
                cameraMode = .free(ArtifactDetailLogic.zoomAt(current, factor: ArtifactDetailLogic.zoomStep, px: pane.width / 2, py: pane.height / 2))
            }
            .buttonStyle(.vesper(.outline))
            .help("Zoom in")

            Divider().frame(height: 18)

            Button("Fit") { cameraMode = .fit }
                .buttonStyle(.vesper(cameraMode == .fit ? .primary : .outline))
            Button("100%") { cameraMode = .actual }
                .buttonStyle(.vesper(cameraMode == .actual ? .primary : .outline))

            Divider().frame(height: 18)

            Button("Pan") { tool = .pan }
                .buttonStyle(.vesper(activeTool == .pan ? .primary : .outline))
            Button("Pin") { tool = .pin }
                .buttonStyle(.vesper(activeTool == .pin ? .primary : .outline))
                .disabled(!canPin)
                .help(canPin ? "Click the mockup to pin a comment" : "Pins go on the current version")

            Divider().frame(height: 18)

            Button(showPins ? "Hide pins" : "Show pins") { showPins.toggle() }
                .buttonStyle(.vesper(.outline))
        }
        .padding(6)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func reviewSidebar(
        artifact: API.Artifact,
        primary: API.ArtifactVersion,
        editable: Bool,
        pins: [API.MockupPin],
        showingSavedPins: Bool
    ) -> some View {
        let review = primary.review
        let state = review?.state ?? .pending

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Reviewing header
                reviewSection("Reviewing") {
                    HStack(spacing: 8) {
                        Text(primary.label)
                            .font(.system(size: theme.pointSize(.heading), weight: .semibold, design: .monospaced))
                        ReviewChip(state: state)
                        if primary.id == artifact.currentVersion.id {
                            Text("current")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.swiftUIColor("pill-done-fg", fallback: .green))
                        }
                    }
                    Text("\(primary.createdBy.name) \u{00B7} \(APIDate.shortAgo(primary.createdAt))\(primary.note.isEmpty ? "" : " \u{00B7} \u{201C}\(primary.note)\u{201D}")")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                    if let noteText = review?.note, !noteText.isEmpty {
                        Text(noteText)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.text)
                            .padding(.top, 2)
                    }
                }

                // Pinned comments
                reviewSection("Pins (\(pins.count))") {
                    if pins.isEmpty {
                        Text(editable ? "Switch to Pin mode and click the mockup to attach numbered feedback." : "No pinned comments on this version.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(pins.enumerated()), id: \.offset) { idx, pin in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 20, height: 20)
                                        .background(showingSavedPins ? theme.palette.secondaryText : theme.palette.accent, in: Circle())
                                    Text(pin.text)
                                        .font(.system(size: theme.pointSize(.small)))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if editable && !showingSavedPins {
                                        Button {
                                            draftPins.remove(at: idx)
                                            if activePinIndex == idx { activePinIndex = nil }
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundStyle(theme.palette.tertiaryText)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(6)
                                .background(activePinIndex == idx ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .onTapGesture { activePinIndex = idx }
                            }
                        }
                    }
                }

                // Decision
                reviewSection("Decision") {
                    if editable {
                        TextEditor(text: $note)
                            .font(.system(size: theme.pointSize(.body)))
                            .frame(height: 80)
                            .padding(4)
                            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))

                        if let reviewError {
                            Text(reviewError)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        }
                        if let savedDecision {
                            Text(savedDecision == .approved ? "Approved." : "Changes requested.")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.swiftUIColor("pill-done-fg", fallback: .green))
                        }

                        HStack(spacing: 8) {
                            Button("Approve") {
                                Task { await submitReview(artifact: artifact, decision: .approved) }
                            }
                            .buttonStyle(.vesper(.approve))
                            .disabled(deciding)

                            Button("Request changes") {
                                Task { await submitReview(artifact: artifact, decision: .changesRequested) }
                            }
                            .buttonStyle(.vesper(.approveOutline))
                            .disabled(deciding || (note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftPins.isEmpty))
                        }
                    } else {
                        Text("Only the current version (\(artifact.currentVersion.label)) can be reviewed.")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                        Button("Switch to \(artifact.currentVersion.label)") {
                            primaryVersionId = artifact.currentVersion.id
                            cameraMode = .fit
                        }
                        .buttonStyle(.vesper(.outline))
                    }
                }
            }
        }
    }

    private func reviewSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(theme.palette.tertiaryText)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider().overlay(theme.palette.border)
        }
    }

    private func submitReview(artifact: API.Artifact, decision: API.ReviewArtifactVersionBody.Decision) async {
        guard let client = context.store.client, !deciding else { return }
        deciding = true
        reviewError = nil
        savedDecision = nil
        defer { deciding = false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // The snapshot is the drawing on screen when it's of the version being decided.
            let shown = primaryDrawing?.versionId == artifact.currentVersion.id ? primaryDrawing : nil
            _ = try await MockupRendering.review(
                client: client,
                artifactId: artifact.id,
                versionId: artifact.currentVersion.id,
                source: shown?.source ?? artifact.bodyMd,
                drawing: shown?.drawing,
                decision: decision,
                note: trimmed.isEmpty ? nil : trimmed,
                pins: draftPins.isEmpty ? nil : draftPins
            )
            note = ""
            draftPins = []
            savedDecision = decision
            context.store.invalidate(QueryInvalidation(resources: ["artifacts"]))
            await context.store.refetch(API.getArtifact(id: artifact.id))
        } catch {
            reviewError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func loadDrawing(artifact: API.Artifact, version: API.ArtifactVersion) async -> RenderedMockup? {
        let source: String?
        if version.id == artifact.currentVersion.id {
            source = artifact.bodyMd
        } else if let client = context.store.client {
            let path = ArtifactDetailLogic.contentPath(artifactId: artifact.id, versionId: version.id)
            if let data = try? await client.request("GET", path, headers: ["Accept": "*/*"], timeout: 60) {
                source = String(data: data, encoding: .utf8)
            } else {
                source = nil
            }
        } else {
            source = nil
        }
        guard let source, !source.isEmpty else { return nil }
        let parsed = ArtifactDetailLogic.svgSize(source)
        if let drawing = await MockupRendering.draw(source: source, cacheID: "review-\(artifact.id)-\(version.id)") {
            return RenderedMockup(image: drawing.image, size: drawing.size, label: version.label, versionId: version.id,
                                  drawing: drawing, source: source)
        }
        if let image = NSImage(data: Data(source.utf8)) {
            return RenderedMockup(image: image, size: parsed, label: version.label, versionId: version.id, drawing: nil, source: source)
        }
        return nil
    }
}
