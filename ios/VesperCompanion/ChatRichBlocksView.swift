import SwiftUI
import UIKit
import VesperCore

// MARK: - Rich Markdown Segment Renderer (Headings, Code Blocks, Blockquotes, Lists, Inline)

struct ChatRichMarkdownView: View {
    let markdown: String
    var foreground: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = code
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))

                case .heading(let level, let text):
                    inlineMarkdown(text)
                        .font(level <= 1 ? .title3.bold() : (level == 2 ? .headline : .subheadline.bold()))
                        .foregroundStyle(foreground)
                        .padding(.top, 2)

                case .blockquote(let text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3)
                        inlineMarkdown(text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                case .paragraph(let text):
                    inlineMarkdown(text)
                        .font(.body)
                        .foregroundStyle(foreground)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineMarkdown(_ text: String) -> some View {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
        } else {
            Text(text)
        }
    }

    private enum Block {
        case code(lang: String, body: String)
        case heading(level: Int, text: String)
        case blockquote(String)
        case paragraph(String)
    }

    private func parseBlocks(_ md: String) -> [Block] {
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var para: [String] = []
        var i = 0

        func flushPara() {
            let joined = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            para.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushPara()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: lang, body: codeLines.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }
                let rest = trimmed.dropFirst(hashes.count)
                if rest.hasPrefix(" ") {
                    flushPara()
                    blocks.append(.heading(level: hashes.count, text: String(rest.dropFirst())))
                    i += 1
                    continue
                }
            }
            if trimmed.hasPrefix("> ") {
                flushPara()
                var qLines: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()
                    qLines.append(q.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(qLines.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushPara()
            } else {
                para.append(line)
            }
            i += 1
        }
        flushPara()
        return blocks
    }
}

// MARK: - Diff Card

