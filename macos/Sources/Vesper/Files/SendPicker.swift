import AppKit
import Observation
import SwiftUI
import VesperCore

/// "Send to Vesper": which chat should these files go to? One panel at a time; files that arrive
/// while it is open replace its list (desktop send-files.html).
@MainActor
final class SendPickerController: NSObject, NSWindowDelegate {
    private weak var aux: AuxWindows?
    private var panel: NSPanel?
    private var model: SendPickerModel?

    init(aux: AuxWindows) { self.aux = aux }

    /// `cleanup` runs when the picker closes (a screenshot's temp folder is removed there).
    func present(accepted: [AcceptedFile], rejected: [RejectedFile], cleanup: (() -> Void)? = nil) {
        vlog("send picker: \(accepted.count) accepted, \(rejected.count) rejected")
        guard let aux else { vlog("send picker: no aux"); return }
        if let model, let panel {
            model.replace(accepted: accepted, rejected: rejected, cleanup: cleanup)
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = SendPickerModel(aux: aux, accepted: accepted, rejected: rejected, cleanup: cleanup)
        model.close = { [weak self] in self?.panel?.close() }
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Send to Vesper"
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: SendPickerView(model: model))
        panel.setContentSize(NSSize(width: 520, height: 520))
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.load() }
    }

    /// VESPER_DEBUG only: presses Send.
    func debugSubmit() { Task { await model?.send() } }

    func windowWillClose(_ notification: Notification) {
        model?.runCleanup()
        guard let panel else { return }
        self.panel = nil
        model = nil
        // AppKit is still inside `close()` on the panel here, and Cancel reaches it from the panel's
        // own SwiftUI action; freeing the panel or its hosting controller now is a use-after-free.
        // Let them go on the next main-queue turn.
        DispatchQueue.main.async { panel.contentViewController = nil }
    }
}

@MainActor
@Observable
final class SendPickerModel {
    var accepted: [AcceptedFile]
    var rejected: [RejectedFile]
    var chats: [ChatSummary] = []
    var target = "new"
    var personaId = ""
    var message = ""
    var error: String?
    var sending = false
    var progress = ""
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored private weak var aux: AuxWindows?
    @ObservationIgnored private var cleanup: (() -> Void)?

    init(aux: AuxWindows, accepted: [AcceptedFile], rejected: [RejectedFile], cleanup: (() -> Void)?) {
        self.aux = aux
        self.accepted = accepted
        self.rejected = rejected
        self.cleanup = cleanup
        if accepted.isEmpty { error = "None of these can be attached." }
    }

    var options: CaptureOptionsStore? { aux?.options }
    var title: String { accepted.count == 1 ? "Send 1 file to a chat" : "Send \(accepted.count) files to a chat" }
    var placeholder: String { accepted.count == 1 ? "Here's this file." : "Here's these files." }

    func replace(accepted: [AcceptedFile], rejected: [RejectedFile], cleanup newCleanup: (() -> Void)?) {
        runCleanup()
        cleanup = newCleanup
        self.accepted = accepted
        self.rejected = rejected
        error = accepted.isEmpty ? "None of these can be attached." : nil
    }

    func runCleanup() {
        cleanup?()
        cleanup = nil
    }

    func load() async {
        guard let aux, let client = aux.client() else { return }
        await aux.options.refreshIfStale()
        personaId = aux.options.defaultPersonaId
        if let data = try? await client.request("GET", "/api/v1/chats?persona_id=all") { chats = CaptureOptions.parseChats(data) }
    }

    func send() async {
        guard !sending, !accepted.isEmpty, let aux else { return }
        guard let client = aux.client() else { error = "Vesper isn't ready yet."; return }
        error = nil
        sending = true
        defer { sending = false; progress = "" }
        var ids: [String] = []
        for (i, file) in accepted.enumerated() {
            progress = "Uploading \(i + 1) of \(accepted.count)…"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else { error = "Couldn't read \(file.name)."; return }
            do {
                ids.append(try await client.uploadAttachment(fileName: file.name, mime: file.mime, data: data))
            } catch let e as APIError {
                error = "\(file.name): \(e.userMessage)"
                return
            } catch {
                self.error = "\(file.name): upload failed"
                return
            }
        }
        progress = "Sending…"
        let call: APICall
        switch Drop.buildSendFilesRequest(SendFilesInput(target: target, personaId: personaId, message: message, attachmentIds: ids)) {
        case .failure(let e): error = e.message; return
        case .success(let c): call = c
        }
        do {
            let response = try await client.send(call, timeout: 30)
            let chatId = target == "new" ? ((response as? [String: Any])?["id"] as? String) : target
            let href = chatId.flatMap { Capture.captureResultHref(.message, response: ["id": $0]) }
            close()
            aux.openHref(href ?? "/chat")
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SendPickerView: View {
    @Bindable var model: SendPickerModel

    private func sizeLabel(_ n: Int) -> String {
        n >= 1024 * 1024 ? String(format: "%.1f MB", Double(n) / 1024 / 1024) : "\(max(1, Int((Double(n) / 1024).rounded()))) KB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title).font(.title3.weight(.semibold)).padding([.horizontal, .top], 20).padding(.bottom, 10)
            List {
                ForEach(model.accepted, id: \.path) { file in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 20, height: 20)
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(sizeLabel(file.size)).foregroundStyle(.secondary).font(.callout)
                    }
                }
                ForEach(model.rejected, id: \.name) { file in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text(file.name).lineLimit(1).truncationMode(.middle)
                            Text(file.reason).foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
            }
            .frame(minHeight: 120)

            Form {
                Picker("Send to", selection: $model.target) {
                    Text("New chat").tag("new")
                    if !model.chats.isEmpty {
                        Divider()
                        ForEach(model.chats) { Text($0.title.isEmpty ? "Untitled chat" : $0.title).tag($0.id) }
                    }
                }
                if model.target == "new" {
                    Picker("Persona", selection: $model.personaId) {
                        Text("Default persona").tag("")
                        ForEach(model.options?.personas ?? [], id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                TextField("Message", text: $model.message, prompt: Text(model.placeholder), axis: .vertical)
                    .lineLimit(1...3)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: model.target == "new" ? 180 : 140)

            HStack {
                if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(2) }
                else if !model.progress.isEmpty { ProgressView().controlSize(.small); Text(model.progress).foregroundStyle(.secondary).font(.callout) }
                Spacer()
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Send") { Task { await model.send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.sending || model.accepted.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 520)
    }
}
