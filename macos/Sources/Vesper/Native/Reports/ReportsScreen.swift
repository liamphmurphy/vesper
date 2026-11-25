import Charts
import SwiftUI
import VesperCore

/// Pure-SwiftUI Reports screen (`/reports` and `/costs`) with Swift Charts. Zero AppKit imports.
struct ReportsScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var tab: ReportsLogic.Tab = .costs
    @State private var preset: ReportsLogic.RangePreset = .days30
    @State private var customFrom: String = ReportsLogic.presetRange(days: 30).from
    @State private var customTo: String = ReportsLogic.presetRange(days: 30).to
    @State private var projectFilter: String = ""
    @State private var groupBy: ReportsLogic.GroupBy = .agents
    @State private var personaFilter: String = "all"
    @State private var effortSelection: ReportsLogic.EffortSelection = .all
    @State private var watched: [QueryKey] = []

    private static let bootstrapRequest = API.getBootstrap()

    private var activeRange: (from: String, to: String) {
        if let days = preset.dayCount {
            return ReportsLogic.presetRange(days: days)
        }
        return (customFrom, customTo)
    }

    private var projectParam: String? { projectFilter.isEmpty ? nil : projectFilter }

    private var costsRequest: APIRequest<API.CostReport> {
        let range = activeRange
        return API.getCosts(from: range.from, to: range.to, project: projectParam)
    }

    private var highlightsRequest: APIRequest<API.GetHighlightsResponse> {
        let range = activeRange
        return API.getHighlights(from: range.from, to: range.to, project: projectParam)
    }

    var body: some View {
        let store = context.store
        let projects = (store.entry(Self.bootstrapRequest).data?.projects ?? []).filter { !$0.archived }
        let agents = store.entry(Self.bootstrapRequest).data?.agents ?? []
        let agentNames = Dictionary(agents.map { ($0.handle, $0.name) }, uniquingKeysWith: { _, latest in latest })
        let currentChrome = NativeChrome(
            title: "Reports",
            subtitle: tab.label,
            navigator: ReportsLogic.navModel(
                tab: tab,
                preset: preset,
                groupBy: groupBy,
                projectFilter: projectFilter,
                projects: projects
            )
        )

        VStack(spacing: 0) {
            if preset == .custom {
                customRangeBar
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == .costs {
                        costsContent(entry: store.entry(costsRequest), agentNames: agentNames)
                    } else {
                        highlightsContent(entry: store.entry(highlightsRequest))
                    }
                }
                .padding(24)
                .frame(maxWidth: 1040, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: currentChrome, initial: true) { _, next in
            context.chrome = next
        }
        .onAppear {
            context.chrome = currentChrome
            context.onCommand = { handleCommand($0) }
        }
        .task(id: context.match) {
            seed(from: context.match)
            watch()
        }
        .task(id: "\(tab.rawValue)|\(activeRange.from)|\(activeRange.to)|\(projectFilter)") {
            watch()
        }
        .onDisappear {
            context.onCommand = nil
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
    }

    private func handleCommand(_ command: NativeCommand) {
        guard let action = ReportsLogic.navAction(for: command) else { return }
        switch action {
        case .selectTab(let next): tab = next
        case .selectRange(let next): preset = next
        case .selectGroup(let next): groupBy = next
        case .selectSpace(let key): projectFilter = key
        }
    }

    private var customRangeBar: some View {
        HStack(spacing: 10) {
            Text("Custom range")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.palette.secondaryText)
            TextField("YYYY-MM-DD", text: $customFrom).textFieldStyle(.roundedBorder).frame(width: 110)
            Text("to").foregroundStyle(theme.palette.secondaryText)
            TextField("YYYY-MM-DD", text: $customTo).textFieldStyle(.roundedBorder).frame(width: 110)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func costsContent(entry: QueryEntry<API.CostReport>, agentNames: [String: String]) -> some View {
        let p = theme.palette
        if let err = ReportsLogic.rangeError(from: activeRange.from, to: activeRange.to) {
            Text(err).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
        } else if entry.data == nil && entry.error == nil {
            SkeletonBar(height: 220)
        } else if let error = entry.error, entry.data == nil {
            QueryErrorView(message: error.userMessage) {
                Task { _ = await context.store.refetch(costsRequest) }
            }
        } else if let report = entry.data {
            let stacked = ReportsLogic.stackSeries(days: report.days, by: groupBy)
            let points = ReportsLogic.chartPoints(from: stacked, by: groupBy, agentNames: agentNames)
            let cpp = ReportsLogic.costPerPoint(micros: report.estimated.costMicros, points: report.estimated.points)

            HStack(spacing: 12) {
                kpiCard(title: "Total spend", value: ReportsLogic.spendLabel(micros: report.total.costMicros, unpricedRuns: report.unpricedRuns), subtitle: "\(report.total.runs) runs")
                kpiCard(title: "Tokens", value: ReportsLogic.compactCount(report.total.tokens), subtitle: report.unpricedRuns > 0 ? "\(report.unpricedRuns) unpriced" : "All priced")
                kpiCard(title: "Cost / point", value: cpp ?? "–", subtitle: "\(report.estimated.tickets) estimated tickets")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Daily spend (\(groupBy.label.lowercased()))").font(.headline)
                if points.isEmpty {
                    Text("No spend recorded in this range.")
                        .font(.callout)
                        .foregroundStyle(p.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Chart(points) { pt in
                        BarMark(
                            x: .value("Day", ReportsLogic.formatUTCShortDay(pt.date)),
                            y: .value("USD", pt.dollars)
                        )
                        .foregroundStyle(by: .value("Series", pt.seriesLabel))
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(String(format: "$%.2f", v))
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                }
            }
            .padding(16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))

            HStack(alignment: .top, spacing: 16) {
                breakdownCard(title: "By agent", slices: report.agents, total: report.total.costMicros)
                breakdownCard(title: "By model", slices: report.models, total: report.total.costMicros)
            }

            HStack(alignment: .top, spacing: 16) {
                breakdownCard(title: "By space", slices: report.projects, total: report.total.costMicros)
                breakdownCard(title: "By purpose", slices: report.purposes, total: report.total.costMicros)
            }

            if !report.topTickets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top tickets").font(.headline)
                    ForEach(report.topTickets, id: \.key) { ticket in
                        Button {
                            context.navigate("/tickets/\(ticket.key)")
                        } label: {
                            HStack {
                                Text(ticket.key).font(.caption.monospaced()).foregroundStyle(p.secondaryText)
                                Text(ticket.title).lineLimit(1)
                                Spacer()
                                if let pts = ticket.points {
                                    Text("\(pts) pt").font(.caption).foregroundStyle(p.secondaryText)
                                }
                                Text(ReportsLogic.usd(micros: ticket.costMicros)).font(.callout.monospacedDigit().weight(.medium))
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(16)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            }
        }
    }

    @ViewBuilder
    private func highlightsContent(entry: QueryEntry<API.GetHighlightsResponse>) -> some View {
        let p = theme.palette
        if entry.data == nil && entry.error == nil {
            SkeletonBar(height: 180)
        } else if let error = entry.error, entry.data == nil {
            QueryErrorView(message: error.userMessage) {
                Task { _ = await context.store.refetch(highlightsRequest) }
            }
        } else if let resp = entry.data {
            let filtered = ReportsLogic.filterBuckets(resp.buckets, personaId: personaFilter, selection: effortSelection)
            let summary = ReportsLogic.routingHighlights(filtered)

            HStack(spacing: 12) {
                Picker("Effort", selection: $effortSelection) {
                    ForEach(ReportsLogic.EffortSelection.allCases, id: \.self) { sel in
                        Text(sel.label).tag(sel)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Spacer()
            }

            HStack(spacing: 12) {
                kpiCard(title: "Turns", value: "\(summary.turns)", subtitle: "\(summary.automatic) auto · \(summary.chosen) manual")
                kpiCard(title: "Raised", value: "\(summary.raised)", subtitle: "\(summary.adjusted) adjusted")
                kpiCard(title: "Avg latency", value: summary.averageMs.map { String(format: "%.1fs", $0 / 1000.0) } ?? "–", subtitle: "\(summary.timed) timed turns")
            }

            if !summary.efforts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Turns by effort").font(.headline)
                    Chart(summary.efforts) { row in
                        BarMark(
                            x: .value("Effort", row.label),
                            y: .value("Turns", row.turns)
                        )
                        .foregroundStyle(p.accent)
                    }
                    .frame(height: 200)
                }
                .padding(16)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
            }

            HStack(alignment: .top, spacing: 16) {
                highlightTable(title: "By persona", rows: summary.personas)
                highlightTable(title: "By model", rows: summary.models)
            }
        }
    }

    private func kpiCard(title: String, value: String, subtitle: String) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(p.secondaryText)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(subtitle).font(.caption).foregroundStyle(p.tertiaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func breakdownCard(title: String, slices: [API.CostSlice], total: Int) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if slices.isEmpty {
                Text("None").font(.callout).foregroundStyle(p.secondaryText)
            } else {
                ForEach(slices.prefix(10), id: \.key) { slice in
                    HStack {
                        Text(slice.label).lineLimit(1)
                        Spacer()
                        Text(ReportsLogic.share(part: slice.costMicros, total: total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(p.secondaryText)
                        Text(ReportsLogic.spendLabel(micros: slice.costMicros, unpricedRuns: slice.unpricedRuns))
                            .font(.callout.monospacedDigit())
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func highlightTable(title: String, rows: [ReportsLogic.HighlightRow]) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("None").font(.callout).foregroundStyle(p.secondaryText)
            } else {
                ForEach(rows.prefix(10)) { row in
                    HStack {
                        Text(row.label).lineLimit(1)
                        Spacer()
                        Text("\(row.turns) turns").font(.callout.monospacedDigit()).foregroundStyle(p.secondaryText)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func seed(from match: NativeRouteMatch) {
        if match.path == "/costs" || match.query["tab"] == "costs" {
            tab = .costs
        } else if match.query["tab"] == "highlights" {
            tab = .highlights
        }
        if let project = match.query["project"] {
            projectFilter = project
        }
    }

    private func watch() {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        func start<V: Sendable>(_ req: APIRequest<V>) -> QueryKey {
            store.observe(req)
            store.load(req)
            return req.key
        }
        var next = [start(Self.bootstrapRequest)]
        if ReportsLogic.rangeError(from: activeRange.from, to: activeRange.to) == nil {
            next.append(tab == .costs ? start(costsRequest) : start(highlightsRequest))
        }
        watched = next
    }
}
