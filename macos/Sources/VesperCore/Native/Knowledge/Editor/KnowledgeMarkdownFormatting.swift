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

    /// Returns a normalized single-line URL string if `raw` looks like a link suitable
    /// for wrapping selected text on Cmd+V paste (e.g. `https://...`, `http://...`, `mailto:...`).
    public static func pastableURL(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "http", "https", "ftp":
            guard let host = components.host, !host.isEmpty else { return nil }
            return trimmed
        case "mailto":
            let remainder = String(trimmed.dropFirst("mailto:".count))
            guard remainder.contains("@"), remainder.count >= 3 else { return nil }
            return trimmed
        case "vesper", "obsidian":
            guard trimmed.count > scheme.count + 3 else { return nil }
            return trimmed
        default:
            return nil
        }
    }

    /// When text is selected and the pasted string is a valid URL, wraps the selection as
    /// `[selected](url)` with the caret placed immediately after the closing `)`.
    /// Returns `nil` when selection is collapsed, empty/whitespace, already a URL, inside code/frontmatter,
    /// or when `pastedString` is not a URL.
    public static func pasteURLOverSelection(
        text: String,
        selection: NSRange,
        pastedString: String
    ) -> EditResult? {
        guard selection.length > 0, let url = pastableURL(from: pastedString) else {
            return nil
        }
        let ns = text as NSString
        guard selection.location >= 0, selection.location + selection.length <= ns.length else {
            return nil
        }
        if KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: selection.location, in: text) {
            return nil
        }
        let selected = ns.substring(with: selection)
        let trimmedSelected = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelected.isEmpty,
              !selected.contains("\n"),
              !selected.contains("\r"),
              pastableURL(from: trimmedSelected) == nil else {
            return nil
        }
        let escapedLabel = selected.replacingOccurrences(of: "]", with: "\\]")
        let replacement = "[\(escapedLabel)](\(url))"
        let next = ns.replacingCharacters(in: selection, with: replacement)
        let caretAfter = selection.location + (replacement as NSString).length
        return EditResult(text: next, selection: NSRange(location: caretAfter, length: 0))
    }

    /// When a Vesper Library URL is pasted at a collapsed caret outside code/frontmatter,
    /// rewrites it into a `![[library:...]]` embed.
    public static func pasteLibraryEmbed(
        text: String,
        selection: NSRange,
        pastedString: String,
        title: String? = nil
    ) -> EditResult? {
        guard selection.length == 0,
              let id = LibraryLogic.libraryItemID(fromURL: pastedString) else {
            return nil
        }
        let ns = text as NSString
        guard selection.location >= 0, selection.location <= ns.length else {
            return nil
        }
        if KnowledgeMarkdownSyntax.isInsideCodeOrFrontmatter(utf16Offset: selection.location, in: text) {
            return nil
        }
        let replacement = LibraryLogic.embedMarkdown(id: id, title: title)
        let next = ns.replacingCharacters(in: selection, with: replacement)
        let caretAfter = selection.location + (replacement as NSString).length
        return EditResult(text: next, selection: NSRange(location: caretAfter, length: 0))
    }

    /// Generates a deterministic, filesystem-safe screenshot filename (e.g. `Screenshot-2026-11-26-062500.png`).
    public static func screenshotFilename(
        date: Date = Date(),
        extension ext: String = "png",
        calendar: Calendar = .current
    ) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = comps.year ?? 2026
        let mo = comps.month ?? 1
        let d = comps.day ?? 1
        let h = comps.hour ?? 0
        let mi = comps.minute ?? 0
        let s = comps.second ?? 0
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        let finalExt = cleanExt.isEmpty ? "png" : cleanExt
        return String(format: "Screenshot-%04d-%02d-%02d-%02d%02d%02d.%@", y, mo, d, h, mi, s, finalExt)
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
