import Foundation

// MARK: - Table Types

/// GFM column alignment parsed from the delimiter row (`---`, `:---`, `:---:`, `---:`).
public enum MarkdownTableAlignment: String, Sendable, Equatable, Hashable, CaseIterable {
    case none
    case left
    case center
    case right
}

/// 0-based coordinate into a `MarkdownTableModel` where `row == 0` is the header row and `row >= 1` are body rows.
public struct TableCellCoordinate: Sendable, Equatable, Hashable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TableCellCoordinate, rhs: TableCellCoordinate) -> Bool {
        if lhs.row != rhs.row { return lhs.row < rhs.row }
        return lhs.column < rhs.column
    }
}

// MARK: - Markdown Table Model

/// Pure Foundation model for an embedded GFM pipe table with exact source-range tracking,
/// grid editing, navigation, column resizing, Edit-as-Markdown round-trip, and Tiptap-compatible serialization.
public struct MarkdownTableModel: Sendable, Equatable, Hashable, Identifiable {
    public static let defaultColumnWidth: Double = 160
    public static let minColumnWidth: Double = 48
    public static let maxColumnWidth: Double = 1200

    public let id: String
    /// UTF-16 range of the table in the original markdown string (excluding any trailing newline).
    public var sourceRange: NSRange
    /// UTF-8 byte range of the table in the original markdown string.
    public var utf8ByteRange: Range<Int>
    /// Exact original markdown text as parsed; returned verbatim by `serialize()` when `isDirty == false`.
    public let originalRawText: String
    /// Whether any table cell, structure, alignment, or raw markdown edit has occurred.
    public var isDirty: Bool
    /// Line ending preserved from the original table (`"\r\n"` or `"\n"`).
    public var lineEnding: String
    /// Header row cells (row 0).
    public var headers: [String]
    /// Body rows (row 1..<totalRowCount).
    public var rows: [[String]]
    /// Column alignments matching `headers.count`.
    public var alignments: [MarkdownTableAlignment]
    /// Visual column widths (in points) for UI column resizing.
    public var columnWidths: [Double]
    /// Whether the user has toggled "Edit as Markdown" raw pipe text mode.
    public var isEditingRawMarkdown: Bool

    public var columnCount: Int { headers.count }
    public var totalRowCount: Int { 1 + rows.count }

    public init(
        id: String,
        sourceRange: NSRange,
        utf8ByteRange: Range<Int>,
        originalRawText: String,
        isDirty: Bool = false,
        lineEnding: String = "\n",
        headers: [String],
        rows: [[String]],
        alignments: [MarkdownTableAlignment],
        columnWidths: [Double]? = nil,
        isEditingRawMarkdown: Bool = false
    ) {
        self.id = id
        self.sourceRange = sourceRange
        self.utf8ByteRange = utf8ByteRange
        self.originalRawText = originalRawText
        self.isDirty = isDirty
        self.lineEnding = lineEnding
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        self.columnWidths = columnWidths ?? Array(repeating: Self.defaultColumnWidth, count: headers.count)
        self.isEditingRawMarkdown = isEditingRawMarkdown
    }

    // MARK: Cell Access & Editing

    public func isValidCoordinate(_ coord: TableCellCoordinate) -> Bool {
        coord.row >= 0 && coord.row < totalRowCount && coord.column >= 0 && coord.column < columnCount
    }

    public func cellText(at coord: TableCellCoordinate) -> String {
        guard isValidCoordinate(coord) else { return "" }
        if coord.row == 0 {
            return headers[coord.column]
        }
        return rows[coord.row - 1][coord.column]
    }

    public mutating func setCellText(_ text: String, at coord: TableCellCoordinate) {
        guard isValidCoordinate(coord) else { return }
        if coord.row == 0 {
            guard headers[coord.column] != text else { return }
            headers[coord.column] = text
        } else {
            guard rows[coord.row - 1][coord.column] != text else { return }
            rows[coord.row - 1][coord.column] = text
        }
        isDirty = true
    }

    // MARK: Tab / Shift-Tab Navigation

