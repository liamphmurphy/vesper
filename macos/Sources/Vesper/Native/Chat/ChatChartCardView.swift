import Charts
import SwiftUI
import VesperCore

/// Native Swift Charts & Canvas renderer for `ChatChartSpec` (LAZYAGENTS-321):
/// `bar`, `stacked-bar`, `line`, `area`, `stacked-area`, `scatter`, `histogram`, `heatmap`,
/// `calendar-heatmap`, `radar`, and `sparkline`, using the shared `ChatVizPalette(theme:)`.
struct ChatChartCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatChartSpec

    @State private var mode: DisplayMode = .chart
    @State private var showLightbox = false

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
            switch spec.type {
            case .bar:
                axisDecorated(barChart, height: height)
            case .stackedBar:
                axisDecorated(stackedBarChart, height: height)
            case .line:
                axisDecorated(lineChart, height: height)
            case .area:
                axisDecorated(areaChart(stacked: false), height: height)
            case .stackedArea:
                axisDecorated(areaChart(stacked: true), height: height)
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
            }
        }
        .padding(14)
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
        HStack(spacing: 12) {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                HStack(spacing: 5) {
                    Circle()
                        .fill(viz.seriesColor(at: idx))
                        .frame(width: 8, height: 8)
                    Text(series.name.isEmpty ? "Series \(idx + 1)" : series.name)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
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
        for (sIdx, series) in spec.series.enumerated() {
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
        for (sIdx, series) in spec.series.enumerated() {
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
        for (sIdx, series) in spec.series.enumerated() {
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

    private var chartIcon: String {
        switch spec.type {
        case .bar, .stackedBar, .histogram: "chart.bar"
        case .line, .area, .stackedArea, .sparkline: "chart.xyaxis.line"
        case .scatter: "chart.dots.scatter"
        case .heatmap, .calendarHeatmap: "square.grid.3x3.fill"
        case .radar: "pentagon"
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
