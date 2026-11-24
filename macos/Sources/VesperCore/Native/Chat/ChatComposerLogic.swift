import Foundation

// MARK: - Slash Commands (`web/lib/chat-commands.ts`)

public struct ChatSlashCommand: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let args: String?
    public let hint: String
    public let free: Bool
    public let optionalArg: Bool

    public init(name: String, args: String? = nil, hint: String, free: Bool = false, optionalArg: Bool = false) {
        self.name = name
        self.args = args
        self.hint = hint
        self.free = free
        self.optionalArg = optionalArg
    }

    public static let all: [ChatSlashCommand] = [
        ChatSlashCommand(name: "model", args: "model", hint: "Switch the model for the next message"),
        ChatSlashCommand(name: "effort", args: "effort", hint: "Set the reasoning effort for the next message"),
        ChatSlashCommand(name: "persona", args: "persona", hint: "Start a new chat with another persona"),
        ChatSlashCommand(name: "workflow", args: "workflow", hint: "Run one of your published workflows"),
        ChatSlashCommand(name: "new", hint: "Start a new conversation"),
        ChatSlashCommand(name: "compact", args: "focus", hint: "Compact context onto a fresh window (optional focus)", free: true, optionalArg: true),
        ChatSlashCommand(name: "repo", args: "repository", hint: "Select a repository in this conversation"),
        ChatSlashCommand(name: "memory", hint: "Open your memory"),
        ChatSlashCommand(name: "stop", hint: "Stop the current reply"),
        ChatSlashCommand(name: "steer", args: "guidance", hint: "Steer the current reply mid-turn without discarding work", free: true),
        ChatSlashCommand(name: "aside", args: "question", hint: "Ask about the current reply without stopping it", free: true),
        ChatSlashCommand(name: "queue", args: "message", hint: "Send this once the current reply ends", free: true),
        ChatSlashCommand(name: "design", args: "what to design", hint: "Create a design (flow, diagram or wireframe) beside the chat", free: true),
        ChatSlashCommand(name: "music", args: "what to compose", hint: "Generate a music track in this chat", free: true, optionalArg: true),
        ChatSlashCommand(name: "compare", args: "model", hint: "Get a second opinion from another model without switching this chat"),
        ChatSlashCommand(name: "outline", hint: "Open the thread outline (bookmarks, links, checklists, diffs, files)"),
        ChatSlashCommand(name: "thinking", args: "on|off", hint: "Show or hide live thinking blocks inline in the transcript", optionalArg: true),
    ]

    public static func named(_ name: String) -> ChatSlashCommand? {
        let lower = name.lowercased()
        return all.first { $0.name == lower }
    }
}

public struct ChatParsedCommand: Sendable, Equatable, Hashable {
    public let name: String
    public let arg: String

    public init(name: String, arg: String) {
        self.name = name
        self.arg = arg
    }
}

public enum ChatCommandMenuState: Sendable, Equatable, Hashable {
    case command(query: String)
    case arg(name: String, query: String)
}

public struct ChatCompareOption: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(harness):\(model)" }
    public let name: String
    public let harness: String
    public let harnessLabel: String
    public let model: String
    public let modelLabel: String
    public let isDefault: Bool

    public init(
        name: String,
        harness: String,
        harnessLabel: String,
        model: String,
        modelLabel: String,
        isDefault: Bool = false
    ) {
        self.name = name
        self.harness = harness
        self.harnessLabel = harnessLabel
        self.model = model
        self.modelLabel = modelLabel
        self.isDefault = isDefault
    }
}

public enum ChatCompareResolution: Sendable, Equatable {
    case matched(option: ChatCompareOption, question: String)
    case error(String)
}

public enum ChatThinkingToggleResolution: Sendable, Equatable {
    case set(Bool)
    case error(String)
}

/// Persistent preference for streaming reasoning blocks inline in Chat transcripts (`false` by default).
public enum ChatLiveThinkingPreference {
    public static let defaultsKey = "VesperShowLiveThinking"

