import AppKit
import SwiftUI
import VesperCore
import WebKit

/// Native SwiftUI SVG mockup editor (`/artifacts/:id?edit=1`), replacing the web React MockupEditor
/// and `HostedWebPageView`. Supports Visual (offline sanitized SVG DOM canvas), Source, and Split
/// modes, Undo/Redo, zoom, version note, Save version, and Save & approve.
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

    init(artifact: API.Artifact, onDone: @escaping () -> Void) {
        self.artifact = artifact
        self.onDone = onDone
        let initial = artifact.bodyMd ?? ""
        _baseline = State(initialValue: initial)
        _history = State(initialValue: MockupEditorLogic.SourceHistory(initial: initial))
        _mode = State(initialValue: MockupEditorLogic.svgValidationError(initial) == nil ? .visual : .source)
    }

    private var source: String { history.current }
    private var validationError: String? { MockupEditorLogic.svgValidationError(source) }
    private var isDirty: Bool { source != baseline }
    private var canSave: Bool { validationError == nil && isDirty && !saving }

    var body: some View {
        let p = theme.palette
        VStack(spacing: 0) {
            // Editor toolbar
            HStack(spacing: 10) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)

                HStack(spacing: 4) {
                    Button { _ = history.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.vesper(.outline))
                        .disabled(!history.canUndo)
                        .help("Undo")
                    Button { _ = history.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .buttonStyle(.vesper(.outline))
                        .disabled(!history.canRedo)
                        .help("Redo")
                }

                if mode != .source {
                    Picker("Zoom", selection: $zoom) {
                        ForEach(ArtifactDetailLogic.MockupZoomMode.allCases, id: \.self) { z in
                            Text(z.label).tag(z)
                        }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(p.surface)

            Divider().overlay(p.border)

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(p.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.08))
                Divider().overlay(p.border)
            } else if let validationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Color.orange)
                    Text(validationError)
                        .font(.system(size: 12))
                        .foregroundStyle(p.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.orange.opacity(0.08))
                Divider().overlay(p.border)
            }

            // Content area
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if mode == .visual || mode == .split {
                        MockupCanvasWebView(
                            source: source,
                            zoom: zoom,
                            dark: theme.mode == .dark,
                            onCommit: { next, key in
                                history.commit(next, key: key)
                            }
                        )
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
                        .frame(width: mode == .split ? max(320, geo.size.width * 0.42) : nil)
                        .frame(maxWidth: mode == .source ? .infinity : nil, maxHeight: .infinity)
                    }
                }
            }
        }
        .background(p.background)
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
                _ = try await client.send(API.reviewArtifactVersion(
                    id: artifact.id,
                    versionId: saved.currentVersion.id,
                    body: API.ReviewArtifactVersionBody(decision: .approved, note: nil)
                ))
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

// MARK: - Offline SVG Canvas WKWebView

private struct MockupCanvasWebView: NSViewRepresentable {
    let source: String
    let zoom: ArtifactDetailLogic.MockupZoomMode
    let dark: Bool
    let onCommit: (String, String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.userContentController.add(context.coordinator, name: "vesperMockup")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = wv
        context.coordinator.pendingSource = source
        context.coordinator.pendingZoom = zoomArg(zoom)
        context.coordinator.pendingDark = dark
        wv.loadHTMLString(MockupEditorLogic.visualCanvasHTML(dark: dark), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        c.onCommit = onCommit
        c.sync(source: source, zoom: zoomArg(zoom), dark: dark)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "vesperMockup")
    }

    private func zoomArg(_ z: ArtifactDetailLogic.MockupZoomMode) -> String {
        switch z {
        case .fit: "fit"
        case .actual: "100"
        case .double: "200"
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onCommit: (String, String?) -> Void
        var ready = false
        var pendingSource = ""
        var pendingZoom = "fit"
        var pendingDark = false
        var lastPushedSource = ""
        var lastPushedZoom = ""
        var lastPushedDark: Bool?

        init(onCommit: @escaping (String, String?) -> Void) {
            self.onCommit = onCommit
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" {
                ready = true
                pushAll()
            } else if type == "commit", let src = body["source"] as? String {
                lastPushedSource = src
                let key = body["key"] as? String
                onCommit(src, key)
            }
        }

        func sync(source: String, zoom: String, dark: Bool) {
            pendingSource = source
            pendingZoom = zoom
            pendingDark = dark
            if ready { pushAll() }
        }

        private func pushAll() {
            guard let wv = webView else { return }
            if lastPushedDark != pendingDark {
                lastPushedDark = pendingDark
                wv.callAsyncJavaScript("window.__vesperSetTheme(dark)", arguments: ["dark": pendingDark], in: nil, in: .page, completionHandler: nil)
            }
            if lastPushedSource != pendingSource {
                lastPushedSource = pendingSource
                wv.callAsyncJavaScript("window.__vesperSetSource(src)", arguments: ["src": pendingSource], in: nil, in: .page, completionHandler: nil)
            }
            if lastPushedZoom != pendingZoom {
                lastPushedZoom = pendingZoom
                wv.callAsyncJavaScript("window.__vesperSetZoom(z)", arguments: ["z": pendingZoom], in: nil, in: .page, completionHandler: nil)
            }
        }
    }
}
