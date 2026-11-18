import AppKit
import VesperCore

/// "Vesper Logs": the last 256 KB of `<data>/logs/vesper-app.log`, refreshed every 2 s while the
/// window is visible (the earlier Electron logs page). Copy, Reveal in Finder, Restart Stack.
@MainActor
final class LogsWindowController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let logURL: URL
    private let readTail: () -> String
    private let restart: () -> Void
    private var timer: Timer?
    private var lastText: String?

    init(logURL: URL, readTail: @escaping () -> String, restart: @escaping () -> Void) {
        self.logURL = logURL
        self.readTail = readTail
        self.restart = restart
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.title = "Vesper Logs"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VesperLogs")
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(in window: NSWindow) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            return b
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [button("Copy", #selector(copyLog)), button("Reveal in Finder", #selector(reveal)),
                                      button("Restart Stack", #selector(restartStack)), status])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    func present() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard window?.isVisible == true || lastText == nil else { return }
        var text = readTail()
        if text.isEmpty { text = "(no log output yet)" }
        status.stringValue = logURL.path
        guard text != lastText else { return }
        lastText = text
        let atBottom = scroll.contentView.bounds.maxY >= textView.frame.height - 24
        let offset = scroll.contentView.bounds.origin
        textView.string = text
        if atBottom {
            textView.scrollToEndOfDocument(nil)
        } else {
            scroll.contentView.scroll(to: offset)
        }
    }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func reveal() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }

    @objc private func restartStack() { restart() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        lastText = nil
    }
}
