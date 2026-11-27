import Foundation
import Testing
@testable import VesperCore

@Suite("Browser × Vesper synergy (Knowledge backlinks, highlights, Spaces, multi-tab sharing)")
struct BrowserSynergyTests {
    @Test("BrowserURLNormalizer canonicalizes www, fragments, trailing slashes, and tracking params")
    func urlCanonicalization() {
        let a = BrowserURLNormalizer.canonicalPageKey(for: "https://www.Docs.Example.com/guide/?utm_source=hn&b=2&a=1#intro")
        let b = BrowserURLNormalizer.canonicalPageKey(for: "http://docs.example.com/guide?a=1&b=2&fbclid=xyz")
        #expect(a != nil)
        #expect(a == b)
        #expect(a == "https://docs.example.com/guide?a=1&b=2")

        #expect(BrowserURLNormalizer.canonicalPageKey(for: "about:blank") == nil)
        #expect(BrowserURLNormalizer.canonicalPageKey(for: "javascript:alert(1)") == nil)
        #expect(BrowserURLNormalizer.hostKey(for: "https://www.Example.org/path") == "example.org")
    }

    @Test("BrowserKnowledgeMatcher ranks exact page matches ahead of same-domain matches")
    func knowledgeBacklinkMatching() {
        let pages: [KnowledgePageRow] = [
            KnowledgePageRow(
                id: "p-domain",
                title: "GitHub Overview",
                path: "Clippings/GitHub Overview",
                properties: ["source": .string("https://github.com/other/repo")],
                updatedAt: "2026-11-27T05:00:00Z"
            ),
            KnowledgePageRow(
                id: "p-exact",
                title: "Vesper PR Review",
                path: "Vesper/PR Review",
                properties: ["source": .string("https://www.github.com/liamphmurphy/vesper/pull/718/?utm_medium=email#discussion")],
                updatedAt: "2026-11-26T12:00:00Z"
            ),
            KnowledgePageRow(
                id: "p-site-prop",
                title: "GitHub Notes",
                path: "Notes/GitHub",
                properties: ["source_site": .string("github.com")],
                updatedAt: "2026-11-27T06:00:00Z"
            ),
            KnowledgePageRow(
                id: "p-unrelated",
                title: "Unrelated",
                path: "Notes/Other",
                properties: ["source": .string("https://developer.apple.com/documentation")],
                updatedAt: "2026-11-27T06:00:00Z"
            ),
        ]

        let matches = BrowserKnowledgeMatcher.matchingPages(
            for: "https://github.com/liamphmurphy/vesper/pull/718",
            in: pages
        )
        #expect(matches.map(\.id) == ["p-exact", "p-site-prop", "p-domain"])
        #expect(matches.first?.matchKind == .exactURL)
        #expect(matches[1].matchKind == .sameDomain)
        #expect(matches[2].matchKind == .sameDomain)
    }

    @Test("BrowserHighlightFormatter builds initial literature notes and appends highlights cleanly")
    func highlightMarkdownFormatting() {
        let h1 = BrowserWebHighlight(
            url: "https://example.com/rfc",
            quote: "First key requirement\nSecond line",
            note: "Important constraint",
            color: .green
        )
        let firstBody = BrowserHighlightFormatter.appendHighlightMarkdown(
            existingBody: nil,
            pageTitle: "RFC 9999",
            pageURL: "https://example.com/rfc",
            highlight: h1
        )
        #expect(firstBody.contains("Source: [RFC 9999](https://example.com/rfc)"))
        #expect(firstBody.contains("## Highlights"))
        #expect(firstBody.contains("> First key requirement\n> Second line"))
        #expect(firstBody.contains("Important constraint"))
        #expect(firstBody.contains("vesper-highlight:\(h1.id.uuidString.lowercased())"))

        let h2 = BrowserWebHighlight(
            url: "https://example.com/rfc",
            quote: "Another passage",
            color: .blue
        )
        let appended = BrowserHighlightFormatter.appendHighlightMarkdown(
            existingBody: firstBody,
            pageTitle: "RFC 9999",
            pageURL: "https://example.com/rfc",
            highlight: h2
        )
        #expect(appended.components(separatedBy: "## Highlights").count == 2)
        #expect(appended.contains("> Another passage"))
        #expect(appended.contains("vesper-highlight:\(h2.id.uuidString.lowercased())"))
    }

