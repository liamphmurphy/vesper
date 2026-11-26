import Foundation

// MARK: - Trigger & Candidate Models

/// Kind of completion triggered at the caret, porting and extending `web/lib/knowledge-completion.ts`.
public enum KnowledgeCompletionTriggerKind: Sendable, Equatable, Hashable {
    /// `[[query` — page link completion.
    case page
    /// `[[Target#query` — heading completion within `target` (empty `target` means current document).
    case heading(target: String)
    /// `[[Target^query` or `[[Target#^query` — block ID completion within `target`.
    case blockID(target: String, usesHashPrefix: Bool)
    /// `![[query` — embed/asset completion.
    case embed
    /// `#query` — tag completion.
    case tag
}

/// Active completion trigger detected at a UTF-16 caret offset.
public struct KnowledgeCompletionTrigger: Sendable, Equatable, Hashable {
    public let kind: KnowledgeCompletionTriggerKind
    /// Text typed after the trigger delimiter, used to filter/rank candidates.
    public let query: String
    /// Full UTF-16 range to replace when accepting a candidate (including any trailing `]]` after the caret).
    public let replacementRange: NSRange
    /// UTF-16 start offset of the trigger delimiter (`[[`, `![[`, or `#`), used for Escape dismissal tracking.
    public var triggerOffset: Int { replacementRange.location }

    public init(kind: KnowledgeCompletionTriggerKind, query: String, replacementRange: NSRange) {
        self.kind = kind
        self.query = query
        self.replacementRange = replacementRange
    }
}

/// Candidate kind for filtering against a `KnowledgeCompletionTrigger`.
public enum KnowledgeCompletionCandidateKind: Sendable, Equatable, Hashable {
    case page
    case heading
    case blockID
    case embed
    case tag
}

/// A single completion suggestion item.
public struct KnowledgeCompletionCandidate: Sendable, Equatable, Hashable {
    public let kind: KnowledgeCompletionCandidateKind
    /// Display title shown in the popup (e.g. note title, heading text, asset name, tag name).
    public let title: String
    /// Value inserted into the syntax (e.g. note path, heading text, block id without `^`, asset ref, tag without `#`).
    public let insertRef: String
    /// Secondary detail line (e.g. folder path, MIME type, usage count).
    public let detail: String
    /// Optional SF Symbol name override (e.g. `film`, `waveform`, `doc.richtext` for `![[` attachment types).
    public let symbolName: String?

    public init(
        kind: KnowledgeCompletionCandidateKind,
        title: String,
        insertRef: String,
        detail: String = "",
        symbolName: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.insertRef = insertRef
        self.detail = detail
        self.symbolName = symbolName
    }
}

/// Result of accepting a completion candidate: exact UTF-16 range, text to insert, and resulting caret offset.
public struct KnowledgeCompletionInsertion: Sendable, Equatable, Hashable {
    public let replacementRange: NSRange
    public let insertedText: String
    public let newCaretUTF16: Int

    public init(replacementRange: NSRange, insertedText: String, newCaretUTF16: Int) {
        self.replacementRange = replacementRange
        self.insertedText = insertedText
        self.newCaretUTF16 = newCaretUTF16
    }
}

// MARK: - Completion Logic

/// Pure Foundation port of `web/lib/knowledge-completion.ts` for `[[`, `![[`, and `#` triggers.
public enum KnowledgeCompletionLogic: Sendable {
    private static let maxQueryLength = 200
    private static let escapedTrailingBackslashesRegex = compile("(?:^|[^\\\\])(?:\\\\\\\\)*\\\\$")
    private static let closingBracketsRegex = compile("^[^\\[\\]\\n]*\\]\\]")
    private static let trailingTagCharsRegex = compile("^[\\p{L}\\p{N}_/-]*")

    private static func compile(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    // MARK: Trigger Detection

    /// Detects an active `[[`, `![[`, or `#` completion trigger at `caretUTF16` (collapsed selection).
    /// Returns `nil` inside fenced code, frontmatter, inline code, escaped brackets, triple brackets, or link aliases.
    public static func matchTrigger(in text: String, caretUTF16: Int) -> KnowledgeCompletionTrigger? {
        let ns = text as NSString
        guard caretUTF16 >= 0, caretUTF16 <= ns.length else { return nil }
        if KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: caretUTF16, in: text) {
            return nil
        }

        // Find current line bounds around `caretUTF16`.
        let lineStart = findLineStart(in: ns, before: caretUTF16)
        let lineEnd = findLineEnd(in: ns, from: caretUTF16)
        let before = ns.substring(with: NSRange(location: lineStart, length: caretUTF16 - lineStart))
        let after = ns.substring(with: NSRange(location: caretUTF16, length: lineEnd - caretUTF16))

        if let linkTrigger = matchBracketTrigger(
            before: before,
            after: after,
            lineStart: lineStart,
            caretUTF16: caretUTF16
        ) {
            return linkTrigger
        }

        return matchTagTrigger(
            before: before,
            after: after,
            lineStart: lineStart,
            caretUTF16: caretUTF16
        )
    }

