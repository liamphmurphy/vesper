import Foundation

// MARK: - Context Markers & Work Context (`web/lib/chat-context.ts`, `web/lib/work-context.ts`)

public enum ChatContextMarker {
    public static let work = "\n\n<!-- vesper:work-context -->\n"
    public static let knowledge = "\n\n<!-- vesper:knowledge-context -->\n"
    public static let customApp = "\n\n<!-- vesper:custom-app-context -->\n"
    static let all = [knowledge, work, customApp]
}

public struct ChatStrippedContext: Sendable, Equatable, Hashable {
    public var typedBody: String
    public var workContextLines: [String]
    public var knowledgeContextLines: [String]
    public var customAppContextLines: [String]

    public init(
        typedBody: String,
        workContextLines: [String] = [],
        knowledgeContextLines: [String] = [],
        customAppContextLines: [String] = []
    ) {
        self.typedBody = typedBody
        self.workContextLines = workContextLines
        self.knowledgeContextLines = knowledgeContextLines
        self.customAppContextLines = customAppContextLines
    }
}

public enum ChatWorkSubject: Sendable, Equatable, Hashable {
    case run(id: String, title: String, agent: String, ticketKey: String?)
    case ticket(key: String, title: String)

    public func contextLine(pinned: Bool = false) -> String {
        let verb = pinned ? "Pinned" : "Viewing"
        switch self {
        case .ticket(let key, let title):
            return "\(verb) ticket \(key) (“\(title)”)."
        case .run(let id, let title, let agent, let ticketKey):
            let suffix = ticketKey.map { " for ticket \($0)" } ?? ""
            return "\(verb) run \(id) (“\(title)”) by \(agent)\(suffix)."
        }
    }

    public var label: String {
        switch self {
        case .ticket(let key, let title): return "\(key) · \(title)"
        case .run(_, let title, _, let ticketKey): return ticketKey.map { "\($0) · \(title)" } ?? title
        }
    }

    public static func withWorkContext(_ body: String, viewing: ChatWorkSubject?, pinned: ChatWorkSubject? = nil) -> String {
        let same = pinned != nil && viewing != nil && pinned == viewing
        var lines: [String] = []
        if let pinned, !same { lines.append(pinned.contextLine(pinned: true)) }
        if let viewing { lines.append(viewing.contextLine(pinned: same)) }
        guard !lines.isEmpty else { return body }
        let suffix = ChatContextMarker.work + lines.joined(separator: "\n")
        return body.hasSuffix(suffix) ? body : body + suffix
    }
}

// MARK: - Sources & Citations (`web/lib/chat-sources.ts`)

public struct ChatListedSource: Sendable, Equatable, Hashable {
    public var title: String
    public var url: String
    public var number: Int?
    public var ref: String?

    public init(title: String, url: String, number: Int? = nil, ref: String? = nil) {
        self.title = title
        self.url = url
        self.number = number
        self.ref = ref
    }
}

// MARK: - Transcript Segments

public enum ChatMessageSegment: Sendable, Equatable {
    case markdown(String)
    case embedded(EmbeddedBlockKind, source: String, info: String?, index: Int)
    case chart(ChatChartSpec)
    case choices(ChatChoicesCard)
    case dispatch(ChatDispatchCard)
    case recommend([ChatRecommendCard])
    case workflowRun(ChatWorkflowRunCard)
    case canvas(id: String)
    case pdf(id: String)
    case researchPlan(ChatResearchPlanCard)
}

public struct ParsedChatMessage: Sendable, Equatable {
    public var typedBody: String
    public var context: ChatStrippedContext
    public var segments: [ChatMessageSegment]
    public var sources: [ChatListedSource]
    public var mentions: [String]

    public var hasDispatchSegment: Bool {
        segments.contains { if case .dispatch = $0 { return true }; return false }
    }

    public var hasWorkflowRunSegment: Bool {
        segments.contains { if case .workflowRun = $0 { return true }; return false }
    }

