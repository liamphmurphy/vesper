import XCTest
@testable import VesperCore

final class BrowserTier2LogicTests: XCTestCase {

    // MARK: - Tier 1 -> Tier 2 Profile Migration & Storage

    func testTier1PersistedStateMigratesIntoDefaultPersonalProfile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-browser-tier2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = BrowserStorage.fileURL(dataDirectory: dir)

        let tabId = UUID()
        let tier1JSON = """
        {
          "active_tab_id": "\(tabId.uuidString)",
          "ad_block_disabled_hosts": ["docs.example.com"],
          "ad_block_enabled": true,
          "bookmarks": [
            { "createdAt": "2026-11-26T00:00:00Z", "id": "b1", "title": "Swift", "url": "https://swift.org" }
          ],
          "history": [],
          "open_external_links_in_browser": true,
          "search_engine": "kagi",
          "site_zooms": { "swift.org": 1.2 },
          "tabs": [
            { "id": "\(tabId.uuidString)", "isPinned": true, "isPrivate": false, "title": "Swift", "url": "https://swift.org", "zoom": 1.2 }
          ]
        }
        """
        try Data(tier1JSON.utf8).write(to: file)

        let loaded = BrowserStorage.load(from: file)
        XCTAssertEqual(loaded.profiles.count, 1)
        let personal = try XCTUnwrap(loaded.profiles.first)
        XCTAssertEqual(personal.name, "Personal")
        XCTAssertEqual(personal.dataStoreID, BrowserProfile.defaultDataStoreID)
        XCTAssertEqual(personal.tabs.count, 1)
        XCTAssertEqual(personal.tabs[0].id, tabId)
        XCTAssertEqual(personal.bookmarks.count, 1)
        XCTAssertEqual(personal.siteZooms["swift.org"], 1.2)
        XCTAssertEqual(personal.adBlockDisabledHosts, ["docs.example.com"])
        XCTAssertEqual(loaded.searchEngine, .kagi)
    }

    func testMultiProfilePersistenceStripsPrivateTabsAndOrphanGroupsAcrossProfiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-browser-multi-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = BrowserStorage.fileURL(dataDirectory: dir)

        let validGroup = BrowserTabGroup(name: "Docs", color: .teal)
        let orphanGroupID = UUID()
        let pub1 = BrowserTabRecord(url: "https://a.com", title: "A", groupId: validGroup.id)
        let pub2 = BrowserTabRecord(url: "https://b.com", title: "B", groupId: orphanGroupID)
        let priv = BrowserTabRecord(url: "https://secret.com", title: "Private", isPrivate: true)

        let personal = BrowserProfile.defaultPersonal(tabs: [pub1, priv], activeTabId: priv.id)
        let work = BrowserProfile(
            name: "Work",
            icon: "briefcase.fill",
            color: .purple,
            tabs: [pub1, pub2, priv],
            activeTabId: pub1.id,
            splitTabId: priv.id,
            splitRatio: 0.95,
            tabGroups: [validGroup]
        )

        let state = BrowserPersistedState(profiles: [personal, work], activeProfileId: work.id, autofillEnabled: true)
        try BrowserStorage.save(state, to: file)

        let loaded = BrowserStorage.load(from: file)
        XCTAssertEqual(loaded.profiles.count, 2)
        XCTAssertEqual(loaded.activeProfileId, work.id)

        let loadedPersonal = try XCTUnwrap(loaded.profiles.first(where: { $0.id == personal.id }))
        XCTAssertEqual(loadedPersonal.tabs.map(\.id), [pub1.id])
        XCTAssertEqual(loadedPersonal.activeTabId, pub1.id)

        let loadedWork = try XCTUnwrap(loaded.profiles.first(where: { $0.id == work.id }))
        XCTAssertEqual(loadedWork.tabs.map(\.id), [pub1.id, pub2.id])
        XCTAssertEqual(loadedWork.tabs[0].groupId, validGroup.id)
        XCTAssertNil(loadedWork.tabs[1].groupId)
        XCTAssertNil(loadedWork.splitTabId) // private tab stripped -> split cleared
        XCTAssertEqual(loadedWork.splitRatio, 0.8, accuracy: 0.001) // clamped to [0.2, 0.8]
    }

    func testProfileCreationGuaranteesUniqueDataStoreAndDeletionGuard() {
        let personal = BrowserProfile.defaultPersonal()
        let work = BrowserProfileLogic.makeProfile(name: "Work", icon: "briefcase.fill", color: .orange, existing: [personal])
        XCTAssertNotEqual(work.dataStoreID, personal.dataStoreID)
        XCTAssertNotEqual(work.dataStoreID, BrowserProfile.defaultDataStoreID)
        XCTAssertFalse(BrowserProfileLogic.canDeleteProfile(id: personal.id, in: [personal]))
        XCTAssertTrue(BrowserProfileLogic.canDeleteProfile(id: work.id, in: [personal, work]))
    }

    // MARK: - Tab Groups, Reordering & Split View

    func testTabGroupDisplayOrderAndMove() {
        let g1 = BrowserTabGroup(name: "Research", color: .blue)
        let g2 = BrowserTabGroup(name: "PRs", color: .green)
        let pinned = BrowserTabRecord(url: "https://p.com", title: "Pin", isPinned: true)
        let ungrouped = BrowserTabRecord(url: "https://u.com", title: "Free")
        let inG2 = BrowserTabRecord(url: "https://g2.com", title: "G2", groupId: g2.id)
        let inG1 = BrowserTabRecord(url: "https://g1.com", title: "G1", groupId: g1.id)

        let ordered = BrowserTabGroupLogic.displayOrder(
            tabs: [ungrouped, inG2, pinned, inG1],
            groups: [g1, g2],
            isPinned: \.isPinned,
            groupId: \.groupId
        )
        XCTAssertEqual(ordered.map(\.title), ["Pin", "G1", "G2", "Free"])

        let moved = BrowserTabGroupLogic.move(inG1.id, before: ungrouped.id, in: [ungrouped, inG2, inG1])
        XCTAssertEqual(moved.map(\.title), ["G1", "Free", "G2"])
    }

    func testSplitViewTransitionsOnOpenSwapAndClose() {
        let a = UUID()
        let b = UUID()
        let c = UUID()

        let initial = BrowserSplitState(primaryTabId: a, secondaryTabId: nil, ratio: 0.4)
        XCTAssertFalse(initial.isSplit)

        // Cannot split a tab with itself.
        let same = BrowserTabGroupLogic.openInSplit(tabId: a, current: initial)
        XCTAssertFalse(same.isSplit)

        let split = BrowserTabGroupLogic.openInSplit(tabId: b, current: initial)
        XCTAssertTrue(split.isSplit)
        XCTAssertEqual(split.primaryTabId, a)
        XCTAssertEqual(split.secondaryTabId, b)

        let swapped = BrowserTabGroupLogic.swapPanes(split)
        XCTAssertEqual(swapped.primaryTabId, b)
        XCTAssertEqual(swapped.secondaryTabId, a)
        XCTAssertEqual(swapped.ratio, 0.6, accuracy: 0.001)

        // Closing primary promotes secondary and exits split.
        let afterPrimaryClosed = BrowserTabGroupLogic.reconcileSplitAfterClose(
            closedTabId: b,
            state: swapped,
            remainingTabIds: [a, c]
        )
        XCTAssertFalse(afterPrimaryClosed.isSplit)
        XCTAssertEqual(afterPrimaryClosed.primaryTabId, a)
        XCTAssertNil(afterPrimaryClosed.secondaryTabId)

        // Closing secondary keeps primary and exits split.
        let afterSecondaryClosed = BrowserTabGroupLogic.reconcileSplitAfterClose(
            closedTabId: b,
            state: split,
            remainingTabIds: [a, c]
        )
        XCTAssertFalse(afterSecondaryClosed.isSplit)
        XCTAssertEqual(afterSecondaryClosed.primaryTabId, a)
    }

    // MARK: - AutoFill Origin Security, Matching & Password Generator

    func testAutofillOriginSecurityAndDomainMatching() {
        XCTAssertTrue(BrowserAutofillLogic.isSecureAutofillOrigin("https://github.com/login"))
        XCTAssertTrue(BrowserAutofillLogic.isSecureAutofillOrigin("http://localhost:3000/login"))
        XCTAssertTrue(BrowserAutofillLogic.isSecureAutofillOrigin("http://127.0.0.1:8080/auth"))
        XCTAssertFalse(BrowserAutofillLogic.isSecureAutofillOrigin("http://github.com/login"))
        XCTAssertFalse(BrowserAutofillLogic.isSecureAutofillOrigin("file:///tmp/login.html"))

        XCTAssertEqual(BrowserAutofillLogic.domainGroup(for: "accounts.github.com"), "github.com")
        XCTAssertEqual(BrowserAutofillLogic.domainGroup(for: "login.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(BrowserAutofillLogic.domainGroup(for: "127.0.0.1"), "127.0.0.1")

        let now = Date()
        let creds = [
            BrowserCredential(host: "github.com", username: "root", password: "p1", updatedAt: now),
            BrowserCredential(host: "gist.github.com", username: "gist-user", password: "p2", updatedAt: now.addingTimeInterval(10)),
            BrowserCredential(host: "gitlab.com", username: "other", password: "p3", updatedAt: now),
        ]

        // Exact host match ranks first, sibling subdomain second, unrelated excluded.
        let matches = BrowserAutofillLogic.matchingCredentials(for: "https://github.com/session", in: creds)
        XCTAssertEqual(matches.map(\.username), ["root", "gist-user"])

        // Remote plain HTTP never returns credentials.
        XCTAssertTrue(BrowserAutofillLogic.matchingCredentials(for: "http://github.com/session", in: creds).isEmpty)
    }

    func testAutofillSavePromptRespectsPrivateModeNeverSaveAndUpdates() {
        let existing = [
            BrowserCredential(id: "c1", host: "github.com", username: "liam", password: "old-password")
        ]

        // Private tabs never prompt.
        XCTAssertNil(BrowserAutofillLogic.evaluateSavePrompt(
            urlString: "https://github.com/login",
            username: "liam",
            password: "new-password",
            isPrivate: true,
            autofillEnabled: true,
            neverSaveHosts: [],
            existing: existing
        ))

        // Never-save hosts suppress prompts.
        XCTAssertNil(BrowserAutofillLogic.evaluateSavePrompt(
            urlString: "https://sub.bank.com/login",
            username: "liam",
            password: "secret",
            isPrivate: false,
            autofillEnabled: true,
            neverSaveHosts: ["bank.com"],
            existing: []
        ))

        // Unchanged password does not prompt.
        XCTAssertNil(BrowserAutofillLogic.evaluateSavePrompt(
            urlString: "https://github.com/login",
            username: "liam",
            password: "old-password",
            isPrivate: false,
            autofillEnabled: true,
            neverSaveHosts: [],
            existing: existing
        ))

        // Changed password produces an update prompt referencing existing id.
        let update = BrowserAutofillLogic.evaluateSavePrompt(
            urlString: "https://github.com/login",
            username: "liam",
            password: "new-password",
            isPrivate: false,
            autofillEnabled: true,
            neverSaveHosts: [],
            existing: existing
        )
        XCTAssertEqual(update?.existingCredentialId, "c1")
        XCTAssertEqual(update?.isUpdate, true)

        // New user produces a create prompt.
        let create = BrowserAutofillLogic.evaluateSavePrompt(
            urlString: "https://example.com/login",
            username: "judy@nightcity.net",
            password: "pw",
            isPrivate: false,
            autofillEnabled: true,
            neverSaveHosts: [],
            existing: existing
        )
        XCTAssertNotNil(create)
        XCTAssertEqual(create?.isUpdate, false)
    }

    func testPasswordGeneratorGuaranteesLengthAndCharacterClasses() {
        let pw = BrowserAutofillLogic.generateStrongPassword(length: 24, includeSymbols: true)
        XCTAssertEqual(pw.count, 24)
        XCTAssertTrue(pw.contains(where: \.isUppercase))
        XCTAssertTrue(pw.contains(where: \.isLowercase))
        XCTAssertTrue(pw.contains(where: \.isNumber))
        XCTAssertTrue(pw.contains(where: { "!@#$%^&*-_=+".contains($0) }))

        let noSym = BrowserAutofillLogic.generateStrongPassword(length: 16, includeSymbols: false)
        XCTAssertEqual(noSym.count, 16)
        XCTAssertFalse(noSym.contains(where: { "!@#$%^&*-_=+".contains($0) }))
    }

    // MARK: - WebExtension Manifest Validation

    func testExtensionManifestValidation() throws {
        let validMV3 = Data(#"{"manifest_version":3,"name":"Dark Reader","version":"4.9.1","permissions":["storage","activeTab"],"host_permissions":["<all_urls>"]}"#.utf8)
        let summary = try BrowserExtensionLogic.parseManifest(data: validMV3)
        XCTAssertEqual(summary.name, "Dark Reader")
        XCTAssertEqual(summary.version, "4.9.1")
        XCTAssertEqual(summary.manifestVersion, 3)
        XCTAssertEqual(summary.permissions, ["storage", "activeTab"])
        XCTAssertEqual(summary.hostPermissions, ["<all_urls>"])

        let badVersion = Data(#"{"manifest_version":1,"name":"Ancient"}"#.utf8)
        XCTAssertThrowsError(try BrowserExtensionLogic.parseManifest(data: badVersion)) { err in
            XCTAssertEqual(err as? BrowserExtensionValidationError, .unsupportedManifestVersion(1))
        }

        let missingName = Data(#"{"manifest_version":3,"version":"1.0"}"#.utf8)
        XCTAssertThrowsError(try BrowserExtensionLogic.parseManifest(data: missingName)) { err in
            XCTAssertEqual(err as? BrowserExtensionValidationError, .missingName)
        }
    }
}