    private static func matchBracketTrigger(
        before: String,
        after: String,
        lineStart: Int,
        caretUTF16: Int
    ) -> KnowledgeCompletionTrigger? {
        let beforeNS = before as NSString
        let openRange = beforeNS.range(of: "[[", options: .backwards)
        guard openRange.location != NSNotFound else { return nil }

        let at = openRange.location
        // Reject triple bracket `[[[` or escaped `\[[` (odd trailing backslashes before `[[`).
        if at > 0 && beforeNS.character(at: at - 1) == 0x5B { // '['
            return nil
        }
        let prefixBeforeOpen = beforeNS.substring(to: at)
        if escapedTrailingBackslashesRegex.firstMatch(
            in: prefixBeforeOpen,
            range: NSRange(location: 0, length: (prefixBeforeOpen as NSString).length)
        ) != nil {
            return nil
        }

        let inner = beforeNS.substring(from: at + 2)
        // Port of web/lib/knowledge-completion.ts: disallow brackets, newlines, alias '|', object replacement char.
        if (inner as NSString).length > maxQueryLength { return nil }
        for scalar in inner.unicodeScalars {
            if scalar == "[" || scalar == "]" || scalar == "\n" || scalar == "|" || scalar == "\u{FFFC}" {
                return nil
            }
        }

        let isEmbed = at > 0 && beforeNS.character(at: at - 1) == 0x21 // '!'
        let startUTF16 = lineStart + at - (isEmbed ? 1 : 0)

        // Include any existing closing `]]` on the same line after the caret.
        let afterNS = after as NSString
        let closingLen: Int
        if let m = closingBracketsRegex.firstMatch(in: after, range: NSRange(location: 0, length: afterNS.length)) {
            closingLen = m.range.length
        } else {
            closingLen = 0
        }
        let replacementRange = NSRange(location: startUTF16, length: (caretUTF16 - startUTF16) + closingLen)

        if isEmbed {
            return KnowledgeCompletionTrigger(kind: .embed, query: inner, replacementRange: replacementRange)
        }

        if let hashCaret = inner.range(of: "#^") {
            let target = String(inner[..<hashCaret.lowerBound])
            let query = String(inner[hashCaret.upperBound...])
            return KnowledgeCompletionTrigger(
                kind: .blockID(target: target, usesHashPrefix: true),
                query: query,
                replacementRange: replacementRange
            )
        }
        if let caret = inner.firstIndex(of: "^") {
            let target = String(inner[..<caret])
            let query = String(inner[inner.index(after: caret)...])
            return KnowledgeCompletionTrigger(
                kind: .blockID(target: target, usesHashPrefix: false),
                query: query,
                replacementRange: replacementRange
            )
        }
        if let hash = inner.firstIndex(of: "#") {
            let target = String(inner[..<hash])
            let query = String(inner[inner.index(after: hash)...])
            return KnowledgeCompletionTrigger(
                kind: .heading(target: target),
                query: query,
                replacementRange: replacementRange
            )
        }

        return KnowledgeCompletionTrigger(kind: .page, query: inner, replacementRange: replacementRange)
    }

    private static func matchTagTrigger(
        before: String,
        after: String,
        lineStart: Int,
        caretUTF16: Int
    ) -> KnowledgeCompletionTrigger? {
        let beforeNS = before as NSString
        guard beforeNS.length > 0 else { return nil }

        // Walk backwards across valid tag characters to locate `#`.
        var idx = beforeNS.length
        while idx > 0 {
            let ch = beforeNS.character(at: idx - 1)
            if isTagBodyUTF16Unit(ch) {
                idx -= 1
            } else {
                break
            }
        }
        guard idx > 0, beforeNS.character(at: idx - 1) == 0x23 else { // '#'
            return nil
        }

        let hashPos = idx - 1
        // Match `(?<![\w/#])#`: character before `#` must not be word char, `/`, or `#`.
        if hashPos > 0 {
            let prev = beforeNS.character(at: hashPos - 1)
            if isWordOrSlashOrHash(prev) {
                return nil
            }
        }

        let query = beforeNS.substring(from: idx)
        guard (query as NSString).length <= maxQueryLength else { return nil }

        // Consume any trailing tag characters after the caret so replacement is clean.
        let afterNS = after as NSString
        let trailingLen: Int
        if let m = trailingTagCharsRegex.firstMatch(in: after, range: NSRange(location: 0, length: afterNS.length)) {
            trailingLen = m.range.length
        } else {
            trailingLen = 0
        }

        let startUTF16 = lineStart + hashPos
        let replacementRange = NSRange(location: startUTF16, length: (caretUTF16 - startUTF16) + trailingLen)
        return KnowledgeCompletionTrigger(kind: .tag, query: query, replacementRange: replacementRange)
    }

