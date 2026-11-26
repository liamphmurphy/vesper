import Foundation

// MARK: - Compiled Output Models

/// A single chunk of WebKit `WKContentRuleList` JSON guaranteed to stay under WebKit's 150,000-rule limit.
public struct BrowserCompiledRuleChunk: Sendable, Equatable {
    public let id: String
    public let category: BrowserAdBlockCategory
    public let kind: Kind
    public let ruleCount: Int
    public let json: String
    public let contentHash: String

    public enum Kind: String, Sendable, Equatable {
        case network
        case cosmetic
    }

    public init(
        id: String,
        category: BrowserAdBlockCategory,
        kind: Kind,
        ruleCount: Int,
        json: String,
        contentHash: String
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.ruleCount = ruleCount
        self.json = json
        self.contentHash = contentHash
    }
}

/// A parsed uBO (`##+js(...)`) or AdGuard (`#%#//scriptlet(...)`) scriptlet directive.
public struct BrowserScriptletRule: Codable, Sendable, Equatable {
    public let name: String
    public let args: [String]
    public let includeDomains: [String]
    public let excludeDomains: [String]

    public init(name: String, args: [String], includeDomains: [String] = [], excludeDomains: [String] = []) {
        self.name = name
        self.args = args
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
    }
}

/// A parsed extended/procedural cosmetic rule (e.g. `:has-text()`, `:upward()`, `:matches-css()`, `:remove()`).
public struct BrowserExtendedCSSRule: Codable, Sendable, Equatable {
    public let selector: String
    public let includeDomains: [String]
    public let excludeDomains: [String]
    public let removeNode: Bool

    public init(
        selector: String,
        includeDomains: [String] = [],
        excludeDomains: [String] = [],
        removeNode: Bool = false
    ) {
        self.selector = selector
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.removeNode = removeNode
    }
}

/// A CSS style injection rule (e.g. `##body.modal-open:style(overflow: auto !important;)`).
public struct BrowserInjectedStyleRule: Codable, Sendable, Equatable {
    public let selector: String
    public let cssBody: String
    public let includeDomains: [String]
    public let excludeDomains: [String]

    public init(
        selector: String,
        cssBody: String,
        includeDomains: [String] = [],
        excludeDomains: [String] = []
    ) {
        self.selector = selector
        self.cssBody = cssBody
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
    }
}

/// Phase B advanced rules executed by the `.atDocumentStart` page-world runtime.
public struct BrowserAdvancedBlockingBundle: Codable, Sendable, Equatable {
    public var scriptlets: [BrowserScriptletRule]
    public var extendedCSS: [BrowserExtendedCSSRule]
    public var injectedStyles: [BrowserInjectedStyleRule]
    public var cosmeticExceptionDomains: [String]
    public var youtubeAdShieldEnabled: Bool

    public init(
        scriptlets: [BrowserScriptletRule] = [],
        extendedCSS: [BrowserExtendedCSSRule] = [],
        injectedStyles: [BrowserInjectedStyleRule] = [],
        cosmeticExceptionDomains: [String] = [],
        youtubeAdShieldEnabled: Bool = true
    ) {
        self.scriptlets = scriptlets
        self.extendedCSS = extendedCSS
        self.injectedStyles = injectedStyles
        self.cosmeticExceptionDomains = cosmeticExceptionDomains
        self.youtubeAdShieldEnabled = youtubeAdShieldEnabled
    }

    public var isEmpty: Bool {
        scriptlets.isEmpty && extendedCSS.isEmpty && injectedStyles.isEmpty && !youtubeAdShieldEnabled
    }
}

/// Full compilation artifact across one or more filter lists.
public struct BrowserAdBlockCompilationResult: Sendable, Equatable {
    public var chunks: [BrowserCompiledRuleChunk]
    public var advanced: BrowserAdvancedBlockingBundle
    public var stats: Stats

    public struct Stats: Sendable, Equatable {
        public var networkBlockRules: Int = 0
        public var networkExceptionRules: Int = 0
        public var cosmeticRules: Int = 0
        public var scriptletRules: Int = 0
        public var extendedCSSRules: Int = 0
        public var injectedStyleRules: Int = 0
        public var skippedRules: Int = 0

        public var totalActiveRules: Int {
            networkBlockRules + networkExceptionRules + cosmeticRules + scriptletRules + extendedCSSRules + injectedStyleRules
        }

        public init(
            networkBlockRules: Int = 0,
            networkExceptionRules: Int = 0,
            cosmeticRules: Int = 0,
            scriptletRules: Int = 0,
            extendedCSSRules: Int = 0,
            injectedStyleRules: Int = 0,
            skippedRules: Int = 0
        ) {
            self.networkBlockRules = networkBlockRules
            self.networkExceptionRules = networkExceptionRules
            self.cosmeticRules = cosmeticRules
            self.scriptletRules = scriptletRules
            self.extendedCSSRules = extendedCSSRules
            self.injectedStyleRules = injectedStyleRules
            self.skippedRules = skippedRules
        }
    }

    public init(chunks: [BrowserCompiledRuleChunk], advanced: BrowserAdvancedBlockingBundle, stats: Stats) {
        self.chunks = chunks
        self.advanced = advanced
        self.stats = stats
    }
}

/// Input filter source passed into `BrowserAdBlockCompiler`.
public struct BrowserAdBlockFilterSource: Sendable {
    public let category: BrowserAdBlockCategory
    public let text: String

    public init(category: BrowserAdBlockCategory, text: String) {
        self.category = category
        self.text = text
    }
}

// MARK: - ABP / uBO / Hosts -> WebKit Content Blocker & Advanced Rules Compiler

/// Compiles Adblock Plus, uBlock Origin, AdGuard, and Hosts-file filter lists into:
/// 1. Chunked WebKit `WKContentRuleList` JSON payloads (staying safely under WebKit's 150,000-rule limit
///    and rejecting any regex/selector syntax WebKit's strict DFA compiler would fail on).
/// 2. Phase B advanced rules (scriptlets, procedural/extended CSS, and `:style(...)` injections).
public enum BrowserAdBlockCompiler {
    /// Stay comfortably below WebKit's hard 150,000-rule limit per `WKContentRuleList`.
    public static let defaultMaxRulesPerChunk = 120_000
    /// Batch pure generic cosmetic selectors into comma-separated CSS rules to stay fast and compact.
    public static let genericCosmeticBatchSize = 40

