import Foundation

/// Error returned when a ```chart or ```stats fence cannot be parsed or fails validation.
public struct ChatChartError: Error, Sendable, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum ChatChartType: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case bar
    case stackedBar = "stacked-bar"
    case line
    case area
    case stackedArea = "stacked-area"
    case scatter
    case histogram
    case heatmap
    case calendarHeatmap = "calendar-heatmap"
    case radar
    case sparkline
}

public struct ChatChartPoint: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ChatChartSeries: Sendable, Equatable, Hashable {
    public var name: String
    /// One value per category for bar/stacked-bar/line/area/stacked-area/radar; `nil` marks a gap.
    public var values: [Double?]
    /// `(x, y)` pairs for scatter charts.
    public var points: [ChatChartPoint]

    public init(name: String, values: [Double?] = [], points: [ChatChartPoint] = []) {
        self.name = name
        self.values = values
        self.points = points
    }
}

public struct ChatChartAxis: Sendable, Equatable, Hashable {
    public var label: String?
    public var unit: String?

    public init(label: String? = nil, unit: String? = nil) {
        self.label = label
        self.unit = unit
    }
}

public struct ChatHistogramBin: Sendable, Equatable, Hashable {
    public var lower: Double
    public var upper: Double
    public var count: Int
    public var label: String

    public init(lower: Double, upper: Double, count: Int, label: String) {
        self.lower = lower
        self.upper = upper
        self.count = count
        self.label = label
    }
}

public struct ChatHeatmapData: Sendable, Equatable, Hashable {
    public var xLabels: [String]
    public var yLabels: [String]
    /// Row-major (`yLabels.count` rows × `xLabels.count` cols).
    public var matrix: [[Double?]]
    public var minValue: Double
    public var maxValue: Double

    public init(xLabels: [String], yLabels: [String], matrix: [[Double?]], minValue: Double, maxValue: Double) {
        self.xLabels = xLabels
        self.yLabels = yLabels
        self.matrix = matrix
        self.minValue = minValue
        self.maxValue = maxValue
    }
}

public struct ChatCalendarDay: Sendable, Equatable, Hashable {
    public var date: String
    public var value: Double

    public init(date: String, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Tabular view of a chart's underlying data (for the Show Table toggle).
public struct ChatChartTable: Sendable, Equatable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }
}

/// Pure Swift parser/validator/formatter for ```chart JSON specs (LAZYAGENTS-321).
public struct ChatChartSpec: Sendable, Equatable, Hashable {
    public enum Limits {
        public static let series = 8
        public static let scatterSeries = 3
        public static let categories = 60
        public static let points = 500
        public static let histogramValues = 2000
        public static let heatmapAxis = 32
        public static let calendarDays = 400
    }

    public var type: ChatChartType
    public var title: String?
    public var subtitle: String?
    public var x: ChatChartAxis
    public var y: ChatChartAxis
    public var categories: [String]
    public var series: [ChatChartSeries]
    public var histogramBins: [ChatHistogramBin]
    public var heatmap: ChatHeatmapData?
    public var calendarDays: [ChatCalendarDay]
    public var radarMax: Double?
    public var sparklineValues: [Double]
    public var sparklineDelta: String?
    public var sparklineTone: String?

    public init(
        type: ChatChartType,
        title: String? = nil,
        subtitle: String? = nil,
        x: ChatChartAxis = ChatChartAxis(),
        y: ChatChartAxis = ChatChartAxis(),
        categories: [String] = [],
        series: [ChatChartSeries] = [],
        histogramBins: [ChatHistogramBin] = [],
        heatmap: ChatHeatmapData? = nil,
        calendarDays: [ChatCalendarDay] = [],
        radarMax: Double? = nil,
        sparklineValues: [Double] = [],
        sparklineDelta: String? = nil,
        sparklineTone: String? = nil
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.x = x
        self.y = y
        self.categories = categories
        self.series = series
        self.histogramBins = histogramBins
        self.heatmap = heatmap
        self.calendarDays = calendarDays
        self.radarMax = radarMax
        self.sparklineValues = sparklineValues
        self.sparklineDelta = sparklineDelta
        self.sparklineTone = sparklineTone
    }

