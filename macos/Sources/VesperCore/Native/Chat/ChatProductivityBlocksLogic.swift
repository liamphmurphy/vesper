import Foundation

// MARK: - Interactive Data Table (LAZYAGENTS-328)

public enum ChatDataColumnType: String, Sendable, Equatable, Hashable {
    case text
    case number
    case currency
    case percent
    case duration
    case status
}

public struct ChatDataColumn: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var type: ChatDataColumnType
    public var currencySymbol: String

    public init(key: String, label: String, type: ChatDataColumnType = .text, currencySymbol: String = "$") {
        self.key = key
        self.label = label
        self.type = type
        self.currencySymbol = currencySymbol
    }
}

public enum ChatDataCellValue: Sendable, Equatable, Hashable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case empty

    public var sortNumber: Double? {
        switch self {
        case .number(let n): return n
        case .text(let s):
            let cleaned = s.replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        case .bool(let b): return b ? 1 : 0
        case .empty: return nil
        }
    }

    public var rawText: String {
        switch self {
        case .text(let s): s
        case .number(let d): ChatChartSpec.compactNumber(d)
        case .bool(let b): b ? "Yes" : "No"
        case .empty: ""
        }
    }

    public func formatted(for column: ChatDataColumn) -> String {
        switch self {
        case .empty:
            return "—"
        case .bool(let b):
            return b ? "Yes" : "No"
        case .number(let n):
            switch column.type {
            case .currency:
                let absStr = String(format: "%.2f", abs(n))
                return n < 0 ? "-\(column.currencySymbol)\(absStr)" : "\(column.currencySymbol)\(absStr)"
            case .percent:
                let pct = abs(n) <= 1.0 && n != 0 && abs(n) < 1.0 ? n * 100 : n
                return "\(ChatChartSpec.compactNumber(pct))%"
            case .duration:
                if abs(n) >= 60_000 { return String(format: "%.1fm", n / 60_000) }
                if abs(n) >= 1_000 { return String(format: "%.2fs", n / 1_000) }
                return "\(Int(n.rounded()))ms"
            default:
                return ChatChartSpec.compactNumber(n)
            }
        case .text(let s):
            return s.isEmpty ? "—" : s
        }
    }
}

