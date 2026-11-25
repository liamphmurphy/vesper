import SwiftUI
import VesperCore

// MARK: - Diff Block View (LAZYAGENTS-318)

struct ChatDiffCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let spec: ChatDiffSpec

    @State private var layout: DiffLayout = .unified
    @State private var expandedCollapses: Set<Int> = []
    @State private var highlights: [Int: [CodeToken]] = [:]
    @State private var showLightbox = false

    private enum DiffLayout: String, CaseIterable {
        case unified = "Unified"
        case sideBySide = "Side by Side"
    }

    private var headerTitle: String {
        spec.title ?? spec.filename ?? (spec.mode == .prose ? "Prose diff" : "Code diff")
    }

    var body: some View {
        ChatVizCard(
            icon: "arrow.left.arrow.right.square",
            title: headerTitle,
            subtitle: spec.filename != nil && spec.title != nil ? spec.filename : nil,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("+\(spec.additions)")
                        .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                    Text("-\(spec.deletions)")
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))

                HStack(spacing: 2) {
                    ForEach(DiffLayout.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { layout = mode }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small), weight: layout == mode ? .medium : .regular))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(layout == mode ? theme.palette.text : theme.palette.tertiaryText)
                            .background(layout == mode ? theme.palette.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        } content: {
            diffContent
        }
        .task(id: "\(spec.language ?? "")|\(spec.lines.count)") {
            await highlightCodeLines()
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: headerTitle, subtitle: "+\(spec.additions) -\(spec.deletions)") {
                diffContent
            }
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        let chunks = spec.collapsedChunks()
        if layout == .unified {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chunks) { chunk in
                        switch chunk {
                        case .line(let line):
                            unifiedRow(line)
                        case .collapsed(let cid, let hidden):
                            if expandedCollapses.contains(cid) {
                                ForEach(hidden) { line in unifiedRow(line) }
                            } else {
                                collapsedBanner(id: cid, count: hidden.count)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(chunks) { chunk in
                        switch chunk {
                        case .line(let line):
                            sideRow(left: line.kind == .added ? nil : line, right: line.kind == .removed ? nil : line)
                        case .collapsed(let cid, let hidden):
                            if expandedCollapses.contains(cid) {
                                ForEach(ChatDiffSpec.sideBySidePairs(from: hidden)) { pair in
                                    sideRow(left: pair.left, right: pair.right)
                                }
                            } else {
                                collapsedBanner(id: cid, count: hidden.count)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(minWidth: 560, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func collapsedBanner(id: Int, count: Int) -> some View {
        let p = theme.palette
        return Button {
            expandedCollapses.insert(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                    .imageScale(.small)
                Text("Expand \(count) unchanged lines")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                Spacer()
            }
            .foregroundStyle(p.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(theme.swiftUIColor("surface-raised", fallback: p.surface).opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    private func unifiedRow(_ line: ChatDiffLine) -> some View {
        let p = theme.palette
        let bg = rowBackground(for: line.kind)
        let prefix = line.kind == .added ? "+" : line.kind == .removed ? "-" : line.kind == .hunkHeader ? "" : " "
        return HStack(alignment: .top, spacing: 6) {
            if spec.mode == .code {
                Text(line.oldLine.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
                    .foregroundStyle(p.tertiaryText)
                Text(line.newLine.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
                    .foregroundStyle(p.tertiaryText)
            }
            Text(prefix)
                .frame(width: 10, alignment: .center)
                .foregroundStyle(signColor(for: line.kind))
            lineTextView(line)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: spec.mode == .prose ? theme.pointSize(.chat) : theme.pointSize(.mono), design: spec.mode == .prose ? .default : .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(bg)
    }

    private func sideRow(left: ChatDiffLine?, right: ChatDiffLine?) -> some View {
        let p = theme.palette
        return HStack(alignment: .top, spacing: 0) {
            sideCell(left, isRight: false)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(p.rowBorder).frame(width: 1)
            sideCell(right, isRight: true)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: spec.mode == .prose ? theme.pointSize(.chat) : theme.pointSize(.mono), design: spec.mode == .prose ? .default : .monospaced))
    }

    @ViewBuilder
    private func sideCell(_ line: ChatDiffLine?, isRight: Bool) -> some View {
        let p = theme.palette
        if let line {
            HStack(alignment: .top, spacing: 6) {
                if spec.mode == .code {
                    Text((isRight ? line.newLine : line.oldLine).map(String.init) ?? "")
                        .frame(width: 28, alignment: .trailing)
                        .foregroundStyle(p.tertiaryText)
                }
                lineTextView(line)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(rowBackground(for: line.kind))
        } else {
            Color.clear
                .padding(.vertical, 2)
                .background(p.surface.opacity(0.25))
        }
    }

    @ViewBuilder
    private func lineTextView(_ line: ChatDiffLine) -> some View {
        let p = theme.palette
        if line.kind == .hunkHeader {
            Text(line.text)
                .foregroundStyle(p.tertiaryText)
                .italic()
        } else if !line.wordSpans.isEmpty && (spec.mode == .prose || highlights[line.id] == nil) {
            Text(attributedWordSpans(line))
        } else if let tokens = highlights[line.id], !tokens.isEmpty {
            Text(attributedTokens(tokens))
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(p.text)
        }
    }

    private func attributedWordSpans(_ line: ChatDiffLine) -> AttributedString {
        var result = AttributedString()
        let highlightBg: Color = line.kind == .added
            ? theme.swiftUIColor("state-done", fallback: .green).opacity(theme.mode == .dark ? 0.38 : 0.28)
            : theme.swiftUIColor("pill-blocked-fg", fallback: .red).opacity(theme.mode == .dark ? 0.38 : 0.25)
        for span in line.wordSpans {
            var part = AttributedString(span.text)
            part.foregroundColor = theme.palette.text
            if span.changed {
                part.backgroundColor = highlightBg
            }
            result.append(part)
        }
        return result
    }

    private func attributedTokens(_ tokens: [CodeToken]) -> AttributedString {
        var result = AttributedString()
        let isDark = theme.mode == .dark
        for tok in tokens {
            var part = AttributedString(tok.content)
            let hex = isDark ? tok.dark : tok.light
            part.foregroundColor = hex.flatMap(Color.init(hex:)) ?? theme.palette.text
            result.append(part)
        }
        return result
    }

    private func rowBackground(for kind: ChatDiffLineKind) -> Color {
        switch kind {
        case .added:
            theme.swiftUIColor("state-done", fallback: .green).opacity(theme.mode == .dark ? 0.16 : 0.12)
        case .removed:
            theme.swiftUIColor("pill-blocked-fg", fallback: .red).opacity(theme.mode == .dark ? 0.16 : 0.11)
        case .hunkHeader:
            theme.palette.accent.opacity(0.08)
        case .context:
            .clear
        }
    }

    private func signColor(for kind: ChatDiffLineKind) -> Color {
        switch kind {
        case .added: theme.swiftUIColor("state-done", fallback: .green)
        case .removed: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        default: theme.palette.tertiaryText
        }
    }

    private func highlightCodeLines() async {
        guard spec.mode == .code, let lang = spec.language, !lang.isEmpty else { return }
        let codeLines = spec.lines.filter { $0.kind != .hunkHeader }
        guard !codeLines.isEmpty else { return }
        let joined = codeLines.map(\.text).joined(separator: "\n")
        guard let tokenized = await CodeHighlighter.shared.highlight(joined, language: lang),
              !Task.isCancelled else { return }
        var map: [Int: [CodeToken]] = [:]
        for (idx, line) in codeLines.enumerated() where idx < tokenized.count {
            map[line.id] = tokenized[idx]
        }
        highlights = map
    }
}

// MARK: - Compare / Weighted Decision Matrix View (LAZYAGENTS-319)

struct ChatCompareCardView: View {
    @Environment(\.vesperTheme) private var theme

    let spec: ChatCompareSpec

    @State private var weightOverrides: [Int: Double] = [:]
    @State private var sortByScore = false
    @State private var showWeights = false
    @State private var showLightbox = false

    private var totals: [String: Double] {
        spec.weightedTotals(weights: weightOverrides)
    }

    private var pinnedOption: ChatCompareMatrixOption? {
        spec.recommendedOption
    }

    private var scrollableOptions: [ChatCompareMatrixOption] {
        let rest = spec.options.filter { $0.id != pinnedOption?.id }
        if sortByScore && spec.hasWeightsAndScores {
            let t = totals
            return rest.sorted { (t[$0.id] ?? 0) > (t[$1.id] ?? 0) }
        }
        return rest
    }

    var body: some View {
        ChatVizCard(
            icon: "tablecells.badge.ellipsis",
            title: spec.title ?? "Comparison Matrix",
            subtitle: spec.subtitle,
            supportsLightbox: true,
            isLightboxPresented: $showLightbox
        ) {
            HStack(spacing: 8) {
                if spec.hasWeightsAndScores {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showWeights.toggle() }
                    } label: {
                        Label("Weights", systemImage: "slider.horizontal.3")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(showWeights ? theme.palette.accent : theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)

                    Button {
                        sortByScore.toggle()
                    } label: {
                        Label(sortByScore ? "By score" : "Default order", systemImage: "arrow.up.arrow.down")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(sortByScore ? theme.palette.accent : theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
        } content: {
            matrixContent
        }
        .sheet(isPresented: $showLightbox) {
            ChatLightboxSheet(title: spec.title ?? "Comparison Matrix", subtitle: spec.subtitle) {
                matrixContent
            }
        }
    }

    @ViewBuilder
    private var matrixContent: some View {
        let p = theme.palette
        let currentTotals = totals
        let bestTotal = currentTotals.values.max()

        VStack(alignment: .leading, spacing: 0) {
            if showWeights && spec.hasWeightsAndScores {
                weightsEditor
                Rectangle().fill(p.rowBorder).frame(height: 1)
            }

            // Sticky left columns (Criteria + pinned Recommended option) alongside horizontally scrollable options.
            HStack(alignment: .top, spacing: 0) {
                criteriaColumn(showTotal: spec.hasWeightsAndScores)
                    .frame(width: 170)

                if let pinned = pinnedOption {
                    Rectangle().fill(p.rowBorder).frame(width: 1)
                    optionColumn(pinned, total: currentTotals[pinned.id], isBestTotal: bestTotal != nil && currentTotals[pinned.id] == bestTotal, pinned: true)
                        .frame(width: 165)
                }

                Rectangle().fill(p.rowBorder).frame(width: 1)

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(scrollableOptions.enumerated()), id: \.element.id) { idx, opt in
                            if idx > 0 {
                                Rectangle().fill(p.rowBorder).frame(width: 1)
                            }
                            optionColumn(opt, total: currentTotals[opt.id], isBestTotal: bestTotal != nil && currentTotals[opt.id] == bestTotal, pinned: false)
                                .frame(minWidth: 150, idealWidth: 165)
                        }
                    }
                }
            }
        }
    }

    private var weightsEditor: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Adjust criteria weights (updates weighted total live)")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                Spacer()
                if !weightOverrides.isEmpty {
                    Button("Reset") { weightOverrides.removeAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.micro), weight: .medium))
                        .foregroundStyle(p.accent)
                }
            }
            ForEach(spec.criteria.filter { !$0.scores.isEmpty }) { c in
                let binding = Binding<Double>(
                    get: { weightOverrides[c.id] ?? c.weight ?? 1.0 },
                    set: { weightOverrides[c.id] = $0 }
                )
                HStack(spacing: 10) {
                    Text(c.name)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.text)
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    Slider(value: binding, in: 0...10, step: 0.5)
                    Text(String(format: "%.1f", binding.wrappedValue))
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(p.surface.opacity(0.45))
    }

    private func criteriaColumn(showTotal: Bool) -> some View {
        let p = theme.palette
        let danger = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Criterion")
                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                .foregroundStyle(p.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 10)
                .background(p.surface.opacity(0.5))

            ForEach(spec.criteria) { c in
                Rectangle().fill(p.rowBorder).frame(height: 1)
                HStack(spacing: 5) {
                    if c.dealbreaker {
                        Image(systemName: "exclamationmark.shield.fill")
                            .imageScale(.small)
                            .foregroundStyle(danger)
                            .help("Dealbreaker criterion")
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name)
                            .font(.system(size: theme.pointSize(.small), weight: c.dealbreaker ? .semibold : .medium))
                            .foregroundStyle(c.dealbreaker ? danger : p.text)
                            .lineLimit(2)
                        if let w = weightOverrides[c.id] ?? c.weight, !c.scores.isEmpty {
                            Text("weight \(ChatChartSpec.compactNumber(w))")
                                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10)
                .background(c.dealbreaker ? danger.opacity(0.06) : .clear)
            }

            if showTotal {
                Rectangle().fill(p.rowBorder).frame(height: 1)
                Text("Weighted Total")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(p.surface.opacity(0.7))
            }
        }
    }

    private func optionColumn(_ option: ChatCompareMatrixOption, total: Double?, isBestTotal: Bool, pinned: Bool) -> some View {
        let p = theme.palette
        let winColor = theme.swiftUIColor("state-done", fallback: .green)
        let danger = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(option.name)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    if pinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(p.accent)
                            .help("Recommended")
                    }
                }
                if let sub = option.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 10)
            .background(pinned ? p.accent.opacity(0.12) : p.surface.opacity(0.5))

            ForEach(spec.criteria) { c in
                let isWinner = c.winner == option.id || c.winner == option.name
                let value = c.values[option.id] ?? c.values[option.name] ?? "—"
                let score = c.scores[option.id] ?? c.scores[option.name]
                Rectangle().fill(p.rowBorder).frame(height: 1)
                HStack(spacing: 5) {
                    Text(value)
                        .font(.system(size: theme.pointSize(.small), weight: isWinner ? .semibold : .regular))
                        .foregroundStyle(isWinner ? winColor : p.text)
                        .lineLimit(2)
                    Spacer(minLength: 2)
                    if isWinner {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(winColor)
                    } else if let score {
                        Text(ChatChartSpec.compactNumber(score))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10)
                .background(
                    isWinner
                        ? winColor.opacity(theme.mode == .dark ? 0.14 : 0.10)
                        : (c.dealbreaker ? danger.opacity(0.04) : (pinned ? p.accent.opacity(0.05) : .clear))
                )
            }

            if spec.hasWeightsAndScores {
                Rectangle().fill(p.rowBorder).frame(height: 1)
                HStack(spacing: 4) {
                    Text(total.map { String(format: "%.2f", $0) } ?? "—")
                        .font(.system(size: theme.pointSize(.body), weight: .semibold, design: .monospaced))
                        .foregroundStyle(isBestTotal ? winColor : p.text)
                    if isBestTotal {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(winColor)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 10)
                .background(isBestTotal ? winColor.opacity(0.12) : p.surface.opacity(0.7))
            }
        }
    }
}
