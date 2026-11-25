#if os(macOS)
import Foundation

// Port of the backup inspect/import helpers in desktop/src/stack.ts. The bundled `vesper` binary does
// the work (`vesper app-import`, server/cmd/vesper/app_import.go); this builds its arguments and
// environment and reads what it prints.

/// What `vesper app-import -inspect` prints about a backup archive.
public struct BackupInspection: Sendable, Equatable, Decodable {
    public var exportedAt: String
    public var appVersion: String
    public var schemaVersion: Int
    public var tableCount: Int
    public var totalRows: Int
    public var objectCount: Int
    public var secretsKeyFingerprint: String?
    public var encryptedSecretRows: Int
    public var matchesCurrentKey: Bool
    public var encrypted: Bool
    public var needsPassword: Bool

    enum CodingKeys: String, CodingKey {
        case exportedAt, appVersion, schemaVersion, tableCount, totalRows, objectCount
        case secretsKeyFingerprint, encryptedSecretRows, matchesCurrentKey
        case encrypted, needsPassword
    }

    public init(
        exportedAt: String, appVersion: String, schemaVersion: Int, tableCount: Int, totalRows: Int,
        objectCount: Int, secretsKeyFingerprint: String? = nil, encryptedSecretRows: Int, matchesCurrentKey: Bool,
        encrypted: Bool = false, needsPassword: Bool = false
    ) {
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.tableCount = tableCount
        self.totalRows = totalRows
        self.objectCount = objectCount
        self.secretsKeyFingerprint = secretsKeyFingerprint
        self.encryptedSecretRows = encryptedSecretRows
        self.matchesCurrentKey = matchesCurrentKey
        self.encrypted = encrypted
        self.needsPassword = needsPassword
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exportedAt = try c.decode(String.self, forKey: .exportedAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        tableCount = try c.decode(Int.self, forKey: .tableCount)
        totalRows = try c.decode(Int.self, forKey: .totalRows)
        objectCount = try c.decode(Int.self, forKey: .objectCount)
        secretsKeyFingerprint = try c.decodeIfPresent(String.self, forKey: .secretsKeyFingerprint)
        encryptedSecretRows = try c.decode(Int.self, forKey: .encryptedSecretRows)
        matchesCurrentKey = try c.decode(Bool.self, forKey: .matchesCurrentKey)
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        needsPassword = try c.decodeIfPresent(Bool.self, forKey: .needsPassword) ?? false
    }

    /// The archive holds secrets sealed with a key, so importing needs that key (or dropping the secrets).
    public var hasEncryptedSecrets: Bool { !(secretsKeyFingerprint ?? "").isEmpty }
}

public struct BackupImportError: Error, Equatable, Sendable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum BackupImport {
    public static func inspectArguments(archive: String) -> [String] { ["app-import", "-inspect", archive] }

    public static func importArguments(dataDirectory: String, archive: String, dropSecrets: Bool) -> [String] {
        var args = ["app-import", "-data-dir", dataDirectory]
        if dropSecrets { args.append("-drop-secrets") }
        args.append(archive)
        return args
    }

    /// The environment for `inspect`: SECRETS_KEY is the current key (so it can report a match), or "".
    public static func inspectEnvironment(base: [String: String], currentKey: String?, backupPassword: String? = nil) -> [String: String] {
        var env = base
        env["SECRETS_KEY"] = (currentKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let pw = backupPassword, !pw.isEmpty {
            env["VESPER_BACKUP_PASSWORD"] = pw
        } else {
            env.removeValue(forKey: "VESPER_BACKUP_PASSWORD")
        }
        return env
    }

    /// The environment for the import itself: Postgres location, the archive's key (or "" when dropping secrets).
    public static func importEnvironment(
        base: [String: String], postgresBinDir: String, secretsKey: String?, dropSecrets: Bool, backupPassword: String? = nil
    ) -> [String: String] {
        var env = base
        env["VESPER_POSTGRES_BIN_DIR"] = postgresBinDir
        env["SECRETS_KEY"] = dropSecrets ? "" : (secretsKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        env.removeValue(forKey: "VESPER_NO_SIGNIN")
        if let pw = backupPassword, !pw.isEmpty {
            env["VESPER_BACKUP_PASSWORD"] = pw
        } else {
            env.removeValue(forKey: "VESPER_BACKUP_PASSWORD")
        }
        return env
    }

    /// The error message `vesper` printed: a JSON log line with `err` or `error`, else stderr, else `fallback`.
    public static func extractCLIError(stdout: String, stderr: String, fallback: String) -> String {
        for line in (stdout + "\n" + stderr).split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let e = obj["err"] as? String, !e.isEmpty { return e }
            if let e = obj["error"] as? String, !e.isEmpty { return e }
        }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? fallback : err
    }

    // MARK: Running

    typealias Output = ProcessRunner.Output

    static func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Output {
        try await ProcessRunner.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }

    /// Asks the bundled binary what the archive carries.
    public static func inspect(
        vesperBin: URL, archive: String, currentKey: String?, backupPassword: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> BackupInspection {
        let out = try await run(
            executable: vesperBin, arguments: inspectArguments(archive: archive),
            environment: inspectEnvironment(base: environment, currentKey: currentKey, backupPassword: backupPassword), timeout: 30
        )
        guard out.status == 0 else {
            throw BackupImportError(extractCLIError(stdout: out.stdout, stderr: out.stderr, fallback: "Vesper couldn't read that archive."))
        }
        guard let insp = try? JSONDecoder().decode(BackupInspection.self, from: Data(out.stdout.utf8)) else {
            throw BackupImportError("Vesper couldn't read that archive.")
        }
        return insp
    }

    /// Runs the import into `dataDirectory`. The stack must already be stopped.
    public static func run(
        vesperBin: URL, postgresBinDir: URL, dataDirectory: String, archive: String, secretsKey: String?, dropSecrets: Bool,
        backupPassword: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        let out = try await run(
            executable: vesperBin,
            arguments: importArguments(dataDirectory: dataDirectory, archive: archive, dropSecrets: dropSecrets),
            environment: importEnvironment(
                base: environment, postgresBinDir: postgresBinDir.path, secretsKey: secretsKey, dropSecrets: dropSecrets,
                backupPassword: backupPassword
            ),
            timeout: 15 * 60
        )
        guard out.status == 0 else {
            throw BackupImportError(extractCLIError(stdout: out.stdout, stderr: out.stderr, fallback: "The import failed (exit \(out.status))."))
        }
    }
}
#endif
