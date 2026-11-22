import AppKit
import SwiftUI
import VesperCore

// MARK: - Main SwiftUI Command Palette View

struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel

    private var theme: ThemeTokens { model.theme }
    private var isDark: Bool { theme.mode == .dark }

    private var accentColor: Color { theme.palette.accent }

    private var prefersWhiteOnAccent: Bool {
        let hex = theme.colors["accent"] ?? (isDark ? "#0a84ff" : "#007aff")
        return CommandPaletteLogic.prefersLightText(onAccentHex: hex)
    }

    private var selectedPrimaryText: Color {
        prefersWhiteOnAccent ? .white : Color(red: 0.08, green: 0.08, blue: 0.10)
    }

    private var selectedSecondaryText: Color {
        prefersWhiteOnAccent ? Color.white.opacity(0.85) : Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.78)
    }

    private var primaryText: Color {
        isDark ? Color(red: 0.96, green: 0.96, blue: 0.97) : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    private var secondaryText: Color {
        isDark ? Color(red: 0.63, green: 0.63, blue: 0.67) : Color(red: 0.43, green: 0.43, blue: 0.45)
    }

    private var tertiaryText: Color {
        isDark ? Color(red: 0.56, green: 0.56, blue: 0.58) : Color(red: 0.53, green: 0.53, blue: 0.55)
    }

    private var dividerColor: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.09)
    }

    private var amberColor: Color {
        isDark ? Color(red: 1.0, green: 0.62, blue: 0.04) : Color(red: 0.79, green: 0.41, blue: 0.0)
    }

    private var greenColor: Color {
        isDark ? Color(red: 0.49, green: 0.91, blue: 0.60) : Color(red: 0.12, green: 0.55, blue: 0.28)
    }

    private var purpleColor: Color {
        isDark ? Color(red: 0.89, green: 0.72, blue: 1.0) : Color(red: 0.52, green: 0.25, blue: 0.80)
    }

    private var surfaceTint: Color {
        isDark ? Color(red: 0.14, green: 0.14, blue: 0.16).opacity(0.84) : Color(red: 0.96, green: 0.96, blue: 0.97).opacity(0.86)
    }

    var body: some View {
        let sections = model.sections
        let flatRows = sections.flatMap(\.rows)
        let activeIdx = flatRows.isEmpty ? 0 : min(max(model.activeIndex, 0), flatRows.count - 1)
        let activeRow = flatRows.isEmpty ? nil : flatRows[activeIdx]

        VStack(spacing: 0) {
            // Subtle top specular highlight in dark mode
            if isDark {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }

            searchBar
            divider

            if model.mode == .root {
                chipBar
                divider
            }

            if model.mode == .root && !model.isKnowledgeMode && !model.filters.tokens.isEmpty {
                filterTokenBar
                divider
            }

            GeometryReader { geo in
                let showSplit = geo.size.width >= CGFloat(CommandPaletteLayout.splitPreviewThreshold)
                HStack(spacing: 0) {
                    resultsColumn(sections: sections, flatRows: flatRows, activeRowId: activeRow?.id)
                        .frame(width: showSplit ? 500 : geo.size.width)

                    if showSplit {
                        Rectangle()
                            .fill(dividerColor)
                            .frame(width: 1)
                        CommandPalettePreviewView(model: model, row: activeRow)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            divider
            footerBar
        }
        .background(surfaceTint)
        .onChange(of: activeRow?.id) { _, _ in
            model.ensurePreviewLoaded(for: activeRow)
        }
        .onAppear {
            model.ensurePreviewLoaded(for: activeRow)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(height: 1)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            if model.isCommandsMode {
                modePill(title: "> Commands", fg: purpleColor, bg: purpleColor.opacity(isDark ? 0.18 : 0.14), border: purpleColor.opacity(0.55)) {
                    model.exitSubmode()
                }
            } else if model.isProjectsMode {
                modePill(title: "← Spaces", fg: primaryText, bg: isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), border: dividerColor) {
                    model.exitSubmode()
                }
            } else if model.isKnowledgeMode {
                modePill(title: "Knowledge ×", fg: greenColor, bg: greenColor.opacity(isDark ? 0.16 : 0.14), border: greenColor.opacity(0.55)) {
                    model.switchToGlobal()
                }
            } else if let scoped = model.scopedType {
                modePill(title: "\(scoped.label) ×", fg: accentColor, bg: accentColor.opacity(isDark ? 0.20 : 0.14), border: accentColor.opacity(0.55)) {
                    model.switchToGlobal()
                }
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(model.query.isEmpty ? secondaryText : accentColor)
                    .frame(width: 20)
            }

            CommandPaletteSearchField(
                text: $model.query,
                placeholder: model.inputPlaceholder,
                textColor: NSColor(primaryText),
                placeholderColor: NSColor(tertiaryText),
                focusTick: model.focusTick,
                onAction: { action in
                    handleFieldAction(action)
                }
            )
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            } else if model.mode == .root && !model.isKnowledgeMode && !model.searchText.isEmpty && model.totalSearchCount > 0 {
                Text("\(model.totalSearchCount) \(model.totalSearchCount == 1 ? "result" : "results")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiaryText)
                    .fixedSize()
            }

            Button {
                model.handleEscape()
            } label: {
                Text("esc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private func modePill(title: String, fg: Color, bg: Color, border: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fg)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chip Bar

    private var chipBar: some View {
        HStack(spacing: 8) {
            if model.isKnowledgeMode {
                chipButton(label: "All", active: model.knowledgeKind == nil) {
                    model.pickKnowledgeKind(nil)
                }
                chipButton(label: "Pages", active: model.knowledgeKind == .document) {
                    model.pickKnowledgeKind(.document)
                }
                chipButton(label: "Decks", active: model.knowledgeKind == .deck) {
                    model.pickKnowledgeKind(.deck)
                }
                chipButton(label: "Designs", active: model.knowledgeKind == .design) {
                    model.pickKnowledgeKind(.design)
                }
                Spacer(minLength: 8)
                chipButton(label: "Agent knowledge", active: model.includeAgent, quiet: !model.includeAgent) {
                    model.toggleIncludeAgent()
                }
                chipButton(label: "All Vesper", active: false) {
                    model.switchToGlobal()
                }
            } else if let scoped = model.scopedType {
                chipButton(label: chipLabel(scoped.label, count: model.counts[scoped]), active: true) {
                    model.focusTick &+= 1
                }
                chipButton(label: "All Vesper", active: false) {
                    model.switchToGlobal()
                }
                Spacer(minLength: 8)
                spaceScopeChip
            } else {
                chipButton(
                    label: chipLabel("All", count: model.searchText.isEmpty ? nil : model.totalSearchCount),
                    active: model.oneType == nil
                ) {
                    model.pickType(nil)
                }

                ForEach(CommandPaletteType.chipTypes) { type in
                    let count = model.searchText.isEmpty ? nil : model.counts[type]
                    let dimmed = !model.searchText.isEmpty && !model.isSearching && (model.counts[type] ?? 0) == 0
                    chipButton(
                        label: chipLabel(type.label, count: count),
                        active: model.oneType == type,
                        dimmed: dimmed
                    ) {
                        model.pickType(type)
                    }
                }

                moreChipButton

                Spacer(minLength: 8)
                spaceScopeChip
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
    }

    private func chipLabel(_ base: String, count: Int?) -> String {
        guard let count, count > 0 else { return base }
        return "\(base) \(count)"
    }

    private func chipButton(label: String, active: Bool, dimmed: Bool = false, quiet: Bool = false, action: @escaping () -> Void) -> some View {
        let fg: Color = if active {
            isDark ? .white : accentColor
        } else if dimmed {
            tertiaryText.opacity(0.65)
        } else if quiet {
            secondaryText
        } else {
            isDark ? Color(red: 0.84, green: 0.84, blue: 0.86) : Color(red: 0.23, green: 0.23, blue: 0.24)
        }

        let bg: Color = if active {
            accentColor.opacity(isDark ? 0.22 : 0.13)
        } else if dimmed {
            isDark ? Color.white.opacity(0.025) : Color.black.opacity(0.02)
        } else {
            isDark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
        }

        let border: Color = if active {
            accentColor.opacity(isDark ? 0.70 : 0.55)
        } else if dimmed {
            isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
        } else {
            isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)
        }

        return Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(fg)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(bg, in: Capsule())
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var moreChipButton: some View {
        let activeMore = model.activeMoreType
        let extraCount = model.moreTypesWithResults.count
        let label: String = if let activeMore {
            chipLabel(activeMore.label, count: model.searchText.isEmpty ? nil : model.counts[activeMore])
        } else if !model.searchText.isEmpty && extraCount > 0 {
            "More \(extraCount)"
        } else {
            "More +"
        }

        return chipButton(label: label, active: activeMore != nil || model.moreMenuOpen, quiet: activeMore == nil) {
            model.moreMenuOpen.toggle()
        }
        .popover(isPresented: $model.moreMenuOpen, arrowEdge: .bottom) {
            morePopoverContent
        }
    }

    private var morePopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.searchText.isEmpty ? "TYPES" : "WITH RESULTS")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tertiaryText)
                .tracking(0.5)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)

            let choices = model.searchText.isEmpty ? CommandPaletteType.moreTypes : model.moreTypesWithResults
            if choices.isEmpty {
                Text("Nothing else matched.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(choices) { type in
                    Button {
                        model.pickType(type)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: type.sfSymbol)
                                .font(.system(size: 12))
                                .foregroundStyle(secondaryText)
                                .frame(width: 16)
                            Text(type.label)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(primaryText)
                            if !model.searchText.isEmpty, let count = model.counts[type] {
                                Text("\(count)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(tertiaryText)
                            }
                            Spacer()
                            Text(type.token)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tertiaryText)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            model.oneType == type ? accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !model.searchText.isEmpty && !model.moreTypesWithoutResults.isEmpty {
                Divider().padding(.vertical, 6)
                Text("NO RESULTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tertiaryText)
                    .padding(.horizontal, 8)
                Text(model.moreTypesWithoutResults.map(\.label).joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    @ViewBuilder
    private var spaceScopeChip: some View {
        if let project = model.activeProject {
            chipButton(
                label: model.scopeToProject ? "\(project) ▾" : "All spaces ▾",
                active: model.scopeToProject
            ) {
                model.toggleSpaceScope()
            }
        }
    }

    // MARK: - Filter Token Bar

    private var filterTokenBar: some View {
        HStack(spacing: 6) {
            ForEach(model.filters.tokens, id: \.self) { token in
                Button {
                    model.removeFilterToken(token)
                } label: {
                    Text("\(token) ×")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(accentColor)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(accentColor.opacity(isDark ? 0.16 : 0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    // MARK: - Results List Column

    private func resultsColumn(sections: [PaletteSection], flatRows: [PaletteRow], activeRowId: String?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let error = model.searchError ?? model.knowledgeError ?? model.actionError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    if model.showFacets {
                        facetBar
                    }

                    if flatRows.isEmpty && !model.isSearching {
                        emptyResultsCopy
                    }

                    ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIdx, section in
                        if let label = section.label {
                            sectionHeader(
                                label: label,
                                count: section.count,
                                tone: section.tone,
                                isFirst: sectionIdx == 0 && !model.showFacets
                            )
                        }
                        ForEach(section.rows) { row in
                            let rowIndex = flatRows.firstIndex(where: { $0.id == row.id }) ?? 0
                            rowView(row: row, isSelected: row.id == activeRowId, index: rowIndex)
                                .id(row.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                // Generous top padding ensures the first section header is never clipped under the chip bar.
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
            .onChange(of: activeRowId) { _, newId in
                guard let newId else { return }
                withAnimation(.easeOut(duration: 0.10)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
        }
    }

    private var facetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                facetButton(label: model.facetAnyLabel, active: model.facet == nil) {
                    model.pickFacet(nil)
                }
                ForEach(model.activeFacets.prefix(6)) { f in
                    let label = (!model.isKnowledgeMode && model.oneType == .ticket)
                        ? "\(CommandPaletteModel.statusLabel(f.value)) \(f.count)"
                        : "\(f.value) \(f.count)"
                    facetButton(label: label, active: model.facet == f.value) {
                        model.pickFacet(f.value)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func facetButton(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? primaryText : secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    active
                        ? (isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10))
                        : (isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(active ? Color.clear : dividerColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(label: String, count: Int?, tone: PaletteRowTone, isFirst: Bool) -> some View {
        let title = count.map { "\(label.uppercased()) · \($0)" } ?? label.uppercased()
        return Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(tone == .human ? amberColor : tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, isFirst ? 2 : 12)
            .padding(.bottom, 4)
    }

    private func rowView(row: PaletteRow, isSelected: Bool, index: Int) -> some View {
        let isMore = row.moreOf != nil
        let isChild = row.isChildMessage

        return Button {
            let newTab = NSEvent.modifierFlags.contains(.command)
            model.activate(row, newTab: newTab)
        } label: {
            HStack(spacing: 10) {
                if isChild {
                    Rectangle()
                        .fill(isSelected ? selectedSecondaryText.opacity(0.5) : dividerColor)
                        .frame(width: 2, height: 24)
                        .padding(.leading, 18)
                } else if isMore {
                    Spacer().frame(width: 28)
                } else {
                    rowIconBadge(row: row, isSelected: isSelected)
                }

                VStack(alignment: .leading, spacing: 2) {
                    rowTitleView(row: row, isSelected: isSelected)
                    if let snippet = row.subtitleSnippet, !snippet.isEmpty {
                        snippetSubtitleView(prefix: row.subtitle, parts: snippet, isSelected: isSelected)
                    } else if let sub = row.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(isSelected ? selectedSecondaryText : secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let shortcut = row.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? selectedPrimaryText : secondaryText)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 22)
                        .background(
                            isSelected
                                ? selectedPrimaryText.opacity(0.18)
                                : (isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(isSelected ? Color.clear : dividerColor, lineWidth: 1)
                        )
                } else if let meta = row.meta {
                    HStack(spacing: 5) {
                        Text(meta)
                            .font(.system(size: 11.5, weight: row.metaTone != nil ? .medium : .regular))
                            .foregroundStyle(isSelected ? selectedSecondaryText : metaColor(row.metaTone))
                            .lineLimit(1)
                        if isSelected && !isMore {
                            Text("↵")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(selectedSecondaryText)
                        }
                    }
                } else if isSelected && !isMore {
                    Text("↵")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selectedSecondaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: isMore ? 32 : (isChild ? 42 : 48))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering && model.activeIndex != index {
                model.activeIndex = index
            }
        }
    }

    private func rowIconBadge(row: PaletteRow, isSelected: Bool) -> some View {
        let (fg, bg): (Color, Color) = if isSelected {
            (selectedPrimaryText, selectedPrimaryText.opacity(0.18))
        } else {
            switch row.tone {
            case .human:
                (amberColor, amberColor.opacity(isDark ? 0.16 : 0.14))
            case .run:
                (greenColor, greenColor.opacity(isDark ? 0.16 : 0.14))
            case .accent:
                (accentColor, accentColor.opacity(isDark ? 0.18 : 0.13))
            case .purple:
                (purpleColor, purpleColor.opacity(isDark ? 0.16 : 0.14))
            case .neutral:
                (
                    isDark ? Color(red: 0.83, green: 0.83, blue: 0.85) : Color(red: 0.26, green: 0.26, blue: 0.28),
                    isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
                )
            }
        }

        return Image(systemName: row.sfSymbol)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(fg)
            .frame(width: 28, height: 28)
            .background(bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func rowTitleView(row: PaletteRow, isSelected: Bool) -> some View {
        let isMore = row.moreOf != nil
        if isMore {
            return Text(row.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? selectedPrimaryText : accentColor)
                .lineLimit(1)
        }

        let baseColor: Color = isSelected ? selectedPrimaryText : primaryText
        let weight: Font.Weight = isSelected ? .semibold : .medium
        let size: CGFloat = row.isChildMessage ? 12 : 13

        if row.highlightTitle, !model.highlightQuery.isEmpty {
            let parts = CommandPaletteLogic.matchParts(text: row.title, query: model.highlightQuery)
            var attr = AttributedString()
            for part in parts {
                var run = AttributedString(part.text)
                if part.match {
                    run.foregroundColor = isSelected ? selectedPrimaryText : accentColor
                    run.font = .system(size: size, weight: .bold)
                } else {
                    run.foregroundColor = baseColor
                    run.font = .system(size: size, weight: weight)
                }
                attr.append(run)
            }
            return Text(attr).lineLimit(1)
        }

        return Text(row.title)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(baseColor)
            .lineLimit(1)
    }

    private func snippetSubtitleView(prefix: String?, parts: [CommandPaletteTextPart], isSelected: Bool) -> some View {
        let baseColor = isSelected ? selectedSecondaryText : secondaryText
        let matchColor = isSelected ? selectedPrimaryText : primaryText
        var attr = AttributedString()
        if let prefix, !prefix.isEmpty {
            var p = AttributedString(prefix)
            p.foregroundColor = baseColor
            p.font = .system(size: 11.5)
            attr.append(p)
        }
        var open = AttributedString("“…")
        open.foregroundColor = baseColor
        open.font = .system(size: 11.5)
        attr.append(open)
        for part in parts {
            var run = AttributedString(part.text)
            run.foregroundColor = part.match ? matchColor : baseColor
            run.font = .system(size: 11.5, weight: part.match ? .semibold : .regular)
            attr.append(run)
        }
        var close = AttributedString("…”")
        close.foregroundColor = baseColor
        close.font = .system(size: 11.5)
        attr.append(close)
        return Text(attr).lineLimit(1)
    }

    private func metaColor(_ tone: String?) -> Color {
        switch tone {
        case "in_progress": isDark ? Color(red: 1.0, green: 0.84, blue: 0.04) : Color(red: 0.72, green: 0.50, blue: 0.0)
        case "in_review", "accent": accentColor
        case "done": greenColor
        case "blocked", "failed": isDark ? Color(red: 1.0, green: 0.42, blue: 0.40) : Color(red: 0.80, green: 0.16, blue: 0.18)
        default: tertiaryText
        }
    }

    private var emptyResultsCopy: some View {
        let message: String = {
            if model.isProjectsMode {
                return "No spaces match “\(model.query)”."
            }
            if model.isCommandsMode {
                return "No commands match “\(model.query)”."
            }
            if model.isKnowledgeMode {
                let parsed = CommandPaletteLogic.parseKnowledgeQuery(model.query)
                if !parsed.tag.isEmpty { return "No pages tagged #\(parsed.tag)." }
                if !parsed.text.isEmpty { return "No Knowledge pages match “\(parsed.text)”." }
                return "No Knowledge pages yet."
            }
            if let scoped = model.scopedType, model.searchText.isEmpty {
                return "Type to search \(scoped.noun)…"
            }
            if let one = model.oneType, !model.searchText.isEmpty {
                return "No \(one.noun) match “\(model.searchText)”."
            }
            return "No results for “\(model.query.trimmingCharacters(in: .whitespaces))”."
        }()

        return Text(message)
            .font(.system(size: 13))
            .foregroundStyle(tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        let hints: [(String, String)] = if model.isCommandsMode {
            [("↑↓", "move"), ("↵", "run command"), ("⌫", "exit commands"), ("esc", "close")]
        } else if model.isProjectsMode {
            [("↑↓", "move"), ("↵", "switch space"), ("⌫", "back"), ("esc", "close")]
        } else if model.isKnowledgeMode {
            [("↑↓", "move"), ("↵", "open"), ("⌥↵", "attach to chat"), ("Tab", "next kind"), ("#tag", "filter tag")]
        } else if !model.searchText.isEmpty {
            [("↑↓", "move"), ("↵", "open"), ("⌥↵", "attach to chat"), ("⌘↵", "new tab"), ("→", "expand"), ("Tab", "next type")]
        } else {
            [("↑↓", "move"), ("↵", "open"), ("Tab", "next type"), ("⌘↵", "new tab"), ("@", "people"), ("#", "tickets"), (">", "commands")]
        }

        return HStack(spacing: 16) {
            ForEach(hints, id: \.1) { key, label in
                HStack(spacing: 5) {
                    Text(key)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(primaryText.opacity(0.9))
                    Text(label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tertiaryText)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 35)
        .background(isDark ? Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.75) : Color(red: 0.92, green: 0.92, blue: 0.94).opacity(0.82))
    }

    // MARK: - Keyboard Dispatch

    private func handleFieldAction(_ action: CommandPaletteFieldAction) {
        switch action {
        case .moveUp:
            model.moveUp()
        case .moveDown:
            model.moveDown()
        case .moveHome:
            model.moveHome()
        case .moveEnd:
            model.moveEnd()
        case .confirm(let newTab, let attach, let createKnowledge):
            model.confirm(newTab: newTab, attach: attach, createKnowledge: createKnowledge)
        case .tab(let back):
            model.stepChip(back: back)
        case .expandRight:
            _ = model.expandSelectedChat()
        case .collapseLeft:
            _ = model.collapseSelectedChat()
        case .backspaceOnEmpty:
            _ = model.handleBackspaceOnEmpty()
        case .approve:
            _ = model.approveSelected()
        case .deny:
            _ = model.denySelected()
        case .escape:
            model.handleEscape()
        }
    }
}

// MARK: - Native AppKit Search Input (Deterministic Focus & Key Routing)

enum CommandPaletteFieldAction {
    case moveUp
    case moveDown
    case moveHome
    case moveEnd
    case confirm(newTab: Bool, attach: Bool, createKnowledge: Bool)
    case tab(back: Bool)
    case expandRight
    case collapseLeft
    case backspaceOnEmpty
    case approve
    case deny
    case escape
}

struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let textColor: NSColor
    let placeholderColor: NSColor
    let focusTick: Int
    let onAction: (CommandPaletteFieldAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17, weight: .regular)
        field.lineBreakMode = .byTruncatingHead
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        applyColors(to: field)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
            if let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        applyColors(to: nsView)
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView, let window = nsView.window else { return }
                if window.firstResponder !== nsView.currentEditor() {
                    window.makeFirstResponder(nsView)
                }
                if let editor = nsView.currentEditor() {
                    let end = (nsView.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            }
        }
    }

    private func applyColors(to field: NSTextField) {
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .regular),
                .foregroundColor: placeholderColor,
            ]
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteSearchField
        weak var field: NSTextField?
        var lastFocusTick: Int = -1

        init(_ parent: CommandPaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onAction(.moveUp)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onAction(.moveDown)
                return true
            case #selector(NSResponder.moveToBeginningOfDocument(_:)):
                parent.onAction(.moveHome)
                return true
            case #selector(NSResponder.moveToEndOfDocument(_:)):
                parent.onAction(.moveEnd)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onAction(.confirm(
                    newTab: flags.contains(.command),
                    attach: flags.contains(.option),
                    createKnowledge: flags.contains(.shift)
                ))
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onAction(.tab(back: false))
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onAction(.tab(back: true))
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onAction(.escape)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if textView.string.isEmpty {
                    parent.onAction(.backspaceOnEmpty)
                    return true
                }
                return false
            case #selector(NSResponder.moveRight(_:)):
                let range = textView.selectedRange()
                if range.length == 0 && range.location == (textView.string as NSString).length {
                    parent.onAction(.expandRight)
                    return true
                }
                return false
            case #selector(NSResponder.moveLeft(_:)):
                let range = textView.selectedRange()
                if range.length == 0 && range.location == (textView.string as NSString).length {
                    parent.onAction(.collapseLeft)
                    return true
                }
                return false
            default:
                // Support ⌥A (approve) and ⌥D (deny) on approval rows
                if flags == .option, let chars = NSApp.currentEvent?.charactersIgnoringModifiers?.lowercased() {
                    if chars == "a" {
                        parent.onAction(.approve)
                        return true
                    }
                    if chars == "d" {
                        parent.onAction(.deny)
                        return true
                    }
                }
                return false
            }
        }
    }
}
