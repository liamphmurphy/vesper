import Foundation

// MARK: - Document Segments

/// A contiguous prose slice between embedded tables.
public struct KnowledgeProseSegment: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Either a prose slice or an embedded GFM pipe table.
public enum KnowledgeDocumentSegment: Sendable, Equatable, Hashable, Identifiable {
    case prose(KnowledgeProseSegment)
    case table(MarkdownTableModel)

    public var id: String {
        switch self {
        case .prose(let p): return p.id
        case .table(let t): return t.id
        }
    }

    public var serializedText: String {
        switch self {
        case .prose(let p): return p.text
        case .table(let t): return t.serialize()
        }
    }

    public var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}

// MARK: - Unified Position, Selection & Find Match

/// A unified caret position across prose segments and embedded table cells.
public enum DocumentPosition: Sendable, Equatable, Hashable, Comparable {
    /// UTF-16 offset within `segments[segmentIndex]` (a prose segment).
    case prose(segmentIndex: Int, utf16Offset: Int)
    /// UTF-16 offset within cell `(row, column)` of `segments[segmentIndex]` (a table segment).
    /// `row == 0` is the header row; `row >= 1` are body rows.
    case tableCell(segmentIndex: Int, row: Int, column: Int, utf16Offset: Int)

    public var segmentIndex: Int {
        switch self {
        case .prose(let seg, _): return seg
        case .tableCell(let seg, _, _, _): return seg
        }
    }

    public var isInTable: Bool {
        if case .tableCell = self { return true }
        return false
    }

    public static func < (lhs: DocumentPosition, rhs: DocumentPosition) -> Bool {
        if lhs.segmentIndex != rhs.segmentIndex {
            return lhs.segmentIndex < rhs.segmentIndex
        }
        switch (lhs, rhs) {
        case (.prose(_, let lOff), .prose(_, let rOff)):
            return lOff < rOff
        case (.tableCell(_, let lRow, let lCol, let lOff), .tableCell(_, let rRow, let rCol, let rOff)):
            if lRow != rRow { return lRow < rRow }
            if lCol != rCol { return lCol < rCol }
            return lOff < rOff
        case (.prose, .tableCell):
            return true
        case (.tableCell, .prose):
            return false
        }
    }
}

/// A unified selection that may stay in prose, stay in a table, or span across prose and tables.
public struct DocumentSelection: Sendable, Equatable, Hashable {
    public var anchor: DocumentPosition
    public var focus: DocumentPosition

    public init(anchor: DocumentPosition, focus: DocumentPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public init(collapsedAt position: DocumentPosition) {
        self.anchor = position
        self.focus = position
    }

    public var start: DocumentPosition { min(anchor, focus) }
    public var end: DocumentPosition { max(anchor, focus) }
    public var isCollapsed: Bool { anchor == focus }

    /// `true` when the selection crosses between at least one prose segment and at least one table segment.
    public var spansProseAndTable: Bool {
        guard !isCollapsed else { return false }
        if start.isInTable != end.isInTable { return true }
        return start.segmentIndex != end.segmentIndex
    }
}

/// A single `⌘F` find match located in either prose or a table cell, ordered in document order.
public struct DocumentFindMatch: Sendable, Equatable, Hashable {
    public let position: DocumentPosition
    /// UTF-16 range of the match within that prose segment or table cell string.
    public let range: NSRange
    public let matchedText: String
    public let isInTable: Bool

    public init(position: DocumentPosition, range: NSRange, matchedText: String, isInTable: Bool) {
        self.position = position
        self.range = range
        self.matchedText = matchedText
        self.isInTable = isInTable
    }
}

// MARK: - Undo / Redo History

/// Classifies an edit recorded on the unified document undo/redo stack.
public enum DocumentEditKind: Sendable, Equatable, Hashable {
    case proseEdit(segmentIndex: Int)
    case tableEdit(segmentIndex: Int, description: String)
}

private struct DocumentUndoEntry: Sendable, Equatable {
    let segments: [KnowledgeDocumentSegment]
    let selection: DocumentSelection?
    let kind: DocumentEditKind
}

// MARK: - Knowledge Editor Document

/// Unified document model combining prose slices and embedded `MarkdownTableModel` instances,
/// guaranteeing byte-for-byte round-trip preservation on no-op open/save and surgical edits.
public struct KnowledgeEditorDocument: Sendable, Equatable {
    public static let defaultMaxUndoDepth = 200

