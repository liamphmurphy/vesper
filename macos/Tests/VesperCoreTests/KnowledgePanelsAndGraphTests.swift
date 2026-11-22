import XCTest
@testable import VesperCore

final class KnowledgePanelsAndGraphTests: XCTestCase {
    // MARK: - Graph Layout Parity & Filtering

    func testLayoutGraphMatchesWebFixtureDeterministically() {
        let nodes = [
            KnowledgeGraphInputNode(id: "a", group: "Docs"),
            KnowledgeGraphInputNode(id: "b", group: "Docs"),
            KnowledgeGraphInputNode(id: "c", group: "Campaign"),
            KnowledgeGraphInputNode(id: "d", group: "Campaign"),
            KnowledgeGraphInputNode(id: "e", group: "Top level"),
        ]
        let links = [
            KnowledgeGraphInputLink(source: "a", target: "b"),
            KnowledgeGraphInputLink(source: "b", target: "c"),
            KnowledgeGraphInputLink(source: "c", target: "d"),
            KnowledgeGraphInputLink(source: "a", target: "a"),
            KnowledgeGraphInputLink(source: "a", target: "missing"),
        ]

        let placed = KnowledgeGraphLogic.layoutGraph(nodes: nodes, links: links)
        XCTAssertEqual(placed, KnowledgeGraphLogic.layoutGraph(nodes: nodes, links: links))
        XCTAssertEqual(placed.count, 5)

        // Exact coordinates produced by web/lib/knowledge-graph.ts for this fixture.
        let expected: [(String, Double, Double, Int)] = [
            ("a", 48.87741396562435, -53.19145649730443, 1),
            ("b", 33.54935828138234, -3.1158858813978982, 2),
            ("c", -5.307912915119552, 33.8619367171972, 2),
            ("d", -24.538417245239906, 80.69169390245473, 1),
            ("e", -53.326186127330644, -56.956657579949585, 0),
        ]
        for (idx, exp) in expected.enumerated() {
            XCTAssertEqual(placed[idx].id, exp.0)
            XCTAssertEqual(placed[idx].x, exp.1, accuracy: 1e-9)
            XCTAssertEqual(placed[idx].y, exp.2, accuracy: 1e-9)
            XCTAssertEqual(placed[idx].degree, exp.3)
        }

        let box = KnowledgeGraphLogic.bounds(of: placed)
        XCTAssertEqual(box.x, -113.32618612733064, accuracy: 1e-9)
        XCTAssertEqual(box.y, -116.95665757994959, accuracy: 1e-9)
        XCTAssertEqual(box.width, 222.20360009295499, accuracy: 1e-9)
        XCTAssertEqual(box.height, 257.64835148240434, accuracy: 1e-9)

        let emptyBox = KnowledgeGraphLogic.bounds(of: [])
        XCTAssertEqual(emptyBox, KnowledgeGraphBounds(x: -100, y: -100, width: 200, height: 200))
    }

    func testGraphFilteringNeighborhoodAndHitTesting() {
        let network = KnowledgeNetwork(
            nodes: [
                KnowledgeNetworkNode(id: "p1", title: "Alpha", path: "Docs/Alpha", audience: .private),
                KnowledgeNetworkNode(id: "p2", title: "Beta", path: "Docs/Beta", audience: .shared),
                KnowledgeNetworkNode(id: "p3", title: "Gamma", path: "Campaign/Gamma", audience: .private),
                KnowledgeNetworkNode(id: "p4", title: "Orphan", path: "Orphan", audience: .private),
                KnowledgeNetworkNode(id: "p5", title: "Agent Note", path: "Agent/Note", audience: .agent),
            ],
            links: [
                KnowledgeNetworkLink(source: "p1", target: "p2"),
                KnowledgeNetworkLink(source: "p2", target: "p3"),
                KnowledgeNetworkLink(source: "p1", unresolved: "Missing Page"),
            ]
        )

        // Default excludes agent nodes and unresolved ghost nodes, includes orphans.
        let globalSnap = KnowledgeGraphLogic.buildSnapshot(
            network: network,
            filter: KnowledgeGraphFilter(showOrphans: true, showUnresolved: false, includeAgent: false)
        )
        XCTAssertEqual(Set(globalSnap.nodes.map(\.id)), Set(["p1", "p2", "p3", "p4"]))
        XCTAssertEqual(globalSnap.unresolvedCount, 1)

        // Hide orphans and show unresolved ghost node.
        let unresolvedSnap = KnowledgeGraphLogic.buildSnapshot(
            network: network,
            filter: KnowledgeGraphFilter(showOrphans: false, showUnresolved: true, includeAgent: false)
        )
        XCTAssertFalse(unresolvedSnap.nodes.contains(where: { $0.id == "p4" }))
        XCTAssertTrue(unresolvedSnap.nodes.contains(where: { $0.isUnresolved && $0.title == "Missing Page" }))

        // Local 1-hop neighborhood from p1 includes p1 and p2, not p3.
        let localSnap = KnowledgeGraphLogic.buildSnapshot(
            network: network,
            filter: KnowledgeGraphFilter(showOrphans: true, scope: .local, focusPageId: "p1", hops: 1)
        )
        XCTAssertEqual(Set(localSnap.nodes.map(\.id)), Set(["p1", "p2"]))

        // Viewport world <-> screen round-trip and hit-testing.
        let vp = KnowledgeGraphViewport(panX: 12, panY: -8, scale: 1.8)
        let targetNode = globalSnap.nodes[0]
        let screen = vp.worldToScreen(x: targetNode.x, y: targetNode.y, bounds: globalSnap.bounds, canvasWidth: 900, canvasHeight: 600)
        let roundTrip = vp.screenToWorld(x: screen.x, y: screen.y, bounds: globalSnap.bounds, canvasWidth: 900, canvasHeight: 600)
        XCTAssertEqual(roundTrip.x, targetNode.x, accuracy: 1e-6)
        XCTAssertEqual(roundTrip.y, targetNode.y, accuracy: 1e-6)

        let hit = KnowledgeGraphLogic.hitTest(worldPoint: (targetNode.x + 1, targetNode.y - 1), nodes: globalSnap.nodes, minHitRadius: 10)
        XCTAssertEqual(hit?.id, targetNode.id)
        XCTAssertNil(KnowledgeGraphLogic.hitTest(worldPoint: (99999, 99999), nodes: globalSnap.nodes, minHitRadius: 10))
    }

