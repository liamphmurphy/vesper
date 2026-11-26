import Foundation
import Observation
import VesperCore
import WebKit

// MARK: - Filter List HTTP Fetcher (Injectable for Offline Tests)

struct BrowserFilterListFetchResponse: Sendable {
    var statusCode: Int
    var body: Data
    var etag: String?
    var lastModified: String?

    init(statusCode: Int, body: Data = Data(), etag: String? = nil, lastModified: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.etag = etag
        self.lastModified = lastModified
    }
}

typealias BrowserFilterListFetcher = @Sendable (URL, String?, String?) async throws -> BrowserFilterListFetchResponse

// MARK: - Multi-List WebKit Content Blocker & Phase B Scriptlet Engine

/// App-wide Wipr/uBlock-style Ad & Tracker Blocker engine shared across all Browser profiles.
///
/// Architecture:
/// - **Phase A (WebKit Native)**: Combines bundled offline starter lists + cached upstream
///   EasyList / EasyPrivacy / Peter Lowe / Fanboy Annoyances / uBlock Filters + custom user rules,
///   compiles them off the main thread via `BrowserAdBlockCompiler` into chunked `WKContentRuleList`s
///   (<150k rules each), and caches compiled WebKit bytecode by content hash so relaunches are instant.
/// - **Phase B (Page-World Runtime)**: Generates an `.atDocumentStart` `WKUserScript` in
///   `WKContentWorld.page` running uBO/AdGuard scriptlets, YouTube Ad Shield, `:style(...)` rules,
///   and procedural/extended CSS (`:has-text()`, `:upward()`, `:matches-css()`, `:remove()`).
/// - **Instant Per-Site Allowlisting**: Compiled rule lists are immutable across profiles; disabling
///   protection on a host simply detaches/reattaches the pre-compiled rule lists and user script on
///   tabs visiting that host in <1ms with zero recompilation.
@MainActor
@Observable
final class BrowserAdBlockEngine {
    nonisolated static let maxFilterListBytes = 25 * 1024 * 1024
    nonisolated static let autoUpdateInterval: TimeInterval = 24 * 60 * 60
    private static let identifierPrefix = "com.vesper.mac.browser.adblock.v2."

    private(set) var compiledRuleLists: [WKContentRuleList] = []
    private(set) var compiledPageScript: WKUserScript?
    private(set) var stats = BrowserAdBlockCompilationResult.Stats()
    private(set) var compiledChunkCount: Int = 0
    private(set) var isCompiling: Bool = false
    private(set) var isUpdating: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private let storageDir: URL
    @ObservationIgnored private let listsDir: URL
    @ObservationIgnored private let fetchMetaURL: URL
    @ObservationIgnored private let fetcher: BrowserFilterListFetcher
    @ObservationIgnored private var compileGeneration: Int = 0
    @ObservationIgnored private var lastCompilationSignature: String?
    @ObservationIgnored private var fetchMeta: [String: CachedFetchMeta] = [:]

    private struct CachedFetchMeta: Codable, Sendable {
        var etag: String?
        var lastModified: String?
    }

    init(
        dataDirectory: URL,
        fetcher: BrowserFilterListFetcher? = nil
    ) {
        self.storageDir = BrowserStorage.adBlockDirectory(dataDirectory: dataDirectory)
        self.listsDir = storageDir.appendingPathComponent("lists", isDirectory: true)
        self.fetchMetaURL = storageDir.appendingPathComponent("fetch-meta.json")
        self.fetcher = fetcher ?? Self.defaultFetcher
        self.fetchMeta = Self.loadFetchMeta(from: fetchMetaURL)
    }

    // MARK: - Compilation

    /// Compiles (or loads from WebKit's bytecode cache) all active category rule chunks and the
    /// Phase B page-world scriptlet/extended-CSS runtime.
    func recompile(enabled: Bool, config: BrowserAdBlockConfig, force: Bool = false) async {
        compileGeneration += 1
        let generation = compileGeneration

        guard enabled else {
            compiledRuleLists = []
            compiledPageScript = nil
            stats = .init()
            compiledChunkCount = 0
            lastCompilationSignature = nil
            lastError = nil
            isCompiling = false
            return
        }

        let sources = collectFilterSources(config: config)
        let includeAdvanced = config.isCategoryEnabled(.scriptlets)
            || config.isCategoryEnabled(.annoyances)
            || config.youtubeAdShieldEnabled
            || !config.customRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let signature = compilationSignature(
            sources: sources,
            youtubeShield: config.youtubeAdShieldEnabled,
            includeAdvanced: includeAdvanced
        )
        if !force, signature == lastCompilationSignature, !compiledRuleLists.isEmpty || compiledPageScript != nil {
            return
        }

        isCompiling = true
        lastError = nil

        let ytEnabled = config.youtubeAdShieldEnabled
        let compiled = await Task.detached(priority: .utility) {
            BrowserAdBlockCompiler.compile(
                sources: sources,
                youtubeAdShieldEnabled: ytEnabled
            )
        }.value

        guard generation == compileGeneration else { return }

        var lists: [WKContentRuleList] = []
        var activeIdentifiers = Set<String>()
        var compileErrors: [String] = []

        for chunk in compiled.chunks {
            let identifier = "\(Self.identifierPrefix)\(chunk.id).\(chunk.contentHash)"
            activeIdentifiers.insert(identifier)
            if let list = await loadOrCompileRuleList(identifier: identifier, json: chunk.json) {
                lists.append(list)
            } else {
                compileErrors.append("Chunk \(chunk.id) failed to compile")
            }
            guard generation == compileGeneration else { return }
        }

        // Prune obsolete cached identifiers so WebKit's rule-list store stays compact.
        await pruneStaleRuleLists(keeping: activeIdentifiers)
        guard generation == compileGeneration else { return }

        let effectiveAdvanced: BrowserAdvancedBlockingBundle
        if includeAdvanced {
            var bundle = compiled.advanced
            if !config.isCategoryEnabled(.scriptlets) {
                bundle.scriptlets = []
            }
            effectiveAdvanced = bundle
        } else {
            effectiveAdvanced = BrowserAdvancedBlockingBundle(youtubeAdShieldEnabled: false)
        }

        let script: WKUserScript?
        if let source = BrowserAdBlockScripts.makePageRuntimeSource(for: effectiveAdvanced) {
            script = WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page
            )
        } else {
            script = nil
        }