public struct ChatDataTableSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var columns: [ChatDataColumn]
    public var rows: [[String: ChatDataCellValue]]

    public init(title: String? = nil, subtitle: String? = nil, columns: [ChatDataColumn], rows: [[String: ChatDataCellValue]]) {
        self.title = title
        self.subtitle = subtitle
        self.columns = columns
        self.rows = rows
    }

    public static func isDataTableFence(_ info: String?) -> Bool {
        let w = ChatFenceParsers.firstWord(of: info)
        return w == "datatable" || w == "data-table"
    }

    public func filteredAndSorted(query: String, sortKey: String?, ascending: Bool) -> [[String: ChatDataCellValue]] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = rows
        if !q.isEmpty {
            out = out.filter { row in
                columns.contains { col in
                    let val = row[col.key] ?? .empty
                    return val.formatted(for: col).lowercased().contains(q)
                        || val.rawText.lowercased().contains(q)
                }
            }
        }
        if let sortKey, let col = columns.first(where: { $0.key == sortKey }) {
            out.sort { a, b in
                let va = a[col.key] ?? .empty
                let vb = b[col.key] ?? .empty
                let cmp: Bool
                if let na = va.sortNumber, let nb = vb.sortNumber {
                    cmp = na < nb
                } else {
                    cmp = va.formatted(for: col).localizedCaseInsensitiveCompare(vb.formatted(for: col)) == .orderedAscending
                }
                return ascending ? cmp : !cmp
            }
        }
        return out
    }

    public func csvText() -> String {
        func escape(_ cell: String) -> String {
            if cell.contains(",") || cell.contains("\"") || cell.contains("\n") {
                return "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return cell
        }
        let header = columns.map { escape($0.label) }.joined(separator: ",")
        let body = rows.map { row in
            columns.map { col in
                escape((row[col.key] ?? .empty).formatted(for: col))
            }.joined(separator: ",")
        }
        return ([header] + body).joined(separator: "\n")
    }

    public static func parse(_ code: String) -> Result<ChatDataTableSpec, ChatVisualizationError> {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ChatVisualizationError("Data table block is empty."))
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return parseJSON(trimmed)
        }
        return parseCSV(trimmed)
    }

    private static func parseJSON(_ trimmed: String) -> Result<ChatDataTableSpec, ChatVisualizationError> {
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .failure(ChatVisualizationError("This datatable block isn't valid JSON."))
        }
        let obj = root.objectVal ?? [:]
        let rawRows: [JSONValue]
        if let arr = obj["rows"]?.arrayVal {
            rawRows = arr
        } else if let arr = root.arrayVal {
            rawRows = arr
        } else {
            rawRows = []
        }

        var columns: [ChatDataColumn] = []
        if let rawCols = obj["columns"]?.arrayVal {
            for (idx, raw) in rawCols.enumerated() {
                if let name = raw.trimmedString {
                    columns.append(ChatDataColumn(key: name, label: name))
                } else if let c = raw.objectVal, let key = c["key"]?.trimmedString ?? c["label"]?.trimmedString {
                    let label = c["label"]?.trimmedString ?? key
                    let type = ChatDataColumnType(rawValue: (c["type"]?.trimmedString ?? "text").lowercased()) ?? .text
                    let sym = c["currency"]?.trimmedString ?? "$"
                    columns.append(ChatDataColumn(key: key, label: label, type: type, currencySymbol: sym))
                } else {
                    return .failure(ChatVisualizationError("Column \(idx + 1) needs a key or label."))
                }
            }
        } else if let firstObj = rawRows.first?.objectVal {
            for key in firstObj.keys.sorted() {
                columns.append(ChatDataColumn(key: key, label: key))
            }
        }

        guard !columns.isEmpty, columns.count <= 24 else {
            return .failure(ChatVisualizationError("A datatable needs 1 to 24 columns."))
        }
        guard !rawRows.isEmpty, rawRows.count <= 500 else {
            return .failure(ChatVisualizationError("A datatable needs 1 to 500 rows."))
        }

        var rows: [[String: ChatDataCellValue]] = []
        for raw in rawRows {
            var row: [String: ChatDataCellValue] = [:]
            if let dict = raw.objectVal {
                for col in columns {
                    row[col.key] = cellValue(dict[col.key])
                }
            } else if let arr = raw.arrayVal {
                for (i, col) in columns.enumerated() where i < arr.count {
                    row[col.key] = cellValue(arr[i])
                }
            } else {
                return .failure(ChatVisualizationError("Each datatable row must be a JSON object or array."))
            }
            rows.append(row)
        }

        return .success(ChatDataTableSpec(
            title: obj["title"]?.trimmedString,
            subtitle: obj["subtitle"]?.trimmedString,
            columns: columns,
            rows: rows
        ))
    }

    private static func parseCSV(_ text: String) -> Result<ChatDataTableSpec, ChatVisualizationError> {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2 else {
            return .failure(ChatVisualizationError("CSV datatable needs a header line and at least one data row."))
        }
        let headerCells = splitCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces) }
        guard headerCells.count >= 2, headerCells.allSatisfy({ !$0.isEmpty }) else {
            return .failure(ChatVisualizationError("CSV datatable header needs at least 2 named columns."))
        }
        let columns = headerCells.map { ChatDataColumn(key: $0, label: $0) }
        var rows: [[String: ChatDataCellValue]] = []
        for line in lines.dropFirst().prefix(500) {
            let vals = splitCSVLine(line)
            var row: [String: ChatDataCellValue] = [:]
            for (i, col) in columns.enumerated() {
                let raw = i < vals.count ? vals[i].trimmingCharacters(in: .whitespaces) : ""
                if raw.isEmpty {
                    row[col.key] = .empty
                } else if let d = Double(raw), d.isFinite {
                    row[col.key] = .number(d)
                } else {
                    row[col.key] = .text(raw)
                }
            }
            rows.append(row)
        }
        return .success(ChatDataTableSpec(columns: columns, rows: rows))
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\""); i += 2; continue
                }
                inQuotes.toggle(); i += 1; continue
            }
            if ch == "," && !inQuotes {
                cells.append(current); current = ""; i += 1; continue
            }
            current.append(ch); i += 1
        }
        cells.append(current)
        return cells
    }

    private static func cellValue(_ v: JSONValue?) -> ChatDataCellValue {
        guard let v else { return .empty }
        switch v {
        case .string(let s): return s.isEmpty ? .empty : .text(s)
        case .int(let i): return .number(Double(i))
        case .double(let d): return d.isFinite ? .number(d) : .empty
        case .bool(let b): return .bool(b)
        case .null: return .empty
        default: return .text(String(describing: v))
        }
    }
}

