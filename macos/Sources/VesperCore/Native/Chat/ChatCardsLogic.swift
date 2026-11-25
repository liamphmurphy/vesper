import Foundation

// MARK: - Fence Helpers

public enum ChatFenceParsers {
    public static func firstWord(of info: String?) -> String {
        (info ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { $0.lowercased() } ?? ""
    }

    public static func isUUID(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count == 36 else { return false }
        let bytes = Array(s.utf8)
        for (i, b) in bytes.enumerated() {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if b != UInt8(ascii: "-") { return false }
            } else {
                let isHex = (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                    || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "f"))
                    || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "F"))
                if !isHex { return false }
            }
        }
        return true
    }

    public static func isCanvasFence(_ info: String?) -> Bool { firstWord(of: info) == "canvas" }
    public static func isPDFFence(_ info: String?) -> Bool { firstWord(of: info) == "pdf" }

    public static func parseCanvasID(_ code: String) -> String? {
        let id = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUUID(id) ? id.lowercased() : nil
    }

    public static func parsePDFID(_ code: String) -> String? {
        let id = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUUID(id) ? id.lowercased() : nil
    }

    static func stripBulletPrefix(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == "-" || first == "*" || first == "+" else { return nil }
        let afterMarker = trimmed.dropFirst()
        guard let space = afterMarker.first, space == " " || space == "\t" else { return nil }
        let content = afterMarker.drop(while: { $0 == " " || $0 == "\t" })
        return content.isEmpty ? nil : String(content)
    }
}

// MARK: - Choices Fence (`web/lib/chat-choices.ts`)

public struct ChatChoicesCard: Sendable, Equatable, Hashable {
    public struct Option: Sendable, Equatable, Hashable {
        public var label: String
        public var detail: String

        public init(label: String, detail: String = "") {
            self.label = label
            self.detail = detail
        }
    }

    public static let minOptions = 2
    public static let maxOptions = 6

    public var question: String
    public var options: [Option]

    public init(question: String, options: [Option]) {
        self.question = question
        self.options = options
    }

