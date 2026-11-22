import Foundation

/// Guided Learning domain logic: build states, outline ordering, lesson picking,
/// time budget helpers, citation/markdown helpers, and lesson chart parsing.
/// Swift port of `web/lib/learning.ts` and the chart parser from `web/lib/chat-chart.ts`.
public enum LearnLogic {
    // MARK: Build state & stepper

    public enum BuildState: String, Sendable, CaseIterable, Equatable, Hashable {
        case scoping
        case outlineReady = "outline_ready"
        case researching
        case authoring
        case verifying
        case ready
        case stopped
        case failed

        public init?(courseState: API.CourseState) {
            self.init(rawValue: courseState.rawValue)
        }
    }

    public struct BuildStep: Sendable, Equatable, Hashable {
        public var label: String
        public var state: BuildState

        public init(label: String, state: BuildState) {
            self.label = label
            self.state = state
        }
    }

    public static let buildSteps: [BuildStep] = [
        BuildStep(label: "Scoping", state: .scoping),
        BuildStep(label: "Outline", state: .outlineReady),
        BuildStep(label: "Research", state: .researching),
        BuildStep(label: "Authoring", state: .authoring),
        BuildStep(label: "Review", state: .verifying),
        BuildStep(label: "Ready", state: .ready),
    ]

    public static func buildStepIndex(_ state: String) -> Int {
        buildSteps.firstIndex { $0.state.rawValue == state } ?? -1
    }

    public static func buildStepIndex(_ state: API.CourseState) -> Int {
        buildStepIndex(state.rawValue)
    }

    private static let buildingStates: Set<String> = ["scoping", "researching", "authoring", "verifying"]

    /// Vesper is working: nothing the person does will move it on.
    public static func courseBuilding(_ state: String) -> Bool {
        buildingStates.contains(state)
    }

    public static func courseBuilding(_ state: API.CourseState) -> Bool {
        courseBuilding(state.rawValue)
    }

    public static let courseStateLabels: [BuildState: String] = [
        .scoping: "Drafting outline",
        .outlineReady: "Outline ready",
        .researching: "Researching",
        .authoring: "Writing",
        .verifying: "Reviewing",
        .ready: "Ready",
        .stopped: "Stopped",
        .failed: "Failed",
    ]

    public static func stateLabel(_ state: API.CourseState) -> String {
        BuildState(courseState: state).flatMap { courseStateLabels[$0] } ?? state.rawValue
    }

    public static func statePillTone(_ state: API.CourseState) -> String {
        switch state {
        case .outlineReady: "human"
        case .failed: "blocked"
        default: "neutral"
        }
    }

    // MARK: Outline editing & lesson selection

    public struct OutlineUnitOrder: Sendable, Equatable, Hashable {
        public var title: String
        public var lessons: [String]

        public init(title: String, lessons: [String]) {
            self.title = title
            self.lessons = lessons
        }
    }

    /// Moves a lesson one place through the module's order. At the edge of a unit
    /// it crosses into the neighbouring one. Returns the same array if it can't move.
    public static func moveLesson(_ units: [OutlineUnitOrder], key: String, dir: Int) -> [OutlineUnitOrder] {
        let step = dir < 0 ? -1 : 1
        guard let u = units.firstIndex(where: { $0.lessons.contains(key) }),
              let i = units[u].lessons.firstIndex(of: key) else { return units }
        var next = units
        let j = i + step
        if j >= 0 && j < next[u].lessons.count {
            next[u].lessons.swapAt(i, j)
            return next
        }
        let target = u + step
        guard target >= 0 && target < next.count else { return units }
        next[u].lessons.remove(at: i)
        if step < 0 {
            next[target].lessons.append(key)
        } else {
            next[target].lessons.insert(key, at: 0)
        }
        return next
    }

    /// Runs still to go once the outline is approved: research, write and review per unit with something to teach.
    public static func estimatedRuns(_ units: [API.CourseOutlineUnit]) -> Int {
        estimatedRuns(knownFlagsByUnit: units.map { $0.lessons.map { $0.known == true } })
    }

    public static func estimatedRuns(knownFlagsByUnit units: [[Bool]]) -> Int {
        units.filter { $0.contains(false) }.count * 3
    }

    /// 1-based `"unit.lesson"` numbering across every unit in an outline.
    public static func lessonNumbers(in outline: API.CourseOutline) -> [String: String] {
        var out: [String: String] = [:]
        for (i, unit) in outline.units.enumerated() {
            for (j, lesson) in unit.lessons.enumerated() {
                out[lesson.key] = "\(i + 1).\(j + 1)"
            }
        }
        return out
    }

