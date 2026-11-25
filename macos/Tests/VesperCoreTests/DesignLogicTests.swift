import Foundation
import Testing
@testable import VesperCore

struct DesignLogicTests {
    @Test func interMetricsLoadFromBundleAndMeasureDeterministically() {
        let w1 = DesignMetrics.measure(text: "Hello World", weight: 400, italic: false, size: 16)
        let w2 = DesignMetrics.measure(text: "Hello World", weight: 700, italic: false, size: 16)
        #expect(w1 > 70 && w1 < 110)
        #expect(w2 >= w1)
        #expect(DesignMetrics.face(weight: 400, italic: false).asc > 0.9)
    }

    @Test func autoLayoutPositionsChildrenAndSettleWritesCachedBoxes() throws {
        let child1 = DesignNode(id: "n_c1", type: .shape, x: 0, y: 0, w: 100, h: 40, fill: .color("#3B6FE0"), shape: "rect")
        let child2 = DesignNode(id: "n_c2", type: .shape, x: 0, y: 0, w: 120, h: 40, fill: .color("#4CB782"), shape: "rect")
        let frame = DesignNode(
            id: "n_frame1",
            type: .frame,
            name: "Card",
            x: 10, y: 20, w: 200, h: 200,
            sizing: DesignSizing(w: "hug", h: "hug"),
            fill: .color("#FFFFFF"),
            children: [child1, child2],
            autoLayout: DesignAutoLayout(direction: "vertical", gap: 12, padding: [16, 16, 16, 16])
        )
        let doc = DesignDocument(pages: [DesignPage(id: "p_1", name: "Page 1", children: [frame])])
        let settled = DesignLayoutEngine.settle(doc)
        let f = settled.pages[0].children[0]
        #expect(f.w == 152) // 16 + 120 + 16
        #expect(f.h == 124) // 16 + 40 + 12 + 40 + 16
        #expect(f.children?[0].y == 16)
        #expect(f.children?[1].y == 68) // 16 + 40 + 12

        // Round-trip canonical JSON
        let json = try DesignSchema.encodeCanonical(settled)
        let decoded = try DesignSchema.parse(json)
        #expect(decoded == settled)
    }

    @Test func orthogonalConnectorRouterAvoidsObstacle() {
        let from = DesignBox(x: 0, y: 100, w: 100, h: 60)
        let to = DesignBox(x: 300, y: 100, w: 100, h: 60)
        let obstacle = DesignBox(x: 150, y: 80, w: 100, h: 100)
        let pts = DesignConnectorRouter.connectorPath(fb: from, tb: to, fromAnchor: "right", toAnchor: "left", obstacles: [obstacle])
        #expect(pts.count >= 4)
        #expect(pts.first == DesignPt(100, 130))
        #expect(pts.last == DesignPt(300, 130))
    }

    @Test func prototypePlayerFollowsLinksAndNavigatesBack() {
        let f1 = DesignEditLogic.newFrame(DesignBox(x: 0, y: 0, w: 393, h: 852), name: "Home")
        let f2 = DesignEditLogic.newFrame(DesignBox(x: 450, y: 0, w: 393, h: 852), name: "Detail")
        var doc = DesignDocument(pages: [DesignPage(id: "p_1", name: "Page 1", children: [f1, f2])])
        let added = DesignPrototypeLogic.addLink(in: doc, from: f1.id)
        #expect(added != nil)
        doc = added!.design
        #expect(DesignPrototypeLogic.hotspotsOf(doc, frameId: f1.id).count == 1)

        var player = DesignPrototypePlayer(start: f1.id)
        player.follow(to: f2.id)
        #expect(player.at == f2.id)
        #expect(player.goBack() == f2.id)
        #expect(player.at == f1.id)
    }

