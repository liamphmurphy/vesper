import Foundation

// MARK: - Context Markers (`web/lib/chat-context.ts`)

public enum ChatContextMarker {
    public static let legacyWork = "\n\n<!-- vesper:work-context -->\n"
    public static let knowledge = "\n\n<!-- vesper:knowledge-context -->\n"
    public static let customApp = "\n\n<!-- vesper:custom-app-context -->\n"
    static let all = [knowledge, legacyWork, customApp]
}

public struct ChatStrippedContext: Sendable, Equatable, Hashable {
    public var typedBody: String
    public var knowledgeContextLines: [String]
    public var customAppContextLines: [String]

    public init(
        typedBody: String,
        knowledgeContextLines: [String] = [],
        customAppContextLines: [String] = []
    ) {
        self.typedBody = typedBody
        self.knowledgeContextLines = knowledgeContextLines
        self.customAppContextLines = customAppContextLines
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
    case stats(ChatStatsSpec)
    case diff(ChatDiffSpec)
    case compare(ChatCompareSpec)
    case timeline(ChatTimelineSpec)
    case tree(ChatTreeSpec)
    case compareImages(ChatCompareImagesSpec)
    case graph(ChatGraphSpec)
    case plot(ChatPlotSpec)
    case dataTable(ChatDataTableSpec)
    case codeGroup(ChatCodeGroupSpec)
    case kv(ChatKVSpec)
    case jsonTree(ChatJSONTreeSpec)
    case http(ChatHTTPSpec)
    case tabs(ChatTabsSpec)
    case details(ChatDetailsSpec)
    case choices(ChatChoicesCard)
    case recommend([ChatRecommendCard])
    case gallery(ChatGallerySpec)
    case product(ChatProductSpec)
    case workflowRun(ChatWorkflowRunCard)
    case canvas(id: String)
    case pdf(id: String)
    case researchPlan(ChatResearchPlanCard)
    case callout(ChatCalloutBlock)
    case checklist(ChatChecklistBlock)
    /// A visualization fence whose spec failed validation: shows a visible error banner and raw source.
    case invalidBlock(kind: String, error: String, source: String)
}

public struct ParsedChatMessage: Sendable, Equatable {
    public var typedBody: String
    public var context: ChatStrippedContext
    public var segments: [ChatMessageSegment]
    public var sources: [ChatListedSource]
    public var mentions: [String]
    public var entityRefs: [ChatEntityRef]

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
        mentions: [String] = [],
        entityRefs: [ChatEntityRef] = []
    ) {
        self.typedBody = typedBody
        self.context = context
        self.segments = segments
        self.sources = sources
        self.mentions = mentions
        self.entityRefs = entityRefs
    }
}

public enum ChatTranscriptLogic {
    public static let citeScheme = "cite:"

    // MARK: Context Stripping

    /// Splits appended dock context markers (`knowledge-context`, `custom-app-context`, legacy `work-context`) from the user's typed text.
    public static func stripContext(_ body: String) -> ChatStrippedContext {
        struct MarkerHit { let kind: String; let range: Range<String.Index> }
        var hits: [MarkerHit] = []
        for (kind, marker) in [("work", ChatContextMarker.legacyWork), ("knowledge", ChatContextMarker.knowledge), ("customApp", ChatContextMarker.customApp)] {
            if let range = body.range(of: marker) {
                hits.append(MarkerHit(kind: kind, range: range))
            }
        }
        guard !hits.isEmpty else { return ChatStrippedContext(typedBody: body) }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }

        let typed = String(body[..<hits[0].range.lowerBound])
        var knowledge: [String] = []
        var customApp: [String] = []

        for (i, hit) in hits.enumerated() {
            let end = i + 1 < hits.count ? hits[i + 1].range.lowerBound : body.endIndex
            let lines = body[hit.range.upperBound..<end]
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            switch hit.kind {
            case "work": break
            case "knowledge": knowledge.append(contentsOf: lines)
            default: customApp.append(contentsOf: lines)
            }
        }
        return ChatStrippedContext(
            typedBody: typed,
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
        knownPersonaNames: [String] = [],
        interactiveChecklists: Bool? = nil
    ) -> ParsedChatMessage {
        let context = stripContext(rawBody)
        let (bodyWithoutSources, sources) = extractSources ? splitSourceList(context.typedBody) : (context.typedBody, [])
        let numberedCitations = sources.compactMap(\.number)
        let mentions = parseMentions(in: bodyWithoutSources, knownNames: knownPersonaNames)
        let enableChecklists = interactiveChecklists ?? extractSources
        let segments = parseSegments(bodyWithoutSources, citationNumbers: numberedCitations, interactiveChecklists: enableChecklists)
        let entityRefs = extractSources ? ChatEntityRefExtractor.extract(from: bodyWithoutSources) : []
        return ParsedChatMessage(
            typedBody: context.typedBody,
            context: context,
            segments: segments,
            sources: sources,
            mentions: mentions,
            entityRefs: entityRefs
        )
    }

