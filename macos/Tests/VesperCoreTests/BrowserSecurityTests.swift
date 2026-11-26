import Foundation
import Testing
@testable import VesperCore

@Suite("Browser Security Hardening Logic")
struct BrowserSecurityTests {
    @Test("IDN guard flags punycode, mixed-script homographs, whole-script lookalikes, and bidi controls")
    func idnHomographDetection() {
        let normal = BrowserIDNGuard.inspect(urlString: "https://www.github.com/liamphmurphy/vesper")
        #expect(!normal.isSuspiciousIDN)
        #expect(normal.displayHost == "github.com")

        let punycode = BrowserIDNGuard.inspect(urlString: "https://xn--pple-43d.com/login")
        #expect(punycode.isSuspiciousIDN)
        #expect(punycode.displayHost == "xn--pple-43d.com")
        #expect(punycode.warningReason != nil)

        // Mixed Latin 'a' + Cyrillic 'а' (U+0430)
        let mixed = BrowserIDNGuard.inspect(host: "p\u{0430}ypal.com")
        #expect(mixed.isSuspiciousIDN)

        // Whole-label Cyrillic confusables mimicking "apple"
        let wholeLookalike = BrowserIDNGuard.inspect(host: "\u{0430}\u{0440}\u{0440}\u{0435}.com")
        #expect(wholeLookalike.isSuspiciousIDN)

        // Zero-width space / bidi override
        let bidi = BrowserIDNGuard.inspect(host: "bank\u{202E}moc.com")
        #expect(bidi.isSuspiciousIDN)
    }

    @Test("Tracking parameter stripper removes cross-site trackers while preserving OAuth and normal query params")
    func trackingParameterStripping() throws {
        let tracked = try #require(URL(string: "https://example.com/article?id=42&utm_source=newsletter&utm_medium=email&fbclid=IwAR123&gclid=abc"))
        let result = BrowserTrackingParamStripper.strip(from: tracked)
        #expect(result.removedCount == 4)
        #expect(result.url.absoluteString == "https://example.com/article?id=42")

        let onlyTracking = try #require(URL(string: "https://example.com/page?fbclid=xyz&mc_eid=999"))
        let strippedAll = BrowserTrackingParamStripper.strip(from: onlyTracking)
        #expect(strippedAll.removedCount == 2)
        #expect(strippedAll.url.absoluteString == "https://example.com/page")

        let oauth = try #require(URL(string: "https://auth.example.com/callback?code=123&state=xyz&redirect_uri=https%3A%2F%2Fapp.example.com"))
        let untouched = BrowserTrackingParamStripper.strip(from: oauth)
        #expect(untouched.removedCount == 0)
        #expect(untouched.url == oauth)
    }

    @Test("HTTPS-Only guard upgrades remote HTTP while exempting localhost, RFC1918 LAN, and user exceptions")
    func httpsOnlyUpgradesAndExemptions() throws {
        let remote = try #require(URL(string: "http://example.com:80/docs?q=1"))
        let upgraded = BrowserHTTPSGuard.upgradedHTTPSURL(for: remote, httpsOnlyEnabled: true, exceptions: [])
        #expect(upgraded?.absoluteString == "https://example.com/docs?q=1")

        let disabled = BrowserHTTPSGuard.upgradedHTTPSURL(for: remote, httpsOnlyEnabled: false, exceptions: [])
        #expect(disabled == nil)

        let excepted = BrowserHTTPSGuard.upgradedHTTPSURL(for: remote, httpsOnlyEnabled: true, exceptions: ["example.com"])
        #expect(excepted == nil)

        let localhost = try #require(URL(string: "http://localhost:3000/app"))
        #expect(BrowserHTTPSGuard.upgradedHTTPSURL(for: localhost, httpsOnlyEnabled: true, exceptions: []) == nil)

        let lan = try #require(URL(string: "http://192.168.1.50:8080/"))
        #expect(BrowserHTTPSGuard.upgradedHTTPSURL(for: lan, httpsOnlyEnabled: true, exceptions: []) == nil)

        let dotLocal = try #require(URL(string: "http://nas.local/"))
        #expect(BrowserHTTPSGuard.upgradedHTTPSURL(for: dotLocal, httpsOnlyEnabled: true, exceptions: []) == nil)
    }

    @Test("Top-level data: navigations are blocked when enabled, while subframes and web URLs are allowed")
    func topLevelDataNavigationGuard() throws {
        let dataURL = try #require(URL(string: "data:text/html,<script>alert(1)</script>"))
        #expect(BrowserHTTPSGuard.shouldBlockNavigation(url: dataURL, isMainFrame: true, blockTopLevelData: true))
        #expect(!BrowserHTTPSGuard.shouldBlockNavigation(url: dataURL, isMainFrame: false, blockTopLevelData: true))
        #expect(!BrowserHTTPSGuard.shouldBlockNavigation(url: dataURL, isMainFrame: true, blockTopLevelData: false))

        let httpsURL = try #require(URL(string: "https://example.com/"))
        #expect(!BrowserHTTPSGuard.shouldBlockNavigation(url: httpsURL, isMainFrame: true, blockTopLevelData: true))
    }

    @Test("Download guard flags executable and installer file extensions")
    func riskyDownloadDetection() {
        #expect(BrowserDownloadGuard.isRiskyFilename("Installer.dmg"))
        #expect(BrowserDownloadGuard.isRiskyFilename("update.pkg"))
        #expect(BrowserDownloadGuard.isRiskyFilename("run.command"))
        #expect(BrowserDownloadGuard.isRiskyFilename("profile.mobileconfig"))
        #expect(BrowserDownloadGuard.riskWarning(for: "setup.sh") != nil)

        #expect(!BrowserDownloadGuard.isRiskyFilename("report.pdf"))
        #expect(!BrowserDownloadGuard.isRiskyFilename("photo.png"))
        #expect(BrowserDownloadGuard.riskWarning(for: "notes.txt") == nil)
    }

