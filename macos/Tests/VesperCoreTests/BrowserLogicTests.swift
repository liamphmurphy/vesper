import XCTest
@testable import VesperCore

final class BrowserLogicTests: XCTestCase {

    // MARK: - URL Resolution

    func testOmniboxResolvesURLsAndSearches() {
        XCTAssertEqual(
            BrowserURLResolver.resolve("https://github.com/liamphmurphy/vesper")?.absoluteString,
            "https://github.com/liamphmurphy/vesper"
        )
        XCTAssertEqual(
            BrowserURLResolver.resolve("github.com/liamphmurphy/vesper")?.absoluteString,
            "https://github.com/liamphmurphy/vesper"
        )
        XCTAssertEqual(
            BrowserURLResolver.resolve("localhost:3000/api")?.absoluteString,
            "http://localhost:3000/api"
        )
        XCTAssertEqual(
            BrowserURLResolver.resolve("127.0.0.1:8000")?.absoluteString,
            "http://127.0.0.1:8000"
        )
        XCTAssertEqual(
            BrowserURLResolver.resolve("swift wkwebview snapshot", searchEngine: .duckDuckGo)?.absoluteString,
            "https://duckduckgo.com/?q=swift%20wkwebview%20snapshot"
        )
        XCTAssertEqual(
            BrowserURLResolver.resolve("vesper", searchEngine: .kagi)?.absoluteString,
            "https://kagi.com/search?q=vesper"
        )
        XCTAssertNil(BrowserURLResolver.resolve("   \n\t  "))
    }

    func testOmniboxBlocksDangerousSchemes() {
        let js = BrowserURLResolver.resolve("javascript:alert(1)", searchEngine: .duckDuckGo)
        XCTAssertEqual(js?.host, "duckduckgo.com")

        let file = BrowserURLResolver.resolve("file:///etc/passwd", searchEngine: .duckDuckGo)
        XCTAssertEqual(file?.host, "duckduckgo.com")

        let data = BrowserURLResolver.resolve("data:text/html,<h1>hi</h1>", searchEngine: .duckDuckGo)
        XCTAssertEqual(data?.host, "duckduckgo.com")
    }

    func testDisplayHostAndAddress() {
        XCTAssertEqual(BrowserURLResolver.displayHost(for: "https://www.github.com/a/b"), "github.com")
        XCTAssertEqual(BrowserURLResolver.displayHost(for: "http://localhost:8080/health"), "localhost:8080")
        XCTAssertEqual(BrowserURLResolver.displayAddress(for: "https://www.example.com/"), "example.com")
        XCTAssertEqual(BrowserURLResolver.displayAddress(for: "https://docs.swift.org/swift-book/"), "docs.swift.org/swift-book")
    }

    // MARK: - Page Privacy & Redaction

    func testShareablePageEnforcesPrivateAndNeverShare() {
        let lists = BrowserNeverShareLists(builtin: ["1password.com", "chase.com"], mine: ["mybank.local"])

        let privateCheck = BrowserPageGuard.shareablePage(url: "https://example.com", isPrivate: true, neverShare: lists)
        XCTAssertFalse(privateCheck.ok)

        let builtinCheck = BrowserPageGuard.shareablePage(url: "https://my.1password.com/vault", isPrivate: false, neverShare: lists)
        XCTAssertFalse(builtinCheck.ok)
        XCTAssertFalse(builtinCheck.isUserBlocked)
        XCTAssertEqual(builtinCheck.host, "my.1password.com")

        let mineCheck = BrowserPageGuard.shareablePage(url: "https://www.mybank.local/account", isPrivate: false, neverShare: lists)
        XCTAssertFalse(mineCheck.ok)
        XCTAssertTrue(mineCheck.isUserBlocked)

        let credsCheck = BrowserPageGuard.shareablePage(url: "https://user:pass@example.com", isPrivate: false, neverShare: lists)
        XCTAssertFalse(credsCheck.ok)

        let okCheck = BrowserPageGuard.shareablePage(url: "https://www.github.com/liamphmurphy/vesper", isPrivate: false, neverShare: lists)
        XCTAssertTrue(okCheck.ok)
        XCTAssertEqual(okCheck.host, "github.com")
    }

