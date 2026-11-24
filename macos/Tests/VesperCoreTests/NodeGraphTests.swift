import XCTest
@testable import VesperCore

final class NodeGraphTests: XCTestCase {
    // MARK: - ELKLayoutEngine (JavaScriptCore offline bundle)

    func testELKLayoutEngineLaysOutChainDeterministically() async throws {
        let graph = ELKGraph(
            id: "root",
            layoutOptions: ELKGraph.defaultLayeredOptions,
            children: [
                ELKNode(id: "a", width: 132, height: 52),
                ELKNode(id: "b", width: 132, height: 52),
                ELKNode(id: "c", width: 132, height: 52),
            ],
            edges: [
                ELKEdge(id: "e1", sources: ["a"], targets: ["b"]),
                ELKEdge(id: "e2", sources: ["b"], targets: ["c"]),
            ]
        )

        let laid1 = try await ELKLayoutEngine.shared.layout(graph: graph)
        let laid2 = try await ELKLayoutEngine.shared.layout(graph: graph)
        XCTAssertEqual(laid1, laid2, "ELK layout should be deterministic across runs")

        let byId = Dictionary(uniqueKeysWithValues: laid1.children.map { ($0.id, $0) })
        let a = try XCTUnwrap(byId["a"])
        let b = try XCTUnwrap(byId["b"])
        let c = try XCTUnwrap(byId["c"])

        XCTAssertNotNil(a.x)
        XCTAssertNotNil(b.x)
        XCTAssertNotNil(c.x)
        XCTAssertLessThan(a.x! + a.width, b.x!, "a should be placed left of b")
        XCTAssertLessThan(b.x! + b.width, c.x!, "b should be placed left of c")

        let e1 = try XCTUnwrap(laid1.edges.first { $0.id == "e1" })
        let section = try XCTUnwrap(e1.sections?.first)
        XCTAssertEqual(section.startPoint.x, a.x! + a.width, accuracy: 0.5)
        XCTAssertEqual(section.endPoint.x, b.x!, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(section.polyline.count, 2)
    }

    func testELKLayoutEngineHandlesBranchingDAG() async throws {
        let graph = ELKGraph(
            id: "dag",
            layoutOptions: ELKGraph.defaultLayeredOptions,
            children: [
                ELKNode(id: "start", width: 160, height: 64),
                ELKNode(id: "left", width: 160, height: 64),
                ELKNode(id: "right", width: 160, height: 64),
                ELKNode(id: "merge", width: 160, height: 64),
            ],
            edges: [
                ELKEdge(id: "e1", sources: ["start"], targets: ["left"]),
                ELKEdge(id: "e2", sources: ["start"], targets: ["right"]),
                ELKEdge(id: "e3", sources: ["left"], targets: ["merge"]),
                ELKEdge(id: "e4", sources: ["right"], targets: ["merge"]),
            ]
        )

        let laid = try await ELKLayoutEngine.shared.layout(graph: graph)
        let byId = Dictionary(uniqueKeysWithValues: laid.children.map { ($0.id, $0) })
        let start = try XCTUnwrap(byId["start"])
        let left = try XCTUnwrap(byId["left"])
        let right = try XCTUnwrap(byId["right"])
        let merge = try XCTUnwrap(byId["merge"])

        XCTAssertLessThan(start.x!, left.x!)
        XCTAssertLessThan(left.x!, merge.x!)
        XCTAssertNotEqual(left.y!, right.y!, "parallel branches should not overlap vertically")
        XCTAssertEqual(laid.edges.count, 4)
        XCTAssertTrue(laid.edges.allSatisfy { ($0.sections?.first?.polyline.count ?? 0) >= 2 })
    }

    // MARK: - NodeGraphViewport & NodeGraphDocument

    func testViewportPanZoomMomentumAndFit() {
        var vp = NodeGraphViewport(offset: GraphPoint(x: 10, y: 20), scale: 1.0)
        let screenAnchor = GraphPoint(x: 200, y: 150)
        let beforeGraph = vp.screenToGraph(screenAnchor)
        vp.zoom(factor: 2.0, around: screenAnchor)
        XCTAssertEqual(vp.scale, 2.0, accuracy: 1e-6)
        let afterGraph = vp.screenToGraph(screenAnchor)
        XCTAssertEqual(beforeGraph.x, afterGraph.x, accuracy: 1e-6)
        XCTAssertEqual(beforeGraph.y, afterGraph.y, accuracy: 1e-6)

        vp.pan(by: GraphPoint(x: 30, y: -15))
        vp.velocity = GraphPoint(x: 120, y: 0)
        XCTAssertTrue(vp.stepMomentum(dt: 1.0 / 60.0))
        XCTAssertLessThan(vp.velocity.x, 120)

        vp.fitToView(
            contentBounds: GraphRect(x: 0, y: 0, width: 800, height: 400),
            viewportSize: GraphSize(width: 472, height: 472),
            padding: 36
        )
        XCTAssertEqual(vp.scale, 0.5, accuracy: 1e-6)
    }

    func testDocumentHitTestingMoveConnectCyclePreventionAndDelete() {
        var doc = NodeGraphDocument(
            nodes: [
                NodeGraphNodeModel(id: "a", title: "A", frame: GraphRect(x: 0, y: 0, width: 100, height: 50), hasInputPort: false, deletable: false),
                NodeGraphNodeModel(id: "b", title: "B", frame: GraphRect(x: 200, y: 0, width: 100, height: 50)),
                NodeGraphNodeModel(id: "c", title: "C", frame: GraphRect(x: 400, y: 0, width: 100, height: 50), hasOutputPort: false),
            ],
            edges: [
                NodeGraphEdgeModel(id: "a->b", from: "a", to: "b"),
            ]
        )

        XCTAssertEqual(doc.hitTest(graphPoint: GraphPoint(x: 100, y: 25), interactive: true), .port(nodeId: "a", kind: .output))
        XCTAssertEqual(doc.hitTest(graphPoint: GraphPoint(x: 50, y: 25), interactive: true), .node(id: "a"))
        XCTAssertEqual(doc.hitTest(graphPoint: GraphPoint(x: 150, y: 25), interactive: false), .edge(id: "a->b"))
        XCTAssertEqual(doc.hitTest(graphPoint: GraphPoint(x: 50, y: 200), interactive: true), .none)

        // Cycle prevention & port rules
        XCTAssertTrue(doc.canConnect(from: "b", to: "c"))
        XCTAssertFalse(doc.canConnect(from: "b", to: "a"), "would create a cycle")
        XCTAssertFalse(doc.canConnect(from: "c", to: "b"), "c has no output port")
        XCTAssertNotNil(doc.connect(from: "b", to: "c"))
        XCTAssertFalse(doc.canConnect(from: "b", to: "c"), "duplicate edge")

        doc.moveNode(id: "b", to: GraphPoint(x: 220, y: 40))
        XCTAssertEqual(doc.node(id: "b")?.frame.origin, GraphPoint(x: 220, y: 40))

        XCTAssertFalse(doc.removeNode(id: "a"), "non-deletable trigger")
        XCTAssertTrue(doc.removeNode(id: "b"))
        XCTAssertTrue(doc.edges.isEmpty)
    }

    // MARK: - RunGraphLogic

    func testRunGraphGroupingAndNestedRuns() {
        let turns: [RunGraphLogic.GraphNode] = (1...20).map { i in
            .turn(.init(id: "turn:\(i)", turn: i, trigger: i == 1 ? "start" : "resume", status: i == 20 ? .running : .done, startedAt: ""))
        }
        var edges: [RunGraphLogic.GraphEdge] = (1..<20).map { i in
            .init(id: "seq:\(i)", kind: .sequence, from: "turn:\(i)", to: "turn:\(i + 1)")
        }
        let subA = RunGraphLogic.GraphNode.subagentRun(.init(id: "run:a", runId: "a", agent: "coder", status: .done, costUsd: 0.12, depth: 1, childCount: 1, expanded: true))
        let subB = RunGraphLogic.GraphNode.subagentRun(.init(id: "run:b", runId: "b", agent: "reviewer", status: .done, costUsd: 0.05, depth: 2, childCount: 0, expanded: false))
        edges.append(.init(id: "del:1", kind: .delegation, from: "turn:10", to: "run:a"))
        edges.append(.init(id: "del:2", kind: .delegation, from: "run:a", to: "run:b"))

        let graph = RunGraphLogic.RunGraph(nodes: turns + [subA, subB], edges: edges)
        let layout = RunGraphLogic.layoutRunGraph(graph, expanded: [], keep: ["turn:15"])
        let mainIds = layout.columns.map(\.main.id)

        XCTAssertEqual(mainIds.first, "group:1")
        XCTAssertTrue(mainIds.contains("turn:10"))
        XCTAssertTrue(mainIds.contains("turn:15"))
        XCTAssertEqual(mainIds.last, "turn:20")

        let col10 = layout.columns.first { $0.main.id == "turn:10" }
        XCTAssertEqual(col10?.branch.map(\.id), ["run:a", "more:run:a"])

        let expandedLayout = RunGraphLogic.layoutRunGraph(graph, expanded: ["run:a"], keep: [])
        let expandedCol10 = expandedLayout.columns.first { $0.main.id == "turn:10" }
        XCTAssertEqual(expandedCol10?.branch.map(\.id), ["run:a", "run:b"])
    }

    func testRunGraphBuildsSubagentJobsAndBranchesUnderTurn() {
        let run = API.Run(
            agent: .init(colorIndex: 0, handle: "judy", id: "a1", name: "Judy"),
            approvalScopes: [],
            costUsd: 0.10,
            harness: "claude-code",
            id: "r1",
            inputTokens: 1000,
            mode: .init(rawValue: "auto"),
            model: "opus-5.5",
            outputTokens: 200,
            plan: [],
            purpose: .chat,
            scopes: [],
            startedAt: "2026-11-24T20:00:00Z",
            state: .running,
            ticketKey: "",
            toolCalls: 2
        )
        let turn = API.RunTurn(
            endedAt: nil,
            exitCode: nil,
            hasLog: false,
            inputMessage: "Fix DAG",
            processStartedAt: nil,
            seq: 1,
            startedAt: "2026-11-24T20:00:00Z",
            status: .running,
            trigger: .start,
            usage: nil
        )
        let job = API.SubagentJob(
            agentType: .explorer,
            batchId: .value("batch-1"),
            cachedTokens: 100,
            completedAt: .value("2026-11-24T20:00:12Z"),
            costUsd: .value(0.015),
            createdAt: "2026-11-24T20:00:02Z",
            effort: "low",
            error: "",
            id: "job-1",
            inputTokens: 500,
            model: "haiku",
            outputTokens: 120,
            prompt: "Find files",
            reason: "Fast search",
            requestedTier: "deep",
            resultText: "Found it",
            role: "Codebase Researcher",
            startedAt: .value("2026-11-24T20:00:03Z"),
            status: .completed,
            tier: "fast",
            toolCalls: 4
        )
        let detail = API.RunDetail(
            approvals: [],
            childRuns: [],
            events: [
                API.RunEvent(at: "2026-11-24T20:00:00Z", payload: ["state": .string("turn_started"), "turn": .int(1)], seq: 1, type: .lifecycle),
                API.RunEvent(at: "2026-11-24T20:00:02Z", payload: ["state": .string("subagent_started"), "subagent_id": .string("job-1")], seq: 2, type: .lifecycle),
            ],
            run: run,
            subagentJobs: [job],
            turns: [turn]
        )

        let graph = RunGraphLogic.buildRunGraph(detail: detail)
        let layout = RunGraphLogic.layoutRunGraph(graph)
        let col1 = layout.columns.first { $0.main.id == "turn:1" }
        XCTAssertEqual(col1?.branch.map { $0.id }, ["job:job-1"])

        let doc = RunGraphLogic.buildDocument(from: layout)
        let jobDocNode = doc.nodes.first { $0.id == "job:job-1" }
        XCTAssertEqual(jobDocNode?.title, "↳ Codebase Researcher")
        XCTAssertTrue(jobDocNode?.subtitle.contains("capped ↓") == true)
        XCTAssertTrue(doc.edges.contains { $0.from == "turn:1" && $0.to == "job:job-1" })
    }

    // MARK: - WorkflowsLogic

    func testWorkflowsLogicConnectionsAncestorsRemoveDiffAndGates() {
        let start = API.WorkflowNode(config: .init(), id: "start", title: "Start", type: .trigger, x: 0, y: 0)
        let work = API.WorkflowNode(config: .init(imageEngine: "codex", images: true), id: "work", title: "Work", type: .agent, x: 200, y: 0)
        let check = API.WorkflowNode(config: .init(check: true), id: "check", title: "Check", type: .agent, x: 400, y: 0)
        let gate = API.WorkflowNode(config: .init(maxAttempts: 2, requiresCheck: "check", retryFrom: "work"), id: "ok", title: "Review", type: .gate, x: 600, y: 0)
        let wiki = API.WorkflowNode(config: .init(path: "Docs/Out"), id: "page", title: "Wiki", type: .wiki, x: 800, y: 0)

        let graph = API.WorkflowGraph(
            edges: [
                .init(from: "start", to: "work"),
                .init(from: "work", to: "check"),
                .init(from: "check", to: "ok"),
                .init(from: "ok", to: "page"),
            ],
            nodes: [start, work, check, gate, wiki]
        )

        XCTAssertEqual(WorkflowsLogic.nodeSummary(work), "Persona · images · Codex")
        XCTAssertEqual(WorkflowsLogic.imageEngineName("antigravity"), "Antigravity")
        XCTAssertEqual(WorkflowsLogic.imageEngineName("gemini"), "Gemini API")
        XCTAssertEqual(WorkflowsLogic.imageEngineName(nil), "default engine")

        XCTAssertTrue(WorkflowsLogic.canConnect(in: graph, from: "start", to: "ok"))
        XCTAssertFalse(WorkflowsLogic.canConnect(in: graph, from: "ok", to: "work"), "cycle")
        XCTAssertFalse(WorkflowsLogic.canConnect(in: graph, from: "page", to: "ok"), "output cannot connect")
        XCTAssertFalse(WorkflowsLogic.canConnect(in: graph, from: "work", to: "start"), "cannot target trigger")

        XCTAssertEqual(WorkflowsLogic.ancestors(in: graph, of: "page").map(\.id), ["start", "work", "check", "ok"])
        XCTAssertEqual(WorkflowsLogic.parentChecks(in: graph, of: "ok").map(\.id), ["check"])
        XCTAssertEqual(WorkflowsLogic.gateSources(in: graph, gate: gate), ["check"])
        XCTAssertTrue(WorkflowsLogic.canRequestChanges(gate: gate, attempt: 1))
        XCTAssertFalse(WorkflowsLogic.canRequestChanges(gate: gate, attempt: 2))

        let failedStep = API.WorkflowStep(agentRunId: nil, attempt: 1, checkResult: "failed", createdAt: "", decision: "", finishedAt: nil, images: nil, nodeId: "check", note: "", output: "", state: .done)
        let passedStep = API.WorkflowStep(agentRunId: nil, attempt: 1, checkResult: "passed", createdAt: "", decision: "", finishedAt: nil, images: nil, nodeId: "check", note: "", output: "", state: .done)
        XCTAssertEqual(WorkflowsLogic.failedGateCheck(in: graph, gate: gate, steps: [failedStep])?.id, "check")
        XCTAssertNil(WorkflowsLogic.failedGateCheck(in: graph, gate: gate, steps: [passedStep]))

        let removed = WorkflowsLogic.removeNode(from: graph, id: "work")
        XCTAssertNil(removed.nodes.first { $0.id == "ok" }?.config.retryFrom)
        XCTAssertFalse(removed.edges.contains { $0.from == "work" || $0.to == "work" })

        let diff = WorkflowsLogic.diffGraphs(base: graph, next: removed)
        XCTAssertEqual(diff.nodeDiffs["work"], NodeGraphDiffKind.removed)
        XCTAssertEqual(diff.nodeDiffs["ok"], NodeGraphDiffKind.changed)
        XCTAssertEqual(diff.removedEdges.count, 2)

        XCTAssertEqual(WorkflowsLogic.newNodeId(in: API.WorkflowGraph(edges: [], nodes: [
            API.WorkflowNode(config: .init(), id: "gate_1", title: "Gate", type: .gate, x: nil, y: nil),
        ]), type: .gate), "gate_2")

        let nav = WorkflowsLogic.buildWorkflowPaletteNavModel(disabled: true)
        XCTAssertEqual(nav.id, WorkflowsLogic.paletteNavId)
        XCTAssertEqual(nav.sections.count, 2)
        XCTAssertEqual(nav.sections[0].items.first?.disabled, true)

        let run = API.WorkflowRun(
            chatId: "chat-1",
            checkAttempts: [],
            createdAt: "2026-11-22T00:00:00Z",
            error: "",
            finishedAt: nil,
            graph: graph,
            id: "wfrun-1",
            images: nil,
            input: "Ship it",
            messageId: nil,
            name: "Release flow",
            state: .waiting,
            steps: [passedStep],
            version: 2,
            workflowId: "wf-1"
        )
        let runNav = WorkflowsLogic.buildWorkflowRunNavModel(run: run, selectedNodeId: "check")
        XCTAssertEqual(runNav.id, WorkflowsLogic.workflowRunNavId)
        XCTAssertEqual(runNav.title, "Release flow")
        XCTAssertEqual(runNav.selectedId, "step:check")
        XCTAssertEqual(runNav.actions?.map(\.id), [WorkflowsLogic.runBackAction, WorkflowsLogic.runOpenWorkflowAction])
        XCTAssertEqual(runNav.sections.first(where: { $0.id == "steps" })?.items.count, graph.nodes.count)
        XCTAssertEqual(
            WorkflowsLogic.workflowRunNavAction(for: .navAction(navigatorId: WorkflowsLogic.workflowRunNavId, actionId: WorkflowsLogic.runBackAction)),
            .back
        )
        XCTAssertEqual(
            WorkflowsLogic.workflowRunNavAction(for: .navAction(navigatorId: WorkflowsLogic.workflowRunNavId, actionId: WorkflowsLogic.runOpenWorkflowAction)),
            .openWorkflow
        )
        XCTAssertEqual(
            WorkflowsLogic.workflowRunNavAction(for: .navActivate(navigatorId: WorkflowsLogic.workflowRunNavId, itemId: "step:check")),
            .selectNode("check")
        )
    }
}