    /// True when a code fence's info string starts with `chart` (case-insensitive).
    public static func isChartFence(_ info: String?) -> Bool {
        let first = (info ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
        return first?.lowercased() == "chart"
    }

    /// Parses and validates a ```chart JSON payload.
    public static func parse(_ code: String) -> Result<ChatChartSpec, ChatChartError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .failure(ChatChartError("This chart isn't valid JSON."))
        }

        let obj = asObject(root)
        let rawType = (obj["type"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard let type = ChatChartType(rawValue: rawType) else {
            return .failure(ChatChartError("Unsupported chart type. Expected bar, stacked-bar, line, area, stacked-area, scatter, histogram, heatmap, calendar-heatmap, radar or sparkline."))
        }

        let title = trimmedText(obj["title"])
        let subtitle = trimmedText(obj["subtitle"])
        let xObj = asObject(obj["x"])
        let yObj = asObject(obj["y"])
        let xAxis = ChatChartAxis(label: trimmedText(xObj["label"]), unit: trimmedText(xObj["unit"]))
        let yAxis = ChatChartAxis(label: trimmedText(yObj["label"]), unit: trimmedText(yObj["unit"]))

        switch type {
        case .histogram:
            return parseHistogram(obj: obj, title: title, subtitle: subtitle, xAxis: xAxis, yAxis: yAxis)
        case .heatmap:
            return parseHeatmap(obj: obj, title: title, subtitle: subtitle, xAxis: xAxis, yAxis: yAxis)
        case .calendarHeatmap:
            return parseCalendarHeatmap(obj: obj, title: title, subtitle: subtitle, xAxis: xAxis, yAxis: yAxis)
        case .sparkline:
            return parseSparkline(obj: obj, title: title, subtitle: subtitle, xAxis: xAxis, yAxis: yAxis)
        case .bar, .stackedBar, .line, .area, .stackedArea, .scatter, .radar:
            return parseSeriesChart(type: type, obj: obj, title: title, subtitle: subtitle, xAxis: xAxis, yAxis: yAxis)
        }
    }

    // MARK: - Type-Specific Parsers

    private static func parseSeriesChart(
        type: ChatChartType,
        obj: [String: JSONValue],
        title: String?,
        subtitle: String?,
        xAxis: ChatChartAxis,
        yAxis: ChatChartAxis
    ) -> Result<ChatChartSpec, ChatChartError> {
        let rawSeries: [[String: JSONValue]]
        if case .array(let arr) = obj["series"] {
            rawSeries = arr.map(asObject)
        } else {
            rawSeries = []
        }

        let maxSeries = type == .scatter ? Limits.scatterSeries : Limits.series
        if rawSeries.isEmpty || rawSeries.count > maxSeries {
            return .failure(ChatChartError("A \(type.rawValue) chart needs 1 to \(maxSeries) series."))
        }

        let categories: [String]
        if case .array(let arr) = obj["categories"] {
            categories = arr.map(stringifyJSON)
        } else {
            categories = []
        }

        if type == .radar && (categories.count < 3 || categories.count > 12) {
            return .failure(ChatChartError("A radar chart needs 3 to 12 categories."))
        } else if type != .scatter && (categories.isEmpty || categories.count > Limits.categories) {
            return .failure(ChatChartError("A \(type.rawValue) chart needs 1 to \(Limits.categories) categories."))
        }

        var parsedSeries: [ChatChartSeries] = []
        parsedSeries.reserveCapacity(rawSeries.count)

        for entry in rawSeries {
            let name = trimmedText(entry["name"]) ?? ""
            if name.isEmpty && rawSeries.count > 1 {
                return .failure(ChatChartError("Each series needs a name."))
            }

            if type == .scatter {
                var points: [ChatChartPoint] = []
                if case .array(let rawPoints) = entry["points"] {
                    for p in rawPoints {
                        if case .array(let pair) = p, pair.count == 2,
                           let px = finiteDouble(pair[0]),
                           let py = finiteDouble(pair[1]) {
                            points.append(ChatChartPoint(x: px, y: py))
                        }
                    }
                }
                if points.isEmpty || points.count > Limits.points {
                    return .failure(ChatChartError("Each series needs 1 to \(Limits.points) points."))
                }
                parsedSeries.append(ChatChartSeries(name: name, values: [], points: points))
            } else {
                let rawValues: [JSONValue]
                if case .array(let arr) = entry["values"] {
                    rawValues = arr
                } else {
                    rawValues = []
                }
                let values = rawValues.map(finiteDouble)
                if values.count != categories.count || values.allSatisfy({ $0 == nil }) {
                    return .failure(ChatChartError("Series \"\(name)\" needs one value per category."))
                }
                parsedSeries.append(ChatChartSeries(name: name, values: values, points: []))
            }
        }

        let radarMax = obj["max"].flatMap(finiteDouble)
        return .success(ChatChartSpec(
            type: type,
            title: title,
            subtitle: subtitle,
            x: xAxis,
            y: yAxis,
            categories: categories,
            series: parsedSeries,
            radarMax: radarMax
        ))
    }

    private static func parseHistogram(
        obj: [String: JSONValue],
        title: String?,
        subtitle: String?,
        xAxis: ChatChartAxis,
        yAxis: ChatChartAxis
    ) -> Result<ChatChartSpec, ChatChartError> {
        var rawVals: [Double] = []
        if case .array(let arr) = obj["values"] {
            rawVals = arr.compactMap(finiteDouble)
        } else if case .array(let seriesArr) = obj["series"],
                  let first = seriesArr.first.map(asObject),
                  case .array(let arr) = first["values"] {
            rawVals = arr.compactMap(finiteDouble)
        }
        guard !rawVals.isEmpty, rawVals.count <= Limits.histogramValues else {
            return .failure(ChatChartError("A histogram needs 1 to \(Limits.histogramValues) numeric values."))
        }
        let requestedBins: Int
        if let b = obj["bins"].flatMap(finiteDouble) {
            requestedBins = max(2, min(30, Int(b.rounded())))
        } else {
            requestedBins = max(3, min(16, Int(ceil(sqrt(Double(rawVals.count))))))
        }
        let lo = rawVals.min() ?? 0
        let hi = rawVals.max() ?? 0
        let bins = computeHistogramBins(values: rawVals, binCount: requestedBins, minVal: lo, maxVal: hi)
        return .success(ChatChartSpec(
            type: .histogram,
            title: title,
            subtitle: subtitle,
            x: xAxis,
            y: yAxis,
            histogramBins: bins
        ))
    }

    public static func computeHistogramBins(values: [Double], binCount: Int, minVal: Double, maxVal: Double) -> [ChatHistogramBin] {
        guard !values.isEmpty else { return [] }
        if minVal == maxVal {
            let label = compactNumber(minVal)
            return [ChatHistogramBin(lower: minVal, upper: maxVal, count: values.count, label: label)]
        }
        let count = max(2, binCount)
        let width = (maxVal - minVal) / Double(count)
        var counts = Array(repeating: 0, count: count)
        for v in values {
            var idx = Int(floor((v - minVal) / width))
            if idx >= count { idx = count - 1 }
            if idx < 0 { idx = 0 }
            counts[idx] += 1
        }
        return (0..<count).map { i in
            let lo = minVal + Double(i) * width
            let hi = minVal + Double(i + 1) * width
            return ChatHistogramBin(
                lower: lo,
                upper: hi,
                count: counts[i],
                label: "\(compactNumber(lo))–\(compactNumber(hi))"
            )
        }
    }

    private static func parseHeatmap(
        obj: [String: JSONValue],
        title: String?,
        subtitle: String?,
        xAxis: ChatChartAxis,
        yAxis: ChatChartAxis
    ) -> Result<ChatChartSpec, ChatChartError> {
        let xLabels: [String] = {
            if case .array(let arr) = obj["xLabels"] { return arr.map(stringifyJSON) }
            if case .array(let arr) = obj["x_labels"] { return arr.map(stringifyJSON) }
            if case .array(let arr) = obj["columns"] { return arr.map(stringifyJSON) }
            return []
        }()
        let yLabels: [String] = {
            if case .array(let arr) = obj["yLabels"] { return arr.map(stringifyJSON) }
            if case .array(let arr) = obj["y_labels"] { return arr.map(stringifyJSON) }
            if case .array(let arr) = obj["rows"] { return arr.map(stringifyJSON) }
            return []
        }()
        guard !xLabels.isEmpty, xLabels.count <= Limits.heatmapAxis,
              !yLabels.isEmpty, yLabels.count <= Limits.heatmapAxis
        else {
            return .failure(ChatChartError("A heatmap needs 1 to \(Limits.heatmapAxis) xLabels and yLabels."))
        }
        guard case .array(let rawRows) = obj["matrix"], rawRows.count == yLabels.count else {
            return .failure(ChatChartError("A heatmap matrix must have one row per yLabel."))
        }
        var matrix: [[Double?]] = []
        var allNums: [Double] = []
        for rawRow in rawRows {
            guard case .array(let cells) = rawRow, cells.count == xLabels.count else {
                return .failure(ChatChartError("Each heatmap row needs one value per xLabel."))
            }
            let parsedRow = cells.map(finiteDouble)
            allNums.append(contentsOf: parsedRow.compactMap { $0 })
            matrix.append(parsedRow)
        }
        guard let lo = allNums.min(), let hi = allNums.max() else {
            return .failure(ChatChartError("A heatmap needs at least one numeric cell."))
        }
        return .success(ChatChartSpec(
            type: .heatmap,
            title: title,
            subtitle: subtitle,
            x: xAxis,
            y: yAxis,
            heatmap: ChatHeatmapData(xLabels: xLabels, yLabels: yLabels, matrix: matrix, minValue: lo, maxValue: hi)
        ))
    }

    private static func parseCalendarHeatmap(
        obj: [String: JSONValue],
        title: String?,
        subtitle: String?,
        xAxis: ChatChartAxis,
        yAxis: ChatChartAxis
    ) -> Result<ChatChartSpec, ChatChartError> {
        guard case .array(let rawDays) = obj["days"], !rawDays.isEmpty, rawDays.count <= Limits.calendarDays else {
            return .failure(ChatChartError("A calendar-heatmap needs 1 to \(Limits.calendarDays) day entries."))
        }
        var days: [ChatCalendarDay] = []
        for raw in rawDays {
            let d = asObject(raw)
            guard let date = trimmedText(d["date"]), date.count >= 10,
                  let val = d["value"].flatMap(finiteDouble)
            else {
                return .failure(ChatChartError("Each calendar-heatmap day needs a YYYY-MM-DD date and numeric value."))
            }
            days.append(ChatCalendarDay(date: String(date.prefix(10)), value: val))
        }
        days.sort { $0.date < $1.date }
        return .success(ChatChartSpec(
            type: .calendarHeatmap,
            title: title,
            subtitle: subtitle,
            x: xAxis,
            y: yAxis,
            calendarDays: days
        ))
    }

    private static func parseSparkline(
        obj: [String: JSONValue],
        title: String?,
        subtitle: String?,
        xAxis: ChatChartAxis,
        yAxis: ChatChartAxis
    ) -> Result<ChatChartSpec, ChatChartError> {
        var vals: [Double] = []
        if case .array(let arr) = obj["values"] {
            vals = arr.compactMap(finiteDouble)
        } else if case .array(let sArr) = obj["series"],
                  let first = sArr.first.map(asObject),
                  case .array(let arr) = first["values"] {
            vals = arr.compactMap(finiteDouble)
        }
        guard vals.count >= 2, vals.count <= Limits.points else {
            return .failure(ChatChartError("A sparkline needs 2 to \(Limits.points) numeric values."))
        }
        return .success(ChatChartSpec(
            type: .sparkline,
            title: title,
            subtitle: subtitle,
            x: xAxis,
            y: yAxis,
            sparklineValues: vals,
            sparklineDelta: trimmedText(obj["delta"]),
            sparklineTone: trimmedText(obj["tone"])
        ))
    }

    // MARK: - Ticks & Formatting

    /// Evenly spaced round numbers covering `min...max`, widening endpoints to land on ticks.
    public static func niceTicks(min: Double, max: Double, count: Int = 5) -> [Double] {
        if min == max {
            let pad = abs(min) == 0 ? 1.0 : abs(min)
            return niceTicks(min: min - pad, max: max + pad, count: count)
        }
        let lo = Swift.min(min, max)
        let hi = Swift.max(min, max)
        let rough = (hi - lo) / Double(Swift.max(1, count - 1))
        let mag = pow(10.0, floor(log10(rough)))
        let candidates = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * mag }
        let step = candidates.first(where: { $0 >= rough }) ?? (10.0 * mag)
        let first = Int(floor(lo / step))
        let last = Int(ceil(hi / step))
        guard last >= first else { return [lo, hi] }
        return (first...last).map { i in
            roundToPrecision(Double(i) * step, significantDigits: 12)
        }
    }