        compiledRuleLists = lists
        compiledPageScript = script
        stats = compiled.stats
        compiledChunkCount = lists.count
        lastCompilationSignature = signature
        lastError = compileErrors.isEmpty ? nil : compileErrors.joined(separator: "; ")
        isCompiling = false
    }

    // MARK: - Background Upstream Filter List Updater

    func needsAutoUpdate(config: BrowserAdBlockConfig, now: Date = Date()) -> Bool {
        guard config.autoUpdateEnabled else { return false }
        guard let last = config.lastUpdatedAt else { return true }
        return now.timeIntervalSince(last) >= Self.autoUpdateInterval
    }

    /// Downloads enabled upstream filter lists (EasyList, EasyPrivacy, Peter Lowe, Fanboy, uBlock,
    /// plus custom HTTPS subscriptions), caches them on disk, and returns updated subscription metadata.
    func updateFilterLists(
        config: BrowserAdBlockConfig,
        now: Date = Date()
    ) async -> (config: BrowserAdBlockConfig, updatedCount: Int, errorCount: Int) {
        guard !isUpdating else { return (config, 0, 0) }
        isUpdating = true
        defer { isUpdating = false }

        try? FileManager.default.createDirectory(at: listsDir, withIntermediateDirectories: true)

        var nextConfig = config
        let targets = config.subscriptions.filter { $0.isEnabled && config.isCategoryEnabled($0.category) }
        guard !targets.isEmpty else {
            return (nextConfig, 0, 0)
        }

        let fetcher = self.fetcher
        let existingMeta = self.fetchMeta

        struct FetchOutcome: Sendable {
            let id: String
            let text: String?
            let notModified: Bool
            let etag: String?
            let lastModified: String?
            let error: String?
        }

        let outcomes = await withTaskGroup(of: FetchOutcome.self) { group -> [FetchOutcome] in
            for sub in targets {
                let meta = existingMeta[sub.id]
                group.addTask {
                    guard let url = BrowserAdBlockConfig.validateSubscriptionURL(sub.url) else {
                        return FetchOutcome(id: sub.id, text: nil, notModified: false, etag: nil, lastModified: nil, error: "Invalid HTTPS URL")
                    }
                    do {
                        let resp = try await fetcher(url, meta?.etag, meta?.lastModified)
                        if resp.statusCode == 304 {
                            return FetchOutcome(id: sub.id, text: nil, notModified: true, etag: resp.etag ?? meta?.etag, lastModified: resp.lastModified ?? meta?.lastModified, error: nil)
                        }
                        guard (200..<300).contains(resp.statusCode) else {
                            return FetchOutcome(id: sub.id, text: nil, notModified: false, etag: nil, lastModified: nil, error: "HTTP \(resp.statusCode)")
                        }
                        guard resp.body.count <= BrowserAdBlockEngine.maxFilterListBytes else {
                            return FetchOutcome(id: sub.id, text: nil, notModified: false, etag: nil, lastModified: nil, error: "List exceeds 25 MB limit")
                        }
                        guard let text = String(data: resp.body, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return FetchOutcome(id: sub.id, text: nil, notModified: false, etag: nil, lastModified: nil, error: "Empty or non-UTF8 response")
                        }
                        return FetchOutcome(id: sub.id, text: text, notModified: false, etag: resp.etag, lastModified: resp.lastModified, error: nil)
                    } catch {
                        return FetchOutcome(id: sub.id, text: nil, notModified: false, etag: nil, lastModified: nil, error: error.localizedDescription)
                    }
                }
            }
            var collected: [FetchOutcome] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        var updatedCount = 0
        var errorCount = 0

        for outcome in outcomes {
            guard let idx = nextConfig.subscriptions.firstIndex(where: { $0.id == outcome.id }) else { continue }
            if let error = outcome.error {
                nextConfig.subscriptions[idx].lastError = error
                errorCount += 1
                continue
            }
            if outcome.notModified {
                nextConfig.subscriptions[idx].lastUpdatedAt = now
                nextConfig.subscriptions[idx].lastError = nil
                updatedCount += 1
                continue
            }
            if let text = outcome.text {
                let dest = cachedListFileURL(for: outcome.id)
                do {
                    try Data(text.utf8).write(to: dest, options: .atomic)
                    nextConfig.subscriptions[idx].lastUpdatedAt = now
                    nextConfig.subscriptions[idx].lastError = nil
                    nextConfig.subscriptions[idx].ruleCount = Self.countActiveLines(in: text)
                    fetchMeta[outcome.id] = CachedFetchMeta(etag: outcome.etag, lastModified: outcome.lastModified)
                    updatedCount += 1
                } catch {
                    nextConfig.subscriptions[idx].lastError = error.localizedDescription
                    errorCount += 1
                }
            }
        }

        if updatedCount > 0 {
            nextConfig.lastUpdatedAt = now
            saveFetchMeta()
        }

        return (nextConfig, updatedCount, errorCount)
    }

    /// Removes the on-disk cached list file for a deleted custom subscription.
    func deleteCachedList(for subscriptionID: String) {
        try? FileManager.default.removeItem(at: cachedListFileURL(for: subscriptionID))
        fetchMeta.removeValue(forKey: subscriptionID)
        saveFetchMeta()
    }

    // MARK: - Source Assembly & WebKit Store Caching

    private func collectFilterSources(config: BrowserAdBlockConfig) -> [BrowserAdBlockFilterSource] {
        var sources: [BrowserAdBlockFilterSource] = []

        for category in BrowserAdBlockCategory.allCases where config.isCategoryEnabled(category) {
            // 1. Offline bundled starter list (guarantees Wipr-grade baseline even offline / on first launch).
            let bundled = BrowserAdBlockBundle.bundledListText(for: category)
            if !bundled.isEmpty {
                sources.append(BrowserAdBlockFilterSource(category: category, text: bundled))
            }

            // 2. Cached upstream subscriptions belonging to this category.
            for sub in config.subscriptions where sub.isEnabled && sub.category == category {
                let file = cachedListFileURL(for: sub.id)
                if let cached = try? String(contentsOf: file, encoding: .utf8), !cached.isEmpty {
                    sources.append(BrowserAdBlockFilterSource(category: category, text: cached))
                }
            }
        }

        // 3. User custom rules (ABP/uBO network, cosmetic, extended CSS, or scriptlets).
        let custom = config.customRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            sources.append(BrowserAdBlockFilterSource(category: .ads, text: custom))
        }

        return sources
    }

    private func loadOrCompileRuleList(identifier: String, json: String) async -> WKContentRuleList? {
        let store = WKContentRuleListStore.default()
        if let existing = try? await store?.contentRuleList(forIdentifier: identifier) {
            return existing
        }
        do {
            return try await store?.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            )
        } catch {
            vlog("browser adblock chunk \(identifier) compile failed: \(error)")
            return nil
        }
    }

    private func pruneStaleRuleLists(keeping active: Set<String>) async {
        guard let store = WKContentRuleListStore.default() else { return }
        let available = await store.availableIdentifiers() ?? []
        for id in available where id.hasPrefix(Self.identifierPrefix) && !active.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    private func cachedListFileURL(for id: String) -> URL {
        let safe = id.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")) ? ch : "_"
        }
        return listsDir.appendingPathComponent("\(String(safe)).txt")
    }

    private func compilationSignature(
        sources: [BrowserAdBlockFilterSource],
        youtubeShield: Bool,
        includeAdvanced: Bool
    ) -> String {
        var combined = "\(youtubeShield)|\(includeAdvanced)"
        for src in sources {
            combined += "|\(src.category.rawValue):\(BrowserAdBlockCompiler.stableFNV1aHex(src.text))"
        }
        return BrowserAdBlockCompiler.stableFNV1aHex(combined)
    }

    private static func countActiveLines(in text: String) -> Int {
        var count = 0
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && !line.hasPrefix("!") && !line.hasPrefix("[") && !line.hasPrefix("# ") && line != "#" {
                count += 1
            }
        }
        return count
    }

    private static func loadFetchMeta(from url: URL) -> [String: CachedFetchMeta] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CachedFetchMeta].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveFetchMeta() {
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(fetchMeta) {
            try? data.write(to: fetchMetaURL, options: .atomic)
        }
    }

    private static let defaultFetcher: BrowserFilterListFetcher = { url, etag, lastModified in
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Vesper-AdBlock/1.0", forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified, !lastModified.isEmpty {
            req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        return BrowserFilterListFetchResponse(
            statusCode: http?.statusCode ?? 0,
            body: data,
            etag: http?.value(forHTTPHeaderField: "ETag"),
            lastModified: http?.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}
