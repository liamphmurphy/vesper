import AppKit
import SwiftUI
import VesperCore

/// Native SwiftUI Activity inspector for Chat (`chat.activity`).
/// Provides a List | Graph toggle so the persona's run DAG (turns, in-turn subagent jobs,
/// delegated runs, gates, errors, and outcome) is accessible directly inside Chat.
struct ChatActivityInspectorView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String

    enum Mode: String, CaseIterable {
        case list = "List"
        case graph = "Graph"
    }

    @State private var mode: Mode = .list

    private var chat: API.ChatSession? {
        context.store.entry(API.getChat(id: chatId)).data
    }

    private var messages: [API.ChatMessage] {
        context.store.entry(API.listChatMessages(id: chatId, limit: 200)).data?.messages ?? []
    }

    private var graphRunId: String? {
        if let current = chat?.currentRunId, !current.isEmpty { return current }
        return messages.last(where: { ($0.runId ?? "").isEmpty == false })?.runId
    }

    private var activityTab: InspectorTab? {
        context.chrome.inspector?.tabs.first(where: { $0.id == ChatInspectorLogic.activityTabId })
    }

    var body: some View {
        let activeMode: Mode = graphRunId != nil ? mode : .list
        VStack(spacing: 0) {
            if graphRunId != nil {
                HStack(spacing: 8) {
                    Picker("Activity view", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 150)

                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.palette.rowBorder).frame(height: 1)
                }
            }

            if activeMode == .graph, let runId = graphRunId {
                ChatActivityGraphPane(runId: runId, onOpenList: { mode = .list })
                    .id("graph:\(runId)")
            } else if let tab = activityTab {
                InspectorBodyView(
                    tab: tab,
                    send: { context.onCommand?($0) },
                    navigate: { path, newTab in
                        if newTab { context.openInNewTab(path) } else { context.navigate(path) }
                    },
                    openURL: { NSWorkspace.shared.open($0) }
                )
            } else {
                Text("No activity yet.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Lazily mounted run DAG for the active chat's run inside the Activity inspector.
private struct ChatActivityGraphPane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let runId: String
    let onOpenList: () -> Void

    @State private var selectedId: String?
    @State private var expanded: Set<String> = []
    @State private var useELKLayout = false
    @State private var elkLayout: ELKGraph?
    @State private var viewport = NodeGraphViewport()
    @State private var watchedKeys: [QueryKey] = []

    private static let endedStates: Set<String> = ["completed", "failed", "cancelled"]

    private var runRequest: APIRequest<API.RunDetail> {
        API.getRun(id: runId)
    }

    private var runEntry: QueryEntry<API.RunDetail> {
        context.store.entry(runRequest)
    }

    private var childIds: [String] {
        runEntry.data?.childRuns.map(\.id) ?? []
    }

    private var childDetails: [API.RunDetail] {
        childIds.compactMap { context.store.entry(API.getRun(id: $0)).data }
    }

    var body: some View {
        let entry = runEntry
        Group {
            if let detail = entry.data {
                graphContent(detail: detail)
            } else if let err = entry.error {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.palette.tertiaryText)
                    Text("Graph unavailable")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.palette.text)
                    Text(err.userMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading run graph…")
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: runId) {
            syncWatches(childIds: childIds)
            await pollWhileRunning()
        }
        .onChange(of: childIds) { _, next in
            syncWatches(childIds: next)
        }
        .onDisappear {
            for key in watchedKeys { context.store.stopObserving(key) }
            watchedKeys = []
        }
    }

    @ViewBuilder
    private func graphContent(detail: API.RunDetail) -> some View {
        let graph = RunGraphLogic.buildRunGraph(detail: detail, loaded: childDetails)
        let keep: Set<String> = selectedId.map { [$0] } ?? []
        let layout = RunGraphLogic.layoutRunGraph(graph, expanded: expanded, keep: keep)
        let doc: NodeGraphDocument = {
            var d = RunGraphLogic.buildDocument(from: layout, selectedId: selectedId)
            if useELKLayout, let elkLayout { d.applyELKLayout(elkLayout) }
            return d
        }()
        let signature = "\(useELKLayout ? "elk" : "lane")|\(layout.columns.flatMap { [$0.main.id] + $0.branch.map(\.id) }.joined(separator: ","))"
        let selectedNode = selectedId.flatMap { id in graph.nodes.first { $0.id == id } }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Turns left to right · subagents below")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(useELKLayout ? "Lane" : "ELK") {
                    useELKLayout.toggle()
                }
                .buttonStyle(.vesper(.outline))
                .controlSize(.mini)
            }

            if layout.columns.isEmpty {
                Text("Nothing to draw yet. Turns and subagent branches appear here as the run works.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 8)
            } else {
                NodeGraphCanvasView(
                    document: doc,
                    viewport: $viewport,
                    interactive: false,
                    onSelectNode: { id in
                        if let id, id.hasPrefix("group:") {
                            toggleExpand(id)
                            return
                        }
                        if let id, id.hasPrefix("more:") {
                            toggleExpand(String(id.dropFirst(5)))
                            return
                        }
                        selectedId = id
                    },
                    onActivateNode: { id in
                        if id.hasPrefix("group:") { toggleExpand(id); return }
                        if id.hasPrefix("more:") { toggleExpand(String(id.dropFirst(5))); return }
                        if let node = graph.nodes.first(where: { $0.id == id }) {
                            activate(node)
                        }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))

                legendBar

                if let node = selectedNode {
                    summaryCard(for: node, detail: detail)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: signature) {
            guard useELKLayout, !layout.columns.isEmpty else {
                elkLayout = nil
                return
            }
            let elkInput = RunGraphLogic.toELKGraph(from: layout)
            elkLayout = try? await ELKLayoutEngine.shared.layout(graph: elkInput)
        }
    }

    private var doneColor: Color { theme.swiftUIColor("state-done", fallback: .green) }
    private var humanColor: Color { theme.swiftUIColor("state-human", fallback: .orange) }
    private var blockedColor: Color { theme.swiftUIColor("state-blocked", fallback: .red) }

    private var legendBar: some View {
        HStack(spacing: 10) {
            legendDot(color: doneColor, label: "Done")
            legendDot(color: theme.palette.accent, label: "Running")
            legendDot(color: humanColor, label: "Waiting")
            legendDot(color: blockedColor, label: "Failed")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.palette.tertiaryText)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    @ViewBuilder
    private func summaryCard(for node: RunGraphLogic.GraphNode, detail: API.RunDetail) -> some View {
        let turnMap = RunGraphLogic.turnByEvent(detail.events)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summaryTitle(for: node))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button { selectedId = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }

                if case .subagentJob(let j) = node, !j.tier.isEmpty || !j.flags.isEmpty {
                    HStack(spacing: 4) {
                        if !j.tier.isEmpty {
                            Text(j.tier)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.palette.selected, in: Capsule())
                                .foregroundStyle(theme.palette.accent)
                        }
                        ForEach(j.flags, id: \.self) { flag in
                            let flagColor = flag == .failed ? blockedColor : humanColor
                            Text(flag.label)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(flagColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(flagColor)
                        }
                    }
                }

                ForEach(summaryRows(for: node), id: \.0) { key, value in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(key)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.secondaryText)
                            .frame(width: 72, alignment: .leading)
                        Text(value)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.text)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }

                if let msg = summaryMessage(for: node, detail: detail, turnMap: turnMap), !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.secondaryText)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 6))
                }

                if case .outcome = node {
                    EmptyView()
                } else {
                    Button("Show in List") {
                        activate(node)
                    }
                    .buttonStyle(.vesper(.outline))
                    .controlSize(.small)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: 220)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }

    private func summaryTitle(for node: RunGraphLogic.GraphNode) -> String {
        switch node {
        case .turn(let t): "Turn \(t.turn) · \(t.trigger)"
        case .subagentRun(let s): "↳ \(s.agent)"
        case .subagentJob(let j): "↳ \(j.role.isEmpty ? j.agentType : j.role)"
        case .gate(let g): "\(g.gate.label) after turn \(g.afterTurn)"
        case .error(let e): "Error in turn \(e.turn)"
        case .outcome: "Outcome"
        }
    }

    private func summaryRows(for node: RunGraphLogic.GraphNode) -> [(String, String)] {
        switch node {
        case .turn(let t):
            let dur = APIDate.duration(since: t.startedAt, until: t.endedAt)
            let cost = t.costUsd.map { String(format: "$%.2f", $0) } ?? "–"
            return [("Status", t.status.label), ("Duration", dur), ("Cost", cost)]
        case .subagentRun(let s):
            var rows = [("Status", s.status.label), ("Cost", String(format: "$%.2f", s.costUsd))]
            if s.childCount > 0 { rows.append(("Nested", "\(s.childCount)")) }
            return rows
        case .subagentJob(let j):
            var rows: [(String, String)] = [
                ("Status", j.status.label),
                ("Type", j.agentType),
            ]
            if !j.model.isEmpty {
                let modelStr = j.effort.isEmpty ? j.model : "\(j.model) (\(j.effort))"
                rows.append(("Model", modelStr))
            }
            if j.durationMs != nil {
                rows.append(("Duration", APIDate.duration(since: j.startedAt ?? j.createdAt, until: j.completedAt)))
            }
            if j.toolCalls > 0 { rows.append(("Tool calls", "\(j.toolCalls)")) }
            if let cost = j.costUsd { rows.append(("Cost", String(format: "$%.3f", cost))) }
            if !j.reason.isEmpty { rows.append(("Why", j.reason)) }
            return rows
        case .gate(let g):
            var rows = [("State", g.state.rawValue)]
            if let d = g.detail { rows.append(("Detail", d)) }
            return rows
        case .error:
            return []
        case .outcome(let o):
            return [("Status", o.status.label)]
        }
    }

    private func summaryMessage(
        for node: RunGraphLogic.GraphNode,
        detail: API.RunDetail,
        turnMap: [Int: Int]
    ) -> String? {
        switch node {
        case .turn(let t):
            return RunGraphLogic.finalMessage(detail.events.filter { turnMap[$0.seq] == t.turn })
        case .subagentRun(let s):
            return detail.childRuns.first(where: { $0.id == s.runId })?.outcome
        case .subagentJob(let j):
            if !j.error.isEmpty { return j.error }
            if !j.resultText.isEmpty { return j.resultText }
            return j.prompt.isEmpty ? nil : j.prompt
        case .gate:
            return nil
        case .error(let e):
            return e.message
        case .outcome(let o):
            return o.text
        }
    }

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func activate(_ node: RunGraphLogic.GraphNode) {
        switch node {
        case .turn, .subagentJob, .gate, .error, .subagentRun:
            onOpenList()
        case .outcome:
            break
        }
    }

    private func syncWatches(childIds: [String]) {
        for key in watchedKeys { context.store.stopObserving(key) }
        watchedKeys = []

        func watch(_ req: APIRequest<API.RunDetail>) {
            context.store.observe(req)
            context.store.load(req)
            watchedKeys.append(req.key)
        }

        watch(runRequest)
        for cid in childIds {
            watch(API.getRun(id: cid))
        }
    }

    private func pollWhileRunning() async {
        while !Task.isCancelled {
            if let state = runEntry.data?.run.state.rawValue, Self.endedStates.contains(state) {
                return
            }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            context.store.invalidate(QueryInvalidation(resources: ["runs"]))
        }
    }
}
