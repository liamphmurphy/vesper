import Foundation

/// Pure domain logic for Reports (Costs & Highlights): date range presets, micros currency
/// formatting, daily/agent/model stacked series folding (top N + Other), and routing highlights
/// aggregation (Foundation only; zero AppKit).
/// Ports `web/lib/costs.ts` and `web/lib/highlights.ts`.
public enum ReportsLogic {
    public static let maxRangeDays = 366
    public static let otherKey = "Other"

    public enum Tab: String, Sendable, CaseIterable, Equatable {
        case costs
        case highlights

        public var label: String {
            switch self {
            case .costs: "Costs"
            case .highlights: "Highlights"
            }
        }
    }

    public enum RangePreset: String, Sendable, CaseIterable, Equatable {
        case days7 = "7"
        case days30 = "30"
        case days90 = "90"
        case custom

        public var label: String {
            switch self {
            case .days7: "7 days"
            case .days30: "30 days"
            case .days90: "90 days"
            case .custom: "Custom"
            }
        }

        public var dayCount: Int? {
            switch self {
            case .days7: 7
            case .days30: 30
            case .days90: 90
            case .custom: nil
            }
        }
    }

    public enum GroupBy: String, Sendable, CaseIterable, Equatable {
        case agents
        case models

        public var label: String {
            switch self {
            case .agents: "By agent"
            case .models: "By model"
            }
        }
    }

    public enum EffortSelection: String, Sendable, CaseIterable, Equatable {
        case all
        case auto

        public var label: String {
            switch self {
            case .all: "All effort choices"
            case .auto: "Auto only"
            }
        }
    }

