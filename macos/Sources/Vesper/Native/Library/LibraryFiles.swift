import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import VesperCore

/// Library files on disk, fetched from the API with the app's session: for dragging out to Finder,
/// playing video and audio, and Save a Copy. Downloads are kept for the rest of the run in a
/// per-process temporary folder, so a second drag or play doesn't fetch again.
enum LibraryFiles {
    private static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("vesper-library-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    /// The file at an API path, downloaded once and named `filename` (sanitised, with an extension).
    static func localFile(path: String, filename: String, contentType: String? = nil, client: APIClient) async throws -> URL {
        let ext = contentType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
        let name = QuickLookLogic.safeFilename(filename: filename, fallbackTitle: filename, urlPathComponent: nil, preferredExtension: ext)
        let key = SHA256.hash(data: Data("\(client.baseURL.absoluteString)\(path)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let directory = folder.appendingPathComponent(key, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await client.request("GET", path, headers: ["Accept": "*/*"], timeout: 300)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// "Report.pdf" from a title that may already end in .pdf.
    static func pdfFilename(_ title: String) -> String {
        title.lowercased().hasSuffix(".pdf") ? title : "\(title).pdf"
    }

    /// Asks where to save, then writes a copy of the file there and says so in a toast.
    @MainActor
    static func saveCopy(path: String, filename: String, contentType: String? = nil, client: APIClient?, context: NativeScreenContext) {
        guard let client else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    let source = try await localFile(path: path, filename: filename, contentType: contentType, client: client)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: source, to: destination)
                    context.showToast(ToastItemModel(id: "library.saved.\(path)", title: "Saved \(destination.lastPathComponent)", tone: .success))
                } catch {
                    context.showToast(ToastItemModel(id: "library.save-failed.\(path)", title: "Couldn\u{2019}t save \(filename)",
                                                     description: (error as? APIError)?.userMessage ?? error.localizedDescription, tone: .error))
                }
            }
        }
        if let window = context.window()?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// What a tile hands to a drag: the file itself, fetched when the drop asks for it, so dropping on
    /// Finder or another app copies the real file.
    static func dragProvider(path: String, filename: String, contentType: String?, client: APIClient?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = filename
        guard let client else { return provider }
        let ext = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? contentType.flatMap { UTType(mimeType: $0) } ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let url = try await localFile(path: path, filename: filename, contentType: contentType, client: client)
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    vlog("library drag fetch failed for \(path): \(error)")
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

/// Library images for tiles and dialogs, fetched with the session and decoded off the main thread.
/// Tiles ask for a downsampled copy (`maxPixel`) so a grid of photos stays light.
@MainActor
final class LibraryImages {
    static let shared = LibraryImages()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private static let maxBytes = 60 * 1024 * 1024

    init() { cache.countLimit = 400 }

    func image(path: String, maxPixel: CGFloat?, client: APIClient?) async -> NSImage? {
        guard let client else { return nil }
        let key = "\(client.baseURL.absoluteString)|\(path)|\(maxPixel.map { "\(Int($0))" } ?? "full")"
        if let hit = cache.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<NSImage?, Never> {
            guard let data = try? await client.request("GET", path, headers: ["Accept": "image/*"], timeout: 60),
                  data.count <= Self.maxBytes else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixel: maxPixel) }.value
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    /// A thumbnail through ImageIO when it can make one; SVG (diagrams) and anything else NSImage reads as is.
    nonisolated private static func decode(_ data: Data, maxPixel: CGFloat?) -> NSImage? {
        if let maxPixel, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixel,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: thumbnail, size: .zero)
        }
        return NSImage(data: data)
    }
}