    public static func read(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func write(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

public enum ChatSlashCommandLogic {
    public static let docDraft = "Create a doc: "

    public static func designRequest(_ brief: String) -> String {
        "Create a design: \(brief.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// A message starting with `//` is sent as literal text minus the first slash.
    public static func literalBody(_ text: String) -> String {
        text.hasPrefix("//") ? String(text.dropFirst()) : text
    }

    /// Single-line `/command [arg]` parser matching `web/lib/chat-commands.ts`.
    public static func parseCommand(_ text: String) -> ChatParsedCommand? {
        let trimmed = trimTrailingWhitespace(text)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), !trimmed.contains("\n") else { return nil }
        let rest = trimmed.dropFirst()
        guard let first = rest.first, first.isASCII, first.isLetter else { return nil }

        var idx = rest.startIndex
        while idx < rest.endIndex {
            let ch = rest[idx]
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-") {
                idx = rest.index(after: idx)
            } else {
                break
            }
        }
        let name = String(rest[..<idx]).lowercased()
        guard !name.isEmpty else { return nil }

        if idx == rest.endIndex {
            return ChatParsedCommand(name: name, arg: "")
        }
        let sep = rest[idx]
        guard sep == " " || sep == "\t" else { return nil }
        let arg = String(rest[idx...]).trimmingCharacters(in: .whitespaces)
        return ChatParsedCommand(name: name, arg: arg)
    }

    /// Active completion state for the composer's `/` menu, or `nil` when closed.
    public static func commandMenu(for text: String) -> ChatCommandMenuState? {
        guard text.hasPrefix("/"), !text.hasPrefix("//"), !text.contains("\n") else { return nil }
        let rest = text.dropFirst()
        if let sepIdx = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let name = String(rest[..<sepIdx]).lowercased()
            guard let cmd = ChatSlashCommand.named(name), cmd.args != nil, !cmd.free else { return nil }
            let afterSep = rest[sepIdx...].drop(while: { $0 == " " || $0 == "\t" })
            let query = String(afterSep)
            if cmd.name == "compare", query.contains(where: { $0.isWhitespace }) {
                return nil
            }
            return .arg(name: cmd.name, query: query)
        }
        let query = String(rest)
        guard query.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return .command(query: query)
    }

    public static func matchingCommands(query: String, isRunning: Bool = false) -> [ChatSlashCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = ChatSlashCommand.all.filter { cmd in
            if !isRunning && (cmd.name == "stop" || cmd.name == "steer" || cmd.name == "queue") {
                return true // Keep discoverable; runtime validates active turn.
            }
            return true
        }
        guard !q.isEmpty else { return pool }
        let prefix = pool.filter { $0.name.hasPrefix(q) }
        let contains = pool.filter { !$0.name.hasPrefix(q) && ($0.name.contains(q) || $0.hint.lowercased().contains(q)) }
        return prefix + contains
    }

    public static func applyCommandCompletion(_ command: ChatSlashCommand) -> String {
        command.args != nil ? "/\(command.name) " : "/\(command.name)"
    }

    public static func applyArgumentCompletion(commandName: String, argument: String) -> String {
        let suffix = commandName == "compare" ? " " : ""
        return "/\(commandName) \(argument)\(suffix)"
    }

    /// Parses `/compare <model|harness> [question]` against candidate models.
    public static func resolveCompareTarget(options: [ChatCompareOption], raw: String) -> ChatCompareResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error("Say which model: /compare <model> [question]")
        }
        let lower = trimmed.lowercased()

        let phrases = options.flatMap { option in
            [(option, option.name.lowercased()), (option, option.modelLabel.lowercased())]
        }
        .filter { _, phrase in
            lower == phrase || lower.hasPrefix("\(phrase) ") || lower.hasPrefix("\(phrase)\t")
        }
        .sorted { $0.1.count > $1.1.count }

