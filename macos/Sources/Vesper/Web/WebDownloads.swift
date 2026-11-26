import AppKit
import Observation
import VesperCore
import WebKit

struct BrowserDownloadRecord: Identifiable, Equatable {
    enum State: Equatable {
        case inProgress
        case finished
        case failed(String)
    }

    let id: UUID
    var filename: String
    var destinationURL: URL?
    var state: State
    var startedAt: Date
    var isRisky: Bool = false
}

/// Saves WKDownloads to ~/Downloads (Chromium's default): suggested filename, " 2"/" 3" on a clash,
/// optional per-host confirmation for internal Browser tabs, explicit macOS Gatekeeper quarantine
/// stamping (`com.apple.quarantine`), the Downloads stack bounced when done, a small non-modal
/// notice, errors shown, and an observable list of recent downloads for the Browser's Downloads popover.
@MainActor
@Observable
final class WebDownloads: NSObject, WKDownloadDelegate {
    static let shared = WebDownloads()

    private(set) var recentDownloads: [BrowserDownloadRecord] = []

    /// Optional per-download confirmation callback (used by internal Browser tabs for per-site
    /// download prompts and executable/installer warnings). Returns `true` to proceed.
    @ObservationIgnored private var confirmHandlers: [ObjectIdentifier: @MainActor (String, URL?, URL?) async -> Bool] = [:]
    @ObservationIgnored private var destinations: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var windows: [ObjectIdentifier: NSWindow] = [:]
    @ObservationIgnored private var recordIDs: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var originURLs: [ObjectIdentifier: URL] = [:]
    @ObservationIgnored private var dataURLs: [ObjectIdentifier: URL] = [:]

    var hasActiveDownloads: Bool {
        recentDownloads.contains(where: { $0.state == .inProgress })
    }

    func clearRecentDownloads() {
        recentDownloads.removeAll { $0.state != .inProgress }
    }

    /// Takes over a download WebKit started from `webView`'s navigation.
    func adopt(
        _ download: WKDownload,
        in webView: WKWebView?,
        confirmDownload: (@MainActor (String, URL?, URL?) async -> Bool)? = nil
    ) {
        download.delegate = self
        let key = ObjectIdentifier(download)
        if let window = webView?.window { windows[key] = window }
        if let origin = webView?.url { originURLs[key] = origin }
        if let reqURL = download.originalRequest?.url { dataURLs[key] = reqURL }
        if let confirmDownload { confirmHandlers[key] = confirmDownload }
        let recID = UUID()
        recordIDs[key] = recID
        recentDownloads.insert(
            BrowserDownloadRecord(id: recID, filename: "Preparing download…", destinationURL: nil, state: .inProgress, startedAt: Date()),
            at: 0
        )
        if recentDownloads.count > 25 {
            recentDownloads = Array(recentDownloads.prefix(25))
        }
    }

    /// Explicitly stamps macOS Gatekeeper web-download quarantine metadata (`com.apple.quarantine`)
    /// onto a downloaded file so Gatekeeper always checks downloaded apps, scripts, and archives
    /// without needing app-wide `LSFileQuarantineEnabled` (which would quarantine Postgres/data files).
    @discardableResult
    static func applyWebDownloadQuarantine(to fileURL: URL, dataURL: URL?, originURL: URL?) -> Bool {
        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Vesper",
            kLSQuarantineAgentBundleIdentifierKey as String: Bundle.main.bundleIdentifier ?? "com.vesper.mac",
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        if let dataURL {
            props[kLSQuarantineDataURLKey as String] = dataURL
        }
        if let originURL {
            props[kLSQuarantineOriginURLKey as String] = originURL
        }
        var mutableURL = fileURL
        var values = URLResourceValues()
        values.quarantineProperties = props
        do {
            try mutableURL.setResourceValues(values)
            return true
        } catch {
            vlog("download: failed to stamp quarantine on \(fileURL.lastPathComponent): \(error)")
            return false
        }
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
        let key = ObjectIdentifier(download)
        let safeName = Self.sanitizedName(suggestedFilename)
        let dataURL = response.url ?? dataURLs[key] ?? download.originalRequest?.url
        let originURL = originURLs[key] ?? dataURL
        if let dataURL { dataURLs[key] = dataURL }
        if let originURL { originURLs[key] = originURL }

        let confirm = confirmHandlers.removeValue(forKey: key)
        Task { @MainActor in
            if let confirm {
                let allowed = await confirm(safeName, dataURL, originURL)
                guard allowed else {
                    self.windows.removeValue(forKey: key)
                    self.originURLs.removeValue(forKey: key)
                    self.dataURLs.removeValue(forKey: key)
                    if let recID = self.recordIDs.removeValue(forKey: key) {
                        self.recentDownloads.removeAll { $0.id == recID }
                    }
                    completionHandler(nil)
                    return
                }
            }

            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = Self.uniqueURL(in: dir, name: safeName)
            self.destinations[key] = dest
            if let recID = self.recordIDs[key], let idx = self.recentDownloads.firstIndex(where: { $0.id == recID }) {
                self.recentDownloads[idx].filename = dest.lastPathComponent
                self.recentDownloads[idx].destinationURL = dest
                self.recentDownloads[idx].isRisky = BrowserDownloadGuard.isRiskyFilename(dest.lastPathComponent)
            }
            vlog("download: -> \(dest.path)")
            completionHandler(dest)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        let window = windows.removeValue(forKey: id)
        let recID = recordIDs.removeValue(forKey: id)
        let originURL = originURLs.removeValue(forKey: id)
        let dataURL = dataURLs.removeValue(forKey: id)
        confirmHandlers.removeValue(forKey: id)
        guard let dest = destinations.removeValue(forKey: id) else { return }

        Self.applyWebDownloadQuarantine(to: dest, dataURL: dataURL, originURL: originURL)

        if let recID, let idx = recentDownloads.firstIndex(where: { $0.id == recID }) {
            recentDownloads[idx].state = .finished
            recentDownloads[idx].destinationURL = dest
        }
        vlog("download: finished \(dest.path)")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.DownloadFileFinished"), object: dest.path, userInfo: nil, deliverImmediately: true)
        DownloadNotice.show("Downloaded \(dest.lastPathComponent)", revealing: dest, over: window)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let id = ObjectIdentifier(download)
        let window = windows.removeValue(forKey: id)
        let recID = recordIDs.removeValue(forKey: id)
        originURLs.removeValue(forKey: id)
        dataURLs.removeValue(forKey: id)
        confirmHandlers.removeValue(forKey: id)
        let dest = destinations.removeValue(forKey: id)
        if let dest { try? FileManager.default.removeItem(at: dest) }
        let ns = error as NSError
        vlog("download: failed \(ns.domain) \(ns.code)")
        if let recID, let idx = recentDownloads.firstIndex(where: { $0.id == recID }) {
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                recentDownloads.remove(at: idx)
            } else {
                recentDownloads[idx].state = .failed(ns.localizedDescription)
            }
        }
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

@MainActor
enum WebNavigationPolicy {
    /// Content-Disposition: attachment, or a type WebKit can't display, becomes a download.
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        if let http = response.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           cd.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") { return true }
        return !response.canShowMIMEType
    }
}
