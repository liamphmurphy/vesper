import AppKit
import SwiftUI
import VesperCore

/// Native SwiftUI SVG mockup editor (`/artifacts/:id?edit=1`): Visual (the native canvas), Source
/// and Split modes, Undo/Redo, zoom, version note, Save version, and Save & approve.
///
/// The canvas draws with the same renderer as the viewer and review screens, and only edits
/// mockups that conform to profile v1 (docs/dev/mockup-svg-profile.md). A legacy version opens
/// in Source mode with the problems listed, so the person can bring it into the profile.
struct MockupEditorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    enum Mode: String, CaseIterable {
        case visual, source, split
        var label: String {
            switch self {
            case .visual: "Visual"
            case .source: "Source"
            case .split: "Split"
            }
        }
    }

    let artifact: API.Artifact
    let onDone: () -> Void

    @State private var baseline: String
    @State private var history: MockupEditorLogic.SourceHistory
    @State private var mode: Mode
    @State private var zoom: ArtifactDetailLogic.MockupZoomMode = .fit
    @State private var note = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var canvas = MockupCanvasModel()

    init(artifact: API.Artifact, onDone: @escaping () -> Void) {
        self.artifact = artifact
        self.onDone = onDone
        let initial = artifact.bodyMd ?? ""
        _baseline = State(initialValue: initial)
        _history = State(initialValue: MockupEditorLogic.SourceHistory(initial: initial))
        _mode = State(initialValue: MockupSVGProfile.conforms(initial) ? .visual : .source)
    }

    private var source: String { history.current }
    private var violations: [MockupSVGViolation] { canvas.violations }
    private var isDirty: Bool { source != baseline }
    private var canSave: Bool { violations.isEmpty && isDirty && !saving }
    private var selection: String? { canvas.selection.flatMap { $0.isEmpty ? nil : $0 } }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(p.surface)

            Divider().overlay(p.border)

            if mode != .source {
                shapeBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(p.surface)
                Divider().overlay(p.border)
            }

            if let errorMessage {
                banner(icon: "exclamationmark.triangle.fill", tint: .red, text: errorMessage)
            } else if !violations.isEmpty {
                banner(icon: "exclamationmark.circle", tint: .orange, text: violationSummary)
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    if mode == .visual || mode == .split {
                        visualCanvas
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if mode == .split {
                        Divider().overlay(p.border)
                    }
                    if mode == .source || mode == .split {
                        TextEditor(text: Binding(
                            get: { history.current },
                            set: { history.commit($0, key: "source") }
                        ))
                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                        .frame(width: mode == .split ? max(320, geo.size.width * 0.38) : nil)
                        .frame(maxWidth: mode == .source ? .infinity : nil, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(p.background)
        .onAppear { canvas.update(source: source) }
        .onChange(of: history.current) { _, next in canvas.update(source: next) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            HStack(spacing: 4) {
                Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.vesper(.outline))
                    .disabled(!history.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo")
                Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(.vesper(.outline))
                    .disabled(!history.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo")
            }

            if mode != .source {
                Picker("Zoom", selection: $zoom) {
                    ForEach(ArtifactDetailLogic.MockupZoomMode.allCases, id: \.self) { z in Text(z.label).tag(z) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
            }

            TextField("Version note (optional)", text: $note)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)

            Spacer(minLength: 8)

            Button("Cancel") { handleCancel() }
                .buttonStyle(.vesper(.outline))
            Button("Save version") { Task { await save(approve: false) } }
                .buttonStyle(.vesper(.outline))
                .disabled(!canSave)
            Button("Save & approve") { Task { await save(approve: true) } }
                .buttonStyle(.vesper(.primary))
                .disabled(!canSave)
        }
    }

    private var shapeBar: some View {
        HStack(spacing: 6) {
            ForEach(MockupSVGShapeKind.allCases, id: \.self) { kind in
                Button("+ \(kind.rawValue.capitalized)") { apply(MockupSVGEditing.insert(source, kind: kind, center: nil)) }
                    .buttonStyle(.vesper(.outline))
                    .controlSize(.small)
            }
            Divider().frame(height: 16)
            Button("Duplicate") { applySelected(MockupSVGEditing.duplicate) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Forward") { applySelected(MockupSVGEditing.bringForward) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Backward") { applySelected(MockupSVGEditing.sendBackward) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Delete") { applySelected(MockupSVGEditing.delete) }
            Spacer()
            Text("Click to select · Drag to move · Handles resize · Double-click text to edit · Arrows nudge")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.tertiaryText)
        }
        .buttonStyle(.vesper(.outline))
        .controlSize(.small)
        .disabled(!canvas.canEdit)
        .environment(\.isEnabled, canvas.canEdit)
    }

    @ViewBuilder
    private var visualCanvas: some View {
        if canvas.document == nil {
            VStack(spacing: 8) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 28))
                    .foregroundStyle(theme.palette.tertiaryText)
                Text("This SVG uses features the native editor can\u{2019}t draw. Fix the problems above in Source to edit it visually.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.background))
        } else {
            HStack(spacing: 0) {
                MockupCanvasView(model: canvas, zoom: zoom) { result, key in apply(result, key: key) }
                    .allowsHitTesting(canvas.canEdit)
                    .opacity(canvas.isStale ? 0.55 : 1)
                Divider().overlay(theme.palette.border)
                MockupInspectorView(model: canvas) { result, key in apply(result, key: key) }
            }
        }
    }

    private func banner(icon: String, tint: Color, text: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.text)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(0.08))
            Divider().overlay(theme.palette.border)
        }
    }

    private var violationSummary: String {
        let shown = violations.prefix(3).map(\.message)
        let more = violations.count > 3 ? " (and \(violations.count - 3) more)" : ""
        let lead = source == baseline && !MockupSVGProfile.conforms(baseline)
            ? "This is a legacy mockup: it uses SVG the native renderer doesn\u{2019}t draw. "
            : ""
        return lead + shown.joined(separator: " · ") + more
    }

    // MARK: Edits

    private func apply(_ result: MockupSVGEditResult?, key: String? = nil) {
        guard let result else { return }
        history.commit(result.source, key: key)
        canvas.update(source: result.source)
        canvas.selection = result.selection
    }

    private func applySelected(_ op: (String, String) -> MockupSVGEditResult?) {
        guard let selection else { return }
        apply(op(source, selection))
    }

    private func undo() {
        _ = history.undo()
        canvas.update(source: history.current)
    }

    private func redo() {
        _ = history.redo()
        canvas.update(source: history.current)
    }

    private func handleCancel() {
        if !isDirty {
            onDone()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard your unsaved changes to this mockup?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep editing")
        if alert.runModal() == .alertFirstButtonReturn {
            onDone()
        }
    }

    private func save(approve: Bool) async {
        guard canSave, let client = context.store.client else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }

        var form = APIMultipartForm()
        form.addField("body_md", source)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { form.addField("note", trimmedNote) }

        let saved: API.Artifact
        do {
            saved = try await client.send(API.createArtifactVersion(id: artifact.id, body: form), timeout: 120)
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            return
        }

        baseline = source
        context.store.invalidate(QueryInvalidation(resources: ["artifacts", "knowledge"]))

        if approve {
            do {
                // The server may have normalized the source; snapshot what it stored.
                _ = try await MockupRendering.review(
                    client: client,
                    artifactId: artifact.id,
                    versionId: saved.currentVersion.id,
                    source: saved.bodyMd ?? source,
                    decision: .approved,
                    note: nil
                )
                context.store.invalidate(QueryInvalidation(resources: ["artifacts"]))
            } catch {
                errorMessage = "Saved as \(saved.currentVersion.label), but approving failed: \((error as? APIError)?.userMessage ?? error.localizedDescription)"
                return
            }
        }

        await context.store.refetch(API.getArtifact(id: artifact.id))
        onDone()
    }
}
