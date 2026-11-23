import Foundation

// MARK: - Timeline & Waterfall Block (LAZYAGENTS-320)

public enum ChatTimelineAxisMode: String, Sendable, Equatable, Hashable {
    case date
    case numeric
}

public struct ChatTimelineItem: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var lane: String
    /// Start value (epoch seconds for `.date`, raw numeric unit for `.numeric`).
    public var start: Double
    /// End value; `nil` for point events.
    public var end: Double?
    public var annotation: String?
    public var tone: String?

    public var isPoint: Bool { end == nil || (end ?? start) <= start }

    public init(
        id: Int,
        label: String,
        lane: String,
        start: Double,
        end: Double? = nil,
        annotation: String? = nil,
        tone: String? = nil
    ) {
        self.id = id
        self.label = label
        self.lane = lane
        self.start = start
        self.end = end
        self.annotation = annotation
        self.tone = tone
    }
}

public struct ChatTimelineTick: Sendable, Equatable, Hashable {
    public var fraction: Double
    public var label: String

    public init(fraction: Double, label: String) {
        self.fraction = fraction
        self.label = label
    }
}

public struct ChatTimelineSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var mode: ChatTimelineAxisMode
    public var unit: String
    public var lanes: [String]
    public var items: [ChatTimelineItem]
    public var minValue: Double
    public var maxValue: Double

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        mode: ChatTimelineAxisMode,
        unit: String,
        lanes: [String],
        items: [ChatTimelineItem],
        minValue: Double,
        maxValue: Double
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.unit = unit
        self.lanes = lanes
        self.items = items
        self.minValue = minValue
        self.maxValue = maxValue
    }

    public static func isTimelineFence(_ info: String?) -> Bool {
        let w = ChatFenceParsers.firstWord(of: info)
        return w == "timeline" || w == "waterfall"
    }

    public static func parse(_ code: String) -> Result<ChatTimelineSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This timeline block isn't valid JSON."))
        }

        guard let rawItems = obj["items"]?.arrayVal ?? obj["events"]?.arrayVal,
              !rawItems.isEmpty, rawItems.count <= 200
        else {
            return .failure(ChatVisualizationError("A timeline block needs 1 to 200 items."))
        }

        var declaredLanes: [String] = []
        if let laneArr = obj["lanes"]?.arrayVal {
            declaredLanes = laneArr.compactMap(\.trimmedString)
        }

        var parsedItems: [ChatTimelineItem] = []
        var sawDate = false
        var sawNumeric = false

        for (idx, raw) in rawItems.enumerated() {
            guard let item = raw.objectVal,
                  let label = item["label"]?.trimmedString ?? item["title"]?.trimmedString
            else {
                return .failure(ChatVisualizationError("Timeline item \(idx + 1) needs a label."))
            }
            let lane = item["lane"]?.trimmedString ?? item["group"]?.trimmedString ?? "Timeline"

            let startVal: Double
            let endVal: Double?
            if let atVal = item["at"] {
                guard let parsed = parseTimeValue(atVal) else {
                    return .failure(ChatVisualizationError("Timeline item \"\(label)\" has an invalid 'at' timestamp."))
                }
                if parsed.isDate { sawDate = true } else { sawNumeric = true }
                startVal = parsed.value
                endVal = nil
            } else if let sVal = item["start"] {
                guard let parsedStart = parseTimeValue(sVal) else {
                    return .failure(ChatVisualizationError("Timeline item \"\(label)\" has an invalid 'start' timestamp."))
                }
                if parsedStart.isDate { sawDate = true } else { sawNumeric = true }
                startVal = parsedStart.value
                if let eVal = item["end"] {
                    guard let parsedEnd = parseTimeValue(eVal) else {
                        return .failure(ChatVisualizationError("Timeline item \"\(label)\" has an invalid 'end' timestamp."))
                    }
                    if parsedEnd.isDate { sawDate = true } else { sawNumeric = true }
                    endVal = max(parsedStart.value, parsedEnd.value)
                } else if let dur = item["duration"]?.doubleVal ?? item["durationMs"]?.doubleVal {
                    endVal = parsedStart.value + max(0, dur)
                } else {
                    endVal = nil
                }
            } else {
                return .failure(ChatVisualizationError("Timeline item \"\(label)\" needs either 'at' or 'start'."))
            }

            let annotation: String? = {
                if let a = item["annotation"]?.trimmedString { return a }
                if let tok = item["tokens"]?.doubleVal {
                    return "\(ChatChartSpec.compactNumber(tok)) tok"
                }
                if let metric = item["metric"]?.trimmedString { return metric }
                return nil
            }()

            parsedItems.append(ChatTimelineItem(
                id: idx,
                label: label,
                lane: lane,
                start: startVal,
                end: endVal,
                annotation: annotation,
                tone: item["tone"]?.trimmedString
            ))
        }

        if sawDate && sawNumeric {
            return .failure(ChatVisualizationError("Timeline items cannot mix ISO dates and raw numeric offsets."))
        }
        let mode: ChatTimelineAxisMode = sawDate ? .date : .numeric
        let unit = obj["unit"]?.trimmedString ?? (mode == .date ? "date" : "ms")

        var lanes = declaredLanes
        for item in parsedItems where !lanes.contains(item.lane) {
            lanes.append(item.lane)
        }

        let allStarts = parsedItems.map(\.start)
        let allEnds = parsedItems.map { $0.end ?? $0.start }
        let minVal = allStarts.min() ?? 0
        var maxVal = allEnds.max() ?? minVal
        if maxVal <= minVal {
            maxVal = minVal + (mode == .date ? 3600 : 100)
        }

        return .success(ChatTimelineSpec(
            title: obj["title"]?.trimmedString,
            subtitle: obj["subtitle"]?.trimmedString,
            mode: mode,
            unit: unit,
            lanes: lanes,
            items: parsedItems,
            minValue: minVal,
            maxValue: maxVal
        ))
    }

    /// Generates evenly spaced adaptive ticks formatted from milliseconds/seconds to years.
    public func axisTicks(count: Int = 5) -> [ChatTimelineTick] {
        let steps = max(2, count)
        let span = max(maxValue - minValue, 1e-9)
        return (0..<steps).map { i in
            let f = Double(i) / Double(steps - 1)
            let v = minValue + f * span
            return ChatTimelineTick(fraction: f, label: formatTick(v, span: span))
        }
    }

    public func fraction(for value: Double) -> Double {
        let span = max(maxValue - minValue, 1e-9)
        return max(0, min(1, (value - minValue) / span))
    }

    public func formatTick(_ value: Double, span: Double) -> String {
        if mode == .numeric {
            let u = unit.lowercased()
            if u == "ms" {
                if span >= 120_000 {
                    return String(format: "%.1fm", value / 60_000)
                }
                if span >= 2_000 {
                    return String(format: "%.1fs", value / 1_000)
                }
                return "\(Int(value.rounded()))ms"
            }
            if u == "s" || u == "sec" {
                if span >= 7200 { return String(format: "%.1fh", value / 3600) }
                if span >= 120 { return String(format: "%.1fm", value / 60) }
                return String(format: "%.1fs", value)
            }
            return ChatChartSpec.withUnit(ChatChartSpec.compactNumber(value), unit: unit)
        }

        let date = Date(timeIntervalSince1970: value)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        if span <= 120 {
            fmt.dateFormat = "HH:mm:ss"
        } else if span <= 86_400 {
            fmt.dateFormat = "HH:mm"
        } else if span <= 86_400 * 7 {
            fmt.dateFormat = "MMM d HH:mm"
        } else if span <= 86_400 * 120 {
            fmt.dateFormat = "MMM d"
        } else if span <= 86_400 * 730 {
            fmt.dateFormat = "MMM yyyy"
        } else {
            fmt.dateFormat = "yyyy"
        }
        return fmt.string(from: date)
    }

    private static func parseTimeValue(_ raw: JSONValue) -> (value: Double, isDate: Bool)? {
        if let d = raw.doubleVal {
            return (d, false)
        }
        guard let str = raw.trimmedString else { return nil }
        if let num = Double(str), num.isFinite {
            return (num, false)
        }
        // Try ISO8601 full datetime with or without fractional seconds
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: str) {
            return (d.timeIntervalSince1970, true)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) {
            return (d.timeIntervalSince1970, true)
        }
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy-MM", "yyyy"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: str) {
                return (d.timeIntervalSince1970, true)
            }
        }
        return nil
    }
}