        if let best = phrases.first {
            let question = String(trimmed.dropFirst(best.1.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .matched(option: best.0, question: question)
        }

        let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        let first = String(parts[0])
        let token = first.lowercased()
        let question = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        if let exactModel = options.first(where: { $0.model.lowercased() == token || $0.modelLabel.lowercased() == token }) {
            return .matched(option: exactModel, question: question)
        }
        let exactHarness = options.filter { $0.harness.lowercased() == token || $0.harnessLabel.lowercased() == token }
        if !exactHarness.isEmpty {
            return .matched(option: exactHarness.first(where: \.isDefault) ?? exactHarness[0], question: question)
        }
        if let startsWith = options.first(where: {
            $0.model.lowercased().hasPrefix(token) || $0.modelLabel.lowercased().hasPrefix(token)
                || $0.harness.lowercased().hasPrefix(token) || $0.harnessLabel.lowercased().hasPrefix(token)
        }) {
            return .matched(option: startsWith, question: question)
        }
        if let includes = options.first(where: {
            $0.model.lowercased().contains(token) || $0.modelLabel.lowercased().contains(token)
                || $0.name.lowercased().contains(token)
        }) {
            return .matched(option: includes, question: question)
        }
        return .error("No model matches “\(first)”.")
    }

    /// Parses `/thinking [on|off]` against the current `showLiveThinking` preference.
    /// Empty argument (or `toggle`) flips the current value.
    public static func resolveThinkingToggle(raw: String, current: Bool) -> ChatThinkingToggleResolution {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch token {
        case "", "toggle":
            return .set(!current)
        case "on", "true", "1", "show", "enable":
            return .set(true)
        case "off", "false", "0", "hide", "disable":
            return .set(false)
        default:
            return .error("Usage: /thinking [on|off]")
        }
    }

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev] == " " || s[prev] == "\t" || s[prev] == "\r" || s[prev] == "\n" {
                end = prev
            } else {
                break
            }
        }
        return String(s[..<end])
    }
}

// MARK: - @persona Mention Completion

public struct ChatMentionCandidate: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let handle: String?
    public let isDefault: Bool
    public let inChatList: Bool

    public init(id: String, name: String, handle: String? = nil, isDefault: Bool = false, inChatList: Bool = true) {
        self.id = id
        self.name = name
        self.handle = handle
        self.isDefault = isDefault
        self.inChatList = inChatList
    }

    public init(_ persona: API.Persona) {
        self.init(
            id: persona.id,
            name: persona.name,
            handle: persona.handle,
            isDefault: persona.isDefault,
            inChatList: persona.inChatList
        )
    }
}

public struct ChatMentionTrigger: Sendable, Equatable, Hashable {
    public let query: String
    public let utf16Location: Int
    public let utf16Length: Int

    public init(query: String, utf16Location: Int, utf16Length: Int) {
        self.query = query
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }
}

public enum ChatMentionLogic {
    /// Detects an active `@query` mention immediately before `cursorUTF16`.
    public static func detectTrigger(in text: String, cursorUTF16: Int) -> ChatMentionTrigger? {
        let utf16 = text.utf16
        let clamped = max(0, min(cursorUTF16, utf16.count))
        guard clamped > 0 else { return nil }

        let endIdx = utf16.index(utf16.startIndex, offsetBy: clamped)
        let prefix = String(utf16[..<endIdx]) ?? ""

        // Ignore if inside an odd number of backticks on the current line.
        let lineStart = prefix.lastIndex(of: "\n").map { prefix.index(after: $0) } ?? prefix.startIndex
        let currentLine = prefix[lineStart...]
        if currentLine.filter({ $0 == "`" }).count % 2 == 1 { return nil }

        // Walk backwards from end to find `@` preceded by start-of-string or whitespace.
        guard let atIdx = currentLine.lastIndex(of: "@") else { return nil }
        if atIdx > currentLine.startIndex {
            let before = currentLine[currentLine.index(before: atIdx)]
            if !before.isWhitespace && before != "(" && before != "[" {
                return nil
            }
        }
        let querySlice = currentLine[currentLine.index(after: atIdx)...]
        // Stop triggering if query has double spaces or newline.
        if querySlice.contains("\n") || querySlice.contains("  ") { return nil }
        let query = String(querySlice)
        let location = utf16.distance(from: utf16.startIndex, to: atIdx.samePosition(in: utf16) ?? utf16.startIndex)
        return ChatMentionTrigger(query: query, utf16Location: location, utf16Length: clamped - location)
    }

