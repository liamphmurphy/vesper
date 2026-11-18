import Foundation
import Observation

// The public surface the app target uses to run the bundled `vesper app` (docs/dev/native-mac-app.md,
// "Shell ↔ Go"). The window code depends only on this file's public API; the implementation fills
// in the bodies.

/// Health phases, as desktop/src/stack-health.ts (minus "remote": the app is local only).
public enum StackPhase: String, Sendable, Codable {
    case starting, downloading, running, degraded, error, stopped
}

/// What the window, menu bar and Dock show about the local stack.
public struct StackHealth: Sendable, Equatable {
    public var phase: StackPhase
    /// Short title, e.g. "Vesper is running", "Virtualization unavailable".
    public var title: String
    public var message: String
    /// What the person can do next, e.g. "Free up disk space, then restart the stack."
    public var nextStep: String?
    /// 0...1 while the run image downloads.
    public var downloadFraction: Double?
    /// What the person can do about it (buttons the window offers).
    public var actions: [StackAction]
    /// Run image download progress in bytes, while downloading.
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?

    public init(
        phase: StackPhase, title: String, message: String = "", nextStep: String? = nil, downloadFraction: Double? = nil,
        actions: [StackAction] = [], downloadedBytes: Int64? = nil, totalBytes: Int64? = nil
    ) {
        self.phase = phase
        self.title = title
        self.message = message
        self.nextStep = nextStep.flatMap { $0.isEmpty ? nil : $0 }
        self.downloadFraction = downloadFraction
        self.actions = actions
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }

    public static let initial = StackHealth(phase: .starting, title: "Starting…")
}

/// A signed-in connection to the running stack.
public struct StackSession: Sendable, Equatable {
    /// e.g. http://127.0.0.1:8080
    public var baseURL: URL
    /// The `vesper_session` cookie value. Put it into each web view's cookie store and send it on
    /// the shell's own API calls. Never log it.
    public var sessionToken: String

    public init(baseURL: URL, sessionToken: String) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken
    }

    public static let cookieName = "vesper_session"
}

/// Knobs for the controller. The defaults are what the app uses; tests and the integration test override them.
public struct StackOptions: Sendable {
    /// The resources directory. nil: `BundledResources.locate()` (VESPER_RESOURCES_DIR, the app bundle, or the repo's desktop/resources).
    public var resourcesDirectory: URL?
    public var port: Int
    /// Supplies SECRETS_KEY. nil: the Keychain (`SecretsKeyStore`).
    public var secretsKey: (@Sendable () throws -> String)?
    /// The environment `vesper app` inherits. nil: this process's.
    public var environment: [String: String]?
    public var startupTimeout: Duration
    public var healthPollInterval: Duration
    /// This build's version, for the run image download URL (packaged builds only).
    public var appVersion: String?

    public init(
        resourcesDirectory: URL? = nil, port: Int = 8080, secretsKey: (@Sendable () throws -> String)? = nil,
        environment: [String: String]? = nil, startupTimeout: Duration = .seconds(30),
        healthPollInterval: Duration = .seconds(5), appVersion: String? = nil
    ) {
        self.resourcesDirectory = resourcesDirectory
        self.port = port
        self.secretsKey = secretsKey
        self.environment = environment
        self.startupTimeout = startupTimeout
        self.healthPollInterval = healthPollInterval
        self.appVersion = appVersion
    }
}

/// Runs and supervises the bundled `vesper app`. One per app.
@MainActor
@Observable
public final class StackController {
    public private(set) var health: StackHealth = .initial
    /// Non-nil once the stack is ready and the shell is signed in.
    public private(set) var session: StackSession?
    /// The data dir passed to `vesper app` (default ~/Library/Application Support/vesper-desktop).
    public let dataDirectory: URL

