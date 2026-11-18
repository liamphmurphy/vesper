import AppKit
import Observation
import SwiftUI
import VesperCore

/// File › Import Backup…: pick a .zip, inspect it with `vesper app-import -inspect`, ask which
/// secrets key to use (or to drop the secrets), then stop the stack, run the import into the data
/// directory and start the stack again. Progress and errors show in a sheet (desktop main.ts
/// `vesper:import-backup`, stack.ts).
@MainActor
final class ImportBackupFlow {
    private weak var aux: AuxWindows?
    private var window: NSWindow?
    private var parent: NSWindow?
    private var model: ImportModel?

    init(aux: AuxWindows) { self.aux = aux }

    func start() {
        guard let aux, let app = aux.app else { return }
        if window != nil { window?.makeKeyAndOrderFront(nil); return }
        guard let stack = app.stack else {
            Self.alert("Import isn't available here", "Importing a backup needs the local Vesper stack, which isn't running in this session.")
            return
        }
        guard let resources = BundledResources.locate().flatMap({ BundledResources.resolve(baseDir: $0) }) else {
            Self.alert("Import isn't available", "The bundled Vesper runtime isn't available in this build.")
            return
        }
        NSApp.activate()
        let open = NSOpenPanel()
        open.title = "Import Vesper Backup"
        open.message = "Choose a Vesper backup (.zip) to restore."
        open.prompt = "Choose"
        open.allowedContentTypes = [.zip]
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        present(archive: url, resources: resources, stack: stack, aux: aux, app: app)
    }

