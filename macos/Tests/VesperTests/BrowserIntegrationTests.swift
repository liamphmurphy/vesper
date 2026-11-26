import AppKit
import Testing
import VesperCore
import WebKit
@testable import Vesper

@MainActor
@Suite("Internal Browser Shell & Isolation")
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

    @Test("Browser web views isolate cookies from Vesper's default store and use standard Safari UA")
    func webViewIsolationAndUserAgent() {
        let regular = BrowserWebViewFactory.makeWebView(isPrivate: false, contentRuleList: nil)
        let priv = BrowserWebViewFactory.makeWebView(isPrivate: true, contentRuleList: nil)

        #expect(regular.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(regular.configuration.websiteDataStore === BrowserWebViewFactory.persistentStore)
        #expect(regular.configuration.websiteDataStore.isPersistent)
        #expect(!priv.configuration.websiteDataStore.isPersistent)

        let ua = regular.customUserAgent ?? ""
        #expect(ua.contains("Safari/"))
        #expect(!ua.contains("VesperMac"))
    }

    @Test("MainMenu registers Browser Cmd+Ctrl+1..9 and Cmd+L shortcuts")
    func menuRegistersBrowserShortcuts() {
        let delegate = AppDelegate()
        let menu = MainMenu.build(delegate: delegate)
        let browserMenu = menu.items.first(where: { $0.title == "Browser" })?.submenu
        #expect(browserMenu != nil)

        let items = browserMenu?.items ?? []
        let focus = items.first(where: { $0.action == #selector(AppDelegate.focusBrowserAddressBar(_:)) })
        #expect(focus?.keyEquivalent == "l")
        #expect(focus?.keyEquivalentModifierMask == [.command])

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
