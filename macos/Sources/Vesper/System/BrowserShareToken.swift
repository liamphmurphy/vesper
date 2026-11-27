import Foundation
import VesperCore

/// Caches the bearer token for `/api/v1/browser-extension/*`, which Vesper's internal Browser uses
/// to share tabs, ask personas about pages, clip to Knowledge/Library, and manage never-share hosts.
enum BrowserShareToken {
    private struct Minted: Decodable { let token: String }

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

    /// Returns the cached token for `client.baseURL`, minting one if needed.
    static func token(using client: APIClient, forceRefresh: Bool = false) async throws -> String {
        try await cache.getOrMint(client: client, forceRefresh: forceRefresh)
    }

    static func reset() {
        Task { await cache.clear() }
    }
}