    @Test func proposalReviewDependenciesCascadeAcceptAndReject() {
        let ops: [[String: JSONValue]] = [
            ["op": .string("add_node"), "parent": .string("p_1"), "node": .object(["id": .string("n_new1"), "type": .string("text")])],
            ["op": .string("set_text"), "id": .string("n_new1"), "text": .string("Updated")],
        ]
        let deps = DesignReviewLogic.dependencies(ops: ops)
        #expect(deps == [[], [0]])

        let accepted = DesignReviewLogic.decide(deps: deps, decisions: [:], index: 1, state: .accepted)
        #expect(accepted[0]?.state == .accepted && accepted[1]?.state == .accepted)

        let rejected = DesignReviewLogic.decide(deps: deps, decisions: accepted, index: 0, state: .rejected)
        #expect(rejected[0]?.state == .rejected && rejected[1]?.state == .rejected)
    }

    @Test func inspectCodegenAndSvgPdfExportersWork() {
        let frame = DesignEditLogic.newFrame(DesignBox(x: 0, y: 0, w: 320, h: 200), name: "Login Card")
        let doc = DesignDocument(pages: [DesignPage(id: "p_1", name: "Page 1", children: [frame])])
        let laid = DesignLayoutEngine(design: doc).layoutPage(doc.pages[0])

        let css = DesignInspectLogic.generateCode(design: doc, node: frame, box: laid.boxes[frame.id]!, target: .css)
        #expect(css.contains(".login-card"))
        #expect(css.contains("width: 320"))

        let svg = DesignExporters.exportSVG(box: laid.box, ops: laid.allOps, background: "#0C0C10")
        #expect(svg.contains("<svg"))
        #expect(svg.contains("<rect"))

        let pdf = DesignExporters.exportPDF(items: [(laid.box, laid.allOps, "#0C0C10")], images: [:])
        #expect(String(decoding: pdf.prefix(5), as: UTF8.self) == "%PDF-")
    }

    @Test func designRoutesResolveToNativeScreens() {
        let reg = NativeRouteRegistry.standard(debug: false)
        let edit = reg.resolve("/apps/designs/01des?review=1")
        #expect(edit?.screen == .designEditor)
        #expect(edit?.params["id"] == "01des")
        #expect(edit?.query["review"] == "1")

        let pres = reg.resolve("/present/designs/01des?start=n_frame1")
        #expect(pres?.screen == .designPresent)
        #expect(pres?.params["id"] == "01des")
        #expect(pres?.query["start"] == "n_frame1")
    }

    @Test func withPlainTextHandlesEmptyParagraphs() {
        let paras = DesignEditLogic.withPlainText([], text: "Hello\nWorld")
        #expect(paras.count == 2)
        #expect(paras[0].runs.first?.text == "Hello")
        #expect(paras[1].runs.first?.text == "World")
    }

    @Test func mergeAndRouterTolerateDuplicateIDsAndNegativeObstacles() {
        let dupA = DesignNode(id: "n_dup", type: .shape, x: 0, y: 0, w: 50, h: 50, shape: "rect")
        let dupB = DesignNode(id: "n_dup", type: .shape, x: 60, y: 0, w: 50, h: 50, shape: "rect")
        let base = DesignDocument(pages: [
            DesignPage(id: "p_dup", name: "One", children: [dupA, dupB]),
            DesignPage(id: "p_dup", name: "Two", children: [dupA]),
        ])
        var mine = base
        mine.pages[1].name = "Two edited"
        let merged = DesignMergeLogic.mergeDesigns(base: base, mine: mine, theirs: base)
        #expect(merged != nil)

        // Negative obstacle dimensions must not trap closed range in orthogonal router
        let from = DesignBox(x: 0, y: 100, w: 100, h: 60)
        let to = DesignBox(x: 300, y: 100, w: 100, h: 60)
        let negObstacle = DesignBox(x: 200, y: 180, w: -80, h: -90)
        let pts = DesignConnectorRouter.connectorPath(fb: from, tb: to, fromAnchor: "right", toAnchor: "left", obstacles: [negObstacle])
        #expect(pts.count >= 2)
    }
}
