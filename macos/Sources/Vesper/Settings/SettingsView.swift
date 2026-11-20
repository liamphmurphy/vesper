import AppKit
import Observation
import SwiftUI
import VesperCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, notifications, shortcuts, files, workspaces, power, backups, security, updates
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .notifications: return "Notifications"
        case .shortcuts: return "Shortcuts"
        case .files: return "Files & Links"
        case .workspaces: return "Workspaces"
        case .power: return "Power & Stack"
        case .backups: return "Backups"
        case .security: return "Security"
        case .updates: return "Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notifications: return "bell"
        case .shortcuts: return "keyboard"
        case .files: return "doc.on.doc"
        case .workspaces: return "folder"
        case .power: return "bolt"
        case .backups: return "externaldrive"
        case .security: return "touchid"
        case .updates: return "arrow.down.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsSection = .general
}

struct SettingsView: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                Text("Vesper \(AuxWindows.currentVersion)").font(.caption).foregroundStyle(.secondary).padding(10)
            }
        } detail: {
            SettingsDetail(aux: aux, section: navigation.selection)
                .navigationTitle(navigation.selection.title)
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// One section's form. Reads settings from the store (observed) and writes through `aux.update`.
struct SettingsDetail: View {
    let aux: AuxWindows
    let section: SettingsSection

    @State private var testMessage: String?
    @State private var quickActionsError: String?
    @State private var touchIdMessage: String?
    @State private var exportMessage: String?
    @State private var editingBackupPassword = false
    @State private var backupPassword = ""
    @State private var backupPasswordConfirm = ""
    @State private var backupPasswordError: String?
    @State private var backupPasswordMessage: String?
    @State private var savingBackupPassword = false
    @State private var restartMessage: String?
    @State private var updateMessage: String?

    private var s: NativeSettings { aux.app?.settings.settings ?? NativeSettings() }
    private var state: AuxState { aux.state }

    private func bind<T>(_ keyPath: WritableKeyPath<NativeSettings, T>) -> Binding<T> {
        Binding(get: { s[keyPath: keyPath] }, set: { v in aux.update { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        Form {
            switch section {
            case .general: general
            case .notifications: notifications
            case .shortcuts: shortcuts
            case .files: files
            case .workspaces: workspaces
            case .power: power
            case .backups: backups
            case .security: security
            case .updates: updates
            }
        }
        .formStyle(.grouped)
        .task(id: section) {
            if section == .backups {
                await aux.refreshBackupEncryption()
            }
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: General

    private var lastWindowHint: String {
        switch s.tray.onLastWindowClose {
        case .dock: return "Vesper stays in the Dock and keeps running, and so do your runs."
        case .menuBar:
            return "The Dock icon hides and Vesper keeps running in the menu bar."
                + (s.tray.enabled ? "" : " Needs the menu bar icon; stays in the Dock until it's on.")
        case .quit: return "Vesper quits and stops its stack (asking first if runs are working)."
        }
    }

    @ViewBuilder private var general: some View {
        Section("Menu bar") {
            Toggle(isOn: bind(\.tray.enabled)) {
                Text("Show Vesper in the menu bar")
                Text("Stack status, the Needs-you count, items waiting on you and running runs.")
            }
            Toggle("Show the Needs-you count beside the icon", isOn: bind(\.tray.showCount)).disabled(!s.tray.enabled)
        }
        Section("Tabs") {
            Picker(selection: bind(\.tabs.layout)) {
                Text("Separate").tag(TabLayout.separate)
                Text("Compact").tag(TabLayout.compact)
            } label: {
                Text("Tab layout")
                Text(s.tabs.layout == .compact
                     ? "Tabs sit in the toolbar of one window, like Safari's compact tabs."
                     : "Each tab is its own window under the system tab bar.")
            }
            .pickerStyle(.segmented)
        }
        Section("Windows and Dock") {
            Picker(selection: bind(\.tray.onLastWindowClose)) {
                Text("Stay in Dock").tag(LastWindowPolicy.dock)
                Text("Menu bar only").tag(LastWindowPolicy.menuBar)
                Text("Quit").tag(LastWindowPolicy.quit)
            } label: {
                Text("When the last window closes")
                Text(lastWindowHint)
            }
            Toggle(isOn: bind(\.dock.menu)) {
                Text("Dock menu")
                Text("Right-click the Dock icon for what needs you, a new chat with any persona, Quick Capture and Screenshot to Chat.")
            }
            Toggle(isOn: bind(\.dock.progress)) {
                Text("Show download progress on the Dock icon")
                Text("While the run image downloads on first launch.")
            }
        }
        Section("Login") {
            Toggle(isOn: bind(\.login.openAtLogin)) {
                Text("Open Vesper at login")
                Text("The local stack starts in the background, so Vesper is ready when you are.")
            }
            if let message = state.loginMessage { Text(message).foregroundStyle(.red).font(.callout) }
            Toggle(isOn: bind(\.login.startHidden)) {
                Text("Start in the menu bar, without a window")
                Text("Needs the menu bar icon. If the stack can't start, you get a notification.")
            }
            .disabled(!s.login.openAtLogin)
        }
    }

    // MARK: Notifications

    private static let kindLabels: [String: String] = [
        "approval": "Agent requests", "question": "Agent questions", "blocked": "Failed or blocked runs",
        "stalled": "Stalled runs", "mockup": "Mockups to review", "planning": "Plans to approve",
        "review": "Work ready for review", "workflow_gate": "Workflow gates", "connector_approval": "Connector tool calls",
        "secret_approval": "Requests using a secret", "merged": "Merged pull requests", "pr_approved": "Approved pull requests",
    ]

    private func clock(_ keyPath: WritableKeyPath<NativeSettings, String>) -> Binding<Date> {
        Binding(
            get: {
                let parts = s[keyPath: keyPath].split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 0, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                aux.update { $0[keyPath: keyPath] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) }
            }
        )
    }

    @ViewBuilder private var notifications: some View {
        Section {
            Toggle("Show notifications", isOn: bind(\.notifications.enabled))
            LabeledContent {
                Button("Send a Test") { testMessage = aux.sendTestNotification() }.disabled(!s.notifications.enabled)
            } label: {
                Text("Test notification")
                if let testMessage { Text(testMessage) }
            }
        } footer: {
            footer("Alerts for things that need you, from your inbox and runs.")
        }
        Section("Notify me about") {
            ForEach(NotificationKind.all, id: \.self) { kind in
                Toggle(Self.kindLabels[kind] ?? kind, isOn: Binding(
                    get: { s.notifications.kinds[kind] ?? true },
                    set: { v in aux.update { $0.notifications.kinds[kind] = v } }
                ))
            }
        }
        .disabled(!s.notifications.enabled)
        Section {
            Toggle(isOn: bind(\.notifications.runFinished)) {
                Text("When a run finishes or fails")
                Text("Once per ticket, planning, research or workflow run. Chat replies don't count.")
            }
            Toggle(isOn: bind(\.notifications.actions)) {
                Text("Approve, Decline and Reply in the notification")
                Text("Buttons show when the notification style for Vesper is Alerts (System Settings › Notifications). A reply goes to the ticket, mentioning the agent.")
            }
            Toggle(isOn: bind(\.notifications.groupByWork)) {
                Text("Group by ticket or run")
                Text("A busy run stacks into one group in Notification Center.")
            }
            Toggle("Play a sound", isOn: bind(\.notifications.sound))
        }
        .disabled(!s.notifications.enabled)
        Section {
            Toggle(isOn: bind(\.notifications.quietHours.enabled)) {
                Text("Quiet hours")
                Text("No notifications in this window; they don't arrive later either. macOS Focus also applies on its own.")
            }
            DatePicker("From", selection: clock(\.notifications.quietHours.start), displayedComponents: .hourAndMinute)
                .disabled(!s.notifications.quietHours.enabled)
            DatePicker("To", selection: clock(\.notifications.quietHours.end), displayedComponents: .hourAndMinute)
                .disabled(!s.notifications.quietHours.enabled)
        }
        .disabled(!s.notifications.enabled)
    }

    // MARK: Shortcuts

    @ViewBuilder private func shortcutRow(
        _ kind: GlobalShortcuts.Kind, title: String, hint: String, config: NativeSettings.Shortcut, enabled: Binding<Bool>
    ) -> some View {
        LabeledContent {
            HStack {
                ShortcutRecorder(accelerator: config.shortcut) { aux.setShortcut(kind, accelerator: $0) }
                Toggle("Enabled", isOn: enabled).labelsHidden().toggleStyle(.switch)
            }
        } label: {
            Text(title)
            Text(hint)
            if let error = state.shortcutErrors[kind] { Text(error).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            shortcutRow(.quickCapture, title: "Quick Capture", hint: "Capture a note, message a persona, or file a ticket.",
                        config: s.quickCapture, enabled: bind(\.quickCapture.enabled))
            shortcutRow(.screenshot, title: "Screenshot to Chat",
                        hint: "Drag to capture part of the screen (Space for a window, Esc to cancel), then pick a chat to send it to. macOS asks for Screen Recording permission the first time.",
                        config: s.screenshot, enabled: bind(\.screenshot.enabled))
            shortcutRow(.showHide, title: "Show or hide Vesper",
                        hint: "Brings Vesper forward from any app, or hides it when it's already in front.",
                        config: s.showHide, enabled: bind(\.showHide.enabled))
        } footer: {
            footer("Global shortcuts that work from any app. Click a shortcut and press the keys; use ⌘, ⌥ or ⌃ (Shift alone isn't enough).")
        }
    }

    // MARK: Files & Links

    @ViewBuilder private var files: some View {
        Section {
            Toggle(isOn: bind(\.files.dockDrop)) {
                Text("Send files dropped on Vesper to a chat")
                Text("Drop files on the Dock icon, on a Vesper window, or use Open With. You pick the chat first. PDF, images, text, Markdown, CSV, JSON or zip, up to 25 MB each.")
            }
            LabeledContent {
                Button(state.servicesInstalled ? "Remove" : "Install") {
                    quickActionsError = aux.setQuickActions(installed: !state.servicesInstalled)
                }
                .disabled(!aux.quickActionsAvailable)
            } label: {
                Text("\u{201C}Send to Vesper\u{201D} Quick Actions")
                Text("Adds Send to Vesper (files, in Finder) and Send Text to Vesper (selected text) to the Services menu and Finder's Quick Actions.")
                if let e = quickActionsError { Text(e).foregroundStyle(.red) }
                else if !aux.quickActionsAvailable { Text("Available in the packaged Vesper.app.") }
            }
            Toggle(isOn: bind(\.deepLinks.enabled)) {
                Text("Open vesper:// links")
                Text("vesper://run/<id>, vesper://ticket/<KEY-1>, vesper://epic/<id>, vesper://page/<id>, vesper://chat/<id>, vesper://inbox and vesper://capture. Anything else is ignored.")
            }
        }
    }

    // MARK: Workspaces

    @ViewBuilder private var workspaces: some View {
        Section {
            ValidatedField(title: "Terminal app", value: s.workspaces.terminalApp, validate: { isValidAppName($0) },
                           message: "Letters, digits, spaces and . _ & + ( ) ' - only, up to 64 characters.",
                           hint: "The app \"Open in Terminal\" uses, e.g. Terminal, iTerm, Ghostty.") { v in
                aux.update { $0.workspaces.terminalApp = v }
            }
            Picker(selection: bind(\.workspaces.editor.kind)) {
                Text("Command in Terminal").tag(EditorKind.terminal)
                Text("App").tag(EditorKind.app)
            } label: {
                Text("Editor")
                Text(s.workspaces.editor.kind == .app ? "Open in \(s.workspaces.editor.app)." : "Open in \(s.workspaces.editor.command) in Terminal.")
            }
            if s.workspaces.editor.kind == .terminal {
                ValidatedField(title: "Command", value: s.workspaces.editor.command, validate: { isValidTerminalCommand($0) },
                               message: "Plain words only: a program and its arguments, no quotes or shell characters.",
                               hint: "Runs in Terminal in the folder, with \".\" added, e.g. nvim, hx, emacs -nw.") { v in
                    aux.update { $0.workspaces.editor.command = v }
                }
            } else {
                ValidatedField(title: "App", value: s.workspaces.editor.app, validate: { isValidAppName($0) },
                               message: "Letters, digits, spaces and . _ & + ( ) ' - only, up to 64 characters.",
                               hint: "Opens the folder, e.g. Visual Studio Code, Zed, Cursor.") { v in
                    aux.update { $0.workspaces.editor.app = v }
                }
            }
        } footer: {
            footer("With host-folder workspaces on, a run's or chat's folder chip gets an Open menu: Finder, your terminal, or your editor.")
        }
    }

    // MARK: Power & Stack

    private var runnerSlotsStatus: String? {
        guard let running = aux.app?.stack?.runnerMaxSlots, running > 0, running != s.stack.runnerSlots else { return nil }
        if !(ProcessInfo.processInfo.environment["RUNNER_MAX_CONCURRENT"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return "The runner is using \(running). Restart the stack to use \(s.stack.runnerSlots)."
    }

    @ViewBuilder private var power: some View {
        Section("Power") {
            Toggle(isOn: bind(\.power.preventSleepWhileRunning)) {
                Text("Keep the Mac awake while runs are working")
                Text("Stops idle sleep while a run is starting or running. Closing the lid still sleeps.")
            }
            Toggle(isOn: bind(\.power.easeOffWhenHot)) {
                Text("Take fewer runs when the Mac is hot or in Low Power Mode")
                Text("Half the runs at once when it's hot or in Low Power Mode, one at a time when it's very hot. Runs already going finish; the cap lifts when things cool down.")
            }
            Picker(selection: bind(\.power.onSleep)) {
                Text("Leave runs").tag(SleepPolicy.keep)
                Text("Pause and resume").tag(SleepPolicy.pause)
            } label: {
                Text("When the Mac sleeps")
                Text(s.power.onSleep == .pause
                     ? "Working ticket runs pause before sleep and pick up again after wake with “You were paused; continue.”"
                     : "Runs are left as they are. A run working when the Mac sleeps may fail its turn if its network connection drops; retry it from the run page.")
            }
            Toggle("Warn when switching to battery with runs working", isOn: bind(\.power.warnOnBattery))
            Toggle("Ask before quitting with runs working", isOn: bind(\.power.confirmQuitWithActiveRuns))
        }
        Section("Stack") {
            Toggle(isOn: bind(\.stack.autoRestart)) {
                Text("Restart the stack after a crash")
                Text("Up to 3 times in 10 minutes, then Vesper tells you and stops trying.")
            }
            NumberField(title: "Warn when free disk space drops below", unit: "GB", hint: "In the data directory, where runs keep their disks.",
                        range: 1...1000, value: bind(\.stack.minFreeDiskGb))
            NumberField(title: "Runs at once", unit: nil,
                        hint: "How many runs the local runner works on at the same time. More runs use more memory and CPU.",
                        range: 1...32, value: bind(\.stack.runnerSlots))
            if let status = runnerSlotsStatus {
                HStack {
                    Text(status).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Restart Now") { restartStack() }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Data folder")
                Text(aux.app?.dataDirectory.path ?? "").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let restartMessage { Text(restartMessage).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Show Logs…") { aux.app?.actions.showLogs() }
                    Button("Open Data Folder") { if let dir = aux.app?.dataDirectory { NSWorkspace.shared.open(dir) } }
                    Button("Restart Stack") { restartStack() }
                }
            }
        }
    }

    private func restartStack() {
        Task {
            if await aux.hasActiveRuns() {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Runs are still working."
                alert.informativeText = "Restarting the local stack interrupts them."
                alert.addButton(withTitle: "Restart Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { restartMessage = "Restart cancelled."; return }
            }
            restartMessage = nil
            aux.app?.actions.restartStack()
        }
    }

    // MARK: Backups

    private var everyChoices: [Int] {
        var base = [6, 12, 24, 168]
        if !base.contains(s.backups.export.everyHours) { base.append(s.backups.export.everyHours); base.sort() }
        return base
    }

    private func everyLabel(_ h: Int) -> String {
        switch h {
        case 6, 12: return "Every \(h) hours"
        case 24: return "Daily"
        case 168: return "Weekly"
        default: return "Every \(h) hours"
        }
    }

    @ViewBuilder private var backups: some View {
        Section {
            Toggle(isOn: bind(\.backups.excludeFromTimeMachine)) {
                Text("Keep VM disks and caches out of Time Machine")
                Text("Skips the data folder's vm and images folders: run disks, caches and downloaded images that Vesper rebuilds. Your database, files and settings are still backed up.")
                if s.backups.excludeFromTimeMachine, let excluded = state.timeMachineExcluded {
                    Text(excluded ? "Excluded now." : "Not excluded yet (tmutil hasn't succeeded).")
                }
            }
        }
        Section {
            Toggle(isOn: bind(\.backups.export.enabled)) {
                Text("Save an export to a folder on a schedule")
                Text("A whole-instance export (the same archive File › Import Backup takes). Secrets in it stay sealed with this Mac's key, so keep the key too if you move it; still, pick a private folder.")
                Text(state.lastExportAt.map { "Last export: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "No export yet.")
                if let e = state.lastExportError { Text("Last attempt failed: \(e)").foregroundStyle(.red) }
            }
            LabeledContent {
                Button("Choose…") { chooseExportFolder() }
            } label: {
                Text("Folder")
                Text(s.backups.export.folder.isEmpty ? "No folder chosen." : s.backups.export.folder)
            }
            .disabled(!s.backups.export.enabled)
            Picker("How often", selection: bind(\.backups.export.everyHours)) {
                ForEach(everyChoices, id: \.self) { Text(everyLabel($0)).tag($0) }
            }
            .disabled(!s.backups.export.enabled)
            NumberField(title: "Exports to keep", unit: nil, hint: nil, range: 1...100, value: bind(\.backups.export.keep))
                .disabled(!s.backups.export.enabled)
            LabeledContent {
                Button(state.exporting ? "Exporting…" : "Export Now") { exportNow() }
                    .disabled(s.backups.export.folder.isEmpty || state.exporting)
            } label: {
                Text("Export now")
                if let exportMessage { Text(exportMessage) }
            }
        } header: {
            Text("Scheduled export")
        }
        Section {
            if state.backupEncryptionLoading && state.backupEncryption == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking backup encryption…").foregroundStyle(.secondary)
                }
            } else if let err = state.backupEncryptionError, state.backupEncryption == nil {
                LabeledContent {
                    Button("Retry") { Task { await aux.refreshBackupEncryption() } }
                } label: {
                    Text("Couldn't load backup encryption")
                    Text(err).foregroundStyle(.red)
                }
            } else if let enc = state.backupEncryption {
                if !enc.keyConfigured {
                    Text("Backup encryption requires SECRETS_KEY to be available in the Vesper stack.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent {
                    if !editingBackupPassword {
                        if enc.enabled {
                            HStack(spacing: 8) {
                                Button("Change Password…") { beginEditingBackupPassword() }
                                    .disabled(!enc.keyConfigured || savingBackupPassword)
                                Button("Turn Off") { confirmClearBackupPassword() }
                                    .disabled(savingBackupPassword)
                            }
                        } else {
                            Button("Set Password…") { beginEditingBackupPassword() }
                                .disabled(!enc.keyConfigured || savingBackupPassword)
                        }
                    }
                } label: {
                    Text(enc.enabled ? "Password protection is on" : "Password protection is off")
                    Text(enc.enabled
                         ? "Both manual downloads and scheduled exports are encrypted as .vesper.enc archives."
                         : "Exports currently save as unencrypted .zip archives (secrets inside remain sealed with this Mac's key).")
                    if let backupPasswordMessage { Text(backupPasswordMessage).foregroundStyle(.secondary) }
                }
                if editingBackupPassword {
                    SecureField("Backup password (8–256 characters)", text: $backupPassword)
                    SecureField("Confirm password", text: $backupPasswordConfirm)
                    Text("Applies to both manual downloads and scheduled exports. If you lose this password, encrypted backups cannot be recovered.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let backupPasswordError {
                        Text(backupPasswordError).foregroundStyle(.red).font(.callout)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { cancelEditingBackupPassword() }
                            .disabled(savingBackupPassword)
                        Button(savingBackupPassword ? "Saving…" : "Save Password") { saveBackupPassword() }
                            .disabled(savingBackupPassword || backupPassword.isEmpty || backupPasswordConfirm.isEmpty)
                    }
                }
            } else {
                LabeledContent {
                    Button("Refresh") { Task { await aux.refreshBackupEncryption() } }
                } label: {
                    Text("Waiting for Vesper…")
                    Text("Backup encryption settings load once the local stack is running.")
                }
            }
        } header: {
            Text("Backup encryption")
        }
    }

    private func beginEditingBackupPassword() {
        backupPasswordMessage = nil
        backupPasswordError = nil
        backupPassword = ""
        backupPasswordConfirm = ""
        editingBackupPassword = true
    }

    private func cancelEditingBackupPassword() {
        backupPassword = ""
        backupPasswordConfirm = ""
        backupPasswordError = nil
        editingBackupPassword = false
    }

    private func saveBackupPassword() {
        let count = backupPassword.unicodeScalars.count
        guard count >= 8, count <= 256 else {
            backupPasswordError = "Use 8 to 256 characters."
            return
        }
        guard backupPassword == backupPasswordConfirm else {
            backupPasswordError = "The passwords don't match."
            return
        }
        let pw = backupPassword
        let wasEnabled = state.backupEncryption?.enabled ?? false
        backupPasswordError = nil
        savingBackupPassword = true
        Task {
            defer { savingBackupPassword = false }
            if let err = await aux.setBackupEncryption(password: pw) {
                backupPasswordError = err
            } else {
                backupPassword = ""
                backupPasswordConfirm = ""
                backupPasswordError = nil
                editingBackupPassword = false
                backupPasswordMessage = wasEnabled ? "Backup password updated." : "Backup encryption enabled."
            }
        }
    }

    private func confirmClearBackupPassword() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn off backup encryption?"
        alert.informativeText = "Future manual and scheduled exports will save as unencrypted .zip archives. Existing encrypted exports stay encrypted."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        backupPasswordMessage = nil
        backupPasswordError = nil
        savingBackupPassword = true
        Task {
            defer { savingBackupPassword = false }
            if let err = await aux.clearBackupEncryption() {
                backupPasswordError = err
            } else {
                cancelEditingBackupPassword()
                backupPasswordMessage = "Backup encryption turned off."
            }
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Vesper Exports"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { aux.update { $0.backups.export.folder = url.path } }
    }

    private func exportNow() {
        exportMessage = nil
        Task {
            switch await aux.exportNow() {
            case .success(let file): exportMessage = "Saved \(file.lastPathComponent)."
            case .failure(let e): exportMessage = e.message
            }
        }
    }

    // MARK: Security

    @ViewBuilder private var security: some View {
        Section {
            Toggle(isOn: bind(\.touchId.enabled)) {
                Text("Confirm approvals with Touch ID")
                Text("Asks for your fingerprint in this app before an approval goes through. It's a local check only: the server doesn't verify it, so it guards an unlocked Mac, not other browsers or API calls.")
            }
            LabeledContent {
                Button("Test Touch ID") { Task { touchIdMessage = await aux.testTouchId() ?? "Touch ID worked." } }
                    .disabled(!aux.touchIdAvailable)
            } label: {
                Text("Test")
                if let touchIdMessage { Text(touchIdMessage) }
            }
            if !aux.touchIdAvailable {
                Text("Touch ID isn't available on this Mac (no sensor, lid closed, or no fingerprints), so approvals work with a click as usual.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        Section("Ask for Touch ID on") {
            ForEach([
                (TouchIdScope.runApprovals, "Agent requests on runs"), (.pushRequests, "Pushes and pull requests"),
                (.connectorApprovals, "Connector tool calls"), (.secretApprovals, "Requests that use a secret"),
            ], id: \.0) { scope, label in
                Toggle(label, isOn: Binding(
                    get: { s.touchId.isOn(scope) },
                    set: { v in aux.update { $0.touchId.scopes[scope.rawValue] = v } }
                ))
            }
        }
        .disabled(!s.touchId.enabled)
    }

    // MARK: Updates

    @ViewBuilder private var updates: some View {
        Section {
            Toggle(isOn: bind(\.updates.checkEnabled)) {
                Text("Check for new versions daily")
                Text("Asks the release feed (GitHub) once a day. Nothing about you or your workspace is sent.")
            }
            LabeledContent {
                Button(state.checkingForUpdates ? "Checking…" : "Check for Updates…") { aux.checkForUpdates() }
                    .disabled(state.checkingForUpdates)
            } label: {
                Text("Check now")
                Text("Last checked: \(state.lastUpdateCheckAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never").")
            }
            LabeledContent {
                EmptyView()
            } label: {
                Text("Updating")
                Text("Download the new DMG and drag Vesper.app into Applications, replacing the old one. Your data stays in the data folder and is upgraded on next launch.")
            }
        } footer: {
            footer("Vesper.app isn't notarised, so it can't update itself. It can tell you when a newer DMG is out.")
        }
    }
}

/// A text field that saves only a valid value (on Return or when it loses focus) and says why it didn't.
struct ValidatedField: View {
    let title: String
    let value: String
    let validate: (String) -> Bool
    let message: String
    var hint: String?
    let commit: (String) -> Void

    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 220)
                .focused($focused)
                .onSubmit(save)
        } label: {
            Text(title)
            if let hint { Text(hint) }
            if invalid { Text(message).foregroundStyle(.red) }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == value { invalid = false; text = value; return }
        if validate(trimmed) {
            invalid = false
            commit(trimmed)
        } else {
            invalid = true
        }
    }
}

/// An integer field with a stepper, clamped to a range; an out-of-range entry reverts.
struct NumberField: View {
    let title: String
    let unit: String?
    let hint: String?
    let range: ClosedRange<Int>
    @Binding var value: Int

    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($focused)
                    .onSubmit(save)
                if let unit { Text(unit).foregroundStyle(.secondary) }
                Stepper(title, value: $value, in: range).labelsHidden()
            }
        } label: {
            Text(title)
            if let hint { Text(hint) }
            if invalid { Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound).").foregroundStyle(.red) }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, new in text = String(new); invalid = false }
        .onChange(of: focused) { _, now in if !now { save() } }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(t), range.contains(n) {
            invalid = false
            value = n
        } else {
            invalid = true
            text = String(value)
        }
    }
}