    public static func rankCandidates(
        _ candidates: [ChatMentionCandidate],
        query: String,
        participantIds: Set<String> = []
    ) -> [ChatMentionCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let eligible = candidates.filter { $0.inChatList || participantIds.contains($0.id) }
        guard !q.isEmpty else {
            return eligible.sorted { lhs, rhs in
                let lp = participantIds.contains(lhs.id)
                let rp = participantIds.contains(rhs.id)
                if lp != rp { return lp }
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        func score(_ c: ChatMentionCandidate) -> Int? {
            let name = c.name.lowercased()
            let handle = c.handle?.lowercased() ?? ""
            let isParticipant = participantIds.contains(c.id)
            if name == q || (!handle.isEmpty && handle == q) { return isParticipant ? 0 : 1 }
            if name.hasPrefix(q) { return isParticipant ? 2 : 3 }
            if !handle.isEmpty && handle.hasPrefix(q) { return isParticipant ? 4 : 5 }
            if name.contains(q) || (!handle.isEmpty && handle.contains(q)) { return isParticipant ? 6 : 7 }
            return nil
        }

        return eligible.compactMap { c -> (ChatMentionCandidate, Int)? in
            guard let s = score(c) else { return nil }
            return (c, s)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.0.isDefault != rhs.0.isDefault { return lhs.0.isDefault }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .map(\.0)
    }

    public static func insertMention(
        _ candidate: ChatMentionCandidate,
        into text: String,
        trigger: ChatMentionTrigger
    ) -> (text: String, cursorUTF16: Int) {
        let ns = text as NSString
        let range = NSRange(location: trigger.utf16Location, length: trigger.utf16Length)
        guard range.location >= 0, range.location + range.length <= ns.length else {
            return (text, ns.length)
        }
        let insertion = "@\(candidate.name) "
        let updated = ns.replacingCharacters(in: range, with: insertion)
        return (updated, trigger.utf16Location + (insertion as NSString).length)
    }
}

// MARK: - Attachment Queue & Validation (`web/lib/attachments.ts`)

public enum ChatAttachmentRules {
    public static let maxBytes = 25 * 1024 * 1024
    public static let maxCount = 5
    public static let allowedExtensions: [String] = [
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "txt", "md", "csv", "json", "zip",
    ]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    public static func fileExtension(for filename: String) -> String {
        guard let dot = filename.lastIndex(of: "."), dot < filename.index(before: filename.endIndex) else {
            return ""
        }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }

    public static func problem(filename: String, sizeBytes: Int) -> String? {
        let ext = fileExtension(for: filename)
        guard allowedExtensions.contains(ext) else { return "type not supported" }
        if sizeBytes <= 0 { return "file is empty" }
        if sizeBytes > maxBytes { return "over 25 MB" }
        return nil
    }

    public static func canAdd(currentCount: Int, filename: String, sizeBytes: Int) -> String? {
        if currentCount >= maxCount { return "at most \(maxCount) attachments per message" }
        return problem(filename: filename, sizeBytes: sizeBytes)
    }

    public static func pastedImageName(contentType: String, index: Int) -> String {
        let parts = contentType.split(separator: "/")
        let rawSubtype = parts.count > 1 ? String(parts[1]) : "png"
        let clean = rawSubtype.split(whereSeparator: { $0 == ";" || $0 == "+" }).first.map(String.init)?.lowercased() ?? "png"
        let ext = clean == "jpeg" ? "jpg" : (clean.isEmpty ? "png" : clean)
        return "pasted-image-\(index).\(ext)"
    }

    public static func badge(for filename: String) -> String {
        let ext = fileExtension(for: filename)
        if imageExtensions.contains(ext) { return "IMG" }
        return allowedExtensions.contains(ext) ? ext.uppercased() : "FILE"
    }

    public static func mimeType(for filename: String) -> String {
        switch fileExtension(for: filename) {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "txt": "text/plain"
        case "md": "text/markdown"
        case "csv": "text/csv"
        case "json": "application/json"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }

    /// Supported clipboard/drag image UTI identifiers in preference order.
    public static let pastedImageTypeIdentifiers: [String] = [
        "public.png",
        "public.jpeg",
        "com.compuserve.gif",
        "org.webmproject.webp",
        "public.tiff",
        "public.heic",
    ]

    /// Direct upload MIME type for an image UTI that the server accepts as-is, or `nil` when
    /// the raw bytes should be transcoded to PNG first (e.g. TIFF, HEIC).
    public static func directMimeType(forImageTypeIdentifier uti: String) -> String? {
        switch uti.lowercased() {
        case "public.png": "image/png"
        case "public.jpeg": "image/jpeg"
        case "com.compuserve.gif": "image/gif"
        case "org.webmproject.webp": "image/webp"
        default: nil
        }
    }
}

public struct ChatComposerAttachment: Sendable, Equatable, Identifiable {
    public enum UploadState: Sendable, Equatable {
        case pending
        case uploading
        case uploaded(id: String)
        case failed(String)
    }

    public let id: String
    public var filename: String
    public var contentType: String
    public var sizeBytes: Int
    public var localURL: URL?
    public var uploadState: UploadState

    public var uploadedId: String? {
        if case .uploaded(let id) = uploadState { return id }
        return nil
    }

    public var badge: String { ChatAttachmentRules.badge(for: filename) }

    public init(
        id: String = UUID().uuidString,
        filename: String,
        contentType: String,
        sizeBytes: Int,
        localURL: URL? = nil,
        uploadState: UploadState = .pending
    ) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.localURL = localURL
        self.uploadState = uploadState
    }
}

// MARK: - Context Chips & Work/Knowledge Serialization

public struct ChatKnowledgePassage: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var excerpt: String

    public init(path: String, excerpt: String) {
        self.path = path
        self.excerpt = excerpt
    }
}

public struct ChatContextChip: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case artifact
        case section
        case ticket
        case page
        case canvas
        case workRun
        case workTicket
        case knowledgePage
        case knowledgeFolder
    }

