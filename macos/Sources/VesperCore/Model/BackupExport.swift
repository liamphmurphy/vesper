import Foundation

// Scheduled export and Time Machine exclusion (desktop/src/native.ts "backups"), plus the small
// app-state.json the Electron app kept beside config.json (last export / update check times).

/// `<dataDir>/app-state.json`. Only the keys this subsystem owns are touched; others are preserved.
public enum AppStateFile {
    public static func url(dataDirectory: URL) -> URL { dataDirectory.appendingPathComponent("app-state.json") }

    public static func read(dataDirectory: URL) -> [String: Any] { ConfigFile.readDictionary(at: url(dataDirectory: dataDirectory)) }

    public static func update(dataDirectory: URL, _ edit: (inout [String: Any]) -> Void) {
        var dict = read(dataDirectory: dataDirectory)
        edit(&dict)
        let file = url(dataDirectory: dataDirectory)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }

    /// Milliseconds since the epoch stored under `key`, if valid.
    public static func millis(_ dict: [String: Any], _ key: String) -> Double? {
        guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}

public typealias ExportDownload = @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)

public enum BackupExporter {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    public static let defaultDownload: ExportDownload = { request in
        let (url, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (url, http)
    }

    public static func responseIsEncrypted(_ response: HTTPURLResponse) -> Bool {
        if let hdr = response.value(forHTTPHeaderField: "X-Vesper-Backup-Encrypted"),
           hdr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
            return true
        }
        if let cd = response.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().contains(".vesper.enc") {
            return true
        }
        return false
    }

    /// Downloads GET /api/v1/instance/export to a temporary file, sets mode 0600, moves it straight
    /// into `folder` without staging a `.part` file inside the destination (which can trip cloud
    /// sync daemons such as iCloud Drive), then deletes Vesper's own exports beyond `keep`.
    /// Returns the final file.
    public static func export(
        client: APIClient, folder: String, keep: Int, now: Date = Date(), download: ExportDownload = defaultDownload
    ) async throws -> URL {
        guard !folder.isEmpty else { throw BackupImportError("Choose a folder first.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            throw BackupImportError("The export folder isn't a folder.")
        }
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        var request = URLRequest(url: try client.makeURL("/api/v1/instance/export"))
        request.httpMethod = "GET"
        client.authorize(&request)
        let fm = FileManager.default
        let final: URL
        do {
            let (tmp, response) = try await download(request)
            defer { try? fm.removeItem(at: tmp) }
            guard (200..<300).contains(response.statusCode) else {
                throw BackupImportError("The server answered \(response.statusCode).")
            }
            let encrypted = responseIsEncrypted(response)
            final = folderURL.appendingPathComponent(Backups.exportFileName(now, encrypted: encrypted))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: tmp, to: final)
        } catch {
            if let e = error as? BackupImportError { throw e }
            throw BackupImportError(error.localizedDescription)
        }
        let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        for name in Backups.exportsToPrune(names, keep: keep) { try? fm.removeItem(at: folderURL.appendingPathComponent(name)) }
        return final
    }

    /// Streams GET /api/v1/instance/export to `destination` with 0600 permissions.
    public static func exportToFile(
        client: APIClient, destination: URL, download: ExportDownload = defaultDownload
    ) async throws -> (url: URL, encrypted: Bool) {
        var request = URLRequest(url: try client.makeURL("/api/v1/instance/export"))
        request.httpMethod = "GET"
        client.authorize(&request)
        let fm = FileManager.default
        let (tmp, response) = try await download(request)
        defer { try? fm.removeItem(at: tmp) }
        guard (200..<300).contains(response.statusCode) else {
            throw BackupImportError("The server answered \(response.statusCode).")
        }
        let encrypted = responseIsEncrypted(response)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tmp, to: destination)
        return (destination, encrypted)
    }
}

public enum BackupEncryptionAPI {
    public static func status(client: APIClient) async throws -> BackupEncryptionStatus {
        try await client.get("/api/v1/instance/backup-encryption", as: BackupEncryptionStatus.self)
    }

    public static func setPassword(client: APIClient, password: String) async throws -> BackupEncryptionStatus {
        let body = try JSONEncoder().encode(["password": password])
        let data = try await client.request("PUT", "/api/v1/instance/backup-encryption", body: body)
        do {
            return try JSONDecoder().decode(BackupEncryptionStatus.self, from: data)
        } catch {
            throw APIError.decoding("\(error)")
        }
    }

    public static func clearPassword(client: APIClient) async throws {
        _ = try await client.request("DELETE", "/api/v1/instance/backup-encryption")
    }
}

public enum TimeMachine {
    public static let tmutil = URL(fileURLWithPath: "/usr/bin/tmutil")

    /// Keeps rebuildable folders (VM disks, caches, images) out of Time Machine, or puts them back.
    /// Without -p this is a sticky exclusion on the folder itself (an xattr): no admin rights needed.
    /// True when every folder reads back as it should (excluded when `exclude`, included otherwise).
    public static func apply(dataDirectory: URL, exclude: Bool) async -> Bool {
        var all = true
        for dir in Backups.timeMachineTargets(dataDirectory: dataDirectory.path) {
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let env = ProcessInfo.processInfo.environment
                // addexclusion can take ~10 s, so only change what isn't already the way it should be.
                func excluded() async throws -> Bool? {
                    Backups.parseIsExcluded(try await BackupImport.run(executable: tmutil, arguments: ["isexcluded", dir], environment: env, timeout: 15).stdout)
                }
                if try await excluded() != exclude {
                    _ = try await BackupImport.run(executable: tmutil, arguments: [exclude ? "addexclusion" : "removeexclusion", dir], environment: env, timeout: 60)
                }
                let now = try await excluded()
                if now != exclude { all = false }
            } catch {
                all = false
            }
        }
        return all
    }
}