    // MARK: - Backlinks & Unlinked Mentions

    func testBacklinksOutgoingAndUnlinkedMentions() {
        let network = KnowledgeNetwork(
            nodes: [
                KnowledgeNetworkNode(id: "target", title: "Watchtower", path: "Locations/Watchtower"),
                KnowledgeNetworkNode(id: "src1", title: "Session 1", path: "Sessions/Session 1"),
                KnowledgeNetworkNode(id: "src2", title: "Harbour", path: "Locations/Harbour"),
            ],
            links: [
                KnowledgeNetworkLink(source: "src1", target: "target"),
                KnowledgeNetworkLink(source: "target", target: "src2"),
                KnowledgeNetworkLink(source: "target", unresolved: "Old Keep"),
            ]
        )

        let backlinks = KnowledgePanelsLogic.backlinks(for: "target", in: network)
        XCTAssertEqual(backlinks.map(\.id), ["src1"])

        let outgoing = KnowledgePanelsLogic.outgoingLinks(for: "target", in: network)
        XCTAssertEqual(outgoing.resolved.map(\.id), ["src2"])
        XCTAssertEqual(outgoing.unresolved, ["Old Keep"])

        let page = KnowledgePage(
            id: "target",
            title: "Watchtower",
            properties: ["aliases": .array([.string("North Tower")])]
        )
        let candidates = [
            KnowledgePageRow(id: "src1", title: "Session 1", path: "Sessions/Session 1", summary: "Visited the Watchtower."),
            KnowledgePageRow(id: "src2", title: "Harbour", path: "Locations/Harbour", summary: "South of the North Tower along the cliffs."),
            KnowledgePageRow(id: "src3", title: "Notes", path: "Notes", summary: "Already linked [[Watchtower]] here."),
        ]
        let mentions = KnowledgePanelsLogic.findUnlinkedMentions(of: page, in: candidates, linkedSourceIds: ["src1"])
        XCTAssertEqual(mentions.map(\.pageId), ["src2"])
        XCTAssertEqual(mentions.first?.matchedTerm, "North Tower")

        // Linking skips existing wikilinks and inline code.
        let md = "See `Watchtower` and [[Watchtower]] before visiting the north tower."
        let linked = KnowledgePanelsLogic.linkFirstMention(in: md, term: "North Tower", targetTitle: "Watchtower")
        XCTAssertEqual(linked, "See `Watchtower` and [[Watchtower]] before visiting the [[Watchtower|north tower]].")
        XCTAssertNil(KnowledgePanelsLogic.linkFirstMention(in: "Only [[Watchtower]] here.", term: "Watchtower", targetTitle: "Watchtower"))
    }

    // MARK: - Typed Properties Inspector

    func testPropertiesEditingAndTags() {
        var props: [String: JSONValue] = [
            "tags": .array([.string("dnd")]),
            "status": .string("active"),
            "score": .double(9.5),
            "published": .bool(true),
            "due": .string("2026-11-30"),
            "aliases": .array([.string("Keep")]),
            "zettel_id": .string("20261122"),
        ]

        let fields = KnowledgePanelsLogic.editableProperties(from: props)
        XCTAssertFalse(fields.contains(where: { $0.key == "tags" || $0.key == "zettel_id" }))
        XCTAssertEqual(fields.first(where: { $0.key == "status" })?.type, .text)
        XCTAssertEqual(fields.first(where: { $0.key == "score" })?.type, .number)
        XCTAssertEqual(fields.first(where: { $0.key == "published" })?.type, .bool)
        XCTAssertEqual(fields.first(where: { $0.key == "due" })?.type, .date)
        XCTAssertEqual(fields.first(where: { $0.key == "aliases" })?.type, .list)

        props = KnowledgePanelsLogic.settingProperty("rating", value: KnowledgePanelsLogic.parsePropertyValue("5", as: .number), in: props)
        XCTAssertEqual(props["rating"], .int(5))

        props = KnowledgePanelsLogic.removingProperty("status", from: props)
        XCTAssertNil(props["status"])

        props = KnowledgePanelsLogic.addingTag("#Campaign", to: props)
        props = KnowledgePanelsLogic.addingTag("dnd", to: props) // case-insensitive dedup
        XCTAssertEqual(KnowledgeShellLogic.tags(of: props), ["dnd", "Campaign"])

        props = KnowledgePanelsLogic.removingTag("DND", from: props)
        XCTAssertEqual(KnowledgeShellLogic.tags(of: props), ["Campaign"])
    }

