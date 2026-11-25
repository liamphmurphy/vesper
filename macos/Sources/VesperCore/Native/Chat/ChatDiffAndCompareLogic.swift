import Foundation

// MARK: - Diff Block (LAZYAGENTS-318)

public struct ChatVisualizationError: Error, Sendable, Equatable, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension JSONValue {
    var boolVal: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleVal: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        default: return nil
        }
    }

    var objectVal: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayVal: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var trimmedString: String? {
        guard let raw = stringValue else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

public enum ChatDiffMode: String, Sendable, Equatable, Hashable {
    case code
    case prose
}

public enum ChatDiffLineKind: String, Sendable, Equatable, Hashable {
    case context
    case added
    case removed
    case hunkHeader
}

public struct ChatDiffWordSpan: Sendable, Equatable, Hashable {
    public var text: String
    public var changed: Bool

    public init(text: String, changed: Bool) {
        self.text = text
        self.changed = changed
    }
}

public struct ChatDiffLine: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var kind: ChatDiffLineKind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String
    public var wordSpans: [ChatDiffWordSpan]

    public init(
        id: Int,
        kind: ChatDiffLineKind,
        oldLine: Int? = nil,
        newLine: Int? = nil,
        text: String,
        wordSpans: [ChatDiffWordSpan] = []
    ) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
        self.wordSpans = wordSpans
    }
}

public struct ChatDiffSidePair: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var left: ChatDiffLine?
    public var right: ChatDiffLine?

    public init(id: Int, left: ChatDiffLine?, right: ChatDiffLine?) {
        self.id = id
        self.left = left
        self.right = right
    }
}

public enum ChatDiffChunk: Sendable, Equatable, Hashable, Identifiable {
    case line(ChatDiffLine)
    case collapsed(id: Int, lines: [ChatDiffLine])

    public var id: String {
        switch self {
        case .line(let l): "L\(l.id)"
        case .collapsed(let cid, _): "C\(cid)"
        }
    }
}

