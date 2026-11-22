import Charts
import SwiftUI
import VesperCore

/// Native Swift Charts renderer for `ChatChartSpec` (`bar`, `line`, `scatter`) with a Chart / Data table toggle.
struct ChatChartCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatChartSpec

    @State private var mode: DisplayMode = .chart

    private enum DisplayMode: String, CaseIterable {
        case chart = "Chart"
        case data = "Data"
    }

    private static let seriesPalette: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown,
    ]

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(p.rowBorder).frame(height: 1)
            if mode == .chart {
                chartBody
            } else {
                tableBody
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var chartBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if spec.series.count > 1 {
                legendRow
            }
            Group {
                switch spec.type {
                case .bar: barChart
                case .line: lineChart
                case .scatter: scatterChart
                }
            }
            .frame(height: 240)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(spec.formattedValue(v))
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
        .padding(14)
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { idx, series in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(for: idx))
                        .frame(width: 8, height: 8)
                    Text(series.name.isEmpty ? "Series \(idx + 1)" : series.name)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
        }
    }

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
                .foregroundStyle(color(for: item.seriesIndex))
                .position(by: .value("Series", item.seriesName))
                .cornerRadius(3)
            } else {
                BarMark(
                    x: .value(spec.x.label ?? "Category", item.category),
                    y: .value(spec.y.label ?? "Value", item.value)
                )
                .foregroundStyle(color(for: 0))
                .cornerRadius(3)
            }
        }
    }

    private struct LineDatum: Identifiable {
        let id: String
        let runKey: String
        let category: String
        let seriesIndex: Int
        let value: Double
    }

    /// Splits each series around `nil` values into separate `runKey`s so Swift Charts leaves visible gaps.
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
            .foregroundStyle(color(for: item.seriesIndex))
            .lineStyle(StrokeStyle(lineWidth: 2))

            PointMark(
                x: .value(spec.x.label ?? "Category", item.category),
                y: .value(spec.y.label ?? "Value", item.value)
            )
            .foregroundStyle(color(for: item.seriesIndex))
            .symbolSize(24)
        }
    }

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
            .foregroundStyle(color(for: item.seriesIndex))
            .symbolSize(36)
        }
    }

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

    private func color(for index: Int) -> Color {
        Self.seriesPalette[index % Self.seriesPalette.count]
    }

    private var chartIcon: String {
        switch spec.type {
        case .bar: "chart.bar"
        case .line: "chart.xyaxis.line"
        case .scatter: "chart.dots.scatter"
        }
    }

    private var defaultTitle: String {
        switch spec.type {
        case .bar: "Bar chart"
        case .line: "Line chart"
        case .scatter: "Scatter plot"
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
