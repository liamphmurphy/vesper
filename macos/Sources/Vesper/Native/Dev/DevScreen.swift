import AppKit
import SwiftUI
import VesperCore

/// The terminal session behind /dev: the emulator view, its PTY socket, and the full-screen state.
@MainActor
@Observable
final class DevTerminalModel {
    var connection: DevTerminalLogic.Connection = .disconnected
    var fullscreen = false
    var shortcutsOpen = false
    /// "Sent to chat" shows on the button for a moment after a snapshot goes out.
    var sentNotice = false
    var actionPending = false

    @ObservationIgnored private(set) weak var view: DevTerminalNSView?
    @ObservationIgnored let socket = DevTerminalConnection()
    /// Whether entering full screen put the window into macOS full screen (so leaving takes it out).
    @ObservationIgnored var enteredWindowFullScreen = false

    init() {
        socket.onStateChange = { [weak self] state in self?.socketChanged(state) }
        socket.onOutput = { [weak self] bytes in self?.view?.output(bytes) }
    }

    /// A fresh emulator for this port (the web made a new xterm.js per connection too): attach and dial.
    func attach(_ view: DevTerminalNSView, port: Int, client: APIClient?) {
        self.view = view
        guard let client else { return }
        let size = view.size
        socket.connect(base: client.baseURL, port: port, cols: size.cols, rows: size.rows, client: client)
    }

    func detach(_ view: DevTerminalNSView) {
        guard self.view === view else { return }
        socket.close()
        self.view = nil
    }

    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }

    private func socketChanged(_ state: DevTerminalLogic.Connection) {
        connection = state
        // As the web's onopen: the PTY starts at the URL's size, so send the laid-out size and focus.
        if state == .connected, let size = view?.size {
            socket.resize(cols: size.cols, rows: size.rows)
            focus()
        }
    }
}

