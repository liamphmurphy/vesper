import AppKit
import Testing
import VesperCore
import WebKit
@testable import Vesper

@MainActor
@Suite("Internal Browser Shell, Profiles, Extensions & AutoFill")
struct BrowserIntegrationTests {
    @Test("Browser area appears in the main left navbar list")
    func navbarContainsBrowserArea() {
        let areas = ShellState.fallbackShell.areas
        let browser = areas.first(where: { $0.id == .browser })
        #expect(browser != nil)
        #expect(browser?.label == "Browser")
        #expect(browser?.href == "/browser")
        #expect(browser?.icon == "compass")
    }

    @Test("Browser web views isolate cookies per profile, away from Vesper's default store, and use standard Safari UA")
    func webViewIsolationAndUserAgent() {
        let regular = BrowserWebViewFactory.makeWebView(isPrivate: false)
        let priv = BrowserWebViewFactory.makeWebView(isPrivate: true)
        let workStoreID = UUID()
        let work = BrowserWebViewFactory.makeWebView(
            isPrivate: false,
            profileDataStoreID: workStoreID
        )

        #expect(regular.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(regular.configuration.websiteDataStore === BrowserWebViewFactory.persistentStore)
        #expect(regular.configuration.websiteDataStore.isPersistent)
        #expect(!priv.configuration.websiteDataStore.isPersistent)

        #expect(work.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(work.configuration.websiteDataStore !== regular.configuration.websiteDataStore)
        #expect(work.configuration.websiteDataStore.isPersistent)

        let ua = regular.customUserAgent ?? ""
        #expect(ua.contains("Safari/"))
        #expect(!ua.contains("VesperMac"))
    }

    @Test("WKWebExtensionController attaches to profile WebViews and loads a real MV3 extension")
    func webExtensionHostLoadsMV3Extension() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-ext-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let extDir = tempRoot.appendingPathComponent("sample-ext", isDirectory: true)
        try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        let manifest = """
        {
          "manifest_version": 3,
          "name": "Vesper Test Helper",
          "version": "1.2.3",
          "description": "Integration test extension",
          "permissions": ["storage", "activeTab"],
          "action": { "default_title": "Test Action" }
        }
        """
        try Data(manifest.utf8).write(to: extDir.appendingPathComponent("manifest.json"))

        let profileID = UUID()
        let dataStoreID = UUID()
        let host = BrowserExtensionHost(
            profileID: profileID,
            dataStoreID: dataStoreID,
            dataDirectory: tempRoot,
            initialRecords: []
        )
        defer { host.teardown() }

        let wv = BrowserWebViewFactory.makeWebView(
            isPrivate: false,
            profileDataStoreID: dataStoreID,
            webExtensionController: host.controller
        )
        #expect(wv.configuration.webExtensionController === host.controller)

        let result = await host.installExtension(from: extDir, copyIntoManagedStorage: false)
        let record = try result.get()
        #expect(record.displayName == "Vesper Test Helper")
        #expect(host.records.count == 1)
        #expect(host.toolbarItems.count == 1)
        #expect(host.toolbarItems[0].isLoaded)
        #expect(host.toolbarItems[0].version == "1.2.3")

        await host.setEnabled(false, for: record.id)
        #expect(!host.toolbarItems[0].isEnabled)
        #expect(!host.toolbarItems[0].isLoaded)