// MARK: - Collapsible Tree Block (LAZYAGENTS-323)

public struct ChatTreeNode: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var annotation: String?
    public var isFolder: Bool
    public var children: [ChatTreeNode]

    public init(
        id: String,
        label: String,
        annotation: String? = nil,
        isFolder: Bool,
        children: [ChatTreeNode] = []
    ) {
        self.id = id
        self.label = label
        self.annotation = annotation
        self.isFolder = isFolder
        self.children = children
    }

    public var allExpandableIDs: Set<String> {
        var out: Set<String> = []
        if !children.isEmpty { out.insert(id) }
        for child in children {
            out.formUnion(child.allExpandableIDs)
        }
        return out
    }
}

public struct ChatTreeSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var roots: [ChatTreeNode]

    public init(title: String? = nil, roots: [ChatTreeNode]) {
        self.title = title
        self.roots = roots
    }

    public var allExpandableIDs: Set<String> {
        roots.reduce(into: Set<String>()) { $0.formUnion($1.allExpandableIDs) }
    }

    public static func isTreeFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "tree"
    }

    public static func parse(_ code: String, info: String? = nil) -> Result<ChatTreeSpec, ChatVisualizationError> {
        let rawLines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [(indent: Int, label: String, annotation: String?, explicitFolder: Bool)] = []

        for raw in rawLines {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let (indent, cleaned) = parseIndentedLine(raw)
            guard !cleaned.isEmpty else { continue }
            let (rawLabel, annotation) = splitAnnotation(cleaned)
            let explicitFolder = rawLabel.hasSuffix("/")
            let displayLabel = explicitFolder ? String(rawLabel.dropLast()) : rawLabel
            guard !displayLabel.isEmpty else { continue }
            entries.append((indent, displayLabel, annotation, explicitFolder))
        }

        guard !entries.isEmpty else {
            return .failure(ChatVisualizationError("Tree block is empty."))
        }

        // Build nested hierarchy using an indent stack.
        struct Frame {
            var indent: Int
            var node: ChatTreeNode
        }
        var stack: [Frame] = []
        var roots: [ChatTreeNode] = []

        func popTo(indent: Int) {
            while let top = stack.last, top.indent >= indent {
                var finished = stack.removeLast().node
                if !finished.children.isEmpty { finished.isFolder = true }
                if !stack.isEmpty {
                    stack[stack.count - 1].node.children.append(finished)
                } else {
                    roots.append(finished)
                }
            }
        }

        for (idx, entry) in entries.enumerated() {
            popTo(indent: entry.indent)
            let node = ChatTreeNode(
                id: "n\(idx)",
                label: entry.label,
                annotation: entry.annotation,
                isFolder: entry.explicitFolder,
                children: []
            )
            stack.append(Frame(indent: entry.indent, node: node))
        }
        popTo(indent: -1)

        // Optional title from fence info string: ```tree Project Layout
        let metaTitle: String? = {
            let trimmed = (info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
            let rest = trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }()

        return .success(ChatTreeSpec(title: metaTitle, roots: roots))
    }

    private static func parseIndentedLine(_ raw: String) -> (indent: Int, content: String) {
        var indent = 0
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let ch = raw[idx]
            if ch == " " {
                indent += 1
                idx = raw.index(after: idx)
            } else if ch == "\t" {
                indent += 2
                idx = raw.index(after: idx)
            } else if ch == "│" || ch == "├" || ch == "└" || ch == "─" {
                indent += 1
                idx = raw.index(after: idx)
            } else {
                break
            }
        }
        var rest = String(raw[idx...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") {
            rest = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return (indent, rest)
    }

    private static func splitAnnotation(_ text: String) -> (String, String?) {
        for sep in [" — ", " -- ", " | ", " # "] {
            if let range = text.range(of: sep) {
                let lhs = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rhs = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !lhs.isEmpty && !rhs.isEmpty {
                    return (lhs, rhs)
                }
            }
        }
        return (text, nil)
    }
}

// MARK: - Before/After Image Comparison Slider (LAZYAGENTS-325)

public struct ChatImageRef: Sendable, Equatable, Hashable {
    public var raw: String
    public var primaryPath: String
    public var fallbackPath: String?

    public init(raw: String, primaryPath: String, fallbackPath: String? = nil) {
        self.raw = raw
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
    }

    public static func resolve(_ raw: String) -> ChatImageRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/api/v1/") {
            return ChatImageRef(raw: trimmed, primaryPath: trimmed)
        }
        if trimmed.lowercased().hasPrefix("library:") {
            let id = String(trimmed.dropFirst("library:".count)).trimmingCharacters(in: .whitespaces)
            guard ChatFenceParsers.isUUID(id) else { return nil }
            return ChatImageRef(raw: trimmed, primaryPath: "/api/v1/library/\(id.lowercased())/content")
        }
        if trimmed.lowercased().hasPrefix("attachment:") {
            let id = String(trimmed.dropFirst("attachment:".count)).trimmingCharacters(in: .whitespaces)
            guard ChatFenceParsers.isUUID(id) else { return nil }
            return ChatImageRef(raw: trimmed, primaryPath: "/api/v1/chat-attachments/\(id.lowercased())/content")
        }
        if ChatFenceParsers.isUUID(trimmed) {
            let id = trimmed.lowercased()
            return ChatImageRef(
                raw: trimmed,
                primaryPath: "/api/v1/library/\(id)/content",
                fallbackPath: "/api/v1/chat-attachments/\(id)/content"
            )
        }
        return nil
    }
}

