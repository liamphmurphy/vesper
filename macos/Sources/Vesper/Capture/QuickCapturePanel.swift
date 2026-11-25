import AppKit
import Observation
import SwiftUI
import VesperCore

/// A floating panel for a note, a message to a persona or a ticket (desktop capture.html). It does
/// not activate Vesper, so it appears over whatever app (or full-screen Space) the person is in.
@MainActor
final class QuickCaptureController {
    private weak var aux: AuxWindows?
    private var panel: FloatingPanel?
    private var model: QuickCaptureModel?

    init(aux: AuxWindows) { self.aux = aux }

    func show(prefill: String? = nil, autoSave: Bool = false) {
        guard let aux else { return }
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let model = QuickCaptureModel(aux: aux)
        if let prefill { model.text = prefill }
        model.close = { [weak self] in self?.close() }
        self.model = model
        let panel = FloatingPanel(size: NSSize(width: 540, height: 330), title: "Quick Capture")
        panel.onEscape = { [weak self] in self?.close() }
        panel.contentViewController = NSHostingController(rootView: QuickCaptureView(model: model))
        panel.setContentSize(NSSize(width: 540, height: 330))
        panel.centerOnActiveScreen()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        Task { await aux.options.refreshIfStale(); model.optionsLoaded() }
        if autoSave { Task { try? await Task.sleep(for: .milliseconds(600)); await model.save() } }
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        model = nil
    }
}

/// A key, non-activating panel that floats above other apps and takes standard text commands even
/// though the app isn't active.
final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(size: NSSize, title: String) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return center() }
        let size = self.frame.size
        setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.58 - size.height / 2))
    }

    /// The app may be inactive, so the main menu's Edit items don't see the key; route them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch key {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = Selector(("undo:"))
        default: action = nil
        }
        if let action, let responder = firstResponder, responder.tryToPerform(action, with: nil) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
@Observable
final class QuickCaptureModel {
    struct Saved { var message: String; var href: String? }

    var kind: CaptureKind = .note
    var text = ""
    var personaId = ""
    var error: String?
    var saving = false
    var saved: Saved?
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored private weak var aux: AuxWindows?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init(aux: AuxWindows) {
        self.aux = aux
        optionsLoaded()
    }

    var options: CaptureOptionsStore? { aux?.options }
    var shortcutLabel: String? {
        guard let s = aux?.app?.settings.settings.quickCapture, s.enabled else { return nil }
        return Capture.formatAccelerator(s.shortcut)
    }

    /// Picks defaults once the lists are known: the default persona.
    func optionsLoaded() {
        guard let options else { return }
        if personaId.isEmpty { personaId = options.defaultPersonaId }
    }

    func save() async {
        guard !saving, saved == nil, let aux else { return }
        error = nil
        let input = CaptureInput(kind: kind, text: text, personaId: kind == .message ? personaId : nil)
        let call: APICall
        switch Capture.buildCaptureRequest(input) {
        case .failure(let e): error = e.message; return
        case .success(let c): call = c
        }
        guard let client = aux.client() else { error = "Vesper isn't ready yet."; return }
        saving = true
        defer { saving = false }
        do {
            let response = try await client.send(call, timeout: 30)
            let href = Capture.captureResultHref(kind, response: response)
            let label = kind == .note ? "Note saved" : "Message sent"
            saved = Saved(message: label, href: href)
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.close()
            }
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openResult() {
        if let href = saved?.href { aux?.openHref(href) }
        close()
    }
}

struct QuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let saved = model.saved { confirmation(saved) } else { editor }
        }
        .padding(.top, 8)
        .frame(width: 540, height: 330)
        .background(.regularMaterial)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Capture", selection: $model.kind) {
                Text("Note").tag(CaptureKind.note)
                Text("Message").tag(CaptureKind.message)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(6)
                if model.text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 14).allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

            HStack {
                switch model.kind {
                case .message:
                    Picker("Persona", selection: $model.personaId) {
                        Text("Default persona").tag("")
                        ForEach(model.options?.personas ?? [], id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .frame(maxWidth: 260)
                case .note:
                    Text("Saved to your knowledge base.").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
            }

            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
            }

            HStack {
                Text(model.shortcutLabel.map { "\($0) opens this · Esc closes" } ?? "Esc closes")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.close() }
                Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.saving)
            }
        }
        .padding([.horizontal, .bottom], 16)
        .onAppear { focused = true }
    }

    private var placeholder: String {
        switch model.kind {
        case .note: return "Jot something down…"
        case .message: return "Message a persona…"
        }
    }

    private func confirmation(_ saved: QuickCaptureModel.Saved) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text(saved.message).font(.title3.weight(.semibold))
            HStack {
                if saved.href != nil { Button("Open in Vesper") { model.openResult() }.buttonStyle(.borderedProminent) }
                Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