    public var hasCanvasSegment: Bool {
        segments.contains { if case .canvas = $0 { return true }; return false }
    }

    public init(
        typedBody: String,
        context: ChatStrippedContext,
        segments: [ChatMessageSegment],
        sources: [ChatListedSource] = [],
        mentions: [String] = []
    ) {
        self.typedBody = typedBody
        self.context = context
        self.segments = segments
        self.sources = sources
        self.mentions = mentions
    }
}

public enum ChatTranscriptLogic {
    public static let citeScheme = "cite:"

    // MARK: Context Stripping

    /// Splits appended dock context markers (`work-context`, `knowledge-context`, `custom-app-context`) from the user's typed text.
    public static func stripContext(_ body: String) -> ChatStrippedContext {
        struct MarkerHit { let kind: String; let range: Range<String.Index> }
        var hits: [MarkerHit] = []
        for (kind, marker) in [("work", ChatContextMarker.work), ("knowledge", ChatContextMarker.knowledge), ("customApp", ChatContextMarker.customApp)] {
            if let range = body.range(of: marker) {
                hits.append(MarkerHit(kind: kind, range: range))
            }
        }
        guard !hits.isEmpty else { return ChatStrippedContext(typedBody: body) }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }

        let typed = String(body[..<hits[0].range.lowerBound])
        var work: [String] = []
        var knowledge: [String] = []
        var customApp: [String] = []