public struct ChatCompareImagesSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var before: ChatImageRef
    public var after: ChatImageRef
    public var beforeLabel: String
    public var afterLabel: String

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        before: ChatImageRef,
        after: ChatImageRef,
        beforeLabel: String = "Before",
        afterLabel: String = "After"
    ) {
        self.title = title
        self.subtitle = subtitle
        self.before = before
        self.after = after
        self.beforeLabel = beforeLabel
        self.afterLabel = afterLabel
    }

    public static func isCompareImagesFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "compare-images"
    }

    public static func parse(_ code: String) -> Result<ChatCompareImagesSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This compare-images block isn't valid JSON."))
        }
        guard let beforeRaw = obj["before"]?.trimmedString, let beforeRef = ChatImageRef.resolve(beforeRaw) else {
            return .failure(ChatVisualizationError("compare-images needs a valid 'before' image reference (Library item ID, attachment ID, or /api/v1/ path)."))
        }
        guard let afterRaw = obj["after"]?.trimmedString, let afterRef = ChatImageRef.resolve(afterRaw) else {
            return .failure(ChatVisualizationError("compare-images needs a valid 'after' image reference (Library item ID, attachment ID, or /api/v1/ path)."))
        }
        return .success(ChatCompareImagesSpec(
            title: obj["title"]?.trimmedString,
            subtitle: obj["subtitle"]?.trimmedString,
            before: beforeRef,
            after: afterRef,
            beforeLabel: obj["beforeLabel"]?.trimmedString ?? obj["before_label"]?.trimmedString ?? "Before",
            afterLabel: obj["afterLabel"]?.trimmedString ?? obj["after_label"]?.trimmedString ?? "After"
        ))
    }
}