    /// The exact original markdown string this document was opened with.
    public let originalMarkdown: String
    /// Ordered prose and table segments whose concatenation produces the serialized document.
    public private(set) var segments: [KnowledgeDocumentSegment]
    /// Current unified selection (optional; tracked across undo/redo).
    public var selection: DocumentSelection?

    private var undoStack: [DocumentUndoEntry] = []
    private var redoStack: [DocumentUndoEntry] = []
    private let maxUndoDepth: Int

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoCount: Int { undoStack.count }
    public var redoCount: Int { redoStack.count }

    /// `true` if the current serialized output differs from `originalMarkdown` or any table is dirty.
    public var isDirty: Bool {
        if segments.contains(where: { if case .table(let t) = $0 { return t.isDirty }; return false }) {
            return true
        }
        return serialize() != originalMarkdown
    }

    public init(markdown: String, maxUndoDepth: Int = defaultMaxUndoDepth) {
        self.originalMarkdown = markdown
        self.maxUndoDepth = max(1, maxUndoDepth)
        self.segments = Self.buildSegments(from: markdown)
    }

    private static func buildSegments(from markdown: String) -> [KnowledgeDocumentSegment] {
        let tables = MarkdownTableModel.parseTables(in: markdown)
        if tables.isEmpty {
            return [.prose(KnowledgeProseSegment(id: "prose-0", text: markdown))]
        }

        let ns = markdown as NSString
        var result: [KnowledgeDocumentSegment] = []
        var cursor = 0
        var proseCounter = 0

        for table in tables {
            let start = table.sourceRange.location
            if start > cursor {
                let text = ns.substring(with: NSRange(location: cursor, length: start - cursor))
                result.append(.prose(KnowledgeProseSegment(id: "prose-\(proseCounter)", text: text)))
                proseCounter += 1
            }
            result.append(.table(table))
            cursor = start + table.sourceRange.length
        }

        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            result.append(.prose(KnowledgeProseSegment(id: "prose-\(proseCounter)", text: tail)))
        }

        return result
    }

    // MARK: Serialization & Inspection

    /// Serializes the document back to markdown.
    /// Untouched tables emit their `originalRawText` verbatim, guaranteeing byte-for-byte identity on no-op saves.
    public func serialize() -> String {
        segments.map(\.serializedText).joined()
    }

    /// Indices of all `.table` segments in `segments`.
    public var tableSegmentIndices: [Int] {
        segments.indices.filter { segments[$0].isTable }
    }

    /// Returns the `MarkdownTableModel` at `segmentIndex`, if that segment is a table.
    public func table(at segmentIndex: Int) -> MarkdownTableModel? {
        guard segmentIndex >= 0, segmentIndex < segments.count else { return nil }
        if case .table(let t) = segments[segmentIndex] { return t }
        return nil
    }

    /// Returns the prose text at `segmentIndex`, if that segment is prose.
    public func proseText(at segmentIndex: Int) -> String? {
        guard segmentIndex >= 0, segmentIndex < segments.count else { return nil }
        if case .prose(let p) = segments[segmentIndex] { return p.text }
        return nil
    }

    /// Computes the current UTF-16 range of `segments[index]` within `serialize()`.
    public func serializedUTF16Range(ofSegment index: Int) -> NSRange? {
        guard index >= 0, index < segments.count else { return nil }
        var offset = 0
        for i in 0..<index {
            offset += (segments[i].serializedText as NSString).length
        }
        let len = (segments[index].serializedText as NSString).length
        return NSRange(location: offset, length: len)
    }

    // MARK: Surgical Prose & Table Edits (with Unified Undo/Redo)

