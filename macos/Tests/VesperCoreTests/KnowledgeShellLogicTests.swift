import XCTest
@testable import VesperCore

final class KnowledgeShellLogicTests: XCTestCase {
    private func makeRow(
        id: String,
        title: String? = nil,
        path: String,
        audience: KnowledgeAudience = .private,
        summary: String = "",
        properties: [String: JSONValue] = [:],
        updatedAt: String = "",
        pending: Int = 0,
        unresolved: Int = 0,
        kind: KnowledgePageKind = .document,
        canvasId: String? = nil
    ) -> KnowledgePageRow {
        let derivedTitle = title ?? KnowledgeShellLogic.nameOf(path)
        return KnowledgePageRow(
            id: id,
            title: derivedTitle,
            path: path,
            audience: audience,
            summary: summary,
            properties: properties,
            updatedAt: updatedAt,
            versionId: nil,
            pending: pending,
            unresolved: unresolved,
            kind: kind,
            canvasId: canvasId
        )
    }

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func utcDate(_ iso: String) -> Date {
        APIDate.parse(iso)!
    }

    // MARK: - 1. Routing

    func testDestinationForKnowledgeRoutes() {
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge", params: [:], query: [:])),
            .home
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge", params: [:], query: ["kind": "DECK"])),
            .start(.deck)
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge", params: [:], query: ["kind": "design"])),
            .start(.design)
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge", params: [:], query: ["search": "1"])),
            .search(initialQuery: nil)
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge", params: [:], query: ["q": "swift"])),
            .search(initialQuery: "swift")
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge", params: [:], query: ["tag": "adr"])),
            .search(initialQuery: nil)
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledge, path: "/knowledge/connect", params: [:], query: [:])),
            .connect
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledgeGraph, path: "/knowledge/graph", params: [:], query: [:])),
            .graph
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledgePage, path: "/knowledge/p1", params: ["id": "p1"], query: [:])),
            .page(id: "p1")
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledgePage, path: "/wiki/Arch/ADR", params: ["*": "Arch/ADR"], query: [:])),
            .legacyWiki(path: "/wiki/Arch/ADR")
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledgePage, path: "/knowledge/legacy/foo", params: ["*": "foo"], query: [:])),
            .legacyWiki(path: "/knowledge/legacy/foo")
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .knowledgePage, path: "/knowledge/", params: [:], query: [:])),
            .home
        )
        XCTAssertEqual(
            KnowledgeShellLogic.destination(for: NativeRouteMatch(screen: .inbox, path: "/inbox", params: [:], query: [:])),
            .home
        )

        XCTAssertEqual(KnowledgeDestination.page(id: "p1").activePageId, "p1")
        XCTAssertNil(KnowledgeDestination.home.activePageId)
    }

    // MARK: - 2. Tree Building, Flattening, Filtering & Lookup

    func testBuildTreeOrderingAndCounts() {
        let rows = [
            makeRow(id: "1", path: "Zebra/Alpha"),
            makeRow(id: "2", path: "Inbox/Idea 1"),
            makeRow(id: "3", path: "Daily/2026-11-18"),
            makeRow(id: "4", path: "Daily/2026-11-20"),
            makeRow(id: "5", path: "Daily/2026-11-19"),
            makeRow(id: "6", path: "Alpha/Sub/Deep"),
            makeRow(id: "7", path: "Alpha/First"),
            makeRow(id: "8", path: "Top Note"),
        ]

        let prioritized = KnowledgeShellLogic.buildTree(from: rows, prioritizeInbox: true)
        XCTAssertEqual(prioritized.count, 8)
        XCTAssertEqual(prioritized.folders.map(\.name), ["Inbox", "Alpha", "Daily", "Zebra"])
        XCTAssertEqual(prioritized.pages.map(\.title), ["Top Note"])

        let alpha = prioritized.folders[1]
        XCTAssertEqual(alpha.count, 2)
        XCTAssertEqual(alpha.folders.map(\.path), ["Alpha/Sub"])
        XCTAssertEqual(alpha.pages.map(\.title), ["First"])

        let daily = prioritized.folders[2]
        XCTAssertEqual(daily.pages.map(\.title), ["2026-11-20", "2026-11-19", "2026-11-18"])

        let alphabetical = KnowledgeShellLogic.buildTree(from: rows, prioritizeInbox: false)
        XCTAssertEqual(alphabetical.folders.map(\.name), ["Alpha", "Daily", "Inbox", "Zebra"])
    }

    func testBuildTreeRegularFolderSortingWithIdTieBreaker() {
        let rows = [
            makeRow(id: "b", title: "Note", path: "Notes/Note-b"),
            makeRow(id: "a", title: "Note", path: "Notes/Note-a"),
            makeRow(id: "c", title: "Alpha", path: "Notes/Alpha"),
        ]
        let tree = KnowledgeShellLogic.buildTree(from: rows)
        XCTAssertEqual(tree.folders[0].pages.map(\.id), ["c", "a", "b"])
    }

    func testFlattenTreeExpansionPageCapActiveEscapeAndShowAll() {
        let pages = (0..<10).map { i in
            makeRow(id: "p\(i)", title: String(format: "Note %02d", i), path: "Notes/Note \(i)")
        }
        let tree = KnowledgeShellLogic.buildTree(from: pages)

        let collapsed = KnowledgeShellLogic.flattenTree(tree, expanded: [])
        XCTAssertEqual(collapsed.map(\.id), ["f:Notes"])

        let capped = KnowledgeShellLogic.flattenTree(tree, expanded: ["Notes"])
        XCTAssertEqual(capped.count, 1 + 8 + 1)
        XCTAssertEqual(capped.last?.kind, .showMore(folderPath: "Notes", hiddenCount: 2))

        let withActivePastCap = KnowledgeShellLogic.flattenTree(
            tree,
            expanded: ["Notes"],
            activePageId: "p9"
        )
        XCTAssertEqual(withActivePastCap.count, 1 + 9 + 1)
        XCTAssertTrue(withActivePastCap.contains(where: { $0.id == "p:p9" }))
        XCTAssertEqual(withActivePastCap.last?.kind, .showMore(folderPath: "Notes", hiddenCount: 1))

        let expandedAll = KnowledgeShellLogic.flattenTree(
            tree,
            expanded: ["Notes"],
            showAll: ["Notes"]
        )
        XCTAssertEqual(expandedAll.count, 1 + 10)
        XCTAssertFalse(expandedAll.contains(where: {
            if case .showMore = $0.kind { return true }
            return false
        }))
    }

    func testFilterRowsFindFolderAndFolderPaths() {
        let rows = [
            makeRow(id: "1", title: "Café Menu", path: "Food/Cafe", summary: "Morning espresso"),
            makeRow(id: "2", title: "ADR 01", path: "Architecture/ADR 01", summary: "Postgres storage"),
            makeRow(id: "3", title: "Budget", path: "Finance/Q4/Budget", properties: ["tags": .array([.string("ops-review")])]),
        ]

        XCTAssertEqual(KnowledgeShellLogic.filterRows(rows, matching: "   ").map(\.id), ["1", "2", "3"])
        XCTAssertEqual(KnowledgeShellLogic.filterRows(rows, matching: "cafe").map(\.id), ["1"])
        XCTAssertEqual(KnowledgeShellLogic.filterRows(rows, matching: "architecture").map(\.id), ["2"])
        XCTAssertEqual(KnowledgeShellLogic.filterRows(rows, matching: "POSTGRES").map(\.id), ["2"])
        XCTAssertEqual(KnowledgeShellLogic.filterRows(rows, matching: "ops-review").map(\.id), ["3"])

        let tree = KnowledgeShellLogic.buildTree(from: rows)
        XCTAssertEqual(KnowledgeShellLogic.findFolder(at: "", in: tree)?.path, "")
        XCTAssertEqual(KnowledgeShellLogic.findFolder(at: "/Finance//Q4/", in: tree)?.name, "Q4")
        XCTAssertNil(KnowledgeShellLogic.findFolder(at: "Missing/Folder", in: tree))
        XCTAssertEqual(KnowledgeShellLogic.folderPaths(in: tree), ["Architecture", "Finance", "Finance/Q4", "Food"])
    }

    // MARK: - 3. Paths, Drag-to-Move, Rename, Duplicate & Untitled

    func testPathAndSlugHelpers() {
        XCTAssertEqual(KnowledgeShellLogic.slug("ADR 1: Storage & Auth!"), "adr-1-storage-auth")
        XCTAssertEqual(KnowledgeShellLogic.pageHref(id: "id-1", title: "ADR 1"), "/knowledge/id-1/adr-1")
        XCTAssertEqual(KnowledgeShellLogic.pageHref(id: "id-1", title: "!!!"), "/knowledge/id-1")
        XCTAssertEqual(KnowledgeShellLogic.normalizeFolderPath("/Projects//Vesper/"), "Projects/Vesper")
        XCTAssertEqual(KnowledgeShellLogic.parentOf("Projects/Vesper/Spec"), "Projects/Vesper")
        XCTAssertEqual(KnowledgeShellLogic.parentOf("Top"), "")
        XCTAssertEqual(KnowledgeShellLogic.nameOf("Projects/Vesper/Spec"), "Spec")
        XCTAssertEqual(KnowledgeShellLogic.joinPath("", "Spec"), "Spec")
        XCTAssertEqual(KnowledgeShellLogic.joinPath("Projects/", "/Spec"), "Projects/Spec")
        XCTAssertEqual(KnowledgeShellLogic.joinPath("Projects", ""), "Projects")
        XCTAssertEqual(KnowledgeShellLogic.ancestors(of: nil), [])
        XCTAssertEqual(KnowledgeShellLogic.ancestors(of: "Top"), [])
        XCTAssertEqual(KnowledgeShellLogic.ancestors(of: "A/B/C"), ["A", "A/B"])
    }

    func testPageHrefForRowRoutesCanvasKindsToEditors() {
        let design = makeRow(id: "p-design", title: "Audio Library", path: "Designs/Audio Library", kind: .design, canvasId: "c-design")
        XCTAssertEqual(KnowledgeShellLogic.pageHref(for: design), "/apps/designs/c-design")

        let deck = makeRow(id: "p-deck", title: "Q4 Review", path: "Decks/Q4 Review", kind: .deck, canvasId: "c-deck")
        XCTAssertEqual(KnowledgeShellLogic.pageHref(for: deck), "/apps/slides/c-deck")

        let designWithoutCanvas = makeRow(id: "p-design-2", title: "Draft", path: "Designs/Draft", kind: .design, canvasId: nil)
        XCTAssertEqual(KnowledgeShellLogic.pageHref(for: designWithoutCanvas), "/knowledge/p-design-2/draft")

        let deckEmptyCanvas = makeRow(id: "p-deck-2", title: "Empty", path: "Decks/Empty", kind: .deck, canvasId: "")
        XCTAssertEqual(KnowledgeShellLogic.pageHref(for: deckEmptyCanvas), "/knowledge/p-deck-2/empty")

        let doc = makeRow(id: "p-doc", title: "ADR 1", path: "Decisions/ADR 1", kind: .document, canvasId: "c-doc")
        XCTAssertEqual(KnowledgeShellLogic.pageHref(for: doc), "/knowledge/p-doc/adr-1")
    }

    func testDragPayloadEncodingAndDecoding() {
        let row = makeRow(id: "p1", title: "Doc", path: "Notes/Doc")
        let pagePayload = KnowledgeDragItem.page(row).encodeDragPayload()
        XCTAssertEqual(KnowledgeDragItem.decodeDragPayload(pagePayload), KnowledgeDragItem(kind: .page, id: "p1", path: "Notes/Doc", title: "Doc"))

        let folder = KnowledgeTreeFolder(name: "Notes", path: "Projects/Notes")
        let folderPayload = KnowledgeDragItem.folder(folder).encodeDragPayload()
        XCTAssertEqual(KnowledgeDragItem.decodeDragPayload(folderPayload), KnowledgeDragItem(kind: .folder, id: "Projects/Notes", path: "Projects/Notes", title: "Notes"))

        XCTAssertNil(KnowledgeDragItem.decodeDragPayload("{\"kind\":\"page\"}"))
        XCTAssertNil(KnowledgeDragItem.decodeDragPayload("vesper-knowledge-drag:{invalid"))
    }

    func testMovedPathAndMoveTargets() {
        XCTAssertEqual(KnowledgeShellLogic.movedPath("NPCs", from: "NPCs", to: "People"), "People")
        XCTAssertEqual(KnowledgeShellLogic.movedPath("NPCs/Alice", from: "NPCs", to: "People"), "People/Alice")
        XCTAssertEqual(KnowledgeShellLogic.movedPath("NPCs2/Bob", from: "NPCs", to: "People"), "NPCs2/Bob")

        let folders = ["NPCs", "NPCs/Allies", "NPCs2", "Places"]
        XCTAssertEqual(
            KnowledgeShellLogic.moveTargets(folders: folders, path: "NPCs", isFolder: true),
            ["NPCs2", "Places"]
        )
        XCTAssertEqual(
            KnowledgeShellLogic.moveTargets(folders: folders, path: "NPCs/Alice", isFolder: false),
            ["", "NPCs/Allies", "NPCs2", "Places"]
        )
        XCTAssertEqual(
            KnowledgeShellLogic.moveTargets(folders: folders, path: "NPCs/Alice", isFolder: false, filter: "PLAC"),
            ["Places"]
        )
    }

    func testPlanDropForPagesAndFolders() {
        let row = makeRow(id: "p1", path: "Notes/Spec")
        let pageItem = KnowledgeDragItem.page(row)
        XCTAssertEqual(
            KnowledgeShellLogic.planDrop(item: pageItem, ontoFolder: "Archive", expanded: []),
            .movePage(id: "p1", newPath: "Archive/Spec", title: nil)
        )
        XCTAssertEqual(
            KnowledgeShellLogic.planDrop(item: pageItem, ontoFolder: "", expanded: []),
            .movePage(id: "p1", newPath: "Spec", title: nil)
        )
        XCTAssertNil(KnowledgeShellLogic.planDrop(item: pageItem, ontoFolder: "Notes", expanded: []))

        let folderItem = KnowledgeDragItem(kind: .folder, id: "A", path: "A", title: "A")
        let expanded: Set<String> = ["A", "A/Sub", "A2/Keep"]
        XCTAssertEqual(
            KnowledgeShellLogic.planDrop(item: folderItem, ontoFolder: "Dest/Parent", expanded: expanded),
            .moveFolder(
                from: "A",
                to: "Dest/Parent/A",
                updatedExpanded: ["Dest/Parent/A", "Dest/Parent/A/Sub", "A2/Keep", "Dest", "Dest/Parent"]
            )
        )
        XCTAssertNil(KnowledgeShellLogic.planDrop(item: folderItem, ontoFolder: "", expanded: expanded))
        XCTAssertNil(KnowledgeShellLogic.planDrop(item: folderItem, ontoFolder: "A", expanded: expanded))
        XCTAssertNil(KnowledgeShellLogic.planDrop(item: folderItem, ontoFolder: "A/Sub", expanded: expanded))

        let rootless = KnowledgeDragItem(kind: .folder, id: "", path: "", title: "")
        XCTAssertNil(KnowledgeShellLogic.planDrop(item: rootless, ontoFolder: "Dest", expanded: []))
    }

    func testRenameDuplicateAndUntitledHelpers() {
        XCTAssertEqual(KnowledgeShellLogic.nameError("   "), "Give it a name.")
        XCTAssertNotNil(KnowledgeShellLogic.nameError("a/b"))
        XCTAssertNil(KnowledgeShellLogic.nameError("Valid Name"))

        let row = makeRow(id: "p1", title: "Old", path: "Projects/Old")
        let renamed = KnowledgeShellLogic.planPageRename(page: row, newName: "  New  ")
        XCTAssertEqual(renamed?.title, "New")
        XCTAssertEqual(renamed?.path, "Projects/New")
        XCTAssertNil(KnowledgeShellLogic.planPageRename(page: row, newName: "Old"))
        XCTAssertNil(KnowledgeShellLogic.planPageRename(page: row, newName: "bad/name"))

        let folderRename = KnowledgeShellLogic.planFolderRename(
            folderPath: "Projects/Old",
            newName: "  Fresh ",
            expanded: ["Projects/Old", "Projects/Old/Sub", "Projects/Old2"]
        )
        XCTAssertEqual(folderRename?.from, "Projects/Old")
        XCTAssertEqual(folderRename?.to, "Projects/Fresh")
        XCTAssertEqual(folderRename?.updatedExpanded, ["Projects/Fresh", "Projects/Fresh/Sub", "Projects/Old2"])
        XCTAssertNil(KnowledgeShellLogic.planFolderRename(folderPath: "", newName: "Fresh", expanded: []))
        XCTAssertNil(KnowledgeShellLogic.planFolderRename(folderPath: "Projects/Old", newName: "Old", expanded: []))
        XCTAssertNil(KnowledgeShellLogic.planFolderRename(folderPath: "Projects/Old", newName: "a/b", expanded: []))

        let existing: Set<String> = ["Notes/Spec copy", "notes/spec copy 2"]
        let agentPage = KnowledgePage(
            id: "p1",
            title: "Spec",
            path: "Notes/Spec",
            audience: .agent,
            bodyMd: "Body",
            properties: ["status": .string("draft")]
        )
        let dupAgent = KnowledgeShellLogic.duplicatePageInput(from: agentPage, existingPaths: existing)
        XCTAssertEqual(dupAgent.title, "Spec copy 3")
        XCTAssertEqual(dupAgent.path, "Notes/Spec copy 3")
        XCTAssertEqual(dupAgent.bodyMd, "Body")
        XCTAssertEqual(dupAgent.audience, "private")

        let sharedPage = KnowledgePage(id: "p2", title: "", path: "SharedDoc", audience: .shared)
        let dupShared = KnowledgeShellLogic.duplicatePageInput(from: sharedPage, existingPaths: [])
        XCTAssertEqual(dupShared.title, "Untitled copy")
        XCTAssertEqual(dupShared.path, "Untitled copy")
        XCTAssertEqual(dupShared.audience, "shared")

        XCTAssertEqual(
            KnowledgeShellLogic.nextUntitledPath(in: "", existingPaths: ["untitled", "Untitled 2"]),
            "Untitled 3"
        )
        XCTAssertEqual(
            KnowledgeShellLogic.nextUntitledPath(in: "/Notes/", existingPaths: ["Notes/Untitled"]),
            "Notes/Untitled 2"
        )
    }

    // MARK: - 4. Multi-Select & Bulk Plans

    func testKnowledgeSelection() {
        let ids = ["f:A", "p:1", "p:2", "p:3"]
        var sel = KnowledgeSelection()

        sel.click("p:1", in: ids)
        XCTAssertEqual(sel.selected, ["p:1"])
        XCTAssertEqual(sel.focused, "p:1")
        XCTAssertEqual(sel.anchor, "p:1")

        sel.click("p:3", in: ids, modifier: .extend)
        XCTAssertEqual(sel.selected, ["p:1", "p:2", "p:3"])
        XCTAssertEqual(sel.focused, "p:3")

        sel.click("f:A", in: ids, modifier: .extend)
        XCTAssertEqual(sel.selected, ["f:A", "p:1"])
        XCTAssertEqual(sel.focused, "f:A")

        sel.click("p:3", in: ids, modifier: .toggle)
        XCTAssertEqual(sel.selected, ["f:A", "p:1", "p:3"])
        XCTAssertEqual(sel.focused, "p:3")

        sel.click("p:3", in: ids, modifier: .toggle)
        XCTAssertEqual(sel.selected, ["f:A", "p:1"])
        XCTAssertEqual(sel.focused, "f:A")

        XCTAssertEqual(sel.targets(for: "p:1", in: ids), ["f:A", "p:1"])
        XCTAssertEqual(sel.targets(for: "p:2", in: ids), ["p:2"])

        sel.prune(to: ["p:1", "p:2"])
        XCTAssertEqual(sel.selected, ["p:1"])
        XCTAssertEqual(sel.focused, "p:1")

        sel.selectAll(ids)
        XCTAssertEqual(sel.selected, Set(ids))

        sel.clear()
        XCTAssertTrue(sel.selected.isEmpty)
        XCTAssertNil(sel.focused)
        XCTAssertNil(sel.anchor)

        // Extend without prior anchor falls back to single selection.
        sel.click("p:2", in: ids, modifier: .extend)
        XCTAssertEqual(sel.selected, ["p:2"])
        XCTAssertEqual(sel.anchor, "p:2")
    }

    func testMinimalDeleteBulkMoveAndAudiencePlans() {
        let pages = [
            makeRow(id: "1", path: "Projects/A", audience: .private),
            makeRow(id: "2", path: "Projects/Sub/B", audience: .shared),
            makeRow(id: "3", path: "Projects2/C", audience: .private),
            makeRow(id: "4", path: "Archive/D", audience: .agent),
            makeRow(id: "5", path: "Loose", audience: .private),
        ]

        let selected: Set<String> = ["f:Projects", "f:Projects/Sub", "p:1", "p:2", "p:5"]
        let del = KnowledgeShellLogic.minimalDeletePlan(selectedRowIds: selected, allPages: pages)
        XCTAssertEqual(del.folders, ["Projects"])
        XCTAssertEqual(del.pageIds, ["5"])
        XCTAssertEqual(del.affectedPageCount, 3)

        let move = KnowledgeShellLogic.bulkMovePlan(
            selectedRowIds: ["f:Projects", "f:Projects/Sub", "f:Archive", "p:1", "p:3", "p:5"],
            intoFolder: "Archive",
            allPages: pages
        )
        XCTAssertEqual(move.folders.count, 1)
        XCTAssertEqual(move.folders[0].from, "Projects")
        XCTAssertEqual(move.folders[0].to, "Archive/Projects")
        XCTAssertEqual(move.pages.map(\.id), ["3", "5"])
        XCTAssertEqual(move.pages.map(\.path), ["Archive/C", "Archive/Loose"])

        let shareTargets = KnowledgeShellLogic.bulkAudienceTargets(
            selectedRowIds: ["f:Projects", "p:4", "p:5"],
            allPages: pages,
            to: .shared
        )
        XCTAssertEqual(shareTargets.map(\.id), ["1", "5"])
        XCTAssertTrue(KnowledgeShellLogic.bulkAudienceTargets(selectedRowIds: ["p:1"], allPages: pages, to: .agent).isEmpty)
    }

    // MARK: - 5. Search Filter, Query Builder & Properties

    func testSearchFilterQueryAndRequests() throws {
        XCTAssertFalse(KnowledgeSearchFilter(text: "  ", tag: " ", folder: "/").hasActiveFilters)
        XCTAssertTrue(KnowledgeSearchFilter(orphansOnly: true).hasActiveFilters)

        let simple = KnowledgeSearchFilter(
            text: "  adr  ",
            tag: "##arch",
            folder: "/Projects//Vesper/",
            audience: .agent,
            kind: .document,
            orphansOnly: true,
            unresolvedOnly: true,
            includeAgent: false,
            limit: 50,
            offset: 0
        )
        XCTAssertFalse(simple.requiresPostQuery)
        let q1 = simple.buildQuery()
        XCTAssertEqual(q1.text, "adr")
        XCTAssertEqual(q1.tag, "arch")
        XCTAssertEqual(q1.folder, "Projects/Vesper")
        XCTAssertEqual(q1.includeAgent, true)
        XCTAssertNil(q1.offset)

        let getReq = simple.buildRequest()
        XCTAssertEqual(getReq.method, "GET")
        XCTAssertEqual(getReq.path, "/api/v1/knowledge/pages")
        XCTAssertTrue(getReq.pathAndQuery.contains("q=adr"))
        XCTAssertTrue(getReq.pathAndQuery.contains("tag=arch"))
        XCTAssertTrue(getReq.pathAndQuery.contains("include_agent=true"))

        let withProp = KnowledgeSearchFilter(propertyKey: "priority", propertyValue: "2", offset: 25)
        XCTAssertTrue(withProp.requiresPostQuery)
        let postReq = withProp.buildRequest()
        XCTAssertEqual(postReq.method, "POST")
        XCTAssertEqual(postReq.path, "/api/v1/knowledge/query")
        let body = try XCTUnwrap(postReq.body)
        let (data, contentType) = try body.encode()
        XCTAssertEqual(contentType, "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let props = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual(props["priority"] as? Int, 2)
        XCTAssertEqual(json["offset"] as? Int, 25)

        let keyOnly = KnowledgeSearchFilter(propertyKey: "status", propertyValue: "")
        XCTAssertFalse(keyOnly.requiresPostQuery)
        XCTAssertTrue(keyOnly.matchesClientSidePropertyKey(makeRow(id: "1", path: "A", properties: ["status": .string("open")])))
        XCTAssertFalse(keyOnly.matchesClientSidePropertyKey(makeRow(id: "2", path: "B")))
    }

    func testPropertyAndTagParsing() {
        XCTAssertEqual(KnowledgeShellLogic.parsePropertyFilterValue("TRUE"), .bool(true))
        XCTAssertEqual(KnowledgeShellLogic.parsePropertyFilterValue("false"), .bool(false))
        XCTAssertEqual(KnowledgeShellLogic.parsePropertyFilterValue("42"), .int(42))
        XCTAssertEqual(KnowledgeShellLogic.parsePropertyFilterValue("3.5"), .double(3.5))
        XCTAssertEqual(KnowledgeShellLogic.parsePropertyFilterValue("draft"), .string("draft"))

        XCTAssertEqual(KnowledgeShellLogic.tags(of: ["tags": .array([.string("#one"), .string("two"), .string(" ")])]), ["one", "two"])
        XCTAssertEqual(KnowledgeShellLogic.tags(of: ["tags": .string("#alpha, beta, ")]), ["alpha", "beta"])
        XCTAssertEqual(KnowledgeShellLogic.tags(of: ["tags": .int(5)]), [])

        let rows = [
            makeRow(id: "1", path: "A", properties: ["tags": .array([.string("swift"), .string("swift"), .string("adr")]), "query": .string("q"), "zettel_id": .string("1"), "status": .string("done")]),
            makeRow(id: "2", path: "B", properties: ["tags": .string("adr, beta"), "priority": .int(1)]),
        ]
        let tagCounts = KnowledgeShellLogic.extractTags(from: rows)
        XCTAssertEqual(tagCounts.map(\.tag), ["adr", "beta", "swift"])
        XCTAssertEqual(tagCounts.map(\.count), [2, 1, 1])

        XCTAssertEqual(KnowledgeShellLogic.extractPropertyKeys(from: rows), ["priority", "status"])

        let vis = KnowledgeShellLogic.visibleProperties([
            "query": .string("ignored"),
            "zettel_id": .string("ignored"),
            "empty": .string(""),
            "emptyArr": .array([]),
            "nilVal": .null,
            "owner": .string("Meow"),
            "count": .int(3),
        ])
        XCTAssertEqual(vis.map(\.key), ["count", "owner"])

        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.null), "")
        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.bool(true)), "true")
        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.int(7)), "7")
        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.double(2.5)), "2.5")
        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.string("hi")), "hi")
        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.array([.string("a"), .null, .int(2)])), "a, 2")
        XCTAssertEqual(KnowledgeShellLogic.formatPropertyValue(.object(["k": .int(1)])), "{\"k\":1}")
    }

    // MARK: - 6. Home, Start, Connect, Capture & Editor Seam

    func testPresentationAndDateFormatting() {
        let cal = utcCalendar()
        XCTAssertEqual(KnowledgeShellLogic.greeting(for: utcDate("2026-11-22T09:00:00Z"), calendar: cal), "Good morning")
        XCTAssertEqual(KnowledgeShellLogic.greeting(for: utcDate("2026-11-22T14:00:00Z"), calendar: cal), "Good afternoon")
        XCTAssertEqual(KnowledgeShellLogic.greeting(for: utcDate("2026-11-22T20:00:00Z"), calendar: cal), "Good evening")

        XCTAssertEqual(KnowledgeShellLogic.firstName(from: "  Ada Lovelace "), "Ada")
        XCTAssertNil(KnowledgeShellLogic.firstName(from: "   "))

        let now = utcDate("2026-11-22T12:00:00Z")
        XCTAssertEqual(KnowledgeShellLogic.isoDay(now, calendar: cal), "2026-11-22")
        XCTAssertTrue(KnowledgeShellLogic.isISODate("2026-11-22"))
        XCTAssertFalse(KnowledgeShellLogic.isISODate("2026-11-2"))
        XCTAssertFalse(KnowledgeShellLogic.isISODate("2026/11/22"))

        let en = Locale(identifier: "en_US")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("2026-11-22T11:59:30Z", now: now, calendar: cal, locale: en), "just now")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("2026-11-22T11:50:00Z", now: now, calendar: cal, locale: en), "10 min ago")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("2026-11-22T09:00:00Z", now: now, calendar: cal, locale: en), "3 h ago")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("2026-11-21T20:00:00Z", now: now, calendar: cal, locale: en), "Yesterday")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("2026-10-05T10:00:00Z", now: now, calendar: cal, locale: en), "Oct 5")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("2025-10-05T10:00:00Z", now: now, calendar: cal, locale: en), "Oct 5, 2025")
        XCTAssertEqual(KnowledgeShellLogic.relativeAgo("bad", now: now, calendar: cal, locale: en), "")

        XCTAssertTrue(KnowledgeShellLogic.isUntitled("Untitled"))
        XCTAssertTrue(KnowledgeShellLogic.isUntitled("Untitled Document 3a"))
        XCTAssertFalse(KnowledgeShellLogic.isUntitled("Untitled Proposal"))

        let untitledWithSummary = makeRow(id: "1", title: "Untitled", path: "Inbox/Untitled", summary: "First thought")
        XCTAssertEqual(KnowledgeShellLogic.displayTitle(for: untitledWithSummary), "Untitled \u{00B7} \u{201C}First thought\u{201D}")
        XCTAssertEqual(KnowledgeShellLogic.displayTitle(for: makeRow(id: "2", title: "", path: "")), "Untitled")

        XCTAssertEqual(KnowledgeShellLogic.folderDisplay(of: "Top"), "Top level")
        XCTAssertEqual(KnowledgeShellLogic.folderDisplay(of: "Projects/Vesper/Spec"), "Projects / Vesper")

        XCTAssertEqual(KnowledgeShellLogic.pageSymbol(for: makeRow(id: "d", path: "D", kind: .deck)), "play.rectangle")
        XCTAssertEqual(KnowledgeShellLogic.pageSymbol(for: makeRow(id: "g", path: "G", kind: .design)), "pencil.and.ruler")
        XCTAssertEqual(KnowledgeShellLogic.pageSymbol(for: makeRow(id: "q", path: "Q", properties: ["query": .string("tag:adr")])), "rectangle.split.3x1")
        XCTAssertEqual(KnowledgeShellLogic.pageSymbol(for: makeRow(id: "p", path: "P")), "doc.text")
    }

    func testHomeSummaryAndUnresolvedTargets() {
        let p1 = makeRow(id: "1", path: "A/P1", properties: ["tags": .array((0..<15).map { .string("tag\($0)") })], pending: 2)
        let p2 = makeRow(id: "2", path: "B/P2", kind: .deck)
        let p3 = makeRow(id: "3", path: "C/P3", kind: .design)
        let network = KnowledgeNetwork(
            nodes: [
                KnowledgeNetworkNode(id: "1", title: "P1", path: "A/P1"),
                KnowledgeNetworkNode(id: "2", title: "P2", path: "B/P2"),
                KnowledgeNetworkNode(id: "3", title: "P3", path: "C/P3"),
            ],
            links: [
                KnowledgeNetworkLink(source: "1", target: "2"),
                KnowledgeNetworkLink(source: "1", unresolved: "Missing Page"),
                KnowledgeNetworkLink(source: "2", unresolved: "missing page"),
                KnowledgeNetworkLink(source: "1", unresolved: "Missing Page"),
                KnowledgeNetworkLink(source: "3", unresolved: "Alpha Target"),
            ]
        )

        let summary = KnowledgeShellLogic.homeSummary(
            allPages: [p1, p2, p3],
            recentPages: [p2, p1],
            inboxPages: [p3],
            proposalPages: [p1],
            network: network
        )
        XCTAssertEqual(summary.pagesToReview.map(\.id), ["1"])
        XCTAssertEqual(summary.latestPage?.id, "2")
        XCTAssertEqual(summary.otherRecentPages.map(\.id), ["1"])
        XCTAssertEqual(summary.kindCounts, [.document: 1, .deck: 1, .design: 1])
        XCTAssertEqual(summary.topTags.count, 12)
        XCTAssertEqual(summary.orphanCount, 1)
        XCTAssertEqual(summary.unresolvedCount, 2)

        let targets = KnowledgeShellLogic.unresolvedTargets(in: network)
        XCTAssertEqual(targets.map(\.name), ["Missing Page", "Alpha Target"])
        XCTAssertEqual(targets[0].sources.map(\.id), ["1", "2"])
        XCTAssertEqual(targets[1].sources.map(\.id), ["3"])
    }

    func testStartAndCaptureHelpers() {
        XCTAssertTrue(KnowledgeShellLogic.isDeckBrief("make a deck about quarterly planning"))
        XCTAssertTrue(KnowledgeShellLogic.isDeckBrief("one two three four five six seven eight nine"))
        XCTAssertFalse(KnowledgeShellLogic.isDeckBrief("Q4 Roadmap"))

        XCTAssertTrue(KnowledgeShellLogic.isDesignBrief("Sketch user flow"))
        XCTAssertTrue(KnowledgeShellLogic.isDesignBrief("LAZYAGENTS-284 layout"))
        XCTAssertTrue(KnowledgeShellLogic.isDesignBrief("a b c d e f g"))
        XCTAssertFalse(KnowledgeShellLogic.isDesignBrief("Auth Architecture"))
        XCTAssertEqual(KnowledgeShellLogic.designBriefTitle("Wireframes for LAZYAGENTS-284"), "LAZYAGENTS-284")
        XCTAssertEqual(KnowledgeShellLogic.designBriefTitle("No key"), "")

        let explicit = KnowledgeShellLogic.splitOutline("- Slide 1\n- Slide 2", title: "  My Deck ")
        XCTAssertEqual(explicit.title, "My Deck")
        XCTAssertEqual(explicit.slides, "- Slide 1\n- Slide 2")

        let inferred = KnowledgeShellLogic.splitOutline("\n1. Intro Deck\nSlide A\nSlide B", title: "")
        XCTAssertEqual(inferred.title, "Intro Deck")
        XCTAssertEqual(inferred.slides, "Slide A\nSlide B")

        XCTAssertEqual(
            KnowledgeShellLogic.namedTemplates(from: ["Daily": "d", "ADR": "a", "Meeting": "m"]),
            ["ADR", "Meeting"]
        )

        XCTAssertNil(KnowledgeShellLogic.captureInput(from: "   \n  "))
        let multi = KnowledgeShellLogic.captureInput(from: "Idea title\nLine 2\nLine 3")
        XCTAssertEqual(multi?.title, "Idea title")
        XCTAssertEqual(multi?.bodyMd, "Line 2\nLine 3")

        let shortSingle = KnowledgeShellLogic.captureInput(from: "Quick thought")
        XCTAssertEqual(shortSingle?.title, "Quick thought")
        XCTAssertEqual(shortSingle?.bodyMd, "")

        let longLine = String(repeating: "x", count: 140)
        let longSingle = KnowledgeShellLogic.captureInput(from: longLine)
        XCTAssertEqual(longSingle?.title?.count, 120)
        XCTAssertEqual(longSingle?.bodyMd, longLine)
    }

    func testEditorTargetSeam() {
        let deck = KnowledgePage(id: "1", title: "Deck", kind: .deck, canvasId: "c1")
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: deck, query: ["brief": "hi", "ignored": "x", "review": "1"]),
            .deck(canvasId: "c1", hostedPath: "/apps/slides/c1?brief=hi&review=1")
        )

        let design = KnowledgePage(id: "2", title: "Design", kind: .design, canvasId: "d1")
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: design),
            .design(canvasId: "d1", hostedPath: "/apps/designs/d1")
        )

        let pdfEmbed = KnowledgeEmbed(
            ref: "spec.pdf",
            kind: "file",
            title: "Architecture Spec",
            url: "/api/v1/knowledge/assets/a1",
            contentType: "application/pdf",
            available: true
        )
        let pdfOnly = KnowledgePage(id: "3", title: "Spec", bodyMd: "![[spec.pdf]]", embeds: [pdfEmbed])
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: pdfOnly),
            .pdf(sourcePath: "/api/v1/knowledge/assets/a1", title: "Architecture Spec")
        )

        let pdfWithProse = KnowledgePage(id: "4", title: "Notes", bodyMd: "Summary\n![[spec.pdf]]", embeds: [pdfEmbed])
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: pdfWithProse),
            .hostedPage(hostedPath: "/knowledge/4?embed=1")
        )

        let badPdfEmbed = KnowledgeEmbed(
            ref: "evil.pdf",
            kind: "file",
            url: "/api/v1/knowledge/../secret.pdf",
            contentType: "application/pdf",
            available: true
        )
        let blockedPdf = KnowledgePage(id: "5", title: "Bad", bodyMd: "", embeds: [badPdfEmbed])
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: blockedPdf),
            .hostedPage(hostedPath: "/knowledge/5?embed=1")
        )

        let legacyDoc = KnowledgePage(id: "6", title: "Doc", kind: .document, canvasId: "doc-9", bodyMd: "   ")
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: legacyDoc),
            .hostedPage(hostedPath: "/apps/docs/doc-9")
        )

        let normal = KnowledgePage(id: "7", title: "Page", bodyMd: "Hello")
        XCTAssertEqual(
            KnowledgeShellLogic.editorTarget(for: normal, query: ["outline": "1. Intro"]),
            .hostedPage(hostedPath: "/knowledge/7?embed=1&outline=1.%20Intro")
        )
    }

    // MARK: - 7. Vault Import Helpers

    func testVaultImportHelpers() {
        XCTAssertEqual(KnowledgeShellLogic.normalizeImportFolder("/Obsidian//Vault/"), "Obsidian/Vault")
        XCTAssertEqual(KnowledgeShellLogic.importStep(for: nil), .upload)
        XCTAssertEqual(KnowledgeShellLogic.importStep(for: KnowledgeImportJob(id: "1", state: "scanning")), .review)
        XCTAssertEqual(KnowledgeShellLogic.importStep(for: KnowledgeImportJob(id: "1", state: "preview")), .review)
        XCTAssertEqual(KnowledgeShellLogic.importStep(for: KnowledgeImportJob(id: "1", state: "importing")), .importing)
        XCTAssertEqual(KnowledgeShellLogic.importStep(for: KnowledgeImportJob(id: "1", state: "done")), .importing)

        XCTAssertTrue(KnowledgeShellLogic.isImportPolling(KnowledgeImportJob(id: "1", state: "queued_commit")))
        XCTAssertFalse(KnowledgeShellLogic.isImportPolling(KnowledgeImportJob(id: "1", state: "done")))
        XCTAssertFalse(KnowledgeShellLogic.isImportPolling(nil))

        let errEntry = KnowledgeVaultEntry(source: "bad.md", path: "bad", kind: "markdown", conflict: true, error: "Too large")
        let conflictEntry = KnowledgeVaultEntry(source: "c.md", path: "c", kind: "markdown", renamed: true, conflict: true)
        let renamedEntry = KnowledgeVaultEntry(source: "r.md", path: "r", kind: "markdown", renamed: true, originalTitle: "Old")
        let unsupportedEntry = KnowledgeVaultEntry(source: "x.canvas", path: "x", kind: "attachment", unsupported: true)
        let attachEntry = KnowledgeVaultEntry(source: "img.png", path: "img.png", kind: "attachment")
        let dailyEntry = KnowledgeVaultEntry(source: "2026-11-22.md", path: "Daily/2026-11-22", kind: "markdown", daily: true)
        let taggedEntry = KnowledgeVaultEntry(source: "n.md", path: "n", kind: "markdown", tags: ["adr", "swift"])

        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(errEntry).filter, .skipped)
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(errEntry).tone, .danger)
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(conflictEntry).filter, .conflicts)
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(conflictEntry).tone, .warning)
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(renamedEntry).filter, .renamed)
        XCTAssertTrue(KnowledgeShellLogic.classifyImportEntry(renamedEntry).note.contains("Old"))
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(unsupportedEntry).filter, .files)
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(attachEntry).note, "Attachment")
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(dailyEntry).note, "Daily note")
        XCTAssertEqual(KnowledgeShellLogic.classifyImportEntry(taggedEntry).note, "#adr #swift")

        let plan = KnowledgeVaultPlan(
            entries: [errEntry, conflictEntry, renamedEntry, unsupportedEntry, attachEntry, dailyEntry],
            notes: 4,
            attachments: 2,
            resolved: 3,
            unresolved: ["MissingA", "MissingB"]
        )
        let counts = KnowledgeShellLogic.importFilterCounts(plan: plan)
        XCTAssertEqual(counts[.all], 6)
        XCTAssertEqual(counts[.skipped], 1)
        XCTAssertEqual(counts[.conflicts], 1)
        XCTAssertEqual(counts[.renamed], 1)
        XCTAssertEqual(counts[.files], 1)
        XCTAssertEqual(counts[.unresolved], 2)

        XCTAssertEqual(KnowledgeShellLogic.filteredImportEntries(plan: plan, filter: .all).count, 6)
        XCTAssertEqual(KnowledgeShellLogic.filteredImportEntries(plan: plan, filter: .conflicts).map(\.source), ["c.md"])
        XCTAssertEqual(KnowledgeShellLogic.filteredImportEntries(plan: plan, filter: .skipped).map(\.source), ["bad.md"])

        let reportJob = KnowledgeImportJob(
            id: "j1",
            state: "done",
            report: [
                KnowledgeImportResult(source: "a.md", status: "created"),
                KnowledgeImportResult(source: "b.md", status: "updated"),
                KnowledgeImportResult(source: "c.md", status: "unchanged"),
                KnowledgeImportResult(source: "d.md", status: "conflict"),
                KnowledgeImportResult(source: "e.md", status: "skipped", reason: "empty"),
                KnowledgeImportResult(source: "f.md", status: "failed", reason: "io error"),
            ]
        )
        let summary = KnowledgeShellLogic.importReportSummary(job: reportJob)
        XCTAssertEqual(summary.createdOrUpdated, 2)
        XCTAssertEqual(summary.unchanged, 1)
        XCTAssertEqual(summary.conflicts, 1)
        XCTAssertEqual(summary.skippedOrFailed, 2)
        XCTAssertEqual(summary.failures.map(\.source), ["e.md", "f.md"])

        XCTAssertEqual(KnowledgeShellLogic.formatByteCount(500), "1 MB")
        XCTAssertEqual(KnowledgeShellLogic.formatByteCount(5_200_000), "5 MB")
        XCTAssertEqual(KnowledgeShellLogic.formatByteCount(1_500_000_000), "1.5 GB")
    }
}