// MARK: - Tabbed Code Group (LAZYAGENTS-329)

public struct ChatCodeTab: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var language: String?
    public var code: String
    /// 1-based highlighted line numbers.
    public var highlightedLines: Set<Int>

    public init(id: Int, label: String, language: String? = nil, code: String, highlightedLines: Set<Int> = []) {
        self.id = id
        self.label = label
        self.language = language
        self.code = code
        self.highlightedLines = highlightedLines
    }
}

public struct ChatCodeGroupSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var tabs: [ChatCodeTab]

    public init(title: String? = nil, tabs: [ChatCodeTab]) {
        self.title = title
        self.tabs = tabs
    }

    public static func isCodeGroupFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "code-group"
    }

    public static func parse(_ code: String) -> Result<ChatCodeGroupSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This code-group block isn't valid JSON."))
        }
        guard let rawTabs = obj["tabs"]?.arrayVal ?? obj["files"]?.arrayVal, !rawTabs.isEmpty, rawTabs.count <= 12 else {
            return .failure(ChatVisualizationError("A code-group block needs 1 to 12 tabs."))
        }
        var tabs: [ChatCodeTab] = []
        for (idx, raw) in rawTabs.enumerated() {
            guard let t = raw.objectVal,
                  let label = t["label"]?.trimmedString ?? t["path"]?.trimmedString ?? t["filename"]?.trimmedString,
                  let snippet = t["code"]?.stringValue
            else {
                return .failure(ChatVisualizationError("Code tab \(idx + 1) needs a label and code string."))
            }
            let rawLang = t["language"]?.trimmedString ?? t["lang"]?.trimmedString ?? inferLanguage(from: label)
            let normalizedLang = rawLang.flatMap { MarkdownSource.language(fromFence: $0) ?? $0.lowercased() }
            let highlights = parseLineRanges(t["highlight"] ?? t["highlights"])
            tabs.append(ChatCodeTab(id: idx, label: label, language: normalizedLang, code: snippet, highlightedLines: highlights))
        }
        return .success(ChatCodeGroupSpec(title: obj["title"]?.trimmedString, tabs: tabs))
    }

    public static func parseLineRanges(_ raw: JSONValue?) -> Set<Int> {
        guard let arr = raw?.arrayVal else { return [] }
        var out: Set<Int> = []
        for entry in arr {
            if case .int(let n) = entry, n > 0 {
                out.insert(n)
            } else if let str = entry.trimmedString {
                let parts = str.split(separator: "-")
                if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]), lo > 0, hi >= lo, hi - lo <= 200 {
                    for line in lo...hi { out.insert(line) }
                } else if let single = Int(str), single > 0 {
                    out.insert(single)
                }
            }
        }
        return out
    }

    private static func inferLanguage(from filename: String) -> String? {
        guard let dot = filename.lastIndex(of: ".") else { return nil }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }
}

// MARK: - Structured Key-Value Spec Card (LAZYAGENTS-330)

public struct ChatKVItem: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var key: String
    public var value: String
    public var tone: String?
    public var mono: Bool
    public var section: String?

    public init(id: Int, key: String, value: String, tone: String? = nil, mono: Bool = false, section: String? = nil) {
        self.id = id
        self.key = key
        self.value = value
        self.tone = tone
        self.mono = mono
        self.section = section
    }
}

