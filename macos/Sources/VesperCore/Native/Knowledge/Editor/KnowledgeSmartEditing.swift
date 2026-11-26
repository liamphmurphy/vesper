import Foundation

/// Pure Foundation smart-editing engine for the Knowledge markdown editor:
/// - Enter continues `- [ ] `, `- `, `* `, `+ `, and `1. ` lists (and exits empty items)
/// - Tab / Shift+Tab indents and outdents list items and multi-line selections
/// - Auto-closes `[[`, `` ` ``, and `**`, wraps selections, skips over closing delimiters,
///   and deletes matched empty pairs on Backspace.
public enum KnowledgeSmartEditing: Sendable {
    public typealias EditResult = KnowledgeMarkdownFormatting.EditResult

    private static let checklistRegex = compile("^([ \\t]*)([-*+])([ \\t]+)\\[[ xX]\\]([ \\t]+)(.*)$")
    private static let unorderedRegex = compile("^([ \\t]*)([-*+])([ \\t]+)(.*)$")
    private static let orderedRegex = compile("^([ \\t]*)(\\d+)([.)])([ \\t]+)(.*)$")

    private static func compile(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    // MARK: - Smart Newline (List / Checklist Continuation)

    /// Computes a smart list/checklist continuation or empty-item exit for Return/Enter.
    /// Returns `nil` when the caret is not on a list line or is inside a fenced code block/frontmatter.
    public static func handleNewline(in text: String, selection: NSRange) -> EditResult? {
        let ns = text as NSString
        guard selection.location >= 0, selection.location + selection.length <= ns.length else {
            return nil
        }
        if KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: selection.location, in: text) {
            return nil
        }

        let lineBounds = lineContentRange(containing: selection.location, in: ns)
        let lineText = ns.substring(with: lineBounds)
        let lineNS = lineText as NSString
        let wholeLine = NSRange(location: 0, length: lineNS.length)

        let prefixUTF16Length: Int
        let nextLinePrefix: String

        if let m = checklistRegex.firstMatch(in: lineText, range: wholeLine) {
            let indent = lineNS.substring(with: m.range(at: 1))
            let bullet = lineNS.substring(with: m.range(at: 2))
            let bodyRange = m.range(at: 5)
            prefixUTF16Length = bodyRange.location
            nextLinePrefix = "\(indent)\(bullet) [ ] "
        } else if let m = unorderedRegex.firstMatch(in: lineText, range: wholeLine) {
            let indent = lineNS.substring(with: m.range(at: 1))
            let bullet = lineNS.substring(with: m.range(at: 2))
            let bodyRange = m.range(at: 4)
            prefixUTF16Length = bodyRange.location
            nextLinePrefix = "\(indent)\(bullet) "
        } else if let m = orderedRegex.firstMatch(in: lineText, range: wholeLine) {
            let indent = lineNS.substring(with: m.range(at: 1))
            let numStr = lineNS.substring(with: m.range(at: 2))
            let delim = lineNS.substring(with: m.range(at: 3))
            let bodyRange = m.range(at: 5)
            guard let num = Int(numStr) else { return nil }
            prefixUTF16Length = bodyRange.location
            nextLinePrefix = "\(indent)\(num + 1)\(delim) "
        } else {
            return nil
        }

        let caretInLine = selection.location - lineBounds.location
        // If caret is before the list marker body (e.g. at column 0 before `- `), let normal newline run.
        guard caretInLine >= prefixUTF16Length else {
            return nil
        }

        let bodyText = lineNS.substring(from: prefixUTF16Length)
        let isEmptyItem = bodyText.trimmingCharacters(in: .whitespaces).isEmpty && selection.length == 0
        if isEmptyItem {
            // Exit the list by clearing the empty list prefix on the current line.
            let next = ns.replacingCharacters(in: lineBounds, with: "")
            return EditResult(text: next, selection: NSRange(location: lineBounds.location, length: 0))
        }

        let insertion = "\n" + nextLinePrefix
        let next = ns.replacingCharacters(in: selection, with: insertion)
        let caretAfter = selection.location + (insertion as NSString).length
        return EditResult(text: next, selection: NSRange(location: caretAfter, length: 0))
    }