public struct ChatDiffSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var filename: String?
    public var language: String?
    public var mode: ChatDiffMode
    public var lines: [ChatDiffLine]
    public var additions: Int
    public var deletions: Int

    public init(
        title: String? = nil,
        filename: String? = nil,
        language: String? = nil,
        mode: ChatDiffMode = .code,
        lines: [ChatDiffLine],
        additions: Int,
        deletions: Int
    ) {
        self.title = title
        self.filename = filename
        self.language = language
        self.mode = mode
        self.lines = lines
        self.additions = additions
        self.deletions = deletions
    }

    public static func isDiffFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "diff"
    }

    /// Parses either a JSON `{before, after, language?, mode?, title?, filename?}` / `{diff, ...}` spec
    /// or a raw unified diff (`---`/`+++`/`@@` or `+`/`-` lines).
    public static func parse(_ code: String, info: String? = nil) -> Result<ChatDiffSpec, ChatVisualizationError> {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ChatVisualizationError("Diff block is empty."))
        }

        // Optional language hint in fence meta: ```diff go
        let metaLang: String? = {
            let parts = (info ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            return MarkdownSource.language(fromFence: String(parts[1])) ?? String(parts[1]).lowercased()
        }()

        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let root = try? JSONDecoder().decode(JSONValue.self, from: data),
                  case .object(let obj) = root
            else {
                return .failure(ChatVisualizationError("Diff JSON spec isn't valid JSON."))
            }

            let title = obj["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = obj["filename"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLang = obj["language"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let language = rawLang.flatMap { $0.isEmpty ? nil : (MarkdownSource.language(fromFence: $0) ?? $0.lowercased()) } ?? metaLang
            let mode: ChatDiffMode = (obj["mode"]?.stringValue?.lowercased() == "prose") ? .prose : .code

            if let unified = obj["diff"]?.stringValue ?? obj["patch"]?.stringValue {
                return parseUnified(unified, title: title, filename: filename, language: language, mode: mode)
            }
            guard let before = obj["before"]?.stringValue, let after = obj["after"]?.stringValue else {
                return .failure(ChatVisualizationError("Diff JSON spec needs either before/after strings or a diff string."))
            }
            return .success(buildFromPair(before: before, after: after, title: title, filename: filename, language: language, mode: mode))
        }

        return parseUnified(code, title: nil, filename: nil, language: metaLang, mode: .code)
    }

    public static func buildFromPair(
        before: String,
        after: String,
        title: String?,
        filename: String?,
        language: String?,
        mode: ChatDiffMode
    ) -> ChatDiffSpec {
        let oldLines = before.isEmpty ? [] : before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = after.isEmpty ? [] : after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let raw = diffLineSequences(old: oldLines, new: newLines)
        let enriched = enrichWordDiffs(raw)
        let adds = enriched.filter { $0.kind == .added }.count
        let dels = enriched.filter { $0.kind == .removed }.count
        return ChatDiffSpec(
            title: title?.isEmpty == true ? nil : title,
            filename: filename?.isEmpty == true ? nil : filename,
            language: language,
            mode: mode,
            lines: enriched,
            additions: adds,
            deletions: dels
        )
    }

    private static func parseUnified(
        _ text: String,
        title: String?,
        filename: String?,
        language: String?,
        mode: ChatDiffMode
    ) -> Result<ChatDiffSpec, ChatVisualizationError> {
        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [ChatDiffLine] = []
        var detectedFile = filename
        var oldNum = 1
        var newNum = 1
        var nextID = 0
        var hasDiffSignal = false

        for line in rawLines {
            if line.hasPrefix("diff --git ") || line.hasPrefix("index ") {
                hasDiffSignal = true
                continue
            }
            if line.hasPrefix("--- ") {
                hasDiffSignal = true
                continue
            }
            if line.hasPrefix("+++ ") {
                hasDiffSignal = true
                let candidate = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if detectedFile == nil, candidate != "/dev/null" {
                    detectedFile = candidate.hasPrefix("b/") ? String(candidate.dropFirst(2)) : candidate
                }
                continue
            }
            if line.hasPrefix("@@") {
                hasDiffSignal = true
                if let parsed = parseHunkHeader(line) {
                    oldNum = parsed.oldStart
                    newNum = parsed.newStart
                }
                out.append(ChatDiffLine(id: nextID, kind: .hunkHeader, text: line))
                nextID += 1
                continue
            }
            if line.hasPrefix("+") {
                hasDiffSignal = true
                out.append(ChatDiffLine(id: nextID, kind: .added, oldLine: nil, newLine: newNum, text: String(line.dropFirst())))
                newNum += 1
                nextID += 1
            } else if line.hasPrefix("-") {
                hasDiffSignal = true
                out.append(ChatDiffLine(id: nextID, kind: .removed, oldLine: oldNum, newLine: nil, text: String(line.dropFirst())))
                oldNum += 1
                nextID += 1
            } else if line.hasPrefix(" ") {
                out.append(ChatDiffLine(id: nextID, kind: .context, oldLine: oldNum, newLine: newNum, text: String(line.dropFirst())))
                oldNum += 1
                newNum += 1
                nextID += 1
            } else if !line.isEmpty {
                out.append(ChatDiffLine(id: nextID, kind: .context, oldLine: oldNum, newLine: newNum, text: line))
                oldNum += 1
                newNum += 1
                nextID += 1
            }
        }

        guard hasDiffSignal, !out.isEmpty else {
            return .failure(ChatVisualizationError("Diff block must contain unified diff lines (+/-, @@) or a JSON before/after spec."))
        }

        let enriched = enrichWordDiffs(out)
        let adds = enriched.filter { $0.kind == .added }.count
        let dels = enriched.filter { $0.kind == .removed }.count
        return .success(ChatDiffSpec(
            title: title?.isEmpty == true ? nil : title,
            filename: detectedFile,
            language: language,
            mode: mode,
            lines: enriched,
            additions: adds,
            deletions: dels
        ))
    }

    /// Collapses long unchanged runs (> threshold lines) while keeping `keepContext` lines around edits.
    public func collapsedChunks(threshold: Int = 7, keepContext: Int = 2) -> [ChatDiffChunk] {
        var chunks: [ChatDiffChunk] = []
        var contextRun: [ChatDiffLine] = []
        var nextCollapseID = 0

        func flushRun(isStart: Bool, isEnd: Bool) {
            guard !contextRun.isEmpty else { return }
            let lead = isStart ? 0 : keepContext
            let trail = isEnd ? 0 : keepContext
            if contextRun.count > threshold && contextRun.count > lead + trail + 2 {
                for l in contextRun.prefix(lead) { chunks.append(.line(l)) }
                let hidden = Array(contextRun[lead..<(contextRun.count - trail)])
                chunks.append(.collapsed(id: nextCollapseID, lines: hidden))
                nextCollapseID += 1
                for l in contextRun.suffix(trail) { chunks.append(.line(l)) }
            } else {
                for l in contextRun { chunks.append(.line(l)) }
            }
            contextRun.removeAll(keepingCapacity: true)
        }

        var seenChange = false
        for line in lines {
            if line.kind == .context {
                contextRun.append(line)
            } else {
                flushRun(isStart: !seenChange, isEnd: false)
                seenChange = true
                chunks.append(.line(line))
            }
        }
        flushRun(isStart: !seenChange, isEnd: true)
        return chunks
    }

    /// Builds side-by-side pairs aligning removed/added hunks row-for-row.
    public static func sideBySidePairs(from lines: [ChatDiffLine]) -> [ChatDiffSidePair] {
        var pairs: [ChatDiffSidePair] = []
        var i = 0
        var nextID = 0
        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .context, .hunkHeader:
                pairs.append(ChatDiffSidePair(id: nextID, left: line, right: line))
                nextID += 1
                i += 1
            case .removed, .added:
                var removed: [ChatDiffLine] = []
                var added: [ChatDiffLine] = []
                while i < lines.count && (lines[i].kind == .removed || lines[i].kind == .added) {
                    if lines[i].kind == .removed { removed.append(lines[i]) } else { added.append(lines[i]) }
                    i += 1
                }
                let count = max(removed.count, added.count)
                for k in 0..<count {
                    pairs.append(ChatDiffSidePair(
                        id: nextID,
                        left: k < removed.count ? removed[k] : nil,
                        right: k < added.count ? added[k] : nil
                    ))
                    nextID += 1
                }
            }
        }
        return pairs
    }

    /// Computes word-level diff spans between two strings (for prose diffs and changed-line pairs).
    public static func wordDiff(old: String, new: String) -> (oldSpans: [ChatDiffWordSpan], newSpans: [ChatDiffWordSpan]) {
        let a = tokenizeWords(old)
        let b = tokenizeWords(new)
        let ops = lcsDiff(a, b)
        var oldSpans: [ChatDiffWordSpan] = []
        var newSpans: [ChatDiffWordSpan] = []
        for op in ops {
            switch op {
            case .equal(let token):
                appendSpan(&oldSpans, text: token, changed: false)
                appendSpan(&newSpans, text: token, changed: false)
            case .delete(let token):
                appendSpan(&oldSpans, text: token, changed: true)
            case .insert(let token):
                appendSpan(&newSpans, text: token, changed: true)
            }
        }
        return (oldSpans, newSpans)
    }

    // MARK: - Private Diff Algorithms

    private enum DiffOp<T> {
        case equal(T)
        case delete(T)
        case insert(T)
    }

    private static func diffLineSequences(old: [String], new: [String]) -> [ChatDiffLine] {
        let ops = lcsDiff(old, new)
        var out: [ChatDiffLine] = []
        var oldNum = 1
        var newNum = 1
        for (idx, op) in ops.enumerated() {
            switch op {
            case .equal(let s):
                out.append(ChatDiffLine(id: idx, kind: .context, oldLine: oldNum, newLine: newNum, text: s))
                oldNum += 1; newNum += 1
            case .delete(let s):
                out.append(ChatDiffLine(id: idx, kind: .removed, oldLine: oldNum, newLine: nil, text: s))
                oldNum += 1
            case .insert(let s):
                out.append(ChatDiffLine(id: idx, kind: .added, oldLine: nil, newLine: newNum, text: s))
                newNum += 1
            }
        }
        return out
    }

    private static func enrichWordDiffs(_ lines: [ChatDiffLine]) -> [ChatDiffLine] {
        var out = lines
        var i = 0
        while i < out.count {
            if out[i].kind == .removed {
                var rIndices: [Int] = []
                var aIndices: [Int] = []
                while i < out.count && out[i].kind == .removed { rIndices.append(i); i += 1 }
                while i < out.count && out[i].kind == .added { aIndices.append(i); i += 1 }
                let pairCount = min(rIndices.count, aIndices.count)
                for k in 0..<pairCount {
                    let ri = rIndices[k], ai = aIndices[k]
                    let (oldS, newS) = wordDiff(old: out[ri].text, new: out[ai].text)
                    out[ri].wordSpans = oldS
                    out[ai].wordSpans = newS
                }
            } else {
                i += 1
            }
        }
        return out
    }

    private static func lcsDiff<T: Equatable>(_ a: [T], _ b: [T]) -> [DiffOp<T>] {
        let m = a.count, n = b.count
        if m == 0 { return b.map { .insert($0) } }
        if n == 0 { return a.map { .delete($0) } }
        // Guard very large inputs against O(m*n) memory blowup.
        if m * n > 250_000 {
            return a.map { .delete($0) } + b.map { .insert($0) }
        }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var ops: [DiffOp<T>] = []
        var i = 0, j = 0
        while i < m && j < n {
            if a[i] == b[j] {
                ops.append(.equal(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < m { ops.append(.delete(a[i])); i += 1 }
        while j < n { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false
        for ch in text {
            let ws = ch.isWhitespace
            if !current.isEmpty && ws != inWhitespace {
                tokens.append(current)
                current = ""
            }
            current.append(ch)
            inWhitespace = ws
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func appendSpan(_ spans: inout [ChatDiffWordSpan], text: String, changed: Bool) {
        if let last = spans.last, last.changed == changed {
            spans[spans.count - 1].text += text
        } else {
            spans.append(ChatDiffWordSpan(text: text, changed: changed))
        }
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        // @@ -12,4 +15,6 @@
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let oldStr = parts[1].dropFirst().split(separator: ",").first.map(String.init) ?? ""
        let newStr = parts[2].dropFirst().split(separator: ",").first.map(String.init) ?? ""
        guard let o = Int(oldStr), let n = Int(newStr) else { return nil }
        return (o, n)
    }
}

// MARK: - Compare / Weighted Decision Matrix (LAZYAGENTS-319)

public struct ChatCompareMatrixOption: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var subtitle: String?
    public var recommended: Bool

    public init(id: String, name: String, subtitle: String? = nil, recommended: Bool = false) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.recommended = recommended
    }
}

public struct ChatCompareCriterion: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var weight: Double?
    public var dealbreaker: Bool
    public var winner: String?
    public var values: [String: String]
    public var scores: [String: Double]

    public init(
        id: Int,
        name: String,
        weight: Double? = nil,
        dealbreaker: Bool = false,
        winner: String? = nil,
        values: [String: String] = [:],
        scores: [String: Double] = [:]
    ) {
        self.id = id
        self.name = name
        self.weight = weight
        self.dealbreaker = dealbreaker
        self.winner = winner
        self.values = values
        self.scores = scores
    }
}

public struct ChatCompareSpec: Sendable, Equatable, Hashable {
    public var title: String?
    public var subtitle: String?
    public var options: [ChatCompareMatrixOption]
    public var criteria: [ChatCompareCriterion]

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        options: [ChatCompareMatrixOption],
        criteria: [ChatCompareCriterion]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.options = options
        self.criteria = criteria
    }

    public var hasWeightsAndScores: Bool {
        criteria.contains { !$0.scores.isEmpty }
    }

    public var recommendedOption: ChatCompareMatrixOption? {
        options.first(where: \.recommended)
    }

    /// Computes live weighted totals per option ID given optional user-adjusted weight overrides.
    public func weightedTotals(weights: [Int: Double] = [:]) -> [String: Double] {
        var totals: [String: Double] = Dictionary(options.map { ($0.id, 0.0) }, uniquingKeysWith: { _, latest in latest })
        var weightSum = 0.0
        for c in criteria where !c.scores.isEmpty {
            let w = max(0, weights[c.id] ?? c.weight ?? 1.0)
            weightSum += w
            for opt in options {
                if let score = c.scores[opt.id] {
                    totals[opt.id, default: 0] += score * w
                }
            }
        }
        if weightSum > 0 {
            for opt in options {
                totals[opt.id] = (totals[opt.id] ?? 0) / weightSum
            }
        }
        return totals
    }

    public static func isCompareFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "compare"
    }

    public static func parse(_ code: String) -> Result<ChatCompareSpec, ChatVisualizationError> {
        guard let data = code.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = root
        else {
            return .failure(ChatVisualizationError("This compare block isn't valid JSON."))
        }

        guard case .array(let rawOptions) = obj["options"], rawOptions.count >= 2, rawOptions.count <= 10 else {
            return .failure(ChatVisualizationError("A compare block needs 2 to 10 options."))
        }
        var options: [ChatCompareMatrixOption] = []
        var seenOptionIDs: Set<String> = []
        for (idx, raw) in rawOptions.enumerated() {
            if case .string(let name) = raw {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return .failure(ChatVisualizationError("Option \(idx + 1) needs a name.")) }
                let id = clean
                if seenOptionIDs.insert(id).inserted {
                    options.append(ChatCompareMatrixOption(id: id, name: clean))
                }
            } else if case .object(let dict) = raw {
                let name = dict["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let id = dict["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
                guard !name.isEmpty, !id.isEmpty else {
                    return .failure(ChatVisualizationError("Option \(idx + 1) needs a name."))
                }
                if seenOptionIDs.insert(id).inserted {
                    options.append(ChatCompareMatrixOption(
                        id: id,
                        name: name,
                        subtitle: dict["subtitle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                        recommended: dict["recommended"]?.boolVal ?? false
                    ))
                }
            }
        }
        guard options.count >= 2 else {
            return .failure(ChatVisualizationError("A compare block needs at least 2 distinct options."))
        }

        guard case .array(let rawCriteria) = obj["criteria"], !rawCriteria.isEmpty, rawCriteria.count <= 40 else {
            return .failure(ChatVisualizationError("A compare block needs 1 to 40 criteria rows."))
        }

        var criteria: [ChatCompareCriterion] = []
        for (idx, raw) in rawCriteria.enumerated() {
            guard case .object(let dict) = raw,
                  let name = dict["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                return .failure(ChatVisualizationError("Criterion \(idx + 1) needs a name."))
            }
            let weight: Double? = {
                switch dict["weight"] {
                case .int(let i): return Double(i)
                case .double(let d): return d.isFinite ? d : nil
                default: return nil
                }
            }()
            let dealbreaker = dict["dealbreaker"]?.boolVal ?? false
            let winner = dict["winner"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

            var values: [String: String] = [:]
            if case .object(let valMap) = dict["values"] {
                for (k, v) in valMap {
                    values[k] = stringifyScalar(v)
                }
            }
            var scores: [String: Double] = [:]
            if case .object(let scoreMap) = dict["scores"] {
                for (k, v) in scoreMap {
                    switch v {
                    case .int(let i): scores[k] = Double(i)
                    case .double(let d) where d.isFinite: scores[k] = d
                    default: break
                    }
                }
            }

            criteria.append(ChatCompareCriterion(
                id: idx,
                name: name,
                weight: weight,
                dealbreaker: dealbreaker,
                winner: winner?.isEmpty == true ? nil : winner,
                values: values,
                scores: scores
            ))
        }

        return .success(ChatCompareSpec(
            title: obj["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: obj["subtitle"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            options: options,
            criteria: criteria
        ))
    }

    private static func stringifyScalar(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): ChatChartSpec.compactNumber(d)
        case .bool(let b): b ? "Yes" : "No"
        case .null: "—"
        default: ""
        }
    }
}