    public var id: String { key }
    public let key: String
    public let kind: Kind
    public let label: String
    public let refId: String?
    public let refKey: String?
    public let anchor: String?
    public let agent: String?
    public let pinned: Bool

    public init(
        kind: Kind,
        label: String,
        refId: String? = nil,
        refKey: String? = nil,
        anchor: String? = nil,
        agent: String? = nil,
        pinned: Bool = false
    ) {
        self.kind = kind
        self.label = label
        self.refId = refId
        self.refKey = refKey
        self.anchor = anchor
        self.agent = agent
        self.pinned = pinned
        self.key = [kind.rawValue, refId ?? refKey ?? label, anchor ?? ""].joined(separator: ":")
    }

    public var asWorkSubject: ChatWorkSubject? {
        switch kind {
        case .workTicket:
            guard let refKey else { return nil }
            return .ticket(key: refKey, title: label)
        case .workRun:
            guard let refId else { return nil }
            return .run(id: refId, title: label, agent: agent ?? "agent", ticketKey: refKey)
        default:
            return nil
        }
    }

    public var asAPIContextRef: API.ChatContextRef? {
        switch kind {
        case .artifact: API.ChatContextRef(id: refId, kind: .artifact)
        case .section: API.ChatContextRef(anchor: anchor, id: refId, kind: .section)
        case .ticket: API.ChatContextRef(key: refKey, kind: .ticket)
        case .page: API.ChatContextRef(id: refId, kind: .page)
        case .canvas: API.ChatContextRef(id: refId, kind: .canvas)
        case .workRun, .workTicket, .knowledgePage, .knowledgeFolder: nil
        }
    }
}

public enum ChatComposerContextLogic {
    public static let maxContextRefs = 20

    public static func addChip(_ chip: ChatContextChip, to chips: [ChatContextChip]) -> [ChatContextChip] {
        guard chips.count < maxContextRefs, !chips.contains(where: { $0.key == chip.key }) else { return chips }
        return chips + [chip]
    }

    public static func removeChip(key: String, from chips: [ChatContextChip]) -> [ChatContextChip] {
        chips.filter { $0.key != key }
    }

    public static func toAPIContextRefs(_ chips: [ChatContextChip]) -> [API.ChatContextRef]? {
        let refs = chips.compactMap(\.asAPIContextRef)
        return refs.isEmpty ? nil : refs
    }