    // MARK: Ranking & Filtering

    /// Filters `candidates` to those matching `trigger` and ranks them deterministically by relevance.
    public static func rankCandidates(
        _ candidates: [KnowledgeCompletionCandidate],
        for trigger: KnowledgeCompletionTrigger,
        limit: Int? = nil
    ) -> [KnowledgeCompletionCandidate] {
        let expectedKind = candidateKind(for: trigger.kind)
        let query = trigger.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let matchingKind = candidates.filter { $0.kind == expectedKind }
        if query.isEmpty {
            let sorted = matchingKind.sorted { lhs, rhs in
                let titleCmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleCmp != .orderedSame { return titleCmp == .orderedAscending }
                return lhs.insertRef.localizedCaseInsensitiveCompare(rhs.insertRef) == .orderedAscending
            }
            if let limit, limit >= 0 { return Array(sorted.prefix(limit)) }
            return sorted
        }

        var scored: [(candidate: KnowledgeCompletionCandidate, score: Int)] = []
        for candidate in matchingKind {
            if let score = matchScore(candidate: candidate, query: query) {
                scored.append((candidate, score))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.title.count != rhs.candidate.title.count {
                return lhs.candidate.title.count < rhs.candidate.title.count
            }
            let titleCmp = lhs.candidate.title.localizedCaseInsensitiveCompare(rhs.candidate.title)
            if titleCmp != .orderedSame { return titleCmp == .orderedAscending }
            return lhs.candidate.insertRef.localizedCaseInsensitiveCompare(rhs.candidate.insertRef) == .orderedAscending
        }

        let ranked = scored.map(\.candidate)
        if let limit, limit >= 0 { return Array(ranked.prefix(limit)) }
        return ranked
    }

    private static func candidateKind(for triggerKind: KnowledgeCompletionTriggerKind) -> KnowledgeCompletionCandidateKind {
        switch triggerKind {
        case .page: return .page
        case .heading: return .heading
        case .blockID: return .blockID
        case .embed: return .embed
        case .tag: return .tag
        }
    }

    private static func matchScore(candidate: KnowledgeCompletionCandidate, query: String) -> Int? {
        let title = candidate.title.lowercased()
        let ref = candidate.insertRef.lowercased()
        let detail = candidate.detail.lowercased()
        let leaf = ref.components(separatedBy: "/").last ?? ref

        if title == query || ref == query || leaf == query { return 1000 }
        if title.hasPrefix(query) || leaf.hasPrefix(query) { return 800 }
        if ref.hasPrefix(query) { return 700 }
        if hasWordPrefixMatch(in: title, query: query) || hasWordPrefixMatch(in: ref, query: query) { return 600 }
        if title.contains(query) { return 500 }
        if ref.contains(query) { return 400 }
        if !detail.isEmpty && detail.contains(query) { return 250 }
        if isSubsequence(query, of: title) || isSubsequence(query, of: leaf) { return 200 }
        return nil
    }

    private static func hasWordPrefixMatch(in haystack: String, query: String) -> Bool {
        let separators = CharacterSet.alphanumerics.inverted
        let parts = haystack.components(separatedBy: separators)
        return parts.contains { $0.hasPrefix(query) }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var needleIdx = needle.startIndex
        for ch in haystack where needleIdx < needle.endIndex {
            if ch == needle[needleIdx] {
                needleIdx = needle.index(after: needleIdx)
            }
        }
        return needleIdx == needle.endIndex
    }

    // MARK: Insertion Calculation

    /// Computes the exact UTF-16 replacement range, inserted text, and post-insertion caret offset.
    public static func insertion(
        for candidate: KnowledgeCompletionCandidate,
        trigger: KnowledgeCompletionTrigger
    ) -> KnowledgeCompletionInsertion {
        let text: String
        switch trigger.kind {
        case .page:
            text = "[[\(candidate.insertRef)]]"
        case .heading(let target):
            text = "[[\(target)#\(candidate.insertRef)]]"
        case .blockID(let target, let usesHashPrefix):
            let cleanID = candidate.insertRef.hasPrefix("^") ? String(candidate.insertRef.dropFirst()) : candidate.insertRef
            let sep = usesHashPrefix ? "#^" : "^"
            text = "[[\(target)\(sep)\(cleanID)]]"
        case .embed:
            text = "![[\(candidate.insertRef)]]"
        case .tag:
            let cleanTag = candidate.insertRef.hasPrefix("#") ? String(candidate.insertRef.dropFirst()) : candidate.insertRef
            text = "#\(cleanTag)"
        }
        let insertedUTF16Len = (text as NSString).length
        return KnowledgeCompletionInsertion(
            replacementRange: trigger.replacementRange,
            insertedText: text,
            newCaretUTF16: trigger.replacementRange.location + insertedUTF16Len
        )
    }

    /// Applies `insertion` to `text` using UTF-16 `NSRange` semantics.
    public static func apply(_ insertion: KnowledgeCompletionInsertion, to text: String) -> String {
        let ns = text as NSString
        guard insertion.replacementRange.location >= 0,
              insertion.replacementRange.location + insertion.replacementRange.length <= ns.length else {
            return text
        }
        return ns.replacingCharacters(in: insertion.replacementRange, with: insertion.insertedText)
    }

    // MARK: UTF-16 Helpers

    private static func findLineStart(in ns: NSString, before offset: Int) -> Int {
        var idx = offset
        while idx > 0 {
            if ns.character(at: idx - 1) == 0x0A { // '\n'
                break
            }
            idx -= 1
        }
        return idx
    }

    private static func findLineEnd(in ns: NSString, from offset: Int) -> Int {
        var idx = offset
        while idx < ns.length {
            let ch = ns.character(at: idx)
            if ch == 0x0A || ch == 0x0D { // '\n' or '\r'
                break
            }
            idx += 1
        }
        return idx
    }

    private static func isTagBodyUTF16Unit(_ unit: unichar) -> Bool {
        if unit == 0x5F || unit == 0x2F || unit == 0x2D { return true } // '_', '/', '-'
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isWordOrSlashOrHash(_ unit: unichar) -> Bool {
        if unit == 0x5F || unit == 0x2F || unit == 0x23 { return true } // '_', '/', '#'
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}

// MARK: - Completion Popup Session State

/// Pure state machine for keyboard navigation and Escape dismissal (mirrors `Completion` in `web/lib/knowledge-completion.ts`).
public struct KnowledgeCompletionSession: Sendable, Equatable {
    public var trigger: KnowledgeCompletionTrigger?
    public var candidates: [KnowledgeCompletionCandidate]
    public var activeIndex: Int
    public var dismissedAtOffset: Int?

    public var isOpen: Bool { trigger != nil }

    public init(
        trigger: KnowledgeCompletionTrigger? = nil,
        candidates: [KnowledgeCompletionCandidate] = [],
        activeIndex: Int = 0,
        dismissedAtOffset: Int? = nil
    ) {
        self.trigger = trigger
        self.candidates = candidates
        self.activeIndex = activeIndex
        self.dismissedAtOffset = dismissedAtOffset
    }

    public mutating func update(
        text: String,
        caretUTF16: Int,
        allCandidates: [KnowledgeCompletionCandidate],
        limit: Int? = 20
    ) {
        guard let next = KnowledgeCompletionLogic.matchTrigger(in: text, caretUTF16: caretUTF16) else {
            dismissedAtOffset = nil
            close()
            return
        }
        if dismissedAtOffset == next.triggerOffset {
            return
        }
        let ranked = KnowledgeCompletionLogic.rankCandidates(allCandidates, for: next, limit: limit)
        if trigger?.triggerOffset != next.triggerOffset || trigger?.query != next.query || trigger?.kind != next.kind {
            activeIndex = 0
        } else if !ranked.isEmpty {
            activeIndex = min(activeIndex, ranked.count - 1)
        } else {
            activeIndex = 0
        }
        trigger = next
        candidates = ranked
    }

    public mutating func moveSelection(delta: Int) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        activeIndex = ((activeIndex + delta) % count + count) % count
    }

    public mutating func dismiss() {
        dismissedAtOffset = trigger?.triggerOffset
        close()
    }

    public mutating func close() {
        trigger = nil
        candidates = []
        activeIndex = 0
    }

    public mutating func acceptActive() -> KnowledgeCompletionInsertion? {
        guard let trigger, activeIndex >= 0, activeIndex < candidates.count else { return nil }
        let insertion = KnowledgeCompletionLogic.insertion(for: candidates[activeIndex], trigger: trigger)
        close()
        return insertion
    }
}