    public static func isChoicesFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "choices"
    }

    public static func parse(_ code: String) -> ChatChoicesCard? {
        var questionLines: [String] = []
        var options: [Option] = []
        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let item = ChatFenceParsers.stripBulletPrefix(line) {
                let parts = item.split(separator: "|", omittingEmptySubsequences: false)
                let label = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let detail = parts.dropFirst().map(String.init).joined(separator: "|").trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    options.append(Option(label: label, detail: detail))
                }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && options.isEmpty {
                    questionLines.append(trimmed)
                }
            }
        }
        guard options.count >= minOptions && options.count <= maxOptions else { return nil }
        return ChatChoicesCard(question: questionLines.joined(separator: " "), options: options)
    }

    public static func choicePrompt(_ label: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]`@\n")
        let cleaned = label.unicodeScalars.filter { !forbidden.contains($0) }
        return "Going with: \(String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces))"
    }

    public func chosenOption(nextMessageBody: String?) -> String? {
        guard let next = nextMessageBody, !next.isEmpty else { return nil }
        return options.first(where: { next.hasSuffix(Self.choicePrompt($0.label)) })?.label
    }
}

// MARK: - Recommend Fence (`web/lib/chat-recommend.ts`)

public struct ChatRecommendCard: Sendable, Equatable, Hashable {
    public var url: String
    public var note: String
    public var youtubeVideoID: String?
    public var youtubeMomentSeconds: Int?

    public init(url: String, note: String = "", youtubeVideoID: String? = nil, youtubeMomentSeconds: Int? = nil) {
        self.url = url
        self.note = note
        self.youtubeVideoID = youtubeVideoID
        self.youtubeMomentSeconds = youtubeMomentSeconds
    }

    private static let youtubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be",
    ]

    public static func isRecommendFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "recommend"
    }

    public static func parse(_ code: String) -> ChatRecommendCard? {
        let lines = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let urlStr = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: urlStr),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              parsed.host != nil
        else { return nil }

        let note = lines.dropFirst()
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let videoID = youtubeVideoID(from: urlStr)
        let moment = youtubeMoment(from: urlStr)?.seconds
        return ChatRecommendCard(url: urlStr, note: note, youtubeVideoID: videoID, youtubeMomentSeconds: moment)
    }

    public static func isYouTubeID(_ id: String) -> Bool {
        guard id.count == 11 else { return false }
        return id.unicodeScalars.allSatisfy { s in
            (s.value >= 65 && s.value <= 90)
                || (s.value >= 97 && s.value <= 122)
                || (s.value >= 48 && s.value <= 57)
                || s == "_" || s == "-"
        }
    }

    public static func videoEmbedURL(id: String?) -> String? {
        guard let id, isYouTubeID(id) else { return nil }
        return "https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&rel=0"
    }

    public static func youtubeVideoID(from href: String?) -> String? {
        guard let href, let components = URLComponents(string: href),
              let host = components.host?.lowercased(),
              youtubeHosts.contains(host)
        else { return nil }
        let candidate: String
        if host.hasSuffix("youtu.be") {
            candidate = String(components.path.dropFirst()).split(separator: "/").first.map(String.init) ?? ""
        } else {
            candidate = components.queryItems?.first(where: { $0.name == "v" })?.value ?? ""
        }
        return isYouTubeID(candidate) ? candidate : nil
    }

    public static func youtubeMoment(from href: String?) -> (id: String, seconds: Int)? {
        guard let href, let id = youtubeVideoID(from: href),
              let components = URLComponents(string: href),
              let raw = components.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value,
              let secs = parseTimestampSeconds(raw)
        else { return nil }
        return (id, secs)
    }

    public static func summarizePrompt(url: String, title: String?, isVideo: Bool) -> String {
        let forbidden = CharacterSet(charactersIn: "[]`@\n")
        let cleaned = (title ?? "").unicodeScalars.filter { !forbidden.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        let target = name.isEmpty ? url : "[\(name)](\(url))"
        return "Summarize this \(isVideo ? "video" : "page"): \(target)"
    }

    public static func summaryRequestURL(from body: String?) -> String? {
        guard let body else { return nil }
        for prefix in ["Summarize this video: ", "Summarize this page: "] {
            guard let range = body.range(of: prefix) else { continue }
            let rest = body[range.upperBound...]
            if rest.hasPrefix("["), let mid = rest.range(of: "]("), let end = rest[mid.upperBound...].firstIndex(of: ")") {
                let url = String(rest[mid.upperBound..<end])
                if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
            } else {
                let token = rest.prefix(while: { !$0.isWhitespace })
                let url = String(token)
                if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
            }
        }
        return nil
    }

    private static func parseTimestampSeconds(_ raw: String) -> Int? {
        guard !raw.isEmpty else { return nil }
        let plain = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        if !plain.isEmpty && plain.allSatisfy(\.isNumber), let n = Int(plain) {
            return n
        }
        var total = 0
        var num = 0
        var hasPart = false
        for ch in raw {
            if ch.isNumber, let d = ch.wholeNumberValue {
                num = num * 10 + d
            } else if ch == "h" {
                total += num * 3600; num = 0; hasPart = true
            } else if ch == "m" {
                total += num * 60; num = 0; hasPart = true
            } else if ch == "s" {
                total += num; num = 0; hasPart = true
            } else {
                return nil
            }
        }
        return hasPart && num == 0 ? total : nil
    }
}

// MARK: - Workflow Run & Research Plan Fences

public struct ChatWorkflowRunCard: Sendable, Equatable, Hashable {
    public var workflowID: String
    public var input: String

    public init(workflowID: String, input: String) {
        self.workflowID = workflowID
        self.input = input
    }

    public static func isWorkflowRunFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "workflow-run"
    }

    public static func parse(_ code: String) -> ChatWorkflowRunCard? {
        let lines = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let id = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChatFenceParsers.isUUID(id) else { return nil }
        let input = lines.dropFirst().map(String.init).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatWorkflowRunCard(workflowID: id.lowercased(), input: input)
    }
}

public struct ChatResearchPlanCard: Sendable, Equatable, Hashable {
    public struct Question: Sendable, Equatable, Hashable {
        public var label: String
        public var question: String

        public init(label: String, question: String) {
            self.label = label
            self.question = question
        }
    }

    public enum ReportLength: String, Sendable, Equatable, Hashable, CaseIterable {
        case brief, standard, detailed
        case inDepth = "in_depth"

        public static func parse(_ raw: String) -> ReportLength? {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            return Self(rawValue: norm)
        }
    }

    public enum ReportTone: String, Sendable, Equatable, Hashable, CaseIterable {
        case report, explainer, essay, academic, news

        public static func parse(_ raw: String) -> ReportTone? {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if norm == "news article" { return .news }
            return Self(rawValue: norm)
        }
    }

    public static let maxQuestions = 5
    public static let sourceRange = 5...200
    public static let minuteRange = 5...120

    public var title: String
    public var questions: [Question]
    public var length: ReportLength?
    public var tone: ReportTone?

    public init(title: String, questions: [Question], length: ReportLength? = nil, tone: ReportTone? = nil) {
        self.title = title
        self.questions = questions
        self.length = length
        self.tone = tone
    }

    public static func isResearchPlanFence(_ info: String?) -> Bool {
        ChatFenceParsers.firstWord(of: info) == "research-plan"
    }

