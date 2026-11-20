import AppKit
import CryptoKit
import Quartz
import UniformTypeIdentifiers
import VesperCore

private final class QuickLookPreviewItem: NSObject, QLPreviewItem, @unchecked Sendable {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}

/// The session cookie is set by hand on Quick Look downloads, and URLSession copies request
/// headers onto a followed redirect, so a redirect off the stack's origin is refused rather than
/// handing the session token to another host. The 3xx then fails the status check.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let base: URL

    init(base: URL) { self.base = base }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, BridgeOrigin.matches(url: target, base: base) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Manages macOS Quick Look (`QLPreviewPanel`) for same-origin Vesper files, images, audio,
/// videos, and PDFs. Downloads authenticated items to a temporary cache cleaned on exit.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private static let maxBytes = 100 * 1024 * 1024

    private weak var aux: AuxWindows?
    var connection: Connection? {
        didSet {
            if connection != oldValue {
                clearCache()
            }
        }
    }

    private let cacheDirectory: URL
    private var cachedFiles: [URL: URL] = [:]
    private var previewItems: [QuickLookPreviewItem] = []
    private var currentIndex = 0
    private var generation = 0
    private var fetchTask: Task<Void, Never>?

    var hasItems: Bool { !previewItems.isEmpty }

    init(aux: AuxWindows) {
        self.aux = aux
        self.cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-quicklook-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        super.init()
    }

    func preview(items: [QuickLookItem], index: Int?, from window: NSWindow?) {
        if connection == nil, let conn = aux?.app?.connection {
            connection = conn
        }
        guard let conn = connection, !items.isEmpty else { return }

        var resolvedPairs: [(url: URL, item: QuickLookItem)] = []
        for item in items {
            guard let resolved = URL(string: item.url, relativeTo: conn.baseURL)?.absoluteURL,
                  BridgeOrigin.matches(url: resolved, base: conn.baseURL) else {
                continue
            }
            resolvedPairs.append((resolved, item))
        }
        guard !resolvedPairs.isEmpty else { return }

        let targetIndex = QuickLookLogic.clampIndex(index, count: resolvedPairs.count)
        generation += 1
        let activeGen = generation
        fetchTask?.cancel()

        fetchTask = Task { @MainActor [weak self, weak window] in
            guard let self else { return }
            var loaded: [QuickLookPreviewItem] = []
            var mappedIndex: Int?
            for (pairIndex, pair) in resolvedPairs.enumerated() {
                guard !Task.isCancelled, self.generation == activeGen else { return }
                if let localURL = await self.materialize(url: pair.url, item: pair.item, conn: conn) {
                    if pairIndex == targetIndex {
                        mappedIndex = loaded.count
                    }
                    loaded.append(QuickLookPreviewItem(url: localURL, title: pair.item.title))
                }
            }
            guard !Task.isCancelled, self.generation == activeGen, !loaded.isEmpty else { return }
            self.previewItems = loaded
            self.currentIndex = QuickLookLogic.clampIndex(mappedIndex ?? targetIndex, count: loaded.count)
            window?.makeKeyAndOrderFront(nil)
            guard let panel = QLPreviewPanel.shared() else { return }
            if !panel.isVisible {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.updateController()
            panel.currentPreviewItemIndex = self.currentIndex
            panel.reloadData()
        }
    }

    func attach(to panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = QuickLookLogic.clampIndex(currentIndex, count: previewItems.count)
    }

    func detach(from panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    func cleanup() {
        fetchTask?.cancel()
        fetchTask = nil
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        clearCache()
    }

    // MARK: Private download & cache

    private func materialize(url: URL, item: QuickLookItem, conn: Connection) async -> URL? {
        if let existing = cachedFiles[url], FileManager.default.fileExists(atPath: existing.path) {
            return existing
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("\(StackSession.cookieName)=\(conn.sessionToken)", forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await URLSession.shared.data(
                for: request, delegate: SameOriginRedirects(base: conn.baseURL)
            )
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count <= Self.maxBytes else {
                return nil
            }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? item.contentType ?? "")
                .split(separator: ";")
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let preferredExt = mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            let leaf = url.lastPathComponent == "content" ? nil : url.lastPathComponent
            let name = QuickLookLogic.safeFilename(
                filename: item.filename,
                fallbackTitle: item.title,
                urlPathComponent: leaf,
                preferredExtension: preferredExt
            )

            let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let folder = cacheDirectory.appendingPathComponent(hash, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let localURL = folder.appendingPathComponent(name)
            try data.write(to: localURL, options: .atomic)
            cachedFiles[url] = localURL
            return localURL
        } catch {
            vlog("quickLook fetch failed for \(url.path): \(error)")
            return nil
        }
    }

    private func clearCache() {
        cachedFiles.removeAll()
        previewItems.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let item: QuickLookPreviewItem? = MainActor.assumeIsolated {
            guard previewItems.indices.contains(index) else { return nil }
            return previewItems[index]
        }
        return item
    }
}
