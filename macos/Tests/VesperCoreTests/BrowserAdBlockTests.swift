import XCTest
@testable import VesperCore

final class BrowserAdBlockTests: XCTestCase {

    // MARK: - Network & Hosts Compilation

    func testCompilesABPNetworkRulesAndHostsFileEntries() throws {
        let list = """
        ! Comment line
        [Adblock Plus 2.0]
        # Hash comment
        0.0.0.0 tracker.bad.example
        127.0.0.1 localhost
        ||ads.example.com^$third-party,script
        |https://cdn.example.com/ad.js$image,domain=news.example.com
        @@||ads.example.com/allow.js$script
        ||important.ads.example^$important
        ||cancelled.ads.example^$script
        ||cancelled.ads.example^$script,badfilter
        """

        let result = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .ads, text: list)],
            youtubeAdShieldEnabled: false
        )

        XCTAssertEqual(result.chunks.count, 1)
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(chunk.kind, .network)

        let data = try XCTUnwrap(chunk.json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        // 0.0.0.0 tracker.bad.example + ads.example.com + cdn.example.com/ad.js + exception + important = 5
        // localhost and badfilter-cancelled rule must be excluded.
        XCTAssertEqual(rules.count, 5)
        XCTAssertFalse(chunk.json.contains("localhost"))
        XCTAssertFalse(chunk.json.contains("cancelled\\.ads\\.example"))

        // Verify ordering: normal blocks -> exceptions (`ignore-previous-rules`) -> `$important` blocks.
        let actionTypes = rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(actionTypes, ["block", "block", "block", "ignore-previous-rules", "block"])

        // Verify domain scoping & resource types on cdn.example.com/ad.js.
        let cdnRule = rules[2]
        let trigger = try XCTUnwrap(cdnRule["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["if-domain"] as? [String], ["*news.example.com"])
        XCTAssertEqual(trigger["resource-type"] as? [String], ["image"])
    }

    func testRejectsWebKitIncompatibleRegexSyntax() {
        // Valid WebKit DFA triggers
        XCTAssertTrue(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https?://+([^:/]+\\.)?doubleclick\\.net[^a-zA-Z0-9._%-]"))
        XCTAssertTrue(BrowserAdBlockCompiler.isValidWebKitURLFilter(".*"))
        XCTAssertTrue(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://example\\.com/ads/[0-9]+\\.js$"))

        // Invalid for WebKit ContentExtensionParser (would abort entire list compilation)
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https?://example\\.com([:/?#]|$)"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://(ads|track)\\.example\\.com/"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("(?<=foo)bar"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("(?!ads)foo"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://example\\.com/\\d+\\.js$"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://example\\.com/a{2,4}\\.js$"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://example\\.com/.*?\\.js$"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://example\\.com/(\\w+)\\1$"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://exämple\\.com/$"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("^https://example\\.com/(unclosed"))
        XCTAssertFalse(BrowserAdBlockCompiler.isValidWebKitURLFilter("|leading-or"))

        // Mixed if-domain + unless-domain is forbidden by WebKit and must be safely skipped.
        let mixed = "||ads.example^$domain=a.com|~b.com"
        let res = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .ads, text: mixed)],
            youtubeAdShieldEnabled: false
        )
        XCTAssertTrue(res.chunks.isEmpty)
        XCTAssertEqual(res.stats.skippedRules, 1)
    }

    // MARK: - Cosmetic Batching, Exceptions & Chunking

    func testCosmeticBatchingAndExceptions() throws {
        let list = """
        ##.ad-box-1
        ##.ad-box-2
        ##.ad-excepted-globally
        #@#.ad-excepted-globally
        ##.ad-excepted-on-one-site
        trusted.example#@#.ad-excepted-on-one-site
        news.example##.promo-banner
        """

        let result = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .ads, text: list)],
            youtubeAdShieldEnabled: false
        )

        XCTAssertEqual(result.chunks.count, 1)
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(chunk.kind, .cosmetic)

        let data = try XCTUnwrap(chunk.json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        // 1. `.ad-excepted-on-one-site` with `unless-domain: ["*trusted.example"]`
        // 2. batched generic `.ad-box-1, .ad-box-2`
        // 3. domain-scoped `news.example` `.promo-banner`
        XCTAssertEqual(rules.count, 3)
        XCTAssertFalse(chunk.json.contains("ad-excepted-globally"))

        let unlessRule = rules.first { (($0["trigger"] as? [String: Any])?["unless-domain"] as? [String]) == ["*trusted.example"] }
        XCTAssertEqual((unlessRule?["action"] as? [String: Any])?["selector"] as? String, ".ad-excepted-on-one-site")

        let batched = rules.first { ($0["trigger"] as? [String: Any])?["if-domain"] == nil && ($0["trigger"] as? [String: Any])?["unless-domain"] == nil }
        XCTAssertEqual((batched?["action"] as? [String: Any])?["selector"] as? String, ".ad-box-1, .ad-box-2")
    }

    func testNetworkChunkingSplitsUnderLimitAndPreservesExceptionsPerChunk() throws {
        var lines: [String] = []
        for i in 0..<140 {
            lines.append("||ad\(i).example.net^$third-party")
        }
        lines.append("@@||ad5.example.net/ok.js$third-party")

        let result = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .ads, text: lines.joined(separator: "\n"))],
            youtubeAdShieldEnabled: false,
            maxRulesPerChunk: 60
        )

        // 140 blocks with chunk limit 60 (1 exception reserved per chunk -> 59 blocks/chunk) => 3 chunks.
        XCTAssertEqual(result.chunks.count, 3)
        for chunk in result.chunks {
            XCTAssertLessThanOrEqual(chunk.ruleCount, 60)
            // Every network chunk carries the category's exception rule so WebKit honors `ignore-previous-rules`.
            XCTAssertTrue(chunk.json.contains("ignore-previous-rules"))
        }
    }

    // MARK: - Phase B: Scriptlets, Extended CSS & Style Injection

    func testParsesUBOScriptletsAdGuardScriptletsExtendedCSSAndStyles() {
        let list = """
        youtube.com##+js(json-prune, adPlacements playerAds)
        example.com##+js(set, canRunAds, true)
        example.com#@#+js(set, canRunAds, true)
        news.example#%#//scriptlet('aopr', 'adBlockDetected')
        ##body.sp-message-open:style(overflow: auto !important;)
        reddit.com##article:has-text(/^Promoted$/):remove()
        example.com#?#div.card:has-text(Sponsored):upward(2)
        @@||safe.example^$elemhide
        """

        let result = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .scriptlets, text: list)],
            youtubeAdShieldEnabled: true
        )

        // `example.com##+js(set, ...)` is cancelled by `example.com#@#+js(set, ...)`.
        XCTAssertEqual(result.advanced.scriptlets.count, 2)
        XCTAssertEqual(result.advanced.scriptlets[0].name, "json-prune")
        XCTAssertEqual(result.advanced.scriptlets[0].includeDomains, ["youtube.com"])
        XCTAssertEqual(result.advanced.scriptlets[0].args, ["adPlacements playerAds"])

        XCTAssertEqual(result.advanced.scriptlets[1].name, "abort-on-property-read")
        XCTAssertEqual(result.advanced.scriptlets[1].includeDomains, ["news.example"])
        XCTAssertEqual(result.advanced.scriptlets[1].args, ["adBlockDetected"])

        XCTAssertEqual(result.advanced.injectedStyles.count, 1)
        XCTAssertEqual(result.advanced.injectedStyles[0].selector, "body.sp-message-open")
        XCTAssertEqual(result.advanced.injectedStyles[0].cssBody, "overflow: auto !important;")

        XCTAssertEqual(result.advanced.extendedCSS.count, 2)
        XCTAssertTrue(result.advanced.extendedCSS[0].removeNode)
        XCTAssertEqual(result.advanced.extendedCSS[0].selector, "article:has-text(/^Promoted$/)")
        XCTAssertFalse(result.advanced.extendedCSS[1].removeNode)
        XCTAssertEqual(result.advanced.extendedCSS[1].selector, "div.card:has-text(Sponsored):upward(2)")

        XCTAssertEqual(result.advanced.cosmeticExceptionDomains, ["safe.example"])

        let runtimeJS = BrowserAdBlockScripts.makePageRuntimeSource(for: result.advanced)
        XCTAssertNotNil(runtimeJS)
        XCTAssertTrue(runtimeJS?.contains("ytInitialPlayerResponse") == true)
        XCTAssertTrue(runtimeJS?.contains("adPlacements playerAds") == true)
    }

    // MARK: - Bundled Starter Lists & Config Persistence

    func testBundledStarterListsLoadAndCompileCleanly() throws {
        var sources: [BrowserAdBlockFilterSource] = []
        for category in BrowserAdBlockCategory.allCases {
            let text = BrowserAdBlockBundle.bundledListText(for: category)
            XCTAssertFalse(text.isEmpty, "Bundled starter list for \(category.rawValue) must not be empty")
            sources.append(BrowserAdBlockFilterSource(category: category, text: text))
        }

        let compiled = BrowserAdBlockCompiler.compile(sources: sources, youtubeAdShieldEnabled: true)
        XCTAssertGreaterThan(compiled.stats.networkBlockRules, 150)
        XCTAssertGreaterThan(compiled.stats.cosmeticRules, 50)
        XCTAssertGreaterThan(compiled.stats.scriptletRules, 10)
        XCTAssertGreaterThan(compiled.stats.extendedCSSRules, 5)
        XCTAssertGreaterThan(compiled.stats.injectedStyleRules, 5)
        XCTAssertGreaterThanOrEqual(compiled.chunks.count, 4)

        for chunk in compiled.chunks {
            let data = try XCTUnwrap(chunk.json.data(using: .utf8))
            let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertEqual(arr.count, chunk.ruleCount)
            for item in arr {
                let trigger = try XCTUnwrap(item["trigger"] as? [String: Any])
                let urlFilter = try XCTUnwrap(trigger["url-filter"] as? String)
                XCTAssertTrue(BrowserAdBlockCompiler.isValidWebKitURLFilter(urlFilter), "Invalid trigger: \(urlFilter)")
                // Never emit both if-domain and unless-domain in the same trigger.
                XCTAssertFalse(trigger["if-domain"] != nil && trigger["unless-domain"] != nil)
            }
        }
    }

    func testAdBlockConfigPersistsAndValidatesSubscriptionURLs() throws {
        XCTAssertNotNil(BrowserAdBlockConfig.validateSubscriptionURL("https://easylist.to/easylist/easylist.txt"))
        XCTAssertNil(BrowserAdBlockConfig.validateSubscriptionURL("http://insecure.example/list.txt"))
        XCTAssertNil(BrowserAdBlockConfig.validateSubscriptionURL("file:///etc/passwd"))
        XCTAssertNil(BrowserAdBlockConfig.validateSubscriptionURL("not a url"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-ab-cfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = BrowserStorage.fileURL(dataDirectory: dir)

        var cfg = BrowserAdBlockConfig.default
        cfg.setCategory(.annoyances, enabled: false)
        cfg.youtubeAdShieldEnabled = false
        cfg.customRules = "example.com##.nag-banner\n||tracker.example^"
        cfg.subscriptions.append(BrowserFilterListSubscription(
            id: "custom-1",
            name: "My Custom List",
            category: .ads,
            url: "https://example.com/my-filters.txt",
            isBuiltIn: false,
            isEnabled: true
        ))

        let state = BrowserPersistedState(adBlockEnabled: true, adBlockConfig: cfg)
        try BrowserStorage.save(state, to: file)
        let loaded = BrowserStorage.load(from: file)

        XCTAssertFalse(loaded.adBlockConfig.isCategoryEnabled(.annoyances))
        XCTAssertTrue(loaded.adBlockConfig.isCategoryEnabled(.ads))
        XCTAssertFalse(loaded.adBlockConfig.youtubeAdShieldEnabled)
        XCTAssertEqual(loaded.adBlockConfig.customRules, cfg.customRules)
        XCTAssertTrue(loaded.adBlockConfig.subscriptions.contains(where: { $0.id == "custom-1" && $0.name == "My Custom List" }))
    }
}