    public static func parse(_ code: String) -> ChatResearchPlanCard? {
        var title = ""
        var length: ReportLength?
        var tone: ReportTone?
        var questions: [Question] = []

        for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "length", !val.isEmpty {
                    length = ReportLength.parse(val) ?? length
                    continue
                }
                if key == "tone", !val.isEmpty {
                    tone = ReportTone.parse(val) ?? tone
                    continue
                }
            }
            if let bullet = ChatFenceParsers.stripBulletPrefix(line) {
                let parts = bullet.split(separator: "|", omittingEmptySubsequences: false)
                let label = parts.first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let rest = parts.dropFirst().map(String.init).joined(separator: "|").trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    if !rest.isEmpty {
                        questions.append(Question(label: label, question: rest))
                    } else {
                        questions.append(Question(label: String(label.prefix(40)), question: label))
                    }
                }
            } else if !trimmed.isEmpty && title.isEmpty {
                title = trimmed
            }
        }

        guard !title.isEmpty, !questions.isEmpty, questions.count <= maxQuestions else { return nil }
        return ChatResearchPlanCard(title: title, questions: questions, length: length, tone: tone)
    }

    public func isReady(sources: Int, minutes: Int) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !questions.isEmpty
            && questions.count <= Self.maxQuestions
            && questions.allSatisfy { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty && !$0.question.trimmingCharacters(in: .whitespaces).isEmpty }
            && Self.sourceRange.contains(sources)
            && Self.minuteRange.contains(minutes)
    }

    public static func minutesLabel(ms: Int) -> String {
        let m = Int((Double(ms) / 60_000.0).rounded())
        return m < 1 ? "<1 min" : "\(m) min"
    }

    public static func spendLabel(spent: Double, limit: Double?) -> String {
        guard let limit else { return "no spend limit" }
        let limitStr = limit.rounded() == limit ? String(Int(limit)) : String(format: "%.2f", limit)
        return String(format: "$%.2f of $%@", spent, limitStr)
    }
}

// MARK: - Status Slot & Interactive Card State Helpers

public enum ChatStatusSlotKind: Int, Sendable, Equatable, Hashable, CaseIterable {
    case blocking = 0
    case needsYou = 1
    case failedTurn = 2
    case error = 3
    case live = 4
}

public struct ChatStatusSlotEntry: Sendable, Equatable, Hashable {
    public var key: String
    public var kind: ChatStatusSlotKind
    public var pinned: Bool

    public init(key: String, kind: ChatStatusSlotKind, pinned: Bool = false) {
        self.key = key
        self.kind = kind
        self.pinned = pinned
    }

    public static func order(_ items: [ChatStatusSlotEntry]) -> [ChatStatusSlotEntry] {
        items.enumerated()
            .sorted { a, b in
                a.element.kind.rawValue != b.element.kind.rawValue
                    ? a.element.kind.rawValue < b.element.kind.rawValue
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    public static func split(_ items: [ChatStatusSlotEntry], expanded: Bool) -> (shown: [ChatStatusSlotEntry], hidden: [ChatStatusSlotEntry]) {
        let ordered = order(items)
        if expanded { return (ordered, []) }
        var shown: [ChatStatusSlotEntry] = []
        var hidden: [ChatStatusSlotEntry] = []
        for (i, item) in ordered.enumerated() {
            if i == 0 || item.kind == .blocking || item.pinned {
                shown.append(item)
            } else {
                hidden.append(item)
            }
        }
        return (shown, hidden)
    }
}

public enum ChatMediaStageState: String, Sendable, Equatable, Hashable {
    case done, active, failed, pending
}

public struct ChatMediaStage: Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var failed: String
    public var retry: String

    public init(id: String, label: String, failed: String, retry: String) {
        self.id = id; self.label = label; self.failed = failed; self.retry = retry
    }
}

public enum ChatCardDisplay {
    public static func stateBadge(for state: String) -> (label: String, tone: Tone) {
        switch state.lowercased() {
        case "pending", "waiting", "awaiting_approval": return ("Pending", .human)
        case "approved", "applied", "pushed", "merged", "done", "completed": return (state.capitalized, .done)
        case "rejected", "declined", "failed", "cancelled", "closed": return (state.capitalized, .blocked)
        case "running", "in_progress", "pushing": return ("Running", .accent)
        default: return (state.capitalized, .neutral)
        }
    }

    public static func pushSummary(branch: String, commitCount: Int, fileCount: Int) -> String {
        let c = commitCount == 1 ? "1 commit" : "\(commitCount) commits"
        let f = fileCount == 1 ? "1 file" : "\(fileCount) files"
        return "\(branch) · \(c) · \(f)"
    }

