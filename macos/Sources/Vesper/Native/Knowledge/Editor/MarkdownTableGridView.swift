import SwiftUI
import VesperCore

/// Pure SwiftUI interactive GFM pipe-table grid embedded in `KnowledgeEditorView`.
///
/// Supports inline cell editing, `Tab`/`⇧Tab` navigation (appending a row on the last cell),
/// row/column insertion & removal, alignment cycling, draggable column resize handles,
/// "Edit as Markdown" raw pipe round-trip mode, and `⌘F` match highlighting.
struct MarkdownTableGridView: View {
    @Environment(\.vesperTheme) private var theme

    let table: MarkdownTableModel
    let segmentIndex: Int
    var requestedFocusCell: TableCellCoordinate? = nil
    var findMatches: [DocumentFindMatch] = []
    var activeFindMatch: DocumentFindMatch? = nil

    let onEditCell: (Int, Int, String) -> Void
    let onNavigateTab: (TableCellCoordinate, Bool) -> TableCellCoordinate?
    let onAddRow: (Int?) -> Void
    let onRemoveRow: (Int) -> Void
    let onAddColumn: (Int?) -> Void
    let onRemoveColumn: (Int) -> Void
    let onCycleAlignment: (Int) -> Void
    let onResizeColumn: (Int, Double) -> Void
    let onToggleRawMode: (Bool) -> Void
    let onApplyRawMarkdown: (String) -> Bool
    let onFocusCell: (TableCellCoordinate) -> Void

