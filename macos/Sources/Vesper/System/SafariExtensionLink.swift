import Foundation
import VesperCore
import VesperSafariBridge

/// Connects Vesper for Safari (docs/dev/safari-extension.md). Each time the shell signs in to
/// `vesper app` it mints the extension's token, replacing the last, and writes it with the server's
/// address to the file the extension's sandbox may read. The token only reaches
/// /api/v1/browser-extension/*, so the file never holds the session.
enum SafariExtensionLink {
    struct Minted: Decodable { let token: String }

    static func refresh(client: APIClient) {
        Task.detached(priority: .utility) {
            do {
                let data = try await client.request("POST", "/api/v1/browser-extension-token")
                let minted = try JSONDecoder().decode(Minted.self, from: data)
                try SafariConnectionFile.write(SafariConnection(baseURL: client.baseURL.absoluteString, token: minted.token))
                vlog("safari extension: connection file written")
            } catch {
                // The extension then says Vesper isn't connected; nothing else depends on it.
                vlog("safari extension: couldn't write the connection file: \(error)")
            }
        }
    }
}