    /// Navigates `Tab` / `⇧Tab` across cells. Pressing `Tab` on the last cell of the last row
    /// appends a new empty body row, marks the table dirty, and moves to its first cell.
    @discardableResult
    public mutating func navigateTab(from coord: TableCellCoordinate, backwards: Bool = false) -> TableCellCoordinate {
        guard columnCount > 0 else { return TableCellCoordinate(row: 0, column: 0) }
        let clampedRow = max(0, min(coord.row, totalRowCount - 1))
        let clampedCol = max(0, min(coord.column, columnCount - 1))

        if backwards {
            if clampedCol > 0 {
                return TableCellCoordinate(row: clampedRow, column: clampedCol - 1)
            }
            if clampedRow > 0 {
                return TableCellCoordinate(row: clampedRow - 1, column: columnCount - 1)
            }
            return TableCellCoordinate(row: 0, column: 0)
        } else {
            if clampedCol + 1 < columnCount {
                return TableCellCoordinate(row: clampedRow, column: clampedCol + 1)
            }
            if clampedRow + 1 < totalRowCount {
                return TableCellCoordinate(row: clampedRow + 1, column: 0)
            }
            // Last cell of last row -> append a new row.
            addRow()
            return TableCellCoordinate(row: totalRowCount - 1, column: 0)
        }
    }

    // MARK: Row & Column Mutations

    /// Inserts a body row at `bodyIndex` (or appends at the end if `nil`).
    public mutating func addRow(at bodyIndex: Int? = nil, cells: [String]? = nil) {
        let normalized: [String]
        if let cells {
            if cells.count >= columnCount {
                normalized = Array(cells.prefix(columnCount))
            } else {
                normalized = cells + Array(repeating: "", count: columnCount - cells.count)
            }
        } else {
            normalized = Array(repeating: "", count: columnCount)
        }
        let targetIndex = max(0, min(bodyIndex ?? rows.count, rows.count))
        rows.insert(normalized, at: targetIndex)
        isDirty = true
    }

    /// Removes the body row at `bodyIndex` (0-based into `rows`).
    @discardableResult
    public mutating func removeRow(at bodyIndex: Int) -> Bool {
        guard bodyIndex >= 0 && bodyIndex < rows.count else { return false }
        rows.remove(at: bodyIndex)
        isDirty = true
        return true
    }

    /// Inserts a column at `index` (or appends at the end if `nil`).
    public mutating func addColumn(
        at index: Int? = nil,
        header: String = "",
        alignment: MarkdownTableAlignment = .none,
        width: Double = defaultColumnWidth
    ) {
        let targetIndex = max(0, min(index ?? columnCount, columnCount))
        headers.insert(header, at: targetIndex)
        alignments.insert(alignment, at: targetIndex)
        columnWidths.insert(Self.clampWidth(width), at: targetIndex)
        for r in rows.indices {
            rows[r].insert("", at: targetIndex)
        }
        isDirty = true
    }

    /// Removes the column at `index` if more than one column exists.
    @discardableResult
    public mutating func removeColumn(at index: Int) -> Bool {
        guard columnCount > 1, index >= 0 && index < columnCount else { return false }
        headers.remove(at: index)
        alignments.remove(at: index)
        columnWidths.remove(at: index)
        for r in rows.indices {
            rows[r].remove(at: index)
        }
        isDirty = true
        return true
    }

    /// Sets the GFM alignment for column `index`.
    public mutating func setAlignment(_ alignment: MarkdownTableAlignment, forColumn index: Int) {
        guard index >= 0 && index < alignments.count else { return }
        guard alignments[index] != alignment else { return }
        alignments[index] = alignment
        isDirty = true
    }

    /// Resizes the visual width of column `index`, clamped to `[minColumnWidth, maxColumnWidth]`.
    public mutating func resizeColumn(at index: Int, width: Double) {
        guard index >= 0 && index < columnWidths.count else { return }
        columnWidths[index] = Self.clampWidth(width)
    }

    private static func clampWidth(_ width: Double) -> Double {
        max(minColumnWidth, min(width, maxColumnWidth))
    }

    // MARK: Edit as Markdown Round-Trip

    /// Returns the raw pipe markdown shown when entering "Edit as Markdown" mode.
    public func rawMarkdownForEditing() -> String {
        serialize()
    }

    /// Applies edited raw pipe markdown back into the structured table model.
    /// Returns `false` and leaves the table unchanged if `raw` is not a valid GFM table.
    @discardableResult
    public mutating func applyRawMarkdown(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        let parsed = Self.parseTables(in: trimmed)
        guard parsed.count == 1, let first = parsed.first, first.originalRawText == trimmed else {
            return false
        }
        headers = first.headers
        rows = first.rows
        alignments = first.alignments
        lineEnding = first.lineEnding
        if columnWidths.count < headers.count {
            columnWidths.append(contentsOf: Array(repeating: Self.defaultColumnWidth, count: headers.count - columnWidths.count))
        } else if columnWidths.count > headers.count {
            columnWidths = Array(columnWidths.prefix(headers.count))
        }
        if trimmed != originalRawText {
            isDirty = true
        }
        return true
    }

    // MARK: Tiptap-Compatible Serialization