    @Test("BrowserSpaceRoutingLogic resolves group-over-profile Space binding and smart clip folders")
    func spaceRoutingResolution() {
        let groupID = UUID()
        let unlinkedGroupID = UUID()
        let groups = [
            BrowserTabGroup(id: groupID, name: "Vesper Dev", color: .blue, spaceId: "space-vesper"),
            BrowserTabGroup(id: unlinkedGroupID, name: "Misc", color: .gray, spaceId: nil),
        ]

        let tabInLinkedGroup = BrowserTabRecord(url: "https://example.com", groupId: groupID)
        let tabInUnlinkedGroup = BrowserTabRecord(url: "https://example.com", groupId: unlinkedGroupID)
        let ungroupedTab = BrowserTabRecord(url: "https://example.com", groupId: nil)

        #expect(BrowserSpaceRoutingLogic.resolvedSpaceId(for: tabInLinkedGroup, tabGroups: groups, profileSpaceId: "space-profile") == "space-vesper")
        #expect(BrowserSpaceRoutingLogic.resolvedSpaceId(for: tabInUnlinkedGroup, tabGroups: groups, profileSpaceId: "space-profile") == "space-profile")
        #expect(BrowserSpaceRoutingLogic.resolvedSpaceId(for: ungroupedTab, tabGroups: groups, profileSpaceId: nil) == nil)

        let withDefaultFolder = BrowserSpaceSummary(
            id: "s1",
            name: "Vesper",
            personaId: "p-judy",
            defaultKnowledgeFolder: "/Vesper/Research/",
            firstKnowledgeFolder: "Vesper/Notes"
        )
        #expect(BrowserSpaceRoutingLogic.clipFolder(for: withDefaultFolder) == "Vesper/Research")

        let withFirstFolder = BrowserSpaceSummary(
            id: "s2",
            name: "Umbra",
            firstKnowledgeFolder: "Campaigns/Umbra"
        )
        #expect(BrowserSpaceRoutingLogic.clipFolder(for: withFirstFolder) == "Campaigns/Umbra")

        let withoutFolder = BrowserSpaceSummary(id: "s3", name: "Job Search")
        #expect(BrowserSpaceRoutingLogic.clipFolder(for: withoutFolder) == "Spaces/Job Search/Clippings")
        #expect(BrowserSpaceRoutingLogic.clipFolder(for: nil) == "Clippings")

        let props = BrowserSpaceRoutingLogic.clipProperties(
            url: "https://example.com/doc",
            title: "Doc",
            host: "example.com",
            space: withDefaultFolder
        )
        #expect(props["space"] == .string("Vesper"))
        #expect(props["space_id"] == .string("s1"))

        let personas = [BrowserExtensionPersona(id: "p-judy", name: "Judy", isDefault: false)]
        #expect(BrowserSpaceRoutingLogic.defaultShareTarget(space: withDefaultFolder, companionChatId: nil, personas: personas) == "persona:p-judy")
        #expect(BrowserSpaceRoutingLogic.defaultShareTarget(space: withDefaultFolder, companionChatId: "chat-1", personas: personas) == "companion")
    }