/// /dev: the persistent Nix + LazyVim workspace's tmux session in a native terminal (SwiftTerm, vendored
/// in macos/Vendor/SwiftTerm), replacing the web's xterm.js one on the same PTY socket.
struct DevScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @State private var model = DevTerminalModel()
    @State private var reconnectSeq = 0

    private static let request = API.getDevWorkspace()

    var body: some View {
        let entry = context.store.entry(Self.request)
        Group {
            if let ws = entry.data {
                if ws.enabled {
                    workspace(ws)
                } else {
                    disabled
                }
            } else if let error = entry.error {
                QueryErrorView(message: "Couldn\u{2019}t load dev workspace: \(error.userMessage)") {
                    Task { _ = await context.store.refetch(Self.request) }
                }
            } else {
                GeometryReader { proxy in SkeletonBar(height: proxy.size.height) }.padding(16)
            }
        }
        .task {
            context.store.load(Self.request)
        }
        .task(id: entry.data.map { DevTerminalLogic.isBusy(state: $0.state, action: $0.action?.value?.rawValue) } ?? false) {
            // While the container starts or an action runs, poll as the web did (every 2 s).
            guard let ws = entry.data, DevTerminalLogic.isBusy(state: ws.state, action: ws.action?.value?.rawValue) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                _ = await context.store.refetch(Self.request)
            }
        }
        .onAppear {
            context.store.observe(Self.request)
            publishChrome()
            context.onCommand = { command in
                if case .titleAction(menuItemId: "dev.secure-keyboard") = command { DevSecureKeyboardEntry.isEnabled.toggle() }
            }
        }
        .onDisappear {
            context.store.stopObserving(Self.request.key)
            setFullscreen(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: DevSecureKeyboardEntry.didChange)) { _ in publishChrome() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            // Leaving macOS full screen another way (the green button, ⌃⌘F) leaves the terminal's too.
            guard model.fullscreen, model.enteredWindowFullScreen, (note.object as? NSWindow) === context.window()?.window else { return }
            model.enteredWindowFullScreen = false
            setFullscreen(false)
        }
        .sheet(isPresented: $model.shortcutsOpen, onDismiss: { model.focus() }) {
            DevShortcutsSheet(groups: DevTerminalLogic.shortcutGroups(tmuxPrefix: entry.data?.tmuxPrefix))
        }
    }

    // MARK: Chrome

    private func publishChrome() {
        context.chrome = NativeChrome(
            title: "Dev workspace",
            titleMenu: [MenuItem(id: "dev.secure-keyboard", label: "Secure Keyboard Entry", icon: "lock",
                                 checked: DevSecureKeyboardEntry.isEnabled)]
        )
    }

    // MARK: States

    private var disabled: some View {
        VStack(spacing: 0) {
            LibraryEmptyState(icon: "terminal", title: "Dev workspace is disabled",
                              message: "Enable the persistent Nix + LazyVim workspace in Settings to spin up the container and auto-clone your repositories.")
            Button("Configure in Settings") { context.navigate("/settings#dev-workspace") }
                .buttonStyle(.vesper(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workspace(_ ws: API.DevWorkspace) -> some View {
        let port = ws.state == .ready ? ws.port?.value : nil
        return VStack(spacing: 0) {
            if !model.fullscreen {
                header(ws, port: port)
            }
            if ws.state == .error, let error = ws.error?.value, !error.isEmpty {
                Text(error)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)))
                    .overlay(alignment: .bottom) { Rectangle().fill(theme.palette.border).frame(height: 1) }
            }
            if let port {
                DevTerminalRepresentable(model: model, port: port, client: context.store.client) { toggleFullscreen() }
                    .id("\(port)-\(reconnectSeq)")
                    .padding(4)
            } else {
                notReady(ws)
            }
        }
        .background(gruvbox(DevTerminalTheme.chrome))
        .clipShape(RoundedRectangle(cornerRadius: model.fullscreen ? 0 : 8))
        .overlay {
            if !model.fullscreen { RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border) }
        }
        .overlay(alignment: .topTrailing) {
            if model.fullscreen { fullscreenOverlay(port: port) }
        }
        .padding(model.fullscreen ? 0 : 16)
    }

    private func header(_ ws: API.DevWorkspace, port: Int?) -> some View {
        let pill = DevTerminalLogic.pill(connection: model.connection, enabled: ws.enabled, state: ws.state, step: ws.step?.value)
        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text("Dev workspace").font(.system(size: theme.pointSize(.body), weight: .semibold))
                Text("/workspace")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                TonePill(label: pill.label, tone: pill.tone)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(model.sentNotice ? "Sent to chat" : "Send to chat", action: sendToChat)
                    .disabled(port == nil)
                    .help("Attach the visible terminal output (and any selected text) to a chat")
                Button("Sync repos") { run(.sync) }
                    .disabled(ws.state == .starting || model.actionPending)
                if port != nil && model.connection == .disconnected {
                    Button("Reconnect") { reconnectSeq += 1 }
                }
                Button("Shortcuts") { model.shortcutsOpen = true }
                Button("Settings") { context.navigate("/settings#dev-workspace") }
                Button(action: toggleFullscreen) {
                    HStack(spacing: 6) {
                        Text("Fullscreen")
                        Text(DevTerminalLogic.fullscreenHint).font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced)).opacity(0.7)
                    }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(port == nil)
                .help("Toggle fullscreen (\(DevTerminalLogic.fullscreenHint))")
            }
            .buttonStyle(.vesper())
        }
        .vesperText(.body, theme)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.palette.border).frame(height: 1) }
    }

    private func notReady(_ ws: API.DevWorkspace) -> some View {
        VStack(spacing: 12) {
            Text(ws.state == .starting ? (ws.step?.value.flatMap { $0.isEmpty ? nil : $0 } ?? "Preparing Nix + LazyVim container…")
                                       : "Dev workspace container is not ready yet.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(gruvbox(DevTerminalTheme.foreground))
            Text("First boot builds the Nix profile and clones configured repositories.")
                .font(.system(size: 13))
                .foregroundStyle(gruvbox(DevTerminalTheme.mutedText))
            if ws.state != .starting {
                Button("Start container") { run(.start) }
                    .buttonStyle(.vesper(.primary))
                    .disabled(model.actionPending)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Full screen's floating bar: the socket's dot, Reconnect when it dropped, and Exit (web overlay).
    private func fullscreenOverlay(port: Int?) -> some View {
        let dot = switch model.connection {
        case .connected: DevTerminalTheme.dotConnected
        case .connecting: DevTerminalTheme.dotConnecting
        case .disconnected: DevTerminalTheme.dotDisconnected
        }
        return DevFullscreenBar {
            HStack(spacing: 8) {
                Circle().fill(gruvbox(dot)).frame(width: 6, height: 6)
                if port != nil && model.connection == .disconnected {
                    Button("Reconnect") { reconnectSeq += 1 }
                        .buttonStyle(DevOverlayButtonStyle(filled: false))
                }
                Button(action: toggleFullscreen) {
                    HStack(spacing: 4) {
                        Text("Exit").fontWeight(.medium)
                        Text(DevTerminalLogic.fullscreenHint).font(.system(size: 10, design: .monospaced)).opacity(0.7)
                    }
                }
                .buttonStyle(DevOverlayButtonStyle(filled: true))
                .help("Exit fullscreen (\(DevTerminalLogic.fullscreenHint))")
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 12)
    }

    private func gruvbox(_ hex: String) -> Color {
        let c = RGBA(hex: hex) ?? RGBA(red: 0, green: 0, blue: 0)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    // MARK: Actions

    private func run(_ action: API.DevWorkspaceActionRequest.Action) {
        model.actionPending = true
        Task {
            defer { model.actionPending = false }
            do {
                let ws = try await context.store.mutate(API.devWorkspaceAction(body: .init(action: action)))
                context.store.setData(ws, for: Self.request)
            } catch {
                context.showToast(ToastItemModel(id: "dev.action", title: "Couldn\u{2019}t \(action == .sync ? "sync repos" : "start the container")",
                                                 description: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
            }
        }
    }

    private func toggleFullscreen() { setFullscreen(!model.fullscreen) }

    /// The web's fullscreen gave the terminal the whole screen: here the window enters macOS full screen
    /// (unless it already is) and the sidebar folds, then both come back as they were.
    private func setFullscreen(_ on: Bool) {
        guard on != model.fullscreen else { return }
        let controller = context.window()
        model.fullscreen = on
        controller?.state.sidebarHidden = on
        if let window = controller?.window {
            let isFull = window.styleMask.contains(.fullScreen)
            if on && !isFull {
                model.enteredWindowFullScreen = true
                window.toggleFullScreen(nil)
            } else if !on && model.enteredWindowFullScreen {
                model.enteredWindowFullScreen = false
                if isFull { window.toggleFullScreen(nil) }
            }
        }
        DispatchQueue.main.async { model.focus() }
    }

    /// Writes the visible output (and the selection) to a Markdown file and offers it to a chat through
    /// the app's send picker, as Screenshot to Chat does. The web attached it to the open companion chat.
    private func sendToChat() {
        guard let view = model.view, let aux = context.window()?.app.aux else { return }
        let now = Date()
        let size = view.size
        let markdown = DevTerminalLogic.snapshotMarkdown(lines: DevTerminalLogic.snapshotLines(view.bufferText), selection: view.selectedText,
                                                         cols: size.cols, rows: size.rows, at: now)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-dev-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let file = dir.appendingPathComponent(DevTerminalLogic.snapshotFilename(at: now))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(markdown.utf8).write(to: file)
        } catch {
            context.showToast(ToastItemModel(id: "dev.snapshot", title: "Couldn\u{2019}t save the terminal output",
                                             description: error.localizedDescription, tone: .error))
            return
        }
        aux.files.offer([file.path], cleanup: { try? FileManager.default.removeItem(at: dir) })
        model.sentNotice = true
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            model.sentNotice = false
        }
    }
}

/// The floating bar's frame: faint until hovered, as the web's `opacity-35 hover:opacity-100`.
private struct DevFullscreenBar<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .font(.system(size: 11))
            .foregroundStyle(Color(.sRGB, red: 0xeb / 255, green: 0xdb / 255, blue: 0xb2 / 255))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.sRGB, red: 0x1d / 255, green: 0x20 / 255, blue: 0x21 / 255, opacity: 0.9), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.sRGB, red: 0x3c / 255, green: 0x38 / 255, blue: 0x36 / 255)))
            .opacity(hovering ? 1 : 0.35)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct DevOverlayButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(filled ? Color(.sRGB, red: 0x3c / 255, green: 0x38 / 255, blue: 0x36 / 255) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if !filled { RoundedRectangle(cornerRadius: 4).stroke(Color(.sRGB, red: 0x50 / 255, green: 0x49 / 255, blue: 0x45 / 255)) }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// "Terminal & LazyVim shortcuts" (the web's dialog), grouped by tool.
private struct DevShortcutsSheet: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let groups: [DevTerminalLogic.ShortcutGroup]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal & LazyVim shortcuts").vesperText(.heading, theme)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.palette.secondaryText)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close shortcuts")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider().overlay(theme.palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(theme.palette.tertiaryText)
                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.offset) { index, item in
                                    if index > 0 { Divider().overlay(theme.palette.rowBorder) }
                                    HStack(spacing: 16) {
                                        Text(item.keys).font(.system(size: theme.pointSize(.small), weight: .medium, design: .monospaced))
                                        Spacer(minLength: 8)
                                        Text(item.description)
                                            .foregroundStyle(theme.palette.secondaryText)
                                            .multilineTextAlignment(.trailing)
                                    }
                                    .vesperText(.body, theme)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }
                            }
                            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 620)
        .frame(maxHeight: 640)
        .background(theme.swiftUIColor("surface-raised", fallback: theme.palette.surface))
    }
}
