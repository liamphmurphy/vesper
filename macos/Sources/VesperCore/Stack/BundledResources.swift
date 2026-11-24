import Foundation

/// The files `vesper app` needs, found under a resources directory (Contents/Resources of the
/// packaged app, or `macos/staged` in development).
public struct BundledResources: Sendable, Equatable {
    public var baseDir: URL
    public var vesperBin: URL
    public var postgresBinDir: URL
    public var kernelPath: URL?
    public var webDistDir: URL?
    /// `<base>/node/bin/node`, when bundled.
    public var nodeBin: URL?

    public init(baseDir: URL, vesperBin: URL, postgresBinDir: URL, kernelPath: URL? = nil, webDistDir: URL? = nil, nodeBin: URL? = nil) {
        self.baseDir = baseDir
        self.vesperBin = vesperBin
        self.postgresBinDir = postgresBinDir
        self.kernelPath = kernelPath
        self.webDistDir = webDistDir
        self.nodeBin = nodeBin
    }

    /// nil unless `bin/vesper` and `postgres/bin/postgres` exist (desktop/src/stack.ts `resolveBundledResources`).
    public static func resolve(baseDir: URL) -> BundledResources? {
        let fm = FileManager.default
        let vesper = baseDir.appendingPathComponent("bin/vesper")
        let postgres = baseDir.appendingPathComponent("postgres/bin/postgres")
        guard fm.fileExists(atPath: vesper.path), fm.fileExists(atPath: postgres.path) else { return nil }
        let kernel = baseDir.appendingPathComponent("images/vmlinux")
        let web = baseDir.appendingPathComponent("web")
        let node = baseDir.appendingPathComponent("node/bin/node")
        return BundledResources(
            baseDir: baseDir,
            vesperBin: vesper,
            postgresBinDir: baseDir.appendingPathComponent("postgres/bin"),
            kernelPath: fm.fileExists(atPath: kernel.path) ? kernel : nil,
            webDistDir: fm.fileExists(atPath: web.appendingPathComponent("index.html").path) ? web : nil,
            nodeBin: fm.isExecutableFile(atPath: node.path) ? node : nil
        )
    }

    /// Where the resources are: `VESPER_RESOURCES_DIR`, else the packaged app's Resources, else
    /// (not in a .app) `<repo>/macos/staged` found by walking up from the executable and the
    /// current directory.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) -> URL? {
        if let override = environment["VESPER_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if bundle.bundleURL.pathExtension == "app", let resources = bundle.resourceURL { return resources }
        let starts = [bundle.executableURL?.deletingLastPathComponent(), URL(fileURLWithPath: FileManager.default.currentDirectoryPath)].compactMap { $0 }
        for start in starts {
            var dir = start
            for _ in 0..<12 {
                let candidate = dir.appendingPathComponent("macos/staged", isDirectory: true)
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("bin/vesper").path) { return candidate }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    /// True when running from a .app bundle.
    public static func isPackaged(bundle: Bundle = .main) -> Bool { bundle.bundleURL.pathExtension == "app" }
}

/// The environment and arguments for `vesper app` (docs/dev/native-mac-app.md, "Shell ↔ Go").
public struct StackLaunch: Sendable {
    public var resources: BundledResources
    public var dataDirectory: URL
    public var secretsKey: String
    public var port: Int
    /// Node for the bundled Next server. In dev: VESPER_NODE_BIN or `node` on PATH.
    public var nodeBin: String?
    /// Where to download agent-base.erofs on first launch (packaged builds). VESPER_ROOTFS_URL in the environment wins.
    public var rootfsUrl: String?
    /// Runs the local runner executes at once (RUNNER_MAX_CONCURRENT). The variable in the environment wins.
    public var runnerSlots: Int?
    /// PEM or DER files of roots agent VMs trust, for a TLS-inspecting proxy (RUNNER_EXTRA_CA_FILE). The variable in the environment wins.
    public var extraCaFiles: [String]

    public init(
        resources: BundledResources, dataDirectory: URL, secretsKey: String, port: Int = 8080, nodeBin: String? = nil,
        rootfsUrl: String? = nil, runnerSlots: Int? = nil, extraCaFiles: [String] = []
    ) {
        self.resources = resources
        self.dataDirectory = dataDirectory
        self.secretsKey = secretsKey
        self.port = port
        self.nodeBin = nodeBin
        self.rootfsUrl = rootfsUrl
        self.runnerSlots = runnerSlots
        self.extraCaFiles = extraCaFiles
    }

    public var address: String { "127.0.0.1:\(port)" }

    public var arguments: [String] { ["app", "-data-dir", dataDirectory.path, "-addr", address] }

    /// The environment `vesper app` runs with: inherit, then set ours; never VESPER_NO_SIGNIN or VESPER_NODE_RUN_AS_NODE.
    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["SECRETS_KEY"] = secretsKey
        env["VESPER_APP_DATA_DIR"] = dataDirectory.path
        env["VESPER_APP_ADDR"] = address
        env["VESPER_POSTGRES_BIN_DIR"] = resources.postgresBinDir.path
        if let kernel = resources.kernelPath { env["VESPER_KERNEL_PATH"] = kernel.path }
        if let web = resources.webDistDir { env["VESPER_WEB_DIST_DIR"] = web.path }
        if let node = nodeBin, !node.isEmpty { env["VESPER_NODE_BIN"] = node }
        if let url = rootfsUrl, base["VESPER_ROOTFS_URL"]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            env["VESPER_ROOTFS_URL"] = url
        }
        if let slots = runnerSlots, slots > 0, base["RUNNER_MAX_CONCURRENT"]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            env["RUNNER_MAX_CONCURRENT"] = String(slots)
        }
        let caPaths = extraCaFiles.filter { !$0.isEmpty }
        if !caPaths.isEmpty, base["RUNNER_EXTRA_CA_FILE"]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            env["RUNNER_EXTRA_CA_FILE"] = caPaths.joined(separator: ":")
        }
        env["VESPER_APP_SIGN_IN_CODE"] = "stdout"
        env.removeValue(forKey: "VESPER_NO_SIGNIN")
        env.removeValue(forKey: "VESPER_NODE_RUN_AS_NODE")
        return env
    }

    /// The Node binary to hand to the Go server: the bundled one, else VESPER_NODE_BIN, else `node` on PATH.
    public static func resolveNode(resources: BundledResources, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let bundled = resources.nodeBin { return bundled.path }
        if let own = environment["VESPER_NODE_BIN"]?.trimmingCharacters(in: .whitespaces), !own.isEmpty { return own }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/node"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
