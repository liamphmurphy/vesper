import SwiftUI
import VesperCore

// MARK: - Interactive Data Table View (LAZYAGENTS-328)

struct ChatDataTableCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatDataTableSpec

    @State private var query = ""
    @State private var sortKey: String?
    @State private var ascending = true
    @State private var showLightbox = false

    private var visibleRows: [[String: ChatDataCellValue]] {
        spec.filteredAndSorted(query: query, sortKey: sortKey, ascending: ascending)
    }

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "tablecells",
            title: spec.title ?? "Data Table",
            subtitle: spec.subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            HStack(spacing: 8) {
                Text("\(visibleRows.count)/\(spec.rows.count)")
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                Button {
                    context.copyToClipboard(spec.csvText())
                    context.showToast(ToastItemModel(id: "datatable.csv", title: "Copied CSV", tone: .success))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Copy CSV")
            }
        } content: {
            tableBody
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Data Table", subtitle: "\(spec.rows.count) rows") {
                tableBody
            }
        }
    }

    private var tableBody: some View {
        let p = theme.palette
        let rows = visibleRows

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
                TextField("Filter rows…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(p.surface.opacity(0.45))

            Rectangle().fill(p.rowBorder).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                    GridRow {
                        ForEach(spec.columns) { col in
                            let isSorted = sortKey == col.key
                            Button {
                                if sortKey == col.key {
                                    ascending.toggle()
                                } else {
                                    sortKey = col.key
                                    ascending = true
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(col.label)
                                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                                        .foregroundStyle(isSorted ? p.text : p.secondaryText)
                                    if isSorted {
                                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(p.accent)
                                    }
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .gridColumnAlignment(isNumeric(col.type) ? .trailing : .leading)
                        }
                    }
                    .padding(.horizontal, 12)

                    Divider()

                    ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                        GridRow {
                            ForEach(spec.columns) { col in
                                let cell = row[col.key] ?? .empty
                                let formatted = cell.formatted(for: col)
                                Group {
                                    if col.type == .status {
                                        TonePill(label: formatted, tone: statusPillTone(formatted))
                                    } else {
                                        Text(formatted)
                                            .font(.system(size: theme.pointSize(.small), design: isNumeric(col.type) ? .monospaced : .default))
                                            .foregroundStyle(p.text)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        .padding(.horizontal, 12)
                        .background(rIdx % 2 == 1 ? p.surface.opacity(0.35) : .clear)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func isNumeric(_ type: ChatDataColumnType) -> Bool {
        type == .number || type == .currency || type == .percent || type == .duration
    }

    private func statusPillTone(_ text: String) -> String {
        switch text.lowercased() {
        case "done", "ok", "pass", "passed", "active", "healthy", "merged", "success": "done"
        case "failed", "error", "blocked", "down", "critical", "canceled": "blocked"
        case "running", "in_progress", "pending", "warning", "degraded": "human"
        default: "neutral"
        }
    }
}

// MARK: - Tabbed Code Group View (LAZYAGENTS-329)

struct ChatCodeGroupCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatCodeGroupSpec

    @State private var selectedTab = 0
    @State private var highlights: [Int: [[CodeToken]]] = [:]
    @State private var copiedTab = false
    @State private var copiedAll = false

    private var activeTab: ChatCodeTab {
        spec.tabs[min(selectedTab, max(0, spec.tabs.count - 1))]
    }

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "doc.on.doc",
            title: spec.title ?? "Code",
            supportsLightbox: false
        ) {
            HStack(spacing: 8) {
                Button {
                    context.copyToClipboard(activeTab.code)
                    copiedTab = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1400))
                        copiedTab = false
                    }
                } label: {
                    Label(copiedTab ? "Copied" : "Copy", systemImage: copiedTab ? "checkmark" : "doc.on.doc")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                }
                .buttonStyle(.plain)

                if spec.tabs.count > 1 {
                    Button {
                        let combined = spec.tabs.map { "// \($0.label)\n\($0.code)" }.joined(separator: "\n\n")
                        context.copyToClipboard(combined)
                        copiedAll = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(1400))
                            copiedAll = false
                        }
                    } label: {
                        Text(copiedAll ? "Copied all" : "Copy all")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(spec.tabs) { tab in
                            let isActive = tab.id == activeTab.id
                            Button(tab.label) { selectedTab = tab.id }
                                .buttonStyle(.plain)
                                .font(.system(size: theme.pointSize(.small), weight: isActive ? .semibold : .regular, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(isActive ? p.text : p.tertiaryText)
                                .background(isActive ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                Rectangle().fill(p.rowBorder).frame(height: 1)

                let lines = activeTab.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                let tokens = highlights[activeTab.id]
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            let lineNum = idx + 1
                            let isHL = activeTab.highlightedLines.contains(lineNum)
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(lineNum)")
                                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                    .foregroundStyle(isHL ? p.accent : p.tertiaryText)
                                    .frame(width: 28, alignment: .trailing)
                                if let lineTokens = tokens?[safe: idx], !lineTokens.isEmpty {
                                    Text(attributed(lineTokens))
                                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                        .textSelection(.enabled)
                                } else {
                                    Text(line.isEmpty ? " " : line)
                                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                        .foregroundStyle(p.text)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1.5)
                            .background(isHL ? p.accent.opacity(theme.mode == .dark ? 0.16 : 0.11) : .clear)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .task(id: activeTab.id) {
            guard highlights[activeTab.id] == nil, let lang = activeTab.language else { return }
            if let toks = await CodeHighlighter.shared.highlight(activeTab.code, language: lang) {
                highlights[activeTab.id] = toks
            }
        }
    }

    private func attributed(_ tokens: [CodeToken]) -> AttributedString {
        var out = AttributedString()
        let isDark = theme.mode == .dark
        for tok in tokens {
            var part = AttributedString(tok.content)
            let hex = isDark ? tok.dark : tok.light
            part.foregroundColor = hex.flatMap(Color.init(hex:)) ?? theme.palette.text
            out.append(part)
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Key-Value Spec Card View (LAZYAGENTS-330)

struct ChatKVCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatKVSpec

    @State private var copiedID: Int?
    @State private var forceMono = false

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "list.bullet.rectangle.portrait",
            title: spec.title ?? "Summary",
            subtitle: spec.subtitle,
            supportsLightbox: false
        ) {
            Button {
                forceMono.toggle()
            } label: {
                Text("Mono")
                    .font(.system(size: theme.pointSize(.micro), weight: forceMono ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(forceMono ? p.accent : p.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Toggle monospace values")
        } content: {
            let columns = [GridItem(.adaptive(minimum: 190, maximum: 320), spacing: 10)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(spec.items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.key)
                                .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                .foregroundStyle(p.tertiaryText)
                            if let tone = item.tone {
                                TonePill(label: item.value, tone: mapTone(tone))
                            } else {
                                Text(item.value)
                                    .font(.system(size: theme.pointSize(.small), weight: .medium, design: (forceMono || item.mono) ? .monospaced : .default))
                                    .foregroundStyle(p.text)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 4)
                        Button {
                            context.copyToClipboard(item.value)
                            copiedID = item.id
                            Task {
                                try? await Task.sleep(for: .milliseconds(1200))
                                if copiedID == item.id { copiedID = nil }
                            }
                        } label: {
                            Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copiedID == item.id ? theme.swiftUIColor("state-done", fallback: .green) : p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(item.key)")
                    }
                    .padding(9)
                    .background(p.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.rowBorder))
                }
            }
            .padding(10)
        }
    }

    private func mapTone(_ raw: String) -> String {
        switch raw.lowercased() {
        case "success", "positive", "done", "ok": "done"
        case "danger", "error", "negative", "blocked": "blocked"
        case "warning", "caution": "human"
        case "accent", "info": "review"
        default: "neutral"
        }
    }
}

// MARK: - Collapsible JSON Tree & HTTP Views (LAZYAGENTS-331)

struct ChatJSONTreeCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatJSONTreeSpec

    @State private var query = ""
    @State private var expanded: Set<String> = ["$"]

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "curlybraces",
            title: spec.title ?? "JSON",
            supportsLightbox: false
        ) {
            Button {
                context.copyToClipboard(spec.rawSource)
                context.showToast(ToastItemModel(id: "json.copy", title: "Copied JSON", tone: .success))
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Copy JSON")
        } content: {
            ChatJSONTreeExplorerView(root: spec.root, query: $query, expanded: $expanded)
        }
    }
}

struct ChatJSONTreeExplorerView: View {
    @Environment(\.vesperTheme) private var theme

    let root: ChatJSONTreeNode
    @Binding var query: String
    @Binding var expanded: Set<String>

    var body: some View {
        let p = theme.palette
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
                TextField("Search keys or values…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.small)))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(p.surface.opacity(0.45))

            Rectangle().fill(p.rowBorder).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: true) {
                ChatJSONNodeRowView(node: root, depth: 0, query: q, expanded: $expanded)
                    .padding(10)
            }
        }
    }
}

private struct ChatJSONNodeRowView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let node: ChatJSONTreeNode
    let depth: Int
    let query: String
    @Binding var expanded: Set<String>

    private var isOpen: Bool {
        !query.isEmpty || expanded.contains(node.path)
    }

    var body: some View {
        let p = theme.palette
        let viz = ChatVizPalette(theme: theme)
        if node.matches(query: query) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if node.isContainer && !node.children.isEmpty {
                        Button {
                            if expanded.contains(node.path) { expanded.remove(node.path) } else { expanded.insert(node.path) }
                        } label: {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 12)
                    }

                    if let key = node.key {
                        Text(key)
                            .foregroundStyle(viz.seriesColor(at: 0))
                        Text(":")
                            .foregroundStyle(p.tertiaryText)
                    }

                    if node.isContainer {
                        Text(node.summaryBadge)
                            .foregroundStyle(p.tertiaryText)
                    } else {
                        Text(node.scalarDisplay ?? "")
                            .foregroundStyle(scalarColor(viz: viz))
                            .textSelection(.enabled)
                    }

                    Button {
                        context.copyToClipboard(node.path)
                        context.showToast(ToastItemModel(id: "json.path", title: "Copied \(node.path)", tone: .success))
                    } label: {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(p.tertiaryText.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Copy JSONPath (\(node.path))")
                }
                .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                .padding(.leading, CGFloat(depth * 14))

                if node.isContainer && isOpen {
                    ForEach(node.children) { child in
                        ChatJSONNodeRowView(node: child, depth: depth + 1, query: query, expanded: $expanded)
                    }
                }
            }
        }
    }

    private func scalarColor(viz: ChatVizPalette) -> Color {
        switch node.kind {
        case .string: viz.seriesColor(at: 2)
        case .number: viz.seriesColor(at: 1)
        case .bool: viz.seriesColor(at: 6)
        case .null: theme.palette.tertiaryText
        default: theme.palette.text
        }
    }
}

struct ChatHTTPCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatHTTPSpec

    @State private var activeTab = "Body"
    @State private var jsonQuery = ""
    @State private var jsonExpanded: Set<String> = ["$"]

    var body: some View {
        let p = theme.palette
        ChatVizCard(
            icon: "network",
            title: spec.title ?? "HTTP Exchange",
            supportsLightbox: false
        ) {
            HStack(spacing: 6) {
                if let ms = spec.durationMs {
                    Text("\(ms) ms")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                if let bytes = spec.sizeBytes {
                    Text(ChatCodeReviewLogic.formatBytes(bytes))
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                if let status = spec.status {
                    TonePill(label: "\(status)", tone: status >= 200 && status < 300 ? "done" : (status >= 400 ? "blocked" : "human"))
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(spec.method)
                        .font(.system(size: theme.pointSize(.micro), weight: .bold, design: .monospaced))
                        .foregroundStyle(methodColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(methodColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    Text(spec.url)
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(p.text)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        context.copyToClipboard(spec.url)
                        context.showToast(ToastItemModel(id: "http.url", title: "Copied URL", tone: .success))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                            .foregroundStyle(p.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(p.surface.opacity(0.5))

                Rectangle().fill(p.rowBorder).frame(height: 1)

                HStack(spacing: 4) {
                    ForEach(["Body", "Headers (\(spec.headers.count))"], id: \.self) { label in
                        let key = label.hasPrefix("Headers") ? "Headers" : "Body"
                        let selected = activeTab == key
                        Button(label) { activeTab = key }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small), weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(selected ? p.text : p.tertiaryText)
                            .background(selected ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

                Rectangle().fill(p.rowBorder).frame(height: 1)

                if activeTab == "Headers" {
                    if spec.headers.isEmpty {
                        Text("No headers")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.tertiaryText)
                            .padding(12)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(spec.headers) { h in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(h.name)
                                        .font(.system(size: theme.pointSize(.mono), weight: .medium, design: .monospaced))
                                        .foregroundStyle(p.secondaryText)
                                        .frame(minWidth: 120, alignment: .leading)
                                    Text(h.value)
                                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                        .foregroundStyle(p.text)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(12)
                    }
                } else if let jsonBody = spec.jsonBody {
                    ChatJSONTreeExplorerView(root: jsonBody, query: $jsonQuery, expanded: $jsonExpanded)
                } else if let textBody = spec.textBody, !textBody.isEmpty {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(textBody)
                            .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                            .foregroundStyle(p.text)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                } else {
                    Text("Empty body")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                        .padding(12)
                }
            }
        }
    }

    private var methodColor: Color {
        switch spec.method {
        case "GET": theme.swiftUIColor("state-done", fallback: .green)
        case "POST": theme.palette.accent
        case "PUT", "PATCH": theme.swiftUIColor("state-progress", fallback: .orange)
        case "DELETE": theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        default: theme.palette.secondaryText
        }
    }
}

// MARK: - Tabs & Collapsible Details Views (LAZYAGENTS-332)

struct ChatTabsCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatTabsSpec
    var citations: [Int] = []

    @State private var selected = 0

    var body: some View {
        let p = theme.palette
        let active = spec.tabs[min(selected, max(0, spec.tabs.count - 1))]

        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if let title = spec.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.secondaryText)
                            .padding(.trailing, 8)
                    }
                    ForEach(spec.tabs) { tab in
                        let isActive = tab.id == active.id
                        Button(tab.label) { selected = tab.id }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small), weight: isActive ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(isActive ? p.text : p.tertiaryText)
                            .background(isActive ? p.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            Rectangle().fill(p.rowBorder).frame(height: 1)
            MarkdownView(markdown: active.body, textStyle: .chat, chat: true, citations: citations)
                .padding(12)
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

struct ChatDetailsCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatDetailsSpec
    var citations: [Int] = []

    @State private var isOpen: Bool

    init(spec: ChatDetailsSpec, citations: [Int] = []) {
        self.spec = spec
        self.citations = citations
        self._isOpen = State(initialValue: spec.defaultOpen)
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                        .frame(width: 14)
                    Text(spec.summary)
                        .font(.system(size: theme.pointSize(.body), weight: .medium))
                        .foregroundStyle(p.text)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Rectangle().fill(p.rowBorder).frame(height: 1)
                MarkdownView(markdown: spec.body, textStyle: .chat, chat: true, citations: citations)
                    .padding(12)
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}
