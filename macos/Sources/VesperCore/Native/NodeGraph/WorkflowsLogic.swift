import Foundation

/// Pure Swift port of `web/lib/workflows.ts`, `web/lib/native-shell/models/workflows.ts`,
/// and `web/lib/native-shell/models/workflow-inspector.ts`.
public enum WorkflowsLogic {
    public static let workflowsNavId = "workflows"
    public static let paletteNavId = "workflow-palette"
    public static let defaultNodeWidth: Double = 176
    public static let defaultNodeHeight: Double = 72

    public struct PaletteItem: Sendable, Equatable, Identifiable {
        public var id: String { type.rawValue }
        public var type: API.WorkflowNode.TypeValue
        public var label: String

        public init(type: API.WorkflowNode.TypeValue, label: String) {
            self.type = type
            self.label = label
        }
    }

    public struct PaletteGroup: Sendable, Equatable, Identifiable {
        public var id: String { group.lowercased() }
        public var group: String
        public var items: [PaletteItem]

        public init(group: String, items: [PaletteItem]) {
            self.group = group
            self.items = items
        }
    }

    public static let palette: [PaletteGroup] = [
        PaletteGroup(group: "Steps", items: [
            PaletteItem(type: .enrich, label: "Enrich prompt"),
            PaletteItem(type: .agent, label: "Agent step"),
            PaletteItem(type: .gate, label: "Human gate"),
        ]),
        PaletteGroup(group: "Outputs", items: [
            PaletteItem(type: .wiki, label: "Add to wiki"),
            PaletteItem(type: .library, label: "Add to library"),
            PaletteItem(type: .ticket, label: "Create ticket"),
            PaletteItem(type: .chat, label: "Post to chat"),
        ]),
    ]

    public static func nodeLabel(_ type: API.WorkflowNode.TypeValue) -> String {
        switch type {
        case .trigger: "Trigger"
        case .enrich: "Enrich"
        case .agent: "Agent step"
        case .gate: "Human gate"
        case .wiki, .library, .ticket, .chat: "Output"
        default: type.rawValue.capitalized
        }
    }

    public static func isOutput(_ type: API.WorkflowNode.TypeValue) -> Bool {
        type == .wiki || type == .library || type == .ticket || type == .chat
    }

    public static func imageEngineName(_ engine: String?) -> String {
        switch engine {
        case "codex": "Codex"
        case "antigravity": "Antigravity"
        case "auto": "Auto engine"
        default: "default engine"
        }
    }

    public static func nodeSummary(_ node: API.WorkflowNode) -> String {
        let c = node.config
        switch node.type {
        case .trigger:
            return "outputs: input"
        case .enrich:
            return "Sharpens the request"
        case .agent:
            if c.check == true {
                if let retry = c.retryFrom, !retry.isEmpty { return "Check · re-runs \(retry)" }
                return "Check"
            }
            if c.images == true {
                return "Persona · images · \(imageEngineName(c.imageEngine))"
            }
            if let handle = c.agentHandle, !handle.isEmpty { return "@\(handle)" }
            return c.web == true ? "Persona · web" : "Persona · read-only"
        case .gate:
            if let req = c.requiresCheck, !req.isEmpty { return "Needs \(req) to pass" }
            if let retry = c.retryFrom, !retry.isEmpty { return "Can re-run \(retry)" }
            return "Approve or reject"
        case .wiki:
            return (c.path?.isEmpty == false) ? c.path! : "No path yet"
        case .library, .ticket:
            return (c.title?.isEmpty == false) ? c.title! : "No title yet"
        case .chat:
            return "Posts a message"
        default:
            return ""
        }
    }