        host.removeExtension(id: record.id)
        #expect(host.records.isEmpty)
    }

    @Test("BrowserAutofillManager isolates credentials per profile and enforces HTTPS/private rules")
    func autofillManagerProfileIsolation() {
        let backing = InMemoryBrowserCredentialStore()
        let personalID = UUID()
        let workID = UUID()

        let personal = BrowserAutofillManager(profileID: personalID, store: backing)
        let work = BrowserAutofillManager(profileID: workID, store: backing)

        #expect(personal.saveCredential(host: "github.com", username: "personal-liam", password: "pw1"))
        #expect(work.saveCredential(host: "github.com", username: "work-liam", password: "pw2"))

        let personalMatches = personal.matchingCredentials(for: "https://github.com/login")
        let workMatches = work.matchingCredentials(for: "https://github.com/login")
        #expect(personalMatches.map(\.username) == ["personal-liam"])
        #expect(workMatches.map(\.username) == ["work-liam"])

        // Unencrypted remote HTTP must not receive credentials.
        #expect(personal.matchingCredentials(for: "http://github.com/login").isEmpty)

        // Private tabs must not prompt to save credentials.
        let privatePrompt = personal.evaluateSubmission(
            urlString: "https://example.com/login",
            username: "secret",
            password: "pw",
            isPrivate: true,
            autofillEnabled: true,
            neverSaveHosts: []
        )
        #expect(privatePrompt == nil)

        // Updating an existing user produces an update prompt; deleting clears it.
        let updatePrompt = personal.evaluateSubmission(
            urlString: "https://github.com/login",
            username: "personal-liam",
            password: "pw-updated",
            isPrivate: false,
            autofillEnabled: true,
            neverSaveHosts: []
        )
        #expect(updatePrompt?.isUpdate == true)

        #expect(personal.deleteCredential(id: personalMatches[0].id))
        #expect(personal.matchingCredentials(for: "https://github.com/login").isEmpty)
        #expect(work.matchingCredentials(for: "https://github.com/login").count == 1)
    }

    @Test("MainMenu registers Browser Tier 1 and Tier 2 shortcuts")
    func menuRegistersBrowserShortcuts() {
        let delegate = AppDelegate()
        let menu = MainMenu.build(delegate: delegate)
        let browserMenu = menu.items.first(where: { $0.title == "Browser" })?.submenu
        #expect(browserMenu != nil)

        let items = browserMenu?.items ?? []
        let focus = items.first(where: { $0.action == #selector(AppDelegate.focusBrowserAddressBar(_:)) })
        #expect(focus?.keyEquivalent == "l")
        #expect(focus?.keyEquivalentModifierMask == [.command])

        let split = items.first(where: { $0.action == #selector(AppDelegate.toggleBrowserSplitView(_:)) })
        #expect(split?.keyEquivalent == "\\")
        #expect(split?.keyEquivalentModifierMask == [.command, .control])

        let mute = items.first(where: { $0.action == #selector(AppDelegate.toggleBrowserTabMute(_:)) })
        #expect(mute?.keyEquivalent == "m")
        #expect(mute?.keyEquivalentModifierMask == [.command, .option])

        let group = items.first(where: { $0.action == #selector(AppDelegate.newBrowserTabGroup(_:)) })
        #expect(group?.keyEquivalent == "g")
        #expect(group?.keyEquivalentModifierMask == [.command, .control])

        let autofill = items.first(where: { $0.action == #selector(AppDelegate.openBrowserAutofill(_:)) })
        #expect(autofill?.keyEquivalent == "a")
        #expect(autofill?.keyEquivalentModifierMask == [.command, .shift])

        let extensions = items.first(where: { $0.action == #selector(AppDelegate.openBrowserExtensions(_:)) })
        #expect(extensions?.keyEquivalent == "e")
        #expect(extensions?.keyEquivalentModifierMask == [.command, .control])

        let numbered = items.filter { $0.action == #selector(AppDelegate.selectBrowserTab(_:)) }
        #expect(numbered.count == 9)
        for n in 1...9 {
            let item = numbered.first(where: { $0.tag == n })
            #expect(item?.keyEquivalent == "\(n)")
            #expect(item?.keyEquivalentModifierMask == [.command, .control])
        }

        let next = items.first(where: { $0.action == #selector(AppDelegate.nextBrowserTab(_:)) })
        let prev = items.first(where: { $0.action == #selector(AppDelegate.previousBrowserTab(_:)) })
        #expect(next?.keyEquivalent == "]")
        #expect(next?.keyEquivalentModifierMask == [.command, .control])
        #expect(prev?.keyEquivalent == "[")
        #expect(prev?.keyEquivalentModifierMask == [.command, .control])
    }

    @Test("BrowserAdBlockEngine compiles all bundled starter filter lists into real WebKit WKContentRuleLists")
    func adBlockEngineCompilesBundledStarterListsInWebKit() async {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-adblock-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let engine = BrowserAdBlockEngine(dataDirectory: tempRoot)
        await engine.recompile(enabled: true, config: .default)

        #expect(engine.lastError == nil)
        #expect(engine.compiledRuleLists.count >= 4)
        #expect(engine.compiledPageScript != nil)
        #expect(engine.stats.networkBlockRules > 150)
        #expect(engine.stats.cosmeticRules > 50)
        #expect(engine.stats.scriptletRules > 10)

        // Instant per-tab attach/detach when switching between protected and allowlisted hosts.
        let record = BrowserTabRecord(url: "", title: "Test")
        let session = BrowserTabSession(
            record: record,
            contentRuleLists: engine.compiledRuleLists,
            adBlockPageScript: engine.compiledPageScript,
            adBlockActive: true
        )
        defer { session.teardown() }
        session.adBlockActiveProvider = { url in
            BrowserContentBlockerRules.isAdBlockActive(
                globalEnabled: true,
                host: url,
                disabledHosts: ["trusted.example"]
            )
        }

        // Attached initially: metrics bridge + passkey bridge + passkey observer + autofill + adblock page script = 5 user scripts.
        #expect(session.webView.configuration.userContentController.userScripts.count == 5)

        // Navigating to allowlisted host detaches adblock page script while preserving AutoFill, passkey & metrics scripts.
        session.syncAdBlockForURL("https://trusted.example/page")
        #expect(session.webView.configuration.userContentController.userScripts.count == 4)

        // Navigating back to a protected host reattaches the adblock page script instantaneously.
        session.syncAdBlockForURL("https://news.example/article")
        #expect(session.webView.configuration.userContentController.userScripts.count == 5)
    }

    @Test("BrowserAdBlockEngine downloads, caches, handles 304 ETag, and compiles upstream filter lists")
    func adBlockEngineUpdaterCachesAndCompilesRemoteLists() async {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-adblock-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mockList = """
        ! Mock Upstream EasyList
        ||mocked-ad-network.example^$third-party
        ##.mocked-ad-slot
        example.com##+js(set-constant, mockedAdFlag, false)
        """
        let counter = FetchCounter()
        let engine = BrowserAdBlockEngine(dataDirectory: tempRoot) { url, etag, _ in
            let call = await counter.increment()
            if call == 1 {
                return BrowserFilterListFetchResponse(
                    statusCode: 200,
                    body: Data(mockList.utf8),
                    etag: "\"v1\""
                )
            }
            #expect(etag == "\"v1\"")
            return BrowserFilterListFetchResponse(statusCode: 304, body: Data(), etag: "\"v1\"")
        }

        var cfg = BrowserAdBlockConfig(
            enabledCategories: [.ads, .scriptlets],
            subscriptions: [
                BrowserFilterListSubscription(
                    id: "mock-list",
                    name: "Mock Upstream",
                    category: .ads,
                    url: "https://filters.example.com/list.txt",
                    isBuiltIn: false,
                    isEnabled: true
                ),
            ],
            youtubeAdShieldEnabled: false
        )

        let first = await engine.updateFilterLists(config: cfg)
        #expect(first.updatedCount == 1)
        #expect(first.errorCount == 0)
        #expect(first.config.subscriptions[0].ruleCount == 3)
        #expect(first.config.subscriptions[0].lastUpdatedAt != nil)
        cfg = first.config

        // Second refresh sends If-None-Match and handles 304 cleanly.
        let second = await engine.updateFilterLists(config: cfg)
        #expect(second.updatedCount == 1)
        #expect(second.errorCount == 0)

        await engine.recompile(enabled: true, config: second.config, force: true)
        #expect(engine.lastError == nil)
        #expect(!engine.compiledRuleLists.isEmpty)
        #expect(engine.compiledPageScript != nil)
    }

    @Test("Phase B page-world runtime executes scriptlets, YouTube ad pruning, extended CSS, and :style() in live WKWebView")
    func phaseBRuntimeExecutesInLiveWebView() async throws {
        let rulesText = """
        ##+js(set-constant, canRunAds, true)
        ##body.scroll-locked:style(overflow: auto !important;)
        youtube.com##div.feed-card:has-text(Sponsored):upward(1)
        """
        let compiled = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .scriptlets, text: rulesText)],
            youtubeAdShieldEnabled: true
        )
        let source = try #require(BrowserAdBlockScripts.makePageRuntimeSource(for: compiled.advanced))
        let pageScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

        var hitCount = 0
        let metricsProxy = BrowserScriptMessageProxy { _ in
            hitCount += 1
        }
        let webView = BrowserWebViewFactory.makeWebView(
            isPrivate: true,
            adBlockPageScript: pageScript,
            adBlockMetricsHandler: metricsProxy
        )
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BrowserAdBlockScripts.metricsHandlerName,
                contentWorld: .defaultClient
            )
            webView.navigationDelegate = nil
        }

        let navDelegate = TestNavigationWaiter()
        webView.navigationDelegate = navDelegate

        let html = """
        <!doctype html>
        <html>
        <head>
          <style>body.scroll-locked { overflow: hidden; }</style>
          <script>
            window.ytInitialPlayerResponse = {
              videoDetails: { title: "Demo Video" },
              adPlacements: [{ id: "pre-roll" }],
              playerAds: [{ id: "mid-roll" }],
              adSlots: [{ id: "slot-1" }]
            };
            window.__parsedTest = JSON.parse('{"adPlacements":[1],"video":"ok"}');
          </script>
        </head>
        <body class="scroll-locked">
          <section id="wrapper-sponsored">
            <div class="feed-card"><span>Sponsored</span></div>
          </section>
          <section id="wrapper-organic">
            <div class="feed-card"><span>Real Video</span></div>
          </section>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/watch?v=test123")!)
        await navDelegate.waitForFinish()
        // Allow the 120ms DOM observer pass to settle.
        try await Task.sleep(for: .milliseconds(250))

        let checkJS = """
        ({
          canRunAds: window.canRunAds,
          ytTitle: window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails && window.ytInitialPlayerResponse.videoDetails.title,
          ytHasAdPlacements: window.ytInitialPlayerResponse && ('adPlacements' in window.ytInitialPlayerResponse),
          ytHasPlayerAds: window.ytInitialPlayerResponse && ('playerAds' in window.ytInitialPlayerResponse),
          ytHasAdSlots: window.ytInitialPlayerResponse && ('adSlots' in window.ytInitialPlayerResponse),
          parsedHasAdPlacements: window.__parsedTest && ('adPlacements' in window.__parsedTest),
          parsedVideo: window.__parsedTest && window.__parsedTest.video,
          sponsoredDisplay: getComputedStyle(document.getElementById('wrapper-sponsored')).display,
          organicDisplay: getComputedStyle(document.getElementById('wrapper-organic')).display,
          bodyOverflow: getComputedStyle(document.body).overflow
        })
        """
        let raw = try await webView.evaluateJavaScript(checkJS)
        let dict = try #require(raw as? [String: Any])

        #expect((dict["canRunAds"] as? Bool) == true)
        #expect((dict["ytTitle"] as? String) == "Demo Video")
        #expect((dict["ytHasAdPlacements"] as? Bool) == false)
        #expect((dict["ytHasPlayerAds"] as? Bool) == false)
        #expect((dict["ytHasAdSlots"] as? Bool) == false)
        #expect((dict["parsedHasAdPlacements"] as? Bool) == false)
        #expect((dict["parsedVideo"] as? String) == "ok")
        #expect((dict["sponsoredDisplay"] as? String) == "none")
        #expect((dict["organicDisplay"] as? String) != "none")
        #expect((dict["bodyOverflow"] as? String) == "auto")
        #expect(hitCount > 0)
    }

    @Test("BrowserAdBlockEngine resiliently isolates an invalid WebKit rule instead of dropping the whole chunk")
    func adBlockEngineResilientCompilationIsolatesInvalidRules() async {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-adblock-resilient-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let engine = BrowserAdBlockEngine(dataDirectory: tempRoot)
        let testID = "com.vesper.mac.browser.adblock.v2.test-resilient-\(UUID().uuidString.lowercased())"
        defer {
            Task { try? await WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: testID) }
        }

        // Mix 2 valid WebKit rules with 1 poison rule containing a `|` disjunction WebKit rejects.
        let poisonChunkJSON = """
        [
          {"trigger":{"url-filter":"^https?://+([^:/]+\\\\.)?trafficjunky\\\\.net[^a-zA-Z0-9._%-]"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://(bad|poison)\\\\.example\\\\.com/"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://+([^:/]+\\\\.)?adtng\\\\.com[^a-zA-Z0-9._%-]"},"action":{"type":"block"}}
        ]
        """

        let recovered = await engine.loadOrCompileRuleList(identifier: testID, json: poisonChunkJSON)
        #expect(recovered != nil)

        // Also verify `needsAutoUpdate` triggers when a newly added built-in subscription has never been fetched.
        var cfg = BrowserAdBlockConfig.default
        cfg.lastUpdatedAt = Date()
        for idx in cfg.subscriptions.indices {
            cfg.subscriptions[idx].lastUpdatedAt = Date()
        }
        #expect(!engine.needsAutoUpdate(config: cfg))
        cfg.subscriptions[0].lastUpdatedAt = nil
        #expect(engine.needsAutoUpdate(config: cfg))
    }

    @Test("Phase B runtime enforces entity domains, procedural :-abp-has/:matches-attr/:style, noeval-if, nowoif, and disable-newtab-links in live WKWebView")
    func phaseBRuntimeHandlesEntityDomainsAndAdvancedRulesInLiveWebView() async throws {
        let rulesText = """
        videohub.*##.tj-banner
        videohub.*##div.ad-slot:-abp-has(> a[href*="trafficjunky"]):upward(1)
        videohub.*##div:matches-attr(data-ad-zone=/^tj_/):style(opacity: 0 !important)
        videohub.*##+js(noeval-if, trafficjunky)
        videohub.*##+js(nowoif, /trafficjunky|exoclick/i)
        videohub.*##+js(disable-newtab-links, trafficjunky)
        """
        let compiled = BrowserAdBlockCompiler.compile(
            sources: [BrowserAdBlockFilterSource(category: .scriptlets, text: rulesText)],
            youtubeAdShieldEnabled: false
        )
        let source = try #require(BrowserAdBlockScripts.makePageRuntimeSource(for: compiled.advanced))
        let pageScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)

        let webView = BrowserWebViewFactory.makeWebView(
            isPrivate: true,
            adBlockPageScript: pageScript
        )
        defer { webView.navigationDelegate = nil }

        let navDelegate = TestNavigationWaiter()
        webView.navigationDelegate = navDelegate

        let html = """
        <!doctype html>
        <html>
        <head>
          <script>
            window.__evalBlocked = (eval('window.__tjRan = true; "trafficjunky"') === undefined && !window.__tjRan);
            window.__evalBenign = eval('2 + 3');
            window.__popupBlocked = (window.open('https://ads.trafficjunky.net/pop') === null);
          </script>
        </head>
        <body>
          <div id="banner" class="tj-banner">TrafficJunky Ad</div>
          <section id="tj-card">
            <div class="ad-slot"><a href="https://ads.trafficjunky.com/click">Promo</a></div>
          </section>
          <section id="organic-card">
            <div class="ad-slot"><a href="https://www.videohub.org/watch/2">Real Video</a></div>
          </section>
          <div id="attr-ad" data-ad-zone="tj_sidebar">Sidebar Ad</div>
          <a id="hijack-link" href="https://ads.trafficjunky.net/go" target="_blank">Ad Link</a>
          <a id="normal-link" href="https://www.videohub.org/about" target="_blank">About</a>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.videohub.org/watch/1")!)
        await navDelegate.waitForFinish()
        try await Task.sleep(for: .milliseconds(250))

        let checkJS = """
        ({
          evalBlocked: window.__evalBlocked,
          evalBenign: window.__evalBenign,
          popupBlocked: window.__popupBlocked,
          bannerDisplay: getComputedStyle(document.getElementById('banner')).display,
          tjCardDisplay: getComputedStyle(document.getElementById('tj-card')).display,
          organicCardDisplay: getComputedStyle(document.getElementById('organic-card')).display,
          attrAdOpacity: getComputedStyle(document.getElementById('attr-ad')).opacity,
          hijackTarget: document.getElementById('hijack-link').getAttribute('target') || '',
          normalTarget: document.getElementById('normal-link').getAttribute('target') || ''
        })
        """
        let raw = try await webView.evaluateJavaScript(checkJS)
        let dict = try #require(raw as? [String: Any])

        #expect((dict["evalBlocked"] as? Bool) == true)
        #expect((dict["evalBenign"] as? Int) == 5)
        #expect((dict["popupBlocked"] as? Bool) == true)
        #expect((dict["bannerDisplay"] as? String) == "none")
        #expect((dict["tjCardDisplay"] as? String) == "none")
        #expect((dict["organicCardDisplay"] as? String) != "none")
        #expect((dict["attrAdOpacity"] as? String) == "0")
        #expect((dict["hijackTarget"] as? String) == "")
        #expect((dict["normalTarget"] as? String) == "_blank")
    }

    @Test("BrowserWebViewFactory enables upgradeKnownHostsToHTTPS, Lockdown Mode, aligned UA, and per-profile proxyConfigurations")
    func webViewSecurityHardeningConfiguration() {
        let proxy = BrowserProxyConfig(mode: .socks5, host: "127.0.0.1", port: 1080, applyToPrivateTabs: true)
        let webView = BrowserWebViewFactory.makeWebView(
            isPrivate: true,
            lockdownModeEnabled: true,
            proxyConfig: proxy
        )
        #expect(webView.configuration.upgradeKnownHostsToHTTPS == true)
        #expect(webView.configuration.preferences.isFraudulentWebsiteWarningEnabled == true)
        #expect(webView.configuration.defaultWebpagePreferences.isLockdownModeEnabled == true)
        #expect(webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        #expect(webView.customUserAgent?.contains("Version/18.4") == false)
    }

    @Test("WebDownloads stamps macOS Gatekeeper web-download quarantine metadata on downloaded files")
    func downloadsStampQuarantineMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sample.txt")
        try Data("hello".utf8).write(to: fileURL)

        let dataURL = try #require(URL(string: "https://downloads.example.com/sample.txt"))
        let originURL = try #require(URL(string: "https://example.com/releases"))
        let stamped = WebDownloads.applyWebDownloadQuarantine(to: fileURL, dataURL: dataURL, originURL: originURL)
        #expect(stamped == true)

        let values = try fileURL.resourceValues(forKeys: [.quarantinePropertiesKey])
        let props = try #require(values.quarantineProperties)
        #expect((props[kLSQuarantineTypeKey as String] as? String) == (kLSQuarantineTypeWebDownload as String))
        #expect((props[kLSQuarantineAgentNameKey as String] as? String) == "Vesper")
    }

    @Test("BrowserAutofillManager enforces biometric Touch ID gate and Apple Passwords CSV import")
    func autofillBiometricGateAndCSVImport() async {
        let store = InMemoryBrowserCredentialStore()
        let denyingAuth = StubBiometricAuthenticator(shouldSucceed: false)
        let manager = BrowserAutofillManager(
            profileID: UUID(),
            store: store,
            authenticator: denyingAuth
        )

        let imported = manager.importApplePasswordsCSV("Title,URL,Username,Password\nExample,https://example.com,alice,secret123\n")
        #expect(imported == 1)
        #expect(manager.credentials.count == 1)

        let allowedWithoutGate = await manager.authenticateIfRequired(requireTouchID: false, reason: "test")
        #expect(allowedWithoutGate == true)
        #expect(denyingAuth.callCount == 0)

        let deniedWithGate = await manager.authenticateIfRequired(requireTouchID: true, reason: "test")
        #expect(deniedWithGate == false)
        #expect(denyingAuth.callCount == 1)

        denyingAuth.shouldSucceed = true
        let grantedWithGate = await manager.authenticateIfRequired(requireTouchID: true, reason: "test")
        #expect(grantedWithGate == true)
        #expect(denyingAuth.callCount == 2)
    }

    @Test("BrowserHighlightScripts injects, disambiguates, and removes persistent <mark> highlights in real WKWebView")
    func persistentHighlightsDOMInjectionAndRemoval() async throws {
        let webView = BrowserWebViewFactory.makeWebView(isPrivate: true)
        let waiter = TestNavigationWaiter()
        webView.navigationDelegate = waiter

        let html = """
        <!doctype html>
        <html>
          <body>
            <p id="p1">Intro before target phrase here.</p>
            <p id="p2">Exact context before target phrase after exact suffix.</p>
            <textarea id="ta">Exact context before target phrase after exact suffix.</textarea>
          </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/doc"))
        await waiter.waitForFinish()

        let h = BrowserWebHighlight(
            url: "https://example.com/doc",
            quote: "target phrase",
            prefix: "Exact context before",
            suffix: "after exact suffix",
            color: .yellow
        )
        let applyJS = BrowserHighlightScripts.applyHighlightsJS(highlights: [h])
        let firstCount = (try? await webView.evaluateJavaScript(applyJS)) as? Int
        #expect(firstCount == 1)

        // Applying again must be idempotent (no nested/duplicate marks).
        let secondCount = (try? await webView.evaluateJavaScript(applyJS)) as? Int
        #expect(secondCount == 1)

        let inspectJS = """
        (() => {
          const marks = document.querySelectorAll('mark[data-vesper-highlight]');
          return {
            total: marks.length,
            parentId: marks[0] ? marks[0].parentElement.id : "",
            text: marks[0] ? marks[0].textContent : ""
          };
        })();
        """
        let inspected = try #require((try? await webView.evaluateJavaScript(inspectJS)) as? [String: Any])
        #expect((inspected["total"] as? Int) == 1)
        #expect((inspected["parentId"] as? String) == "p2")
        #expect((inspected["text"] as? String) == "target phrase")

        let removeJS = BrowserHighlightScripts.removeHighlightJS(id: h.id)
        let removed = (try? await webView.evaluateJavaScript(removeJS)) as? Int
        #expect(removed == 1)

        let afterCount = (try? await webView.evaluateJavaScript("document.querySelectorAll('mark[data-vesper-highlight]').length")) as? Int
        #expect(afterCount == 0)
        let restoredText = (try? await webView.evaluateJavaScript("document.getElementById('p2').textContent")) as? String
        #expect(restoredText == "Exact context before target phrase after exact suffix.")
    }
}

@MainActor
private final class StubBiometricAuthenticator: BrowserBiometricAuthenticator {
    var shouldSucceed: Bool
    var callCount: Int = 0

    init(shouldSucceed: Bool) {
        self.shouldSucceed = shouldSucceed
    }

    func authenticate(reason: String) async -> Bool {
        callCount += 1
        return shouldSucceed
    }
}

private actor FetchCounter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}

@MainActor
private final class TestNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func waitForFinish() async {
        if finished { return }
        await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }
}