    // MARK: - Query Table Columns, Filtering & Sorting

    func testQueryTableColumnsFormattingFilterAndSort() {
        let rows = [
            KnowledgePageRow(
                id: "1",
                title: "Mara",
                path: "NPCs/Mara",
                audience: .private,
                properties: [
                    "role": .string("Scout"),
                    "location": .string("[[Locations/Watchtower|The Tower]]"),
                    "tags": .array([.string("npc")]),
                ],
                updatedAt: "2026-11-20T10:00:00Z"
            ),
            KnowledgePageRow(
                id: "2",
                title: "Bram",
                path: "NPCs/Bram",
                audience: .shared,
                properties: [
                    "role": .string("Blacksmith"),
                    "location": .string("[[Locations/Harbour]]"),
                    "tags": .array([.string("npc"), .string("merchant")]),
                ],
                updatedAt: "2026-11-21T10:00:00Z"
            ),
        ]

        let cols = KnowledgePanelsLogic.queryTableColumns(for: rows)
        XCTAssertEqual(cols, ["location", "role"])
        XCTAssertEqual(KnowledgePanelsLogic.formatQueryCell(rows[0].properties["location"]), "The Tower")
        XCTAssertEqual(KnowledgePanelsLogic.formatQueryCell(rows[1].properties["location"]), "Harbour")

        let sortedAsc = KnowledgePanelsLogic.filterAndSortQueryRows(rows, filterText: "", sortColumn: .title, direction: .ascending)
        XCTAssertEqual(sortedAsc.map(\.id), ["2", "1"])

        let filtered = KnowledgePanelsLogic.filterAndSortQueryRows(rows, filterText: "harbour", sortColumn: .updatedAt, direction: .descending)
        XCTAssertEqual(filtered.map(\.id), ["2"])
    }

    // MARK: - Diff Engine & Review Decisions

    func testDiffLinesWordSegmentsAndReviewDecisions() {
        let diff = KnowledgePanelsLogic.diffLines(
            before: "Header\nThe quick brown fox\nFooter",
            after: "Header\nThe fast brown wolf\nFooter"
        )
        XCTAssertEqual(diff.map(\.kind), [.unchanged, .removed, .added, .unchanged])
        XCTAssertTrue(diff[1].segments.contains(where: { $0.text == "quick" && $0.isChanged }))
        XCTAssertTrue(diff[2].segments.contains(where: { $0.text == "fast" && $0.isChanged }))
        XCTAssertTrue(diff[1].segments.contains(where: { $0.text.contains("brown") && !$0.isChanged }))

        let reviewPending = KnowledgeReview(
            id: "rev-1",
            state: "pending",
            changes: [
                KnowledgePageChange(raw: ["index": .int(0), "state": .string("pending"), "before": .string("a"), "after": .string("b")]),
                KnowledgePageChange(raw: ["index": .int(1), "state": .string("stale"), "before": .string("c"), "after": .string("d")]),
            ]
        )
        let reviewPast = KnowledgeReview(
            id: "rev-0",
            state: "accepted",
            changes: [
                KnowledgePageChange(raw: ["index": .int(0), "state": .string("accepted")]),
            ]
        )
        let page = KnowledgePage(id: "p1", title: "Spec", reviews: [reviewPending, reviewPast])

        let pending = KnowledgePanelsLogic.pendingChanges(in: page)
        XCTAssertEqual(pending.count, 2)
        XCTAssertFalse(pending[0].isStale)
        XCTAssertTrue(pending[1].isStale)
        XCTAssertEqual(KnowledgePanelsLogic.pastReviews(in: page).map(\.id), ["rev-0"])

        let bulk = KnowledgePanelsLogic.bulkDecisions(for: page, accept: true)
        XCTAssertEqual(bulk.count, 1)
        XCTAssertEqual(bulk[0].reviewId, "rev-1")
        XCTAssertEqual(bulk[0].decisions, [KnowledgeReviewDecision(index: 0, accept: true)])

        let rejected = KnowledgePanelsLogic.singleDecision(for: pending[0], accept: false, reason: "  Keep original phrasing  ")
        XCTAssertEqual(rejected, KnowledgeReviewDecision(index: 0, accept: false, reason: "Keep original phrasing"))
    }
}