    public static func newNodeId(in graph: API.WorkflowGraph, type: API.WorkflowNode.TypeValue) -> String {
        let existing = Set(graph.nodes.map(\.id))
        var i = 1
        while true {
            let candidate = "\(type.rawValue)_\(i)"
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
    }

    /// Every node that runs before `id`.
    public static func ancestors(in graph: API.WorkflowGraph, of id: String) -> [API.WorkflowNode] {
        var seen: Set<String> = []
        var stack: [String] = [id]
        while let cur = stack.popLast() {
            for e in graph.edges where e.to == cur && !seen.contains(e.from) {
                seen.insert(e.from)
                stack.append(e.from)
            }
        }
        return graph.nodes.filter { seen.contains($0.id) }
    }

    /// Whether connecting `from -> to` is allowed (no self-loop, no output source, no trigger target, no cycle).
    public static func canConnect(in graph: API.WorkflowGraph, from: String, to: String) -> Bool {
        guard from != to,
              let a = graph.nodes.first(where: { $0.id == from }),
              let b = graph.nodes.first(where: { $0.id == to }),
              !isOutput(a.type),
              b.type != .trigger else {
            return false
        }
        if graph.edges.contains(where: { $0.from == from && $0.to == to }) {
            return false
        }
        return !ancestors(in: graph, of: from).contains(where: { $0.id == to })
    }

    /// Removes a node, its incident edges, and any `retryFrom`/`requiresCheck`/`show` references to it.
    public static func removeNode(from graph: API.WorkflowGraph, id: String) -> API.WorkflowGraph {
        let nextNodes = graph.nodes
            .filter { $0.id != id }
            .map { node -> API.WorkflowNode in
                var copy = node
                if copy.config.retryFrom == id { copy.config.retryFrom = nil }
                if copy.config.requiresCheck == id { copy.config.requiresCheck = nil }
                if let show = copy.config.show, show.contains(id) {
                    copy.config.show = show.filter { $0 != id }
                }
                return copy
            }
        let nextEdges = graph.edges.filter { $0.from != id && $0.to != id }
        return API.WorkflowGraph(edges: nextEdges, nodes: nextNodes)
    }

    public struct GraphDiff: Sendable, Equatable {
        public var nodeDiffs: [String: NodeGraphDiffKind]
        public var removedNodes: [API.WorkflowNode]
        public var addedEdges: [API.WorkflowEdge]
        public var removedEdges: [API.WorkflowEdge]
    }

    public static func diffGraphs(base: API.WorkflowGraph, next: API.WorkflowGraph) -> GraphDiff {
        var nodeDiffs: [String: NodeGraphDiffKind] = [:]
        let baseById = Dictionary(uniqueKeysWithValues: base.nodes.map { ($0.id, $0) })
        let nextIds = Set(next.nodes.map(\.id))

        for n in next.nodes {
            if let old = baseById[n.id] {
                if old.type != n.type || old.title != n.title || old.config != n.config {
                    nodeDiffs[n.id] = .changed
                }
            } else {
                nodeDiffs[n.id] = .added
            }
        }
        let removedNodes = base.nodes.filter { !nextIds.contains($0.id) }
        for n in removedNodes { nodeDiffs[n.id] = .removed }

        func hasEdge(_ g: API.WorkflowGraph, _ e: API.WorkflowEdge) -> Bool {
            g.edges.contains { $0.from == e.from && $0.to == e.to }
        }
        return GraphDiff(
            nodeDiffs: nodeDiffs,
            removedNodes: removedNodes,
            addedEdges: next.edges.filter { !hasEdge(base, $0) },
            removedEdges: base.edges.filter { !hasEdge(next, $0) }
        )
    }

    public static func runActive(_ state: API.WorkflowRun.State) -> Bool {
        state == .running || state == .waiting
    }

    public static func runStateLabel(_ state: API.WorkflowRun.State) -> String {
        switch state {
        case .running: "Running"
        case .waiting: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        default: state.rawValue.capitalized
        }
    }

    public static func runStateTone(_ state: API.WorkflowRun.State) -> String {
        switch state {
        case .waiting: "human"
        case .done: "done"
        case .failed: "blocked"
        default: "neutral"
        }
    }

    public static func gateSources(in graph: API.WorkflowGraph, gate: API.WorkflowNode) -> [String] {
        if let show = gate.config.show, !show.isEmpty { return show }
        return graph.edges.filter { $0.to == gate.id }.map(\.from)
    }

    public static func parentChecks(in graph: API.WorkflowGraph, of id: String) -> [API.WorkflowNode] {
        graph.nodes.filter { node in
            node.type == .agent
                && node.config.check == true
                && graph.edges.contains(where: { $0.from == node.id && $0.to == id })
        }
    }

    public static func failedGateCheck(
        in graph: API.WorkflowGraph,
        gate: API.WorkflowNode,
        steps: [API.WorkflowStep]
    ) -> API.WorkflowNode? {
        guard let checkId = gate.config.requiresCheck, !checkId.isEmpty else { return nil }
        if let step = steps.first(where: { $0.nodeId == checkId }),
           step.state == .done,
           step.checkResult == "passed" {
            return nil
        }
        return graph.nodes.first(where: { $0.id == checkId })
            ?? API.WorkflowNode(config: .init(), id: checkId, title: checkId, type: .agent, x: nil, y: nil)
    }

    public static func canRequestChanges(gate: API.WorkflowNode, attempt: Int) -> Bool {
        guard let retry = gate.config.retryFrom, !retry.isEmpty else { return false }
        return attempt < (gate.config.maxAttempts ?? 3)
    }

    public static func imagesByAttempt(_ images: [API.WorkflowImage]) -> [(attempt: Int, images: [API.WorkflowImage])] {
        let grouped = Dictionary(grouping: images, by: \.attempt)
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    // MARK: - Graph <-> NodeGraphDocument & ELK Conversion

    public static func toNodeGraphDocument(
        graph: API.WorkflowGraph,
        selectedNodeId: String? = nil,
        selectedEdgeId: String? = nil,
        stepStatusByNodeId: [String: API.WorkflowStep.State] = [:],
        diff: GraphDiff? = nil
    ) -> NodeGraphDocument {
        let allNodes = graph.nodes + (diff?.removedNodes ?? [])
        let allEdges = graph.edges + (diff?.removedEdges ?? [])
        let addedEdgeKeys = Set((diff?.addedEdges ?? []).map { "\($0.from)->\($0.to)" })
        let removedEdgeKeys = Set((diff?.removedEdges ?? []).map { "\($0.from)->\($0.to)" })

        let docNodes = allNodes.enumerated().map { idx, n -> NodeGraphNodeModel in
            let x = n.x ?? Double(idx) * (defaultNodeWidth + 48) + 24
            let y = n.y ?? 80
            let status = stepStatusByNodeId[n.id]
            let d = diff?.nodeDiffs[n.id]
            let tone: NodeGraphTone
            switch status {
            case .running: tone = .accent
            case .waiting: tone = .human
            case .done: tone = .done
            case .failed: tone = .blocked
            default:
                if d == .added || d == .changed { tone = .accent }
                else if d == .removed { tone = .blocked }
                else if n.type == .gate { tone = .human }
                else { tone = .neutral }
            }
            let diffPrefix = d == .added ? "+ " : d == .changed ? "~ " : d == .removed ? "− " : ""
            return NodeGraphNodeModel(
                id: n.id,
                eyebrow: "\(diffPrefix)\(nodeLabel(n.type).uppercased())",
                title: n.title.isEmpty ? "Untitled" : n.title,
                subtitle: status == .waiting ? "Waiting for you" : nodeSummary(n),
                frame: GraphRect(x: x, y: y, width: defaultNodeWidth, height: defaultNodeHeight),
                shape: .card,
                tone: tone,
                isLive: status == .running,
                isDashed: d == .added || d == .removed,
                diff: d,
                hasInputPort: n.type != .trigger,
                hasOutputPort: !isOutput(n.type),
                deletable: n.type != .trigger
            )
        }

        let docEdges = allEdges.map { e -> NodeGraphEdgeModel in
            let key = "\(e.from)->\(e.to)"
            let isAdded = addedEdgeKeys.contains(key)
            let isRemoved = removedEdgeKeys.contains(key)
            return NodeGraphEdgeModel(
                id: key,
                from: e.from,
                to: e.to,
                tone: isAdded ? .accent : isRemoved ? .blocked : .neutral,
                isDashed: isAdded || isRemoved
            )
        }

        return NodeGraphDocument(
            nodes: docNodes,
            edges: docEdges,
            selectedNodeId: selectedNodeId,
            selectedEdgeId: selectedEdgeId
        )
    }

    public static func toELKGraph(_ graph: API.WorkflowGraph) -> ELKGraph {
        let children = graph.nodes.map {
            ELKNode(id: $0.id, width: defaultNodeWidth, height: defaultNodeHeight)
        }
        let edges = graph.edges.map {
            ELKEdge(id: "\($0.from)->\($0.to)", sources: [$0.from], targets: [$0.to])
        }
        return ELKGraph(id: "workflow", layoutOptions: ELKGraph.defaultLayeredOptions, children: children, edges: edges)
    }

    public static func applyingELKLayout(_ layout: ELKGraph, to graph: API.WorkflowGraph) -> API.WorkflowGraph {
        let posById = Dictionary(uniqueKeysWithValues: layout.children.map { ($0.id, $0) })
        let updatedNodes = graph.nodes.map { node -> API.WorkflowNode in
            var copy = node
            if let laid = posById[node.id], let x = laid.x, let y = laid.y {
                copy.x = x
                copy.y = y
            }
            return copy
        }
        return API.WorkflowGraph(edges: graph.edges, nodes: updatedNodes)
    }

    // MARK: - NavModel & Inspector Builders

    public static func buildWorkflowsNavModel(
        workflows: [API.Workflow],
        runs: [API.WorkflowRun],
        selectedId: String? = nil
    ) -> NavModel {
        var sections: [NavSection] = [
            NavSection(
                id: "workflows",
                items: workflows.map { w in
                    NavItem(
                        id: w.id,
                        title: w.name,
                        trailing: w.publishedVersion > 0 ? "v\(w.publishedVersion)" : "Draft",
                        href: "/workflows/\(w.id)"
                    )
                },
                emptyText: "No workflows yet"
            ),
        ]
        if !runs.isEmpty {
            sections.append(NavSection(
                id: "runs",
                title: "Recent runs",
                items: runs.prefix(20).map { r in
                    NavItem(id: "run:\(r.id)", title: r.name, href: "/workflows/runs/\(r.id)")
                }
            ))
        }
        return NavModel(id: workflowsNavId, title: "Workflows", sections: sections, selectedId: selectedId)
    }

    public static func buildWorkflowPaletteNavModel(disabled: Bool = false) -> NavModel {
        NavModel(
            id: paletteNavId,
            title: "Node types",
            sections: palette.map { group in
                NavSection(
                    id: group.id,
                    title: group.group,
                    items: group.items.map { item in
                        NavItem(id: item.type.rawValue, title: item.label, icon: "plus", disabled: disabled ? true : nil)
                    }
                )
            }
        )
    }

    public static func buildWorkflowInspectorSections(
        workflow: API.Workflow,
        graph: API.WorkflowGraph,
        selectedNode: API.WorkflowNode?,
        personas: [API.Persona],
        preview: Bool,
        error: String? = nil
    ) -> [InspectorSection] {
        var sections: [InspectorSection] = []
        let disabled = preview

        if let error, !error.isEmpty {
            sections.append(InspectorSection(
                id: "error",
                items: [InspectorItem(id: "workflow_error", kind: .note, label: "Error", detail: error, tone: .blocked)]
            ))
        }

        if let n = selectedNode {
            let c = n.config
            let before = ancestors(in: graph, of: n.id)
            let rerunnable = [InspectorOption(value: "", label: n.type == .gate ? "Only approve or reject" : "Don’t retry")]
                + before.filter { $0.type == .enrich || $0.type == .agent }
                    .map { InspectorOption(value: $0.id, label: "Re-run from \($0.title)") }
            let checkOptions = [InspectorOption(value: "", label: "No check")]
                + parentChecks(in: graph, of: n.id).map { InspectorOption(value: $0.id, label: $0.title) }
            let personaOptions = [InspectorOption(value: "", label: "The chat’s persona")]
                + personas.map { InspectorOption(value: $0.id, label: $0.name) }

            var items: [InspectorItem] = [
                InspectorItem(id: "node.title", kind: .text, label: "Title", value: n.title, disabled: disabled),
                InspectorItem(id: "node.output", kind: .fact, label: "Output token", value: "{{\(n.id).output}}", mono: true),
            ]
            if n.type != .trigger {
                let promptLabel: String = switch n.type {
                case .enrich: "Extra instructions (optional)"
                case .agent: "What this step should do"
                case .gate: "Message to the reviewer"
                default: "Body (empty uses previous output)"
                }
                items.append(InspectorItem(id: "node.prompt", kind: .text, label: promptLabel, value: c.prompt ?? "", multiline: true, disabled: disabled))
            }
            if n.type == .agent {
                items.append(InspectorItem(id: "node.persona_id", kind: .picker, label: "Persona", value: c.personaId ?? "", disabled: disabled, options: personaOptions))
                items.append(InspectorItem(id: "node.web", kind: .toggle, label: "Read the web", detail: "Disables workspace access for this step.", checked: c.web ?? false, disabled: disabled))
                items.append(InspectorItem(id: "node.images", kind: .toggle, label: "Generate images", checked: c.images ?? false, disabled: disabled))
                if c.images == true {
                    items.append(InspectorItem(
                        id: "node.image_engine",
                        kind: .picker,
                        label: "Image engine",
                        value: c.imageEngine ?? "",
                        disabled: disabled,
                        options: [
                            InspectorOption(value: "", label: "Persona / workspace default"),
                            InspectorOption(value: "auto", label: "Auto (first connected)"),
                            InspectorOption(value: "codex", label: "Codex"),
                            InspectorOption(value: "antigravity", label: "Antigravity"),
                        ]
                    ))
                }
                items.append(InspectorItem(id: "node.check", kind: .toggle, label: "Pass/fail check", detail: "Stops downstream steps unless it passes.", checked: c.check ?? false, disabled: disabled))
                if c.check == true {
                    items.append(InspectorItem(id: "node.retry_from", kind: .picker, label: "If check fails", value: c.retryFrom ?? "", disabled: disabled, options: rerunnable))
                    if let rf = c.retryFrom, !rf.isEmpty {
                        items.append(InspectorItem(id: "node.max_attempts", kind: .text, label: "Failures allowed", value: String(c.maxAttempts ?? 3), placeholder: "1-5", disabled: disabled))
                    }
                }
            }
            if n.type == .gate {
                items.append(InspectorItem(id: "node.retry_from", kind: .picker, label: "If changes requested", value: c.retryFrom ?? "", disabled: disabled, options: rerunnable))
                if let rf = c.retryFrom, !rf.isEmpty {
                    items.append(InspectorItem(id: "node.max_attempts", kind: .text, label: "Reviews allowed", value: String(c.maxAttempts ?? 3), placeholder: "1-5", disabled: disabled))
                }
                items.append(InspectorItem(id: "node.requires_check", kind: .picker, label: "Needs check", value: c.requiresCheck ?? "", disabled: disabled, options: checkOptions))
            }
            if n.type == .wiki {
                items.append(InspectorItem(id: "node.path", kind: .text, label: "Page path", value: c.path ?? "", placeholder: "Research/Findings", mono: true, disabled: disabled))
                items.append(InspectorItem(id: "node.mode", kind: .picker, label: "If page exists", value: c.mode ?? "replace", disabled: disabled, options: [
                    InspectorOption(value: "replace", label: "Replace (keeps history)"),
                    InspectorOption(value: "append", label: "Append to end"),
                ]))
            }
            if n.type == .library || n.type == .ticket {
                items.append(InspectorItem(id: "node.item_title", kind: .text, label: n.type == .ticket ? "Ticket title" : "Item title", value: c.title ?? "", disabled: disabled))
            }
            if n.type != .trigger {
                items.append(InspectorItem(id: "node_actions", kind: .actions, actions: [
                    InspectorAction(id: "delete_node", label: "Delete node", icon: "trash", destructive: true, disabled: disabled),
                ]))
            }
            sections.append(InspectorSection(id: "node", title: "Step · \(n.type.rawValue)", items: items))
        } else {
            let versionText = workflow.publishedVersion > 0
                ? "v\(workflow.publishedVersion)\(workflow.unpublishedChanges ? " · edited" : "")"
                : "Draft"
            sections.append(InspectorSection(
                id: "workflow",
                title: "Workflow settings",
                items: [
                    InspectorItem(id: "workflow.status", kind: .fact, label: "Version", value: versionText, mono: true),
                    InspectorItem(id: "workflow.name", kind: .text, label: "Name", value: workflow.name, disabled: disabled),
                    InspectorItem(id: "workflow.description", kind: .text, label: "When to use", value: workflow.description, placeholder: "Personas read this to recognize a request", multiline: true, disabled: disabled),
                    InspectorItem(id: "workflow.hint", kind: .note, detail: "Select a node on the canvas to configure it.", tone: .neutral),
                ]
            ))
        }

        if !workflow.issues.isEmpty {
            sections.append(InspectorSection(
                id: "issues",
                title: "Before you can publish",
                aside: String(workflow.issues.count),
                items: [
                    InspectorItem(
                        id: "issue_list",
                        kind: .list,
                        actionId: "select_issue_node",
                        rows: workflow.issues.enumerated().map { idx, issue in
                            NavItem(id: issue.node ?? "issue:\(idx)", title: issue.message, status: .human)
                        }
                    ),
                ]
            ))
        }

        return sections
    }
}