    public static func withKnowledgeContext(
        _ body: String,
        viewingPagePath: String? = nil,
        attachedPages: [String] = [],
        attachedFolders: [String] = [],
        passages: [ChatKnowledgePassage] = []
    ) -> String {
        var lines: [String] = []
        if let viewing = viewingPagePath?.trimmingCharacters(in: .whitespacesAndNewlines), !viewing.isEmpty {
            lines.append("Viewing page \(viewing).")
        }
        for page in attachedPages where !page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Attached page \(page).")
        }
        for folder in attachedFolders where !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Attached folder \(folder).")
        }
        for passage in passages where !passage.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Attached passage from \(passage.path): \(passage.excerpt)")
        }
        guard !lines.isEmpty else { return body }
        let suffix = ChatContextMarker.knowledge + lines.joined(separator: "\n")
        return body.hasSuffix(suffix) ? body : body + suffix
    }

    /// Appends work-context and knowledge-context markers from active chips onto `typed`.
    public static func serializeBody(_ typed: String, chips: [ChatContextChip], passages: [ChatKnowledgePassage] = []) -> String {
        let workViewing = chips.first(where: { !$0.pinned && ($0.kind == .workRun || $0.kind == .workTicket) })?.asWorkSubject
        let workPinned = chips.first(where: { $0.pinned && ($0.kind == .workRun || $0.kind == .workTicket) })?.asWorkSubject
        let knowledgeViewing = chips.first(where: { $0.kind == .knowledgePage && $0.pinned })?.label
        let knowledgePages = chips.filter { $0.kind == .knowledgePage && !$0.pinned }.map(\.label)
        let knowledgeFolders = chips.filter { $0.kind == .knowledgeFolder }.map(\.label)

        var body = ChatWorkSubject.withWorkContext(typed, viewing: workViewing, pinned: workPinned)
        body = withKnowledgeContext(
            body,
            viewingPagePath: knowledgeViewing,
            attachedPages: knowledgePages,
            attachedFolders: knowledgeFolders,
            passages: passages
        )
        return body
    }
}

// MARK: - Per-Chat Draft Store

public struct ChatComposerDraft: Codable, Sendable, Equatable {
    public var text: String
    public var chips: [ChatContextChip]
    public var updatedAt: Date

    public init(text: String, chips: [ChatContextChip] = [], updatedAt: Date = Date()) {
        self.text = text
        self.chips = chips
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chips.isEmpty
    }
}

public final class ChatDraftStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "VesperNativeChatDraft.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func storageKey(for chatId: String?) -> String {
        let suffix = (chatId?.isEmpty == false) ? chatId! : "__new__"
        return keyPrefix + suffix
    }

    public func load(chatId: String?) -> ChatComposerDraft? {
        lock.withLock {
            guard let data = defaults.data(forKey: storageKey(for: chatId)) else { return nil }
            return try? JSONDecoder().decode(ChatComposerDraft.self, from: data)
        }
    }

    public func save(_ draft: ChatComposerDraft, chatId: String?) {
        lock.withLock {
            let key = storageKey(for: chatId)
            if draft.isEmpty {
                defaults.removeObject(forKey: key)
                return
            }
            if let data = try? JSONEncoder().encode(draft) {
                defaults.set(data, forKey: key)
            }
        }
    }

    public func clear(chatId: String?) {
        lock.withLock {
            defaults.removeObject(forKey: storageKey(for: chatId))
        }
    }
}

/// Text another screen asks a composer to draft without sending, such as Knowledge's
/// Ask a Persona PDF request. `token` grows with each request so a repeat is applied again.
public struct ChatComposerPrefill: Sendable, Equatable {
    public let token: Int
    public let text: String

    public init(token: Int, text: String) {
        self.token = token
        self.text = text
    }

    /// The draft after applying `prefill`: it fills an empty draft, is skipped when the draft
    /// already holds it, and otherwise follows what the person typed after a blank line.
    public static func merge(_ prefill: String, into draft: String) -> String {
        let trimmed = prefill.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return prefill }
        if draft.contains(trimmed) { return draft }
        return "\(draft)\n\n\(prefill)"
    }
}

// MARK: - Send Modes & Harness Usage Formatting