    /// The lesson to open: the one asked for, else the first with work left, else the first.
    public static func pickLesson(_ lessons: [API.CourseLesson], requested: String?) -> API.CourseLesson? {
        let open = lessons.filter { $0.status != .known }
        if let requested, let match = open.first(where: { $0.key == requested }) {
            return match
        }
        if let unfinished = open.first(where: { $0.progress == .new && !$0.checks.isEmpty }) {
            return unfinished
        }
        return open.first
    }

    // MARK: Time budget & guide options

    /// Above this a module is built in parts (the server's learningPartMinutes).
    public static let partMinutes = 480

    /// The time slider's stops: half hours up to 3h, then whole hours to 20h.
    public static let timeSteps: [Int] = [30, 60, 90, 120, 150, 180] + (0..<17).map { 240 + $0 * 60 }

    public static func timeLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = Double(minutes) / 60.0
        let whole = minutes % 60 == 0
        let num = whole ? "\(minutes / 60)" : String(format: "%.1f", h)
        return "\(num) \(h == 1 ? "hour" : "hours")"
    }

    /// About how many parts a module of this length is planned as (the server's guidance).
    public static func partsEstimate(_ minutes: Int) -> Int {
        minutes > partMinutes ? min(max((minutes + 120) / 240, 2), 6) : 1
    }

    public static func timeDetail(_ minutes: Int) -> String {
        if minutes <= 90 { return "A focused pass over what matters most." }
        if minutes <= 240 { return "Room for the main ideas and some practice." }
        if minutes <= partMinutes { return "A thorough module to work through over time." }
        return "Built in about \(partsEstimate(minutes)) parts. The first is built now; each next one is outlined as you near it, from how you\u{2019}re doing."
    }

    /// Matches `Math.round(minutes / 6) / 10` + `"h"`.
    public static func hoursTenthsLabel(_ minutes: Int) -> String {
        let tenths = Int((Double(minutes) / 6.0).rounded())
        if tenths % 10 == 0 {
            return "\(tenths / 10)h"
        }
        return "\(Double(tenths) / 10.0)h"
    }

    public struct ConfidenceOption: Sendable, Equatable, Identifiable {
        public var value: Int
        public var label: String
        public var id: Int { value }

        public init(value: Int, label: String) {
            self.value = value
            self.label = label
        }
    }

    public static let confidenceOptions: [ConfidenceOption] = [
        ConfidenceOption(value: 1, label: "Guessing"),
        ConfidenceOption(value: 2, label: "Fairly"),
        ConfidenceOption(value: 3, label: "Certain"),
    ]

    public struct LevelOption: Sendable, Equatable, Identifiable {
        public var value: API.CourseCreate.Level
        public var label: String
        public var detail: String
        public var id: String { value.rawValue }

        public init(value: API.CourseCreate.Level, label: String, detail: String) {
            self.value = value
            self.label = label
            self.detail = detail
        }
    }

    public static let levelOptions: [LevelOption] = [
        LevelOption(value: .new, label: "New", detail: "I\u{2019}m starting from scratch."),
        LevelOption(value: .some, label: "Some background", detail: "I\u{2019}ve met the basics and want to go further."),
        LevelOption(value: .experienced, label: "Experienced", detail: "I know this area and want the depth."),
    ]

    public static let quickTutorPrompts = [
        "Explain this differently",
        "Give me an example",
        "Quiz me on this",
    ]

    // MARK: Approval limits

    public static let sourceRange = 5...200
    public static let minuteRange = 5...120

    public static func parsedSpendLimit(_ spendText: String) -> Double? {
        let trimmed = spendText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    public static func approveLimitsValid(sources: Int, minutes: Int, spendText: String) -> Bool {
        guard sourceRange.contains(sources), minuteRange.contains(minutes) else { return false }
        let trimmed = spendText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let spend = Double(trimmed), spend.isFinite, spend > 0 else { return false }
        return true
    }

    // MARK: Markdown, citation, wizard & tutor helpers

    /// Markdown links, so a citation sits at the end of its paragraph.
    public static func citationsMarkdown(_ numbers: [Int]?) -> String {
        (numbers ?? []).map { " [\\[\($0)\\]](#source-\($0))" }.joined()
    }

    /// Wraps `code` in a Markdown fenced code block safe for `MarkdownView`.
    public static func codeFenceMarkdown(code: String, lang: String? = nil) -> String {
        var maxRun = 2
        var current = 0
        for ch in code {
            if ch == "`" {
                current += 1
                if current > maxRun { maxRun = current }
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: maxRun + 1)
        let info = (lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(fence)\(info)\n\(code)\n\(fence)"
    }

    /// What an SVG's `<title>` says, for its alt text.
    public static func svgTitle(_ source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: [.caseInsensitive]) else {
            return nil
        }
        let ns = source as NSString
        guard let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let text = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public static func defaultProjectKey(projects: [API.Project], preferred: String? = nil) -> String? {
        if let preferred, !preferred.isEmpty, let match = projects.first(where: { $0.key == preferred && !$0.archived }) {
            return match.key
        }
        return projects.first(where: { !$0.archived })?.key
    }

    public struct ModelSelection: Sendable, Equatable, Hashable {
        public var harness: String
        public var model: String

        public init(harness: String, model: String) {
            self.harness = harness
            self.model = model
        }
    }

    public static func defaultModelSelection(from groups: [API.ChatHarnessModels]) -> ModelSelection? {
        for group in groups {
            if let def = group.models.first(where: { $0.default }) {
                return ModelSelection(harness: group.harness.rawValue, model: def.id)
            }
        }
        return nil
    }

    public static func modelDisplayLabel(groups: [API.ChatHarnessModels], selection: ModelSelection) -> (harness: String, model: String) {
        let group = groups.first { $0.harness.rawValue == selection.harness }
        let harnessLabel = group?.label ?? selection.harness
        let modelLabel = group?.models.first(where: { $0.id == selection.model })?.label ?? selection.model
        return (harnessLabel, modelLabel)
    }

    public enum TutorContentBlock: Sendable, Equatable {
        case markdown(String)
        case chart(String)
    }

    /// Splits top-level ```` ```chart ```` fenced blocks out of tutor markdown so native Swift Charts
    /// can render them inline alongside `MarkdownView`.
    public static func splitTutorMarkdown(_ markdown: String) -> [TutorContentBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var result: [TutorContentBlock] = []
        var markdownBuffer: [String] = []
        var chartBuffer: [String] = []
        var fenceChar: Character?
        var fenceLength = 0
        var inChartFence = false

        func flushMarkdown() {
            let joined = markdownBuffer.joined(separator: "\n")
            markdownBuffer.removeAll()
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(joined))
            }
        }

        for line in lines {
            let trimmed = line.drop(while: { $0 == " " })
            if let activeChar = fenceChar {
                let closingCount = trimmed.prefix(while: { $0 == activeChar }).count
                let rest = trimmed.dropFirst(closingCount)
                if closingCount >= fenceLength && rest.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fenceChar = nil
                    fenceLength = 0
                    if inChartFence {
                        result.append(.chart(chartBuffer.joined(separator: "\n")))
                        chartBuffer.removeAll()
                        inChartFence = false
                    } else {
                        markdownBuffer.append(line)
                    }
                    continue
                }
                if inChartFence {
                    chartBuffer.append(line)
                } else {
                    markdownBuffer.append(line)
                }
                continue
            }

            if let first = trimmed.first, (first == "`" || first == "~") {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let infoWord = info.split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
                    let validBacktickInfo = first != "`" || !info.contains("`")
                    if validBacktickInfo {
                        fenceChar = first
                        fenceLength = count
                        if infoWord == "chart" {
                            flushMarkdown()
                            inChartFence = true
                            chartBuffer.removeAll()
                            continue
                        }
                    }
                }
            }
            markdownBuffer.append(line)
        }

        if inChartFence {
            // Unclosed chart fence: fall back to markdown so partial text isn't lost.
            let fence = String(repeating: String(fenceChar ?? "`"), count: max(3, fenceLength))
            markdownBuffer.append("\(fence)chart")
            markdownBuffer.append(contentsOf: chartBuffer)
        }
        flushMarkdown()
        return result
    }

    // MARK: Charts (ported from web/lib/chat-chart.ts)

    public enum ChartType: String, Sendable, Equatable {
        case bar
        case line
        case scatter
    }

    public struct ChartPoint: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct ChartSeries: Sendable, Equatable {
        public var name: String
        public var values: [Double?]
        public var points: [ChartPoint]

        public init(name: String, values: [Double?] = [], points: [ChartPoint] = []) {
            self.name = name
            self.values = values
            self.points = points
        }
    }

    public struct ChartSpec: Sendable, Equatable {
        public var type: ChartType
        public var title: String?
        public var subtitle: String?
        public var xLabel: String?
        public var yLabel: String?
        public var yUnit: String?
        public var categories: [String]
        public var series: [ChartSeries]

        public init(
            type: ChartType,
            title: String? = nil,
            subtitle: String? = nil,
            xLabel: String? = nil,
            yLabel: String? = nil,
            yUnit: String? = nil,
            categories: [String] = [],
            series: [ChartSeries]
        ) {
            self.type = type
            self.title = title
            self.subtitle = subtitle
            self.xLabel = xLabel
            self.yLabel = yLabel
            self.yUnit = yUnit
            self.categories = categories
            self.series = series
        }
    }

    public enum ChartParseResult: Sendable, Equatable {
        case spec(ChartSpec)
        case error(String)
    }

    public static let chartMaxSeries = 8
    public static let chartMaxScatterSeries = 3
    public static let chartMaxCategories = 60
    public static let chartMaxPoints = 500

    private static func trimmedText(_ value: JSONValue?) -> String? {
        guard case .string(let s) = value else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func finiteNumber(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let n):
            return Double(n)
        case .double(let d) where d.isFinite:
            return d
        default:
            return nil
        }
    }

    private static func jsonObject(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let obj) = value { return obj }
        return [:]
    }

    private static func stringifyCategory(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let n): return String(n)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .array(let arr): return arr.map(stringifyCategory).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    public static func parseChart(_ code: String) -> ChartParseResult {
        guard let data = code.data(using: .utf8),
              let raw = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .error("This chart isn't valid JSON.")
        }
        let r = jsonObject(raw)
        guard case .string(let rawType) = r["type"], let type = ChartType(rawValue: rawType) else {
            return .error("A chart's type must be bar, line or scatter.")
        }
        let list: [[String: JSONValue]]
        if case .array(let items) = r["series"] {
            list = items.map { jsonObject($0) }
        } else {
            list = []
        }
        let maxSeries = type == .scatter ? chartMaxScatterSeries : chartMaxSeries
        if list.isEmpty || list.count > maxSeries {
            return .error("A \(type.rawValue) chart needs 1 to \(maxSeries) series.")
        }
        let categories: [String]
        if case .array(let cats) = r["categories"] {
            categories = cats.map(stringifyCategory)
        } else {
            categories = []
        }
        if type != .scatter && (categories.isEmpty || categories.count > chartMaxCategories) {
            return .error("A \(type.rawValue) chart needs 1 to \(chartMaxCategories) categories.")
        }

        var series: [ChartSeries] = []
        for s in list {
            let name = trimmedText(s["name"]) ?? ""
            if name.isEmpty && list.count > 1 {
                return .error("Each series needs a name.")
            }
            if type == .scatter {
                let rawPoints: [JSONValue]
                if case .array(let arr) = s["points"] { rawPoints = arr } else { rawPoints = [] }
                let points: [ChartPoint] = rawPoints.compactMap { item in
                    guard case .array(let pair) = item, pair.count == 2,
                          let x = finiteNumber(pair[0]),
                          let y = finiteNumber(pair[1]) else { return nil }
                    return ChartPoint(x: x, y: y)
                }
                if points.isEmpty || points.count > chartMaxPoints {
                    return .error("Each series needs 1 to \(chartMaxPoints) points.")
                }
                series.append(ChartSeries(name: name, points: points))
            } else {
                let rawValues: [JSONValue]
                if case .array(let arr) = s["values"] { rawValues = arr } else { rawValues = [] }
                let values: [Double?] = rawValues.map { finiteNumber($0) }
                if values.count != categories.count || values.allSatisfy({ $0 == nil }) {
                    return .error("Series \"\(name)\" needs one value per category.")
                }
                series.append(ChartSeries(name: name, values: values))
            }
        }

        let x = jsonObject(r["x"])
        let y = jsonObject(r["y"])
        return .spec(ChartSpec(
            type: type,
            title: trimmedText(r["title"]),
            subtitle: trimmedText(r["subtitle"]),
            xLabel: trimmedText(x["label"]),
            yLabel: trimmedText(y["label"]),
            yUnit: trimmedText(y["unit"]),
            categories: categories,
            series: series
        ))
    }

    private static func makeCompactFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 4
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static func makeCompactScaleFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 3
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static func makeFullNumberFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US")
        return f
    }

    /// Compact from 1,000 up: 1K, 2.5M.
    public static func compactNumber(_ value: Double) -> String {
        let absValue = abs(value)
        let suffixes: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (limit, suffix) in suffixes where absValue >= limit {
            let scaled = value / limit
            let text = makeCompactScaleFormatter().string(from: NSNumber(value: scaled)) ?? String(scaled)
            return "\(text)\(suffix)"
        }
        if value == 0 { return "0" }
        return makeCompactFormatter().string(from: NSNumber(value: value)) ?? String(value)
    }

    /// A currency symbol leads the number; any other unit follows it.
    public static func withUnit(_ value: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return value }
        if unit.count == 1, "$€£¥".contains(unit) {
            if value.hasPrefix("-") {
                return "-\(unit)\(value.dropFirst())"
            }
            return "\(unit)\(value)"
        }
        if let first = unit.first, first == "%" || first == "°" {
            return "\(value)\(unit)"
        }
        return "\(value) \(unit)"
    }

    public static func formatChartValue(_ value: Double, unit: String?) -> String {
        let text = makeFullNumberFormatter().string(from: NSNumber(value: value)) ?? String(value)
        return withUnit(text, unit: unit)
    }
}
