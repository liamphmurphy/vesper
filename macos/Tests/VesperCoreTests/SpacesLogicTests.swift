import XCTest
@testable import VesperCore

final class SpacesLogicTests: XCTestCase {
    func testTokensBareURLAndInitial() {
        XCTAssertEqual(SpacesLogic.initial(for: "  health"), "H")
        XCTAssertEqual(SpacesLogic.initial(for: "!!!"), "#")
        XCTAssertEqual(SpacesLogic.formatTokens(950), "950")
        XCTAssertEqual(SpacesLogic.formatTokens(1240), "1.2k")
        XCTAssertEqual(SpacesLogic.formatTokens(13100), "13k")
        XCTAssertEqual(SpacesLogic.formatTokens(13100, precise: true), "13.1k")
        XCTAssertEqual(SpacesLogic.bareURL("https://www.examine.com/creatine/"), "examine.com/creatine")
    }

    func testNavModelListsSpacesAndDecodesCommands() {
        let sp = API.ChatSpace(
            chatCount: 4,
            color: .teal,
            connectorIds: [],
            createdAt: "2026-11-20T00:00:00Z",
            description: "Campaign notes",
            id: "sp-1",
            inlineTokens: 0,
            instructions: "",
            knowledgeCount: 1,
            memoryCount: 0,
            name: "Umbra",
            openTaskCount: 2,
            repoCount: 0,
            sourceCount: 1,
            spaceMemory: true,
            updatedAt: "2026-11-20T00:00:00Z"
        )
        let nav = SpacesLogic.navModel(spaces: [sp], activeSpaceId: "sp-1")
        XCTAssertEqual(nav.id, SpacesLogic.navId)
        XCTAssertEqual(nav.selectedId, "space:sp-1")
        XCTAssertEqual(nav.actions?.map(\.id), [SpacesLogic.newSpaceAction])
        XCTAssertEqual(nav.sections.first?.items.first?.trailing, "4")
        XCTAssertTrue(SpacesLogic.subtitle(for: sp).contains("1 Knowledge link"))
        XCTAssertTrue(SpacesLogic.subtitle(for: sp).contains("2 open tasks"))

        XCTAssertEqual(
            SpacesLogic.navAction(for: .navAction(navigatorId: SpacesLogic.navId, actionId: SpacesLogic.newSpaceAction)),
            .newSpace
        )
        XCTAssertEqual(
            SpacesLogic.navAction(for: .navActivate(navigatorId: SpacesLogic.navId, itemId: "space:sp-1", newTab: true)),
            .openSpace("sp-1", newTab: true)
        )
        XCTAssertEqual(
            SpacesLogic.navAction(for: .navActivate(navigatorId: SpacesLogic.navId, itemId: "new-chat:sp-1", newTab: false)),
            .openSpace("sp-1", newTab: false)
        )
        XCTAssertEqual(
            SpacesLogic.navAction(for: .navActivate(navigatorId: SpacesLogic.navId, itemId: "chat:c-9", newTab: false)),
            .openChat("c-9", newTab: false)
        )
    }

    func testKnowledgeLinkSuggestionsForFolders() {
        let pages = [
            KnowledgePageRow(id: "p1", title: "Campaign Bible", path: "Umbra/Campaign Bible", updatedAt: "2026-11-20T10:00:00Z"),
            KnowledgePageRow(id: "p2", title: "Kael", path: "Umbra/NPCs/Kael", updatedAt: "2026-11-21T10:00:00Z"),
            KnowledgePageRow(id: "p3", title: "Vesper Architecture", path: "Engineering/Vesper/Architecture", updatedAt: "2026-11-22T10:00:00Z"),
            KnowledgePageRow(id: "p4", title: "Root Note", path: "Root Note", updatedAt: "2026-11-23T10:00:00Z"),
        ]
        let existing = [
            API.ChatSpaceKnowledgeLink(
                createdAt: "2026-11-20T00:00:00Z",
                id: "l1",
                isDefaultTarget: true,
                kind: .folder,
                pageCount: 1,
                path: "Engineering",
                pinned: false
            ),
        ]

        // Empty query returns all unlinked folders sorted alphabetically with recursive counts.
        let all = SpacesLogic.knowledgeLinkSuggestions(query: "", kind: .folder, pages: pages, existingLinks: existing)
        XCTAssertEqual(all.map(\.path), ["Engineering/Vesper", "Umbra", "Umbra/NPCs"])
        XCTAssertEqual(all.first(where: { $0.path == "Umbra" })?.pageCount, 2)
        XCTAssertEqual(all.first(where: { $0.path == "Umbra" })?.subtitle, "2 pages")
        XCTAssertEqual(all.first(where: { $0.path == "Umbra/NPCs" })?.subtitle, "1 page")

        // Prefix/name match ranks exact/name prefix above deeper path substring matches.
        let npcMatches = SpacesLogic.knowledgeLinkSuggestions(query: "npc", kind: .folder, pages: pages, existingLinks: existing)
        XCTAssertEqual(npcMatches.map(\.path), ["Umbra/NPCs"])

        // Leading/trailing slashes are normalized.
        let umbraMatches = SpacesLogic.knowledgeLinkSuggestions(query: "/umb/", kind: .folder, pages: pages, existingLinks: existing)
        XCTAssertEqual(umbraMatches.map(\.path), ["Umbra", "Umbra/NPCs"])
    }

    func testKnowledgeLinkSuggestionsForPages() {
        let pages = [
            KnowledgePageRow(id: "p1", title: "Campaign Bible", path: "Umbra/Campaign Bible", updatedAt: "2026-11-20T10:00:00Z"),
            KnowledgePageRow(id: "p2", title: "Kael", path: "Umbra/NPCs/Kael", updatedAt: "2026-11-22T10:00:00Z"),
            KnowledgePageRow(id: "p3", title: "Scratchpad", path: "Scratchpad", updatedAt: "2026-11-23T10:00:00Z"),
            KnowledgePageRow(id: "p4", title: "Kael Duplicate", path: "Umbra/NPCs/Kael", updatedAt: "2026-11-19T10:00:00Z"),
        ]
        let existing = [
            API.ChatSpaceKnowledgeLink(
                createdAt: "2026-11-20T00:00:00Z",
                id: "l1",
                isDefaultTarget: false,
                kind: .page,
                pageCount: 1,
                path: "Umbra/Campaign Bible",
                pinned: true
            ),
        ]

        // Empty query returns unlinked pages most-recently-updated first, deduplicated.
        let recent = SpacesLogic.knowledgeLinkSuggestions(query: "", kind: .page, pages: pages, existingLinks: existing)
        XCTAssertEqual(recent.map(\.path), ["Scratchpad", "Umbra/NPCs/Kael"])
        XCTAssertNil(recent[0].subtitle)
        XCTAssertEqual(recent[1].subtitle, "Umbra/NPCs")

        // Matches by folder path as well as title.
        let byPath = SpacesLogic.knowledgeLinkSuggestions(query: "umbra/npc", kind: .page, pages: pages, existingLinks: existing)
        XCTAssertEqual(byPath.map(\.path), ["Umbra/NPCs/Kael"])

        // Respects limit.
        let limited = SpacesLogic.knowledgeLinkSuggestions(query: "", kind: .page, pages: pages, existingLinks: [], limit: 2)
        XCTAssertEqual(limited.count, 2)
    }
}