    /// How the process last ended, or nil if it hasn't since the last start.
    public private(set) var lastExit: StackExitInfo?
    /// Why the last start failed, if it did.
    public private(set) var startError: String?
    /// The run image state from the last health poll.
    public private(set) var runImage: RootfsStatus?
    /// Whether the server's runner is connected (nil: unknown).
    public private(set) var runnerOnline: Bool?
    /// The runner's own max_concurrent and its current slot limit, from the last poll (0 / nil: unknown).
    public private(set) var runnerMaxSlots = 0
    public private(set) var runnerSlotLimit: Int?
    /// True between `start()` and the stack being ready, and while restarting.
    public private(set) var isStarting = false
    /// True while the `vesper app` process is alive.
    public private(set) var isProcessRunning = false

    /// Settings the controller reads (apply from `NativeSettings.stack` whenever they change).
    public var autoRestart = true
    public var minFreeDiskGb = 10
    /// RUNNER_MAX_CONCURRENT for the next start (the environment variable still wins). nil: leave the runner's default.
    public var runnerSlotsOverride: Int?
    /// Called when the process exits on its own after a successful start. `willRestart` says whether auto-restart will follow.
    public var onCrash: ((StackExitInfo, _ willRestart: Bool) -> Void)?
    /// Called whenever `session` changes (monitors start and stop from here).
    public var onSessionChange: ((StackSession?) -> Void)?

    private let options: StackOptions
    private var process: Process?
    private var generation = 0
    private var stopping = false
    private var collector: StackOutputCollector?
    private var startupContinuation: AsyncStream<StartupEvent>.Continuation?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var healthTask: Task<Void, Never>?
    private var restartTimes: [Date] = []
    private var startInFlight = false

    public init(dataDirectory: URL, options: StackOptions = StackOptions()) {
        self.dataDirectory = dataDirectory
        self.options = options
    }