    func testSamePageIgnoresFragment() {
        XCTAssertTrue(BrowserPageGuard.samePage("https://example.com/docs#intro", "https://example.com/docs#api"))
        XCTAssertFalse(BrowserPageGuard.samePage("https://example.com/docs?v=1", "https://example.com/docs?v=2"))
    }

    func testRedactCardNumbers() {
        // Valid Luhn test Visa (4111...) and non-Luhn number should be handled accurately.
        let input = "Pay 4111 1111 1111 1111 or ref 1234567890123456."
        let redacted = BrowserPageGuard.redactCardNumbers(input)
        XCTAssertEqual(redacted, "Pay [card number removed] or ref 1234567890123456.")
    }

    func testSiteActionsForGitHubAndYouTube() {
        let personas = [
            BrowserExtensionPersona(id: "p1", name: "Judy", isDefault: true),
            BrowserExtensionPersona(id: "p2", name: "Code Reviewer", isDefault: false),
        ]
        let prActions = BrowserPageGuard.siteActions(url: "https://github.com/liamphmurphy/vesper/pull/42", personas: personas)
        XCTAssertEqual(prActions.map(\.id), ["review-pr", "ticket-from-pr"])
        XCTAssertEqual(prActions.first?.personaId, "p2")

        let ytActions = BrowserPageGuard.siteActions(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", personas: personas)
        XCTAssertEqual(ytActions.map(\.id), ["video-notes"])
        XCTAssertEqual(ytActions.first?.personaId, "p1")
    }

    // MARK: - Tab Ordering, Shortcuts, History & Suggestions

    func testNumberedTabShortcutsAndDisplayOrder() {
        let t1 = BrowserTabRecord(url: "https://a.com", title: "A", isPinned: false)
        let t2 = BrowserTabRecord(url: "https://b.com", title: "B", isPinned: true)
        let t3 = BrowserTabRecord(url: "https://c.com", title: "C", isPinned: false)
        let ordered = BrowserTabListLogic.displayOrder([t1, t2, t3], isPinned: \.isPinned)
        XCTAssertEqual(ordered.map(\.title), ["B", "A", "C"])

        XCTAssertEqual(BrowserTabListLogic.indexForNumberedShortcut(1, count: 3), 0)
        XCTAssertEqual(BrowserTabListLogic.indexForNumberedShortcut(3, count: 3), 2)
        XCTAssertNil(BrowserTabListLogic.indexForNumberedShortcut(4, count: 3))
        XCTAssertEqual(BrowserTabListLogic.indexForNumberedShortcut(9, count: 3), 2) // 9 = last tab
        XCTAssertEqual(BrowserTabListLogic.nextIndex(after: 2, count: 3), 0)
        XCTAssertEqual(BrowserTabListLogic.previousIndex(before: 0, count: 3), 2)
    }

    func testHistoryUpsertAndCap() {
        let d1 = Date(timeIntervalSince1970: 1000)
        let d2 = Date(timeIntervalSince1970: 2000)
        var history: [BrowserHistoryEntry] = []
        history = BrowserTabListLogic.recordVisit(url: "https://a.com", title: "A", at: d1, in: history, limit: 2)
        history = BrowserTabListLogic.recordVisit(url: "https://b.com", title: "B", at: d1, in: history, limit: 2)
        history = BrowserTabListLogic.recordVisit(url: "https://a.com", title: "A Updated", at: d2, in: history, limit: 2)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].url, "https://a.com")
        XCTAssertEqual(history[0].title, "A Updated")
        XCTAssertEqual(history[0].visitCount, 2)

