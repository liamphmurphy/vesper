import AppKit
import VesperCore

/// Persona and agent pictures for the native sidebar. The API serves them behind the session
/// cookie, so they're fetched with it, only from the Vesper origin (never another host), and
/// cached for the life of the app.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()

    /// Set by AppModel whenever the connection changes.
    var connection: Connection? {
        didSet { if connection != oldValue { cache.removeAll() } }
    }

    private var cache: [URL: NSImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private static let maxBytes = 5 * 1024 * 1024

    func image(for raw: String) async -> NSImage? {
        guard let conn = connection,
              let url = URL(string: raw, relativeTo: conn.baseURL)?.absoluteURL,
              BridgeOrigin.matches(url: url, base: conn.baseURL) else { return nil }
        if let hit = cache[url] { return hit }
        if failed.contains(url) { return nil }
        if let running = inFlight[url] { return await running.value }
        let task = Task<NSImage?, Never> {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpShouldHandleCookies = false
            request.setValue("\(StackSession.cookieName)=\(conn.sessionToken)", forHTTPHeaderField: "Cookie")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix("image/"),
                  data.count <= Self.maxBytes
            else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache[url] = image } else { failed.insert(url) }
        return image
    }
}