    private static let unsupportedNetworkOptionPrefixes: [String] = [
        "csp=", "redirect=", "redirect-rule=", "removeparam=", "replace=",
        "denyallow=", "header=", "permissions=", "uritransform=", "rewrite=",
        "app=", "method=", "to=", "from=", "ipaddress=", "reason=", "urlskip=",
    ]

    private static let extendedCSSMarkers: [String] = [
        ":has-text(", ":-abp-contains(", ":-abp-has(", ":upward(", ":matches-css(",
        ":matches-css-before(", ":matches-css-after(", ":matches-path(", ":matches-attr(",
        ":matches-prop(", ":xpath(", ":remove(", ":remove-attr(", ":remove-class(",
        ":style(", ":contains(", ":if(", ":if-not(", ":watch-attr(", ":min-text-length(",
        ":others(", ":nth-ancestor(", ":shadow(",
    ]

    /// Compiles multiple categorized filter sources into WebKit rule chunks and an advanced blocking bundle.
    public static func compile(
        sources: [BrowserAdBlockFilterSource],
        youtubeAdShieldEnabled: Bool = true,
        maxRulesPerChunk: Int = defaultMaxRulesPerChunk
    ) -> BrowserAdBlockCompilationResult {
        let clampedChunkLimit = max(50, min(145_000, maxRulesPerChunk))

        // Group raw lines by category while tracking global `$badfilter` cancellations first.
        var badFilterPatterns = Set<String>()
        var linesByCategory: [BrowserAdBlockCategory: [String]] = [:]

        for source in sources {
            var bucket = linesByCategory[source.category] ?? []
            source.text.enumerateLines { rawLine, _ in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return }
                if line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("# ") || line == "#" {
                    return
                }
                if line.contains("$"), let badKey = extractBadFilterKey(from: line) {
                    badFilterPatterns.insert(badKey)
                    return
                }
                bucket.append(line)
            }
            linesByCategory[source.category] = bucket
        }

        var allChunks: [BrowserCompiledRuleChunk] = []
        var allScriptlets: [BrowserScriptletRule] = []
        var scriptletExceptions: [ScriptletException] = []
        var allExtendedCSS: [BrowserExtendedCSSRule] = []
        var allInjectedStyles: [BrowserInjectedStyleRule] = []
        var cosmeticExceptionDomains = Set<String>()
        var stats = BrowserAdBlockCompilationResult.Stats()

