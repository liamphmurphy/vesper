import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI
import VesperCore

/// Secure Keyboard Entry, as Terminal.app has it: while it's on and a Dev terminal has the keyboard,
/// macOS keeps other processes from reading keystrokes (`EnableSecureEventInput`). The choice is
/// remembered in the app's defaults and toggled from the Vesper menu or the screen's title menu.
@MainActor
enum DevSecureKeyboardEntry {
    static let defaultsKey = "VesperDevSecureKeyboardEntry"
    static let didChange = Notification.Name("VesperDevSecureKeyboardEntryDidChange")

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The Vesper menu's item ("Secure Keyboard Entry"); it reaches the focused terminal through the
    /// responder chain, so it's enabled only while one has the keyboard.
    static let toggleAction = #selector(DevTerminalNSView.toggleSecureKeyboardEntry(_:))
}

/// SwiftTerm's AppKit terminal with what the Dev workspace adds: the web's Gruvbox colours and font,
/// Secure Keyboard Entry while focused, and ⌘⇧↵ for full screen before the terminal sees the key.
@MainActor
final class DevTerminalNSView: TerminalView {
    /// ⌘⇧↵ or ⌃⇧↵ in this window, wherever the keyboard focus is (the web listened on the window).
    var onFullscreenShortcut: (() -> Void)?

    private var secureInput = SecureInputBalance()
    /// Set from SwiftTerm's focus hook, which runs before the window records its new first responder.
    private var focused = false
    private var keyMonitor: Any?
    private var settingObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: DevTerminalTheme.fontSize, weight: .regular))
        applyTheme()
        // xterm.js rings no bell by default; tmux and zsh bells would otherwise beep at every Tab.
        bellStyle = .none
        settingObserver = NotificationCenter.default.addObserver(forName: DevSecureKeyboardEntry.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSecureInput() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func applyTheme() {
        func color(_ hex: String) -> NSColor {
            let c = RGBA(hex: hex) ?? RGBA(red: 0, green: 0, blue: 0)
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
        installColors(DevTerminalTheme.ansi.map { hex in
            let c = RGBA(hex: hex) ?? RGBA(red: 0, green: 0, blue: 0)
            return SwiftTerm.Color(red: UInt16(c.red * 65535), green: UInt16(c.green * 65535), blue: UInt16(c.blue * 65535))
        })
        nativeBackgroundColor = color(DevTerminalTheme.background)
        nativeForegroundColor = color(DevTerminalTheme.foreground)
        caretColor = color(DevTerminalTheme.cursor)
        selectedTextBackgroundColor = color(DevTerminalTheme.selection)
    }

    // MARK: What the screen reads and writes

    var size: (cols: Int, rows: Int) {
        let terminal = getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// The active buffer's text, scrollback included, one line per row.
    var bufferText: String { String(decoding: getTerminal().getBufferAsData(kind: .active), as: UTF8.self) }

    var selectedText: String? { getSelection() }

    /// Bytes from the PTY.
    func output(_ bytes: [UInt8]) { feed(byteArray: bytes[...]) }

    // MARK: Focus and Secure Keyboard Entry

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            focused = newValue
            updateSecureInput()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        removeKeyMonitor()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateSecureInput() }
                })
            }
            installKeyMonitor()
        }
        updateSecureInput()
    }

    private func updateSecureInput() {
        let wanted = DevTerminalLogic.wantsSecureInput(enabled: DevSecureKeyboardEntry.isEnabled, terminalFocused: focused && window != nil,
                                                       windowIsKey: window?.isKeyWindow ?? false)
        switch secureInput.update(wanted: wanted) {
        case .enable?: EnableSecureEventInput()
        case .disable?: DisableSecureEventInput()
        case nil: break
        }
    }

    @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
        DevSecureKeyboardEntry.isEnabled.toggle()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == DevSecureKeyboardEntry.toggleAction {
            (item as? NSMenuItem)?.state = DevSecureKeyboardEntry.isEnabled ? .on : .off
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Full screen shortcut

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags
            guard DevTerminalLogic.isFullscreenShortcut(key: event.charactersIgnoringModifiers ?? "",
                                                       command: flags.contains(.command), control: flags.contains(.control),
                                                       option: flags.contains(.option), shift: flags.contains(.shift))
            else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.windowNumber == windowNumber,
                      !self.isHiddenOrHasHiddenAncestor else { return false }
                self.onFullscreenShortcut?()
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Releases secure input and the monitors; the view is leaving for good.
    func teardown() {
        removeKeyMonitor()
        removeWindowObservers()
        if let settingObserver { NotificationCenter.default.removeObserver(settingObserver) }
        settingObserver = nil
        if secureInput.update(wanted: false) == .disable { DisableSecureEventInput() }
        terminalDelegate = nil
    }
}

/// Hosts the SwiftTerm view; a new `id` (port or Reconnect) makes a fresh emulator and socket.
struct DevTerminalRepresentable: NSViewRepresentable {
    let model: DevTerminalModel
    let port: Int
    let client: APIClient?
    let onFullscreenShortcut: () -> Void

    func makeCoordinator() -> DevTerminalCoordinator { DevTerminalCoordinator(model: model) }

    func makeNSView(context: Context) -> DevTerminalNSView {
        let view = DevTerminalNSView()
        view.terminalDelegate = context.coordinator
        view.onFullscreenShortcut = onFullscreenShortcut
        model.attach(view, port: port, client: client)
        return view
    }

    func updateNSView(_ view: DevTerminalNSView, context: Context) {
        view.onFullscreenShortcut = onFullscreenShortcut
    }

    static func dismantleNSView(_ view: DevTerminalNSView, coordinator: DevTerminalCoordinator) {
        coordinator.model.detach(view)
        view.teardown()
    }
}

/// SwiftTerm's callbacks: keystrokes and size changes go to the PTY, OSC 52 copies to the pasteboard.
@MainActor
final class DevTerminalCoordinator {
    let model: DevTerminalModel

    init(model: DevTerminalModel) { self.model = model }
}

extension DevTerminalCoordinator: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        model.socket.resize(cols: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        model.socket.send(data)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = DevTerminalLogic.osc52Text(content) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Only web links open (OSC 8 or a URL in the output); the container could print any scheme.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
