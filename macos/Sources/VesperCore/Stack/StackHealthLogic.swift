import Foundation

// Port of desktop/src/stack-health.ts: the health of the bundled `vesper app` stack, derived from
// what the shell can observe. Pure, so every state has a unit test. (The Electron "remote" and
// "external" modes are dropped: the Swift app is local only.)

public enum StackAction: String, Sendable, Codable { case restart, logs, retry, settings, storage }

public struct StackExitInfo: Sendable, Equatable {
    public var code: Int32?
    public var signal: Int32?
    public var stderrTail: String
    public init(code: Int32? = nil, signal: Int32? = nil, stderrTail: String = "") {
        self.code = code
        self.signal = signal
        self.stderrTail = stderrTail
    }
}

public struct StackHealthInput: Sendable {
    public var arch: String
    /// Darwin kernel major (`uname -r`), e.g. 24 for macOS 15.
    public var darwinMajor: Int?
    public var starting: Bool
    public var processRunning: Bool
    public var startError: String?
    public var exit: StackExitInfo?
    public var freeDiskBytes: Int64?
    public var minFreeDiskGb: Int
    public var image: RootfsStatus?
    public var runnerOnline: Bool?

    public init(
        arch: String = "arm64", darwinMajor: Int? = 24, starting: Bool = false, processRunning: Bool = true,
        startError: String? = nil, exit: StackExitInfo? = nil, freeDiskBytes: Int64? = nil, minFreeDiskGb: Int = 10,
        image: RootfsStatus? = nil, runnerOnline: Bool? = nil
    ) {
        self.arch = arch
        self.darwinMajor = darwinMajor
        self.starting = starting
        self.processRunning = processRunning
        self.startError = startError
        self.exit = exit
        self.freeDiskBytes = freeDiskBytes
        self.minFreeDiskGb = minFreeDiskGb
        self.image = image
        self.runnerOnline = runnerOnline
    }
}

public struct ClassifiedStackError: Sendable, Equatable {
    public var title: String
    public var message: String
    public var nextStep: String
}

public enum StackHealthLogic {
    /// macOS 15 (Darwin 24) on Apple Silicon is the microVM runner's floor.
    public static let minDarwinMajor = 24
    static let gb: Int64 = 1 << 30

    public static func darwinMajor(release: String) -> Int? {
        Int(release.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "")
    }