    public static func secretPlacementLabel(placement: String, key: String) -> String {
        switch placement {
        case "bearer": return "Authorization: Bearer"
        case "header": return "\(key) header"
        case "query": return "\(key) query parameter"
        case "basic": return "Basic auth"
        default: return placement
        }
    }

    public static func secretSentAs(placement: String, key: String, handle: String) -> String {
        let ph = "‹\(handle.isEmpty ? "secret" : handle)›"
        switch placement {
        case "bearer": return "Authorization: Bearer \(ph)"
        case "header": return "\(key.isEmpty ? "X-Api-Key" : key): \(ph)"
        case "query": return "?\(key.isEmpty ? "api_key" : key)=\(ph)"
        case "basic": return "Authorization: Basic \(ph)"
        default: return ph
        }
    }

    public static func canApprovePersonaProposal(state: String, avatarState: String?) -> Bool {
        state == "pending" && avatarState != "pending"
    }

    public static func ticketChangeLabel(tool: String, ticketKey: String) -> String {
        switch tool {
        case "update_ticket": return "Update \(ticketKey)"
        case "update_ticket_blockers": return "Update blockers on \(ticketKey)"
        case "comment_ticket": return "Comment on \(ticketKey)"
        case "update_epic": return "Update epic \(ticketKey)"
        default: return "\(tool) \(ticketKey)"
        }
    }

    // MARK: Audio & Video Cards (`web/lib/chat-audio.ts`, `web/lib/chat-video.ts`)

    public static let audioStages: [ChatMediaStage] = [
        ChatMediaStage(id: "compose", label: "Compose", failed: "Composing failed", retry: "Retry composing"),
        ChatMediaStage(id: "render", label: "Render", failed: "Rendering failed", retry: "Retry render"),
        ChatMediaStage(id: "check", label: "Mix check", failed: "Checking the mix failed", retry: "Retry mix check"),
        ChatMediaStage(id: "save", label: "Save to Library", failed: "Saving failed", retry: "Retry save"),
    ]

    public static let musicStages: [ChatMediaStage] = [
        ChatMediaStage(id: "compose", label: "Queued", failed: "Couldn’t start generation", retry: "Retry"),
        ChatMediaStage(id: "render", label: "Generating", failed: "Music generation failed", retry: "Retry"),
        ChatMediaStage(id: "save", label: "Save to Library", failed: "Saving failed", retry: "Retry"),
    ]

    public static let videoStages: [ChatMediaStage] = [
        ChatMediaStage(id: "write", label: "Write renderer", failed: "Writing the renderer failed", retry: "Retry writing"),
        ChatMediaStage(id: "stills", label: "Check stills", failed: "Checking the stills failed", retry: "Retry stills"),
        ChatMediaStage(id: "render", label: "Render frames", failed: "Rendering failed", retry: "Retry render"),
        ChatMediaStage(id: "encode", label: "Encode", failed: "Encoding failed", retry: "Retry encode"),
        ChatMediaStage(id: "save", label: "Save to Library", failed: "Saving failed", retry: "Retry save"),
    ]

    public static func mediaStageStates(stages: [ChatMediaStage], currentStage: String, state: String) -> [ChatMediaStageState] {
        let at = stages.firstIndex(where: { $0.id == currentStage }) ?? -1
        return stages.indices.map { i in
            if state == "done" || i < at { return .done }
            if i > at { return .pending }
            return state == "failed" ? .failed : .active
        }
    }

    public static func waveBars(peaks: [Int]?, count: Int = 64) -> [Double] {
        guard count > 0 else { return [] }
        guard let peaks, !peaks.isEmpty else {
            return Array(repeating: 0.08, count: count)
        }
        return (0..<count).map { i in
            let from = (i * peaks.count) / count
            let to = max(from + 1, ((i + 1) * peaks.count) / count)
            var top = 0
            for j in from..<min(to, peaks.count) { top = max(top, peaks[j]) }
            return max(0.08, Double(top) / 255.0)
        }
    }

    public static func mediaClock(ms: Int) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let ss = String(format: "%02d", s % 60)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(ss)" : "\(m):\(ss)"
    }

    public static func videoPlannedMeta(width: Int, height: Int, fps: Int, durationMs: Int) -> String {
        let secs = Double(durationMs) / 1000.0
        let secStr = secs.rounded() == secs ? String(Int(secs)) : String(format: "%.1f", secs)
        return "\(width)×\(height) · \(fps) fps · \(secStr) s"
    }

    public static func formattedFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    public static func isImageAttachment(contentType: String) -> Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    public static func canvasKindLabel(_ kind: String) -> String {
        switch kind.lowercased() {
        case "design": return "Design"
        case "svg", "diagram": return "Diagram"
        case "code": return "Code"
        default: return "Document"
        }
    }
}
