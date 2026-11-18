import AppKit
import WebKit

/// Saves WKDownloads to ~/Downloads (Chromium's default): suggested filename, " 2"/" 3" on a clash,
/// the Downloads stack bounced when done, a small non-modal notice, errors shown.
@MainActor
final class WebDownloads: NSObject, WKDownloadDelegate {
    static let shared = WebDownloads()

    private var destinations: [ObjectIdentifier: URL] = [:]
    private var windows: [ObjectIdentifier: NSWindow] = [:]

    /// Takes over a download WebKit started from `webView`'s navigation.
    func adopt(_ download: WKDownload, in webView: WKWebView?) {
        download.delegate = self
        if let window = webView?.window { windows[ObjectIdentifier(download)] = window }
    }

    // MARK: Naming

    static func sanitizedName(_ suggested: String) -> String {
        var name = (suggested as NSString).lastPathComponent
        name = name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "download" : name
    }

    /// `dir/name`, or `dir/base 2.ext`, `base 3.ext`, ... for the first free one.
    static func uniqueURL(in dir: URL, name: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = dir.appendingPathComponent(name)
        if !exists(first) { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.uniqueURL(in: dir, name: Self.sanitizedName(suggestedFilename))
        destinations[ObjectIdentifier(download)] = dest
        vlog("download: -> \(dest.path)")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        let window = windows.removeValue(forKey: id)
        guard let dest = destinations.removeValue(forKey: id) else { return }
        vlog("download: finished \(dest.path)")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"), object: dest.path, userInfo: nil, deliverImmediately: true)
        DownloadNotice.show("Downloaded \(dest.lastPathComponent)", revealing: dest, over: window)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        let window = windows.removeValue(forKey: id)
        let dest = destinations.removeValue(forKey: id)
        if let dest { try? FileManager.default.removeItem(at: dest) }
        let ns = error as NSError
        vlog("download: failed \(ns.domain) \(ns.code)")
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        DownloadNotice.show("Download failed: \(ns.localizedDescription)", revealing: nil, over: window, isError: true)
    }
}

/// A small non-modal HUD at the bottom of the window; click "Show" to reveal the file.
@MainActor
enum DownloadNotice {
    private static var current: NSPanel?
    private static var timer: Timer?
    private static var target: URL?

    static func show(_ text: String, revealing file: URL?, over window: NSWindow?, isError: Bool = false) {
        dismiss()
        guard let parent = window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        target = file

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = isError ? .systemRed : .labelColor
        label.setAccessibilityRole(.staticText)
        var views: [NSView] = [label]
        if file != nil {
            let button = NSButton(title: "Show", target: NoticeActions.shared, action: #selector(NoticeActions.reveal))
            button.bezelStyle = .rounded
            button.controlSize = .small
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 10)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            effect.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        let size = effect.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = effect
        let frame = parent.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
        parent.addChildWindow(panel, ordered: .above)
        current = panel
        timer = Timer.scheduledTimer(withTimeInterval: isError ? 8 : 5, repeats: false) { _ in
            MainActor.assumeIsolated { DownloadNotice.dismiss() }
        }
    }

    static func dismiss() {
        timer?.invalidate()
        timer = nil
        if let panel = current {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        current = nil
    }

    fileprivate static func revealTarget() {
        if let target { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        dismiss()
    }
}

@MainActor
private final class NoticeActions: NSObject {
    static let shared = NoticeActions()
    @objc func reveal() { DownloadNotice.revealTarget() }
}
