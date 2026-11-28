import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

extension SettingsPane: Identifiable {
    public var id: String { rawValue }

    var settingsTitle: String {
        switch self {
        case .you: return "You"
        case .appearance: return "Appearance"
        case .memory: return "Memory"
        case .promptTemplates: return "Prompt Templates"
        case .personas: return "Personas"
        case .secrets: return "Credentials & API Secrets"
        case .connectors: return "Connectors"
        case .repositories: return "Repositories"
        case .workspace: return "Workspace"
        case .runners: return "Runners"
        case .devWorkspace: return "Dev Workspace"
        case .spaces: return "Spaces"
        case .signIn: return "Sign-in"
        case .general: return "General"
        case .notifications: return "Notifications"
        case .shortcuts: return "Shortcuts"
        case .files: return "Files & Links"
        case .workspaces: return "Workspaces"
        case .power: return "Power & Stack"
        case .backups: return "Backups"
        case .security: return "Security"
        case .companion: return "iPhone Companion"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .you: return "person.crop.circle"
        case .appearance: return "paintpalette"
        case .memory: return "brain"
        case .promptTemplates: return "text.badge.star"
        case .personas: return "person.2"
        case .secrets: return "key"
        case .connectors: return "powerplug"
        case .repositories: return "chevron.left.forwardslash.chevron.right"
        case .workspace: return "building.2"
        case .runners: return "server.rack"
        case .devWorkspace: return "terminal"
        case .spaces: return "square.grid.2x2"
        case .signIn: return "lock"
        case .general: return "gearshape"
        case .notifications: return "bell"
        case .shortcuts: return "keyboard"
        case .files: return "doc.on.doc"
        case .workspaces: return "folder"
        case .power: return "bolt"
        case .backups: return "externaldrive"
        case .security: return "touchid"
        case .companion: return "iphone"
        case .updates: return "arrow.down.circle"
        }
    }
}

private struct SettingsSidebarGroup: Identifiable {
    let id: String
    let title: String
    let panes: [SettingsPane]
}

private let settingsSidebarGroups: [SettingsSidebarGroup] = [
    SettingsSidebarGroup(id: "personal", title: "Personal", panes: [.you, .appearance, .memory, .promptTemplates]),
    SettingsSidebarGroup(id: "personas", title: "Personas", panes: [.personas]),
    SettingsSidebarGroup(id: "integrations", title: "Integrations", panes: [.secrets, .connectors, .repositories]),
    SettingsSidebarGroup(id: "workspace", title: "Workspace", panes: [.workspace, .runners, .devWorkspace, .spaces]),
    SettingsSidebarGroup(id: "account", title: "Account", panes: [.signIn]),
    SettingsSidebarGroup(id: "mac-app", title: "Mac App", panes: [.general, .notifications, .shortcuts, .files, .workspaces, .power, .backups, .security, .companion, .updates]),
]

@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsPane = .you
    var searchText = ""
    var personaId: String?
    var personaFilter: SettingsPersonaFilter = .all
    var memoryFocusId: String?
    var secretsTab: SettingsSecretsTab = .provider
    var secretId: String?
    var spaceId: String?
    var anchor: String?
    var runnerRunId: String?

    func apply(_ destination: SettingsDestination) {
        switch destination {
        case .pane(
            let pane,
            let personaId,
            let personaFilter,
            let memoryFocusId,
            let secretsTab,
            let secretId,
            let spaceId,
            let anchor,
            let runnerRunId
        ):
            self.selection = pane
            self.personaId = personaId
            self.personaFilter = personaFilter
            self.memoryFocusId = memoryFocusId
            self.secretsTab = secretsTab
            self.secretId = secretId
            self.spaceId = spaceId
            self.anchor = anchor
            self.runnerRunId = runnerRunId
        case .spaceRedirect:
            self.selection = .spaces
        }
    }

    func navigate(_ path: String) {
        if let dest = SettingsRouteResolver.resolve(path) {
            apply(dest)
        }
    }
}

