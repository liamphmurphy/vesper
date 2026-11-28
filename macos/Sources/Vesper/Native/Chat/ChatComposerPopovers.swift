import SwiftUI
import VesperCore

// MARK: - Completion Popover (@mention & /slash)

struct ChatCompletionItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let badge: String?
    let personaId: String?
    let applyValue: String
}

struct ChatComposerCompletionPopover: View {
    @Environment(\.vesperTheme) private var theme

    let heading: String
    let items: [ChatCompletionItem]
    let selectedIndex: Int
    let onSelect: (ChatCompletionItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(heading)
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.secondaryText)
                Spacer(minLength: 4)
                Text("↑↓ navigate · Tab/Return select · Esc close")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let selected = idx == selectedIndex
                            Button {
                                onSelect(item)
                            } label: {
                                HStack(spacing: 8) {
                                    if let personaId = item.personaId {
                                        WorkPersonaAvatarView(id: personaId, handle: nil, name: item.title, size: 18)
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .font(.system(size: theme.pointSize(.small), weight: .medium))
                                                .foregroundStyle(p.text)
                                                .lineLimit(1)
                                            if let badge = item.badge, !badge.isEmpty {
                                                Text(badge)
                                                    .font(.system(size: theme.pointSize(.micro)))
                                                    .foregroundStyle(p.tertiaryText)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(p.surface, in: Capsule())
                                            }
                                        }
                                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(.system(size: theme.pointSize(.micro)))
                                                .foregroundStyle(p.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    selected ? p.selected : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(idx)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 210)
                .onChange(of: selectedIndex) { _, next in
                    proxy.scrollTo(next, anchor: .center)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.swiftUIColor("surface-raised", fallback: p.surface))
                .shadow(color: Color.black.opacity(0.14), radius: 10, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

// MARK: - Pinned Collapsible Live Step Checklist Bar

/// Compact pinned bar above the composer while a running turn has a `TodoWrite` / `TaskCreate` plan.
/// Shows progress (`N/M steps`, plus failed count if any) with an expandable checklist (~7 visible rows,
/// scrollable if more), and auto-hides once the turn completes.
struct ChatPinnedPlanChecklistBar: View {
    @Environment(\.vesperTheme) private var theme

    let progress: ChatPlanProgress
    let turnKey: String

    @State private var isExpanded = false

    private static let maxVisibleRows = 7
    private static let approxRowHeight: CGFloat = 26

    var body: some View {
        let p = theme.palette
        let doneColor = theme.swiftUIColor("state-done", fallback: .green)
        let failedColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let ratio: CGFloat = progress.total > 0 ? CGFloat(progress.completed + progress.failed) / CGFloat(progress.total) : 0
        let listHeight = min(CGFloat(progress.steps.count) * Self.approxRowHeight + 12, CGFloat(Self.maxVisibleRows) * Self.approxRowHeight + 12)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: progress.activeStep != nil ? "checklist" : (progress.failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(progress.failed > 0 && progress.activeStep == nil ? failedColor : (progress.activeStep != nil ? p.accent : doneColor))

                    Text("\(progress.completed)/\(progress.total) \(progress.total == 1 ? "step" : "steps")")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))
                        .foregroundStyle(p.text)

                    if progress.failed > 0 {
                        Text("· \(progress.failed) failed")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(failedColor)
                    }

                    if !isExpanded, let active = progress.activeStep {
                        Text("— \(active.title)")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    ZStack(alignment: .leading) {
                        Capsule().fill(p.border)
                        Capsule()
                            .fill(progress.failed > 0 ? failedColor : p.accent)
                            .frame(width: max(ratio > 0 ? 4 : 0, 36 * min(1, ratio)))
                    }
                    .frame(width: 36, height: 4)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse step checklist" : "Expand live step checklist (\(progress.progressLabel))")

            if isExpanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(progress.steps, id: \.key) { step in
                            HStack(spacing: 7) {
                                if step.state == .active {
                                    ChatPulsingStatusDot(color: p.accent, size: 6, active: true)
                                        .frame(width: 14)
                                } else {
                                    Image(systemName: stepIcon(step.state))
                                        .imageScale(.small)
                                        .foregroundStyle(stepColor(step.state, palette: p, doneColor: doneColor, failedColor: failedColor))
                                        .frame(width: 14)
                                }
                                Text(step.title)
                                    .font(.system(size: theme.pointSize(.small), weight: step.state == .active ? .medium : .regular))
                                    .foregroundStyle(stepTextColor(step.state, palette: p, failedColor: failedColor))
                                    .lineLimit(1)
                                if step.state == .active, let detail = step.detail, !detail.isEmpty {
                                    Text("· \(detail)")
                                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                        .foregroundStyle(p.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                            }
                            .frame(minHeight: 20)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(height: listHeight)
            }
        }
        .background(
            theme.swiftUIColor("surface-raised", fallback: p.surface),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(progress.failed > 0 ? failedColor.opacity(0.4) : p.border))
        .onChange(of: turnKey) { _, _ in
            isExpanded = false
        }
    }

    private func stepIcon(_ state: ChatStepState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .active: "circle.dotted"
        case .failed: "xmark.circle.fill"
        case .planned: "circle"
        }
    }

    private func stepColor(_ state: ChatStepState, palette p: NativePalette, doneColor: Color, failedColor: Color) -> Color {
        switch state {
        case .done: doneColor
        case .active: p.accent
        case .failed: failedColor
        case .planned: p.tertiaryText
        }
    }

    private func stepTextColor(_ state: ChatStepState, palette p: NativePalette, failedColor: Color) -> Color {
        switch state {
        case .done: p.secondaryText
        case .active: p.text
        case .failed: failedColor
        case .planned: p.tertiaryText
        }
    }
}

// MARK: - Harness Usage Button & Popover

struct ChatHarnessUsageButton: View {
    @Environment(\.vesperTheme) private var theme

    let activeHarnessId: String
    let harnesses: [API.HarnessActivity]
    let isWorking: Bool

    @State private var showingPopover = false
    @State private var isHovered = false

    private var activeActivity: API.HarnessActivity? {
        harnesses.first(where: { $0.harness == activeHarnessId })
            ?? harnesses.first(where: \.connected)
            ?? harnesses.first
    }

    private var characterKind: HarnessCharacterView.Kind {
        HarnessCharacterView.kind(for: activeActivity?.harness ?? activeHarnessId) ?? .robot
    }

    var body: some View {
        let p = theme.palette
        let badge = activeActivity.map(ChatHarnessUsageLogic.compactBadge(for:)) ?? "Usage"
        let working = isWorking || (activeActivity?.running ?? 0) > 0

        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                HarnessCharacterView(kind: characterKind, working: working, size: 18)
                Text(badge)
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (showingPopover ? p.selected : (isHovered ? p.hover : Color.clear)),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(showingPopover ? p.accent.opacity(0.45) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Harness allowance & activity")
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            harnessPopoverContent
        }
    }

    private var harnessPopoverContent: some View {
        let displayed = harnesses.filter(\.connected).isEmpty ? harnesses : harnesses.filter(\.connected)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Harness usage")
                .font(.headline)
            if displayed.isEmpty {
                Text("No harness activity reported yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayed, id: \.harness) { activity in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if let kind = HarnessCharacterView.kind(for: activity.harness) {
                                HarnessCharacterView(kind: kind, working: activity.running > 0, size: 30)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(activity.label)
                                    .font(.subheadline.weight(.semibold))
                                if activity.running > 0 {
                                    Text("\(activity.running) active")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            if let plan = activity.plan, !plan.isEmpty {
                                TonePill(label: plan.capitalized, tone: "neutral")
                            }
                        }
                        ForEach(ChatHarnessUsageLogic.railUsageRows(for: activity)) { row in
                            UsageRowView(row: row)
                        }
                    }
                    if activity.harness != displayed.last?.harness {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 276)
    }
}

// MARK: - Model & Reasoning Effort Two-Column Popover

struct ChatModelEffortPickerPopover: View {
    @Environment(\.vesperTheme) private var theme

    let state: ChatModelEffortState
    @Binding var selectedHarness: API.Harness?
    @Binding var selectedModel: String?
    @Binding var selectedEffort: API.ChatEffort?
    let onDismiss: () -> Void

    private static let modelColumnWidth: CGFloat = 224
    private static let effortColumnWidth: CGFloat = 160
    private static let maxModelListHeight: CGFloat = 320

    private var estimatedModelListHeight: CGFloat {
        // Auto row + optional divider + each group header and model row.
        let modelCount = state.availableGroups.reduce(0) { $0 + $1.models.count }
        let groupCount = state.availableGroups.count
        let dividerOverhead: CGFloat = groupCount > 0 ? 9 : 0
        let contentHeight = CGFloat(1 + modelCount) * 26 + CGFloat(groupCount) * 24 + dividerOverhead + 12
        return min(contentHeight, Self.maxModelListHeight)
    }

    var body: some View {
        let p = theme.palette
        HStack(alignment: .top, spacing: 0) {
            modelColumn(palette: p)
                .frame(width: Self.modelColumnWidth)

            Divider()

            effortColumn(palette: p)
                .frame(width: Self.effortColumnWidth)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func modelColumn(palette p: NativePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Model")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ChatPickerOptionRow(
                        title: "Auto (default)",
                        trailing: nil,
                        isSelected: state.currentModelId == nil
                    ) {
                        selectedHarness = nil
                        selectedModel = nil
                        selectedEffort = nil
                    }

                    if !state.availableGroups.isEmpty {
                        Divider()
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                    }

                    ForEach(state.availableGroups, id: \.harness.rawValue) { group in
                        Text(group.label)
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                            .padding(.horizontal, 8)
                            .padding(.top, 5)
                            .padding(.bottom, 2)

                        ForEach(group.models, id: \.id) { item in
                            ChatPickerOptionRow(
                                title: item.label,
                                trailing: nil,
                                isSelected: item.id == state.currentModelId
                            ) {
                                let result = ChatModelEffortPickerLogic.selectModel(
                                    item,
                                    harness: group.harness,
                                    currentEffort: selectedEffort
                                )
                                selectedHarness = result.harness
                                selectedModel = result.model
                                selectedEffort = result.effort
                                if result.shouldDismiss {
                                    onDismiss()
                                }
                            }
                        }
                    }
                }
                .padding(5)
            }
            .frame(height: estimatedModelListHeight)
        }
    }

    private func effortColumn(palette p: NativePalette) -> some View {
        let defaultHint = state.currentModel?.defaultEffort.map(ChatModelEffortPickerLogic.effortLabel)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Reasoning effort")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

            Divider()

            if state.availableEfforts.isEmpty {
                Text("Not configurable for this model")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ChatPickerOptionRow(
                        title: "Default",
                        trailing: defaultHint,
                        isSelected: state.currentEffort == nil
                    ) {
                        selectedEffort = nil
                        onDismiss()
                    }

                    Divider()
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)

                    ForEach(state.availableEfforts, id: \.rawValue) { eff in
                        ChatPickerOptionRow(
                            title: ChatModelEffortPickerLogic.effortLabel(eff),
                            trailing: nil,
                            isSelected: eff == state.currentEffort
                        ) {
                            selectedEffort = eff
                            onDismiss()
                        }
                    }
                }
                .padding(5)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct ChatPickerOptionRow: View {
    @Environment(\.vesperTheme) private var theme

    let title: String
    let trailing: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.accent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: theme.pointSize(.small), weight: isSelected ? .medium : .regular))
                    .foregroundStyle(p.text)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let trailing, !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                (isSelected ? p.selected : (isHovered ? p.hover : Color.clear)),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