    /// Replaces UTF-16 `range` inside prose segment `segmentIndex` with `replacement`.
    @discardableResult
    public mutating func replaceProse(
        in segmentIndex: Int,
        range: NSRange,
        with replacement: String,
        newSelection: DocumentSelection? = nil
    ) -> Bool {
        guard segmentIndex >= 0, segmentIndex < segments.count,
              case .prose(var prose) = segments[segmentIndex] else {
            return false
        }
        let ns = prose.text as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else {
            return false
        }
        let updated = ns.replacingCharacters(in: range, with: replacement)
        guard updated != prose.text else { return false }

        pushUndo(kind: .proseEdit(segmentIndex: segmentIndex))
        prose.text = updated
        segments[segmentIndex] = .prose(prose)
        if let newSelection {
            selection = newSelection
        }
        return true
    }

    /// Replaces the entire text of prose segment `segmentIndex`.
    @discardableResult
    public mutating func setProse(
        _ newText: String,
        in segmentIndex: Int,
        newSelection: DocumentSelection? = nil
    ) -> Bool {
        guard segmentIndex >= 0, segmentIndex < segments.count,
              case .prose(var prose) = segments[segmentIndex],
              prose.text != newText else {
            return false
        }
        pushUndo(kind: .proseEdit(segmentIndex: segmentIndex))
        prose.text = newText
        segments[segmentIndex] = .prose(prose)
        if let newSelection {
            selection = newSelection
        }
        return true
    }

    /// Applies an arbitrary mutation to the table at `segmentIndex`, recording an undo entry only if the table changed.
    @discardableResult
    public mutating func editTable(
        at segmentIndex: Int,
        description: String = "Edit table",
        _ mutate: (inout MarkdownTableModel) -> Void
    ) -> Bool {
        guard segmentIndex >= 0, segmentIndex < segments.count,
              case .table(var table) = segments[segmentIndex] else {
            return false
        }
        let before = table
        mutate(&table)
        guard table != before else { return false }

        pushUndo(kind: .tableEdit(segmentIndex: segmentIndex, description: description))
        segments[segmentIndex] = .table(table)
        return true
    }

    /// Edits a single cell of the table at `segmentIndex`.
    @discardableResult
    public mutating func editTableCell(
        at segmentIndex: Int,
        row: Int,
        column: Int,
        text: String
    ) -> Bool {
        editTable(at: segmentIndex, description: "Edit cell (\(row),\(column))") { table in
            table.setCellText(text, at: TableCellCoordinate(row: row, column: column))
        }
    }

    /// Navigates `Tab` / `⇧Tab` in the table at `segmentIndex`. Appending a row on the last cell records an undo entry.
    @discardableResult
    public mutating func navigateTableTab(
        at segmentIndex: Int,
        from coord: TableCellCoordinate,
        backwards: Bool = false
    ) -> TableCellCoordinate? {
        guard segmentIndex >= 0, segmentIndex < segments.count,
              case .table(var table) = segments[segmentIndex] else {
            return nil
        }
        let before = table
        let next = table.navigateTab(from: coord, backwards: backwards)
        if table != before {
            pushUndo(kind: .tableEdit(segmentIndex: segmentIndex, description: "Append row via Tab"))
            segments[segmentIndex] = .table(table)
        }
        selection = DocumentSelection(collapsedAt: .tableCell(
            segmentIndex: segmentIndex,
            row: next.row,
            column: next.column,
            utf16Offset: 0
        ))
        return next
    }

    /// Applies edited raw pipe markdown in "Edit as Markdown" mode for the table at `segmentIndex`.
    @discardableResult
    public mutating func applyRawTableMarkdown(_ raw: String, at segmentIndex: Int) -> Bool {
        guard segmentIndex >= 0, segmentIndex < segments.count,
              case .table(var table) = segments[segmentIndex] else {
            return false
        }
        let before = table
        guard table.applyRawMarkdown(raw) else { return false }
        if table != before {
            pushUndo(kind: .tableEdit(segmentIndex: segmentIndex, description: "Edit table as Markdown"))
            segments[segmentIndex] = .table(table)
        }
        return true
    }

    // MARK: Undo / Redo

    private mutating func pushUndo(kind: DocumentEditKind) {
        undoStack.append(DocumentUndoEntry(segments: segments, selection: selection, kind: kind))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        redoStack.removeAll(keepingCapacity: true)
    }

