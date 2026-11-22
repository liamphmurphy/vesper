import Charts
import SwiftUI
import VesperCore

/// Reusable inline banner matching web `<Banner>` tones (`blocked`, `human`, `neutral`).
struct LearnBanner: View {
    @Environment(\.vesperTheme) private var theme

    var tone: String = "neutral"
    let title: String
    var bodyText: String? = nil
    var bullets: [String] = []
    var retry: (() -> Void)? = nil

    var body: some View {
        let p = theme.palette
        let (fg, bg, border): (Color, Color, Color) = switch tone {
        case "blocked":
            (
                theme.swiftUIColor("pill-blocked-fg", fallback: .red),
                theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)),
                theme.swiftUIColor("pill-blocked-fg", fallback: .red).opacity(0.35)
            )
        case "human":
            (
                theme.swiftUIColor("pill-human-fg", fallback: .orange),
                theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.1)),
                theme.swiftUIColor("state-human", fallback: .orange).opacity(0.4)
            )
        default:
            (
                p.text,
                theme.swiftUIColor("surface-sunken", fallback: p.surface),
                p.border
            )
        }

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(fg)
                if let bodyText, !bodyText.isEmpty {
                    Text(bodyText)
                        .vesperText(.body, theme)
                        .foregroundStyle(p.secondaryText)
                }
                if !bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(p.tertiaryText)
                                Text(bullet).vesperText(.small, theme).foregroundStyle(p.secondaryText)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.vesper())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(border))
    }
}

/// Thin horizontal progress track matching the web course cards and study header.
struct LearnProgressBar: View {
    @Environment(\.vesperTheme) private var theme
    let value: Int
    let total: Int

    var body: some View {
        let fraction = total > 0 ? min(max(Double(value) / Double(total), 0), 1) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.swiftUIColor("track", fallback: theme.palette.hover))
                Capsule()
                    .fill(theme.swiftUIColor("text-2", fallback: theme.palette.secondaryText))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityValue("\(value) of \(total)")
    }
}

/// Status pill using `LearnLogic.stateLabel` and `LearnLogic.statePillTone`.
struct LearnStatePill: View {
    let state: API.CourseState

    var body: some View {
        TonePill(label: LearnLogic.stateLabel(state), tone: LearnLogic.statePillTone(state))
    }
}

/// Native Swift Charts view (with Chart / Data toggle) for lesson `chart` blocks and tutor ```` ```chart ```` fences.
struct LessonChartView: View {
    @Environment(\.vesperTheme) private var theme

    let json: String
    var alt: String? = nil
    var captionMarkdown: String? = nil
    var showCodeOnError: Bool = false
    var onLink: ((MarkdownLinkTarget) -> Bool)? = nil

    @State private var mode: ViewMode = .chart

    private enum ViewMode: String, CaseIterable {
        case chart = "Chart"
        case data = "Data"
    }

    private struct BarDatum: Identifiable, Sendable {
        let id: String
        let category: String
        let series: String
        let value: Double
    }

    private struct LineDatum: Identifiable, Sendable {
        let id: String
        let category: String
        let series: String
        let segment: String
        let value: Double
    }

    private struct ScatterDatum: Identifiable, Sendable {
        let id: String
        let series: String
        let x: Double
        let y: Double
    }

    private static let fallbackColors: [Color] = [
        .blue, .orange, .green, .yellow, .pink, .teal, .purple, .red,
    ]

    var body: some View {
        switch LearnLogic.parseChart(json) {
        case .error(let reason):
            errorView(reason: reason)
        case .spec(let spec):
            chartCard(spec: spec)
        }
    }