        for category in BrowserAdBlockCategory.allCases {
            guard let lines = linesByCategory[category], !lines.isEmpty else { continue }
            var networkBlocks: [WebKitRule] = []
            var networkExceptions: [WebKitRule] = []
            var importantBlocks: [WebKitRule] = []

            var genericCosmeticSelectors: [String] = []
            var genericCosmeticSeen = Set<String>()
            var domainCosmeticRules: [CosmeticRule] = []
            var genericCosmeticExceptions = Set<String>()
            var domainCosmeticExceptions: [String: Set<String>] = [:] // selector -> excluded domains

            var networkRuleDedup = Set<String>()

            for line in lines {
                // 1. AdGuard scriptlets: `domains#%#//scriptlet('name', 'arg1')` / `#@%#`
                if let adguardScriptlet = parseAdGuardScriptlet(line) {
                    if adguardScriptlet.isException {
                        scriptletExceptions.append(ScriptletException(
                            name: adguardScriptlet.rule.name,
                            args: adguardScriptlet.rule.args,
                            domains: adguardScriptlet.rule.includeDomains
                        ))
                    } else {
                        allScriptlets.append(adguardScriptlet.rule)
                        stats.scriptletRules += 1
                    }
                    continue
                }

                // 2. Cosmetic / Extended CSS / uBO scriptlets (`##`, `#@#`, `#?#`, `#@?#`)
                if let cosmeticOp = findCosmeticOperator(in: line) {
                    let domainPart = String(line[..<cosmeticOp.range.lowerBound])
                    let body = String(line[cosmeticOp.range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    guard !body.isEmpty else {
                        stats.skippedRules += 1
                        continue
                    }

                    let parsedDomains = parseDomainList(domainPart, separator: ",")
                    if parsedDomains.hasInvalidDomain {
                        stats.skippedRules += 1
                        continue
                    }

                    // uBO scriptlet: `##+js(...)` or `#@#+js(...)`
                    if body.hasPrefix("+js(") && body.hasSuffix(")") {
                        let inner = String(body.dropFirst(4).dropLast())
                        if let rule = parseUBOScriptletBody(
                            inner,
                            includeDomains: parsedDomains.include,
                            excludeDomains: parsedDomains.exclude
                        ) {
                            if cosmeticOp.isException {
                                scriptletExceptions.append(ScriptletException(
                                    name: rule.name,
                                    args: rule.args,
                                    domains: rule.includeDomains
                                ))
                            } else {
                                allScriptlets.append(rule)
                                stats.scriptletRules += 1
                            }
                        } else {
                            stats.skippedRules += 1
                        }
                        continue
                    }

                    // Skip HTML response filters (`##^...`) which WebKit cannot execute natively.
                    if body.hasPrefix("^") {
                        stats.skippedRules += 1
                        continue
                    }

                    // Style injection rule: `selector:style(css)`
                    if let styleRule = parseStyleInjectionRule(
                        body: body,
                        includeDomains: parsedDomains.include,
                        excludeDomains: parsedDomains.exclude
                    ) {
                        if !cosmeticOp.isException {
                            allInjectedStyles.append(styleRule)
                            stats.injectedStyleRules += 1
                        }
                        continue
                    }

                    // Extended / procedural CSS (`#?#` or contains `:has-text(`, `:upward(`, `:remove()`, etc.)
                    if cosmeticOp.isExtended || isExtendedCSSSelector(body) {
                        if !cosmeticOp.isException {
                            let removeNode = body.hasSuffix(":remove()")
                            let cleaned = removeNode ? String(body.dropLast(":remove()".count)) : body
                            if !cleaned.isEmpty {
                                allExtendedCSS.append(BrowserExtendedCSSRule(
                                    selector: cleaned,
                                    includeDomains: parsedDomains.include,
                                    excludeDomains: parsedDomains.exclude,
                                    removeNode: removeNode
                                ))
                                stats.extendedCSSRules += 1
                            } else {
                                stats.skippedRules += 1
                            }
                        }
                        continue
                    }

                    // Standard CSS hiding rule (`##selector` / `#@#selector`)
                    guard isValidStandardCSSSelector(body) else {
                        stats.skippedRules += 1
                        continue
                    }

                    if cosmeticOp.isException {
                        if parsedDomains.include.isEmpty && parsedDomains.exclude.isEmpty {
                            genericCosmeticExceptions.insert(body)
                        } else {
                            for d in parsedDomains.include {
                                domainCosmeticExceptions[body, default: []].insert(d)
                            }
                        }
                    } else if parsedDomains.include.isEmpty && parsedDomains.exclude.isEmpty {
                        if genericCosmeticSeen.insert(body).inserted {
                            genericCosmeticSelectors.append(body)
                        }
                    } else {
                        domainCosmeticRules.append(CosmeticRule(
                            selector: body,
                            includeDomains: parsedDomains.include,
                            excludeDomains: parsedDomains.exclude
                        ))
                    }
                    continue
                }

                // Skip AdGuard CSS injection `#$$`, `#$#`, `#%#` (non-scriptlet arbitrary JS is intentionally blocked for security).
                if line.contains("#%#") || line.contains("#@%#") || line.contains("#$#") || line.contains("#@$#") || line.contains("$$") {
                    stats.skippedRules += 1
                    continue
                }

                // 3. Hosts-file entry (`0.0.0.0 tracker.example.com` or `127.0.0.1 ads.example.com`)
                switch parseHostsFileLine(line) {
                case .block(let hostRule):
                    let dedupKey = "host:\(hostRule.urlFilter)"
                    if !badFilterPatterns.contains(dedupKey), networkRuleDedup.insert(dedupKey).inserted {
                        networkBlocks.append(hostRule)
                        stats.networkBlockRules += 1
                    }
                    continue
                case .ignored:
                    stats.skippedRules += 1
                    continue
                case .notHosts:
                    break
                }

                // 4. Standard ABP/uBO network rule
                switch parseNetworkLine(line, badFilters: badFilterPatterns) {
                case .block(let rule, let important):
                    let dedupKey = rule.dedupKey
                    if networkRuleDedup.insert(dedupKey).inserted {
                        if important {
                            importantBlocks.append(rule)
                        } else {
                            networkBlocks.append(rule)
                        }
                        stats.networkBlockRules += 1
                    }
                case .exception(let rule, let cosmeticAllowDomains):
                    for d in cosmeticAllowDomains {
                        cosmeticExceptionDomains.insert(d)
                    }
                    if let rule {
                        let dedupKey = rule.dedupKey
                        if networkRuleDedup.insert(dedupKey).inserted {
                            networkExceptions.append(rule)
                            stats.networkExceptionRules += 1
                        }
                    }
                case .skipped:
                    stats.skippedRules += 1
                }
            }

            // Build network chunks for this category.
            // Because WebKit evaluates `ignore-previous-rules` strictly within the same `WKContentRuleList`,
            // we keep exceptions + `$important` rules attached to each network block chunk.
            let networkChunks = buildNetworkChunks(
                category: category,
                blocks: networkBlocks,
                exceptions: networkExceptions,
                importantBlocks: importantBlocks,
                maxRulesPerChunk: clampedChunkLimit
            )
            allChunks.append(contentsOf: networkChunks)

            // Resolve cosmetic exceptions and build cosmetic chunks for this category.
            var resolvedCosmeticRules: [WebKitRule] = []
            var pureGenericSelectors: [String] = []

            for selector in genericCosmeticSelectors {
                if genericCosmeticExceptions.contains(selector) { continue }
                if let excluded = domainCosmeticExceptions[selector], !excluded.isEmpty {
                    let unlessDomains = excluded.sorted().map { "*\($0)" }
                    resolvedCosmeticRules.append(WebKitRule(
                        urlFilter: ".*",
                        unlessDomain: unlessDomains,
                        actionType: .cssDisplayNone(selector: selector)
                    ))
                    stats.cosmeticRules += 1
                } else {
                    pureGenericSelectors.append(selector)
                }
            }

            // Batch pure generic selectors into compact comma-separated CSS rules.
            if !pureGenericSelectors.isEmpty {
                var idx = 0
                while idx < pureGenericSelectors.count {
                    let end = min(idx + genericCosmeticBatchSize, pureGenericSelectors.count)
                    let batch = pureGenericSelectors[idx..<end].joined(separator: ", ")
                    resolvedCosmeticRules.append(WebKitRule(
                        urlFilter: ".*",
                        actionType: .cssDisplayNone(selector: batch)
                    ))
                    stats.cosmeticRules += (end - idx)
                    idx = end
                }
            }

            // Domain-scoped cosmetic rules.
            var seenDomainCosmetic = Set<String>()
            for rule in domainCosmeticRules {
                if genericCosmeticExceptions.contains(rule.selector) { continue }
                let exceptionSet = domainCosmeticExceptions[rule.selector] ?? []
                let filteredInclude = rule.includeDomains.filter { !exceptionSet.contains($0) }
                let mergedExclude = Set(rule.excludeDomains).union(exceptionSet)

                // WebKit forbids both if-domain and unless-domain on the same trigger.
                if !filteredInclude.isEmpty && mergedExclude.isEmpty {
                    let domains = filteredInclude.sorted().map { "*\($0)" }
                    let key = "if:\(domains.joined(separator: ","))##\(rule.selector)"
                    if seenDomainCosmetic.insert(key).inserted {
                        resolvedCosmeticRules.append(WebKitRule(
                            urlFilter: ".*",
                            ifDomain: domains,
                            actionType: .cssDisplayNone(selector: rule.selector)
                        ))
                        stats.cosmeticRules += 1
                    }
                } else if filteredInclude.isEmpty && !mergedExclude.isEmpty && rule.includeDomains.isEmpty {
                    let domains = mergedExclude.sorted().map { "*\($0)" }
                    let key = "un:\(domains.joined(separator: ","))##\(rule.selector)"
                    if seenDomainCosmetic.insert(key).inserted {
                        resolvedCosmeticRules.append(WebKitRule(
                            urlFilter: ".*",
                            unlessDomain: domains,
                            actionType: .cssDisplayNone(selector: rule.selector)
                        ))
                        stats.cosmeticRules += 1
                    }
                } else if !filteredInclude.isEmpty {
                    // Mixed include + exclude domains: route to advanced cosmetic bundle so exclusions are exact.
                    allExtendedCSS.append(BrowserExtendedCSSRule(
                        selector: rule.selector,
                        includeDomains: filteredInclude.sorted(),
                        excludeDomains: mergedExclude.sorted(),
                        removeNode: false
                    ))
                    stats.extendedCSSRules += 1
                }
            }

            let cosmeticChunks = buildCosmeticChunks(
                category: category,
                rules: resolvedCosmeticRules,
                maxRulesPerChunk: clampedChunkLimit
            )
            allChunks.append(contentsOf: cosmeticChunks)
        }

        // Apply scriptlet exceptions (`#@#+js(...)`).
        let finalScriptlets = applyScriptletExceptions(allScriptlets, exceptions: scriptletExceptions)
        stats.scriptletRules = finalScriptlets.count

        let advanced = BrowserAdvancedBlockingBundle(
            scriptlets: deduplicateScriptlets(finalScriptlets),
            extendedCSS: deduplicateExtendedCSS(allExtendedCSS),
            injectedStyles: deduplicateInjectedStyles(allInjectedStyles),
            cosmeticExceptionDomains: cosmeticExceptionDomains.sorted(),
            youtubeAdShieldEnabled: youtubeAdShieldEnabled
        )

        return BrowserAdBlockCompilationResult(chunks: allChunks, advanced: advanced, stats: stats)
    }

    // MARK: - Internal Rule Structs

    private enum WebKitAction: Equatable {
        case block
        case ignorePreviousRules
        case cssDisplayNone(selector: String)
    }

    private struct WebKitRule: Equatable {
        var urlFilter: String
        var isCaseSensitive: Bool = false
        var loadType: [String]? = nil
        var resourceType: [String]? = nil
        var ifDomain: [String]? = nil
        var unlessDomain: [String]? = nil
        var actionType: WebKitAction

        var dedupKey: String {
            "\(urlFilter)|\(isCaseSensitive)|\(loadType?.joined(separator: ",") ?? "")|\(resourceType?.joined(separator: ",") ?? "")|\(ifDomain?.joined(separator: ",") ?? "")|\(unlessDomain?.joined(separator: ",") ?? "")|\(actionType)"
        }

        func toJSONDictionary() -> [String: Any] {
            var trigger: [String: Any] = ["url-filter": urlFilter]
            if isCaseSensitive {
                trigger["url-filter-is-case-sensitive"] = true
            }
            if let loadType, !loadType.isEmpty {
                trigger["load-type"] = loadType
            }
            if let resourceType, !resourceType.isEmpty {
                trigger["resource-type"] = resourceType
            }
            if let ifDomain, !ifDomain.isEmpty {
                trigger["if-domain"] = ifDomain
            } else if let unlessDomain, !unlessDomain.isEmpty {
                trigger["unless-domain"] = unlessDomain
            }

            let action: [String: Any]
            switch actionType {
            case .block:
                action = ["type": "block"]
            case .ignorePreviousRules:
                action = ["type": "ignore-previous-rules"]
            case .cssDisplayNone(let selector):
                action = ["type": "css-display-none", "selector": selector]
            }
            return ["trigger": trigger, "action": action]
        }
    }

    private struct CosmeticRule {
        let selector: String
        let includeDomains: [String]
        let excludeDomains: [String]
    }

    private struct ScriptletException {
        let name: String
        let args: [String]
        let domains: [String]
    }

    private enum NetworkParseResult {
        case block(WebKitRule, important: Bool)
        case exception(WebKitRule?, cosmeticAllowDomains: [String])
        case skipped
    }

    // MARK: - Chunk Builders

    private static func buildNetworkChunks(
        category: BrowserAdBlockCategory,
        blocks: [WebKitRule],
        exceptions: [WebKitRule],
        importantBlocks: [WebKitRule],
        maxRulesPerChunk: Int
    ) -> [BrowserCompiledRuleChunk] {
        guard !blocks.isEmpty || !importantBlocks.isEmpty else { return [] }

        let tailRules = exceptions + importantBlocks
        // Ensure at least half the chunk budget goes to block rules; cap exceptions if an extreme list exceeds budget.
        let maxTail = max(0, maxRulesPerChunk / 3)
        let boundedTail = tailRules.count > maxTail ? Array(tailRules.prefix(maxTail)) : tailRules
        let blockCapacity = max(1, maxRulesPerChunk - boundedTail.count)

        var chunks: [BrowserCompiledRuleChunk] = []
        if blocks.isEmpty {
            if let chunk = encodeChunk(
                id: "\(category.rawValue)-net-0",
                category: category,
                kind: .network,
                rules: importantBlocks
            ) {
                chunks.append(chunk)
            }
            return chunks
        }

        var idx = 0
        var chunkIndex = 0
        while idx < blocks.count {
            let end = min(idx + blockCapacity, blocks.count)
            let slice = Array(blocks[idx..<end]) + boundedTail
            if let chunk = encodeChunk(
                id: "\(category.rawValue)-net-\(chunkIndex)",
                category: category,
                kind: .network,
                rules: slice
            ) {
                chunks.append(chunk)
            }
            idx = end
            chunkIndex += 1
        }
        return chunks
    }

    private static func buildCosmeticChunks(
        category: BrowserAdBlockCategory,
        rules: [WebKitRule],
        maxRulesPerChunk: Int
    ) -> [BrowserCompiledRuleChunk] {
        guard !rules.isEmpty else { return [] }
        var chunks: [BrowserCompiledRuleChunk] = []
        var idx = 0
        var chunkIndex = 0
        while idx < rules.count {
            let end = min(idx + maxRulesPerChunk, rules.count)
            let slice = Array(rules[idx..<end])
            if let chunk = encodeChunk(
                id: "\(category.rawValue)-cos-\(chunkIndex)",
                category: category,
                kind: .cosmetic,
                rules: slice
            ) {
                chunks.append(chunk)
            }
            idx = end
            chunkIndex += 1
        }
        return chunks
    }

    private static func encodeChunk(
        id: String,
        category: BrowserAdBlockCategory,
        kind: BrowserCompiledRuleChunk.Kind,
        rules: [WebKitRule]
    ) -> BrowserCompiledRuleChunk? {
        guard !rules.isEmpty else { return nil }
        let array = rules.map { $0.toJSONDictionary() }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: []),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return BrowserCompiledRuleChunk(
            id: id,
            category: category,
            kind: kind,
            ruleCount: rules.count,
            json: json,
            contentHash: stableFNV1aHex(json)
        )
    }