    public static func parseSegments(_ markdown: String, citationNumbers: [Int] = [], interactiveChecklists: Bool = false) -> [ChatMessageSegment] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [ChatMessageSegment] = []
        var mdBuffer: [String] = []
        var embedIndex = 0
        var nextChecklistIndex = 0

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
                if ChatChartSpec.isChartFence(infoOpt) {
                    flushMarkdown()
                    switch ChatChartSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.chart(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "chart", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatStatsSpec.isStatsFence(infoOpt) {
                    flushMarkdown()
                    switch ChatStatsSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.stats(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "stats", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatDiffSpec.isDiffFence(infoOpt) {
                    flushMarkdown()
                    switch ChatDiffSpec.parse(code, info: infoOpt) {
                    case .success(let spec):
                        segments.append(.diff(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "diff", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatCompareSpec.isCompareFence(infoOpt) {
                    flushMarkdown()
                    switch ChatCompareSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.compare(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "compare", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatTimelineSpec.isTimelineFence(infoOpt) {
                    flushMarkdown()
                    switch ChatTimelineSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.timeline(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "timeline", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatTreeSpec.isTreeFence(infoOpt) {
                    flushMarkdown()
                    switch ChatTreeSpec.parse(code, info: infoOpt) {
                    case .success(let spec):
                        segments.append(.tree(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "tree", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatCompareImagesSpec.isCompareImagesFence(infoOpt) {
                    flushMarkdown()
                    switch ChatCompareImagesSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.compareImages(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "compare-images", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatGraphSpec.isGraphFence(infoOpt) {
                    flushMarkdown()
                    switch ChatGraphSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.graph(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "graph", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatPlotSpec.isPlotFence(infoOpt) {
                    flushMarkdown()
                    switch ChatPlotSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.plot(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "plot", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatDataTableSpec.isDataTableFence(infoOpt) {
                    flushMarkdown()
                    switch ChatDataTableSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.dataTable(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "datatable", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatCodeGroupSpec.isCodeGroupFence(infoOpt) {
                    flushMarkdown()
                    switch ChatCodeGroupSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.codeGroup(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "code-group", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatKVSpec.isKVFence(infoOpt) {
                    flushMarkdown()
                    switch ChatKVSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.kv(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "kv", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatJSONTreeSpec.isJSONTreeFence(infoOpt) {
                    flushMarkdown()
                    switch ChatJSONTreeSpec.parse(code, info: infoOpt) {
                    case .success(let spec):
                        segments.append(.jsonTree(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "json-tree", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatHTTPSpec.isHTTPFence(infoOpt) {
                    flushMarkdown()
                    switch ChatHTTPSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.http(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "http", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatTabsSpec.isTabsFence(infoOpt) {
                    flushMarkdown()
                    switch ChatTabsSpec.parse(code) {
                    case .success(let spec):
                        segments.append(.tabs(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "tabs", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatDetailsSpec.isDetailsFence(infoOpt) {
                    flushMarkdown()
                    switch ChatDetailsSpec.parse(code, info: infoOpt) {
                    case .success(let spec):
                        segments.append(.details(spec))
                    case .failure(let err):
                        segments.append(.invalidBlock(kind: "details", error: err.message, source: code))
                    }
                    i = nextIndex
                    continue
                }
                if ChatChoicesCard.isChoicesFence(infoOpt), let card = ChatChoicesCard.parse(code) {
                    flushMarkdown()
                    segments.append(.choices(card))
                    i = nextIndex
                    continue
                }
                if ChatRecommendCard.isRecommendFence(infoOpt), let card = ChatRecommendCard.parse(code) {
                    appendRecommend(card)
                    i = nextIndex
                    continue
                }
                if ChatGallerySpec.isGalleryFence(infoOpt), let spec = ChatGallerySpec.parse(code) {
                    flushMarkdown()
                    segments.append(.gallery(spec))
                    i = nextIndex
                    continue
                }
                if ChatProductSpec.isProductFence(infoOpt), let spec = ChatProductSpec.parse(code) {
                    flushMarkdown()
                    segments.append(.product(spec))
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

            // GitHub/Obsidian callout blockquote: `> [!type] Title` / `> [!type]-`
            if let header = ChatCalloutBlock.parseHeader(line) {
                var bodyLines: [String] = []
                var j = i + 1
                while j < lines.count, let stripped = ChatCalloutBlock.stripBlockquotePrefix(lines[j]) {
                    bodyLines.append(stripped)
                    j += 1
                }
                let rawBody = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let body = citationNumbers.isEmpty ? rawBody : linkCitations(rawBody, numbers: citationNumbers)
                flushMarkdown()
                segments.append(.callout(ChatCalloutBlock(
                    kind: header.kind,
                    rawType: header.rawType,
                    title: header.title,
                    body: body,
                    collapsible: header.collapsible,
                    defaultCollapsed: header.defaultCollapsed
                )))
                i = j
                continue
            }

            // Interactive GFM task list (`- [ ]` / `- [x]`) in assistant messages
            if interactiveChecklists, let firstTask = ChatChecklistBlock.parseTaskLine(line) {
                var items: [ChatChecklistItem] = [
                    ChatChecklistItem(index: nextChecklistIndex, defaultChecked: firstTask.checked, indentLevel: firstTask.indentLevel, text: firstTask.text)
                ]
                nextChecklistIndex += 1
                var j = i + 1
                while j < lines.count {
                    if let task = ChatChecklistBlock.parseTaskLine(lines[j]) {
                        items.append(ChatChecklistItem(index: nextChecklistIndex, defaultChecked: task.checked, indentLevel: task.indentLevel, text: task.text))
                        nextChecklistIndex += 1
                        j += 1
                    } else if lines[j].trimmingCharacters(in: .whitespaces).isEmpty,
                              j + 1 < lines.count,
                              ChatChecklistBlock.parseTaskLine(lines[j + 1]) != nil {
                        j += 1
                    } else {
                        break
                    }
                }
                flushMarkdown()
                segments.append(.checklist(ChatChecklistBlock(items: items)))
                i = j
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

// MARK: - Transcript Load State & Tail Window

/// Whether `ChatTranscriptView` should show an error, a loading skeleton, or the scroll view.
public enum ChatTranscriptLoadState: Sendable, Equatable {
    case error
    case loading
    case ready
}

/// Tail-windowing and load-state rules for the native chat transcript.
///
/// Rendering a bounded suffix of messages in a regular `VStack` keeps opening long histories fast
/// while giving `.defaultScrollAnchor(.bottom)` exact row heights on pass 1 (avoiding macOS
/// `LazyVStack` bottom-anchor blanking with dynamic `MarkdownTextView` heights).
public enum ChatTranscriptWindow {
    public static let initialLimit = 30
    public static let pageSize = 30
    public static let targetContextBefore = 5

    /// Holds the skeleton until the first payload arrives (even before `.task` flips `isFetching`
    /// to true), while allowing an already-loaded empty chat to render normally.
    public static func loadState(hasData: Bool, hasError: Bool, isEmpty: Bool) -> ChatTranscriptLoadState {
        if hasError && isEmpty { return .error }
        if !hasData { return .loading }
        return .ready
    }

    /// Returns the effective visible count needed to show at least `visibleLimit` trailing messages
    /// plus `targetMessageId` (with `contextBefore` earlier messages) when jumping to an older turn.
    public static func effectiveLimit(
        messageIds: [String],
        visibleLimit: Int,
        targetMessageId: String? = nil,
        contextBefore: Int = targetContextBefore
    ) -> Int {
        let base = max(initialLimit, visibleLimit)
        guard let targetMessageId, !targetMessageId.isEmpty,
              let index = messageIds.firstIndex(of: targetMessageId) else {
            return base
        }
        let start = max(0, index - max(0, contextBefore))
        return max(base, messageIds.count - start)
    }

    /// Index slice of `messages` currently rendered in the transcript `VStack`.
    public static func visibleRange(totalCount: Int, visibleLimit: Int) -> Range<Int> {
        guard totalCount > 0 else { return 0..<0 }
        let clamped = max(1, visibleLimit)
        let start = max(0, totalCount - clamped)
        return start..<totalCount
    }

    /// Number of earlier messages omitted above `visibleRange`.
    public static func hiddenCount(totalCount: Int, visibleLimit: Int) -> Int {
        visibleRange(totalCount: totalCount, visibleLimit: visibleLimit).lowerBound
    }

    /// Expands `currentLimit` by `pageSize`, clamped to `totalCount`.
    public static func expandedLimit(
        currentLimit: Int,
        totalCount: Int,
        pageSize: Int = pageSize
    ) -> Int {
        let next = max(initialLimit, currentLimit) + max(1, pageSize)
        return min(max(totalCount, initialLimit), next)
    }

    /// Preserves the revealed top boundary when new messages append to an already-expanded window.
    public static func adjustedLimitForAppend(
        currentLimit: Int,
        previousCount: Int,
        newCount: Int
    ) -> Int {
        guard currentLimit > initialLimit, newCount > previousCount else { return currentLimit }
        return currentLimit + (newCount - previousCount)
    }

    /// Button title for revealing the next batch of hidden earlier messages.
    public static func earlierButtonLabel(hiddenCount: Int, pageSize: Int = pageSize) -> String {
        guard hiddenCount > 0 else { return "" }
        let batch = min(hiddenCount, max(1, pageSize))
        let unit = batch == 1 ? "message" : "messages"
        if hiddenCount > batch {
            return "Show \(batch) earlier \(unit) (\(hiddenCount) hidden)"
        }
        return "Show \(batch) earlier \(unit)"
    }
}