    /// Returns `originalRawText` verbatim when untouched (`isDirty == false`),
    /// or Tiptap-compatible padded GFM markdown when edited (`isDirty == true`).
    public func serialize() -> String {
        guard isDirty else { return originalRawText }
        return serializeTiptapFormatted()
    }

    /// Serializes with the exact column padding of `@tiptap/extension-table` (`renderTableToMarkdown`):
    /// `| col1 | col2 |` padded to each column's max width with a minimum width of 3 for separators.
    public func serializeTiptapFormatted() -> String {
        guard columnCount > 0 else { return "" }

        let escapedHeaders = headers.map(Self.escapeCellForSerialization)
        let escapedRows = rows.map { row in
            (0..<columnCount).map { col in
                Self.escapeCellForSerialization(col < row.count ? row[col] : "")
            }
        }

        var colWidths = Array(repeating: 3, count: columnCount)
        for col in 0..<columnCount {
            colWidths[col] = max(colWidths[col], escapedHeaders[col].count)
        }
        for row in escapedRows {
            for col in 0..<columnCount {
                colWidths[col] = max(colWidths[col], row[col].count)
            }
        }

        func pad(_ text: String, to width: Int) -> String {
            let deficit = max(0, width - text.count)
            return deficit == 0 ? text : text + String(repeating: " ", count: deficit)
        }

        var lines: [String] = []
        let headerLine = "| " + (0..<columnCount).map { pad(escapedHeaders[$0], to: colWidths[$0]) }.joined(separator: " | ") + " |"
        lines.append(headerLine)

        let sepLine = "| " + (0..<columnCount).map { col -> String in
            let dashes = String(repeating: "-", count: max(3, colWidths[col]))
            switch alignments[col] {
            case .left: return ":\(dashes)"
            case .right: return "\(dashes):"
            case .center: return ":\(dashes):"
            case .none: return dashes
            }
        }.joined(separator: " | ") + " |"
        lines.append(sepLine)

        for row in escapedRows {
            let bodyLine = "| " + (0..<columnCount).map { pad(row[$0], to: colWidths[$0]) }.joined(separator: " | ") + " |"
            lines.append(bodyLine)
        }

        return lines.joined(separator: lineEnding)
    }

    private static func escapeCellForSerialization(_ raw: String) -> String {
        // Match @tiptap/extension-table: newlines become <br>, unescaped pipes become \|.
        let withBreaks = raw.replacingOccurrences(
            of: "[ \\t]*\\r?\\n[ \\t]*",
            with: "<br>",
            options: .regularExpression
        )
        var out = ""
        var prevBackslash = false
        for ch in withBreaks {
            if ch == "|" && !prevBackslash {
                out.append("\\|")
                prevBackslash = false
            } else {
                out.append(ch)
                prevBackslash = (ch == "\\") && !prevBackslash
            }
        }
        return out
    }

    // MARK: GFM Pipe Table Parser

    private static let fenceRegex = try! NSRegularExpression(pattern: "^ {0,3}(`{3,}|~{3,})(.*)$")
    private static let delimiterCellRegex = try! NSRegularExpression(pattern: "^:?-{1,}:?$")