public enum ChatSendMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case send
    case queue
    case steer
    case aside
    case interrupt

    public var id: String { rawValue }

    /// Short mode name used for labels and accessibility (matches web `SEND_MODE_LABEL`).
    public var label: String {
        switch self {
        case .send: "Send"
        case .queue: "Queue"
        case .steer: "Steer"
        case .aside: "Aside"
        case .interrupt: "Interrupt"
        }
    }

    /// Action verb shown on the submit button (matches web `sendModeAction`).
    public var actionLabel: String {
        switch self {
        case .send: "Send"
        case .queue: "Queue"
        case .steer: "Steer"
        case .aside: "Ask aside"
        case .interrupt: "Interrupt"
        }
    }

    /// Tooltip explaining what sending in this mode does (matches web `SEND_MODE_HINT`).
    public var hint: String {
        switch self {
        case .send: "Send message"
        case .queue: "Send this once the current reply ends"
        case .steer: "Steer the active reply mid-turn without losing progress"
        case .aside: "Ask about the current reply without stopping it"
        case .interrupt: "Stop the reply and answer this together with your last message"
        }
    }

    /// SF Symbol for the mode switcher pill (matches web `send-modes.tsx` + `SidebarIcons`).
    public var systemImage: String {
        switch self {
        case .send: "arrow.up"
        case .queue: "clock"
        case .steer: "safari"
        case .aside: "arrow.triangle.branch"
        case .interrupt: "bolt"
        }
    }

    /// SF Symbol for the primary submit button (matches web `SendButton` in `reply-tools.tsx`).
    public var sendButtonSystemImage: String {
        switch self {
        case .send, .queue: "arrow.up"
        case .steer: "safari"
        case .aside: "arrow.triangle.branch"
        case .interrupt: "bolt"
        }
    }

    /// Composer placeholder reflecting the active send mode (matches web `sendModePlaceholder`).
    public func placeholder(personaName: String) -> String {
        switch self {
        case .send:
            "Message \(personaName)… (/ for commands, @ for personas)"
        case .queue:
            "Queue a follow-up for when \(personaName) finishes…"
        case .steer:
            "Steer \(personaName) mid-turn without discarding work…"
        case .aside:
            "Ask on the side. \(personaName) keeps working…"
        case .interrupt:
            "Stop \(personaName) and steer it…"
        }
    }

    /// Cycles through `runningModes` (Tab / Shift+Tab while a reply is running).
    public func cycled(backward: Bool = false) -> ChatSendMode {
        let modes = Self.runningModes
        guard let idx = modes.firstIndex(of: self) else {
            return backward ? modes[modes.count - 1] : modes[0]
        }
        let step = backward ? modes.count - 1 : 1
        return modes[(idx + step) % modes.count]
    }

    public static let runningModes: [ChatSendMode] = [.queue, .steer, .aside, .interrupt]
}

public enum ChatComposerSendLogic {
    public static func resolveSendMode(
        isRunning: Bool,
        preferredWhileRunning: ChatSendMode,
        parsedCommand: ChatParsedCommand?
    ) -> ChatSendMode {
        if let cmd = parsedCommand {
            switch cmd.name {
            case "steer": return isRunning ? .steer : .send
            case "queue": return isRunning ? .queue : .send
            case "aside": return .aside
            default: break
            }
        }
        guard isRunning else { return .send }
        return preferredWhileRunning == .send ? .queue : preferredWhileRunning
    }

    /// Queue, steer, and aside endpoints carry text only; interrupt and ordinary send accept attachments, context chips, and research mode.
    public static func textOnlyValidationError(
        mode: ChatSendMode,
        hasAttachments: Bool,
        hasContextChips: Bool,
        researchMode: Bool
    ) -> String? {
        guard mode == .queue || mode == .steer || mode == .aside else { return nil }
        guard hasAttachments || hasContextChips || researchMode else { return nil }
        let subject: String = switch mode {
        case .aside: "An aside"
        case .steer: "A steer"
        default: "A follow-up"
        }
        return "\(subject) is text only: remove the context and files, or pick Interrupt to send them now."
    }
}

public struct ChatDictationAnchor: Equatable, Sendable {
    public let prefix: String
    public let suffix: String

    public init(prefix: String, suffix: String) {
        self.prefix = prefix
        self.suffix = suffix
    }
}

public enum ChatComposerDictationLogic {
    /// Minimum press duration (seconds) that activates press-and-hold push-to-talk.
    public static let holdThresholdSeconds: TimeInterval = 0.28

    public enum ReleaseAction: Sendable, Equatable {
        case stopAndCommit
        case keepListening
    }