    /// Compact representation from 1,000 up: `1K`, `2.5M`, `1.25B`, `3T`.
    public static func compactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let absVal = abs(value)
        let scales: [(Double, String)] = [
            (1e12, "T"),
            (1e9, "B"),
            (1e6, "M"),
            (1e3, "K"),
        ]
        for (limit, suffix) in scales where absVal >= limit {
            let scaled = roundToPrecision(value / limit, significantDigits: 3)
            return "\(formatCleanNumber(scaled))\(suffix)"
        }
        let rounded = roundToPrecision(value, significantDigits: 4)
        return formatCleanNumber(rounded)
    }

    /// Formats a value string with its unit: currency symbols lead (after `-`), `%`/`°` attach directly, others follow with a space.
    public static func withUnit(_ value: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return value }
        if unit == "$" || unit == "€" || unit == "£" || unit == "¥" {
            if value.hasPrefix("-") {
                return "-\(unit)\(value.dropFirst())"
            }
            return "\(unit)\(value)"
        }
        if unit.hasPrefix("%") || unit.hasPrefix("°") {
            return "\(value)\(unit)"
        }
        return "\(value) \(unit)"
    }

    /// Formatted value using `compactNumber` and this chart's `y.unit`.
    public func formattedValue(_ value: Double) -> String {
        Self.withUnit(Self.compactNumber(value), unit: y.unit)
    }

    /// Builds an accessible data table mirroring the chart's underlying values for every chart type.
    public func tableRows() -> ChatChartTable {
        switch type {
        case .scatter:
            let xHeader = x.label ?? "X"
            let yHeader = y.label ?? "Y"
            let showSeries = series.count > 1
            let headers = showSeries ? ["Series", xHeader, yHeader] : [xHeader, yHeader]
            var rows: [[String]] = []
            for s in series {
                for p in s.points {
                    let xStr = Self.compactNumber(p.x)
                    let yStr = formattedValue(p.y)
                    rows.append(showSeries ? [s.name, xStr, yStr] : [xStr, yStr])
                }
            }
            return ChatChartTable(headers: headers, rows: rows)

        case .histogram:
            let headers = [x.label ?? "Range", y.label ?? "Count"]
            let rows = histogramBins.map { [$0.label, String($0.count)] }
            return ChatChartTable(headers: headers, rows: rows)

        case .heatmap:
            guard let hm = heatmap else { return ChatChartTable(headers: [], rows: []) }
            let headers = [y.label ?? "Row"] + hm.xLabels
            let rows = hm.yLabels.enumerated().map { rIdx, yLab in
                [yLab] + hm.matrix[rIdx].map { v in v.map(formattedValue) ?? "—" }
            }
            return ChatChartTable(headers: headers, rows: rows)

        case .calendarHeatmap:
            let headers = ["Date", y.label ?? "Value"]
            let rows = calendarDays.map { [$0.date, formattedValue($0.value)] }
            return ChatChartTable(headers: headers, rows: rows)

        case .sparkline:
            let headers = ["Point", y.label ?? "Value"]
            let rows = sparklineValues.enumerated().map { [String($0.offset + 1), formattedValue($0.element)] }
            return ChatChartTable(headers: headers, rows: rows)

        case .bar, .stackedBar, .line, .area, .stackedArea, .radar:
            let catHeader = x.label ?? (type == .radar ? "Axis" : "Category")
            let valueHeaders = series.map { $0.name.isEmpty ? (y.label ?? "Value") : $0.name }
            let headers = [catHeader] + valueHeaders
            var rows: [[String]] = []
            rows.reserveCapacity(categories.count)
            for (idx, cat) in categories.enumerated() {
                var row = [cat]
                for s in series {
                    if idx < s.values.count, let v = s.values[idx] {
                        row.append(formattedValue(v))
                    } else {
                        row.append("—")
                    }
                }
                rows.append(row)
            }
            return ChatChartTable(headers: headers, rows: rows)
        }
    }

    // MARK: - Private JSON & Number Helpers

    fileprivate static func asObject(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let dict) = value { return dict }
        return [:]
    }

    fileprivate static func trimmedText(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func finiteDouble(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let i):
            return Double(i)
        case .double(let d):
            return d.isFinite ? d : nil
        default:
            return nil
        }
    }

    fileprivate static func stringifyJSON(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return formatCleanNumber(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return a.map(stringifyJSON).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    private static func roundToPrecision(_ value: Double, significantDigits: Int) -> Double {
        guard value != 0, value.isFinite else { return 0 }
        let magnitude = floor(log10(abs(value)))
        let factor = pow(10.0, Double(significantDigits - 1) - magnitude)
        let rounded = (value * factor).rounded() / factor
        return rounded == 0 ? 0 : rounded
    }

    private static func formatCleanNumber(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        let s = String(format: "%.12g", value)
        return s == "-0" ? "0" : s
    }
}

// MARK: - Stat Tiles / KPI Row (`stats` fence, LAZYAGENTS-321)

public struct ChatStatTile: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var value: String
    public var delta: String?
    public var tone: String?
    public var subtitle: String?
    public var sparkline: [Double]

    public init(
        id: Int,
        label: String,
        value: String,
        delta: String? = nil,
        tone: String? = nil,
        subtitle: String? = nil,
        sparkline: [Double] = []
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.delta = delta
        self.tone = tone
        self.subtitle = subtitle
        self.sparkline = sparkline
    }
}