public struct ChatKVSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var items: [ChatKVItem]

    public init(title: String? = nil, subtitle: String? = nil, items: [ChatKVItem]) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }

    public static func isKVFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "kv"
    }

    public static func parse(_ code: String) -> Result<ChatKVSpec, ChatVisualizationError> {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ChatVisualizationError("KV block is empty."))
        }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let root = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let obj) = root
            else {
                return .failure(ChatVisualizationError("This kv block isn't valid JSON."))
            }
            var items: [ChatKVItem] = []
            if let rawItems = obj["items"]?.arrayVal {
                for (idx, raw) in rawItems.enumerated() {
                    guard let entry = raw.objectVal,
                          let key = entry["key"]?.trimmedString ?? entry["label"]?.trimmedString,
                          let val = entry["value"]
                    else {
                        return .failure(ChatVisualizationError("KV item \(idx + 1) needs a key and value."))
                    }
                    items.append(ChatKVItem(
                        id: idx,
                        key: key,
                        value: stringifyValue(val),
                        tone: entry["tone"]?.trimmedString,
                        mono: entry["mono"]?.boolVal ?? false,
                        section: entry["section"]?.trimmedString
                    ))
                }
            } else {
                // Allow flat object `{ "Host": "localhost", "Port": 5432 }`
                for (idx, key) in obj.keys.sorted().enumerated() where key != "title" && key != "subtitle" {
                    if let val = obj[key] {
                        items.append(ChatKVItem(id: idx, key: key, value: stringifyValue(val)))
                    }
                }
            }
            guard !items.isEmpty else {
                return .failure(ChatVisualizationError("KV block needs at least one key-value item."))
            }
            return .success(ChatKVSpec(title: obj["title"]?.trimmedString, subtitle: obj["subtitle"]?.trimmedString, items: items))
        }

        // Plain `Key: Value` text lines with optional `[Section]` headers
        var items: [ChatKVItem] = []
        var section: String?
        for rawLine in trimmed.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") && line.count > 2 {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !v.isEmpty {
                items.append(ChatKVItem(id: items.count, key: k, value: v, section: section))
            }
        }
        guard !items.isEmpty else {
            return .failure(ChatVisualizationError("KV block needs JSON items or 'Key: Value' lines."))
        }
        return .success(ChatKVSpec(items: items))
    }

    private static func stringifyValue(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): ChatChartSpec.compactNumber(d)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: ""
        }
    }
}

// MARK: - Collapsible JSON Tree & HTTP Card (LAZYAGENTS-331)

public enum ChatJSONKind: String, Sendable, Equatable, Hashable {
    case object, array, string, number, bool, null
}

public struct ChatJSONTreeNode: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var key: String?
    public var kind: ChatJSONKind
    public var scalarDisplay: String?
    public var children: [ChatJSONTreeNode]

    public init(path: String, key: String?, kind: ChatJSONKind, scalarDisplay: String? = nil, children: [ChatJSONTreeNode] = []) {
        self.path = path
        self.key = key
        self.kind = kind
        self.scalarDisplay = scalarDisplay
        self.children = children
    }

    public var isContainer: Bool { kind == .object || kind == .array }

    public var summaryBadge: String {
        switch kind {
        case .object: "{\(children.count)}"
        case .array: "[\(children.count)]"
        default: scalarDisplay ?? ""
        }
    }

    public func matches(query: String) -> Bool {
        if query.isEmpty { return true }
        if let k = key, k.lowercased().contains(query) { return true }
        if let s = scalarDisplay, s.lowercased().contains(query) { return true }
        if path.lowercased().contains(query) { return true }
        return children.contains { $0.matches(query: query) }
    }

    public static func build(from value: JSONValue, key: String? = nil, path: String = "$") -> ChatJSONTreeNode {
        switch value {
        case .object(let dict):
            let kids = dict.keys.sorted().map { k in
                let childPath = "\(path).\(k)"
                return build(from: dict[k] ?? .null, key: k, path: childPath)
            }
            return ChatJSONTreeNode(path: path, key: key, kind: .object, children: kids)
        case .array(let arr):
            let kids = arr.enumerated().map { idx, el in
                build(from: el, key: "[\(idx)]", path: "\(path)[\(idx)]")
            }
            return ChatJSONTreeNode(path: path, key: key, kind: .array, children: kids)
        case .string(let s):
            return ChatJSONTreeNode(path: path, key: key, kind: .string, scalarDisplay: "\"\(s)\"")
        case .int(let i):
            return ChatJSONTreeNode(path: path, key: key, kind: .number, scalarDisplay: String(i))
        case .double(let d):
            return ChatJSONTreeNode(path: path, key: key, kind: .number, scalarDisplay: ChatChartSpec.compactNumber(d))
        case .bool(let b):
            return ChatJSONTreeNode(path: path, key: key, kind: .bool, scalarDisplay: b ? "true" : "false")
        case .null:
            return ChatJSONTreeNode(path: path, key: key, kind: .null, scalarDisplay: "null")
        }
    }
}