    public static func formatBytes(_ n: Int64) -> String {
        if n < 0 { return "?" }
        if n >= gb { return String(format: "%.1f GB", Double(n) / Double(gb)) }
        if n >= 1 << 20 { return "\(Int((Double(n) / Double(1 << 20)).rounded())) MB" }
        return "\(Int((Double(n) / 1024).rounded())) KB"
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Turns a start error or crash output into a named failure with a next step. First match wins.
    public static func classifyStackError(_ text: String) -> ClassifiedStackError {
        if matches(text, #"virtualization|VZErrorDomain|com\.apple\.security\.virtualization|hypervisor"#) {
            return ClassifiedStackError(
                title: "Virtualization unavailable",
                message: "macOS refused to start a virtual machine for runs.",
                nextStep: "Vesper needs Apple Silicon with macOS 15 or later. A self-built app must sign bin/vesper with deploy/microvm/vz.entitlements (make -C macos app does this)."
            )
        }
        if matches(text, #"ENOSPC|no space left"#) {
            return ClassifiedStackError(title: "Disk full", message: "The data directory ran out of space.", nextStep: "Free up disk space, then restart the stack.")
        }
        if matches(text, #"address already in use|EADDRINUSE|bind: "#) {
            return ClassifiedStackError(
                title: "Port in use", message: "Another program is using Vesper's local port.",
                nextStep: "Quit the other program (or another Vesper), then restart the stack."
            )
        }
        if matches(text, #"SECRETS_KEY|safeStorage|Keychain"#) {
            return ClassifiedStackError(
                title: "Keychain key unavailable", message: "Vesper couldn't read its secrets key from the macOS Keychain.",
                nextStep: "Unlock the login keychain and allow Vesper access when macOS asks, then restart the stack."
            )
        }
        if matches(text, #"embedded postgres|postgres|initdb|pg_ctl"#) {
            return ClassifiedStackError(
                title: "Database didn't start", message: "The bundled Postgres failed to start.",
                nextStep: "Open the logs to see why. If another Vesper is running, quit it first."
            )
        }
        if matches(text, #"Timed out waiting"#) {
            return ClassifiedStackError(
                title: "Stack is slow to start", message: "vesper app didn't report ready within 30 seconds.",
                nextStep: "Restart the stack; if it keeps timing out, open the logs."
            )
        }
        return ClassifiedStackError(
            title: "Stack stopped", message: "The local Vesper stack exited unexpectedly.",
            nextStep: "Restart the stack. If it keeps stopping, open the logs."
        )
    }

    public static func derive(_ input: StackHealthInput) -> StackHealth {
        if input.arch != "arm64" || (input.darwinMajor.map { $0 < minDarwinMajor } ?? false) {
            return StackHealth(
                phase: .error, title: "Virtualization unavailable", message: "This Mac can't run Vesper's microVMs.",
                nextStep: "Vesper needs Apple Silicon with macOS 15 or later.", actions: []
            )
        }
        let lowDisk = input.freeDiskBytes.map { $0 < Int64(input.minFreeDiskGb) * gb } ?? false

        if input.startError != nil || (input.exit != nil && !input.processRunning && !input.starting) {
            let c = classifyStackError("\(input.startError ?? "")\n\(input.exit?.stderrTail ?? "")")
            let override = lowDisk && c.title == "Stack stopped"
            return StackHealth(
                phase: .error,
                title: override ? "Disk almost full" : c.title,
                message: override ? "Only \(formatBytes(input.freeDiskBytes ?? 0)) free in the data directory." : c.message,
                nextStep: override ? "Free up disk space, then restart the stack." : c.nextStep,
                actions: override ? [.restart, .storage, .logs] : [.restart, .logs]
            )
        }
        if input.starting {
            return StackHealth(phase: .starting, title: "Starting Vesper…", message: "Starting the database, server and runner.", actions: [.logs])
        }
        if !input.processRunning {
            return StackHealth(phase: .stopped, title: "Stack stopped", message: "The local Vesper stack isn't running.", nextStep: "Start it again.", actions: [.restart, .logs])
        }
        if let image = input.image, image.state == .downloading {
            let done = image.downloadedBytes ?? 0
            let total = image.totalBytes ?? 0
            return StackHealth(
                phase: .downloading,
                title: "Downloading the run image",
                message: total > 0
                    ? "\(formatBytes(done)) of \(formatBytes(total)). Runs start once it's done."
                    : "\(formatBytes(done)) so far. Runs start once it's done.",
                nextStep: "This happens once, on first launch.",
                downloadFraction: total > 0 ? min(1, max(0, Double(done) / Double(total))) : nil,
                actions: [.logs], downloadedBytes: done, totalBytes: total
            )
        }
        if let image = input.image, image.state == .error {
            let detail = image.error.flatMap { $0.isEmpty ? nil : $0 } ?? "the agent image couldn't be prepared"
            return StackHealth(
                phase: .degraded, title: "Run image unavailable", message: "Chats and runs can't start: \(detail).",
                nextStep: (image.error ?? "").contains("VESPER_ROOTFS_URL")
                    ? "Build it with deploy/microvm/build-images.sh, or set VESPER_ROOTFS_URL, then restart the stack."
                    : "Check your connection and disk space, then restart the stack.",
                actions: [.restart, .logs]
            )
        }
        if lowDisk {
            return StackHealth(
                phase: .degraded, title: "Disk almost full",
                message: "Only \(formatBytes(input.freeDiskBytes ?? 0)) free in the data directory (warning below \(input.minFreeDiskGb) GB).",
                nextStep: "Free up disk space before starting more runs.", actions: [.storage, .logs]
            )
        }
        if input.runnerOnline == false {
            return StackHealth(
                phase: .degraded, title: "Runner offline", message: "The server is up but its runner isn't, so runs won't start.",
                nextStep: "Restart the stack. If it stays offline, open the logs.", actions: [.restart, .logs]
            )
        }
        return StackHealth(phase: .running, title: "Vesper is running", actions: [.logs])
    }

    /// Auto-restart guard: at most `max` restarts within `window` seconds.
    public static func shouldAutoRestart(restartTimes: [Date], now: Date, max: Int = 3, window: TimeInterval = 600) -> Bool {
        restartTimes.filter { now.timeIntervalSince($0) < window }.count < max
    }

    /// The last `maxBytes` of a log file, starting at a line boundary. Empty when missing.
    public static func readLogTail(_ url: URL, maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "" }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        if start == 0 { return text }
        if let nl = text.firstIndex(of: "\n") { return String(text[text.index(after: nl)...]) }
        return text
    }

    public static func freeDiskBytes(at url: URL) -> Int64? {
        var probe = url
        // The data directory may not exist yet; ask its nearest existing parent.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let free = values.volumeAvailableCapacity
        else { return nil }
        return Int64(free)
    }
}
