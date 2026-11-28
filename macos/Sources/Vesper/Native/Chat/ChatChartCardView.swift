import AppKit
import Charts
import SwiftUI
import VesperCore

/// Native Swift Charts & Canvas renderer for `ChatChartSpec` (LAZYAGENTS-321):
/// `bar`, `stacked-bar`, `line`, `area`, `stacked-area`, `scatter`, `histogram`, `heatmap`,
/// `calendar-heatmap`, `radar`, `sparkline`, `waterfall`, and `sankey`, using `ChatVizPalette(theme:)`.
struct ChatChartCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatChartSpec

    @State private var mode: DisplayMode = .chart
    @State private var showLightbox = false
    @State private var hiddenSeries: Set<Int> = []
    @State private var hoveredCategory: String?
    @State private var hoveredWaterfallIndex: Int?
    @State private var hoveredSankeyNodeId: String?
    @State private var savingLibrary = false
    @State private var savedLibrary = false

    private enum DisplayMode: String, CaseIterable {
        case chart = "Chart"
        case data = "Data"
    }

    private var viz: ChatVizPalette { ChatVizPalette(theme: theme) }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(p.rowBorder).frame(height: 1)
            if mode == .chart {
                chartBody(height: spec.type == .sparkline ? 96 : 250)
            } else {
                tableBody
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? defaultTitle, subtitle: spec.subtitle) {
                chartBody(height: 440)
            }
        }
    }

    private var header: some View {
        let p = theme.palette
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: chartIcon)
                .imageScale(.small)
                .foregroundStyle(p.tertiaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.title ?? defaultTitle)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                if let subtitle = spec.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(DisplayMode.allCases, id: \.self) { item in
                    Button(item.rawValue) { mode = item }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.small), weight: mode == item ? .medium : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(mode == item ? p.text : p.tertiaryText)
                        .background(mode == item ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            if mode == .data {
                Button {
                    context.copyToClipboard(csvText())
                    context.showToast(ToastItemModel(id: "chart.csv", title: "Copied CSV", tone: .success))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Copy CSV")
            } else {
                Button {
                    ChatVizExporter.copyPNG(of: exportSnapshotView, context: context)
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Copy chart as PNG")

                Button {
                    guard !savingLibrary else { return }
                    savingLibrary = true
                    Task {
                        defer { savingLibrary = false }
                        if await ChatVizExporter.savePNGToLibrary(
                            of: exportSnapshotView,
                            title: spec.title ?? defaultTitle,
                            context: context
                        ) {
                            savedLibrary = true
                        }
                    }
                } label: {
                    Image(systemName: savedLibrary ? "checkmark" : "bookmark")
                        .imageScale(.small)
                        .foregroundStyle(savedLibrary ? p.accent : p.tertiaryText)
                }
                .buttonStyle(.plain)
                .disabled(savingLibrary)
                .help(savedLibrary ? "Saved to Library" : "Save chart PNG to Library")
            }
            Button {
                showLightbox = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Expand to lightbox")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func chartBody(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if spec.series.count > 1 {
                legendRow
            }
            Group {
                switch spec.type {
                case .bar:
                    interactiveCategorical(axisDecorated(barChart, height: height))
                case .stackedBar:
                    interactiveCategorical(axisDecorated(stackedBarChart, height: height))
                case .line:
                    interactiveCategorical(axisDecorated(lineChart, height: height))
                case .area:
                    interactiveCategorical(axisDecorated(areaChart(stacked: false), height: height))
                case .stackedArea:
                    interactiveCategorical(axisDecorated(areaChart(stacked: true), height: height))
                case .scatter:
                    axisDecorated(scatterChart, height: height)
                case .histogram:
                    axisDecorated(histogramChart, height: height)
                case .heatmap:
                    heatmapView
                case .calendarHeatmap:
                    calendarHeatmapView
                case .radar:
                    radarView(height: max(height, 260))
                case .sparkline:
                    sparklineChartView
                case .waterfall:
                    waterfallView(height: max(height, 250))
                case .sankey:
                    sankeyView(height: max(height, 260))
                }
            }
            .overlay(alignment: .topTrailing) {
                // Float the hover readout above the plot rather than inserting a row into the
                // VStack so hovering bars/lines/waterfall/sankey never shifts the card height.
                if let readout = activeHoverReadout {
                    Text(readout)
                        .font(.system(size: theme.pointSize(.micro), weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.palette.text)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            theme.swiftUIColor("surface-raised", fallback: theme.palette.surface),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.accent.opacity(0.45)))
                        .shadow(color: .black.opacity(theme.mode == .dark ? 0.30 : 0.12), radius: 6, y: 2)
                        .padding(6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.10), value: activeHoverReadout != nil)
        }
        .padding(14)
    }

    private var exportSnapshotView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(theme.palette.text)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
            chartBody(height: 280)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
        .environment(\.vesperTheme, theme)
    }

    private var activeHoverReadout: String? {
        if let cat = hoverReadoutText { return cat }
        if let wf = waterfallHoverReadoutText { return wf }
        if let sk = sankeyHoverReadoutText { return sk }
        return nil
    }

    private var waterfallHoverReadoutText: String? {
        guard spec.type == .waterfall,
              let idx = hoveredWaterfallIndex,
              idx >= 0, idx < spec.waterfallItems.count else { return nil }
        let it = spec.waterfallItems[idx]
        let delta = it.kind == .delta && it.value > 0 ? "+\(spec.formattedValue(it.value))" : spec.formattedValue(it.value)
        return "\(it.label): \(delta) · total \(spec.formattedValue(it.endY))"
    }

    private var sankeyHoverReadoutText: String? {
        guard spec.type == .sankey,
              let id = hoveredSankeyNodeId,
              let data = spec.sankey,
              let node = data.nodes.first(where: { $0.id == id }) else { return nil }
        let outSum = data.links.filter { $0.from == id }.reduce(0) { $0 + $1.value }
        let inSum = data.links.filter { $0.to == id }.reduce(0) { $0 + $1.value }
        let total = max(outSum, inSum)
        return "\(node.label): \(spec.formattedValue(total))"
    }

    private var hoverReadoutText: String? {
        guard let cat = hoveredCategory,
              let cIdx = spec.categories.firstIndex(of: cat) else { return nil }
        let parts = spec.series.enumerated().compactMap { sIdx, s -> String? in
            guard !hiddenSeries.contains(sIdx), cIdx < s.values.count, let v = s.values[cIdx] else { return nil }
            let name = s.name.isEmpty ? (spec.y.label ?? "Value") : s.name
            return "\(name): \(spec.formattedValue(v))"
        }
        guard !parts.isEmpty else { return nil }
        return "\(cat) — \(parts.joined(separator: " · "))"
    }

    private func interactiveCategorical<C: View>(_ chart: C) -> some View {
        chart.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let x = location.x - origin.x
                            if let cat: String = proxy.value(atX: x) {
                                hoveredCategory = cat
                            }
                        case .ended:
                            hoveredCategory = nil
                        }
                    }
            }
        }
    }

    private func axisDecorated<C: View>(_ chart: C, height: CGFloat) -> some View {
        chart
            .frame(height: height)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(spec.type == .histogram ? ChatChartSpec.compactNumber(v) : spec.formattedValue(v))
                                .font(.system(size: theme.pointSize(.micro)))
                        }
                    }
                }
            }
            .chartXAxisLabel(alignment: .center) {
                if let label = spec.x.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
            .chartYAxisLabel(position: .leading, alignment: .center) {
                if let label = spec.y.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
    }

    private var legendRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                    let hidden = hiddenSeries.contains(idx)
                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            let allOthers = Set(spec.series.indices.filter { $0 != idx })
                            hiddenSeries = (hiddenSeries == allOthers) ? [] : allOthers
                        } else if hidden {
                            hiddenSeries.remove(idx)
                        } else if hiddenSeries.count + 1 < spec.series.count {
                            hiddenSeries.insert(idx)
                        } else {
                            hiddenSeries.removeAll()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(viz.seriesColor(at: idx).opacity(hidden ? 0.28 : 1))
                                .frame(width: 8, height: 8)
                            Text(series.name.isEmpty ? "Series \(idx + 1)" : series.name)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(hidden ? theme.palette.tertiaryText : theme.palette.secondaryText)
                                .strikethrough(hidden)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(hidden ? Color.clear : theme.palette.surface.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Click to hide/show series · Option-click to solo")
                }
            }
        }
    }

    // MARK: - Bar / Stacked Bar

    private struct BarDatum: Identifiable {
        let id: String
        let category: String
        let seriesName: String
        let seriesIndex: Int
        let value: Double
    }

    private var barData: [BarDatum] {
        var rows: [BarDatum] = []
        for (sIdx, series) in spec.series.enumerated() where !hiddenSeries.contains(sIdx) {
            let sName = series.name.isEmpty ? (spec.y.label ?? "Value") : series.name
            for (cIdx, category) in spec.categories.enumerated() where cIdx < series.values.count {
                if let val = series.values[cIdx] {
                    rows.append(BarDatum(id: "\(sIdx)-\(cIdx)", category: category, seriesName: sName, seriesIndex: sIdx, value: val))
                }
            }
        }
        return rows
    }

    private var barChart: some View {
        Chart(barData) { item in
            if spec.series.count > 1 {
                BarMark(
                    x: .value(spec.x.label ?? "Category", item.category),
                    y: .value(spec.y.label ?? "Value", item.value)
                )
                .foregroundStyle(viz.seriesColor(at: item.seriesIndex))
                .position(by: .value("Series", item.seriesName))
                .cornerRadius(3)
            } else {
                BarMark(
                    x: .value(spec.x.label ?? "Category", item.category),
                    y: .value(spec.y.label ?? "Value", item.value)
                )
                .foregroundStyle(viz.seriesColor(at: 0))
                .cornerRadius(3)
            }
        }
    }

    private var stackedBarChart: some View {
        Chart(barData) { item in
            BarMark(
                x: .value(spec.x.label ?? "Category", item.category),
                y: .value(spec.y.label ?? "Value", item.value),
                stacking: .standard
            )
            .foregroundStyle(viz.seriesColor(at: item.seriesIndex))
        }
    }

    // MARK: - Line / Area / Stacked Area

    private struct LineDatum: Identifiable {
        let id: String
        let runKey: String
        let category: String
        let seriesIndex: Int
        let value: Double
    }

    private var lineData: [LineDatum] {
        var rows: [LineDatum] = []
        for (sIdx, series) in spec.series.enumerated() where !hiddenSeries.contains(sIdx) {
            var run = 0
            for (cIdx, category) in spec.categories.enumerated() where cIdx < series.values.count {
                if let val = series.values[cIdx] {
                    rows.append(LineDatum(id: "\(sIdx)-\(cIdx)", runKey: "\(sIdx)-\(run)", category: category, seriesIndex: sIdx, value: val))
                } else {
                    run += 1
                }
            }
        }
        return rows
    }

    private var lineChart: some View {
        Chart(lineData) { item in
            LineMark(
                x: .value(spec.x.label ?? "Category", item.category),
                y: .value(spec.y.label ?? "Value", item.value),
                series: .value("Run", item.runKey)
            )
            .foregroundStyle(viz.seriesColor(at: item.seriesIndex))
            .lineStyle(StrokeStyle(lineWidth: 2))

            PointMark(
                x: .value(spec.x.label ?? "Category", item.category),
                y: .value(spec.y.label ?? "Value", item.value)
            )
            .foregroundStyle(viz.seriesColor(at: item.seriesIndex))
            .symbolSize(24)
        }
    }

    private func areaChart(stacked: Bool) -> some View {
        Chart(lineData) { item in
            let col = viz.seriesColor(at: item.seriesIndex)
            AreaMark(
                x: .value(spec.x.label ?? "Category", item.category),
                y: .value(spec.y.label ?? "Value", item.value),
                series: .value("Run", item.runKey),
                stacking: stacked ? .standard : .unstacked
            )
            .foregroundStyle(col.opacity(stacked ? 0.55 : 0.25))

            if !stacked {
                LineMark(
                    x: .value(spec.x.label ?? "Category", item.category),
                    y: .value(spec.y.label ?? "Value", item.value),
                    series: .value("Run", item.runKey)
                )
                .foregroundStyle(col)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
    }

    // MARK: - Scatter & Histogram

    private struct ScatterDatum: Identifiable {
        let id: String
        let seriesIndex: Int
        let x: Double
        let y: Double
    }

    private var scatterData: [ScatterDatum] {
        var rows: [ScatterDatum] = []
        for (sIdx, series) in spec.series.enumerated() where !hiddenSeries.contains(sIdx) {
            for (pIdx, point) in series.points.enumerated() {
                rows.append(ScatterDatum(id: "\(sIdx)-\(pIdx)", seriesIndex: sIdx, x: point.x, y: point.y))
            }
        }
        return rows
    }

    private var scatterChart: some View {
        Chart(scatterData) { item in
            PointMark(
                x: .value(spec.x.label ?? "X", item.x),
                y: .value(spec.y.label ?? "Y", item.y)
            )
            .foregroundStyle(viz.seriesColor(at: item.seriesIndex))
            .symbolSize(36)
        }
    }

    private var histogramChart: some View {
        Chart(Array(spec.histogramBins.enumerated()), id: \.offset) { _, bin in
            BarMark(
                x: .value(spec.x.label ?? "Range", bin.label),
                y: .value(spec.y.label ?? "Count", Double(bin.count))
            )
            .foregroundStyle(viz.seriesColor(at: 0))
            .cornerRadius(2)
        }
    }

    // MARK: - Heatmap

    @ViewBuilder
    private var heatmapView: some View {
        if let hm = spec.heatmap {
            let span = max(hm.maxValue - hm.minValue, 1e-9)
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                        GridRow {
                            Text("")
                                .frame(minWidth: 64)
                            ForEach(hm.xLabels, id: \.self) { col in
                                Text(col)
                                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .lineLimit(1)
                                    .frame(minWidth: 44)
                            }
                        }
                        ForEach(Array(hm.yLabels.enumerated()), id: \.offset) { rIdx, rowLabel in
                            GridRow {
                                Text(rowLabel)
                                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .lineLimit(1)
                                    .frame(minWidth: 64, alignment: .trailing)
                                    .padding(.trailing, 4)
                                ForEach(0..<hm.xLabels.count, id: \.self) { cIdx in
                                    let val = hm.matrix[rIdx][cIdx]
                                    let t = val.map { ($0 - hm.minValue) / span } ?? 0
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(val == nil ? viz.panel : viz.sequentialColor(t: t))
                                        .frame(minWidth: 44, minHeight: 28)
                                        .overlay {
                                            if let val {
                                                Text(spec.formattedValue(val))
                                                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                                    .foregroundStyle(t > 0.55 ? Color.white : viz.ink)
                                                    .lineLimit(1)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Text(spec.formattedValue(hm.minValue))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText)
                        LinearGradient(
                            colors: [viz.sequentialColor(t: 0.05), viz.sequentialColor(t: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 90, height: 8)
                        .clipShape(Capsule())
                        Text(spec.formattedValue(hm.maxValue))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Calendar Heatmap

    private var calendarHeatmapView: some View {
        let days = spec.calendarDays
        let vals = days.map(\.value)
        let lo = vals.min() ?? 0
        let hi = vals.max() ?? 1
        let span = max(hi - lo, 1e-9)
        let columnsCount = max(1, Int(ceil(Double(days.count) / 7.0)))

        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(0..<columnsCount, id: \.self) { week in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { dow in
                                let idx = week * 7 + dow
                                if idx < days.count {
                                    let day = days[idx]
                                    let t = day.value <= 0 ? 0 : (day.value - lo) / span
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(viz.sequentialColor(t: t, accentIndex: 2))
                                        .frame(width: 13, height: 13)
                                        .help("\(day.date): \(spec.formattedValue(day.value))")
                                } else {
                                    Color.clear.frame(width: 13, height: 13)
                                }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if let first = days.first?.date, let last = days.last?.date {
                    Text("\(first) → \(last)")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                Spacer()
                HStack(spacing: 3) {
                    Text("Less").font(.system(size: theme.pointSize(.micro))).foregroundStyle(theme.palette.tertiaryText)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { t in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(viz.sequentialColor(t: t, accentIndex: 2))
                            .frame(width: 10, height: 10)
                    }
                    Text("More").font(.system(size: theme.pointSize(.micro))).foregroundStyle(theme.palette.tertiaryText)
                }
            }
        }
    }

    // MARK: - Radar Chart

    private func radarView(height: CGFloat) -> some View {
        let cats = spec.categories
        let allVals = spec.series.flatMap { $0.values.compactMap { $0 } }
        let maxVal = max(spec.radarMax ?? allVals.max() ?? 1.0, 1e-6)
        let palette = viz

        return Canvas { ctx, size in
            let n = cats.count
            guard n >= 3 else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(24, min(size.width, size.height) / 2 - 38)

            func point(index: Int, frac: Double) -> CGPoint {
                let angle = -Double.pi / 2 + (Double(index) / Double(n)) * 2 * Double.pi
                return CGPoint(
                    x: center.x + CGFloat(cos(angle) * frac) * radius,
                    y: center.y + CGFloat(sin(angle) * frac) * radius
                )
            }

            // Concentric guide polygons
            for ring in 1...4 {
                let f = Double(ring) / 4.0
                var path = Path()
                for i in 0..<n {
                    let pt = point(index: i, frac: f)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                ctx.stroke(path, with: .color(palette.grid), lineWidth: 1)
            }

            // Spokes & axis labels
            for i in 0..<n {
                var spoke = Path()
                spoke.move(to: center)
                spoke.addLine(to: point(index: i, frac: 1.0))
                ctx.stroke(spoke, with: .color(palette.grid), lineWidth: 1)

                let labelPt = point(index: i, frac: 1.16)
                let label = Text(cats[i]).font(.system(size: 11)).foregroundStyle(palette.muted)
                ctx.draw(ctx.resolve(label), at: labelPt, anchor: .center)
            }

            // Series polygons
            for (sIdx, series) in spec.series.enumerated() {
                let color = palette.seriesColor(at: sIdx)
                var poly = Path()
                for i in 0..<n {
                    let val = i < series.values.count ? (series.values[i] ?? 0) : 0
                    let frac = max(0, min(1, val / maxVal))
                    let pt = point(index: i, frac: frac)
                    if i == 0 { poly.move(to: pt) } else { poly.addLine(to: pt) }
                }
                poly.closeSubpath()
                ctx.fill(poly, with: .color(color.opacity(0.22)))
                ctx.stroke(poly, with: .color(color), lineWidth: 2)
            }
        }
        .frame(height: height)
    }

    // MARK: - Sparkline Chart

    private var sparklineChartView: some View {
        let vals = spec.sparklineValues
        let latest = vals.last.map(spec.formattedValue) ?? "—"
        let color = spec.sparklineTone != nil
            ? ChatVizPalette.toneColor(spec.sparklineTone, theme: theme)
            : viz.seriesColor(at: 0)

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(latest)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.palette.text)
                if let delta = spec.sparklineDelta {
                    Text(delta)
                        .font(.system(size: theme.pointSize(.small), weight: .medium, design: .monospaced))
                        .foregroundStyle(color)
                }
            }
            ChatSparklinePathView(values: vals, color: color)
                .frame(height: 52)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Accessible Data Table

    private var tableBody: some View {
        let table = spec.tableRows()
        let p = theme.palette
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { idx, header in
                        Text(header)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.secondaryText)
                            .gridColumnAlignment(idx == 0 ? .leading : .trailing)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                            Text(cell)
                                .font(.system(size: theme.pointSize(.small), design: idx == 0 ? .default : .monospaced))
                                .foregroundStyle(p.text)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Waterfall & Sankey

    private func waterfallView(height: CGFloat) -> some View {
        let items = spec.waterfallItems
        let allY = items.flatMap { [$0.startY, $0.endY, 0.0] }
        let lo = allY.min() ?? 0
        let hi = allY.max() ?? 1
        let span = max(hi - lo, 1e-9)
        let posColor = theme.swiftUIColor("state-done", fallback: .green)
        let negColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let totColor = viz.seriesColor(at: 0)
        let hovered = hoveredWaterfallIndex

        return GeometryReader { geo in
                let padTop: CGFloat = 20
                let padBottom: CGFloat = 34
                let padH: CGFloat = 12
                let plotH = max(40, geo.size.height - padTop - padBottom)
                let colW = (geo.size.width - padH * 2) / CGFloat(max(1, items.count))
                let barW = max(14, min(52, colW * 0.62))
                let yFor: (Double) -> CGFloat = { val in
                    padTop + (1 - CGFloat((val - lo) / span)) * plotH
                }

                Canvas { ctx, _ in
                    let zeroY = yFor(0)
                    var zeroLine = Path()
                    zeroLine.move(to: CGPoint(x: padH, y: zeroY))
                    zeroLine.addLine(to: CGPoint(x: geo.size.width - padH, y: zeroY))
                    ctx.stroke(zeroLine, with: .color(viz.grid), lineWidth: 1)

                    for (idx, item) in items.enumerated() {
                        let cx = padH + (CGFloat(idx) + 0.5) * colW
                        let topY = min(yFor(item.startY), yFor(item.endY))
                        let botY = max(yFor(item.startY), yFor(item.endY))
                        let rect = CGRect(x: cx - barW / 2, y: topY, width: barW, height: max(3, botY - topY))
                        let color: Color = switch item.kind {
                        case .start, .total: totColor
                        case .delta: item.value >= 0 ? posColor : negColor
                        }
                        let isHov = hovered == idx
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(isHov ? 1.0 : 0.82)))
                        if idx + 1 < items.count {
                            let nextCx = padH + (CGFloat(idx + 1) + 0.5) * colW
                            let connY = yFor(item.endY)
                            var conn = Path()
                            conn.move(to: CGPoint(x: cx + barW / 2, y: connY))
                            conn.addLine(to: CGPoint(x: nextCx - barW / 2, y: connY))
                            ctx.stroke(conn, with: .color(viz.muted.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                        let valText = item.kind == .delta && item.value > 0 ? "+\(spec.formattedValue(item.value))" : spec.formattedValue(item.value)
                        ctx.draw(Text(valText).font(.system(size: 10, design: .monospaced)).foregroundColor(viz.ink), at: CGPoint(x: cx, y: max(9, topY - 9)))
                        ctx.draw(Text(item.label).font(.system(size: 10)).foregroundColor(viz.muted), at: CGPoint(x: cx, y: geo.size.height - 14))
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let pt):
                        let idx = Int((pt.x - padH) / max(1, colW))
                        hoveredWaterfallIndex = (idx >= 0 && idx < items.count) ? idx : nil
                    case .ended:
                        hoveredWaterfallIndex = nil
                    }
                }
            }
            .frame(height: height)
    }

    private func sankeyView(height: CGFloat) -> some View {
        let data = spec.sankey ?? ChatSankeyData(nodes: [], links: [])
        let nodes = data.nodes
        let links = data.links
        // Compute topological column depth (0 = source, max = sink)
        var depth: [String: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for _ in 0..<nodes.count {
            for link in links {
                let dFrom = depth[link.from] ?? 0
                if (depth[link.to] ?? 0) <= dFrom {
                    depth[link.to] = min(nodes.count, dFrom + 1)
                }
            }
        }
        let maxCol = max(1, depth.values.max() ?? 1)
        let columns: [[ChatSankeyNode]] = (0...maxCol).map { col in
            nodes.filter { (depth[$0.id] ?? 0) == col }
        }
        var nodeTotals: [String: Double] = [:]
        for n in nodes {
            let outSum = links.filter { $0.from == n.id }.reduce(0) { $0 + $1.value }
            let inSum = links.filter { $0.to == n.id }.reduce(0) { $0 + $1.value }
            nodeTotals[n.id] = max(outSum, inSum, 1e-6)
        }
        let palette = viz
        let hoveredId = hoveredSankeyNodeId

        return GeometryReader { geo in
            let padX: CGFloat = 14
            let padY: CGFloat = 14
            let nodeW: CGFloat = 14
            let usableW = max(80, geo.size.width - padX * 2 - nodeW)
            let usableH = max(80, geo.size.height - padY * 2)
            let colStep = usableW / CGFloat(max(1, maxCol))
            let gapY: CGFloat = 10

            var nodeRects: [String: CGRect] = [:]
            var nodeColorIdx: [String: Int] = [:]
            for (idx, n) in nodes.enumerated() { nodeColorIdx[n.id] = idx }

            for (colIdx, colNodes) in columns.enumerated() where !colNodes.isEmpty {
                let colTotal = colNodes.reduce(0.0) { $0 + (nodeTotals[$1.id] ?? 1) }
                let totalGap = gapY * CGFloat(max(0, colNodes.count - 1))
                let availH = max(20, usableH - totalGap)
                var y = padY
                let x = padX + CGFloat(colIdx) * colStep
                for n in colNodes {
                    let h = max(14, CGFloat((nodeTotals[n.id] ?? 1) / max(colTotal, 1e-6)) * availH)
                    nodeRects[n.id] = CGRect(x: x, y: y, width: nodeW, height: h)
                    y += h + gapY
                }
            }

            return Canvas { ctx, _ in
                var outOffset: [String: CGFloat] = [:]
                var inOffset: [String: CGFloat] = [:]

                for link in links {
                    guard let fromRect = nodeRects[link.from], let toRect = nodeRects[link.to] else { continue }
                    let fromScale = fromRect.height / CGFloat(max(nodeTotals[link.from] ?? 1, 1e-6))
                    let toScale = toRect.height / CGFloat(max(nodeTotals[link.to] ?? 1, 1e-6))
                    let thickFrom = max(2, CGFloat(link.value) * fromScale)
                    let thickTo = max(2, CGFloat(link.value) * toScale)
                    let y1 = fromRect.minY + (outOffset[link.from] ?? 0)
                    let y2 = toRect.minY + (inOffset[link.to] ?? 0)
                    outOffset[link.from, default: 0] += thickFrom
                    inOffset[link.to, default: 0] += thickTo

                    let x1 = fromRect.maxX
                    let x2 = toRect.minX
                    let midX = (x1 + x2) / 2
                    var ribbon = Path()
                    ribbon.move(to: CGPoint(x: x1, y: y1))
                    ribbon.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: midX, y: y1), control2: CGPoint(x: midX, y: y2))
                    ribbon.addLine(to: CGPoint(x: x2, y: y2 + thickTo))
                    ribbon.addCurve(to: CGPoint(x: x1, y: y1 + thickFrom), control1: CGPoint(x: midX, y: y2 + thickTo), control2: CGPoint(x: midX, y: y1 + thickFrom))
                    ribbon.closeSubpath()

                    let baseColor = palette.seriesColor(at: nodeColorIdx[link.from] ?? 0)
                    let emphasized = hoveredId == nil || hoveredId == link.from || hoveredId == link.to
                    ctx.fill(ribbon, with: .color(baseColor.opacity(emphasized ? 0.34 : 0.1)))
                }

                for n in nodes {
                    guard let r = nodeRects[n.id] else { continue }
                    let c = palette.seriesColor(at: nodeColorIdx[n.id] ?? 0)
                    let emphasized = hoveredId == nil || hoveredId == n.id
                    ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(c.opacity(emphasized ? 1.0 : 0.35)))
                    let label = "\(n.label) (\(spec.formattedValue(nodeTotals[n.id] ?? 0)))"
                    let isRightEdge = (depth[n.id] ?? 0) == maxCol
                    let tx = isRightEdge ? r.minX - 6 : r.maxX + 6
                    ctx.draw(
                        Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(palette.ink),
                        at: CGPoint(x: tx, y: r.midY),
                        anchor: isRightEdge ? .trailing : .leading
                    )
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let pt):
                    hoveredSankeyNodeId = nodeRects.first(where: { $0.value.insetBy(dx: -8, dy: -4).contains(pt) })?.key
                case .ended:
                    hoveredSankeyNodeId = nil
                }
            }
        }
        .frame(height: height)
    }

    private var chartIcon: String {
        switch spec.type {
        case .bar, .stackedBar, .histogram, .waterfall: "chart.bar"
        case .line, .area, .stackedArea, .sparkline: "chart.xyaxis.line"
        case .scatter: "chart.dots.scatter"
        case .heatmap, .calendarHeatmap: "square.grid.3x3.fill"
        case .radar: "pentagon"
        case .sankey: "arrow.triangle.branch"
        }
    }

    private var defaultTitle: String {
        switch spec.type {
        case .bar: "Bar chart"
        case .stackedBar: "Stacked bar chart"
        case .line: "Line chart"
        case .area: "Area chart"
        case .stackedArea: "Stacked area chart"
        case .scatter: "Scatter plot"
        case .histogram: "Histogram"
        case .heatmap: "Heatmap"
        case .calendarHeatmap: "Calendar heatmap"
        case .radar: "Radar chart"
        case .sparkline: "Sparkline"
        case .waterfall: "Waterfall chart"
        case .sankey: "Flow diagram"
        }
    }

    private func csvText() -> String {
        let table = spec.tableRows()
        func escape(_ cell: String) -> String {
            if cell.contains(",") || cell.contains("\"") || cell.contains("\n") {
                return "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return cell
        }
        let headerLine = table.headers.map(escape).joined(separator: ",")
        let bodyLines = table.rows.map { $0.map(escape).joined(separator: ",") }
        return ([headerLine] + bodyLines).joined(separator: "\n")
    }
}

// MARK: - Reusable Inline Sparkline & KPI Stat Tiles Card (LAZYAGENTS-321)

struct ChatSparklinePathView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = max(hi - lo, 1e-9)
            let pad: CGFloat = 3
            let w = max(1, size.width - pad * 2)
            let h = max(1, size.height - pad * 2)

            var line = Path()
            var area = Path()
            for (idx, val) in values.enumerated() {
                let x = pad + CGFloat(idx) / CGFloat(values.count - 1) * w
                let y = pad + (1 - CGFloat((val - lo) / span)) * h
                if idx == 0 {
                    line.move(to: CGPoint(x: x, y: y))
                    area.move(to: CGPoint(x: x, y: size.height - pad))
                    area.addLine(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                    area.addLine(to: CGPoint(x: x, y: y))
                }
            }
            area.addLine(to: CGPoint(x: pad + w, y: size.height - pad))
            area.closeSubpath()

            ctx.fill(area, with: .color(color.opacity(0.16)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

struct ChatStatsCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatStatsSpec

    var body: some View {
        let p = theme.palette
        let viz = ChatVizPalette(theme: theme)
        let columns = [GridItem(.adaptive(minimum: 155, maximum: 260), spacing: 10)]

        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title, !title.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    if let subtitle = spec.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                    }
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(spec.items) { tile in
                    let toneCol = tile.tone != nil
                        ? ChatVizPalette.toneColor(tile.tone, theme: theme)
                        : viz.seriesColor(at: tile.id)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tile.label)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(tile.value)
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundStyle(p.text)
                                .lineLimit(1)
                            if let delta = tile.delta, !delta.isEmpty {
                                Text(delta)
                                    .font(.system(size: theme.pointSize(.micro), weight: .medium, design: .monospaced))
                                    .foregroundStyle(toneCol)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(toneCol.opacity(0.14), in: Capsule())
                            }
                        }
                        if tile.sparkline.count >= 2 {
                            ChatSparklinePathView(values: tile.sparkline, color: toneCol)
                                .frame(height: 28)
                        }
                        if let sub = tile.subtitle, !sub.isEmpty {
                            Text(sub)
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border))
                }
            }
        }
    }
}