    /// Resolves mic button release between press-and-hold push-to-talk and tap-to-toggle.
    public static func releaseAction(
        elapsedSeconds: TimeInterval,
        wasListeningBeforePress: Bool
    ) -> ReleaseAction {
        if wasListeningBeforePress { return .stopAndCommit }
        return elapsedSeconds >= holdThresholdSeconds ? .stopAndCommit : .keepListening
    }

    /// Splits `text` at a UTF-16 cursor offset (clamped to valid bounds) into prefix and suffix.
    public static func anchor(in text: String, cursorUTF16: Int) -> ChatDictationAnchor {
        let ns = text as NSString
        let clamped = max(0, min(cursorUTF16, ns.length))
        return ChatDictationAnchor(
            prefix: ns.substring(to: clamped),
            suffix: ns.substring(from: clamped)
        )
    }

    /// Composes `anchor` with `spoken` text, adding separating spaces only when adjacent text
    /// doesn't already have whitespace, and returns the updated text plus the UTF-16 cursor
    /// offset immediately after `spoken`.
    public static func compose(anchor: ChatDictationAnchor, spoken: String) -> (text: String, cursorUTF16: Int) {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (anchor.prefix + anchor.suffix, (anchor.prefix as NSString).length)
        }
        let needsLeadingSpace = anchor.prefix.last.map { !$0.isWhitespace } ?? false
        let needsTrailingSpace = anchor.suffix.first.map { !$0.isWhitespace } ?? false
        let leading = needsLeadingSpace ? " " : ""
        let trailing = needsTrailingSpace ? " " : ""
        let combined = anchor.prefix + leading + trimmed + trailing + anchor.suffix
        let cursor = (anchor.prefix as NSString).length + ((leading + trimmed) as NSString).length
        return (combined, cursor)
    }
}

public enum ChatHarnessUsageLogic {
    public static func compactBadge(for activity: API.HarnessActivity) -> String {
        if !activity.connected { return "Offline" }
        if activity.limitedUntil != nil { return "Limited" }
        if activity.usageChecking && activity.windows.isEmpty { return "Checking…" }
        if let primary = activity.windows.first {
            return "\(Int(primary.usedPercent.rounded()))%"
        }
        return activity.running > 0 ? "\(activity.running) active" : "Ready"
    }

    public static func railUsageRows(for activity: API.HarnessActivity, now: Date = Date()) -> [RailUsage] {
        guard activity.usageAvailable else {
            return [
                RailUsage(
                    id: "\(activity.harness):unavailable",
                    title: activity.label,
                    value: activity.connected ? "Connected" : "Offline",
                    unavailable: true,
                    sub: activity.usageChecking ? "Checking plan allowance…" : "Plan allowance not reported for this harness."
                ),
            ]
        }

        if activity.windows.isEmpty {
            return [
                RailUsage(
                    id: "\(activity.harness):empty",
                    title: activity.label,
                    value: activity.limitedUntil != nil ? "Limited" : "Ready",
                    tone: activity.limitedUntil != nil ? .limited : .normal,
                    unavailable: true,
                    sub: activity.limitedUntil.map { "Limited until \(resetLabel($0, now: now))" }
                ),
            ]
        }

        return activity.windows.map { window in
            let clamped = min(max(window.usedPercent, 0), 100)
            let tone: UsageTone = (activity.limitedUntil != nil || clamped >= 100)
                ? .limited
                : (clamped >= 80 ? .warn : .normal)
            var meta: [String] = []
            if let plan = activity.plan, !plan.isEmpty {
                meta.append(plan.capitalized)
            }
            if let resetsAt = window.resetsAt {
                meta.append("Resets \(resetLabel(resetsAt, now: now))")
            }
            return RailUsage(
                id: "\(activity.harness):\(window.id)",
                title: window.label,
                value: "\(Int(clamped.rounded()))%",
                fraction: clamped / 100.0,
                tone: tone,
                meta: meta.isEmpty ? nil : meta
            )
        }
    }

    private static func resetLabel(_ iso: String, now: Date) -> String {
        guard let date = APIDate.parse(iso) else { return iso }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 60 { return "soon" }
        let minutes = seconds / 60
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rem = minutes % 60
            return rem > 0 ? "in \(hours)h \(rem)m" : "in \(hours)h"
        }
        return "in \(hours / 24)d"
    }
}