    // MARK: - Smart Tab / Shift+Tab Indent & Outdent

    /// Indents (`outdent == false`) or outdents (`outdent == true`) list items or multi-line selections.
    /// Returns `nil` for collapsed non-list lines on Tab (so standard Tab behavior applies) or when nothing changes.
    public static func handleTab(
        in text: String,
        selection: NSRange,
        outdent: Bool,
        indentUnit: String = "  "
    ) -> EditResult? {
        let ns = text as NSString
        guard selection.location >= 0, selection.location + selection.length <= ns.length else {
            return nil
        }
        if KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: selection.location, in: text) {
            return nil
        }

        let firstLine = lineContentRange(containing: selection.location, in: ns)
        let endAnchor: Int
        if selection.length > 0 {
            let selEnd = selection.location + selection.length
            // When selection ends right at the start of a new line, don't include that trailing line.
            if selEnd > selection.location && selEnd > 0 && ns.character(at: selEnd - 1) == 0x0A {
                endAnchor = selEnd - 1
            } else {
                endAnchor = selEnd
            }
        } else {
            endAnchor = selection.location
        }
        let lastLine = lineContentRange(containing: endAnchor, in: ns)
        let isMultiLine = firstLine.location != lastLine.location

        if !isMultiLine {
            let lineText = ns.substring(with: firstLine)
            if !outdent && !isListLine(lineText) {
                return nil
            }
            if outdent {
                let removed = leadingOutdentLength(of: lineText, maxSpaces: indentUnit.count)
                guard removed > 0 else { return nil }
                let next = ns.replacingCharacters(in: NSRange(location: firstLine.location, length: removed), with: "")
                let newLoc = max(firstLine.location, selection.location - removed)
                let newEnd = max(newLoc, selection.location + selection.length - removed)
                return EditResult(text: next, selection: NSRange(location: newLoc, length: newEnd - newLoc))
            } else {
                let unitLen = (indentUnit as NSString).length
                let next = ns.replacingCharacters(in: NSRange(location: firstLine.location, length: 0), with: indentUnit)
                return EditResult(
                    text: next,
                    selection: NSRange(location: selection.location + unitLen, length: selection.length)
                )
            }
        }

        // Multi-line block indent / outdent.
        let blockStart = firstLine.location
        let blockEnd = lastLine.location + lastLine.length
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        let blockText = ns.substring(with: blockRange)
        let lines = blockText.components(separatedBy: "\n")

        var newLines: [String] = []
        newLines.reserveCapacity(lines.count)
        var firstDelta = 0
        var totalDelta = 0
        let unitLen = (indentUnit as NSString).length

        for (idx, line) in lines.enumerated() {
            if outdent {
                let removed = leadingOutdentLength(of: line, maxSpaces: indentUnit.count)
                if idx == 0 { firstDelta = -removed }
                totalDelta -= removed
                newLines.append(removed > 0 ? String(line.dropFirst(removed)) : line)
            } else {
                if idx == 0 { firstDelta = unitLen }
                totalDelta += unitLen
                newLines.append(indentUnit + line)
            }
        }