    @ViewBuilder
    private func errorView(reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("This chart couldn\u{2019}t be drawn.")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                Text(alt.flatMap { $0.isEmpty ? nil : "\(reason) \($0)" } ?? reason)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }
            if showCodeOnError {
                MarkdownView(
                    markdown: LearnLogic.codeFenceMarkdown(code: json, lang: "json"),
                    textStyle: .small,
                    textColor: "text-2",
                    chat: true,
                    onLink: onLink
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }

    private func chartCard(spec: LearnLogic.ChartSpec) -> some View {
        let p = theme.palette
        let normalizedNames = uniqueSeriesNames(for: spec)
        let categories = uniqueCategoryLabels(for: spec)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label("Chart", systemImage: "chart.bar.xaxis")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(ViewMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))

            Divider().overlay(p.border)

            if mode == .chart {
                VStack(alignment: .leading, spacing: 8) {
                    if spec.title != nil || spec.subtitle != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            if let title = spec.title {
                                Text(title)
                                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                                    .foregroundStyle(p.text)
                            }
                            if let subtitle = spec.subtitle {
                                Text(subtitle)
                                    .vesperText(.small, theme)
                                    .foregroundStyle(p.secondaryText)
                            }
                        }
                    }

                    if let yLabel = spec.yLabel {
                        Text(yLabel)
                            .font(.system(size: theme.pointSize(.micro) + 1))
                            .foregroundStyle(p.tertiaryText)
                    }

                    chartPlot(spec: spec, categories: categories, seriesNames: normalizedNames)
                        .frame(height: 240)

                    if let xLabel = spec.xLabel {
                        Text(xLabel)
                            .font(.system(size: theme.pointSize(.micro) + 1))
                            .foregroundStyle(p.tertiaryText)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(12)
            } else {
                chartDataTable(spec: spec, seriesNames: normalizedNames)
            }

            if let captionMarkdown, !captionMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().overlay(p.border)
                MarkdownView(
                    markdown: captionMarkdown,
                    textStyle: .small,
                    textColor: "text-secondary",
                    onLink: onLink
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(alt ?? spec.title ?? "Chart")
    }

    @ViewBuilder
    private func chartPlot(spec: LearnLogic.ChartSpec, categories: [String], seriesNames: [String]) -> some View {
        let range = seriesNames.indices.map { seriesColor($0) }

        Group {
            switch spec.type {
            case .bar:
                let rows = barRows(spec: spec, categories: categories, seriesNames: seriesNames)
                Chart(rows) { row in
                    if spec.series.count > 1 {
                        BarMark(
                            x: .value(spec.xLabel ?? "Category", row.category),
                            y: .value(spec.yLabel ?? "Value", row.value)
                        )
                        .foregroundStyle(by: .value("Series", row.series))
                        .position(by: .value("Series", row.series))
                    } else {
                        BarMark(
                            x: .value(spec.xLabel ?? "Category", row.category),
                            y: .value(spec.yLabel ?? "Value", row.value)
                        )
                        .foregroundStyle(by: .value("Series", row.series))
                    }
                }
                .chartXScale(domain: categories)
                .chartXAxis {
                    if categories.count > 10 {
                        AxisMarks(values: .automatic(desiredCount: 8))
                    } else {
                        AxisMarks()
                    }
                }

            case .line:
                let rows = lineRows(spec: spec, categories: categories, seriesNames: seriesNames)
                Chart(rows) { row in
                    LineMark(
                        x: .value(spec.xLabel ?? "Category", row.category),
                        y: .value(spec.yLabel ?? "Value", row.value),
                        series: .value("Segment", row.segment)
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Series", row.series))

                    PointMark(
                        x: .value(spec.xLabel ?? "Category", row.category),
                        y: .value(spec.yLabel ?? "Value", row.value)
                    )
                    .foregroundStyle(by: .value("Series", row.series))
                }
                .chartXScale(domain: categories)
                .chartXAxis {
                    if categories.count > 10 {
                        AxisMarks(values: .automatic(desiredCount: 8))
                    } else {
                        AxisMarks()
                    }
                }

            case .scatter:
                let rows = scatterRows(spec: spec, seriesNames: seriesNames)
                Chart(rows) { row in
                    PointMark(
                        x: .value(spec.xLabel ?? "x", row.x),
                        y: .value(spec.yLabel ?? "y", row.y)
                    )
                    .foregroundStyle(by: .value("Series", row.series))
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(LearnLogic.compactNumber(number))
                            }
                        }
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: seriesNames, range: range)
        .chartLegend(spec.series.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(LearnLogic.withUnit(LearnLogic.compactNumber(number), unit: spec.yUnit))
                    }
                }
            }
        }
    }

    private func chartDataTable(spec: LearnLogic.ChartSpec, seriesNames: [String]) -> some View {
        let p = theme.palette
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                if spec.type == .scatter {
                    GridRow {
                        Text("Series").fontWeight(.medium)
                        Text(spec.xLabel ?? "x").fontWeight(.medium).gridColumnAlignment(.trailing)
                        Text(spec.yLabel ?? "y").fontWeight(.medium).gridColumnAlignment(.trailing)
                    }
                    .foregroundStyle(p.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    Divider().overlay(p.border)

                    ForEach(Array(spec.series.enumerated()), id: \.offset) { sIndex, s in
                        let name = seriesNames[sIndex]
                        ForEach(Array(s.points.enumerated()), id: \.offset) { _, pt in
                            GridRow {
                                Text(name)
                                Text(LearnLogic.formatChartValue(pt.x, unit: nil))
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                Text(LearnLogic.formatChartValue(pt.y, unit: spec.yUnit))
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider().overlay(p.rowBorder)
                        }
                    }
                } else {
                    GridRow {
                        Text(spec.xLabel ?? "").fontWeight(.medium)
                        ForEach(Array(seriesNames.enumerated()), id: \.offset) { _, name in
                            Text(name).fontWeight(.medium).gridColumnAlignment(.trailing)
                        }
                    }
                    .foregroundStyle(p.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    Divider().overlay(p.border)

                    ForEach(Array(spec.categories.enumerated()), id: \.offset) { cIndex, category in
                        GridRow {
                            Text(category)
                            ForEach(Array(spec.series.enumerated()), id: \.offset) { _, s in
                                let val = cIndex < s.values.count ? s.values[cIndex] : nil
                                Text(val.map { LearnLogic.formatChartValue($0, unit: spec.yUnit) } ?? "–")
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        if cIndex < spec.categories.count - 1 {
                            Divider().overlay(p.rowBorder)
                        }
                    }
                }
            }
            .vesperText(.small, theme)
            .foregroundStyle(theme.swiftUIColor("text-2", fallback: p.text))
            .frame(minWidth: 360, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func seriesColor(_ index: Int) -> Color {
        let fallback = Self.fallbackColors[index % Self.fallbackColors.count]
        return theme.swiftUIColor("viz-\((index % 8) + 1)", fallback: fallback)
    }

    private func uniqueSeriesNames(for spec: LearnLogic.ChartSpec) -> [String] {
        var counts: [String: Int] = [:]
        return spec.series.enumerated().map { idx, s in
            let base = s.name.isEmpty ? (spec.yLabel ?? "Series \(idx + 1)") : s.name
            let n = (counts[base] ?? 0) + 1
            counts[base] = n
            return n == 1 ? base : "\(base) (\(n))"
        }
    }

    private func uniqueCategoryLabels(for spec: LearnLogic.ChartSpec) -> [String] {
        if Set(spec.categories).count == spec.categories.count {
            return spec.categories
        }
        var counts: [String: Int] = [:]
        return spec.categories.map { cat in
            let n = (counts[cat] ?? 0) + 1
            counts[cat] = n
            return n == 1 ? cat : "\(cat) (\(n))"
        }
    }

    private func barRows(spec: LearnLogic.ChartSpec, categories: [String], seriesNames: [String]) -> [BarDatum] {
        var out: [BarDatum] = []
        for (sIdx, s) in spec.series.enumerated() {
            let sName = seriesNames[sIdx]
            for (cIdx, cat) in categories.enumerated() where cIdx < s.values.count {
                if let v = s.values[cIdx] {
                    out.append(BarDatum(id: "\(sIdx)-\(cIdx)", category: cat, series: sName, value: v))
                }
            }
        }
        return out
    }

    private func lineRows(spec: LearnLogic.ChartSpec, categories: [String], seriesNames: [String]) -> [LineDatum] {
        var out: [LineDatum] = []
        for (sIdx, s) in spec.series.enumerated() {
            let sName = seriesNames[sIdx]
            var segmentIndex = 0
            var hadValueInSegment = false
            for (cIdx, cat) in categories.enumerated() where cIdx < s.values.count {
                if let v = s.values[cIdx] {
                    hadValueInSegment = true
                    out.append(LineDatum(
                        id: "\(sIdx)-\(cIdx)",
                        category: cat,
                        series: sName,
                        segment: "\(sIdx)-\(segmentIndex)",
                        value: v
                    ))
                } else if hadValueInSegment {
                    segmentIndex += 1
                    hadValueInSegment = false
                }
            }
        }
        return out
    }

    private func scatterRows(spec: LearnLogic.ChartSpec, seriesNames: [String]) -> [ScatterDatum] {
        var out: [ScatterDatum] = []
        for (sIdx, s) in spec.series.enumerated() {
            let sName = seriesNames[sIdx]
            for (pIdx, pt) in s.points.enumerated() {
                out.append(ScatterDatum(id: "\(sIdx)-\(pIdx)", series: sName, x: pt.x, y: pt.y))
            }
        }
        return out
    }
}

/// Pure SwiftUI view for lesson `diagram` blocks: overview + interactive step-through captions + SVG source toggle.
struct LessonDiagramView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let svgSource: String
    var alt: String? = nil
    var steps: [String]? = nil
    var captionMarkdown: String? = nil
    var onLink: ((MarkdownLinkTarget) -> Bool)? = nil

    @State private var mode: DiagramMode = .overview
    @State private var stepIndex = 0

    private enum DiagramMode: String, CaseIterable {
        case overview = "Overview"
        case source = "SVG source"
    }

    var body: some View {
        let p = theme.palette
        let stepList = (steps ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let label = stepList.isEmpty ? "Diagram" : "Step-through"
        let title = LearnLogic.svgTitle(svgSource) ?? alt ?? label

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(label, systemImage: "square.on.square.dashed")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                Spacer()
                Button("Copy SVG") {
                    context.copyToClipboard(svgSource)
                    context.showToast(ToastItemModel(id: "learn.svg.copy", title: "SVG copied", tone: .success))
                }
                .buttonStyle(.plain)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)

                Picker("Diagram view", selection: $mode) {
                    ForEach(DiagramMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))

            Divider().overlay(p.border)

            if mode == .overview {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    if let alt, !alt.isEmpty, alt != title {
                        Text(alt)
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                    if !stepList.isEmpty {
                        let safeIndex = min(max(stepIndex, 0), stepList.count - 1)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button("←") { stepIndex = max(0, safeIndex - 1) }
                                    .buttonStyle(.vesper())
                                    .disabled(safeIndex == 0)
                                    .accessibilityLabel("Previous step")
                                Text("Step \(safeIndex + 1) of \(stepList.count)")
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                    .foregroundStyle(p.tertiaryText)
                                Button("→") { stepIndex = min(stepList.count - 1, safeIndex + 1) }
                                    .buttonStyle(.vesper())
                                    .disabled(safeIndex >= stepList.count - 1)
                                    .accessibilityLabel("Next step")
                                Spacer()
                            }
                            Text(stepList[safeIndex])
                                .vesperText(.body, theme)
                                .foregroundStyle(p.text)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(p.selected, in: RoundedRectangle(cornerRadius: 6))

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(stepList.enumerated()), id: \.offset) { idx, step in
                                    Button {
                                        stepIndex = idx
                                    } label: {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("\(idx + 1).")
                                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                                .foregroundStyle(idx == safeIndex ? p.accent : p.tertiaryText)
                                            Text(step)
                                                .vesperText(.small, theme)
                                                .foregroundStyle(idx == safeIndex ? p.text : p.secondaryText)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        Text("SVG diagram source is available in the SVG source tab.")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.tertiaryText)
                    }
                }
                .padding(12)
            } else {
                MarkdownView(
                    markdown: LearnLogic.codeFenceMarkdown(code: svgSource, lang: "html"),
                    textStyle: .small,
                    textColor: "text-2",
                    chat: true,
                    onLink: onLink
                )
                .padding(8)
            }

            if let captionMarkdown, !captionMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().overlay(p.border)
                MarkdownView(
                    markdown: captionMarkdown,
                    textStyle: .small,
                    textColor: "text-secondary",
                    onLink: onLink
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
    }
}
