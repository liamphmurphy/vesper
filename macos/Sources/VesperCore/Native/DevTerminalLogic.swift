import Foundation

/// The Dev workspace terminal's rules: the Swift port of the terminal half of web/lib/dev-workspace.ts
/// (the web's xterm.js terminal is gone; Settings still uses the rest of that file).
public enum DevTerminalLogic {
    /// The terminal socket's state, shown in the header pill and the full-screen overlay's dot.
    public enum Connection: Sendable, Equatable { case connecting, connected, disconnected }

    // MARK: Socket

    /// The terminal socket for the workspace's port, on the host the app reaches Vesper at:
    /// `ws(s)://host:port/ws?cols=…&rows=…`. The runner serves it on a playground port beside the API.
    public static func socketURL(base: URL, port: Int, cols: Int, rows: Int) -> URL? {
        guard let host = base.host(percentEncoded: false), !host.isEmpty, (1...65535).contains(port) else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let scheme = base.scheme?.lowercased() == "https" ? "wss" : "ws"
        return URL(string: "\(scheme)://\(bracketed):\(port)/ws?cols=\(max(1, cols))&rows=\(max(1, rows))")
    }

    /// The `Origin` the socket must send: the runner only lets Vesper's own pages attach (it compares
    /// against WEB_URL/PUBLIC_URL as `scheme://host[:port]`), and the Mac app talks to that origin.
    public static func origin(of base: URL) -> String? {
        guard let scheme = base.scheme?.lowercased(), let host = base.host(percentEncoded: false), !host.isEmpty else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return base.port.map { "\(scheme)://\(bracketed):\($0)" } ?? "\(scheme)://\(bracketed)"
    }

    /// The control message that resizes the PTY (server/internal/runner/dev_workspace.go). Sent as a text
    /// frame; keystrokes go as binary frames so any byte reaches the shell.
    public static func resizeMessage(cols: Int, rows: Int) -> String {
        "{\"type\":\"resize\",\"cols\":\(max(1, cols)),\"rows\":\(max(1, rows))}"
    }

    // MARK: Status

    public static func statusTone(_ state: API.DevWorkspace.State) -> String {
        switch state {
        case .ready: "done"
        case .starting: "human"
        case .error: "blocked"
        default: "neutral"
        }
    }

    public static func statusLabel(enabled: Bool, state: API.DevWorkspace.State, step: String?) -> String {
        let step = step.flatMap { $0.isEmpty ? nil : $0 }
        if !enabled && state == .stopped { return "Stopped (not configured)" }
        if state == .starting { return step.map { "Starting · \($0)" } ?? "Starting…" }
        if state == .ready { return "Ready" }
        if state == .error { return "Error" }
        return "Stopped"
    }

    /// The header pill: the socket's state once it's open or opening, the workspace's otherwise.
    public static func pill(connection: Connection, enabled: Bool, state: API.DevWorkspace.State, step: String?) -> (label: String, tone: String) {
        switch connection {
        case .connected: ("Connected · tmux", "done")
        case .connecting: ("Connecting…", statusTone(state))
        case .disconnected: (statusLabel(enabled: enabled, state: state, step: step), statusTone(state))
        }
    }

    /// While the container starts or an action runs, the workspace is polled every 2 s (the web's BUSY_MS).
    public static func isBusy(state: API.DevWorkspace.State, action: String?) -> Bool {
        state == .starting || !(action ?? "").isEmpty
    }

    // MARK: Keys

    public static let fullscreenHint = "⌘⇧↵"

    /// ⌘⇧↵ (or ⌃⇧↵) toggles full screen; the terminal never sees it. `key` is the event's characters
    /// ignoring modifiers ("\r" for Return, "\u{3}" for keypad Enter).
    public static func isFullscreenShortcut(key: String, command: Bool, control: Bool, option: Bool, shift: Bool) -> Bool {
        guard command || control, shift, !option else { return false }
        return key == "\r" || key == "\u{3}"
    }

    public struct ShortcutGroup: Sendable, Equatable {
        public var title: String
        public var items: [(keys: String, description: String)]

        public static func == (a: ShortcutGroup, b: ShortcutGroup) -> Bool {
            a.title == b.title && a.items.elementsEqual(b.items) { $0.keys == $1.keys && $0.description == $1.description }
        }
    }

    public static func tmuxPrefixLabel(_ prefix: API.DevWorkspace.TmuxPrefix?) -> String {
        switch prefix?.rawValue {
        case "C-a": "Ctrl+a"
        case "C-Space": "Ctrl+Space"
        case "C-s": "Ctrl+s"
        default: "Ctrl+b"
        }
    }