struct ChatDiffCardView: View {
    let spec: ChatDiffSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(spec.title ?? spec.filename ?? "Diff")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if spec.additions > 0 {
                    Text("+\(spec.additions)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                }
                if spec.deletions > 0 {
                    Text("-\(spec.deletions)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.red)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(spec.lines) { line in
                        HStack(spacing: 6) {
                            Text(linePrefix(line.kind))
                                .font(.caption2.monospaced())
                                .foregroundStyle(lineColor(line.kind))
                                .frame(width: 12)
                            Text(line.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(line.kind == .hunkHeader ? .secondary : .primary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lineBackground(line.kind))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func linePrefix(_ kind: ChatDiffLineKind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .hunkHeader: "@"
        case .context: " "
        }
    }

    private func lineColor(_ kind: ChatDiffLineKind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .hunkHeader: .blue
        case .context: .secondary
        }
    }

    private func lineBackground(_ kind: ChatDiffLineKind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        case .hunkHeader: Color.blue.opacity(0.08)
        case .context: Color.clear
        }
    }
}

// MARK: - Comparison Matrix Card

struct ChatCompareCardView: View {
    let spec: ChatCompareSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Criterion")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        ForEach(spec.options) { opt in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(opt.name)
                                        .font(.caption.weight(.semibold))
                                    if opt.recommended {
                                        Image(systemName: "star.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if let sub = opt.subtitle, !sub.isEmpty {
                                    Text(sub).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 120, alignment: .leading)
                        }
                    }
                    Divider()
                    ForEach(spec.criteria) { crit in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(crit.name).font(.caption.weight(.medium))
                                if let w = crit.weight {
                                    Text("wt \(ChatChartSpec.compactNumber(w))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 110, alignment: .leading)

                            ForEach(spec.options) { opt in
                                let isWinner = crit.winner == opt.id
                                let val = crit.values[opt.id] ?? "—"
                                let score = crit.scores[opt.id]
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(val)
                                        .font(.caption)
                                        .fontWeight(isWinner ? .semibold : .regular)
                                        .foregroundStyle(isWinner ? .green : .primary)
                                    if let score {
                                        Text("\(ChatChartSpec.compactNumber(score))/10")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 120, alignment: .leading)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Collapsible Tree Card

struct ChatTreeCardView: View {
    let spec: ChatTreeSpec
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(spec.title ?? "Tree", systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(expanded.isEmpty ? "Expand All" : "Collapse") {
                    expanded = expanded.isEmpty ? spec.allExpandableIDs : []
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(spec.roots) { node in
                    TreeNodeRow(node: node, depth: 0, expanded: $expanded)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if expanded.isEmpty {
                expanded = Set(spec.roots.map(\.id))
            }
        }
    }
}

private struct TreeNodeRow: View {
    let node: ChatTreeNode
    let depth: Int
    @Binding var expanded: Set<String>

    private var isOpen: Bool { expanded.contains(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if !node.children.isEmpty {
                    Button {
                        if isOpen { expanded.remove(node.id) } else { expanded.insert(node.id) }
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12)
                }
                Image(systemName: node.isFolder ? "folder.fill" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(node.isFolder ? .blue : .secondary)
                Text(node.label)
                    .font(.caption.monospaced())
                if let ann = node.annotation, !ann.isEmpty {
                    Text("— \(ann)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)

            if isOpen {
                ForEach(node.children) { child in
                    TreeNodeRow(node: child, depth: depth + 1, expanded: $expanded)
                }
            }
        }
    }
}

// MARK: - Interactive Data Table Card

struct ChatDataTableCardView: View {
    let spec: ChatDataTableSpec

    @State private var query = ""
    @State private var sortKey: String?
    @State private var ascending = true

    var body: some View {
        let rows = spec.filteredAndSorted(query: query, sortKey: sortKey, ascending: ascending)
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Filter rows…", text: $query)
                .font(.caption)
                .textFieldStyle(.roundedBorder)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        ForEach(spec.columns) { col in
                            Button {
                                if sortKey == col.key {
                                    ascending.toggle()
                                } else {
                                    sortKey = col.key
                                    ascending = true
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(col.label)
                                        .font(.caption.weight(.semibold))
                                    if sortKey == col.key {
                                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                            .font(.caption2)
                                    }
                                }
                                .frame(minWidth: 84, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.prefix(50).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(spec.columns) { col in
                                let val = row[col.key] ?? .empty
                                Text(val.formatted(for: col))
                                    .font(.caption.monospacedDigit())
                                    .frame(minWidth: 84, alignment: .leading)
                                    .lineLimit(2)
                            }
                        }
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Tabbed Code Group Card

struct ChatCodeGroupCardView: View {
    let spec: ChatCodeGroupSpec
    @State private var selectedTabId: Int?

    var body: some View {
        let active = spec.tabs.first(where: { $0.id == selectedTabId }) ?? spec.tabs.first
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(spec.tabs) { tab in
                        let isSelected = tab.id == active?.id
                        Button(tab.label) { selectedTabId = tab.id }
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .buttonStyle(.bordered)
                            .tint(isSelected ? .accentColor : .secondary)
                            .controlSize(.mini)
                    }
                }
            }
            if let active {
                HStack {
                    if let lang = active.language, !lang.isEmpty {
                        Text(lang).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = active.code
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        let lines = active.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            let lineNo = idx + 1
                            let hi = active.highlightedLines.contains(lineNo)
                            HStack(spacing: 8) {
                                Text("\(lineNo)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(hi ? Color.accentColor.opacity(0.16) : Color.clear)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Key-Value Spec Card

struct ChatKVCardView: View {
    let spec: ChatKVSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            if let subtitle = spec.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(spec.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let tone = item.tone {
                        Circle()
                            .fill(ChatVizPalette.toneColor(tone))
                            .frame(width: 7, height: 7)
                    }
                    Text(item.key)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(item.value)
                        .font(item.mono ? .caption.monospaced() : .caption)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if item.id != spec.items.last?.id {
                    Divider()
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Collapsible JSON Tree Card

struct ChatJSONTreeCardView: View {
    let spec: ChatJSONTreeSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(spec.title ?? "JSON", systemImage: "curlybraces")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    UIPasteboard.general.string = spec.rawSource
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            JSONNodeView(node: spec.root, depth: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct JSONNodeView: View {
    let node: ChatJSONTreeNode
    let depth: Int
    @State private var expanded: Bool

    init(node: ChatJSONTreeNode, depth: Int) {
        self.node = node
        self.depth = depth
        _expanded = State(initialValue: depth < 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if node.isContainer {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if let key = node.key {
                    Text("\"\(key)\":")
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.indigo)
                }
                if node.isContainer {
                    Text(node.summaryBadge)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else if let scalar = node.scalarDisplay {
                    Text(scalar)
                        .font(.caption.monospaced())
                        .foregroundStyle(node.kind == .string ? .green : (node.kind == .number ? .orange : .purple))
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, CGFloat(depth) * 12)

            if node.isContainer && expanded {
                ForEach(node.children) { child in
                    JSONNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }
}

// MARK: - HTTP Inspector Card

struct ChatHTTPCardView: View {
    let spec: ChatHTTPSpec
    @State private var showHeaders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(spec.method)
                    .font(.caption2.monospaced().weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                if let status = spec.status {
                    let ok = (200..<300).contains(status)
                    Text("\(status)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((ok ? Color.green : Color.red).opacity(0.18), in: Capsule())
                        .foregroundStyle(ok ? .green : .red)
                }
                if let ms = spec.durationMs {
                    Text("\(ms)ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(spec.url)
                .font(.caption.monospaced())
                .textSelection(.enabled)

            if !spec.headers.isEmpty {
                DisclosureGroup("Headers (\(spec.headers.count))", isExpanded: $showHeaders) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(spec.headers) { h in
                            Text("\(h.name): \(h.value)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            }

            if let json = spec.jsonBody {
                JSONNodeView(node: json, depth: 0)
                    .padding(8)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            } else if let text = spec.textBody, !text.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(8)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Tabs & Details Cards

struct ChatTabsCardView: View {
    let spec: ChatTabsSpec
    @State private var selectedId: Int?

    var body: some View {
        let active = spec.tabs.first(where: { $0.id == selectedId }) ?? spec.tabs.first
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(spec.tabs) { tab in
                        let selected = tab.id == active?.id
                        Button(tab.label) { selectedId = tab.id }
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .buttonStyle(.bordered)
                            .tint(selected ? .accentColor : .secondary)
                            .controlSize(.mini)
                    }
                }
            }
            if let active {
                ChatRichMarkdownView(markdown: active.body)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChatDetailsCardView: View {
    let spec: ChatDetailsSpec
    @State private var expanded: Bool

    init(spec: ChatDetailsSpec) {
        self.spec = spec
        _expanded = State(initialValue: spec.defaultOpen)
    }

    var body: some View {
        DisclosureGroup(spec.summary, isExpanded: $expanded) {
            ChatRichMarkdownView(markdown: spec.body)
                .padding(.top, 6)
        }
        .font(.subheadline.weight(.medium))
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Callout & Interactive Checklist Cards

struct ChatCalloutCardView: View {
    let callout: ChatCalloutBlock
    @State private var collapsed: Bool

    init(callout: ChatCalloutBlock) {
        self.callout = callout
        _collapsed = State(initialValue: callout.defaultCollapsed)
    }

    private var accent: Color {
        switch callout.kind {
        case .note: .blue
        case .tip: .green
        case .warning: .orange
        case .caveat: .yellow
        case .conflict: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: callout.kind.systemImage)
                    .foregroundStyle(accent)
                Text(callout.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if callout.collapsible {
                    Button {
                        withAnimation { collapsed.toggle() }
                    } label: {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !collapsed {
                ChatRichMarkdownView(markdown: callout.body)
            }
        }
        .padding(12)
        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.3), lineWidth: 1)
        )
    }
}

struct ChatChecklistCardView: View {
    let chatId: String
    let messageId: String
    let checklist: ChatChecklistBlock
    let persistedState: [String: Bool]?
    let client: APIClient?

    @State private var localState: [Int: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(checklist.items) { item in
                let checked = localState[item.index] ?? persistedState?[String(item.index)] ?? item.defaultChecked
                Button {
                    let next = !checked
                    localState[item.index] = next
                    Task { await persist(index: item.index, checked: next) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(checked ? Color.accentColor : .secondary)
                        Text(item.text)
                            .font(.callout)
                            .strikethrough(checked)
                            .foregroundStyle(checked ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(item.indentLevel) * 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func persist(index: Int, checked: Bool) async {
        guard let client else { return }
        if let body = try? JSONSerialization.data(withJSONObject: ["index": index, "checked": checked]) {
            _ = try? await client.request("PATCH", "/api/v1/chats/\(chatId)/messages/\(messageId)/checklist", body: body)
        }
    }
}

// MARK: - Interactive Choices, Recommend, Gallery, Product, Dispatch, Workflow, Canvas, PDF, Research Plan

struct ChatChoicesCardView: View {
    let card: ChatChoicesCard
    let chosenOption: String?
    let disabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.question)
                .font(.subheadline.weight(.semibold))
            ForEach(card.options, id: \.label) { opt in
                let isChosen = chosenOption == opt.label
                Button {
                    onSelect(opt.label)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(.callout.weight(.medium))
                            if !opt.detail.isEmpty {
                                Text(opt.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isChosen ? Color.green.opacity(0.12) : Color(.tertiarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .disabled(disabled || chosenOption != nil)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChatRecommendCardsView: View {
    let cards: [ChatRecommendCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards, id: \.url) { card in
                if let url = URL(string: card.url) {
                    Link(destination: url) {
                        HStack(spacing: 10) {
                            Image(systemName: card.youtubeVideoID != nil ? "play.rectangle.fill" : "safari.fill")
                                .font(.title3)
                                .foregroundStyle(card.youtubeVideoID != nil ? .red : .accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ChatMediaURL.hostLabel(card.url))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(card.note.isEmpty ? card.url : card.note)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }
}

struct ChatGalleryCardView: View {
    let spec: ChatGallerySpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(spec.items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            if let img = item.image, let url = URL(string: img) {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    default:
                                        Color.secondary.opacity(0.12)
                                    }
                                }
                                .frame(width: 180, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            if let cap = item.caption, !cap.isEmpty {
                                Text(cap).font(.caption).lineLimit(2)
                            }
                            if let src = item.source, !src.isEmpty {
                                Text(src).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 180, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChatProductCardView: View {
    let spec: ChatProductSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
            }
            ForEach(Array(spec.items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(item.name).font(.callout.weight(.semibold))
                        Spacer()
                        if let badge = item.badge, !badge.isEmpty {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.16), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    HStack(spacing: 10) {
                        if let price = item.price { Text(price).font(.subheadline.bold()) }
                        if let rating = item.rating {
                            Label(rating, systemImage: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if !item.specs.isEmpty {
                        Text(item.specs.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let raw = item.url, let url = URL(string: raw) {
                        Link("View Product", destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChatSimpleActionCardView: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ChatInvalidBlockCardView: View {
    let kind: String
    let error: String
    let source: String
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Invalid \(kind) block")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(showSource ? "Hide" : "Source") { showSource.toggle() }
                    .font(.caption2)
            }
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if showSource {
                Text(source)
                    .font(.caption2.monospaced())
                    .padding(6)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