    /// Starts the flow on a known archive (the debug hook uses this to skip the open panel).
    func present(archive: URL, resources: BundledResources, stack: StackController, aux: AuxWindows, app: AppModel) {
        let model = ImportModel(archive: archive, resources: resources, stack: stack, app: app, aux: aux)
        model.finish = { [weak self] in self?.dismiss() }
        self.model = model
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Import Vesper Backup"
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = NSHostingController(rootView: ImportBackupView(model: model))
        window = sheet
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.isVisible {
            self.parent = parent
            parent.beginSheet(sheet)
        } else {
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
        Task { await model.inspect() }
    }

    /// VESPER_DEBUG only: waits for the review step, picks "import without secrets" and presses Import.
    func debugRun() {
        Task {
            for _ in 0..<60 where model?.phase != .review { try? await Task.sleep(for: .milliseconds(500)) }
            model?.choice = .drop
            await model?.runImport()
        }
    }

    private func dismiss() {
        guard let window else { return }
        if let parent, parent.sheets.contains(window) { parent.endSheet(window) }
        window.orderOut(nil)
        window.contentViewController = nil
        self.window = nil
        parent = nil
        model = nil
    }

    static func alert(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable { case inspecting, review, working(String), failed(String), done }
    enum SecretsChoice { case useKey, drop }

    let archive: URL
    var phase: Phase = .inspecting
    var inspection: BackupInspection?
    var choice: SecretsChoice = .useKey
    var keyText = ""
    var keyError: String?
    @ObservationIgnored var finish: () -> Void = {}
    @ObservationIgnored private let resources: BundledResources
    @ObservationIgnored private let stack: StackController
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private weak var aux: AuxWindows?

    init(archive: URL, resources: BundledResources, stack: StackController, app: AppModel, aux: AuxWindows) {
        self.archive = archive
        self.resources = resources
        self.stack = stack
        self.app = app
        self.aux = aux
    }

    /// Whether the person has to say what to do with the archive's secrets.
    var needsKeyChoice: Bool { (inspection?.hasEncryptedSecrets ?? false) && !(inspection?.matchesCurrentKey ?? false) }

    private var scratch: Bool { AuxWindows.isScratchRun }

    /// The key this Mac's stack uses (what `matchesCurrentKey` is measured against).
    private func currentKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if scratch { return env["VESPER_SCRATCH_SECRETS_KEY"] }
        return try? SecretsKeyStore(dataDirectory: stack.dataDirectory).load()
    }

    func inspect() async {
        do {
            inspection = try await BackupImport.inspect(vesperBin: resources.vesperBin, archive: archive.path, currentKey: currentKey())
            phase = .review
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func runImport() async {
        guard let app, inspection != nil else { return }
        keyError = nil
        var key: String?
        var drop = false
        if needsKeyChoice {
            if choice == .drop {
                drop = true
            } else {
                do { key = try SecretsKeyStore.validate(keyText) } catch { keyError = "That isn't a secrets key. It's 32 bytes, base64 encoded."; return }
                phase = .working("Checking the key…")
                let check = try? await BackupImport.inspect(vesperBin: resources.vesperBin, archive: archive.path, currentKey: key)
                guard check?.matchesCurrentKey == true else {
                    phase = .review
                    keyError = "That key doesn't match this backup."
                    return
                }
            }
        } else if inspection?.hasEncryptedSecrets == true {
            key = currentKey()
        }
        if await aux?.hasActiveRuns() == true, !confirmActiveRuns() { phase = .review; return }

        phase = .working("Stopping Vesper…")
        await stack.stop()
        phase = .working("Importing the backup… this can take a few minutes.")
        do {
            try await BackupImport.run(
                vesperBin: resources.vesperBin, postgresBinDir: resources.postgresBinDir,
                dataDirectory: stack.dataDirectory.path, archive: archive.path, secretsKey: key, dropSecrets: drop
            )
        } catch {
            phase = .working("Restarting Vesper…")
            await stack.start()
            phase = .failed(error.localizedDescription)
            return
        }
        if let key, needsKeyChoice, !scratch {
            // The imported data is sealed with this key; the stack reads it from the Keychain on start.
            do { _ = try SecretsKeyStore(dataDirectory: stack.dataDirectory).save(key) } catch {
                phase = .failed("The backup was imported, but its secrets key couldn't be saved to the Keychain: \(error.localizedDescription)")
                return
            }
        }
        phase = .working("Starting Vesper…")
        app.settings.reload()
        await stack.start()
        phase = .done
    }

    private func confirmActiveRuns() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Runs are still working."
        alert.informativeText = "Importing a backup stops the local Vesper stack and replaces the current database and files."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Import Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

struct ImportBackupView: View {
    @Bindable var model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .inspecting:
                progress("Reading the backup…")
            case .review:
                review
            case .working(let text):
                progress(text)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label("The import didn't finish", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
                    Text(message).textSelection(.enabled).foregroundStyle(.secondary)
                    Spacer()
                    HStack { Spacer(); Button("Close") { model.finish() }.keyboardShortcut(.defaultAction) }
                }
            case .done:
                VStack(alignment: .leading, spacing: 10) {
                    Label("Backup imported", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                    Text("Vesper is running with the imported data.").foregroundStyle(.secondary)
                    Spacer()
                    HStack { Spacer(); Button("Done") { model.finish() }.keyboardShortcut(.defaultAction) }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(model.archive.lastPathComponent)?").font(.headline).lineLimit(2)
            if let i = model.inspection {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Exported", i.exportedAt)
                    row("Vesper", i.appVersion.isEmpty ? "unknown" : i.appVersion)
                    row("Contents", "\(i.tableCount) tables, \(i.totalRows) rows, \(i.objectCount) files")
                }
                .font(.callout)
            }
            Text("This stops Vesper and replaces the current database and files with the backup, then starts Vesper again.")
                .font(.callout).foregroundStyle(.secondary)
            if model.needsKeyChoice {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This backup's secrets are sealed with the key of the Mac it was made on.")
                            .font(.callout)
                        Picker("Secrets", selection: $model.choice) {
                            Text("Use that Mac's secrets key").tag(ImportModel.SecretsChoice.useKey)
                            Text("Import without secrets").tag(ImportModel.SecretsChoice.drop)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        if model.choice == .useKey {
                            SecureField("Secrets key (base64)", text: $model.keyText)
                        } else {
                            Text("Stored secrets (API keys, connector credentials) are cleared; you enter them again.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let e = model.keyError { Text(e).foregroundStyle(.red).font(.callout) }
                    }
                }
            } else if model.inspection?.hasEncryptedSecrets == true {
                Label("Its secrets match this Mac's key.", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { model.finish() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await model.runImport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.needsKeyChoice && model.choice == .useKey && model.keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