        history = BrowserTabListLogic.recordVisit(url: "https://c.com", title: "C", at: d2, in: history, limit: 2)
        XCTAssertEqual(history.map(\.url), ["https://c.com", "https://a.com"])
    }

    func testOmniboxSuggestionsDeduplicateAndRank() {
        let open = [BrowserTabRecord(url: "https://swift.org", title: "Swift.org")]
        let bookmarks = [
            BrowserBookmark(url: "https://swift.org", title: "Swift Bookmark"),
            BrowserBookmark(url: "https://docs.swift.org", title: "Swift Docs"),
        ]
        let saved = [(id: "s1", title: "Swift Concurrency Guide", url: "https://example.com/swift", site: "example.com")]
        let history = [BrowserHistoryEntry(url: "https://forums.swift.org", title: "Swift Forums")]

        let suggestions = BrowserTabListLogic.suggestions(
            query: "swift",
            openTabs: open,
            bookmarks: bookmarks,
            savedLinks: saved,
            history: history
        )
        XCTAssertEqual(suggestions.map(\.kind), [.openTab, .bookmark, .savedLink, .history])
        XCTAssertEqual(suggestions[0].url, "https://swift.org")
        XCTAssertEqual(suggestions[1].url, "https://docs.swift.org")
    }

    // MARK: - Persistence & Content Blocker

    func testStorageStripsPrivateTabsOnSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vesper-browser-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = BrowserStorage.fileURL(dataDirectory: dir)

        let pub = BrowserTabRecord(url: "https://example.com", title: "Example", isPrivate: false)
        let priv = BrowserTabRecord(url: "https://secret.example.com", title: "Secret", isPrivate: true)
        let state = BrowserPersistedState(
            tabs: [pub, priv],
            activeTabId: priv.id,
            bookmarks: [BrowserBookmark(url: "https://swift.org", title: "Swift")],
            adBlockEnabled: true,
            adBlockDisabledHosts: ["example.com"]
        )
        try BrowserStorage.save(state, to: file)

        let loaded = BrowserStorage.load(from: file)
        XCTAssertEqual(loaded.tabs, [pub])
        XCTAssertEqual(loaded.activeTabId, pub.id)
        XCTAssertEqual(loaded.bookmarks.count, 1)
        XCTAssertEqual(loaded.adBlockDisabledHosts, ["example.com"])
    }

    func testContentBlockerRuleJSONIsValidAndAppliesExclusions() throws {
        let json = BrowserContentBlockerRules.ruleListJSON(disabledHosts: ["www.Example.com"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 1)
        let trigger = try XCTUnwrap(parsed[0]["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["unless-domain"] as? [String], ["*example.com"])

        XCTAssertFalse(BrowserContentBlockerRules.isAdBlockActive(globalEnabled: true, host: "sub.example.com", disabledHosts: ["example.com"]))
        XCTAssertTrue(BrowserContentBlockerRules.isAdBlockActive(globalEnabled: true, host: "other.com", disabledHosts: ["example.com"]))
        XCTAssertFalse(BrowserContentBlockerRules.isAdBlockActive(globalEnabled: false, host: "other.com", disabledHosts: []))
    }

    func testScreenshotNoteAndQuoteFormatting() {
        let body = BrowserKnowledgeFormatter.screenshotNoteBody(
            title: "Vesper Repo",
            url: "https://github.com/liamphmurphy/vesper",
            assetRef: "browser-shot.png",
            caption: "Look at this layout"
        )
        XCTAssertTrue(body.contains("[Vesper Repo](https://github.com/liamphmurphy/vesper)"))
        XCTAssertTrue(body.contains("Look at this layout"))
        XCTAssertTrue(body.contains("![[browser-shot.png]]"))

        let quote = BrowserKnowledgeFormatter.markdownQuote(
            selection: "Line 1\nLine 2",
            title: "Docs",
            url: "https://example.com"
        )
        XCTAssertEqual(quote, "> Line 1\n> Line 2\n\n— [Docs](https://example.com)")
    }

    // MARK: - BrowserExtensionClient Retry on 401

    func testExtensionClientRetriesOnUnauthorized() async throws {
        let attempts = Counter()
        let transport: HTTPTransport = { req in
            let n = await attempts.next()
            let auth = req.value(forHTTPHeaderField: "Authorization")
            if n == 1 {
                XCTAssertEqual(auth, "Bearer stale-token")
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            XCTAssertEqual(auth, "Bearer fresh-token")
            let body = #"{"personas":[],"chats":[],"never_share":{"builtin":["1password.com"],"mine":[]},"shares":[]}"#
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let client = BrowserExtensionClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            transport: transport,
            tokenProvider: { forceRefresh in forceRefresh ? "fresh-token" : "stale-token" }
        )

        let config = try await client.fetchConfig()
        XCTAssertEqual(config.neverShare.builtin, ["1password.com"])
        let total = await attempts.count
        XCTAssertEqual(total, 2)
    }
}

private actor Counter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