    // MARK: - Date Ranges (UTC)

    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal
    }

    public static func utcDay(_ date: Date) -> String {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    public static func parseUTCDay(_ ymd: String) -> Date? {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        guard let date = utcCalendar.date(from: comps), utcDay(date) == ymd else { return nil }
        return date
    }

    /// The last `days` UTC days, ending today.
    public static func presetRange(days: Int, now: Date = Date()) -> (from: String, to: String) {
        let clamped = max(1, days)
        let cal = utcCalendar
        let todayStart = cal.startOfDay(for: now)
        let fromDate = cal.date(byAdding: .day, value: -(clamped - 1), to: todayStart) ?? todayStart
        return (utcDay(fromDate), utcDay(todayStart))
    }

    public static func rangeError(from: String, to: String) -> String? {
        guard let start = parseUTCDay(from), let end = parseUTCDay(to) else {
            return "Pick a start and end day."
        }
        let span = Int((end.timeIntervalSince(start) / 86_400).rounded()) + 1
        if span < 1 { return "The end day must not be before the start day." }
        if span > maxRangeDays { return "A range is at most \(maxRangeDays) days." }
        return nil
    }

    public static func formatUTCShortDay(_ ymd: String) -> String {
        formatUTC(ymd, format: "MMM d")
    }

    public static func formatUTCWeekday(_ ymd: String) -> String {
        formatUTC(ymd, format: "EEE, MMM d")
    }

    public static func formatUTCYearDay(_ ymd: String) -> String {
        formatUTC(ymd, format: "MMM d, yyyy")
    }

    private static func formatUTC(_ ymd: String, format: String) -> String {
        guard let date = parseUTCDay(ymd) else { return ymd }
        let fmt = DateFormatter()
        fmt.calendar = utcCalendar
        fmt.timeZone = utcCalendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = format
        return fmt.string(from: date)
    }

    // MARK: - Currency & Number Formatting

    /// `412_370_000` -> `"$412.37"`; spend under a cent keeps three decimals so it never reads `$0.00`.
    public static func usd(micros: Int) -> String {
        let value = Double(micros) / 1_000_000.0
        if value > 0 && value < 0.01 {
            return value < 0.001 ? "< $0.001" : String(format: "$%.3f", value)
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let num = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "$\(num)"
    }

    public static func spendLabel(micros: Int, unpricedRuns: Int) -> String {
        if unpricedRuns > 0 {
            return micros > 0 ? "≥ \(usd(micros: micros))" : "Unknown"
        }
        return usd(micros: micros)
    }

    public static func share(part: Int, total: Int) -> String {
        guard total > 0 else { return "–" }
        return String(format: "%.1f%%", (Double(part) / Double(total)) * 100.0)
    }

    public static func costPerPoint(micros: Int, points: Int?) -> String? {
        guard let points, points > 0 else { return nil }
        let perPoint = Int((Double(micros) / Double(points)).rounded())
        return usd(micros: perPoint)
    }

    public static func compactCount(_ value: Int) -> String {
        let absVal = abs(value)
        if absVal >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000.0) }
        if absVal >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000.0) }
        return "\(value)"
    }

    /// `"harness/model"` -> `"model"` when grouping by models.
    public static func seriesLabel(key: String, by: GroupBy, agentNames: [String: String] = [:]) -> String {
        if key == otherKey { return otherKey }
        if by == .agents { return agentNames[key] ?? key }
        if let slash = key.firstIndex(of: "/") {
            return String(key[key.index(after: slash)...])
        }
        return key
    }

    // MARK: - Stacked Series Folding (Top N + Other)

    public struct StackedSegment: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var costMicros: Int

        public init(key: String, costMicros: Int) {
            self.key = key; self.costMicros = costMicros
        }
    }

    public struct StackedBar: Sendable, Equatable, Identifiable {
        public var id: String { date }
        public var date: String
        public var runs: Int
        public var totalMicros: Int
        public var segments: [StackedSegment]

        public init(date: String, runs: Int, totalMicros: Int, segments: [StackedSegment]) {
            self.date = date; self.runs = runs; self.totalMicros = totalMicros; self.segments = segments
        }
    }

    public struct StackedSeriesResult: Sendable, Equatable {
        public var keys: [String]
        public var bars: [StackedBar]
        public var totals: [StackedSegment]

        public init(keys: [String], bars: [StackedBar], totals: [StackedSegment]) {
            self.keys = keys; self.bars = bars; self.totals = totals
        }
    }

    public struct DailyChartPoint: Sendable, Equatable, Identifiable {
        public var id: String { "\(date)::\(seriesKey)" }
        public var date: String
        public var seriesKey: String
        public var seriesLabel: String
        public var dollars: Double
        public var costMicros: Int

        public init(date: String, seriesKey: String, seriesLabel: String, costMicros: Int) {
            self.date = date
            self.seriesKey = seriesKey
            self.seriesLabel = seriesLabel
            self.costMicros = costMicros
            self.dollars = Double(costMicros) / 1_000_000.0
        }
    }

    /// Top `top` most expensive keys over the range, folding the rest into `Other`.
    /// Matches `stackSeries` in `web/lib/costs.ts`.
    public static func stackSeries(
        days: [API.CostDay],
        by: GroupBy,
        top: Int = 6
    ) -> StackedSeriesResult {
        var totals: [String: Int] = [:]
        for day in days {
            let parts = by == .agents ? day.agents : day.models
            for part in parts {
                totals[part.key, default: 0] += part.costMicros
            }
        }
        let ranked = totals
            .filter { $0.value > 0 }
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
        let keepCount = ranked.count > top ? max(0, top - 1) : ranked.count
        let keep = Array(ranked.prefix(keepCount))
        let keptSet = Set(keep.map(\.key))
        var keys = keep.map(\.key)
        let hasOther = ranked.count > keep.count
        if hasOther { keys.append(otherKey) }

        let bars: [StackedBar] = days.map { day in
            var dayParts: [String: Int] = [:]
            let parts = by == .agents ? day.agents : day.models
            for part in parts {
                let k = keptSet.contains(part.key) ? part.key : otherKey
                dayParts[k, default: 0] += part.costMicros
            }
            return StackedBar(
                date: day.date,
                runs: day.runs,
                totalMicros: day.costMicros,
                segments: keys.map { StackedSegment(key: $0, costMicros: dayParts[$0] ?? 0) }
            )
        }

        let otherTotal = ranked.dropFirst(keepCount).reduce(0) { $0 + $1.value }
        let seriesTotals = keys.map { key in
            StackedSegment(key: key, costMicros: key == otherKey ? otherTotal : (totals[key] ?? 0))
        }
        return StackedSeriesResult(keys: keys, bars: bars, totals: seriesTotals)
    }

    public static func chartPoints(
        from stacked: StackedSeriesResult,
        by: GroupBy,
        agentNames: [String: String] = [:]
    ) -> [DailyChartPoint] {
        var out: [DailyChartPoint] = []
        for bar in stacked.bars {
            for seg in bar.segments where seg.costMicros > 0 {
                out.append(DailyChartPoint(
                    date: bar.date,
                    seriesKey: seg.key,
                    seriesLabel: seriesLabel(key: seg.key, by: by, agentNames: agentNames),
                    costMicros: seg.costMicros
                ))
            }
        }
        return out
    }

    /// Round axis maximum (1, 2, 2.5 or 5 × 10ⁿ dollars) at or above `maxMicros`.
    public static func axisMax(maxMicros: Int) -> Int {
        guard maxMicros > 0 else { return 1_000_000 }
        let v = Double(maxMicros) / 1_000_000.0
        let mag = pow(10.0, floor(log10(v)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].first { $0 * mag >= v } ?? 10.0
        return Int((step * mag * 1_000_000.0).rounded())
    }

    // MARK: - Highlights Grouping

    public struct HighlightRow: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public var key: String
        public var label: String
        public var turns: Int
        public var automatic: Int

        public init(key: String, label: String, turns: Int, automatic: Int) {
            self.key = key; self.label = label; self.turns = turns; self.automatic = automatic
        }
    }

    public struct HighlightsSummary: Sendable, Equatable {
        public var turns: Int
        public var automatic: Int
        public var chosen: Int
        public var unknown: Int
        public var raised: Int
        public var adjusted: Int
        public var timed: Int
        public var averageMs: Double?
        public var personas: [HighlightRow]
        public var models: [HighlightRow]
        public var efforts: [HighlightRow]
        public var levels: [HighlightRow]
        public var reasons: [HighlightRow]

        public init(
            turns: Int = 0, automatic: Int = 0, chosen: Int = 0, unknown: Int = 0,
            raised: Int = 0, adjusted: Int = 0, timed: Int = 0, averageMs: Double? = nil,
            personas: [HighlightRow] = [], models: [HighlightRow] = [], efforts: [HighlightRow] = [],
            levels: [HighlightRow] = [], reasons: [HighlightRow] = []
        ) {
            self.turns = turns; self.automatic = automatic; self.chosen = chosen; self.unknown = unknown
            self.raised = raised; self.adjusted = adjusted; self.timed = timed; self.averageMs = averageMs
            self.personas = personas; self.models = models; self.efforts = efforts
            self.levels = levels; self.reasons = reasons
        }
    }

    private static let effortOrder = ["low", "medium", "high", "xhigh", "max", ""]

    public static func effortName(_ raw: String) -> String {
        switch raw {
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra high"
        case "max": "Max"
        case "": "Model default / unrecorded"
        default: raw
        }
    }

    public static func reasonName(_ raw: String) -> String {
        switch raw {
        case "confirmation": "Go-ahead"
        case "effort_mismatch": "Retry or edit"
        default: raw
        }
    }

    public static func filterBuckets(
        _ buckets: [API.HighlightsBucket],
        personaId: String,
        selection: EffortSelection
    ) -> [API.HighlightsBucket] {
        buckets.filter { b in
            let personaOK = personaId == "all" || personaId.isEmpty || b.personaId == personaId
            let selectionOK = selection == .all || !b.effortLevel.isEmpty
            return personaOK && selectionOK
        }
    }

    public static func routingHighlights(_ buckets: [API.HighlightsBucket]) -> HighlightsSummary {
        var turns = 0, automatic = 0, chosen = 0, raised = 0, adjusted = 0, duration = 0, timed = 0
        var personas: [String: HighlightRow] = [:]
        var models: [String: HighlightRow] = [:]
        var efforts: [String: HighlightRow] = [:]
        var levels: [String: HighlightRow] = [:]
        var reasons: [String: HighlightRow] = [:]

        func add(_ map: inout [String: HighlightRow], key: String, label: String, bucket: API.HighlightsBucket) {
            var row = map[key] ?? HighlightRow(key: key, label: label, turns: 0, automatic: 0)
            row.turns += bucket.turns
            if !bucket.effortLevel.isEmpty { row.automatic += bucket.turns }
            map[key] = row
        }

        for b in buckets {
            turns += b.turns
            duration += b.durationMs
            timed += b.timedTurns
            if !b.effortLevel.isEmpty {
                automatic += b.turns
                if !b.reasons.isEmpty { raised += b.turns }
                if !b.effort.isEmpty && b.effort != b.effortLevel { adjusted += b.turns }
                add(&levels, key: b.effortLevel, label: effortName(b.effortLevel), bucket: b)
                for reason in Set(b.reasons) {
                    add(&reasons, key: reason, label: reasonName(reason), bucket: b)
                }
            } else if !b.effort.isEmpty {
                chosen += b.turns
            }
            add(&personas, key: b.personaId, label: b.persona, bucket: b)
            let modelLabel = b.model.isEmpty ? "Unknown model" : "\(b.model) · \(b.harness.isEmpty ? "Unknown harness" : b.harness)"
            add(&models, key: "\(b.harness)/\(b.model)", label: modelLabel, bucket: b)
            add(&efforts, key: b.effort, label: effortName(b.effort), bucket: b)
        }

        func ranked(_ map: [String: HighlightRow]) -> [HighlightRow] {
            map.values.sorted { a, b in a.turns != b.turns ? a.turns > b.turns : a.key < b.key }
        }
        func orderedEfforts(_ map: [String: HighlightRow]) -> [HighlightRow] {
            map.values.sorted { a, b in
                let ia = effortOrder.firstIndex(of: a.key) ?? effortOrder.count
                let ib = effortOrder.firstIndex(of: b.key) ?? effortOrder.count
                return ia != ib ? ia < ib : a.key < b.key
            }
        }

        return HighlightsSummary(
            turns: turns,
            automatic: automatic,
            chosen: chosen,
            unknown: turns - automatic - chosen,
            raised: raised,
            adjusted: adjusted,
            timed: timed,
            averageMs: timed > 0 ? Double(duration) / Double(timed) : nil,
            personas: ranked(personas),
            models: ranked(models),
            efforts: orderedEfforts(efforts),
            levels: orderedEfforts(levels),
            reasons: ranked(reasons)
        )
    }
}