public struct ChatStatsSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var items: [ChatStatTile]

    public init(title: String? = nil, subtitle: String? = nil, items: [ChatStatTile]) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }

    public static func isStatsFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "stats"
    }

    public static func parse(_ code: String) -> Result<ChatStatsSpec, ChatChartError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .failure(ChatChartError("This stats block isn't valid JSON."))
        }
        let obj = ChatChartSpec.asObject(root)
        let rawItems: [JSONValue]
        if case .array(let arr) = obj["items"] {
            rawItems = arr
        } else if case .array(let arr) = obj["tiles"] {
            rawItems = arr
        } else if case .array(let arr) = root {
            rawItems = arr
        } else {
            rawItems = []
        }
        guard !rawItems.isEmpty, rawItems.count <= 12 else {
            return .failure(ChatChartError("A stats block needs 1 to 12 items."))
        }
        var tiles: [ChatStatTile] = []
        for (idx, raw) in rawItems.enumerated() {
            let item = ChatChartSpec.asObject(raw)
            guard let label = ChatChartSpec.trimmedText(item["label"]) else {
                return .failure(ChatChartError("Stat item \(idx + 1) needs a label."))
            }
            let valueStr: String
            if let v = item["value"] {
                let s = ChatChartSpec.stringifyJSON(v).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty, s != "null" else {
                    return .failure(ChatChartError("Stat item \"\(label)\" needs a value."))
                }
                valueStr = ChatChartSpec.withUnit(s, unit: ChatChartSpec.trimmedText(item["unit"]))
            } else {
                return .failure(ChatChartError("Stat item \"\(label)\" needs a value."))
            }
            var spark: [Double] = []
            if case .array(let sArr) = item["sparkline"] {
                spark = sArr.compactMap(ChatChartSpec.finiteDouble)
            }
            tiles.append(ChatStatTile(
                id: idx,
                label: label,
                value: valueStr,
                delta: ChatChartSpec.trimmedText(item["delta"]),
                tone: ChatChartSpec.trimmedText(item["tone"]),
                subtitle: ChatChartSpec.trimmedText(item["subtitle"]),
                sparkline: spark
            ))
        }
        return .success(ChatStatsSpec(
            title: ChatChartSpec.trimmedText(obj["title"]),
            subtitle: ChatChartSpec.trimmedText(obj["subtitle"]),
            items: tiles
        ))
    }
}