    /// Scans `markdown` for all GFM pipe tables outside YAML frontmatter and fenced code blocks.
    public static func parseTables(in markdown: String) -> [MarkdownTableModel] {
        let lines = KnowledgeMarkdownSyntax.splitLines(markdown)
        guard lines.count >= 2 else { return [] }

        let ns = markdown as NSString
        var tables: [MarkdownTableModel] = []
        var lineIndex = 0

        // Skip YAML frontmatter on line 0.
        if let first = lines.first, first.text == "---" {
            var idx = 1
            while idx < lines.count {
                if lines[idx].text == "---" || lines[idx].text == "..." {
                    lineIndex = idx + 1
                    break
                }
                idx += 1
            }
        }

        var openFenceChar: Character?
        var openFenceLength = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let lineNS = line.text as NSString
            if let f = fenceRegex.firstMatch(in: line.text, range: NSRange(location: 0, length: lineNS.length)) {
                let marker = lineNS.substring(with: f.range(at: 1))
                let info = lineNS.substring(with: f.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let cur = openFenceChar {
                    if marker.first == cur && marker.count >= openFenceLength && info.isEmpty {
                        openFenceChar = nil
                        openFenceLength = 0
                    }
                } else {
                    openFenceChar = marker.first
                    openFenceLength = marker.count
                }
                lineIndex += 1
                continue
            }

            if openFenceChar != nil {
                lineIndex += 1
                continue
            }

            // Check if `lineIndex` and `lineIndex + 1` form a GFM table header + delimiter row.
            if lineIndex + 1 < lines.count,
               containsUnescapedPipe(line.text),
               containsUnescapedPipe(lines[lineIndex + 1].text),
               let headerCells = splitPipeRow(line.text),
               let alignments = parseDelimiterRow(lines[lineIndex + 1].text, expectedColumns: headerCells.count) {
                var bodyRows: [[String]] = []
                var lastRowIndex = lineIndex + 1
                var scanIdx = lineIndex + 2

                while scanIdx < lines.count {
                    let candidate = lines[scanIdx].text
                    if isTableTerminator(candidate) || !containsUnescapedPipe(candidate) {
                        break
                    }
                    guard let rowCells = splitPipeRow(candidate) else { break }
                    let normalized: [String]
                    if rowCells.count >= headerCells.count {
                        normalized = Array(rowCells.prefix(headerCells.count))
                    } else {
                        normalized = rowCells + Array(repeating: "", count: headerCells.count - rowCells.count)
                    }
                    bodyRows.append(normalized)
                    lastRowIndex = scanIdx
                    scanIdx += 1
                }

                let startUTF16 = lines[lineIndex].utf16Offset
                let endUTF16 = lines[lastRowIndex].utf16Offset + lines[lastRowIndex].contentUTF16Length
                let sourceRange = NSRange(location: startUTF16, length: endUTF16 - startUTF16)
                let rawText = ns.substring(with: sourceRange)
                let utf8Range = computeUTF8Range(for: sourceRange, in: markdown)
                let lineEnding = rawText.contains("\r\n") ? "\r\n" : "\n"

                tables.append(MarkdownTableModel(
                    id: "table-\(tables.count)-\(startUTF16)",
                    sourceRange: sourceRange,
                    utf8ByteRange: utf8Range,
                    originalRawText: rawText,
                    isDirty: false,
                    lineEnding: lineEnding,
                    headers: headerCells,
                    rows: bodyRows,
                    alignments: alignments
                ))

                lineIndex = lastRowIndex + 1
                continue
            }

            lineIndex += 1
        }

        return tables
    }

    private static func computeUTF8Range(for nsRange: NSRange, in text: String) -> Range<Int> {
        guard let swiftRange = Range(nsRange, in: text) else { return 0..<0 }
        let start = text.utf8.distance(from: text.startIndex, to: swiftRange.lowerBound)
        let end = text.utf8.distance(from: text.startIndex, to: swiftRange.upperBound)
        return start..<end
    }

    private static func isTableTerminator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return true }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") { return true }
        return false
    }

    private static func containsUnescapedPipe(_ line: String) -> Bool {
        var inCode = false
        var prevBackslash = false
        for ch in line {
            if ch == "`" && !prevBackslash {
                inCode.toggle()
            } else if ch == "|" && !inCode && !prevBackslash {
                return true
            }
            prevBackslash = (ch == "\\") && !prevBackslash
        }
        return false
    }

    private static func splitPipeRow(_ line: String) -> [String]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        // Strip trailing unescaped pipe.
        if trimmed.hasSuffix("|") && !hasUnescapedTrailingBackslash(beforeLastCharOf: trimmed) {
            trimmed.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var idx = trimmed.startIndex

        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch == "\\" {
                let next = trimmed.index(after: idx)
                if next < trimmed.endIndex && trimmed[next] == "|" && !inCode {
                    current.append("|")
                    idx = trimmed.index(after: next)
                    continue
                }
                current.append(ch)
                idx = next
                continue
            }
            if ch == "`" {
                inCode.toggle()
                current.append(ch)
                idx = trimmed.index(after: idx)
                continue
            }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                idx = trimmed.index(after: idx)
                continue
            }
            current.append(ch)
            idx = trimmed.index(after: idx)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.isEmpty ? nil : cells
    }

    private static func hasUnescapedTrailingBackslash(beforeLastCharOf s: String) -> Bool {
        guard s.count >= 2 else { return false }
        var count = 0
        var idx = s.index(before: s.index(before: s.endIndex))
        while true {
            if s[idx] == "\\" {
                count += 1
            } else {
                break
            }
            if idx == s.startIndex { break }
            idx = s.index(before: idx)
        }
        return count % 2 == 1
    }

    private static func parseDelimiterRow(_ line: String, expectedColumns: Int) -> [MarkdownTableAlignment]? {
        guard let cells = splitPipeRow(line), cells.count == expectedColumns else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        alignments.reserveCapacity(cells.count)
        for cell in cells {
            let ns = cell as NSString
            guard delimiterCellRegex.firstMatch(in: cell, range: NSRange(location: 0, length: ns.length)) != nil else {
                return nil
            }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right {
                alignments.append(.center)
            } else if left {
                alignments.append(.left)
            } else if right {
                alignments.append(.right)
            } else {
                alignments.append(.none)
            }
        }
        return alignments
    }
}
