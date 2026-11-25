import AppKit
import SwiftUI
import VesperCore

/// A ```mockup fence (`ChatMockupCard`): the version a persona made with create_mockup, drawn natively
/// in the chat's embed frame and decided in place. Drag pans, pinch or ⌘-scroll zooms, double-click
/// fits; a plain scroll still scrolls the transcript. A decision goes through `MockupRendering.review`,
/// so it records the snapshot the review screen would, and the server tells the chat, and with it the
/// persona's next turn, what was decided.
struct MockupCardView: View {
    /// The fence's body.
    let source: String

    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var drawing: MockupRendering.Drawing?
    @State private var drawnSource: String?
    @State private var drawFailed = false
    /// nil fits the drawing to the stage.
    @State private var camera: ArtifactDetailLogic.MockupCamera?
    @State private var dragStart: ArtifactDetailLogic.MockupCamera?
    @State private var magnifyStart: ArtifactDetailLogic.MockupCamera?
    @State private var note = ""
    @State private var deciding = false
    @State private var reviewError: String?
    @State private var reconsidering = false

    private static let maxStageHeight: Double = 420
    private static let minStageHeight: Double = 220

    var body: some View {
        if let card = ChatMockupCard.parse(source) {
            loaded(card)
        } else {
            EmbedFrame(icon: "rectangle.dashed", label: "Mockup", view: .constant("")) {
                EmptyView()
            } content: {
                Text("This mockup card doesn\u{2019}t name a mockup version. Its source is below.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                EmbedSourceView(code: source, language: "json")
            }
        }
    }

    @ViewBuilder
    private func loaded(_ card: ChatMockupCard) -> some View {
        let req = API.getArtifact(id: card.artifactID)
        let entry = context.store.entry(req)
        let artifact = entry.data
        let standing = artifact.map { a in
            ChatMockupCard.standing(
                cardVersionID: card.versionID,
                currentVersionID: a.currentVersion.id,
                versions: a.versions.map { (id: $0.id, label: $0.label, review: $0.review?.state.rawValue) }
            )
        }
        let title = card.title.isEmpty ? (artifact?.title ?? "Mockup") : card.title

        EmbedFrame(icon: "rectangle.dashed", label: title, view: .constant("")) {
            headerActions(card, standing: standing)
        } content: {
            if let error = entry.error {
                QueryErrorView(message: error.userMessage) {
                    Task { await context.store.refetch(req) }
                }
                .padding(12)
            } else {
                stage(title: title)
                if let artifact, let standing {
                    reviewBar(card, artifact: artifact, standing: standing)
                }
            }
        }
        .onAppear {
            context.store.load(req)
            context.store.observe(req)
        }
        .onDisappear { context.store.stopObserving(req.key) }
        .task(id: card.versionID) { await draw(card) }
    }

    // MARK: Header

    @ViewBuilder
    private func headerActions(_ card: ChatMockupCard, standing: ChatMockupCard.Standing?) -> some View {
        if let standing {
            switch standing {
            case .current(let label, let review):
                versionLabel(label)
                TonePill(label: review.pill.label, tone: review.pill.tone)
            case .superseded(let label, let currentLabel):
                versionLabel(label)
                TonePill(label: currentLabel.isEmpty ? "Superseded" : "Superseded by \(currentLabel)", tone: "neutral")
            case .missing:
                EmptyView()
            }
        }
        if drawing != nil {
            Button {
                camera = nil
            } label: {
                Image(systemName: "viewfinder").imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Fit (double-click)")
            .accessibilityLabel("Fit mockup")
        }
        Button {
            open("/artifacts/\(card.artifactID)?edit=1")
        } label: {
            Label("Open editor", systemImage: "pencil").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .help("Open the mockup editor (\u{2318}-click for a new tab)")
    }

    private func versionLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.palette.secondaryText)
    }

    /// In place, or in a new tab when ⌘ is held, like a link in the transcript.
    private func open(_ path: String) {
        if NSEvent.modifierFlags.contains(.command) {
            context.openInNewTab(path)
        } else {
            context.navigate(path)
        }
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(title: String) -> some View {
        if let drawing {
            let size = drawing.size
            let height = min(Self.maxStageHeight, max(Self.minStageHeight, size.height + 2 * ArtifactDetailLogic.fitPad))
            GeometryReader { geo in
                let pane = ArtifactDetailLogic.MockupSize(width: geo.size.width, height: geo.size.height)
                let cam = camera ?? ArtifactDetailLogic.fitView(drawing: size, viewport: pane)
                canvas(drawing, camera: cam, pane: pane, title: title)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        } else if drawFailed {
            Text("This mockup couldn\u{2019}t be drawn. Open it in the editor to see its source.")
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: Self.minStageHeight)
                .accessibilityLabel("Drawing mockup")
        }
    }

    private func canvas(_ drawing: MockupRendering.Drawing, camera cam: ArtifactDetailLogic.MockupCamera,
                        pane: ArtifactDetailLogic.MockupSize, title: String) -> some View {
        ZStack(alignment: .topLeading) {
            theme.swiftUIColor("surface-sunken", fallback: theme.palette.background)
            Image(nsImage: drawing.image)
                .resizable()
                .frame(width: drawing.size.width * cam.scale, height: drawing.size.height * cam.scale)
                .background(Color.white)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                .offset(x: cam.x, y: cam.y)
                .accessibilityLabel(title)
            if drawing.isLegacy {
                Text("Legacy SVG: drawn by WebKit")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.palette.surface.opacity(0.92), in: Capsule())
                    .padding(8)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        // Only zoom is taken: a plain scroll over the card keeps scrolling the transcript.
        .onCanvasScrollWheel { action in
            guard case .zoom(let factor, let x, let y) = action else { return false }
            camera = ArtifactDetailLogic.zoomAt(cam, factor: factor, px: x, py: y)
            return true
        }
        .onTapGesture(count: 2) { camera = nil }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = magnifyStart ?? cam
                    if magnifyStart == nil { magnifyStart = base }
                    camera = ArtifactDetailLogic.zoomAt(base, factor: Double(value.magnification),
                                                        px: Double(value.startLocation.x), py: Double(value.startLocation.y))
                }
                .onEnded { _ in magnifyStart = nil }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let base = dragStart ?? cam
                    if dragStart == nil { dragStart = base }
                    camera = ArtifactDetailLogic.panBy(base, dx: Double(value.translation.width), dy: Double(value.translation.height))
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    // MARK: Review

    @ViewBuilder
    private func reviewBar(_ card: ChatMockupCard, artifact: API.Artifact, standing: ChatMockupCard.Standing) -> some View {
        let p = theme.palette
        Group {
            switch standing {
            case .current(let label, let review) where review.isDecided && !reconsidering:
                decided(label: label, review: review, version: artifact.versions.first { $0.id == card.versionID })
            case .current:
                decisionForm(card)
            case .superseded(_, let currentLabel):
                HStack(spacing: 8) {
                    Text("A newer version\(currentLabel.isEmpty ? "" : " (\(currentLabel))") exists, so this one can\u{2019}t be reviewed here.")
                        .foregroundStyle(p.secondaryText)
                    Spacer(minLength: 8)
                    Button("Review latest") { open("/artifacts/\(card.artifactID)/review") }
                        .buttonStyle(.vesper())
                }
            case .missing:
                Text("This version isn\u{2019}t one of the mockup\u{2019}s.")
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .font(.system(size: theme.pointSize(.small)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(p.rowBorder).frame(height: 1) }
    }

    private func decided(label: String, review: ChatMockupCard.Review, version: API.ArtifactVersion?) -> some View {
        let p = theme.palette
        let approved = review == .approved
        let by = version?.review?.reviewedBy?.name
        let reviewNote = version?.review?.note ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: approved ? "checkmark.circle.fill" : "exclamationmark.bubble.fill")
                .foregroundStyle(theme.swiftUIColor(approved ? "pill-done-fg" : "pill-human-fg", fallback: approved ? .green : .orange))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(approved ? "Approved" : "Changes requested on") \(label)\(by.map { " by \($0)" } ?? "")")
                    .foregroundStyle(p.text)
                if !reviewNote.isEmpty {
                    Text(reviewNote)
                        .foregroundStyle(p.secondaryText)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Change decision") { reconsidering = true }
                .buttonStyle(.vesper())
        }
    }

    private func decisionForm(_ card: ChatMockupCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Note for the persona (required to request changes)", text: $note, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(deciding)
            HStack(spacing: 8) {
                if let reviewError {
                    Text(reviewError)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if reconsidering {
                    Button("Cancel") { reconsidering = false }
                        .buttonStyle(.vesper())
                        .disabled(deciding)
                }
                Button("Request changes") { Task { await decide(card, .changesRequested) } }
                    .buttonStyle(.vesper(.outline))
                    .disabled(deciding || !ChatMockupCard.canSend(changesRequested: true, note: note))
                    .help("Say what should change in the note")
                Button("Approve") { Task { await decide(card, .approved) } }
                    .buttonStyle(.vesper(.approve))
                    .disabled(deciding || drawing == nil && !drawFailed)
            }
        }
    }

    private func decide(_ card: ChatMockupCard, _ decision: API.ReviewArtifactVersionBody.Decision) async {
        guard let client = context.store.client, !deciding else { return }
        deciding = true
        reviewError = nil
        defer { deciding = false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await MockupRendering.review(
                client: client,
                artifactId: card.artifactID,
                versionId: card.versionID,
                source: drawnSource,
                drawing: drawing,
                decision: decision,
                note: trimmed.isEmpty ? nil : trimmed
            )
            note = ""
            reconsidering = false
            context.store.invalidate(QueryInvalidation(resources: ["artifacts"]))
            await context.store.refetch(API.getArtifact(id: card.artifactID))
        } catch {
            reviewError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: Drawing

    /// Draws exactly the card's version (fetched by id, so a newer version doesn't replace it).
    private func draw(_ card: ChatMockupCard) async {
        guard drawnSource == nil else { return }
        guard let client = context.store.client,
              let fetched = await MockupRendering.source(client: client, artifactId: card.artifactID, versionId: card.versionID),
              !fetched.isEmpty else {
            if !Task.isCancelled { drawFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        if let drawn = MockupRendering.draw(source: fetched) {
            drawing = drawn
            drawnSource = fetched
        } else if !Task.isCancelled {
            drawFailed = true
        }
    }
}
