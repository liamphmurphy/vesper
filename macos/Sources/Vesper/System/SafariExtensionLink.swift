import Foundation
import VesperCore
import VesperSafariBridge

/// Connects Vesper for Safari (docs/dev/safari-extension.md) and the internal Browser's sharing API.
/// Each time the shell signs in to `vesper app` it mints the extension's token, replacing the last,
/// writes it to the file the Safari extension's sandbox reads, and caches it in memory so the
/// internal Browser reuses the exact same token without invalidating the Safari extension.
enum SafariExtensionLink {
    struct Minted: Decodable { let token: String }

    private actor TokenCache {
        var baseURL: URL?
        var token: String?
        var inFlight: Task<String, Error>?

        func cached(for baseURL: URL) -> String? {
            guard self.baseURL == baseURL else { return nil }
            return token
        }

        func store(baseURL: URL, token: String) {
            self.baseURL = baseURL
            self.token = token
        }

        func clear() {
            baseURL = nil
            token = nil
        }

        func getOrMint(client: APIClient, forceRefresh: Bool) async throws -> String {
            if !forceRefresh, let existing = cached(for: client.baseURL) {
                return existing
            }
            if let existingTask = inFlight {
                return try await existingTask.value
            }
            let task = Task<String, Error> {
                let data = try await client.request("POST", "/api/v1/browser-extension-token")
                let minted = try JSONDecoder().decode(Minted.self, from: data)
                try? SafariConnectionFile.write(SafariConnection(baseURL: client.baseURL.absoluteString, token: minted.token))
                return minted.token
            }
            inFlight = task
            defer { inFlight = nil }
            let token = try await task.value
            store(baseURL: client.baseURL, token: token)
            return token
        }
    }

    private static let cache = TokenCache()

    static func refresh(client: APIClient) {
        Task.detached(priority: .utility) {
            do {
                _ = try await cache.getOrMint(client: client, forceRefresh: true)
                vlog("safari extension: connection file written")
            } catch {
                // The extension then says Vesper isn't connected; nothing else depends on it.
                vlog("safari extension: couldn't write the connection file: \(error)")
            }
        }
    }

    /// Returns the cached extension token for `client.baseURL`, minting one if needed.
    static func token(using client: APIClient, forceRefresh: Bool = false) async throws -> String {
        try await cache.getOrMint(client: client, forceRefresh: forceRefresh)
    }

    static func reset() {
        Task { await cache.clear() }
    }
}
