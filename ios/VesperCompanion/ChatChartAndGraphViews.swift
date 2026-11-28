import Charts
import MapKit
import SwiftUI
import VesperCore

// MARK: - Chart Color Palette

enum ChatVizPalette {
    static let series: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .green, .indigo, .yellow
    ]

    static func color(at index: Int) -> Color {
        series[abs(index) % series.count]
    }

    static func toneColor(_ tone: String?) -> Color {
        switch tone?.lowercased() {
        case "positive", "success", "good", "green": .green
        case "negative", "danger", "error", "red": .red
        case "warning", "warn", "orange", "amber": .orange
        case "accent", "info", "blue": .accentColor
        default: .secondary
        }
    }
}

// MARK: - Chart Card (All 11 ChatChartType variants + Data Table toggle)

struct ChatChartCardView: View {
    let spec: ChatChartSpec

    @State private var showTable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = spec.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text(spec.type.rawValue.replacingOccurrences(of: "-", with: " ").capitalized)
                            .font(.subheadline.weight(.semibold))
                    }
                    if let subtitle = spec.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(showTable ? "Chart" : "Table") {
                    showTable.toggle()
                }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if showTable {
                chartTableView(spec.tableRows())
            } else {
                chartBody
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var chartBody: some View {
        switch spec.type {
        case .bar:
            categoricalChart(kind: .bar)
        case .stackedBar:
            categoricalChart(kind: .stackedBar)
        case .line:
            categoricalChart(kind: .line)
        case .area:
            categoricalChart(kind: .area)
        case .stackedArea:
            categoricalChart(kind: .stackedArea)
        case .scatter:
            scatterChart
        case .histogram:
            histogramChart
        case .heatmap:
            if let heatmap = spec.heatmap {
                heatmapView(heatmap)
            }
        case .calendarHeatmap:
            calendarHeatmapView(spec.calendarDays)
        case .radar:
            radarView
        case .sparkline:
            sparklineView
        case .waterfall:
            waterfallView
        case .sankey:
            sankeyView
        }
    }

    private enum CatKind { case bar, stackedBar, line, area, stackedArea }

    private struct CatPoint: Identifiable {
        let id: String
        let category: String
        let series: String
        let value: Double
    }

    @ViewBuilder
    private func categoricalChart(kind: CatKind) -> some View {
        let points: [CatPoint] = spec.series.enumerated().flatMap { sIdx, s in
            spec.categories.enumerated().compactMap { cIdx, cat -> CatPoint? in
                guard cIdx < s.values.count, let v = s.values[cIdx] else { return nil }
                return CatPoint(id: "\(sIdx)-\(cIdx)", category: cat, series: s.name, value: v)
            }
        }

        Chart(points) { pt in
            switch kind {
            case .bar:
                BarMark(x: .value(spec.x.label ?? "Category", pt.category),
                        y: .value(spec.y.label ?? "Value", pt.value))
                    .foregroundStyle(by: .value("Series", pt.series))
                    .position(by: .value("Series", pt.series))
            case .stackedBar:
                BarMark(x: .value(spec.x.label ?? "Category", pt.category),
                        y: .value(spec.y.label ?? "Value", pt.value))
                    .foregroundStyle(by: .value("Series", pt.series))
            case .line:
                LineMark(x: .value(spec.x.label ?? "Category", pt.category),
                         y: .value(spec.y.label ?? "Value", pt.value))
                    .foregroundStyle(by: .value("Series", pt.series))
                PointMark(x: .value(spec.x.label ?? "Category", pt.category),
                          y: .value(spec.y.label ?? "Value", pt.value))
                    .foregroundStyle(by: .value("Series", pt.series))
            case .area:
                AreaMark(x: .value(spec.x.label ?? "Category", pt.category),
                         y: .value(spec.y.label ?? "Value", pt.value),
                         stacking: .unstacked)
                    .foregroundStyle(by: .value("Series", pt.series))
                    .opacity(0.35)
                LineMark(x: .value(spec.x.label ?? "Category", pt.category),
                         y: .value(spec.y.label ?? "Value", pt.value))
                    .foregroundStyle(by: .value("Series", pt.series))
            case .stackedArea:
                AreaMark(x: .value(spec.x.label ?? "Category", pt.category),
                         y: .value(spec.y.label ?? "Value", pt.value),
                         stacking: .standard)
                    .foregroundStyle(by: .value("Series", pt.series))
            }
        }
        .chartLegend(spec.series.count > 1 ? .visible : .hidden)
        .frame(height: 210)
    }

    private struct ScatterItem: Identifiable {
        let id: String
        let series: String
        let x: Double
        let y: Double
    }

    private var scatterChart: some View {
        let pts: [ScatterItem] = spec.series.enumerated().flatMap { sIdx, s in
            s.points.enumerated().map { pIdx, p in
                ScatterItem(id: "\(sIdx)-\(pIdx)", series: s.name, x: p.x, y: p.y)
            }
        }
        return Chart(pts) { pt in
            PointMark(x: .value(spec.x.label ?? "X", pt.x),
                      y: .value(spec.y.label ?? "Y", pt.y))
                .foregroundStyle(by: .value("Series", pt.series))
        }
        .chartLegend(spec.series.count > 1 ? .visible : .hidden)
        .frame(height: 210)
    }

    private var histogramChart: some View {
        Chart(spec.histogramBins, id: \.label) { bin in
            BarMark(x: .value(spec.x.label ?? "Bin", bin.label),
                    y: .value(spec.y.label ?? "Count", bin.count))
                .foregroundStyle(Color.accentColor)
        }
        .frame(height: 200)
    }

    private func heatmapView(_ data: ChatHeatmapData) -> some View {
        let span = max(1e-9, data.maxValue - data.minValue)
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Text("").frame(width: 64)
                    ForEach(data.xLabels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 44)
                            .lineLimit(1)
                    }
                }
                ForEach(Array(data.yLabels.enumerated()), id: \.offset) { rIdx, yLabel in
                    HStack(spacing: 3) {
                        Text(yLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                            .lineLimit(1)
                        ForEach(0..<data.xLabels.count, id: \.self) { cIdx in
                            let val = rIdx < data.matrix.count && cIdx < data.matrix[rIdx].count ? data.matrix[rIdx][cIdx] : nil
                            let frac = val.map { max(0.08, min(1.0, ($0 - data.minValue) / span)) } ?? 0
                            RoundedRectangle(cornerRadius: 4)
                                .fill(val == nil ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(frac))
                                .frame(width: 44, height: 26)
                                .overlay {
                                    if let val {
                                        Text(ChatChartSpec.compactNumber(val))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(frac > 0.55 ? .white : .primary)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private func calendarHeatmapView(_ days: [ChatCalendarDay]) -> some View {
        let maxVal = max(1e-9, days.map(\.value).max() ?? 1)
        let columns = Array(repeating: GridItem(.fixed(14), spacing: 3), count: 7)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: columns, spacing: 3) {
                ForEach(days, id: \.date) { day in
                    let intensity = max(0.1, min(1.0, day.value / maxVal))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(day.value <= 0 ? Color.secondary.opacity(0.12) : Color.green.opacity(intensity))
                        .frame(width: 14, height: 14)
                }
            }
            .frame(height: 120)
        }
    }

    private var radarView: some View {
        let count = max(3, spec.categories.count)
        let maxVal = spec.radarMax ?? max(1, spec.series.flatMap { $0.values.compactMap { $0 } }.max() ?? 1)
        return VStack(spacing: 8) {
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.36
                for ring in 1...4 {
                    let r = radius * CGFloat(ring) / 4.0
                    var ringPath = Path()
                    for i in 0..<count {
                        let angle = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / CGFloat(count))
                        let pt = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
                        if i == 0 { ringPath.move(to: pt) } else { ringPath.addLine(to: pt) }
                    }
                    ringPath.closeSubpath()
                    ctx.stroke(ringPath, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                }
                for (sIdx, series) in spec.series.enumerated() {
                    let color = ChatVizPalette.color(at: sIdx)
                    var poly = Path()
                    for i in 0..<count {
                        let v = i < series.values.count ? (series.values[i] ?? 0) : 0
                        let frac = CGFloat(max(0, min(1, v / maxVal)))
                        let angle = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / CGFloat(count))
                        let pt = CGPoint(x: center.x + cos(angle) * radius * frac, y: center.y + sin(angle) * radius * frac)
                        if i == 0 { poly.move(to: pt) } else { poly.addLine(to: pt) }
                    }
                    poly.closeSubpath()
                    ctx.fill(poly, with: .color(color.opacity(0.22)))
                    ctx.stroke(poly, with: .color(color), lineWidth: 2)
                }
            }
            .frame(height: 200)

            HStack(spacing: 12) {
                ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, s in
                    HStack(spacing: 4) {
                        Circle().fill(ChatVizPalette.color(at: idx)).frame(width: 8, height: 8)
                        Text(s.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sparklineView: some View {
        HStack(spacing: 12) {
            Chart(Array(spec.sparklineValues.enumerated()), id: \.offset) { idx, val in
                LineMark(x: .value("i", idx), y: .value("v", val))
                    .foregroundStyle(ChatVizPalette.toneColor(spec.sparklineTone))
                AreaMark(x: .value("i", idx), y: .value("v", val))
                    .foregroundStyle(ChatVizPalette.toneColor(spec.sparklineTone).opacity(0.16))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 48)

            if let delta = spec.sparklineDelta {
                Text(delta)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ChatVizPalette.toneColor(spec.sparklineTone).opacity(0.16), in: Capsule())
                    .foregroundStyle(ChatVizPalette.toneColor(spec.sparklineTone))
            }
        }
    }

    private var waterfallView: some View {
        Chart(spec.waterfallItems) { item in
            let lo = min(item.startY, item.endY)
            let hi = max(item.startY, item.endY)
            let col: Color = switch item.kind {
            case .start, .total: .blue
            case .delta: item.value >= 0 ? .green : .red
            }
            BarMark(
                x: .value("Step", item.label),
                yStart: .value("Start", lo),
                yEnd: .value("End", hi)
            )
            .foregroundStyle(col)
            .cornerRadius(4)
        }
        .frame(height: 200)
    }

    private var sankeyView: some View {
        let data = spec.sankey ?? ChatSankeyData(nodes: [], links: [])
        let labels = Dictionary(uniqueKeysWithValues: data.nodes.map { ($0.id, $0.label) })
        let maxVal = max(data.links.map(\.value).max() ?? 1, 1e-6)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(data.links) { link in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(labels[link.from] ?? link.from) → \(labels[link.to] ?? link.to)")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(spec.formattedValue(link.value))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(6, geo.size.width * CGFloat(link.value / maxVal)), height: 6)
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    private func chartTableView(_ table: ChatChartTable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    ForEach(table.headers, id: \.self) { h in
                        Text(h)
                            .font(.caption.weight(.semibold))
                            .frame(minWidth: 68, alignment: .leading)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 68, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - KPI Stats Card

struct ChatMapCardView: View {
    let spec: ChatMapSpec

    var body: some View {
        let b = spec.bounds
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: b.centerLat, longitude: b.centerLon),
            span: MKCoordinateSpan(latitudeDelta: b.latDelta, longitudeDelta: b.lonDelta)
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(spec.title ?? "Map", systemImage: "map")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if spec.totalRouteKm > 0.05 {
                    Text(String(format: "%.1f km", spec.totalRouteKm))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Map(initialPosition: .region(region)) {
                ForEach(spec.pins) { pin in
                    Marker(pin.label, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon))
                }
                ForEach(spec.routes) { route in
                    let coords = route.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                    MapPolyline(coordinates: coords)
                        .stroke(.blue, lineWidth: 3)
                }
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChatStatsCardView: View {
    let spec: ChatStatsSpec

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(spec.items) { tile in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tile.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(tile.value)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let delta = tile.delta, !delta.isEmpty {
                            Text(delta)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ChatVizPalette.toneColor(tile.tone).opacity(0.16), in: Capsule())
                                .foregroundStyle(ChatVizPalette.toneColor(tile.tone))
                        }
                        if !tile.sparkline.isEmpty {
                            Chart(Array(tile.sparkline.enumerated()), id: \.offset) { i, v in
                                LineMark(x: .value("i", i), y: .value("v", v))
                                    .foregroundStyle(ChatVizPalette.toneColor(tile.tone))
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis(.hidden)
                            .frame(height: 24)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Relationship Graph Card

struct ChatGraphCardView: View {
    let spec: ChatGraphSpec

    @State private var selectedNodeId: String?

    var body: some View {
        let positions = computeCircularLayout(nodes: spec.nodes)
        let neighbors = selectedNodeId.map { spec.neighbors(of: $0) } ?? []

        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Canvas { ctx, size in
                let pad: CGFloat = 28
                let w = max(1, size.width - pad * 2)
                let h = max(1, size.height - pad * 2)

                for edge in spec.edges {
                    guard let p1 = positions[edge.from], let p2 = positions[edge.to] else { continue }
                    let a = CGPoint(x: pad + p1.x * w, y: pad + p1.y * h)
                    let b = CGPoint(x: pad + p2.x * w, y: pad + p2.y * h)
                    let highlighted = selectedNodeId == nil || edge.from == selectedNodeId || edge.to == selectedNodeId
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    ctx.stroke(path, with: .color(.secondary.opacity(highlighted ? 0.5 : 0.12)), lineWidth: highlighted ? 1.5 : 1)
                }

                for node in spec.nodes {
                    guard let p = positions[node.id] else { continue }
                    let pt = CGPoint(x: pad + p.x * w, y: pad + p.y * h)
                    let gIdx = node.group.flatMap { spec.groups.firstIndex(of: $0) } ?? 0
                    let color = ChatVizPalette.color(at: gIdx)
                    let r = CGFloat(max(7, min(14, 7 + node.size * 1.5)))
                    let dimmed = selectedNodeId != nil && node.id != selectedNodeId && !neighbors.contains(node.id)
                    let circle = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                    ctx.fill(circle, with: .color(color.opacity(dimmed ? 0.25 : 0.9)))
                    ctx.draw(
                        Text(node.label).font(.caption2).foregroundStyle(dimmed ? .tertiary : .primary),
                        at: CGPoint(x: pt.x, y: pt.y + r + 9)
                    )
                }
            }
            .frame(height: 240)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(spec.nodes) { node in
                        Button(node.label) {
                            selectedNodeId = selectedNodeId == node.id ? nil : node.id
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .tint(selectedNodeId == node.id ? .accentColor : .secondary)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func computeCircularLayout(nodes: [ChatGraphNode]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        var out: [String: CGPoint] = [:]
        for (i, n) in nodes.enumerated() {
            let angle = -Double.pi / 2 + Double(i) * (2 * Double.pi / Double(nodes.count))
            out[n.id] = CGPoint(x: 0.5 + 0.42 * cos(angle), y: 0.5 + 0.42 * sin(angle))
        }
        return out
    }
}

// MARK: - Math Function Plot Card (with Interactive Sliders)

struct ChatPlotCardView: View {
    let spec: ChatPlotSpec

    @State private var paramValues: [String: Double] = [:]

    private struct PlotSample: Identifiable {
        let id: String
        let label: String
        let x: Double
        let y: Double
    }

    var body: some View {
        let samples = samplePoints()
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            Chart(samples) { pt in
                LineMark(x: .value("x", pt.x), y: .value("y", pt.y))
                    .foregroundStyle(by: .value("Function", pt.label))
            }
            .chartXScale(domain: spec.xMin...spec.xMax)
            .frame(height: 210)

            if !spec.parameters.isEmpty {
                VStack(spacing: 6) {
                    ForEach(spec.parameters) { param in
                        let val = Binding<Double>(
                            get: { paramValues[param.name] ?? param.value },
                            set: { paramValues[param.name] = $0 }
                        )
                        HStack(spacing: 8) {
                            Text("\(param.name) = \(String(format: "%.2f", val.wrappedValue))")
                                .font(.caption.monospacedDigit())
                                .frame(width: 82, alignment: .leading)
                            Slider(value: val, in: param.min...param.max, step: max(0.001, param.step))
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func samplePoints() -> [PlotSample] {
        let steps = 100
        let dx = (spec.xMax - spec.xMin) / Double(steps)
        var vars: [String: Double] = [:]
        for p in spec.parameters {
            vars[p.name] = paramValues[p.name] ?? p.value
        }
        var out: [PlotSample] = []
        for fn in spec.functions {
            guard let ast = fn.ast else { continue }
            for i in 0...steps {
                let x = spec.xMin + Double(i) * dx
                vars["x"] = x
                let y = ast.evaluate(variables: vars)
                if y.isFinite && abs(y) < 1e6 {
                    out.append(PlotSample(id: "\(fn.id)-\(i)", label: fn.label, x: x, y: y))
                }
            }
        }
        return out
    }
}

// MARK: - Timeline / Waterfall Card

struct ChatTimelineCardView: View {
    let spec: ChatTimelineSpec

    var body: some View {
        let span = max(1e-9, spec.maxValue - spec.minValue)
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(Array(spec.lanes.enumerated()), id: \.offset) { laneIdx, lane in
                let laneItems = spec.items.filter { $0.lane == lane }
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(laneItems) { item in
                        let startFrac = max(0, min(1, (item.start - spec.minValue) / span))
                        let endVal = item.end ?? item.start
                        let widthFrac = max(0.04, min(1 - startFrac, (endVal - item.start) / span))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.label)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Spacer()
                                if let ann = item.annotation, !ann.isEmpty {
                                    Text(ann)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.12))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(item.tone.map { ChatVizPalette.toneColor($0) } ?? ChatVizPalette.color(at: laneIdx))
                                        .frame(width: max(8, geo.size.width * widthFrac))
                                        .offset(x: geo.size.width * startFrac)
                                }
                            }
                            .frame(height: 10)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Before / After Image Comparison Slider

struct ChatCompareImagesCardView: View {
    let spec: ChatCompareImagesSpec
    let client: APIClient?

    @State private var split: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text(spec.beforeLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(spec.afterLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    AuthenticatedRemoteImage(
                        client: client,
                        path: spec.after.primaryPath,
                        fallbackPath: spec.after.fallbackPath,
                        contentMode: .fit,
                        maxHeight: 240,
                        allowFullscreen: false
                    )
                    AuthenticatedRemoteImage(
                        client: client,
                        path: spec.before.primaryPath,
                        fallbackPath: spec.before.fallbackPath,
                        contentMode: .fit,
                        maxHeight: 240,
                        allowFullscreen: false
                    )
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().frame(width: geo.size.width * split)
                            Spacer(minLength: 0)
                        }
                    )
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2)
                        .offset(x: geo.size.width * split)
                        .shadow(radius: 2)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Slider(value: $split, in: 0.05...0.95)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