        guard totalDelta != 0 else { return nil }
        let replacement = newLines.joined(separator: "\n")
        let next = ns.replacingCharacters(in: blockRange, with: replacement)
        let newStart = max(blockStart, selection.location + firstDelta)
        let newEnd = max(newStart, selection.location + selection.length + totalDelta)
        return EditResult(text: next, selection: NSRange(location: newStart, length: newEnd - newStart))
    }

    // MARK: - Auto-Pair (`[[`, `` ` ``, `**`), Skip-Over & Selection Wrapping

    /// Intercepts single-character typing for `[[`, `` ` ``, `**` auto-closing, selection wrapping,
    /// and closing-delimiter skip-over. Returns `nil` to fall through to default insertion.
    public static func handleTypedText(
        _ inserted: String,
        in text: String,
        selection: NSRange
    ) -> EditResult? {
        guard inserted.count == 1 else { return nil }
        let ns = text as NSString
        guard selection.location >= 0, selection.location + selection.length <= ns.length else {
            return nil
        }

        let ch = inserted
        guard ch == "[" || ch == "]" || ch == "`" || ch == "*" else { return nil }

        // Never auto-pair inside fenced code blocks or YAML frontmatter.
        if isInsideFencedCodeOrFrontmatter(utf16Offset: selection.location, in: text) {
            return nil
        }

        // Non-empty selection wrapping: `[sel]`, `` `sel` ``, `*sel*` (typing `[` or `*` twice builds `[[sel]]` / `**sel**`).
        if selection.length > 0 {
            let pair: (String, String)? = switch ch {
            case "[": ("[", "]")
            case "`": ("`", "`")
            case "*": ("*", "*")
            default: nil
            }
            guard let (open, close) = pair else { return nil }
            let selected = ns.substring(with: selection)
            guard !selected.contains("\n"), !selected.contains("\r") else { return nil }
            let wrapped = "\(open)\(selected)\(close)"
            let next = ns.replacingCharacters(in: selection, with: wrapped)
            return EditResult(
                text: next,
                selection: NSRange(location: selection.location + (open as NSString).length, length: selection.length)
            )
        }

        let loc = selection.location
        let prev1: unichar? = loc >= 1 ? ns.character(at: loc - 1) : nil
        let prev2: unichar? = loc >= 2 ? ns.character(at: loc - 2) : nil
        let next1: unichar? = loc < ns.length ? ns.character(at: loc) : nil
        let next2: unichar? = loc + 1 < ns.length ? ns.character(at: loc + 1) : nil

        // Skip inline code for `[`, `]`, `*` (but still allow `` ` `` skip-over to exit inline code!).
        if ch != "`", KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: loc, in: text) {
            return nil
        }

        switch ch {
        case "[":
            // Auto-close `[[` -> `[[|]]` when typing the second `[` (not `[[[`, not escaped `\[`, not already before `]]`).
            guard prev1 == 0x5B, prev2 != 0x5B, prev2 != 0x5C else { return nil } // '[', not '[', not '\'
            if next1 == 0x5D && next2 == 0x5D { return nil } // already before `]]`
            let next = ns.replacingCharacters(in: selection, with: "[]]")
            return EditResult(text: next, selection: NSRange(location: loc + 1, length: 0))

        case "]":
            // Skip over an existing closing `]` when completing `[[...]]`.
            guard next1 == 0x5D else { return nil }
            return EditResult(text: text, selection: NSRange(location: loc + 1, length: 0))

        case "`":
            // Case 1: Caret is directly between `` `|` `` -> skip over closing `` ` `` so typing a 3rd `` ` `` builds ```` ``` ```` cleanly.
            if prev1 == 0x60 && next1 == 0x60 {
                return EditResult(text: text, selection: NSRange(location: loc + 1, length: 0))
            }
            // Case 2: Preceded by `` `` `` -> let 3rd backtick insert normally for a fenced code block.
            if prev1 == 0x60 && prev2 == 0x60 {
                return nil
            }
            // Case 3: Immediately before a closing `` ` `` (e.g. `` `code|` ``) -> skip over it.
            if next1 == 0x60 {
                return EditResult(text: text, selection: NSRange(location: loc + 1, length: 0))
            }
            // Case 4: Escaped `\`` or mid-word -> insert normally.
            if prev1 == 0x5C || isAlphanumericUTF16(prev1) || isAlphanumericUTF16(next1) {
                return nil
            }
            // Case 5: Auto-close `` ` `` -> `` `|` ``.
            let next = ns.replacingCharacters(in: selection, with: "``")
            return EditResult(text: next, selection: NSRange(location: loc + 1, length: 0))

        case "*":
            // Case 1: Immediately before closing `**` (e.g. `**bold|**`) or second closing `*` (`**bold*|*`) -> skip over `*`.
            if next1 == 0x2A && (next2 == 0x2A || prev1 == 0x2A) {
                // Only skip when there is an opening `**` earlier on this line so we don't block typing `**` before an existing `*`.
                let lineBounds = lineContentRange(containing: loc, in: ns)
                let beforeOnLine = ns.substring(with: NSRange(location: lineBounds.location, length: loc - lineBounds.location))
                if beforeOnLine.contains("**") {
                    return EditResult(text: text, selection: NSRange(location: loc + 1, length: 0))
                }
            }
            // Case 2: Typing the 2nd `*` after a single `*` (not `***`, not `\*`, not already before `**`) -> `**|**`.
            guard prev1 == 0x2A, prev2 != 0x2A, prev2 != 0x5C else { return nil }
            if next1 == 0x2A && next2 == 0x2A { return nil }
            let next = ns.replacingCharacters(in: selection, with: "***")
            return EditResult(text: next, selection: NSRange(location: loc + 1, length: 0))

        default:
            return nil
        }
    }

    // MARK: - Paired Backspace

    /// Deletes matching auto-closed empty delimiters on Backspace (`[[|]]` -> `[|`, `` `|` `` -> `|`, `**|**` -> `*|`).
    public static func handleBackspace(in text: String, selection: NSRange) -> EditResult? {
        guard selection.length == 0 else { return nil }
        let ns = text as NSString
        let loc = selection.location
        guard loc >= 1, loc < ns.length else { return nil }

        // `` `|` `` -> remove both backticks.
        if ns.character(at: loc - 1) == 0x60 && ns.character(at: loc) == 0x60 {
            let next = ns.replacingCharacters(in: NSRange(location: loc - 1, length: 2), with: "")
            return EditResult(text: next, selection: NSRange(location: loc - 1, length: 0))
        }

        // `[[|]]` -> remove second `[` and closing `]]`, leaving `[|`.
        if loc >= 2, loc + 2 <= ns.length,
           ns.character(at: loc - 2) == 0x5B, ns.character(at: loc - 1) == 0x5B,
           ns.character(at: loc) == 0x5D, ns.character(at: loc + 1) == 0x5D {
            let next = ns.replacingCharacters(in: NSRange(location: loc - 1, length: 3), with: "")
            return EditResult(text: next, selection: NSRange(location: loc - 1, length: 0))
        }

        // `**|**` -> remove second `*` and closing `**`, leaving `*|`.
        if loc >= 2, loc + 2 <= ns.length,
           ns.character(at: loc - 2) == 0x2A, ns.character(at: loc - 1) == 0x2A,
           ns.character(at: loc) == 0x2A, ns.character(at: loc + 1) == 0x2A {
            let next = ns.replacingCharacters(in: NSRange(location: loc - 1, length: 3), with: "")
            return EditResult(text: next, selection: NSRange(location: loc - 1, length: 0))
        }

        return nil
    }

    // MARK: - Helpers

    private static func isListLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return checklistRegex.firstMatch(in: line, range: range) != nil
            || unorderedRegex.firstMatch(in: line, range: range) != nil
            || orderedRegex.firstMatch(in: line, range: range) != nil
    }

    private static func leadingOutdentLength(of line: String, maxSpaces: Int) -> Int {
        if line.hasPrefix("\t") { return 1 }
        var spaces = 0
        for ch in line {
            if ch == " " && spaces < maxSpaces {
                spaces += 1
            } else {
                break
            }
        }
        return spaces
    }

    private static func lineContentRange(containing utf16Offset: Int, in ns: NSString) -> NSRange {
        let clamped = max(0, min(utf16Offset, ns.length))
        var start = clamped
        while start > 0 && ns.character(at: start - 1) != 0x0A {
            start -= 1
        }
        var end = clamped
        while end < ns.length {
            let c = ns.character(at: end)
            if c == 0x0A || c == 0x0D { break }
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isAlphanumericUTF16(_ unit: unichar?) -> Bool {
        guard let unit, let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isInsideFencedCodeOrFrontmatter(utf16Offset: Int, in markdown: String) -> Bool {
        for token in KnowledgeMarkdownSyntax.scan(markdown) {
            switch token.kind {
            case .fencedCodeBlock, .frontmatter:
                let start = token.range.location
                let end = start + token.range.length
                if utf16Offset > start && utf16Offset < end {
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}