public struct ChatJSONTreeSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var root: ChatJSONTreeNode
    public var rawSource: String

    public init(title: String? = nil, root: ChatJSONTreeNode, rawSource: String) {
        self.title = title
        self.root = root
        self.rawSource = rawSource
    }

    public static func isJSONTreeFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "json-tree"
    }

    public static func parse(_ code: String, info: String? = nil) -> Result<ChatJSONTreeSpec, ChatVisualizationError> {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let val = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .failure(ChatVisualizationError("This json-tree block isn't valid JSON."))
        }
        let metaTitle: String? = {
            let t = (info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sp = t.firstIndex(where: \.isWhitespace) else { return nil }
            let rest = t[sp...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }()
        return .success(ChatJSONTreeSpec(title: metaTitle, root: ChatJSONTreeNode.build(from: val), rawSource: trimmed))
    }
}

public struct ChatHTTPHeader: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(name):\(value)" }
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ChatHTTPSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var method: String
    public var url: String
    public var status: Int?
    public var durationMs: Int?
    public var sizeBytes: Int?
    public var headers: [ChatHTTPHeader]
    public var jsonBody: ChatJSONTreeNode?
    public var textBody: String?

    public init(
        title: String? = nil,
        method: String,
        url: String,
        status: Int? = nil,
        durationMs: Int? = nil,
        sizeBytes: Int? = nil,
        headers: [ChatHTTPHeader] = [],
        jsonBody: ChatJSONTreeNode? = nil,
        textBody: String? = nil
    ) {
        self.title = title
        self.method = method
        self.url = url
        self.status = status
        self.durationMs = durationMs
        self.sizeBytes = sizeBytes
        self.headers = headers
        self.jsonBody = jsonBody
        self.textBody = textBody
    }

    public static func isHTTPFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "http"
    }

    public static func parse(_ code: String) -> Result<ChatHTTPSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This http block isn't valid JSON."))
        }
        guard let method = obj["method"]?.trimmedString?.uppercased(),
              let url = obj["url"]?.trimmedString
        else {
            return .failure(ChatVisualizationError("An http block needs 'method' and 'url'."))
        }
        let status = obj["status"]?.doubleVal.map { Int($0.rounded()) }
        let durationMs = (obj["durationMs"] ?? obj["duration_ms"])?.doubleVal.map { Int($0.rounded()) }
        let sizeBytes = (obj["sizeBytes"] ?? obj["size_bytes"])?.doubleVal.map { Int($0.rounded()) }

        var headers: [ChatHTTPHeader] = []
        if let hObj = obj["headers"]?.objectVal {
            for k in hObj.keys.sorted() {
                if let v = hObj[k] {
                    let s: String = {
                        switch v {
                        case .string(let str): return str
                        case .int(let i): return String(i)
                        case .double(let d): return ChatChartSpec.compactNumber(d)
                        case .bool(let b): return b ? "true" : "false"
                        default: return ""
                        }
                    }()
                    headers.append(ChatHTTPHeader(name: k, value: s))
                }
            }
        }

        var jsonBody: ChatJSONTreeNode?
        var textBody: String?
        if let bodyVal = obj["body"] {
            switch bodyVal {
            case .object, .array:
                jsonBody = ChatJSONTreeNode.build(from: bodyVal)
            case .string(let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
                   let bd = trimmed.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(JSONValue.self, from: bd) {
                    jsonBody = ChatJSONTreeNode.build(from: parsed)
                } else {
                    textBody = s
                }
            case .null:
                break
            default:
                textBody = String(describing: bodyVal)
            }
        }

        return .success(ChatHTTPSpec(
            title: obj["title"]?.trimmedString,
            method: method,
            url: url,
            status: status,
            durationMs: durationMs,
            sizeBytes: sizeBytes,
            headers: headers,
            jsonBody: jsonBody,
            textBody: textBody
        ))
    }
}