    /// Undoes the most recent prose or table edit in exact chronological order.
    @discardableResult
    public mutating func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        redoStack.append(DocumentUndoEntry(segments: segments, selection: selection, kind: entry.kind))
        segments = entry.segments
        selection = entry.selection
        return true
    }

    /// Redoes the most recently undone prose or table edit in exact chronological order.
    @discardableResult
    public mutating func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        undoStack.append(DocumentUndoEntry(segments: segments, selection: selection, kind: entry.kind))
        segments = entry.segments
        selection = entry.selection
        return true
    }

    // MARK: Hard Case 1 & 4 — Unified Cross-Boundary Selection & Copy as Markdown

    /// Produces valid markdown for any `DocumentSelection`, including selections that span
    /// prose and embedded table cells (for Copy / `⌘C`).
    public func selectedMarkdown(for selection: DocumentSelection) -> String {
        guard !selection.isCollapsed else { return "" }
        let start = selection.start
        let end = selection.end
        guard start.segmentIndex >= 0, end.segmentIndex < segments.count else { return "" }

        // Same-segment fast paths.
        if start.segmentIndex == end.segmentIndex {
            switch (segments[start.segmentIndex], start, end) {
            case (.prose(let p), .prose(_, let sOff), .prose(_, let eOff)):
                return utf16Substring(of: p.text, from: sOff, to: eOff)
            case (.table(let t), .tableCell(_, let sRow, let sCol, let sOff), .tableCell(_, let eRow, let eCol, let eOff)):
                if sRow == eRow && sCol == eCol {
                    return utf16Substring(of: t.cellText(at: TableCellCoordinate(row: sRow, column: sCol)), from: sOff, to: eOff)
                }
                return serializeTableSlice(
                    t,
                    startCell: (sRow, sCol, sOff),
                    endCell: (eRow, eCol, eOff)
                )
            default:
                return ""
            }
        }

        // Cross-segment selection spanning prose and/or tables.
        var pieces: [String] = []
        for idx in start.segmentIndex...end.segmentIndex {
            switch segments[idx] {
            case .prose(let p):
                let len = (p.text as NSString).length
                let fromOff: Int
                let toOff: Int
                if idx == start.segmentIndex, case .prose(_, let sOff) = start {
                    fromOff = sOff
                } else {
                    fromOff = 0
                }
                if idx == end.segmentIndex, case .prose(_, let eOff) = end {
                    toOff = eOff
                } else {
                    toOff = len
                }
                pieces.append(utf16Substring(of: p.text, from: fromOff, to: toOff))

            case .table(let t):
                if idx > start.segmentIndex && idx < end.segmentIndex {
                    pieces.append(t.serialize())
                } else if idx == start.segmentIndex, case .tableCell(_, let sRow, let sCol, let sOff) = start {
                    let lastRow = max(0, t.totalRowCount - 1)
                    let lastCol = max(0, t.columnCount - 1)
                    let lastCellLen = (t.cellText(at: TableCellCoordinate(row: lastRow, column: lastCol)) as NSString).length
                    pieces.append(serializeTableSlice(
                        t,
                        startCell: (sRow, sCol, sOff),
                        endCell: (lastRow, lastCol, lastCellLen)
                    ))
                } else if idx == end.segmentIndex, case .tableCell(_, let eRow, let eCol, let eOff) = end {
                    pieces.append(serializeTableSlice(
                        t,
                        startCell: (0, 0, 0),
                        endCell: (eRow, eCol, eOff)
                    ))
                } else {
                    pieces.append(t.serialize())
                }
            }
        }
        return pieces.joined()
    }

    private func serializeTableSlice(
        _ table: MarkdownTableModel,
        startCell: (row: Int, col: Int, offset: Int),
        endCell: (row: Int, col: Int, offset: Int)
    ) -> String {
        guard table.columnCount > 0 else { return "" }
        let firstRow = max(0, min(startCell.row, table.totalRowCount - 1))
        let lastRow = max(firstRow, min(endCell.row, table.totalRowCount - 1))

        // Build a valid GFM table: always include the header row (sliced if selection begins on row 0)
        // plus any selected body rows so the copied snippet is valid GFM markdown.
        var headers = table.headers
        if firstRow == 0 {
            for col in 0..<table.columnCount {
                if col < startCell.col {
                    headers[col] = ""
                } else if col == startCell.col && startCell.offset > 0 {
                    let full = headers[col]
                    let endOff = (lastRow == 0 && col == endCell.col) ? endCell.offset : (full as NSString).length
                    headers[col] = utf16Substring(of: full, from: startCell.offset, to: endOff)
                } else if lastRow == 0 && col == endCell.col {
                    headers[col] = utf16Substring(of: headers[col], from: 0, to: endCell.offset)
                } else if lastRow == 0 && col > endCell.col {
                    headers[col] = ""
                }
            }
        }

        var bodyRows: [[String]] = []
        if lastRow >= 1 {
            let bodyStart = max(1, firstRow)
            for r in bodyStart...lastRow {
                var cells = table.rows[r - 1]
                for col in 0..<table.columnCount {
                    if r == firstRow && col < startCell.col {
                        cells[col] = ""
                    } else if r == firstRow && col == startCell.col && r == lastRow && col == endCell.col {
                        cells[col] = utf16Substring(of: cells[col], from: startCell.offset, to: endCell.offset)
                    } else if r == firstRow && col == startCell.col && startCell.offset > 0 {
                        let full = cells[col]
                        cells[col] = utf16Substring(of: full, from: startCell.offset, to: (full as NSString).length)
                    } else if r == lastRow && col == endCell.col {
                        cells[col] = utf16Substring(of: cells[col], from: 0, to: endCell.offset)
                    } else if r == lastRow && col > endCell.col {
                        cells[col] = ""
                    }
                }
                bodyRows.append(cells)
            }
        }

        let subTable = MarkdownTableModel(
            id: "\(table.id)-slice",
            sourceRange: NSRange(location: 0, length: 0),
            utf8ByteRange: 0..<0,
            originalRawText: "",
            isDirty: true,
            lineEnding: table.lineEnding,
            headers: headers,
            rows: bodyRows,
            alignments: table.alignments
        )
        return subTable.serializeTiptapFormatted()
    }

    private func utf16Substring(of string: String, from startOffset: Int, to endOffset: Int) -> String {
        let ns = string as NSString
        let clampedStart = max(0, min(startOffset, ns.length))
        let clampedEnd = max(clampedStart, min(endOffset, ns.length))
        return ns.substring(with: NSRange(location: clampedStart, length: clampedEnd - clampedStart))
    }

    // MARK: Hard Case 2 — Unified Find (`⌘F`) Across Prose & Table Cells

    /// Finds all occurrences of `query` across both prose segments and embedded table cells
    /// in strict document order.
    public func findMatches(query: String, caseSensitive: Bool = false) -> [DocumentFindMatch] {
        guard FindLogic.shouldSearch(query: query) else { return [] }
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        var matches: [DocumentFindMatch] = []

        for (segIdx, segment) in segments.enumerated() {
            switch segment {
            case .prose(let prose):
                let ns = prose.text as NSString
                for range in findRanges(of: query, in: ns, options: options) {
                    matches.append(DocumentFindMatch(
                        position: .prose(segmentIndex: segIdx, utf16Offset: range.location),
                        range: range,
                        matchedText: ns.substring(with: range),
                        isInTable: false
                    ))
                }

            case .table(let table):
                for row in 0..<table.totalRowCount {
                    for col in 0..<table.columnCount {
                        let cell = table.cellText(at: TableCellCoordinate(row: row, column: col))
                        let ns = cell as NSString
                        for range in findRanges(of: query, in: ns, options: options) {
                            matches.append(DocumentFindMatch(
                                position: .tableCell(
                                    segmentIndex: segIdx,
                                    row: row,
                                    column: col,
                                    utf16Offset: range.location
                                ),
                                range: range,
                                matchedText: ns.substring(with: range),
                                isInTable: true
                            ))
                        }
                    }
                }
            }
        }

        return matches
    }

    private func findRanges(of query: String, in ns: NSString, options: NSString.CompareOptions) -> [NSRange] {
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: query, options: options, range: search)
            if found.location == NSNotFound || found.length == 0 { break }
            out.append(found)
            let next = found.location + found.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }
}