    @FocusState private var focusedCell: TableCellCoordinate?
    @State private var rawDraft: String = ""
    @State private var rawError: String? = nil
    @State private var dragStartWidths: [Int: Double] = [:]

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().overlay(p.border)
            if table.isEditingRawMarkdown {
                rawMarkdownEditor
            } else {
                gridBody
            }
        }
        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        .onChange(of: focusedCell) { _, next in
            if let next {
                onFocusCell(next)
            }
        }
        .onChange(of: requestedFocusCell) { _, next in
            if let next, table.isValidCoordinate(next) {
                focusedCell = next
            }
        }
        .onChange(of: table.isEditingRawMarkdown) { _, isRaw in
            if isRaw {
                rawDraft = table.rawMarkdownForEditing()
                rawError = nil
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        let p = theme.palette
        return HStack(spacing: 8) {
            Image(systemName: "tablecells")
                .font(.system(size: 12))
                .foregroundStyle(p.secondaryText)
            Text("\(table.totalRowCount) \u{00D7} \(table.columnCount)")
                .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(p.secondaryText)

            Spacer()

            if !table.isEditingRawMarkdown {
                Button {
                    onAddRow(nil)
                } label: {
                    Label("Row", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)
                .help("Add row at bottom")

                Button {
                    onAddColumn(nil)
                } label: {
                    Label("Column", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)
                .help("Add column at right")
            }

            Button {
                if table.isEditingRawMarkdown {
                    if onApplyRawMarkdown(rawDraft) {
                        rawError = nil
                        onToggleRawMode(false)
                    } else {
                        rawError = "Enter a valid Markdown pipe table (header row + delimiter row)."
                    }
                } else {
                    rawDraft = table.rawMarkdownForEditing()
                    rawError = nil
                    onToggleRawMode(true)
                }
            } label: {
                Label(
                    table.isEditingRawMarkdown ? "Apply Table" : "Edit as Markdown",
                    systemImage: table.isEditingRawMarkdown ? "checkmark" : "chevron.left.forwardslash.chevron.right"
                )
            }
            .buttonStyle(.borderless)
            .font(.system(size: theme.pointSize(.small), weight: .medium))
            .foregroundStyle(p.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    // MARK: - Interactive Grid

    private var gridBody: some View {
        let p = theme.palette
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider().overlay(p.border)
                ForEach(0..<table.rows.count, id: \.self) { bodyIdx in
                    bodyRow(bodyIndex: bodyIdx)
                    if bodyIdx + 1 < table.rows.count {
                        Divider().overlay(p.rowBorder)
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var headerRow: some View {
        let p = theme.palette
        return HStack(spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { col in
                let coord = TableCellCoordinate(row: 0, column: col)
                let width = columnWidth(at: col)
                HStack(spacing: 4) {
                    TextField(
                        "Header",
                        text: cellBinding(row: 0, column: col)
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                    .multilineTextAlignment(textAlignment(for: col))
                    .focused($focusedCell, equals: coord)
                    .onKeyPress(.tab) { press in
                        handleTab(from: coord, backwards: press.modifiers.contains(.shift))
                    }

                    Button {
                        onCycleAlignment(col)
                    } label: {
                        Image(systemName: alignmentIcon(for: col))
                            .font(.system(size: 10))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.borderless)
                    .help("Cycle alignment (\(alignmentLabel(for: col)))")

                    if table.columnCount > 1 {
                        Button {
                            onRemoveColumn(col)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove column")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: width, alignment: frameAlignment(for: col))
                .background(cellBackground(for: coord, isHeader: true))
                .overlay(alignment: .trailing) {
                    columnResizeHandle(column: col, currentWidth: width)
                }
            }

            // Spacer matching the trailing row-delete column in body rows.
            Color.clear
                .frame(width: 28, height: 1)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
    }

    private func bodyRow(bodyIndex: Int) -> some View {
        let p = theme.palette
        let rowNum = bodyIndex + 1
        return HStack(spacing: 0) {
            ForEach(0..<table.columnCount, id: \.self) { col in
                let coord = TableCellCoordinate(row: rowNum, column: col)
                let width = columnWidth(at: col)
                TextField(
                    "",
                    text: cellBinding(row: rowNum, column: col)
                )
                .textFieldStyle(.plain)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.text)
                .multilineTextAlignment(textAlignment(for: col))
                .focused($focusedCell, equals: coord)
                .onKeyPress(.tab) { press in
                    handleTab(from: coord, backwards: press.modifiers.contains(.shift))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: width, alignment: frameAlignment(for: col))
                .background(cellBackground(for: coord, isHeader: false))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(p.rowBorder)
                        .frame(width: 1)
                }
            }

            Button {
                onRemoveRow(bodyIndex)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(p.tertiaryText)
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .help("Remove row")
        }
    }

    private func columnResizeHandle(column: Int, currentWidth: CGFloat) -> some View {
        let p = theme.palette
        return Rectangle()
            .fill(p.border)
            .frame(width: 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidths[column] ?? Double(currentWidth)
                        if dragStartWidths[column] == nil {
                            dragStartWidths[column] = Double(currentWidth)
                        }
                        onResizeColumn(column, start + Double(value.translation.width))
                    }
                    .onEnded { _ in
                        dragStartWidths.removeValue(forKey: column)
                    }
            )
    }

    // MARK: - Edit as Markdown Mode

    private var rawMarkdownEditor: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $rawDraft)
                .font(.system(size: max(11, theme.pointSize(.small)), design: .monospaced))
                .foregroundStyle(p.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 260)
                .padding(8)
                .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))

            if let rawError {
                Text(rawError)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack(spacing: 8) {
                Button("Apply") {
                    if onApplyRawMarkdown(rawDraft) {
                        rawError = nil
                        onToggleRawMode(false)
                    } else {
                        rawError = "Enter a valid Markdown pipe table (header row + delimiter row)."
                    }
                }
                .buttonStyle(.vesper(.primary))

                Button("Cancel") {
                    rawError = nil
                    onToggleRawMode(false)
                }
                .buttonStyle(.vesper())

                Spacer()
            }
        }
        .padding(10)
    }

    // MARK: - Helpers

    private func cellBinding(row: Int, column: Int) -> Binding<String> {
        let coord = TableCellCoordinate(row: row, column: column)
        return Binding(
            get: { table.cellText(at: coord) },
            set: { newValue in onEditCell(row, column, newValue) }
        )
    }

    private func handleTab(from coord: TableCellCoordinate, backwards: Bool) -> KeyPress.Result {
        if let next = onNavigateTab(coord, backwards) {
            focusedCell = next
            return .handled
        }
        return .ignored
    }

    private func columnWidth(at col: Int) -> CGFloat {
        guard col >= 0, col < table.columnWidths.count else {
            return CGFloat(MarkdownTableModel.defaultColumnWidth)
        }
        return CGFloat(table.columnWidths[col])
    }

    private func alignment(for col: Int) -> MarkdownTableAlignment {
        guard col >= 0, col < table.alignments.count else { return .none }
        return table.alignments[col]
    }

    private func textAlignment(for col: Int) -> TextAlignment {
        switch alignment(for: col) {
        case .none, .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frameAlignment(for col: Int) -> Alignment {
        switch alignment(for: col) {
        case .none, .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func alignmentIcon(for col: Int) -> String {
        switch alignment(for: col) {
        case .none, .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }

    private func alignmentLabel(for col: Int) -> String {
        switch alignment(for: col) {
        case .none: return "Default"
        case .left: return "Left"
        case .center: return "Center"
        case .right: return "Right"
        }
    }

    private func cellBackground(for coord: TableCellCoordinate, isHeader: Bool) -> Color {
        let p = theme.palette
        if let active = activeFindMatch, matches(active, coord: coord) {
            return p.accent.opacity(0.28)
        }
        if findMatches.contains(where: { matches($0, coord: coord) }) {
            return p.selected
        }
        if focusedCell == coord {
            return p.accent.opacity(0.08)
        }
        return isHeader ? theme.swiftUIColor("surface-sunken", fallback: p.surface) : Color.clear
    }

    private func matches(_ match: DocumentFindMatch, coord: TableCellCoordinate) -> Bool {
        guard case .tableCell(let seg, let row, let col, _) = match.position else { return false }
        return seg == segmentIndex && row == coord.row && col == coord.column
    }
}
