import Foundation

// The release feed request behind Updates (desktop/src/native.ts checkForUpdates). The feed is public,
// so nothing about the person is sent; the pure parts are in Updates.swift.

public typealias UpdateTransport = @Sendable (URLRequest) async throws -> Data

public enum UpdateCheck {
    public static let defaultTransport: UpdateTransport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    /// The newer release, or nil when this build is current (or the feed's answer isn't a usable release).
    public static func fetch(feedURL: String, currentVersion: String, transport: UpdateTransport = defaultTransport) async throws -> UpdateInfo? {
        guard let url = URL(string: feedURL) else { throw BackupImportError("The update feed isn't a valid address.") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Vesper-Mac/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let data = try await transport(request)
        let release = try? JSONSerialization.jsonObject(with: data)
        return Updates.pickUpdate(currentVersion: currentVersion, feedURL: feedURL, release: release)
    }
}
