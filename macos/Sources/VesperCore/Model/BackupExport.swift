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

    /// Downloads GET /api/v1/instance/export into `folder` as `<name>.part`, renames it when complete
    /// (mode 0600), then deletes Vesper's own exports beyond `keep`. Returns the final file.
    public static func export(
        client: APIClient, folder: String, keep: Int, now: Date = Date(), download: ExportDownload = defaultDownload
    ) async throws -> URL {
        guard !folder.isEmpty else { throw BackupImportError("Choose a folder first.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            throw BackupImportError("The export folder isn't a folder.")
        }
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        let final = folderURL.appendingPathComponent(Backups.exportFileName(now))
        let part = URL(fileURLWithPath: final.path + ".part")
        var request = URLRequest(url: try client.makeURL("/api/v1/instance/export"))
        request.httpMethod = "GET"
        client.authorize(&request)
        let fm = FileManager.default
        do {
            let (tmp, response) = try await download(request)
            defer { try? fm.removeItem(at: tmp) }
            guard (200..<300).contains(response.statusCode) else {
                throw BackupImportError("The server answered \(response.statusCode).")
            }
            try? fm.removeItem(at: part)
            try fm.moveItem(at: tmp, to: part)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: part, to: final)
        } catch {
            try? fm.removeItem(at: part)
            if let e = error as? BackupImportError { throw e }
            throw BackupImportError(error.localizedDescription)
        }
        let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        for name in Backups.exportsToPrune(names, keep: keep) { try? fm.removeItem(at: folderURL.appendingPathComponent(name)) }
        return final
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
