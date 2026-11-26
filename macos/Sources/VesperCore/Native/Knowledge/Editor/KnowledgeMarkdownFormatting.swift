import Foundation

/// Pure Markdown formatting transformations for the Knowledge editor toolbar
/// and keyboard shortcuts (`⌘B`, `⌘I`, `⌘E`, `⌘K`, `⌘⇧X`, headings, lists, blocks).
public enum KnowledgeMarkdownFormatting {
    public struct EditResult: Equatable, Sendable {
        public let text: String
        public let selection: NSRange

        public init(text: String, selection: NSRange) {
            self.text = text
            self.selection = selection
        }
    }

    /// Wraps `selection` in `prefix`/`suffix`, or unwraps it if it is already
    /// wrapped (either inside the selection or immediately surrounding it).
    public static func wrapOrToggle(
        text: String,
        selection: NSRange,
        prefix: String,
        suffix: String
    ) -> EditResult {
        let ns = text as NSString
        let loc = max(0, min(selection.location, ns.length))
        let len = max(0, min(selection.length, ns.length - loc))
        let range = NSRange(location: loc, length: len)
        let prefixLen = (prefix as NSString).length
        let suffixLen = (suffix as NSString).length

        // Case 1: Selection itself includes the delimiters (e.g. `**word**`).
        if len >= prefixLen + suffixLen {
            let selected = ns.substring(with: range)
            if selected.hasPrefix(prefix) && selected.hasSuffix(suffix) {
                let innerRange = NSRange(location: prefixLen, length: len - prefixLen - suffixLen)
                let inner = (selected as NSString).substring(with: innerRange)
                let next = ns.replacingCharacters(in: range, with: inner)
                return EditResult(text: next, selection: NSRange(location: loc, length: (inner as NSString).length))
            }
        }

        // Case 2: Delimiters immediately surround the selection (e.g. `**|word|**`).
        if loc >= prefixLen && loc + len + suffixLen <= ns.length {
            let beforeRange = NSRange(location: loc - prefixLen, length: prefixLen)
            let afterRange = NSRange(location: loc + len, length: suffixLen)
            if ns.substring(with: beforeRange) == prefix && ns.substring(with: afterRange) == suffix {
                let fullRange = NSRange(location: loc - prefixLen, length: prefixLen + len + suffixLen)
                let selected = ns.substring(with: range)
                let next = ns.replacingCharacters(in: fullRange, with: selected)
                return EditResult(text: next, selection: NSRange(location: loc - prefixLen, length: len))
            }
        }

        // Case 3: Wrap selection.
        let selected = ns.substring(with: range)
        let replacement = "\(prefix)\(selected)\(suffix)"
        let next = ns.replacingCharacters(in: range, with: replacement)
        return EditResult(text: next, selection: NSRange(location: loc + prefixLen, length: len))
    }

    /// Toggles a Markdown line prefix (`# `, `## `, `### `, `- `, `1. `, `- [ ] `, `> `)
    /// on the line containing `selection.location`.
    ///
    /// When applying a heading prefix (`# `, `## `, `### `) to a line that already
    /// has a different heading level, the existing heading prefix is replaced rather
    /// than stacked.
    public static func toggleLinePrefix(
        text: String,
        selection: NSRange,
        prefix: String
    ) -> EditResult {
        let ns = text as NSString
        let loc = max(0, min(selection.location, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        let nextLine: String
        let delta: Int
        if line.hasPrefix(prefix) {
            nextLine = String(line.dropFirst(prefix.count))
            delta = -(prefix as NSString).length
        } else if isHeadingPrefix(prefix), let existingHeading = leadingHeadingPrefix(of: line) {
            nextLine = prefix + String(line.dropFirst(existingHeading.count))
            delta = (prefix as NSString).length - (existingHeading as NSString).length
        } else {
            nextLine = prefix + line
            delta = (prefix as NSString).length
        }

        let next = ns.replacingCharacters(in: lineRange, with: nextLine)
        let nextNS = next as NSString
        let adjustedLoc = max(lineRange.location, min(nextNS.length, loc + delta))
        return EditResult(text: next, selection: NSRange(location: adjustedLoc, length: 0))
    }

    /// Inserts a multi-line Markdown block (code fence, table, divider) after `selection`.
    public static func insertBlock(
        text: String,
        selection: NSRange,
        block: String
    ) -> EditResult {
        let ns = text as NSString
        let loc = max(0, min(selection.location + selection.length, ns.length))
        let next = ns.replacingCharacters(in: NSRange(location: loc, length: 0), with: block)
        let caret = NSRange(location: loc + (block as NSString).length, length: 0)
        return EditResult(text: next, selection: caret)
    }

    /// Wraps `selection` as `[selection](url)`, or inserts `[url](url)` when collapsed.
    public static func applyLink(
        text: String,
        selection: NSRange,
        url: String
    ) -> EditResult {
        let href = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty else {
            return EditResult(text: text, selection: selection)
        }
        let ns = text as NSString
        let loc = max(0, min(selection.location, ns.length))
        let len = max(0, min(selection.length, ns.length - loc))
        let range = NSRange(location: loc, length: len)
        let label = len > 0 ? ns.substring(with: range) : href
        let replacement = "[\(label)](\(href))"
        let next = ns.replacingCharacters(in: range, with: replacement)
        return EditResult(
            text: next,
            selection: NSRange(location: loc + 1, length: (label as NSString).length)
        )
    }

    private static func isHeadingPrefix(_ prefix: String) -> Bool {
        guard prefix.hasSuffix(" ") else { return false }
        let hashes = prefix.dropLast()
        return !hashes.isEmpty && hashes.count <= 6 && hashes.allSatisfy { $0 == "#" }
    }

    private static func leadingHeadingPrefix(of line: String) -> String? {
        var count = 0
        for ch in line {
            if ch == "#" {
                count += 1
            } else if ch == " ", count >= 1, count <= 6 {
                return String(repeating: "#", count: count) + " "
            } else {
                return nil
            }
        }
        return nil
    }
}
