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
        let regular = BrowserWebViewFactory.makeWebView(isPrivate: false, contentRuleList: nil)
        let priv = BrowserWebViewFactory.makeWebView(isPrivate: true, contentRuleList: nil)
        let workStoreID = UUID()
        let work = BrowserWebViewFactory.makeWebView(
            isPrivate: false,
            profileDataStoreID: workStoreID,
            contentRuleList: nil
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
            contentRuleList: nil,
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
}