    @Test("Connection security, per-site lockdown, and JavaScript toggles evaluate accurately")
    func connectionSecurityAndSiteControls() {
        #expect(BrowserHTTPSGuard.connectionSecurity(urlString: "https://example.com", hasOnlySecureContent: true, tlsError: nil) == .secure)
        #expect(BrowserHTTPSGuard.connectionSecurity(urlString: "https://example.com", hasOnlySecureContent: false, tlsError: nil) == .mixedContent)
        #expect(BrowserHTTPSGuard.connectionSecurity(urlString: "http://example.com", hasOnlySecureContent: false, tlsError: nil) == .insecureHTTP)
        #expect(BrowserHTTPSGuard.connectionSecurity(urlString: "http://127.0.0.1:8000", hasOnlySecureContent: false, tlsError: nil) == .localHTTP)
        #expect(BrowserHTTPSGuard.connectionSecurity(urlString: "https://bad.example", hasOnlySecureContent: false, tlsError: "Untrusted") == .tlsError("Untrusted"))

        #expect(BrowserHTTPSGuard.isLockdownActive(for: "https://risky.example", globalEnabled: false, enabledHosts: ["risky.example"], disabledHosts: []))
        #expect(!BrowserHTTPSGuard.isLockdownActive(for: "https://trusted.example", globalEnabled: true, enabledHosts: [], disabledHosts: ["trusted.example"]))
        #expect(!BrowserHTTPSGuard.isJavaScriptAllowed(for: "https://news.example/story", disabledHosts: ["news.example"]))
        #expect(BrowserHTTPSGuard.isJavaScriptAllowed(for: "https://app.example", disabledHosts: ["news.example"]))
    }

    @Test("AutoFill blocks mixed-content HTTPS and parses Apple Passwords CSV exports")
    func autofillMixedContentAndCSVImport() {
        #expect(BrowserAutofillLogic.canAutofill(urlString: "https://github.com/login", hasOnlySecureContent: true))
        #expect(!BrowserAutofillLogic.canAutofill(urlString: "https://github.com/login", hasOnlySecureContent: false))
        #expect(BrowserAutofillLogic.canAutofill(urlString: "http://localhost:3000/login", hasOnlySecureContent: false))
        #expect(!BrowserAutofillLogic.canAutofill(urlString: "http://example.com/login", hasOnlySecureContent: false))

        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        GitHub,https://github.com/login,liam@example.com,"s3cr3t,pass",work,
        Linear,https://linear.app,liam,"another""pass",,
        Duplicate,https://github.com,liam@example.com,ignored,,
        """
        let creds = BrowserAutofillLogic.parseApplePasswordsCSV(csv)
        #expect(creds.count == 2)
        #expect(creds[0].host == "github.com")
        #expect(creds[0].username == "liam@example.com")
        #expect(creds[0].password == "s3cr3t,pass")
        #expect(creds[1].host == "linear.app")
        #expect(creds[1].password == "another\"pass")
    }

    @Test("Safari User-Agent aligns with macOS 26+ without stale 18.4 mismatch")
    func safariUserAgentAlignment() {
        let ua26 = BrowserUserAgent.safariUserAgent(osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0))
        #expect(ua26.contains("Version/26.1 Safari/605.1.15"))
        #expect(!ua26.contains("Version/18.4"))
    }

    @Test("BrowserStorage round-trips security config, site permissions, and per-profile proxy config")
    func persistenceRoundTripForSecurityAndProxy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-browser-sec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = BrowserStorage.fileURL(dataDirectory: tempDir)

        var profile = BrowserProfile.defaultPersonal()
        profile.httpsOnlyExceptions = ["legacy.internal"]
        profile.lockdownEnabledHosts = ["untrusted.example"]
        profile.javascriptDisabledHosts = ["nojssite.example"]
        profile.sitePermissions = [
            "meet.example.com": [
                BrowserPermissionKind.camera.rawValue: .allow,
                BrowserPermissionKind.microphone.rawValue: .allow,
            ],
        ]
        profile.proxyConfig = BrowserProxyConfig(mode: .socks5, host: "127.0.0.1", port: 1080, applyToPrivateTabs: true)

        let state = BrowserPersistedState(
            profiles: [profile],
            activeProfileId: profile.id,
            securityConfig: BrowserSecurityConfig(
                httpsOnlyMode: true,
                lockdownModeEnabled: false,
                stripTrackingParameters: true,
                requireTouchIDForAutofill: true,
                confirmDownloads: true,
                blockTopLevelDataNavigations: true
            )
        )
        try BrowserStorage.save(state, to: fileURL)
        let loaded = BrowserStorage.load(from: fileURL)

        #expect(loaded.securityConfig.httpsOnlyMode == true)
        #expect(loaded.securityConfig.requireTouchIDForAutofill == true)
        let loadedProfile = try #require(loaded.profiles.first)
        #expect(loadedProfile.httpsOnlyExceptions == ["legacy.internal"])
        #expect(loadedProfile.lockdownEnabledHosts == ["untrusted.example"])
        #expect(loadedProfile.javascriptDisabledHosts == ["nojssite.example"])
        #expect(loadedProfile.sitePermissions["meet.example.com"]?[BrowserPermissionKind.camera.rawValue] == .allow)
        #expect(loadedProfile.proxyConfig == BrowserProxyConfig(mode: .socks5, host: "127.0.0.1", port: 1080, applyToPrivateTabs: true))
    }
}