struct SettingsView: View {
    let aux: AuxWindows
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(filteredGroups) { group in
                    Section(group.title) {
                        ForEach(group.panes) { pane in
                            Label(pane.settingsTitle, systemImage: pane.symbol).tag(pane)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        TextField("Filter settings…", text: $navigation.searchText)
                            .textFieldStyle(.plain)
                        if !navigation.searchText.isEmpty {
                            Button {
                                navigation.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    Divider()
                }
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom) {
                Text("Vesper \(AuxWindows.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 205, ideal: 230, max: 270)
        } detail: {
            detailView
                .navigationTitle(navigation.selection.settingsTitle)
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 780, minHeight: 520)
    }

    private var filteredGroups: [SettingsSidebarGroup] {
        let q = navigation.searchText
        return settingsSidebarGroups.compactMap { group in
            let matches = group.panes.filter { SettingsRouteResolver.matchesPane($0, title: $0.settingsTitle, query: q) }
            guard !matches.isEmpty else { return nil }
            return SettingsSidebarGroup(id: group.id, title: group.title, panes: matches)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selection {
        case .you:
            SettingsYouPane(aux: aux, navigation: navigation)
        case .appearance:
            SettingsAppearancePane(aux: aux)
        case .memory:
            SettingsMemoryPane(aux: aux, navigation: navigation)
        case .promptTemplates:
            SettingsPromptTemplatesPane(aux: aux)
        case .personas:
            SettingsPersonasPane(aux: aux, navigation: navigation)
        case .secrets:
            SettingsSecretsPane(aux: aux, navigation: navigation)
        case .connectors:
            SettingsConnectorsPane(aux: aux)
        case .repositories:
            SettingsRepositoriesPane(aux: aux)
        case .workspace:
            SettingsWorkspacePane(aux: aux, navigation: navigation)
        case .runners:
            SettingsRunnersPane(aux: aux, navigation: navigation)
        case .devWorkspace:
            SettingsDevWorkspacePane(aux: aux)
        case .spaces:
            SettingsSpacesPane(aux: aux, navigation: navigation)
        case .signIn:
            SettingsSignInPane(aux: aux)
        case .companion:
            SettingsCompanionPane(aux: aux)
        case .general, .notifications, .shortcuts, .files, .workspaces, .power, .backups, .security, .updates:
            SettingsDetail(aux: aux, section: navigation.selection)
        }
    }
}

/// Mac App preference sections + folded web Backup actions on `.backups`.
struct SettingsDetail: View {
    let aux: AuxWindows
    let section: SettingsPane

    @State private var testMessage: String?
    @State private var quickActionsError: String?
    @State private var touchIdMessage: String?
    @State private var exportMessage: String?
    @State private var manualExporting = false
    @State private var manualExportMessage: String?
    @State private var editingBackupPassword = false
    @State private var backupPassword = ""
    @State private var backupPasswordConfirm = ""
    @State private var backupPasswordError: String?
    @State private var backupPasswordMessage: String?
    @State private var savingBackupPassword = false
    @State private var restartMessage: String?
    @State private var extraCaMessage: String?
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
            default: EmptyView()
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

    @ViewBuilder private var notifications: some View {
        Section {
            Toggle("Show desktop notifications", isOn: bind(\.notifications.enabled))
            Toggle(isOn: bind(\.notifications.actions)) {
                Text("Include quick action buttons")
                Text("Approve or deny straight from the banner. Keeps details brief while the screen is locked.")
            }
            .disabled(!s.notifications.enabled)
            Toggle(isOn: bind(\.notifications.groupByWork)) {
                Text("Group notifications by chat or workflow")
                Text("A newer update replaces the earlier unread banner for the same thing.")
            }
            .disabled(!s.notifications.enabled)
            Toggle("Notify when a workflow or scheduled run finishes", isOn: bind(\.notifications.runFinished))
                .disabled(!s.notifications.enabled)
            Toggle("Play a sound", isOn: bind(\.notifications.sound))
                .disabled(!s.notifications.enabled)
            LabeledContent {
                Button("Send Test") { testMessage = aux.sendTestNotification() }
            } label: {
                Text("Test notification")
                if let testMessage { Text(testMessage) }
            }
        }
        Section("Notify when") {
            ForEach([
                ("approval", "An agent asks for approval"), ("question", "An agent asks a question"),
                ("run_failed", "A run stops with a failure"), ("run_completed", "A run finishes without opening a pull request"),
                ("merged", "A pull request is merged"), ("plan_failed", "A plan fails"),
                ("plan_finished", "A plan finishes"), ("wiki", "A wiki suggestion waits for review"),
            ], id: \.0) { kind, label in
                Toggle(label, isOn: Binding(
                    get: { s.notifications.kinds[kind] ?? true },
                    set: { v in aux.update { $0.notifications.kinds[kind] = v } }
                ))
                .disabled(!s.notifications.enabled)
            }
        }
        Section("Quiet hours") {
            Toggle("Pause sounds and popups during quiet hours", isOn: bind(\.notifications.quietHours.enabled))
            ValidatedField(title: "Starts", value: s.notifications.quietHours.start, validate: { isValidClockTime($0) },
                           message: "Use 24-hour HH:MM, for example 22:00.") { v in
                aux.update { $0.notifications.quietHours.start = v }
            }
            .disabled(!s.notifications.quietHours.enabled)
            ValidatedField(title: "Ends", value: s.notifications.quietHours.end, validate: { isValidClockTime($0) },
                           message: "Use 24-hour HH:MM, for example 08:00.") { v in
                aux.update { $0.notifications.quietHours.end = v }
            }
            .disabled(!s.notifications.quietHours.enabled)
        }
    }

    // MARK: Shortcuts

    @ViewBuilder private var shortcuts: some View {
        Section {
            shortcutRow(.quickCapture, setting: bind(\.quickCapture), title: "Quick Capture to Inbox",
                        subtitle: "Opens a tiny prompt from anywhere and saves your note into the Inbox.")
            shortcutRow(.screenshot, setting: bind(\.screenshot), title: "Screenshot to Chat",
                        subtitle: "Crosshair selection attached straight into Quick Capture.")
            shortcutRow(.showHide, setting: bind(\.showHide), title: "Show / Hide Vesper",
                        subtitle: "Bring Vesper forward from any app, or hide it.")
        } footer: {
            footer("Global shortcuts work even when another app has focus. Turn off anything that clashes with your editor.")
        }
    }

    @ViewBuilder
    private func shortcutRow(_ kind: GlobalShortcuts.Kind, setting: Binding<NativeSettings.Shortcut>, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: setting.enabled) {
                Text(title)
                Text(subtitle)
            }
            LabeledContent("Key combination") {
                ShortcutRecorder(accelerator: setting.shortcut.wrappedValue) { accel in
                    aux.setShortcut(kind, accelerator: accel)
                }
            }
            .disabled(!setting.enabled.wrappedValue)
            if let error = state.shortcutErrors[kind] {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: Files & Links

    @ViewBuilder private var files: some View {
        Section("Files in") {
            Toggle(isOn: bind(\.files.dockDrop)) {
                Text("Accept files dropped onto the Dock icon or opened with Vesper")
                Text("PDFs and documents import into Knowledge; images and code attach to a chat or Inbox note.")
            }
            LabeledContent {
                Button(state.servicesInstalled ? "Remove Quick Actions" : "Install Quick Actions") {
                    quickActionsError = aux.setQuickActions(installed: !state.servicesInstalled)
                }
                .disabled(!aux.quickActionsAvailable)
            } label: {
                Text("Finder Quick Actions")
                Text("Adds \"Send to Vesper\" for files and \"Send Text to Vesper\" for text in Finder and Services.")
                if let quickActionsError { Text(quickActionsError).foregroundStyle(.red) }
            }
        }
        Section("Links") {
            Toggle(isOn: bind(\.deepLinks.enabled)) {
                Text("Handle vesper:// links in this app")
                Text("Links from terminals, scripts and browsers open the chat, space or Knowledge page inside Vesper.")
            }
            LabeledContent {
                EmptyView()
            } label: {
                Text("Universal links")
                Text("Supported once Vesper is distributed as a signed app.")
            }
        }
    }

    // MARK: Workspaces

    @ViewBuilder private var workspaces: some View {
        Section {
            ValidatedField(title: "Terminal app", value: s.workspaces.terminalApp, validate: { isValidAppName($0) },
                           message: "Enter an app name like Terminal, iTerm or Ghostty.",
                           hint: "Opened when you choose Open in terminal.") { v in
                aux.update { $0.workspaces.terminalApp = v }
            }
            Picker(selection: bind(\.workspaces.editor.kind)) {
                Text("Terminal command").tag(EditorKind.terminal)
                Text("Desktop app").tag(EditorKind.app)
            } label: {
                Text("Editor")
                Text("Used when you choose Open in editor on a workspace.")
            }
            if s.workspaces.editor.kind == .terminal {
                ValidatedField(title: "Command", value: s.workspaces.editor.command, validate: { isValidTerminalCommand($0) },
                               message: "Use a plain command like nvim or hx (letters, numbers and spaces, no shell operators).",
                               hint: "Run in your terminal inside the workspace folder, e.g. nvim or hx.") { v in
                    aux.update { $0.workspaces.editor.command = v }
                }
            } else {
                ValidatedField(title: "Application", value: s.workspaces.editor.app, validate: { isValidAppName($0) },
                               message: "Enter an app name like Visual Studio Code, Cursor or Zed.",
                               hint: "Launched via open -a with the workspace folder.") { v in
                    aux.update { $0.workspaces.editor.app = v }
                }
            }
        } footer: {
            footer("These apply only to workspaces you open manually from a run's workspace menu; Vesper never scans them.")
        }
    }

    // MARK: Power & Stack

    @ViewBuilder private var power: some View {
        Section("Sleep & Battery") {
            Toggle(isOn: bind(\.power.preventSleepWhileRunning)) {
                Text("Keep Mac awake while an agent is working")
                Text("Prevents idle sleep while a chat or workflow run is active. Closing the lid still sleeps.")
            }
            Picker(selection: bind(\.power.onSleep)) {
                Text("Let runs stay as they are").tag(SleepPolicy.keep)
                Text("Pause runs when the Mac sleeps").tag(SleepPolicy.pause)
            } label: {
                Text("When this Mac sleeps")
                Text("Agents pause between tool calls until the Mac wakes and Vesper resumes them.")
            }
            Toggle(isOn: bind(\.power.warnOnBattery)) {
                Text("Warn when starting a run on low battery (below 20%)")
                Text("Shows in Vesper's tray subtitle as a gentle reminder.")
            }
            Toggle("Ask before quitting while a run is active", isOn: bind(\.power.confirmQuitWithActiveRuns))
            Toggle(isOn: bind(\.power.easeOffWhenHot)) {
                Text("Ease back concurrency while the Mac is very hot or under low power")
                Text("Asks the runner for one active run at a time until temperature settles.")
            }
        }
        Section("Embedded Stack") {
            Toggle(isOn: bind(\.stack.autoRestart)) {
                Text("Restart crashed services automatically")
                Text("Restarts the database, API or runner if one stops unexpectedly.")
            }
            NumberField(title: "Minimum free disk before starting", unit: "GB",
                        hint: "Saves Postgres and runs from running the drive out of space.",
                        range: 1...1000, value: bind(\.stack.minFreeDiskGb))
            NumberField(title: "Concurrent runner slots", unit: nil,
                        hint: "Applies when the runner next starts, or when you restart it below.",
                        range: 1...32, value: bind(\.stack.runnerSlots))
            LabeledContent {
                HStack {
                    Button(s.stack.extraCaFiles.isEmpty ? "Choose…" : "Add…") { chooseExtraCaFiles() }
                    if !s.stack.extraCaFiles.isEmpty {
                        Button("Clear") {
                            extraCaMessage = nil
                            aux.update { $0.stack.extraCaFiles = [] }
                        }
                    }
                }
            } label: {
                Text("Corporate root certificates")
                if let extraCaMessage {
                    Text(extraCaMessage).font(.callout).foregroundStyle(.red)
                }
                if s.stack.extraCaFiles.isEmpty {
                    Text("Behind a proxy that inspects HTTPS, such as Zscaler, choose one or more root or intermediate certificates (PEM, CRT or CER) so agent VMs trust them. Applies when the runner next starts.")
                } else {
                    Text("Applies when the runner next starts.")
                }
            }
            ForEach(s.stack.extraCaFiles, id: \.self) { path in
                LabeledContent {
                    Button("Remove") {
                        extraCaMessage = nil
                        aux.update { $0.stack.extraCaFiles.removeAll { $0 == path } }
                    }
                    .controlSize(.small)
                } label: {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            LabeledContent {
                Button("Restart Local Stack") {
                    restartMessage = "Restarting database, API and runner…"
                    aux.app?.actions.restartStack()
                }
            } label: {
                Text("Local stack")
                if let restartMessage { Text(restartMessage) }
            }
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
            LabeledContent {
                Button(manualExporting ? "Exporting…" : "Export Everything…") { exportArchiveNow() }
                    .disabled(manualExporting || aux.client() == nil)
            } label: {
                Text("Export workspace archive")
                Text("Downloads everything — database, git bundles, wiki, images and sealed secrets — into one archive you can move or keep as a backup.")
                if let manualExportMessage { Text(manualExportMessage).foregroundStyle(.secondary) }
            }
            LabeledContent {
                Button("Import Backup…") { aux.importBackup() }
            } label: {
                Text("Restore or move from an archive")
                Text("Replaces this Mac's workspace from a .zip or encrypted .vesper.enc export.")
            }
        } header: {
            Text("Manual export & import")
        }
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

    private func exportArchiveNow() {
        guard let client = aux.client() else { return }
        let encrypted = state.backupEncryption?.enabled ?? false
        let defaultName = Backups.exportFileName(Date(), encrypted: encrypted)
        guard let dest = SettingsFilePanels.pickSaveURL(
            defaultName: defaultName,
            contentTypes: encrypted ? [.data] : [.zip],
            title: "Export Vesper Backup"
        ) else { return }

        manualExportMessage = nil
        manualExporting = true
        Task {
            defer { manualExporting = false }
            do {
                let result = try await BackupExporter.exportToFile(client: client, destination: dest)
                manualExportMessage = "Saved \(result.url.lastPathComponent)."
            } catch {
                manualExportMessage = error.localizedDescription
            }
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

    /// Keeps only files holding PEM or binary DER X.509 certificates; the runner verifies them again when it starts.
    private func chooseExtraCaFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose Root Certificates (PEM, CRT or CER)"
        panel.message = "Select one or more .pem, .crt or .cer files, or export them with: security find-certificate -a -c Zscaler -p /Library/Keychains/System.keychain > ~/zscaler-root.pem"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var accepted: [String] = []
        var errors: [String] = []
        for url in panel.urls {
            if let err = ExtraCACertificate.validateFile(at: url) {
                errors.append(err)
            } else {
                accepted.append(url.path)
            }
        }
        if !accepted.isEmpty {
            aux.update {
                for path in accepted where !$0.stack.extraCaFiles.contains(path) {
                    $0.stack.extraCaFiles.append(path)
                }
            }
        }
        extraCaMessage = errors.isEmpty ? nil : errors.joined(separator: " ")
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
