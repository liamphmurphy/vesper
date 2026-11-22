import SwiftUI
import VesperCore

/// Native Graph DAG tab for Run Detail (replaces the hosted web `/runs/:id?tab=graph` slot).
/// Renders the run's turns, human gates, delegated subagent runs, errors, and outcome via
/// `NodeGraphCanvasView` + `ELKLayoutEngine` with a List toggle and node Summary card.
struct RunGraphTabSlot: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let detail: API.RunDetail
    let childDetails: [API.RunDetail]
    let allEvents: [API.RunEvent]
    let onOpenTurn: (Int) -> Void
    let onOpenEvent: (Int) -> Void

    @State private var selectedId: String?
    @State private var expanded: Set<String> = []
    @State private var listMode = false
    @State private var useELKLayout = false
    @State private var elkLayout: ELKGraph?
    @State private var viewport = NodeGraphViewport()

    private var mergedDetail: API.RunDetail {
        API.RunDetail(
            approvals: detail.approvals,
            childRuns: detail.childRuns,
            events: allEvents.isEmpty ? detail.events : allEvents,
            run: detail.run,
            turns: detail.turns
        )
    }

    private var runGraph: RunGraphLogic.RunGraph {
        RunGraphLogic.buildRunGraph(detail: mergedDetail, loaded: childDetails)
    }

    private var layout: RunGraphLogic.GraphLayout {
        let keep: Set<String> = selectedId.map { [$0] } ?? []
        return RunGraphLogic.layoutRunGraph(runGraph, expanded: expanded, keep: keep)
    }

    private var document: NodeGraphDocument {
        var doc = RunGraphLogic.buildDocument(from: layout, selectedId: selectedId)
        if useELKLayout, let elkLayout {
            doc.applyELKLayout(elkLayout)
        }
        return doc
    }

    private var layoutSignature: String {
        let ids = layout.columns.flatMap { [$0.main.id] + $0.branch.map(\.id) }
        return "\(useELKLayout ? "elk" : "lane")|\(ids.joined(separator: ","))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            if layout.columns.isEmpty {
                Text("Nothing to draw yet. Turns appear here as the run works.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        if listMode {
                            listFallback
                        } else {
                            NodeGraphCanvasView(
                                document: document,
                                viewport: $viewport,
                                interactive: false,
                                onSelectNode: { handleSelect($0) },
                                onActivateNode: { activateNode(id: $0) }
                            )
                            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))

                            legendBar
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let node = selectedGraphNode {
                        summaryCard(for: node)
                            .frame(width: 290)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: layoutSignature) {
            guard useELKLayout, !layout.columns.isEmpty else {
                elkLayout = nil
                return
            }
            let elkInput = RunGraphLogic.toELKGraph(from: layout)
            elkLayout = try? await ELKLayoutEngine.shared.layout(graph: elkInput)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Turns left to right · subagent runs below the turn that delegated them")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.secondaryText)
            Spacer()
            if !listMode {
                Button(useELKLayout ? "Lane layout" : "ELK layout") {
                    useELKLayout.toggle()
                }
                .buttonStyle(.vesper(.outline))
            }
            Button(listMode ? "Graph" : "List") {
                listMode.toggle()
            }
            .buttonStyle(.vesper(.outline))
        }
    }

    private var legendBar: some View {
        HStack(spacing: 14) {
            legendSwatch(theme.swiftUIColor("state-done", fallback: .green), "done")
            legendSwatch(theme.palette.accent, "running")
            legendSwatch(theme.swiftUIColor("state-human", fallback: .orange), "waiting")
            legendSwatch(theme.swiftUIColor("state-blocked", fallback: .red), "failed")
            legendSwatch(theme.palette.border, "pending / cancelled")
            Spacer()
            Text("Click selects · double-click opens")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.tertiaryText)
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(label)
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
    }

    private var listFallback: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(layout.columns.enumerated()), id: \.offset) { _, col in
                    let lbl = RunGraphLogic.labels(for: col.main)
                    VStack(alignment: .leading, spacing: 6) {
                        Button { handleSelect(col.main.id) } label: {
                            HStack {
                                Text(lbl.title).fontWeight(.semibold)
                                Text(lbl.subtitle).foregroundStyle(theme.palette.secondaryText)
                                Spacer()
                            }
                            .padding(8)
                            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedId == col.main.id ? theme.palette.accent : theme.palette.border))
                        }
                        .buttonStyle(.plain)

                        ForEach(col.branch) { branch in
                            let bLbl = RunGraphLogic.labels(for: branch)
                            Button { handleSelect(branch.id) } label: {
                                HStack {
                                    Text(bLbl.title).fontWeight(.medium)
                                    Text(bLbl.subtitle).foregroundStyle(theme.palette.secondaryText)
                                    Spacer()
                                }
                                .padding(7)
                                .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedId == branch.id ? theme.palette.accent : theme.palette.border))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, CGFloat(branch.depth * 18))
                        }
                    }
                }
            }
        }
    }

    private func handleSelect(_ id: String?) {
        guard let id else {
            selectedId = nil
            return
        }
        // Group and "more" placeholders toggle immediately on click.
        if id.hasPrefix("group:") {
            toggleExpanded(id)
            return
        }
        if id.hasPrefix("more:") {
            toggleExpanded(String(id.dropFirst(5)))
            return
        }
        if selectedId == id {
            activateNode(id: id)
        } else {
            selectedId = id
        }
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func activateNode(id: String) {
        if id.hasPrefix("group:") { toggleExpanded(id); return }
        if id.hasPrefix("more:") { toggleExpanded(String(id.dropFirst(5))); return }
        guard let node = runGraph.nodes.first(where: { $0.id == id }) else { return }
        switch node {
        case .turn(let t):
            onOpenTurn(t.turn)
        case .subagentRun(let s):
            context.navigate("/runs/\(s.runId)")
        case .gate(let g):
            onOpenTurn(g.afterTurn)
        case .error(let e):
            onOpenEvent(e.seq)
        case .outcome:
            break
        }
    }

    private var selectedGraphNode: RunGraphLogic.GraphNode? {
        guard let selectedId else { return nil }
        return runGraph.nodes.first { $0.id == selectedId }
    }

    @ViewBuilder
    private func summaryCard(for node: RunGraphLogic.GraphNode) -> some View {
        let turnMap = RunGraphLogic.turnByEvent(mergedDetail.events)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summaryTitle(for: node))
                    .vesperText(.heading, theme)
                Spacer()
                Button { selectedId = nil } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            ForEach(summaryRows(for: node), id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(key)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                        .frame(width: 84, alignment: .leading)
                    Text(value)
                        .vesperText(.body, theme)
                    Spacer()
                }
            }

            if let message = summaryMessage(for: node, turnMap: turnMap), !message.isEmpty {
                Text(message)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 6))
            }

            if let actionTitle = summaryAction(for: node) {
                Button(actionTitle) {
                    activateNode(id: node.id)
                }
                .buttonStyle(.vesper(.primary))
            }
        }
        .padding(14)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }

    private func summaryTitle(for node: RunGraphLogic.GraphNode) -> String {
        switch node {
        case .turn(let t): "Turn \(t.turn) · \(t.trigger)"
        case .subagentRun(let s): "↳ \(s.agent)"
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
            var rows = [
                ("Status", s.status.label),
                ("Cost", String(format: "$%.2f", s.costUsd)),
            ]
            if s.childCount > 0 { rows.append(("Nested runs", "\(s.childCount)")) }
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

    private func summaryMessage(for node: RunGraphLogic.GraphNode, turnMap: [Int: Int]) -> String? {
        switch node {
        case .turn(let t):
            return RunGraphLogic.finalMessage(mergedDetail.events.filter { turnMap[$0.seq] == t.turn })
        case .subagentRun(let s):
            return mergedDetail.childRuns.first(where: { $0.id == s.runId })?.outcome
        case .gate:
            return nil
        case .error(let e):
            return e.message
        case .outcome(let o):
            return o.text
        }
    }

    private func summaryAction(for node: RunGraphLogic.GraphNode) -> String? {
        switch node {
        case .turn, .error: "Open in Trace"
        case .subagentRun: "Open run"
        case .gate(let g): g.state == .pending ? "Go to turn \(g.afterTurn)" : "Open turn \(g.afterTurn)"
        case .outcome: nil
        }
    }
}
