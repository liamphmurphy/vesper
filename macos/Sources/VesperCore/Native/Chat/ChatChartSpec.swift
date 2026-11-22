import Foundation

/// Error returned when a ```chart fence cannot be parsed or fails validation.
public struct ChatChartError: Error, Sendable, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum ChatChartType: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case bar
    case line
    case scatter
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
    /// One value per category for bar/line charts; `nil` marks a gap. Empty for scatter charts.
    public var values: [Double?]
    /// `(x, y)` pairs for scatter charts. Empty for bar/line charts.
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

/// Tabular view of a chart's underlying data (for the Show Table toggle).
public struct ChatChartTable: Sendable, Equatable {
    public var headers: [String]
    public var rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }
}

/// Pure Swift port of `web/lib/chat-chart.ts`: parses, validates, and formats ```chart JSON specs.
public struct ChatChartSpec: Sendable, Equatable, Hashable {
    public enum Limits {
        public static let series = 8
        public static let scatterSeries = 3
        public static let categories = 60
        public static let points = 500
    }

    public var type: ChatChartType
    public var title: String?
    public var subtitle: String?
    public var x: ChatChartAxis
    public var y: ChatChartAxis
    public var categories: [String]
    public var series: [ChatChartSeries]

    public init(
        type: ChatChartType,
        title: String? = nil,
        subtitle: String? = nil,
        x: ChatChartAxis = ChatChartAxis(),
        y: ChatChartAxis = ChatChartAxis(),
        categories: [String] = [],
        series: [ChatChartSeries]
    ) {
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.x = x
        self.y = y
        self.categories = categories
        self.series = series
    }

    /// True when a code fence's info string starts with `chart` (case-insensitive).
    public static func isChartFence(_ info: String?) -> Bool {
        let first = (info ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
        return first?.lowercased() == "chart"
    }

    /// Parses and validates a ```chart JSON payload using the same rules as `web/lib/chat-chart.ts`.
    public static func parse(_ code: String) -> Result<ChatChartSpec, ChatChartError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .failure(ChatChartError("This chart isn't valid JSON."))
        }

        let obj = asObject(root)
        guard let typeRaw = obj["type"]?.stringValue,
              let type = ChatChartType(rawValue: typeRaw)
        else {
            return .failure(ChatChartError("A chart's type must be bar, line or scatter."))
        }

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

        if type != .scatter && (categories.isEmpty || categories.count > Limits.categories) {
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

        let xObj = asObject(obj["x"])
        let yObj = asObject(obj["y"])

        return .success(ChatChartSpec(
            type: type,
            title: trimmedText(obj["title"]),
            subtitle: trimmedText(obj["subtitle"]),
            x: ChatChartAxis(label: trimmedText(xObj["label"])),
            y: ChatChartAxis(label: trimmedText(yObj["label"]), unit: trimmedText(yObj["unit"])),
            categories: categories,
            series: parsedSeries
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

    /// Builds a readable data table mirroring the chart's series and categories/points.
    public func tableRows() -> ChatChartTable {
        if type == .scatter {
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
        }

        let catHeader = x.label ?? "Category"
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

    // MARK: - Private JSON & Number Helpers

    private static func asObject(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let dict) = value { return dict }
        return [:]
    }

    private static func trimmedText(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func finiteDouble(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let i):
            return Double(i)
        case .double(let d):
            return d.isFinite ? d : nil
        default:
            return nil
        }
    }

    private static func stringifyJSON(_ value: JSONValue) -> String {
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