        for (i, hit) in hits.enumerated() {
            let end = i + 1 < hits.count ? hits[i + 1].range.lowerBound : body.endIndex
            let lines = body[hit.range.upperBound..<end]
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            switch hit.kind {
            case "work": work.append(contentsOf: lines)
            case "knowledge": knowledge.append(contentsOf: lines)
            default: customApp.append(contentsOf: lines)
            }
        }
        return ChatStrippedContext(
            typedBody: typed,
            workContextLines: work,
            knowledgeContextLines: knowledge,
            customAppContextLines: customApp
        )
    }

    // MARK: Sources Extraction & Citations

    public static func splitSourceList(_ markdown: String) -> (body: String, sources: [ChatListedSource]) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var collected: [[ChatListedSource]] = []

        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let heading = matchSourcesHeading(line) {
                let inline = lineSources(heading.remainder)
                if !heading.remainder.isEmpty && inline.isEmpty { break }
                let listed = inline + collected.reversed().flatMap { $0 }
                if listed.isEmpty { break }
                var end = i
                while end > 0 && (lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty || isThematicRule(lines[end - 1])) {
                    end -= 1
                }
                let body = lines[0..<end].joined(separator: "\n")
                return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (markdown, []) : (body, listed)
            }
            let found = lineSources(line)
            if found.isEmpty { break }
            collected.append(found)
        }
        return (markdown, [])
    }

    public static func linkCitations(_ markdown: String, numbers: [Int]) -> String {
        let known = Set(numbers)
        guard !known.isEmpty else { return markdown }
        var fenceChar: Character?
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.map { line in
            if let opener = parseFenceOpener(line) {
                if fenceChar == nil { fenceChar = opener.char; return line }
                if fenceChar == opener.char && opener.info.trimmingCharacters(in: .whitespaces).isEmpty {
                    fenceChar = nil; return line
                }
            }
            if fenceChar != nil { return line }
            return linkCitationsInLine(line, known: known)
        }.joined(separator: "\n")
    }

    public static func summaryText(_ markdown: String) -> String {
        let body = splitSourceList(markdown).body
        var out = ""
        let chars = Array(body)
        var i = 0
        while i < chars.count {
            if chars[i] == "[" {
                if let (endIdx, _) = matchCitationBracket(chars, at: i),
                   !(endIdx + 1 < chars.count && (chars[endIdx + 1] == "(" || chars[endIdx + 1] == ":")) {
                    if out.last == " " { out.removeLast() }
                    i = endIdx + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func sourceSplitLabel(vesper: Int, web: Int) -> String {
        if vesper > 0 && web > 0 { return "\(vesper) in Vesper · \(web) from the web" }
        return vesper > 0 ? "in Vesper" : "from the web"
    }

    // MARK: Message Segment Parser (Linear Single-Pass)

    public static func parseMessage(
        _ rawBody: String,
        extractSources: Bool = true,
        knownPersonaNames: [String] = []
    ) -> ParsedChatMessage {
        let context = stripContext(rawBody)
        let (bodyWithoutSources, sources) = extractSources ? splitSourceList(context.typedBody) : (context.typedBody, [])
        let numberedCitations = sources.compactMap(\.number)
        let mentions = parseMentions(in: bodyWithoutSources, knownNames: knownPersonaNames)
        let segments = parseSegments(bodyWithoutSources, citationNumbers: numberedCitations)
        return ParsedChatMessage(
            typedBody: context.typedBody,
            context: context,
            segments: segments,
            sources: sources,
            mentions: mentions
        )
    }

    public static func parseSegments(_ markdown: String, citationNumbers: [Int] = []) -> [ChatMessageSegment] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [ChatMessageSegment] = []
        var mdBuffer: [String] = []
        var embedIndex = 0

        func flushMarkdown() {
            guard !mdBuffer.isEmpty else { return }
            let joined = mdBuffer.joined(separator: "\n")
            mdBuffer.removeAll(keepingCapacity: true)
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let text = citationNumbers.isEmpty ? joined : linkCitations(joined, numbers: citationNumbers)
            segments.append(.markdown(text))
        }

        func appendRecommend(_ card: ChatRecommendCard) {
            let gapIsWhitespaceOnly = mdBuffer.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if gapIsWhitespaceOnly, case .recommend(var existing) = segments.last {
                mdBuffer.removeAll(keepingCapacity: true)
                existing.append(card)
                segments[segments.count - 1] = .recommend(existing)
            } else {
                flushMarkdown()
                segments.append(.recommend([card]))
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Standalone $$ display math block
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "$$" {
                var j = i + 1
                var mathLines: [String] = []
                var closed = false
                while j < lines.count {
                    if lines[j].trimmingCharacters(in: .whitespaces) == "$$" {
                        closed = true
                        break
                    }
                    mathLines.append(lines[j])
                    j += 1
                }
                if closed {
                    let source = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !source.isEmpty {
                        flushMarkdown()
                        segments.append(.embedded(.math, source: source, info: "math", index: embedIndex))
                        embedIndex += 1
                        i = j + 1
                        continue
                    }
                }
            }

            if let opener = parseFenceOpener(line) {
                var j = i + 1
                var codeLines: [String] = []
                while j < lines.count {
                    if isFenceCloser(lines[j], char: opener.char, minLength: opener.length) {
                        break
                    }
                    codeLines.append(lines[j])
                    j += 1
                }
                let code = codeLines.joined(separator: "\n")
                let infoTrimmed = opener.info.trimmingCharacters(in: .whitespaces)
                let infoOpt: String? = infoTrimmed.isEmpty ? nil : infoTrimmed
                let nextIndex = j < lines.count ? j + 1 : lines.count

                if let kind = EmbeddedBlockKind.classify(info: infoOpt) {
                    flushMarkdown()
                    segments.append(.embedded(kind, source: code, info: infoOpt, index: embedIndex))
                    embedIndex += 1
                    i = nextIndex
                    continue
                }
                if ChatChartSpec.isChartFence(infoOpt), case .success(let spec) = ChatChartSpec.parse(code) {
                    flushMarkdown()
                    segments.append(.chart(spec))
                    i = nextIndex
                    continue
                }
                if ChatChoicesCard.isChoicesFence(infoOpt), let card = ChatChoicesCard.parse(code) {
                    flushMarkdown()
                    segments.append(.choices(card))
                    i = nextIndex
                    continue
                }
                if ChatDispatchCard.isDispatchFence(infoOpt), let card = ChatDispatchCard.parse(code) {
                    flushMarkdown()
                    segments.append(.dispatch(card))
                    i = nextIndex
                    continue
                }
                if ChatRecommendCard.isRecommendFence(infoOpt), let card = ChatRecommendCard.parse(code) {
                    appendRecommend(card)
                    i = nextIndex
                    continue
                }
                if ChatWorkflowRunCard.isWorkflowRunFence(infoOpt), let card = ChatWorkflowRunCard.parse(code) {
                    flushMarkdown()
                    segments.append(.workflowRun(card))
                    i = nextIndex
                    continue
                }
                if ChatFenceParsers.isCanvasFence(infoOpt), let id = ChatFenceParsers.parseCanvasID(code) {
                    flushMarkdown()
                    segments.append(.canvas(id: id))
                    i = nextIndex
                    continue
                }
                if ChatFenceParsers.isPDFFence(infoOpt), let id = ChatFenceParsers.parsePDFID(code) {
                    flushMarkdown()
                    segments.append(.pdf(id: id))
                    i = nextIndex
                    continue
                }
                if ChatResearchPlanCard.isResearchPlanFence(infoOpt), let plan = ChatResearchPlanCard.parse(code) {
                    flushMarkdown()
                    segments.append(.researchPlan(plan))
                    i = nextIndex
                    continue
                }

                // Ordinary code fence or invalid/partial special fence: keep verbatim in markdown.
                for k in i..<nextIndex { mdBuffer.append(lines[k]) }
                i = nextIndex
                continue
            }

            mdBuffer.append(line)
            i += 1
        }

        flushMarkdown()
        return segments
    }

    // MARK: Multi-Persona @Mention Parsing

    /// Extracts `@mentions` outside code fences and inline code, matching known multi-word persona names first.
    public static func parseMentions(in text: String, knownNames: [String] = []) -> [String] {
        let sortedKnown = knownNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        var result: [String] = []
        var seen: Set<String> = []
        var fenceChar: Character?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in lines {
            if let opener = parseFenceOpener(line) {
                if fenceChar == nil { fenceChar = opener.char; continue }
                if fenceChar == opener.char && opener.info.trimmingCharacters(in: .whitespaces).isEmpty {
                    fenceChar = nil; continue
                }
            }
            if fenceChar != nil { continue }

            let chars = Array(line)
            var idx = 0
            var inInlineCode = false
            while idx < chars.count {
                if chars[idx] == "`" {
                    inInlineCode.toggle()
                    idx += 1
                    continue
                }
                if !inInlineCode && chars[idx] == "@" {
                    let prevIsWord = idx > 0 && (chars[idx - 1].isLetter || chars[idx - 1].isNumber || chars[idx - 1] == "_")
                    if !prevIsWord {
                        let rest = String(chars[(idx + 1)...])
                        var matchedName: String?
                        for name in sortedKnown {
                            if rest.lowercased().hasPrefix(name.lowercased()) {
                                let afterIdx = idx + 1 + name.count
                                let boundary = afterIdx >= chars.count || !(chars[afterIdx].isLetter || chars[afterIdx].isNumber || chars[afterIdx] == "_")
                                if boundary {
                                    matchedName = name
                                    idx = afterIdx
                                    break
                                }
                            }
                        }
                        if matchedName == nil {
                            var end = idx + 1
                            if end < chars.count && chars[end].isLetter {
                                while end < chars.count && (chars[end].isLetter || chars[end].isNumber || chars[end] == "_" || chars[end] == "-") {
                                    end += 1
                                }
                                matchedName = String(chars[(idx + 1)..<end])
                                idx = end
                            }
                        }
                        if let name = matchedName, seen.insert(name.lowercased()).inserted {
                            result.append(name)
                            continue
                        }
                    }
                }
                idx += 1
            }
        }
        return result
    }

    // MARK: Private Helpers

    private struct FenceOpener { let char: Character; let length: Int; let info: String }

    private static func parseFenceOpener(_ line: String) -> FenceOpener? {
        var spaces = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == " " && spaces < 3 {
            spaces += 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let ch = line[idx]
        guard ch == "`" || ch == "~" else { return nil }
        var count = 0
        while idx < line.endIndex && line[idx] == ch {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= 3 else { return nil }
        let info = String(line[idx...])
        if ch == "`" && info.contains("`") { return nil }
        return FenceOpener(char: ch, length: count, info: info)
    }

    private static func isFenceCloser(_ line: String, char: Character, minLength: Int) -> Bool {
        var spaces = 0
        var idx = line.startIndex
        while idx < line.endIndex && line[idx] == " " && spaces < 3 {
            spaces += 1
            idx = line.index(after: idx)
        }
        var count = 0
        while idx < line.endIndex && line[idx] == char {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= minLength else { return false }
        return line[idx...].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func isThematicRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, let first = t.first, first == "-" || first == "*" || first == "_" else { return false }
        return t.allSatisfy { $0 == first }
    }

    private static func matchSourcesHeading(_ line: String) -> (hasColon: Bool, remainder: String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("*") || s.hasPrefix("_") { s.removeFirst() }
        let lower = s.lowercased()
        let prefixes = ["web sources", "web source", "web references", "web links", "web urls", "sources", "source", "references", "reference", "links", "link", "urls", "url"]
        guard let matched = prefixes.first(where: { lower.hasPrefix($0) }) else { return nil }
        var rest = String(s.dropFirst(matched.count)).trimmingCharacters(in: .whitespaces)
        for ext in ["i used", "i consulted", "used", "consulted"] {
            if rest.lowercased().hasPrefix(ext) {
                rest = String(rest.dropFirst(ext.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        while rest.hasPrefix("*") || rest.hasPrefix("_") { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)
        let hasColon = rest.hasPrefix(":")
        if hasColon { rest.removeFirst() }
        while rest.hasPrefix("*") || rest.hasPrefix("_") { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty && !hasColon { return nil }
        return (hasColon, rest)
    }

    private static func lineSources(_ line: String) -> [ChatListedSource] {
        var out: [ChatListedSource] = []
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let number = leadingListNumber(trimmed)

        // Extract markdown links `[title](https://...)` and bare `https://...` URLs.
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == "[",
               let closeBracket = line[idx...].firstIndex(of: "]"),
               closeBracket < line.endIndex {
                let afterBracket = line.index(after: closeBracket)
                if afterBracket < line.endIndex && line[afterBracket] == "(",
                   let closeParen = line[afterBracket...].firstIndex(of: ")") {
                    let urlStart = line.index(after: afterBracket)
                    let url = String(line[urlStart..<closeParen])
                    if url.hasPrefix("http://") || url.hasPrefix("https://") {
                        let title = String(line[line.index(after: idx)..<closeBracket]).trimmingCharacters(in: .whitespaces)
                        out.append(ChatListedSource(title: title, url: url))
                        idx = line.index(after: closeParen)
                        continue
                    }
                }
            }
            if line[idx...].hasPrefix("https://") || line[idx...].hasPrefix("http://") {
                var end = idx
                while end < line.endIndex && !line[end].isWhitespace && !"<>()[]".contains(line[end]) {
                    end = line.index(after: end)
                }
                let rawURL = String(line[idx..<end]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\"*_"))
                let title: String
                if out.isEmpty {
                    title = stripListPrefix(String(line[..<idx]))
                        .replacingOccurrences(of: "*", with: "")
                        .replacingOccurrences(of: "_", with: "")
                        .replacingOccurrences(of: "`", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t:|(–—-"))
                } else {
                    title = ""
                }
                out.append(ChatListedSource(title: title, url: rawURL))
                idx = end
                continue
            }
            idx = line.index(after: idx)
        }

        if let n = number {
            if !out.isEmpty {
                out[0].number = n
            } else if let start = line.range(of: "[["), let end = line[start.upperBound...].range(of: "]]") {
                let inner = String(line[start.upperBound..<end.lowerBound])
                let ref = inner.split(separator: "|", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                if !ref.isEmpty {
                    out.append(ChatListedSource(title: "", url: "", number: n, ref: ref))
                }
            }
        }
        return out
    }

    private static func leadingListNumber(_ s: String) -> Int? {
        var digits = ""
        var idx = s.startIndex
        while idx < s.endIndex && s[idx].isNumber && digits.count < 2 {
            digits.append(s[idx])
            idx = s.index(after: idx)
        }
        guard !digits.isEmpty, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let after = s.index(after: idx)
        guard after < s.endIndex && s[after].isWhitespace else { return nil }
        return Int(digits)
    }

    private static func stripListPrefix(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let first = t.first, first == "-" || first == "*" || first == "+" {
            return String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if leadingListNumber(t) != nil, let sep = t.firstIndex(where: { $0 == "." || $0 == ")" }) {
            return String(t[t.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func linkCitationsInLine(_ line: String, known: Set<Int>) -> String {
        let chars = Array(line)
        var out = ""
        var i = 0
        var inCode = false
        while i < chars.count {
            if chars[i] == "`" {
                inCode.toggle()
                out.append(chars[i])
                i += 1
                continue
            }
            if !inCode && chars[i] == "[" {
                let prev = i > 0 ? chars[i - 1] : nil
                if prev != "[" && prev != "\\" && prev != "!",
                   let (endIdx, n) = matchCitationBracket(chars, at: i),
                   known.contains(n),
                   !(endIdx + 1 < chars.count && (chars[endIdx + 1] == "(" || chars[endIdx + 1] == ":")) {
                    out += "[\(n)](\(citeScheme)\(n))"
                    i = endIdx + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func matchCitationBracket(_ chars: [Character], at start: Int) -> (endIndex: Int, number: Int)? {
        var j = start + 1
        var digits = ""
        while j < chars.count && chars[j].isNumber && digits.count < 2 {
            digits.append(chars[j])
            j += 1
        }
        guard !digits.isEmpty, j < chars.count, chars[j] == "]", let n = Int(digits) else { return nil }
        return (j, n)
    }
}

/// Bounded cache for `ChatTranscriptLogic.parseMessage` keyed by message id, body, role flag, and
/// known persona names so SwiftUI transcript updates don't re-parse unchanged messages.
public final class ChatParsedMessageCache: @unchecked Sendable {
    private struct Key: Hashable {
        let messageId: String
        let bodyMd: String
        let extractSources: Bool
        let knownPersonaNames: [String]
    }

    private let lock = NSLock()
    private let maxEntries: Int
    private var entries: [Key: ParsedChatMessage] = [:]
    private var insertionOrder: [Key] = []

    public init(maxEntries: Int = 512) {
        self.maxEntries = max(1, maxEntries)
    }

    public func parsed(
        messageId: String,
        bodyMd: String,
        extractSources: Bool,
        knownPersonaNames: [String]
    ) -> ParsedChatMessage {
        let key = Key(
            messageId: messageId,
            bodyMd: bodyMd,
            extractSources: extractSources,
            knownPersonaNames: knownPersonaNames
        )
        if let hit = lock.withLock({ entries[key] }) {
            return hit
        }
        let value = ChatTranscriptLogic.parseMessage(
            bodyMd,
            extractSources: extractSources,
            knownPersonaNames: knownPersonaNames
        )
        lock.withLock {
            if entries[key] == nil {
                if insertionOrder.count >= maxEntries {
                    let evicted = insertionOrder.removeFirst()
                    entries.removeValue(forKey: evicted)
                }
                insertionOrder.append(key)
                entries[key] = value
            }
        }
        return value
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            insertionOrder.removeAll()
        }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }
}