    /// The Shortcuts sheet. LazyVim and tmux as on the web; the last group is the Mac app's (the web's
    /// described the browser's keyboard lock, which a native view doesn't need).
    public static func shortcutGroups(tmuxPrefix: API.DevWorkspace.TmuxPrefix?) -> [ShortcutGroup] {
        let p = tmuxPrefixLabel(tmuxPrefix)
        return [
            ShortcutGroup(title: "LazyVim & Neovim", items: [
                ("Space", "Leader menu (which-key)"),
                ("Space f f", "Find files across /workspace"),
                ("Space /", "Live grep (ripgrep)"),
                ("Space e", "Toggle file explorer"),
                ("Space g g", "Open lazygit"),
                ("Space f t", "Toggle floating terminal"),
                ("Ctrl+h / j / k / l", "Move between editor splits"),
                ("Ctrl+w", "Window management prefix"),
            ]),
            ShortcutGroup(title: "tmux (\(p) prefix)", items: [
                ("\(p) c", "New shell window"),
                ("\(p) n / p", "Next / previous window"),
                ("\(p) % / \"", "Split pane vertically / horizontally"),
                ("\(p) o", "Cycle panes"),
                ("\(p) [", "Scroll / copy mode (q to exit)"),
                ("\(p) d", "Detach session (keeps running)"),
            ]),
            ShortcutGroup(title: "Mac app & Full screen", items: [
                ("Cmd/Ctrl+Shift+Enter", "Toggle full screen"),
                ("Ctrl+Cmd+S", "Toggle left sidebar"),
                ("Esc, Ctrl+W / T / N", "Always sent to the terminal"),
                ("Option+key", "Sent as Meta (Alt)"),
                ("Cmd+C / Cmd+V", "Copy selection / paste into terminal"),
                ("Shift+drag", "Select text bypassing tmux mouse mode"),
                ("Vesper ▸ Secure Keyboard Entry", "Keep other apps from reading keystrokes"),
            ]),
        ]
    }

    // MARK: Clipboard

    /// Largest OSC 52 payload the terminal copies, in base64 characters (web OSC52_MAX_PAYLOAD).
    public static let osc52MaxPayload = 1 << 20

    /// The text of an OSC 52 clipboard write (tmux and Neovim copy through it), already base64-decoded by
    /// the emulator. Nil for an empty or oversized payload or one that isn't UTF-8. Reads ("?") are never
    /// answered, so the container can't read the host clipboard.
    public static func osc52Text(_ content: Data) -> String? {
        guard !content.isEmpty, content.count <= osc52MaxPayload / 4 * 3 else { return nil }
        return String(data: content, encoding: .utf8)
    }

    // MARK: Send to chat

    /// The last `maxLines` lines of the buffer's text up to its last non-blank line, each trimmed on the
    /// right (web extractTerminalLines).
    public static func snapshotLines(_ text: String, maxLines: Int = 120) -> [String] {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        guard let end = rows.lastIndex(where: { !$0.isEmpty }) else { return [] }
        let start = max(0, end - max(1, maxLines) + 1)
        return Array(rows[start...end])
    }

    /// "dev-terminal-20261116-061530.md" (UTC).
    public static func snapshotFilename(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "dev-terminal-\(f.string(from: date)).md"
    }

    /// The Markdown file "Send to chat" attaches: the selection (if any) and the visible output.
    public static func snapshotMarkdown(lines: [String], selection: String?, cols: Int, rows: Int, at date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = ["# Dev terminal snapshot", "", "- Captured: \(iso.string(from: date))", "- Size: \(cols)x\(rows)", ""]
        if let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            out += ["## Selected text", "", fence(selection), ""]
        }
        out += ["## Visible terminal output (\(lines.count) \(lines.count == 1 ? "line" : "lines"))", ""]
        out.append(lines.isEmpty ? "(empty)" : fence(lines.joined(separator: "\n")))
        var text = out.joined(separator: "\n")
        while text.last?.isWhitespace == true { text.removeLast() }
        return text + "\n"
    }

    /// A code fence longer than any backtick run inside.
    static func fence(_ s: String) -> String {
        var longest = 0, run = 0
        for c in s {
            run = c == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return "\(ticks)\n\(s)\n\(ticks)"
    }

    // MARK: Secure Keyboard Entry

    /// Whether secure event input should be on: the person turned it on and a Dev terminal has the
    /// keyboard in the key window (Terminal.app's Secure Keyboard Entry).
    public static func wantsSecureInput(enabled: Bool, terminalFocused: Bool, windowIsKey: Bool) -> Bool {
        enabled && terminalFocused && windowIsKey
    }
}

/// Keeps `EnableSecureEventInput`/`DisableSecureEventInput` balanced: the system counts calls, so each
/// terminal enables at most once and disables only what it enabled.
public struct SecureInputBalance: Sendable, Equatable {
    public enum Change: Sendable, Equatable { case enable, disable }
    public private(set) var isOn = false

    public init() {}

    /// The call to make so secure input matches `wanted`, or nil when it already does.
    public mutating func update(wanted: Bool) -> Change? {
        guard wanted != isOn else { return nil }
        isOn = wanted
        return wanted ? .enable : .disable
    }
}

/// The web terminal's Gruvbox palette and font (xterm.js `GRUVBOX_THEME`, 13 pt ui-monospace).
public enum DevTerminalTheme {
    public static let fontSize = 13.0
    public static let background = "#282828"
    public static let foreground = "#ebdbb2"
    public static let cursor = "#ebdbb2"
    public static let selection = "#504945"
    /// The frame around the terminal (`bg-[#1d2021]`), the overlay's border and its muted text.
    public static let chrome = "#1d2021"
    public static let chromeBorder = "#3c3836"
    public static let mutedText = "#a89984"
    /// The overlay's status dot: connected, connecting, disconnected.
    public static let dotConnected = "#b8bb26"
    public static let dotConnecting = "#fabd2f"
    public static let dotDisconnected = "#fb4934"
    /// ANSI 0–15: black, red, green, yellow, blue, magenta, cyan, white, then the bright ones.
    public static let ansi = [
        "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
        "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
    ]
}
