import SwiftUI
import VesperCore

/// `/workflows/runs/:id`: live workflow run graph, human gate review panel (Approve / Request changes / Reject),
/// stop control, and selected step output/check attempts detail.
struct WorkflowRunScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var selectedNodeId: String?
    @State private var viewport = NodeGraphViewport()
    @State private var gateNote = ""
    @State private var busy = false
    @State private var actionError: String?

    private var runId: String { context.match.params["id"] ?? "" }
    private var runRequest: APIRequest<API.WorkflowRun> { API.getWorkflowRun(id: runId) }

    private var runEntry: QueryEntry<API.WorkflowRun> {
        context.store.entry(runRequest)
    }

    var body: some View {
        Group {
            if let error = runEntry.error, runEntry.data == nil {
                QueryErrorView(message: error.userMessage) {
                    Task { _ = await context.store.refetch(runRequest) }
                }
            } else if let run = runEntry.data {
                runBody(run)
            } else {
                SkeletonBar(height: 320)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: runId) {
            guard !runId.isEmpty else { return }
            context.store.observe(runRequest)
            context.store.load(runRequest)
        }
        .task(id: runEntry.data?.state) {
            guard let run = runEntry.data, WorkflowsLogic.runActive(run.state) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                _ = await context.store.refetch(runRequest)
            }
        }
        .onDisappear {
            context.store.stopObserving(runRequest.key)
        }
    }

    @ViewBuilder
    private func runBody(_ run: API.WorkflowRun) -> some View {
        let statusMap = Dictionary(run.steps.map { ($0.nodeId, $0.state) }, uniquingKeysWith: { _, latest in latest })
        let document = WorkflowsLogic.toNodeGraphDocument(
            graph: run.graph,
            selectedNodeId: selectedNodeId,
            stepStatusByNodeId: statusMap
        )

        let currentChrome = buildChrome(run)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !run.input.isEmpty {
                    Text(run.input)
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                }

                if let err = actionError ?? (run.error.isEmpty ? nil : run.error) {
                    Text(err)
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)), in: RoundedRectangle(cornerRadius: 8))
                }

                NodeGraphCanvasView(
                    document: document,
                    viewport: $viewport,
                    interactive: false,
                    onSelectNode: { selectedNodeId = $0 }
                )
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))

                if let waitingStep = run.steps.first(where: { $0.state == .waiting }),
                   let gateNode = run.graph.nodes.first(where: { $0.id == waitingStep.nodeId }) {
                    gatePanel(run: run, gate: gateNode, step: waitingStep)
                }

                if let nodeId = selectedNodeId,
                   let node = run.graph.nodes.first(where: { $0.id == nodeId }) {
                    stepDetailCard(run: run, node: node)
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
        }
        .onChange(of: currentChrome, initial: true) { _, next in
            context.chrome = next
        }
        .onAppear {
            context.chrome = currentChrome
            context.onCommand = { handleCommand($0, run: run) }
        }
        .onChange(of: run.id) { _, _ in
            context.onCommand = { handleCommand($0, run: run) }
        }
        .onDisappear {
            context.onCommand = nil
        }
    }

    private func gatePanel(run: API.WorkflowRun, gate: API.WorkflowNode, step: API.WorkflowStep) -> some View {
        let canChanges = WorkflowsLogic.canRequestChanges(gate: gate, attempt: step.attempt)
        let failedCheck = WorkflowsLogic.failedGateCheck(in: run.graph, gate: gate, steps: run.steps)
        let sourceIds = WorkflowsLogic.gateSources(in: run.graph, gate: gate)

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(gate.title).vesperText(.heading, theme)
                if let prompt = gate.config.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }

            ForEach(sourceIds, id: \.self) { srcId in
                if let srcStep = run.steps.first(where: { $0.nodeId == srcId }), !srcStep.output.isEmpty {
                    let srcTitle = run.graph.nodes.first(where: { $0.id == srcId })?.title ?? srcId
                    DisclosureGroup(srcTitle) {
                        MarkdownView(markdown: srcStep.output)
                            .padding(.top, 6)
                    }
                    .padding(10)
                    .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let failedCheck {
                Text("\(failedCheck.title) didn’t pass, so this can’t be approved. Request changes or reject it.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            if canChanges {
                TextField("Note for the re-run (required when requesting changes)", text: $gateNote)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button("Approve") {
                    Task { await decideGate(runId: run.id, nodeId: gate.id, decision: "approve") }
                }
                .buttonStyle(.vesper(.approve))
                .disabled(busy || failedCheck != nil)

                if canChanges {
                    Button("Request changes") {
                        Task { await decideGate(runId: run.id, nodeId: gate.id, decision: "changes") }
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(busy || gateNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Spacer()

                Button("Reject and stop") {
                    Task { await decideGate(runId: run.id, nodeId: gate.id, decision: "reject") }
                }
                .buttonStyle(.vesper(.danger))
                .disabled(busy)
            }
        }
        .padding(16)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.swiftUIColor("state-human", fallback: .orange)))
    }

    private func stepDetailCard(run: API.WorkflowRun, node: API.WorkflowNode) -> some View {
        let step = run.steps.first(where: { $0.nodeId == node.id })
        let checks = run.checkAttempts.filter { $0.nodeId == node.id }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(node.title).vesperText(.heading, theme)
                if let step {
                    Text("attempt \(step.attempt) · \(step.checkResult.isEmpty ? step.state.rawValue : step.checkResult)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                Spacer()
                if let agentRunId = step?.agentRunId, !agentRunId.isEmpty {
                    Button("Open run") {
                        context.navigate("/runs/\(agentRunId)")
                    }
                    .buttonStyle(.vesper(.outline))
                }
            }

            if let note = step?.note, !note.isEmpty {
                Text(note)
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }

            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checks, id: \.attempt) { check in
                        DisclosureGroup("Attempt \(check.attempt) · \(check.result)") {
                            VStack(alignment: .leading, spacing: 6) {
                                if !check.note.isEmpty {
                                    Text(check.note).vesperText(.small, theme)
                                }
                                if !check.output.isEmpty {
                                    MarkdownView(markdown: check.output)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .padding(8)
                        .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if let output = step?.output, !output.isEmpty {
                MarkdownView(markdown: output)
            } else {
                Text("No output yet.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            }
        }
        .padding(16)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    private func decideGate(runId: String, nodeId: String, decision: String) async {
        busy = true
        actionError = nil
        defer { busy = false }
        let trimmed = gateNote.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await context.store.mutate(
                API.decideWorkflowGate(
                    id: runId,
                    body: API.WorkflowGateDecision(decision: decision, nodeId: nodeId, note: trimmed.isEmpty ? nil : trimmed)
                )
            )
            gateNote = ""
            context.store.setData(updated, for: runRequest)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func stopRun(_ runId: String) async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            let updated = try await context.store.mutate(API.stopWorkflowRun(id: runId))
            context.store.setData(updated, for: runRequest)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func buildChrome(_ run: API.WorkflowRun) -> NativeChrome {
        var items: [ShellToolbarItem] = []
        if WorkflowsLogic.runActive(run.state) {
            items.append(ShellToolbarItem(id: "wfrun.stop", label: "Stop", icon: "pause", kind: .button, disabled: busy, showsLabel: true))
        }
        if !run.chatId.isEmpty {
            items.append(ShellToolbarItem(id: "wfrun.chat", label: "Open chat", icon: "msg", kind: .button, showsLabel: true))
        }
        let tabActivity: TabActivityStatus? = if run.state == .waiting {
            .needsAttention
        } else if WorkflowsLogic.runActive(run.state) {
            .running
        } else {
            nil
        }
        return NativeChrome(
            title: run.name,
            subtitle: "v\(run.version) · \(WorkflowsLogic.runStateLabel(run.state))",
            toolbarItems: items,
            navigator: WorkflowsLogic.buildWorkflowRunNavModel(run: run, selectedNodeId: selectedNodeId),
            tabActivity: tabActivity
        )
    }

    private func handleCommand(_ command: NativeCommand, run: API.WorkflowRun) {
        if case .toolbarAction(let itemId, _) = command {
            if itemId == "wfrun.stop" {
                Task { await stopRun(run.id) }
            } else if itemId == "wfrun.chat", !run.chatId.isEmpty {
                context.navigate("/chat/\(run.chatId)")
            }
            return
        }
        guard let action = WorkflowsLogic.workflowRunNavAction(for: command) else { return }
        switch action {
        case .back:
            context.navigate("/workflows")
        case .openWorkflow:
            if let wfId = run.workflowId, !wfId.isEmpty {
                context.navigate("/workflows/\(wfId)")
            }
        case .selectNode(let nodeId):
            selectedNodeId = nodeId
        }
    }
}