// MARK: - Tabs & Collapsible Details Blocks (LAZYAGENTS-332)

public struct ChatMarkdownTab: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var label: String
    public var body: String

    public init(id: Int, label: String, body: String) {
        self.id = id
        self.label = label
        self.body = body
    }
}

public struct ChatTabsSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var tabs: [ChatMarkdownTab]

    public init(title: String? = nil, tabs: [ChatMarkdownTab]) {
        self.title = title
        self.tabs = tabs
    }

    public static func isTabsFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "tabs"
    }

    public static func parse(_ code: String) -> Result<ChatTabsSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root,
              let rawTabs = obj["tabs"]?.arrayVal,
              !rawTabs.isEmpty, rawTabs.count <= 10
        else {
            return .failure(ChatVisualizationError("A tabs block needs JSON with 1 to 10 tabs."))
        }
        var tabs: [ChatMarkdownTab] = []
        for (idx, raw) in rawTabs.enumerated() {
            guard let t = raw.objectVal,
                  let label = t["label"]?.trimmedString ?? t["title"]?.trimmedString,
                  let body = t["body"]?.stringValue ?? t["content"]?.stringValue
            else {
                return .failure(ChatVisualizationError("Tab \(idx + 1) needs a label and markdown body."))
            }
            tabs.append(ChatMarkdownTab(id: idx, label: label, body: body))
        }
        return .success(ChatTabsSpec(title: obj["title"]?.trimmedString, tabs: tabs))
    }
}

public struct ChatDetailsSpec: Sendable, Equatable, Hashable {
    public var summary: String
    public var body: String
    public var defaultOpen: Bool

    public init(summary: String, body: String, defaultOpen: Bool = false) {
        self.summary = summary
        self.body = body
        self.defaultOpen = defaultOpen
    }

    public static func isDetailsFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "details"
    }

    public static func parse(_ code: String, info: String? = nil) -> Result<ChatDetailsSpec, ChatVisualizationError> {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ChatVisualizationError("Details block is empty."))
        }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let root = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let obj) = root,
                  let summary = obj["summary"]?.trimmedString ?? obj["title"]?.trimmedString,
                  let body = obj["body"]?.stringValue ?? obj["content"]?.stringValue
            else {
                return .failure(ChatVisualizationError("Details JSON needs 'summary' and 'body'."))
            }
            return .success(ChatDetailsSpec(summary: summary, body: body, defaultOpen: obj["open"]?.boolVal ?? false))
        }

        // Fence header summary: ```details Show derivation
        let metaSummary: String? = {
            let t = (info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sp = t.firstIndex(where: \.isWhitespace) else { return nil }
            let rest = t[sp...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : rest
        }()
        if let metaSummary {
            return .success(ChatDetailsSpec(summary: metaSummary, body: trimmed, defaultOpen: false))
        }

        // First-line summary separated by `---`
        let parts = trimmed.components(separatedBy: "\n---\n")
        if parts.count >= 2 {
            let summary = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty && !body.isEmpty {
                return .success(ChatDetailsSpec(summary: summary, body: body, defaultOpen: false))
            }
        }
        return .failure(ChatVisualizationError("Details block needs JSON {\"summary\",\"body\"} or a summary in the fence header."))
    }
}
