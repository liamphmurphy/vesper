import SwiftUI
import VesperCore

/// Structured Trace timeline (`Trace` tab): filter tabs (All / Messages / Tools / Errors),
/// text search, Expand/Collapse all, Follow toggle with Jump to latest, collapsible turn groups,
/// and expandable JSON payload inspection.
struct RunTraceView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let detail: API.RunDetail
    let childDetails: [API.RunDetail]
    let events: [API.RunEvent]
    let childLoadError: Bool
    let childLoading: Bool
    @Binding var filter: RunThreadLogic.TraceFilter
    @Binding var search: String
    @Binding var anchor: RunsLogic.Anchor?

    @State private var allExpanded = false
    @State private var turnOpen: [Int: Bool] = [:]
    @State private var toolOpen: [String: Bool] = [:]
    @State private var payloadOpen: Set<String> = []
    @State private var follow = true

    private var run: API.Run { detail.run }
    private var isLive: Bool { RunsLogic.isLive(run) }

    var body: some View {
        let built = RunThreadLogic.buildTrace(
            detail: detail,
            events: events,
            childDetails: childDetails,
            filter: filter,
            search: search
        )
        let lastTurn = max(detail.turns.map(\.seq).max() ?? 0, built.groups.map(\.turn).max() ?? 0)
        let focusTurn = anchor.flatMap { a -> Int? in
            if a.kind == .turn { return a.number }
            return RunThreadLogic.turnByEvent(events)[a.number]
        }

        VStack(spacing: 0) {
            filterBar(counts: built.counts)
            Divider()
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let outcome = run.outcome, !outcome.isEmpty, !isLive {
                                VStack(alignment: .leading, spacing: 6) {
                                    MarkdownView(markdown: outcome, textStyle: .body, textColor: "text-2", chat: true)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
                            }
                            if childLoadError {
                                Text("Couldn\u{2019}t load some delegated agent logs.")
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.12)), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if childLoading {
                                Text("Loading delegated agent logs…")
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.palette.secondaryText)
                            }
                            if built.groups.isEmpty {
                                emptyState(totalRows: built.counts.all)
                            } else {
                                ForEach(built.groups) { group in
                                    turnGroupSection(
                                        group,
                                        isOpen: isTurnOpen(group.turn, focusTurn: focusTurn, lastTurn: lastTurn)
                                    )
                                    .id("turn-\(group.turn)")
                                }
                            }
                            Text(
                                "Normalized events. The raw harness stream of each turn is kept with the run ("
                                    + (run.mode == .managed ? "raw links on each turn" : "unmanaged sessions have none")
                                    + "). Plan and usage live in the Context dock."
                            )
                            .font(.system(size: theme.pointSize(.micro) + 1))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .padding(.top, 4)
                            Color.clear.frame(height: 1).id("trace-bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: anchor, initial: true) { _, next in
                        guard let next else { return }
                        follow = false
                        if next.kind == .turn {
                            turnOpen[next.number] = true
                        } else if let targetTurn = RunThreadLogic.turnByEvent(events)[next.number] {
                            turnOpen[targetTurn] = true
                        }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(next.scrollID, anchor: .top)
                            }
                        }
                    }
                    .onChange(of: events.count) { _, _ in
                        if follow && anchor == nil {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("trace-bottom", anchor: .bottom)
                            }
                        }
                    }

                    if !follow {
                        Button {
                            follow = true
                            anchor = nil
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("trace-bottom", anchor: .bottom)
                            }
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                        }
                        .buttonStyle(.vesper(.outline))
                        .padding(16)
                    }
                }
            }
        }
        .onChange(of: run.id) { _, _ in
            allExpanded = false
            turnOpen.removeAll()
            toolOpen.removeAll()
            payloadOpen.removeAll()
            follow = anchor == nil
        }
    }

    // MARK: - Filter Bar

    private func filterBar(counts: RunThreadLogic.TraceCounts) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(RunThreadLogic.TraceFilter.allCases, id: \.rawValue) { kind in
                    let active = filter == kind
                    Button {
                        filter = kind
                    } label: {
                        HStack(spacing: 4) {
                            Text(kind.label)
                            Text("\(counts[kind])")
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                .foregroundStyle(active ? theme.palette.accent : theme.palette.tertiaryText)
                        }
                        .font(.system(size: theme.pointSize(.small), weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(active ? theme.palette.selected : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
            TextField("Filter trace…", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
            Button(allExpanded ? "Collapse all" : "Expand all") {
                turnOpen.removeAll()
                toolOpen.removeAll()
                allExpanded.toggle()
            }
            .buttonStyle(.vesper(.outline))
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: theme.pointSize(.small)))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Turn Group

    private func isTurnOpen(_ turn: Int, focusTurn: Int?, lastTurn: Int) -> Bool {
        turnOpen[turn] ?? (allExpanded || turn == (focusTurn ?? lastTurn))
    }

    private func turnGroupSection(_ group: RunThreadLogic.TraceTurnGroup, isOpen: Bool) -> some View {
        let sunken = theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)
        let record = group.turnRecord
        let usage = record?.usage ?? [:]
        let costVal = RunsLogic.jsonDouble(usage["cost_usd"]) ?? 0
        let costStr = WorkLogic.runCost(costVal, source: usage["cost_source"]?.stringValue)
        let toolCallsCount = RunThreadLogic.jsonInt(usage["tool_calls"])
        let inputTokens = RunThreadLogic.jsonInt(usage["input_tokens"]) ?? 0
        let outputTokens = RunThreadLogic.jsonInt(usage["output_tokens"]) ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    turnOpen[group.turn] = !isOpen
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .frame(width: 12)
                        Text(group.title)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(theme.palette.text)
                        if let trig = group.triggerSummary {
                            Text(trig)
                                .vesperText(.small, theme)
                                .foregroundStyle(theme.palette.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let record {
                    HStack(spacing: 6) {
                        if record.status == .pending {
                            Text("waiting for the runner")
                        } else if record.status == .running {
                            Text("running")
                                .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                        } else {
                            Text(RunsLogic.clockTime(record.processStartedAt ?? record.startedAt))
                            if let procStart = record.processStartedAt {
                                Text("· \(APIDate.duration(since: procStart, until: record.endedAt, now: Date()))")
                            }
                            if let toolCallsCount {
                                Text("· \(toolCallsCount) calls")
                            }
                            Text("· \(costStr)")
                            if let exitCode = record.exitCode, exitCode != 0 {
                                Text("· exit \(exitCode)")
                            }
                        }
                        if record.hasLog {
                            Button("raw \u{2197}") {
                                openRawLog(turnSeq: record.seq)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(sunken.opacity(0.75))

            if isOpen {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.entries) { entry in
                        traceEntryView(entry)
                            .id(entry.sourceRun == nil ? "event-\(entry.anchorEvent.seq)" : entry.id)
                    }
                }
                .padding(12)

                if let record, record.hasLog || record.status == .done {
                    Divider()
                    HStack {
                        Text(
                            "Turn \(group.turn) total · \(RunsLogic.compactNumber(inputTokens)) in · "
                                + "\(RunsLogic.compactNumber(outputTokens)) out · \(costStr)"
                        )
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                        Spacer()
                        if record.hasLog {
                            Button("raw log \u{2197}") {
                                openRawLog(turnSeq: record.seq)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: theme.pointSize(.micro) + 1))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(theme.palette.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    @ViewBuilder
    private func traceEntryView(_ entry: RunThreadLogic.TraceEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source = entry.sourceRun {
                Button("\(source.agent.name) · delegated agent") {
                    context.navigate("/runs/\(source.id)")
                }
                .buttonStyle(.link)
                .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium))
            }
            switch entry.row {
            case .tool(let pair):
                RunToolCallCard(
                    pair: pair,
                    isOpen: toolOpen[entry.id] ?? allExpanded,
                    onToggle: {
                        let current = toolOpen[entry.id] ?? allExpanded
                        toolOpen[entry.id] = !current
                    },
                    rawJSON: entry.rawPayloadJSON
                )
            case .event(let event):
                eventRowView(entry: entry, event: event)
            }
        }
    }

    @ViewBuilder
    private func eventRowView(entry: RunThreadLogic.TraceEntry, event: API.RunEvent) -> some View {
        let jsonVisible = payloadOpen.contains(entry.id)
        if event.type == .message && event.payload["kind"] == nil {
            let author = entry.sourceRun?.agent.name ?? run.agent.name
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(author)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(theme.palette.text)
                    Spacer()
                    Button(jsonVisible ? "Hide JSON" : "JSON") { togglePayload(entry.id) }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.micro) + 1))
                    Text(RunsLogic.clockTime(event.at, includeSeconds: true))
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                MarkdownView(markdown: entry.summaryText, textStyle: .body, textColor: "text-2", chat: true)
                if jsonVisible {
                    payloadJSONBox(entry: entry)
                }
            }
            .padding(12)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border)))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(theme.palette.accent.opacity(0.6))
                    .frame(width: 2)
            }
        } else {
            let rowBg: Color = entry.isError
                ? theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.15)).opacity(0.35)
                : entry.isWarning
                    ? theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.15)).opacity(0.35)
                    : Color.clear
            let rowBorder: Color = entry.isError
                ? theme.swiftUIColor("pill-blocked-bg", fallback: .red)
                : entry.isWarning
                    ? theme.swiftUIColor("state-human", fallback: .orange).opacity(0.4)
                    : Color.clear

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(event.type == .message && event.payload["kind"]?.stringValue == "thinking" ? "Thinking: \(entry.summaryText)" : entry.summaryText)
                        .font(
                            event.type == .usage || event.type == .toolResult
                                ? .system(size: theme.pointSize(.micro) + 1, design: .monospaced)
                                : .system(size: theme.pointSize(.small))
                        )
                        .foregroundStyle(
                            entry.isError
                                ? theme.swiftUIColor("pill-blocked-fg", fallback: .red)
                                : theme.palette.secondaryText
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(jsonVisible ? "Hide JSON" : "JSON") { togglePayload(entry.id) }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.micro) + 1))

                    Text(RunsLogic.clockTime(event.at, includeSeconds: true))
                        .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                if jsonVisible {
                    payloadJSONBox(entry: entry)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(rowBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(rowBorder))
        }
    }

    private func payloadJSONBox(entry: RunThreadLogic.TraceEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("seq \(entry.anchorEvent.seq) · \(entry.anchorEvent.type.rawValue)")
                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                Spacer()
                Button("Copy JSON") {
                    context.copyToClipboard(entry.rawPayloadJSON)
                    context.showToast(ToastItemModel(id: "trace.json.\(entry.id)", title: "Copied event JSON", tone: .success))
                }
                .buttonStyle(.link)
                .font(.system(size: theme.pointSize(.micro) + 1))
            }
            ScrollView(.horizontal) {
                Text(entry.rawPayloadJSON)
                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.secondaryText)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 6))
    }

    private func emptyState(totalRows: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(theme.palette.tertiaryText)
            Text(totalRows > 0 ? "No events match" : "No events yet")
                .vesperText(.heading, theme)
            Text(totalRows > 0 ? "Try another tab or filter."
                 : run.state == .queued ? "The run starts when a runner slot is free."
                 : "Events appear as the harness works.")
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    private func togglePayload(_ id: String) {
        if payloadOpen.contains(id) {
            payloadOpen.remove(id)
        } else {
            payloadOpen.insert(id)
        }
    }

    private func openRawLog(turnSeq: Int) {
        let path = RunsLogic.rawLogPath(runId: run.id, turnSeq: turnSeq)
        if let url = context.resolvedURL(path) {
            context.openExternal(url.absoluteString)
        }
    }
}