    /// ~/Library/Application Support/vesper-desktop (Electron's `app.name`), or `VESPER_USER_DATA_DIR`.
    nonisolated public static func defaultDataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["VESPER_USER_DATA_DIR"]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("vesper-desktop", isDirectory: true)
    }

    /// `<dataDir>/logs/vesper-app.log`.
    public var logFileURL: URL { dataDirectory.appendingPathComponent("logs/vesper-app.log") }

    /// The end of the log file for the Logs window (default 256 KB), from a line boundary.
    public func recentLogTail(maxBytes: Int = 256 * 1024) -> String {
        StackHealthLogic.readLogTail(logFileURL, maxBytes: maxBytes)
    }

    /// An API client for the signed-in session, or nil.
    public func makeAPIClient() -> APIClient? { session.map { APIClient(session: $0) } }

    public func apply(_ settings: NativeSettings.Stack) {
        autoRestart = settings.autoRestart
        minFreeDiskGb = settings.minFreeDiskGb
        runnerSlotsOverride = settings.runnerSlots
        recomputeHealth()
    }

    // MARK: Start

    /// Starts the stack if it isn't running. Updates `health` and then `session`.
    public func start() async {
        guard !startInFlight, !isProcessRunning else { return }
        startInFlight = true
        defer { startInFlight = false }
        stopping = false
        isStarting = true
        startError = nil
        lastExit = nil
        runImage = nil
        runnerOnline = nil
        runnerMaxSlots = 0
        recomputeHealth()
        do {
            try await launchAndSignIn()
            isStarting = false
        } catch {
            isStarting = false
            let text = (error as? StackStartError)?.text ?? "\(error)"
            startError = text
            if let proc = process, proc.isRunning {
                stopping = true  // a failed start isn't a crash: no auto-restart
                await terminateProcess()
            }
            recomputeHealth()
            return
        }
        recomputeHealth()
        startHealthPolling()
    }

    private func launchAndSignIn() async throws {
        let env = options.environment ?? ProcessInfo.processInfo.environment
        let arch = Self.machineArchitecture()
        if arch != "arm64" { throw StackStartError("Virtualization unavailable: Vesper needs Apple Silicon.") }

        guard let base = options.resourcesDirectory ?? BundledResources.locate(environment: env),
              let resources = BundledResources.resolve(baseDir: base)
        else {
            throw StackStartError("Vesper's bundled resources (bin/vesper, postgres) weren't found. Rebuild the app (make -C macos app).")
        }

        let secretsKey: String
        do {
            secretsKey = try options.secretsKey?() ?? SecretsKeyStore(dataDirectory: dataDirectory).load()
        } catch {
            throw StackStartError("SECRETS_KEY unavailable from the Keychain: \(error)")
        }

        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let log = StackLogWriter(url: logFileURL)
        let collector = StackOutputCollector(log: log)
        self.collector = collector

        var rootfsUrl: String?
        if BundledResources.isPackaged() || options.appVersion != nil,
           let version = options.appVersion ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        {
            rootfsUrl = Updates.releaseAssetUrl(version: version, assetName: "agent-base.erofs")
        }
        let launch = StackLaunch(
            resources: resources, dataDirectory: dataDirectory, secretsKey: secretsKey, port: options.port,
            nodeBin: StackLaunch.resolveNode(resources: resources, environment: env), rootfsUrl: rootfsUrl,
            runnerSlots: runnerSlotsOverride
        )

        generation += 1
        let gen = generation
        let proc = Process()
        proc.executableURL = resources.vesperBin
        proc.arguments = launch.arguments
        proc.environment = launch.environment(base: env)
        proc.currentDirectoryURL = dataDirectory
        let stdout = Pipe(), stderr = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = stdout
        proc.standardError = stderr

        let (events, continuation) = AsyncStream<StartupEvent>.makeStream()
        startupContinuation = continuation
        collector.onReady = { url in continuation.yield(.ready(url)) }

        proc.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            Task { @MainActor in self?.processExited(generation: gen, status: status, reason: reason) }
        }
        stopping = false
        do {
            try proc.run()
        } catch {
            startupContinuation = nil
            throw StackStartError("Couldn't start vesper app: \(error.localizedDescription)")
        }
        process = proc
        isProcessRunning = true
        collector.startReading(stdout.fileHandleForReading, isStderr: false)
        collector.startReading(stderr.fileHandleForReading, isStderr: true)

        let timeout = options.startupTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(.timeout)
        }
        var outcome: StartupEvent = .timeout
        for await event in events {
            outcome = event
            break
        }
        timer.cancel()
        startupContinuation = nil

        switch outcome {
        case .ready(let urlString):
            guard let url = URL(string: urlString) else { throw StackStartError("vesper app printed an unusable URL: \(urlString)") }
            guard let code = collector.takeSignInCode() else {
                throw StackStartError("vesper app didn't print a sign-in code (is bin/vesper current? VESPER_APP_SIGN_IN_CODE=stdout)")
            }
            let token = try await StackSignIn.redeem(baseURL: url, code: code)
            session = StackSession(baseURL: url, sessionToken: token)
            onSessionChange?(session)
        case .exited:
            await collector.finishReading()
            throw StackStartError("vesper app exited unexpectedly (\(describeExit(lastExit))): \(collector.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .timeout:
            throw StackStartError("Timed out waiting for vesper app to start.\n\(collector.stderrTail)")
        }
    }

    // MARK: Stop / restart

    /// Stops and starts the stack (menu, menu bar, Settings, auto-restart).
    public func restart() async {
        await stop()
        runnerMaxSlots = 0
        await start()
    }

    /// SIGTERM, wait up to 10 s, then SIGKILL. Called on quit.
    public func stop() async {
        stopping = true
        healthTask?.cancel()
        healthTask = nil
        await terminateProcess()
        let hadSession = session != nil
        session = nil
        if hadSession { onSessionChange?(nil) }
        isStarting = false
        recomputeHealth()
    }

    private func terminateProcess() async {
        guard let proc = process, proc.isRunning else {
            process = nil
            isProcessRunning = false
            return
        }
        proc.terminate()  // SIGTERM
        if await waitForExit(seconds: 10) { return }
        kill(proc.processIdentifier, SIGKILL)
        _ = await waitForExit(seconds: 2)
    }

    private func waitForExit(seconds: Double) async -> Bool {
        if !isProcessRunning { return true }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run { self?.resumeExitWaiters() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in exitWaiters.append(c) }
        timeout.cancel()
        return !isProcessRunning
    }

    private func resumeExitWaiters() {
        let waiters = exitWaiters
        exitWaiters = []
        for w in waiters { w.resume() }
    }

    private func processExited(generation gen: Int, status: Int32, reason: Process.TerminationReason) {
        guard gen == generation else { return }
        isProcessRunning = false
        process = nil
        let tail = collector?.stderrTail ?? ""
        lastExit = reason == .uncaughtSignal
            ? StackExitInfo(code: nil, signal: status, stderrTail: tail)
            : StackExitInfo(code: status, signal: nil, stderrTail: tail)
        resumeExitWaiters()
        if let cont = startupContinuation {
            cont.yield(.exited)
            return
        }
        if stopping {
            lastExit = nil  // we asked it to stop: that's "stopped", not a crash
            return
        }
        // The stack died on its own.
        healthTask?.cancel()
        healthTask = nil
        let hadSession = session != nil
        session = nil
        if hadSession { onSessionChange?(nil) }
        Task { await self.afterCrash() }
    }

    private func afterCrash() async {
        await collector?.finishReading()
        if let collector, var exit = lastExit {
            exit.stderrTail = collector.stderrTail
            lastExit = exit
        }
        recomputeHealth()
        let now = Date()
        let willRestart = autoRestart && StackHealthLogic.shouldAutoRestart(restartTimes: restartTimes, now: now)
        if let exit = lastExit { onCrash?(exit, willRestart) }
        if willRestart {
            restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 600 } + [now]
            await start()
        }
    }

    // MARK: Health

    private func startHealthPolling() {
        healthTask?.cancel()
        let interval = options.healthPollInterval
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let fast = self?.health.phase == .downloading
                try? await Task.sleep(for: fast ? .seconds(2) : interval)
            }
        }
    }

    /// Reads the run image and runner state once and recomputes `health`.
    public func pollOnce() async {
        guard isProcessRunning, let client = makeAPIClient() else { return }
        async let image = try? client.get("/api/v1/system/vm-image", as: RootfsStatus.self, timeout: 3)
        async let runner = try? client.get("/api/v1/runner", as: RunnerStatus.self, timeout: 3)
        let (img, run) = await (image, runner)
        guard isProcessRunning, session != nil else { return }
        runImage = img
        runnerOnline = run?.online
        if let first = run?.runners?.first {
            runnerMaxSlots = first.maxConcurrent ?? 0
            runnerSlotLimit = first.slotLimit
        }
        recomputeHealth()
    }

    private func recomputeHealth() {
        let input = StackHealthInput(
            arch: Self.machineArchitecture(),
            darwinMajor: Self.darwinMajor(),
            starting: isStarting,
            processRunning: isProcessRunning && !isStarting,
            startError: startError,
            exit: isProcessRunning ? nil : lastExit,
            freeDiskBytes: StackHealthLogic.freeDiskBytes(at: dataDirectory),
            minFreeDiskGb: minFreeDiskGb,
            image: runImage,
            runnerOnline: runnerOnline
        )
        let next = StackHealthLogic.derive(input)
        if next != health { health = next }
    }

    // MARK: Platform

    static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func darwinMajor() -> Int? {
        var size = 0
        sysctlbyname("kern.osrelease", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osrelease", &buf, &size, nil, 0) == 0 else { return nil }
        return StackHealthLogic.darwinMajor(release: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    private func describeExit(_ exit: StackExitInfo?) -> String {
        guard let exit else { return "unknown" }
        if let code = exit.code { return "code \(code)" }
        if let signal = exit.signal { return "signal \(signal)" }
        return "unknown"
    }
}

// MARK: - Supporting types

enum StartupEvent: Sendable {
    case ready(String)
    case exited
    case timeout
}

struct StackStartError: Error {
    var text: String
    init(_ text: String) { self.text = text }
}

/// Appends lines to `<dataDir>/logs/vesper-app.log`.
final class StackLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}

/// Reads the child's stdout and stderr line by line: captures the sign-in code and the ready URL
/// (the code line is never logged) and logs everything else.
final class StackOutputCollector: @unchecked Sendable {
    static let codePrefix = "VESPER_SIGN_IN_CODE="
    static let readyPrefix = "VESPER_READY_URL="

    private let lock = NSLock()
    private let log: StackLogWriter
    private var code: String?
    private var tail = ""
    var onReady: (@Sendable (String) -> Void)?
    private var openReaders = 0

    init(log: StackLogWriter) { self.log = log }

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }

    func takeSignInCode() -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { code = nil }
        return code
    }

    /// Reads on a dedicated thread with blocking reads: `FileHandle.bytes` can hold lines back until the pipe closes.
    func startReading(_ handle: FileHandle, isStderr: Bool) {
        lock.lock()
        openReaders += 1
        lock.unlock()
        let thread = Thread { [self] in
            var pending = Data()
            while true {
                let chunk = handle.availableData  // blocks; empty at EOF
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    process(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self), isStderr: isStderr)
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            if !pending.isEmpty { process(String(decoding: pending, as: UTF8.self), isStderr: isStderr) }
            lock.lock()
            openReaders -= 1
            lock.unlock()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    private var readersOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return openReaders > 0
    }

    /// Waits (briefly) for the readers to drain after the process exits. A grandchild holding the
    /// pipe open must not hang us.
    func finishReading() async {
        for _ in 0..<50 where readersOpen { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func process(_ rawLine: String, isStderr: Bool) {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if !isStderr, line.hasPrefix(Self.codePrefix) {
            lock.lock()
            code = String(line.dropFirst(Self.codePrefix.count)).trimmingCharacters(in: .whitespaces)
            lock.unlock()
            return
        }
        log.append(line)
        if isStderr {
            lock.lock()
            tail = String((tail + line + "\n").suffix(4096))
            lock.unlock()
        } else if line.hasPrefix(Self.readyPrefix) {
            let url = String(line.dropFirst(Self.readyPrefix.count)).trimmingCharacters(in: .whitespaces)
            if url.hasPrefix("http://") { onReady?(url) }
        }
    }
}

/// Redeems the one-time sign-in code: GET <url>/api/v1/sign-in?code=… with redirects off, and takes
/// the `vesper_session` cookie from `Set-Cookie`.
public enum StackSignIn {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    public static func redeem(baseURL: URL, code: String, timeout: TimeInterval = 10) async throws -> String {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw StackStartError("Bad server URL.") }
        comps.path = "/api/v1/sign-in"
        comps.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = comps.url else { throw StackStartError("Bad sign-in URL.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) } catch {
            throw StackStartError("Sign-in request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw StackStartError("Sign-in answered with no HTTP response.") }
        guard (200..<400).contains(http.statusCode) else { throw StackStartError("Sign-in was refused (HTTP \(http.statusCode)).") }
        guard let token = sessionToken(from: http) else { throw StackStartError("Sign-in answered with no \(StackSession.cookieName) cookie.") }
        return token
    }

    /// The `vesper_session` value in a response's Set-Cookie header, if any.
    public static func sessionToken(from response: HTTPURLResponse) -> String? {
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
        let url = response.url ?? URL(string: "http://127.0.0.1")!
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first { $0.name == StackSession.cookieName }
            .map(\.value)
    }
}