    // MARK: - Network Rule Parsing

    private static func extractBadFilterKey(from line: String) -> String? {
        guard let dollarIdx = line.lastIndex(of: "$") else { return nil }
        let optionsPart = line[line.index(after: dollarIdx)...]
        let opts = optionsPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard opts.contains("badfilter") else { return nil }
        let pattern = String(line[..<dollarIdx])
        let remainingOpts = opts.filter { $0 != "badfilter" }.sorted().joined(separator: ",")
        return "\(pattern)$\(remainingOpts)"
    }

    private enum HostsParseResult {
        case block(WebKitRule)
        case ignored
        case notHosts
    }

    private static func parseHostsFileLine(_ line: String) -> HostsParseResult {
        let stripped = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? line
        let parts = stripped.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return .notHosts }
        let ip = String(parts[0])
        guard ip == "0.0.0.0" || ip == "127.0.0.1" || ip == "::" || ip == "::1" else { return .notHosts }
        guard parts.count == 2, let host = normalizeASCIIHost(String(parts[1])) else { return .ignored }
        guard host != "localhost" && host != "localhost.localdomain" && host != "local" && host != "broadcasthost" && host != "0.0.0.0" else {
            return .ignored
        }
        let escaped = escapeForWebKitRegex(host)
        let filter = "^https?://+([^:/]+\\.)?\(escaped)[^a-zA-Z0-9._%-]"
        guard isValidWebKitURLFilter(filter) else { return .ignored }
        return .block(WebKitRule(urlFilter: filter, actionType: .block))
    }

    private static func parseNetworkLine(_ line: String, badFilters: Set<String>) -> NetworkParseResult {
        guard !line.contains(where: \.isWhitespace) else { return .skipped }
        var working = line
        var isException = false
        if working.hasPrefix("@@") {
            isException = true
            working = String(working.dropFirst(2))
        }
        guard !working.isEmpty else { return .skipped }

        // Split pattern and `$options` (ignore `$` inside raw `/regex/`).
        var pattern = working
        var rawOptions: [String] = []
        if !working.hasPrefix("/"), let dollarIdx = working.lastIndex(of: "$") {
            let candidateOptions = String(working[working.index(after: dollarIdx)...])
            if !candidateOptions.isEmpty && !candidateOptions.contains("/") {
                pattern = String(working[..<dollarIdx])
                rawOptions = candidateOptions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }

        // Check `$badfilter` cancellation.
        let normalizedOptKey = rawOptions.map { $0.lowercased() }.sorted().joined(separator: ",")
        let ruleKey = "\(isException ? "@@" : "")\(pattern)$\(normalizedOptKey)"
        if badFilters.contains(ruleKey) { return .skipped }

        var isCaseSensitive = false
        var isImportant = false
        var loadType: [String]? = nil
        var includeResources = Set<String>()
        var excludeResources = Set<String>()
        var includeDomains: [String] = []
        var excludeDomains: [String] = []
        var isCosmeticExceptionOnly = false
        var isDocumentException = false

        for opt in rawOptions {
            let lower = opt.lowercased()
            if lower.isEmpty || lower == "all" { continue }
            if unsupportedNetworkOptionPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return .skipped
            }
            if lower == "match-case" {
                isCaseSensitive = true
                continue
            }
            if lower == "important" {
                isImportant = true
                continue
            }
            if lower == "third-party" || lower == "3p" {
                loadType = ["third-party"]
                continue
            }
            if lower == "~third-party" || lower == "first-party" || lower == "1p" {
                loadType = ["first-party"]
                continue
            }
            if lower == "elemhide" || lower == "ehide" || lower == "generichide" || lower == "ghide" || lower == "specifichide" || lower == "shide" {
                if isException { isCosmeticExceptionOnly = true; continue }
                return .skipped
            }
            if lower == "document" || lower == "doc" {
                if isException {
                    isDocumentException = true
                    continue
                }
                includeResources.insert("document")
                continue
            }
            if lower.hasPrefix("domain=") {
                let domStr = String(opt.dropFirst("domain=".count))
                let parsed = parseDomainList(domStr, separator: "|")
                if parsed.hasInvalidDomain { return .skipped }
                includeDomains = parsed.include
                excludeDomains = parsed.exclude
                continue
            }

            // Map ABP/uBO resource type options to WebKit resource types.
            let negated = lower.hasPrefix("~")
            let name = negated ? String(lower.dropFirst()) : lower
            if let mapped = mapResourceType(name) {
                for t in mapped {
                    if negated { excludeResources.insert(t) } else { includeResources.insert(t) }
                }
            } else {
                // Unknown option: bail safely rather than over-blocking.
                return .skipped
            }
        }

        // Document / elemhide allowlist extraction (`@@||example.com^$document` or `$elemhide`).
        var cosmeticAllowDomains: [String] = []
        if isException && (isCosmeticExceptionOnly || isDocumentException) {
            if let anchoredHost = extractAnchoredDomain(from: pattern) {
                cosmeticAllowDomains.append(anchoredHost)
            }
            cosmeticAllowDomains.append(contentsOf: includeDomains)
            if isCosmeticExceptionOnly && !isDocumentException {
                return .exception(nil, cosmeticAllowDomains: cosmeticAllowDomains)
            }
        }

        // WebKit forbids BOTH `if-domain` and `unless-domain` in the same trigger.
        if !includeDomains.isEmpty && !excludeDomains.isEmpty {
            return .skipped
        }

        let resolvedResources: [String]?
        if !includeResources.isEmpty {
            resolvedResources = includeResources.subtracting(excludeResources).sorted()
            if resolvedResources?.isEmpty == true { return .skipped }
        } else if !excludeResources.isEmpty {
            let allWebKitTypes: Set<String> = [
                "document", "image", "style-sheet", "script", "font", "raw",
                "svg-document", "media", "popup", "ping", "fetch", "websocket",
            ]
            let remaining = allWebKitTypes.subtracting(excludeResources).sorted()
            if remaining.isEmpty { return .skipped }
            resolvedResources = remaining
        } else {
            resolvedResources = nil
        }

        guard let urlFilter = compileURLPatternToWebKitRegex(pattern) else {
            return isException && !cosmeticAllowDomains.isEmpty
                ? .exception(nil, cosmeticAllowDomains: cosmeticAllowDomains)
                : .skipped
        }

        let rule = WebKitRule(
            urlFilter: urlFilter,
            isCaseSensitive: isCaseSensitive,
            loadType: loadType,
            resourceType: resolvedResources,
            ifDomain: includeDomains.isEmpty ? nil : includeDomains.map { "*\($0)" },
            unlessDomain: excludeDomains.isEmpty ? nil : excludeDomains.map { "*\($0)" },
            actionType: isException ? .ignorePreviousRules : .block
        )

        if isException {
            return .exception(rule, cosmeticAllowDomains: cosmeticAllowDomains)
        }
        return .block(rule, important: isImportant)
    }

    private static func mapResourceType(_ name: String) -> [String]? {
        switch name {
        case "script": return ["script"]
        case "image", "img": return ["image"]
        case "stylesheet", "css": return ["style-sheet"]
        case "font": return ["font"]
        case "media": return ["media"]
        case "popup": return ["popup"]
        case "ping", "beacon": return ["ping"]
        case "websocket": return ["websocket"]
        case "subdocument", "frame": return ["document"]
        case "xmlhttprequest", "xhr", "fetch": return ["raw", "fetch"]
        case "other", "object", "object-subrequest": return ["raw"]
        default: return nil
        }
    }

    private static func extractAnchoredDomain(from pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let rest = String(pattern.dropFirst(2))
        let hostPart = rest.prefix(while: { $0 != "^" && $0 != "/" && $0 != "*" && $0 != "|" })
        return normalizeASCIIHost(String(hostPart))
    }

    /// Translates an ABP/uBO URL pattern (or raw `/regex/`) into a WebKit-validated ASCII `url-filter`.
    public static func compileURLPatternToWebKitRegex(_ rawPattern: String) -> String? {
        let pattern = rawPattern.trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty || pattern == "*" {
            return ".*"
        }

        // Raw regex rule: `/pattern/`
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count >= 2 {
            let inner = String(pattern.dropFirst().dropLast())
            guard !inner.isEmpty, isValidWebKitURLFilter(inner) else { return nil }
            return inner
        }

        var working = pattern
        var regex = ""

        if working.hasPrefix("||") {
            regex += "^https?://+([^:/]+\\.)?"
            working = String(working.dropFirst(2))
        } else if working.hasPrefix("|") {
            regex += "^"
            working = String(working.dropFirst())
        }

        var hasEndAnchor = false
        if working.hasSuffix("|") {
            hasEndAnchor = true
            working = String(working.dropLast())
        }

        // Reject non-ASCII patterns immediately (WebKit content blockers are strictly ASCII).
        guard working.utf8.allSatisfy({ $0 < 128 }) else { return nil }

        // Trim redundant leading/trailing `*` wildcards.
        while working.hasPrefix("*") { working.removeFirst() }
        while working.hasSuffix("*") { working.removeLast() }
        if working.isEmpty && !hasEndAnchor {
            return regex.isEmpty ? ".*" : nil
        }

        var previousWasWildcard = false
        for ch in working {
            switch ch {
            case "*":
                if !previousWasWildcard {
                    regex += ".*"
                    previousWasWildcard = true
                }
            case "^":
                // WebKit URLFilterParser forbids `|` disjunctions; use ABP's standard separator class
                // (WebKit passes canonicalized URLs with trailing `/` to content blockers).
                regex += "[^a-zA-Z0-9._%-]"
                previousWasWildcard = false
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "|", "\\", "$":
                regex += "\\\(ch)"
                previousWasWildcard = false
            default:
                regex.append(ch)
                previousWasWildcard = false
            }
        }

        if hasEndAnchor {
            regex += "$"
        }

        guard isValidWebKitURLFilter(regex) else { return nil }
        return regex
    }

    /// Validates that a regex string conforms to WebKit's strict `URLFilterParser` DFA grammar so
    /// compiling a 100,000-rule list never aborts with a single bad trigger.
    public static func isValidWebKitURLFilter(_ filter: String) -> Bool {
        guard !filter.isEmpty, filter.count <= 2048 else { return false }
        guard filter.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return false }

        let chars = Array(filter)
        var parenDepth = 0
        var inCharClass = false
        var escaped = false
        var prevWasQuantifier = false
        var prevWasAtom = false

        for (i, ch) in chars.enumerated() {
            if escaped {
                // Reject PCRE shorthand classes & backreferences unsupported by WebKit's ContentExtensionParser.
                if "dDwWsSbBpPkxu123456789".contains(ch) {
                    return false
                }
                escaped = false
                prevWasQuantifier = false
                prevWasAtom = true
                continue
            }

            if ch == "\\" {
                escaped = true
                continue
            }

            if inCharClass {
                if ch == "]" {
                    inCharClass = false
                    prevWasAtom = true
                    prevWasQuantifier = false
                }
                continue
            }

            switch ch {
            case "[":
                inCharClass = true
                prevWasQuantifier = false
                prevWasAtom = false
            case "]":
                return false
            case "(":
                // Reject lookarounds / non-capturing / inline flags `(?...)`.
                if i + 1 < chars.count && chars[i + 1] == "?" {
                    return false
                }
                // Reject empty `()`.
                if i + 1 < chars.count && chars[i + 1] == ")" {
                    return false
                }
                parenDepth += 1
                prevWasQuantifier = false
                prevWasAtom = false
            case ")":
                parenDepth -= 1
                if parenDepth < 0 { return false }
                prevWasQuantifier = false
                prevWasAtom = true
            case "{", "}":
                // Unescaped `{m,n}` counted quantifiers are rejected by WebKit's DFA parser.
                return false
            case "*", "+", "?":
                // Reject leading quantifiers, consecutive quantifiers (`**`, `*?`, `+?`, `??`).
                if !prevWasAtom || prevWasQuantifier {
                    return false
                }
                prevWasQuantifier = true
            case "|":
                // WebKit's URLFilterParser rejects all `|` disjunctions ("Disjunctions are not supported yet").
                return false
            case "^":
                if i != 0 { return false }
                prevWasQuantifier = false
                prevWasAtom = false
            case "$":
                if i != chars.count - 1 { return false }
                prevWasQuantifier = false
                prevWasAtom = false
            default:
                prevWasQuantifier = false
                prevWasAtom = true
            }
        }

        if escaped || inCharClass || parenDepth != 0 {
            return false
        }
        return true
    }

    // MARK: - Cosmetic, Extended CSS & Scriptlet Parsing

    private struct CosmeticOperatorMatch {
        let range: Range<String.Index>
        let isException: Bool
        let isExtended: Bool
    }

    private static func findCosmeticOperator(in line: String) -> CosmeticOperatorMatch? {
        // Order matters: check longer tokens first.
        let operators: [(token: String, isException: Bool, isExtended: Bool)] = [
            ("#@?#", true, true),
            ("#@#", true, false),
            ("#?#", false, true),
            ("##", false, false),
        ]
        var earliest: (match: CosmeticOperatorMatch, lower: String.Index)?
        for op in operators {
            if let range = line.range(of: op.token) {
                // Ensure the prefix before the operator looks like a domain list (no `/`, `$`, or whitespace).
                let prefix = line[..<range.lowerBound]
                if prefix.contains("/") || prefix.contains("$") || prefix.contains(" ") {
                    continue
                }
                if earliest == nil || range.lowerBound < earliest!.lower {
                    earliest = (CosmeticOperatorMatch(range: range, isException: op.isException, isExtended: op.isExtended), range.lowerBound)
                }
            }
        }
        return earliest?.match
    }

    private static func isExtendedCSSSelector(_ selector: String) -> Bool {
        extendedCSSMarkers.contains(where: { selector.contains($0) })
    }

    private static func parseStyleInjectionRule(
        body: String,
        includeDomains: [String],
        excludeDomains: [String]
    ) -> BrowserInjectedStyleRule? {
        guard let styleRange = body.range(of: ":style("), body.hasSuffix(")") else { return nil }
        let selector = String(body[..<styleRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let css = String(body[styleRange.upperBound..<body.index(before: body.endIndex)]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, !css.isEmpty else { return nil }
        // Reject extended procedural markers inside the selector part for pure style injection.
        guard !isExtendedCSSSelector(selector), isValidStandardCSSSelector(selector) else { return nil }
        // Prevent breaking out of `<style>` tag.
        guard !css.lowercased().contains("</style") else { return nil }
        return BrowserInjectedStyleRule(
            selector: selector,
            cssBody: css,
            includeDomains: includeDomains,
            excludeDomains: excludeDomains
        )
    }

    /// Checks whether a CSS selector is safe to emit into a WebKit `css-display-none` rule
    /// (and safe to batch with commas without invalidating neighboring selectors).
    public static func isValidStandardCSSSelector(_ selector: String) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1024 else { return false }
        guard !trimmed.hasPrefix(","), !trimmed.hasSuffix(",") else { return false }
        guard !trimmed.contains("{"), !trimmed.contains("}"), !trimmed.contains(";"), !trimmed.contains("##") else {
            return false
        }
        if isExtendedCSSSelector(trimmed) { return false }

        var parenDepth = 0
        var bracketDepth = 0
        var quote: Character? = nil
        var escaped = false

        for ch in trimmed {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "(": parenDepth += 1
            case ")":
                parenDepth -= 1
                if parenDepth < 0 { return false }
            case "[": bracketDepth += 1
            case "]":
                bracketDepth -= 1
                if bracketDepth < 0 { return false }
            default: break
            }
        }
        return !escaped && quote == nil && parenDepth == 0 && bracketDepth == 0
    }

    private static func parseUBOScriptletBody(
        _ inner: String,
        includeDomains: [String],
        excludeDomains: [String]
    ) -> BrowserScriptletRule? {
        let parts = splitScriptletArgs(inner, delimiter: ",")
        guard let rawName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return nil
        }
        let canonical = canonicalScriptletName(rawName)
        let args = Array(parts.dropFirst()).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return BrowserScriptletRule(
            name: canonical,
            args: args,
            includeDomains: includeDomains,
            excludeDomains: excludeDomains
        )
    }

    private static func parseAdGuardScriptlet(_ line: String) -> (rule: BrowserScriptletRule, isException: Bool)? {
        let isException: Bool
        let range: Range<String.Index>
        if let r = line.range(of: "#@%#//scriptlet(") {
            isException = true
            range = r
        } else if let r = line.range(of: "#%#//scriptlet(") {
            isException = false
            range = r
        } else {
            return nil
        }
        guard line.hasSuffix(")") else { return nil }

        let domainPart = String(line[..<range.lowerBound])
        let parsedDomains = parseDomainList(domainPart, separator: ",")
        if parsedDomains.hasInvalidDomain { return nil }

        let inner = String(line[range.upperBound..<line.index(before: line.endIndex)])
        let parts = splitScriptletArgs(inner, delimiter: ",").map { unquoteScriptletArg($0) }
        guard let rawName = parts.first, !rawName.isEmpty else { return nil }
        let rule = BrowserScriptletRule(
            name: canonicalScriptletName(rawName),
            args: Array(parts.dropFirst()),
            includeDomains: parsedDomains.include,
            excludeDomains: parsedDomains.exclude
        )
        return (rule, isException)
    }

    private static func splitScriptletArgs(_ input: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                current.append(ch)
                continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                continue
            }
            if ch == delimiter {
                result.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        result.append(current)
        return result
    }

    private static func unquoteScriptletArg(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2,
           (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
        {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func canonicalScriptletName(_ raw: String) -> String {
        let name = raw.lowercased().replacingOccurrences(of: ".js", with: "")
        switch name {
        case "set", "set-constant": return "set-constant"
        case "aopr", "abort-on-property-read": return "abort-on-property-read"
        case "aopw", "abort-on-property-write": return "abort-on-property-write"
        case "acis", "abort-current-inline-script", "abort-current-script": return "abort-current-inline-script"
        case "json-prune": return "json-prune"
        case "json-prune-fetch-response": return "json-prune-fetch-response"
        case "json-prune-xhr-response": return "json-prune-xhr-response"
        case "nostif", "no-settimeout-if", "prevent-settimeout": return "no-setTimeout-if"
        case "nosiif", "no-setinterval-if", "prevent-setinterval": return "no-setInterval-if"
        case "no-fetch-if", "prevent-fetch": return "no-fetch-if"
        case "no-xhr-if", "prevent-xhr": return "no-xhr-if"
        case "aeld", "addEventListener-defuser".lowercased(), "prevent-addeventlistener": return "prevent-addEventListener"
        case "nowoif", "no-window-open-if", "prevent-window-open": return "nowoif"
        case "ra", "remove-attr": return "remove-attr"
        case "rc", "remove-class": return "remove-class"
        case "trusted-click-element", "click-element": return "click-element"
        default: return name
        }
    }

    private static func applyScriptletExceptions(
        _ rules: [BrowserScriptletRule],
        exceptions: [ScriptletException]
    ) -> [BrowserScriptletRule] {
        guard !exceptions.isEmpty else { return rules }
        return rules.compactMap { rule in
            var excluded = Set(rule.excludeDomains)
            for ex in exceptions {
                let nameMatches = ex.name.isEmpty || ex.name == rule.name
                let argsMatch = ex.args.isEmpty || ex.args == rule.args
                guard nameMatches && argsMatch else { continue }
                if ex.domains.isEmpty {
                    return nil
                }
                for d in ex.domains {
                    excluded.insert(d)
                }
            }
            let remainingInclude = rule.includeDomains.filter { !excluded.contains($0) }
            if !rule.includeDomains.isEmpty && remainingInclude.isEmpty {
                return nil
            }
            return BrowserScriptletRule(
                name: rule.name,
                args: rule.args,
                includeDomains: remainingInclude,
                excludeDomains: excluded.sorted()
            )
        }
    }

    // MARK: - Domain Helpers & Utilities

    private struct ParsedDomains {
        var include: [String] = []
        var exclude: [String] = []
        var hasInvalidDomain = false
    }

    private static func parseDomainList(_ raw: String, separator: Character) -> ParsedDomains {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ParsedDomains() }
        var parsed = ParsedDomains()
        for piece in trimmed.split(separator: separator) {
            var token = piece.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let isNegated = token.hasPrefix("~")
            if isNegated { token.removeFirst() }
            // Skip regex/wildcard entity domains like `example.*` or `/regex/` that WebKit triggers can't encode.
            if token.contains("*") || token.contains("/") {
                parsed.hasInvalidDomain = true
                return parsed
            }
            guard let host = normalizeASCIIHost(token) else {
                parsed.hasInvalidDomain = true
                return parsed
            }
            if isNegated {
                parsed.exclude.append(host)
            } else {
                parsed.include.append(host)
            }
        }
        return parsed
    }

    private static func normalizeASCIIHost(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, s.count <= 253 else { return nil }
        guard s.utf8.allSatisfy({ b in
            (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E
        }) else { return nil }
        guard s.contains(".") || s == "localhost" else { return nil }
        return s
    }

    private static func escapeForWebKitRegex(_ literal: String) -> String {
        var out = ""
        out.reserveCapacity(literal.count + 8)
        for ch in literal {
            if ".+?()[]{}|\\^$*".contains(ch) {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    private static func deduplicateScriptlets(_ list: [BrowserScriptletRule]) -> [BrowserScriptletRule] {
        var seen = Set<String>()
        return list.filter { item in
            let key = "\(item.name)|\(item.args.joined(separator: "\u{1F}"))|\(item.includeDomains.joined(separator: ","))|\(item.excludeDomains.joined(separator: ","))"
            return seen.insert(key).inserted
        }
    }

    private static func deduplicateExtendedCSS(_ list: [BrowserExtendedCSSRule]) -> [BrowserExtendedCSSRule] {
        var seen = Set<String>()
        return list.filter { item in
            let key = "\(item.selector)|\(item.removeNode)|\(item.includeDomains.joined(separator: ","))|\(item.excludeDomains.joined(separator: ","))"
            return seen.insert(key).inserted
        }
    }

    private static func deduplicateInjectedStyles(_ list: [BrowserInjectedStyleRule]) -> [BrowserInjectedStyleRule] {
        var seen = Set<String>()
        return list.filter { item in
            let key = "\(item.selector)|\(item.cssBody)|\(item.includeDomains.joined(separator: ","))|\(item.excludeDomains.joined(separator: ","))"
            return seen.insert(key).inserted
        }
    }

    /// Deterministic 64-bit FNV-1a hex digest for stable `WKContentRuleListStore` cache identifiers.
    public static func stableFNV1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
