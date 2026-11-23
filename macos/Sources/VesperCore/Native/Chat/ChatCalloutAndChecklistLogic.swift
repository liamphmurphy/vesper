import Foundation

// MARK: - Callout / Admonition Blocks (LAZYAGENTS-322)

public enum ChatCalloutKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case note
    case tip
    case warning
    case caveat
    case conflict

    public var defaultTitle: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .warning: "Warning"
        case .caveat: "Caveat"
        case .conflict: "Conflict"
        }
    }

    public var systemImage: String {
        switch self {
        case .note: "info.circle.fill"
        case .tip: "lightbulb.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .caveat: "exclamationmark.circle.fill"
        case .conflict: "bolt.trianglebadge.exclamationmark.fill"
        }
    }

    public static func from(rawType: String) -> ChatCalloutKind {
        switch rawType.lowercased() {
        case "note", "info": return .note
        case "tip", "hint", "important": return .tip
        case "warning", "caution", "attention": return .warning
        case "caveat": return .caveat
        case "conflict", "contradiction", "danger": return .conflict
        default: return .note
        }
    }
}

public struct ChatCalloutBlock: Sendable, Equatable, Hashable {
    public var kind: ChatCalloutKind
    public var rawType: String
    public var title: String
    public var body: String
    public var collapsible: Bool
    public var defaultCollapsed: Bool

    public init(
        kind: ChatCalloutKind,
        rawType: String,
        title: String,
        body: String,
        collapsible: Bool = false,
        defaultCollapsed: Bool = false
    ) {
        self.kind = kind
        self.rawType = rawType
        self.title = title
        self.body = body
        self.collapsible = collapsible
        self.defaultCollapsed = defaultCollapsed
    }

    /// Parses a callout header line such as `> [!warning]- Careful here`.
    /// Returns nil for ordinary blockquotes.
    public static func parseHeader(_ line: String) -> (kind: ChatCalloutKind, rawType: String, title: String, collapsible: Bool, defaultCollapsed: Bool)? {
        guard let stripped = stripBlockquotePrefix(line) else { return nil }
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!") else { return nil }
        guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
        let typeStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        guard typeStart < closeBracket else { return nil }
        let rawType = String(trimmed[typeStart..<closeBracket]).trimmingCharacters(in: .whitespaces)
        guard !rawType.isEmpty, rawType.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        var rest = trimmed[trimmed.index(after: closeBracket)...]
        var collapsible = false
        var defaultCollapsed = false
        if let first = rest.first, first == "-" || first == "+" {
            collapsible = true
            defaultCollapsed = (first == "-")
            rest = rest.dropFirst()
        }
        let customTitle = String(rest).trimmingCharacters(in: .whitespaces)
        let kind = ChatCalloutKind.from(rawType: rawType)
        let title = customTitle.isEmpty ? kind.defaultTitle : customTitle
        return (kind, rawType.lowercased(), title, collapsible, defaultCollapsed)
    }

    /// Strips a leading `>` (with optional single following space) from a blockquote line.
    public static func stripBlockquotePrefix(_ line: String) -> String? {
        var idx = line.startIndex
        var leadingSpaces = 0
        while idx < line.endIndex && line[idx] == " " && leadingSpaces < 3 {
            idx = line.index(after: idx)
            leadingSpaces += 1
        }
        guard idx < line.endIndex, line[idx] == ">" else { return nil }
        idx = line.index(after: idx)
        if idx < line.endIndex && line[idx] == " " {
            idx = line.index(after: idx)
        }
        return String(line[idx...])
    }
}

// MARK: - Interactive Checklists (LAZYAGENTS-324)

public struct ChatChecklistItem: Sendable, Equatable, Hashable, Identifiable {
    /// 0-based index across all task-list items in the message outside fenced code blocks,
    /// matching `server/internal/runs/chat_checklists.go`.
    public var index: Int
    public var defaultChecked: Bool
    public var indentLevel: Int
    public var text: String

    public var id: Int { index }

    public init(index: Int, defaultChecked: Bool, indentLevel: Int = 0, text: String) {
        self.index = index
        self.defaultChecked = defaultChecked
        self.indentLevel = indentLevel
        self.text = text
    }
}

public struct ChatChecklistBlock: Sendable, Equatable, Hashable {
    public var items: [ChatChecklistItem]

    public init(items: [ChatChecklistItem]) {
        self.items = items
    }

    public func isChecked(_ item: ChatChecklistItem, state: [String: Bool]?) -> Bool {
        if let override = state?[String(item.index)] {
            return override
        }
        return item.defaultChecked
    }

    public func completedCount(state: [String: Bool]?) -> Int {
        items.filter { isChecked($0, state: state) }.count
    }

    /// Matches a GFM task-list line such as `- [ ] Do thing`, `  * [x] Done`, `1. [ ] Step`.
    public static func parseTaskLine(_ line: String) -> (indentLevel: Int, checked: Bool, text: String)? {
        var spaces = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == " " {
                spaces += 1
                idx = line.index(after: idx)
            } else if ch == "\t" {
                spaces += 2
                idx = line.index(after: idx)
            } else {
                break
            }
        }
        guard idx < line.endIndex else { return nil }
        let ch = line[idx]
        if ch == "-" || ch == "*" || ch == "+" {
            idx = line.index(after: idx)
        } else if ch.isNumber {
            while idx < line.endIndex && line[idx].isNumber {
                idx = line.index(after: idx)
            }
            guard idx < line.endIndex && line[idx] == "." else { return nil }
            idx = line.index(after: idx)
        } else {
            return nil
        }

        // At least one space/tab after bullet or number
        var hadSpace = false
        while idx < line.endIndex && (line[idx] == " " || line[idx] == "\t") {
            hadSpace = true
            idx = line.index(after: idx)
        }
        guard hadSpace else { return nil }

        // Must have `[ ]`, `[x]`, or `[X]` followed by whitespace
        guard idx < line.endIndex, line[idx] == "[" else { return nil }
        let markIdx = line.index(after: idx)
        guard markIdx < line.endIndex else { return nil }
        let mark = line[markIdx]
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        let closeIdx = line.index(after: markIdx)
        guard closeIdx < line.endIndex, line[closeIdx] == "]" else { return nil }
        let afterClose = line.index(after: closeIdx)
        guard afterClose < line.endIndex, line[afterClose] == " " || line[afterClose] == "\t" else { return nil }

        let text = String(line[afterClose...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (indentLevel: min(spaces / 2, 4), checked: mark == "x" || mark == "X", text: text)
    }
}
