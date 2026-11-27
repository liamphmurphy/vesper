import SwiftUI
import VesperCore

/// `/workflows/:id`: interactive native node-graph workflow editor with palette sidebar,
/// drag/connect `NodeGraphCanvasView`, ELK auto-layout, inspector panel, debounced save, and Publish.
struct WorkflowEditorScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var draftGraph: API.WorkflowGraph?
    @State private var loadedWorkflowId: String?
    @State private var selectedNodeId: String?
    @State private var selectedEdgeId: String?
    @State private var inspectorOpen = false
    @State private var viewport = NodeGraphViewport()
    @State private var saving = false
    @State private var publishing = false
    @State private var resolvingProposal = false
    @State private var actionError: String?
    @State private var saveTask: Task<Void, Never>?

    private var workflowId: String { context.match.params["id"] ?? "" }
    private var workflowRequest: APIRequest<API.Workflow> { API.getWorkflow(id: workflowId) }
    private static let personasRequest = API.listPersonas()

    private var workflowEntry: QueryEntry<API.Workflow> {
        context.store.entry(workflowRequest)
    }

    private var personas: [API.Persona] {
        context.store.entry(Self.personasRequest).data?.personas ?? []
    }

    var body: some View {
        Group {
            if let error = workflowEntry.error, workflowEntry.data == nil {
                QueryErrorView(message: error.userMessage) {
                    Task { _ = await context.store.refetch(workflowRequest) }
                }
            } else if let workflow = workflowEntry.data {
                editorBody(workflow: workflow)
            } else {
                SkeletonBar(height: 360)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: workflowId) {
            guard !workflowId.isEmpty else { return }
            context.store.observe(workflowRequest)
            context.store.load(workflowRequest)
            context.store.load(Self.personasRequest)
        }
        .onDisappear {
            flushPendingSave()
            context.store.stopObserving(workflowRequest.key)
        }
    }

    @ViewBuilder
    private func editorBody(workflow: API.Workflow) -> some View {
        let graph = activeGraph(for: workflow)
        let proposal = workflow.proposals.first
        let diff = proposal.map { WorkflowsLogic.diffGraphs(base: graph, next: $0.graph) }
        let shownGraph = proposal?.graph ?? graph
        let document = WorkflowsLogic.toNodeGraphDocument(
            graph: shownGraph,
            selectedNodeId: selectedNodeId,
            selectedEdgeId: selectedEdgeId,
            diff: diff
        )

        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let proposal {
                    proposalBanner(proposal, workflow: workflow)
                }
                if let err = actionError {
                    Text(err)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)))
                }

                ZStack(alignment: .topTrailing) {
                    NodeGraphCanvasView(
                        document: document,
                        viewport: $viewport,
                        interactive: proposal == nil,
                        onSelectNode: { id in
                            selectedNodeId = id
                            selectedEdgeId = nil
                        },
                        onSelectEdge: { id in
                            selectedEdgeId = id
                            selectedNodeId = nil
                        },
                        onMoveNode: { nodeId, origin in
                            moveNode(id: nodeId, to: origin, workflow: workflow)
                        },
                        onConnect: { source, target in
                            connect(from: source, to: target, workflow: workflow)
                        }
                    )

                    canvasActionBar(workflow: workflow, graph: graph, preview: proposal != nil)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            inspectorSidebar(workflow: workflow, graph: graph, preview: proposal != nil)
                .frame(width: 280)
                .background(theme.palette.background)
        }
        .onAppear {
            syncDraftIfNeeded(workflow)
            publishChrome(workflow: workflow, graph: graph)
            context.onCommand = { handleCommand($0, workflow: workflow) }
        }
        .onChange(of: workflow) { _, updated in
            if loadedWorkflowId != updated.id {
                syncDraftIfNeeded(updated)
            }
            context.onCommand = { handleCommand($0, workflow: updated) }
            publishChrome(workflow: updated, graph: activeGraph(for: updated))
        }
        .onChange(of: selectedNodeId) { _, _ in
            publishChrome(workflow: workflow, graph: graph)
        }
        .onChange(of: saving) { _, _ in
            publishChrome(workflow: workflow, graph: graph)
        }
        .onChange(of: publishing) { _, _ in
            publishChrome(workflow: workflow, graph: graph)
        }
        .onChange(of: actionError) { _, _ in
            publishChrome(workflow: workflow, graph: graph)
        }
    }

    private func canvasActionBar(workflow: API.Workflow, graph: API.WorkflowGraph, preview: Bool) -> some View {
        let canPublish = WorkflowsLogic.canPublish(workflow: workflow, publishing: publishing, preview: preview)
        return HStack(spacing: 6) {
            if !preview, let edgeId = selectedEdgeId {
                Button("Delete edge") {
                    deleteEdge(id: edgeId, workflow: workflow)
                }
                .buttonStyle(.vesper(.danger))
            }
            if !preview {
                Button("Auto-layout") {
                    Task { await autoLayout(workflow: workflow, graph: graph) }
                }
                .buttonStyle(.vesper(.outline))

                Button(WorkflowsLogic.publishButtonLabel(publishing: publishing)) {
                    Task { await publishWorkflow(workflow) }
                }
                .buttonStyle(.vesper(.primary))
                .disabled(!canPublish)
                .help(WorkflowsLogic.publishHelpText(workflow: workflow, publishing: publishing, preview: preview))
            }
        }
    }

    private func proposalBanner(_ proposal: API.WorkflowProposal, workflow: API.Workflow) -> some View {
        HStack(spacing: 10) {
            Text(proposal.summary)
                .vesperText(.body, theme)
                .lineLimit(2)
            Spacer()
            Button("Apply") {
                Task { await resolveProposal(proposal.id, action: .apply, workflow: workflow) }
            }
            .buttonStyle(.vesper(.primary))
            .disabled(resolvingProposal)

            Button("Discard") {
                Task { await resolveProposal(proposal.id, action: .discard, workflow: workflow) }
            }
            .buttonStyle(.vesper(.outline))
            .disabled(resolvingProposal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.swiftUIColor("accent-soft", fallback: theme.palette.accent.opacity(0.12)))
    }

    @ViewBuilder
    private func inspectorSidebar(workflow: API.Workflow, graph: API.WorkflowGraph, preview: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let nodeId = selectedNodeId, let node = graph.nodes.first(where: { $0.id == nodeId }) {
                    nodeInspector(workflow: workflow, graph: graph, node: node, preview: preview)
                } else {
                    workflowSettingsInspector(workflow: workflow, preview: preview)
                }

                if !workflow.issues.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Before you can publish")
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.palette.secondaryText)
                        ForEach(Array(workflow.issues.enumerated()), id: \.offset) { _, issue in
                            Button {
                                if let nodeId = issue.node { selectedNodeId = nodeId }
                            } label: {
                                Text(issue.message)
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func workflowSettingsInspector(workflow: API.Workflow, preview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workflow settings")
                .vesperText(.heading, theme)

            VStack(alignment: .leading, spacing: 4) {
                Text("Add node")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                ForEach(WorkflowsLogic.palette) { group in
                    Text(group.group)
                        .vesperText(.micro, theme)
                        .foregroundStyle(theme.palette.tertiaryText)
                        .padding(.top, 4)
                    ForEach(group.items) { item in
                        Button("+ \(item.label)") {
                            addNode(type: item.type, label: item.label, workflow: workflow)
                        }
                        .buttonStyle(.vesper(.outline))
                        .disabled(preview)
                    }
                }
            }

            Divider()
            Text("Select a node on the canvas to configure it, or drag from a right port to a left port to connect steps.")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.tertiaryText)
        }
    }

    private func nodeInspector(workflow: API.Workflow, graph: API.WorkflowGraph, node: API.WorkflowNode, preview: Bool) -> some View {
        let disabled = preview
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Step · \(WorkflowsLogic.nodeLabel(node.type))")
                    .vesperText(.heading, theme)
                Spacer()
                Button { selectedNodeId = nil } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Text("{{\(node.id).output}}")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title").vesperText(.small, theme).foregroundStyle(theme.palette.secondaryText)
                TextField("Title", text: Binding(
                    get: { node.title },
                    set: { newTitle in patchNode(node.id, workflow: workflow) { $0.title = newTitle } }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
            }

            if node.type != .trigger {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.type == .gate ? "Message to reviewer" : "Instructions / prompt")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                    TextEditor(text: Binding(
                        get: { node.config.prompt ?? "" },
                        set: { val in patchNode(node.id, workflow: workflow) { $0.config.prompt = val } }
                    ))
                    .font(.system(size: 12))
                    .frame(minHeight: 84)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                    .disabled(disabled)
                }
            }

            if node.type == .agent {
                Toggle("Read the web", isOn: Binding(
                    get: { node.config.web ?? false },
                    set: { val in patchNode(node.id, workflow: workflow) { $0.config.web = val ? true : nil } }
                ))
                .disabled(disabled)

                Toggle("Generate images", isOn: Binding(
                    get: { node.config.images ?? false },
                    set: { val in patchNode(node.id, workflow: workflow) { $0.config.images = val ? true : nil } }
                ))
                .disabled(disabled)

                Toggle("Pass/fail check", isOn: Binding(
                    get: { node.config.check ?? false },
                    set: { val in
                        patchNode(node.id, workflow: workflow) {
                            $0.config.check = val ? true : nil
                            if !val { $0.config.retryFrom = nil; $0.config.maxAttempts = nil }
                        }
                    }
                ))
                .disabled(disabled)
            }

            if node.type == .wiki {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page path").vesperText(.small, theme).foregroundStyle(theme.palette.secondaryText)
                    TextField("Research/Findings", text: Binding(
                        get: { node.config.path ?? "" },
                        set: { val in patchNode(node.id, workflow: workflow) { $0.config.path = val } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
                }
            }

            if node.type == .library || node.type == .ticket {
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.type == .ticket ? "Ticket title" : "Item title")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                    TextField("Title", text: Binding(
                        get: { node.config.title ?? "" },
                        set: { val in patchNode(node.id, workflow: workflow) { $0.config.title = val } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
                }
            }

            if node.type != .trigger {
                Button("Delete node") {
                    let next = WorkflowsLogic.removeNode(from: graph, id: node.id)
                    selectedNodeId = nil
                    scheduleSave(next, workflow: workflow)
                }
                .buttonStyle(.vesper(.danger))
                .disabled(disabled)
            }
        }
    }

    // MARK: - Graph Editing & Persistence

    private func activeGraph(for workflow: API.Workflow) -> API.WorkflowGraph {
        if loadedWorkflowId == workflow.id, let draftGraph { return draftGraph }
        return workflow.draft
    }

    private func syncDraftIfNeeded(_ workflow: API.Workflow) {
        loadedWorkflowId = workflow.id
        draftGraph = workflow.draft
    }

    private func addNode(type: API.WorkflowNode.TypeValue, label: String, workflow: API.Workflow) {
        let graph = activeGraph(for: workflow)
        let id = WorkflowsLogic.newNodeId(in: graph, type: type)
        let shift = Double(graph.nodes.count % 6) * 28.0
        let center = viewport.screenToGraph(GraphPoint(x: 280 + shift, y: 180 + shift))
        let newNode = API.WorkflowNode(config: .init(), id: id, title: label, type: type, x: center.x, y: center.y)
        let next = API.WorkflowGraph(edges: graph.edges, nodes: graph.nodes + [newNode])
        selectedNodeId = id
        scheduleSave(next, workflow: workflow)
    }

    private func moveNode(id: String, to origin: GraphPoint, workflow: API.Workflow) {
        patchNode(id, workflow: workflow) {
            $0.x = origin.x
            $0.y = origin.y
        }
    }

    private func connect(from: String, to: String, workflow: API.Workflow) {
        let graph = activeGraph(for: workflow)
        guard WorkflowsLogic.canConnect(in: graph, from: from, to: to) else { return }
        let next = API.WorkflowGraph(edges: graph.edges + [API.WorkflowEdge(from: from, to: to)], nodes: graph.nodes)
        scheduleSave(next, workflow: workflow)
    }

    private func deleteEdge(id: String, workflow: API.Workflow) {
        let graph = activeGraph(for: workflow)
        let next = API.WorkflowGraph(edges: graph.edges.filter { "\($0.from)->\($0.to)" != id }, nodes: graph.nodes)
        selectedEdgeId = nil
        scheduleSave(next, workflow: workflow)
    }

    private func patchNode(_ id: String, workflow: API.Workflow, mutate: (inout API.WorkflowNode) -> Void) {
        let graph = activeGraph(for: workflow)
        let nodes = graph.nodes.map { node -> API.WorkflowNode in
            guard node.id == id else { return node }
            var copy = node
            mutate(&copy)
            return copy
        }
        scheduleSave(API.WorkflowGraph(edges: graph.edges, nodes: nodes), workflow: workflow)
    }

    private func scheduleSave(_ next: API.WorkflowGraph, workflow: API.Workflow) {
        draftGraph = next
        loadedWorkflowId = workflow.id
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await saveNow(next, workflowId: workflow.id)
        }
    }

    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        if let id = loadedWorkflowId, let graph = draftGraph {
            Task { await saveNow(graph, workflowId: id) }
        }
    }

    private func saveNow(_ graph: API.WorkflowGraph, workflowId: String) async {
        saving = true
        actionError = nil
        defer { saving = false }
        do {
            let updated = try await context.store.mutate(
                API.updateWorkflow(id: workflowId, body: API.WorkflowPatch(description: nil, graph: graph, name: nil))
            )
            context.store.setData(updated, for: API.getWorkflow(id: workflowId))
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func publishWorkflow(_ workflow: API.Workflow) async {
        publishing = true
        actionError = nil
        defer { publishing = false }
        saveTask?.cancel()
        if let graph = draftGraph {
            await saveNow(graph, workflowId: workflow.id)
        }
        do {
            let updated = try await context.store.mutate(API.publishWorkflow(id: workflow.id))
            context.store.setData(updated, for: workflowRequest)
            draftGraph = updated.draft
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resolveProposal(_ proposalId: String, action: API.ResolveWorkflowProposalAction, workflow: API.Workflow) async {
        resolvingProposal = true
        actionError = nil
        defer { resolvingProposal = false }
        do {
            let updated = try await context.store.mutate(
                API.resolveWorkflowProposal(id: workflow.id, proposalId: proposalId, action: action)
            )
            context.store.setData(updated, for: workflowRequest)
            draftGraph = updated.draft
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func autoLayout(workflow: API.Workflow, graph: API.WorkflowGraph) async {
        do {
            let elk = try await ELKLayoutEngine.shared.layout(graph: WorkflowsLogic.toELKGraph(graph))
            let laid = WorkflowsLogic.applyingELKLayout(elk, to: graph)
            scheduleSave(laid, workflow: workflow)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func publishChrome(workflow: API.Workflow, graph: API.WorkflowGraph) {
        let preview = !workflow.proposals.isEmpty
        let version = workflow.publishedVersion > 0
            ? "v\(workflow.publishedVersion)\(workflow.unpublishedChanges ? " · edited" : "")"
            : "Draft"
        let status = saving ? "Saving…" : "Saved"
        let selectedNode = selectedNodeId.flatMap { id in graph.nodes.first { $0.id == id } }
        let sections = WorkflowsLogic.buildWorkflowInspectorSections(
            workflow: workflow,
            graph: graph,
            selectedNode: selectedNode,
            personas: personas,
            preview: preview,
            error: actionError
        )
        context.chrome = NativeChrome(
            title: workflow.name,
            subtitle: "\(version) · \(status)",
            toolbarItems: [
                ShellToolbarItem(
                    id: "workflow.publish",
                    label: WorkflowsLogic.publishButtonLabel(publishing: publishing),
                    icon: "upload",
                    kind: .button,
                    disabled: !WorkflowsLogic.canPublish(workflow: workflow, publishing: publishing, preview: preview),
                    accent: true,
                    showsLabel: true
                ),
            ],
            inspector: InspectorModel(
                id: "workflow-editor",
                open: inspectorOpen,
                activeTabId: "details",
                tabs: [InspectorTab(id: "details", label: "Details", icon: "sliders", kind: .native, sections: sections)]
            ),
            navigator: WorkflowsLogic.buildWorkflowPaletteNavModel(disabled: preview)
        )
    }

    private func handleCommand(_ command: NativeCommand, workflow: API.Workflow) {
        switch command {
        case .inspectorVisibility(let open):
            inspectorOpen = open
            context.chrome.inspector?.open = open
        case .inspectorSelectTab:
            inspectorOpen = true
            context.chrome.inspector?.open = true
        case .navActivate(let navId, let itemId, _) where navId == WorkflowsLogic.paletteNavId:
            guard workflow.proposals.isEmpty else { return }
            if let item = WorkflowsLogic.palette.flatMap(\.items).first(where: { $0.type.rawValue == itemId }) {
                addNode(type: item.type, label: item.label, workflow: workflow)
            }
        case .toolbarAction(let itemId, _) where itemId == "workflow.publish":
            Task { await publishWorkflow(workflow) }
        case .inspectorAction(_, let actionId, let itemId, _):
            if actionId == "delete_node", let id = selectedNodeId, workflow.proposals.isEmpty {
                let next = WorkflowsLogic.removeNode(from: activeGraph(for: workflow), id: id)
                selectedNodeId = nil
                scheduleSave(next, workflow: workflow)
            } else if actionId == "select_issue_node", let itemId, !itemId.hasPrefix("issue:") {
                selectedNodeId = itemId
            }
        default:
            break
        }
    }
}