    @Test("BrowserMultiTabShareLogic enforces Auto-Follow privacy gates and builds multi-tab bundles safely")
    func autoFollowAndMultiTabBundling() {
        let neverShare = BrowserNeverShareLists(builtin: ["1password.com"], mine: ["bank.local"])

        #expect(BrowserMultiTabShareLogic.isAutoFollowEligible(
            urlString: "https://docs.swift.org/swift-book",
            isPrivate: false,
            isCompanionOpen: true,
            neverShare: neverShare
        ) == true)
        #expect(BrowserMultiTabShareLogic.isAutoFollowEligible(
            urlString: "https://docs.swift.org/swift-book",
            isPrivate: true,
            isCompanionOpen: true,
            neverShare: neverShare
        ) == false)
        #expect(BrowserMultiTabShareLogic.isAutoFollowEligible(
            urlString: "https://vault.1password.com/items",
            isPrivate: false,
            isCompanionOpen: true,
            neverShare: neverShare
        ) == false)
        #expect(BrowserMultiTabShareLogic.isAutoFollowEligible(
            urlString: "https://docs.swift.org/swift-book",
            isPrivate: false,
            isCompanionOpen: false,
            neverShare: neverShare
        ) == false)

        let t1 = BrowserMultiTabInput(
            tabId: UUID(),
            url: "https://example.com/spec-a",
            title: "Spec A",
            text: "Architecture notes for Spec A with card 4111-1111-1111-1111."
        )
        let t2 = BrowserMultiTabInput(
            tabId: UUID(),
            url: "https://example.com/spec-b",
            title: "Spec B",
            text: String(repeating: "B", count: 60_000)
        )
        let privateTab = BrowserMultiTabInput(
            tabId: UUID(),
            url: "https://example.com/secret",
            title: "Private",
            text: "Should never appear",
            isPrivate: true
        )
        let blockedTab = BrowserMultiTabInput(
            tabId: UUID(),
            url: "https://my.bank.local/account",
            title: "Bank",
            text: "Should never appear"
        )

        let bundle = BrowserMultiTabShareLogic.buildBundle(
            tabs: [t1, privateTab, t2, blockedTab],
            groupName: "RFC Review",
            neverShare: neverShare
        )
        #expect(bundle != nil)
        #expect(bundle?.includedCount == 2)
        #expect(bundle?.skippedCount == 2)
        #expect(bundle?.includedTabIDs == [t1.tabId, t2.tabId])
        #expect(bundle?.title == "RFC Review (2 tabs)")
        #expect(bundle?.combinedText.contains("4111-1111-1111-1111") == false)
        #expect(bundle?.combinedText.contains("Should never appear") == false)
        #expect(bundle?.combinedText.contains("## Tab 1 of 2: Spec A") == true)
        #expect(bundle?.combinedText.contains("## Tab 2 of 2: Spec B") == true)
        #expect(bundle?.combinedText.contains("[Truncated to fit multi-tab budget]") == true)
    }

    @Test("BrowserStorage round-trips Space links, web highlights, and Auto-Follow config with backward compatibility")
    func persistenceRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesper-synergy-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let group = BrowserTabGroup(name: "Vesper", color: .indigo, spaceId: "space-123")
        let highlight = BrowserWebHighlight(
            url: "https://example.com/article",
            quote: "Key takeaway",
            prefix: "Here is the",
            suffix: "from the paper",
            note: "Review later",
            color: .pink,
            knowledgePageId: "page-456"
        )
        var profile = BrowserProfile.defaultPersonal()
        profile.tabGroups = [group]
        profile.spaceId = "space-default"
        profile.highlights = [highlight]

        var state = BrowserPersistedState.empty
        state.profiles = [profile]
        state.activeProfileId = profile.id
        state.layoutConfig.autoFollowCompanionTab = true

        try BrowserStorage.save(state, to: tmp)
        let loaded = BrowserStorage.load(from: tmp)
        #expect(loaded.layoutConfig.autoFollowCompanionTab == true)
        #expect(loaded.profiles.first?.spaceId == "space-default")
        #expect(loaded.profiles.first?.tabGroups.first?.spaceId == "space-123")
        #expect(loaded.profiles.first?.highlights.count == 1)
        #expect(loaded.profiles.first?.highlights.first?.quote == "Key takeaway")
        #expect(loaded.profiles.first?.highlights.first?.knowledgePageId == "page-456")

        // Legacy JSON missing all new keys should decode cleanly with safe defaults.
        let legacy = Data("{\"ad_block_enabled\":true}".utf8)
        let decoded = try JSONDecoder().decode(BrowserPersistedState.self, from: legacy)
        #expect(decoded.layoutConfig.autoFollowCompanionTab == false)
        #expect(decoded.profiles.first?.spaceId == nil)
        #expect(decoded.profiles.first?.highlights.isEmpty == true)
    }
}
