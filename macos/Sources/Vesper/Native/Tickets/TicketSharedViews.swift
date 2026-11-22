import SwiftUI
import VesperCore

// Reusable pure-SwiftUI Ticket components (shared seam for LAZYAGENTS-281). Zero AppKit imports.

/// Status glyph matching the web's `StatusGlyph`, optionally accompanied by its label.
struct TicketStatusBadge: View {
    @Environment(\.vesperTheme) private var theme
    let status: API.TicketStatus
    var showsLabel: Bool = false
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: 5) {
            glyph
                .accessibilityLabel(TicketsLogic.statusLabel(status))
            if showsLabel {
                Text(TicketsLogic.statusLabel(status))
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.text)
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        let color = statusColor
        switch status {
        case .backlog:
            Circle()
                .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2.2, 2.2]))
                .frame(width: size, height: size)
        case .todo:
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: size, height: size)
        case .inProgress:
            ZStack {
                Circle().strokeBorder(color, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(color)
                    .padding(2.5)
            }
            .frame(width: size, height: size)
        case .inReview:
            ZStack {
                Circle().strokeBorder(color, lineWidth: 1.5)
                Circle()
                    .fill(color)
                    .frame(width: size * 0.45, height: size * 0.45)
            }
            .frame(width: size, height: size)
        case .done:
            ZStack {
                Circle().fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.56, weight: .bold))
                    .foregroundStyle(theme.swiftUIColor("text-on-accent", fallback: .white))
            }
            .frame(width: size, height: size)
        case .canceled:
            ZStack {
                Circle().strokeBorder(color, lineWidth: 1.4)
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
        default:
            Circle()
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: size, height: size)
        }
    }

    private var statusColor: Color {
        switch status {
        case .backlog: theme.swiftUIColor("state-backlog", fallback: theme.palette.tertiaryText)
        case .todo: theme.palette.secondaryText
        case .inProgress: theme.swiftUIColor("state-progress", fallback: theme.palette.accent)
        case .inReview: theme.swiftUIColor("state-review", fallback: .purple)
        case .done: theme.swiftUIColor("state-done", fallback: .green)
        case .canceled: theme.palette.tertiaryText
        default: theme.palette.tertiaryText
        }
    }
}

/// Priority glyph matching the web's `PriorityGlyph`, optionally showing its text label.
struct TicketPriorityBadge: View {
    @Environment(\.vesperTheme) private var theme
    let priority: API.Priority
    var showsLabel: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(priorityColor)
                .accessibilityLabel(TicketsLogic.priorityLabel(priority))
            if showsLabel {
                Text(TicketsLogic.priorityLabel(priority))
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(priority == .none ? theme.palette.tertiaryText : theme.palette.secondaryText)
            }
        }
    }

    private var symbolName: String {
        switch priority {
        case .urgent: "exclamationmark.square.fill"
        case .high: "chevron.up.2"
        case .medium: "equal"
        case .low: "chevron.down"
        case .none: "minus"
        default: "minus"
        }
    }

    private var priorityColor: Color {
        switch priority {
        case .urgent: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .high: theme.swiftUIColor("state-human", fallback: .orange)
        case .medium: theme.palette.secondaryText
        case .low: theme.palette.tertiaryText
        case .none: theme.palette.tertiaryText.opacity(0.6)
        default: theme.palette.tertiaryText
        }
    }
}

/// Story-point estimate badge (`3 pts` or `3` / `–`).
struct TicketEstimateBadge: View {
    @Environment(\.vesperTheme) private var theme
    let points: Int?
    var compact: Bool = false
    var showUnit: Bool = false

    var body: some View {
        if let points {
            Text(showUnit ? "\(points) pt\(points == 1 ? "" : "s")" : "\(points)")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.secondaryText)
                .padding(.horizontal, compact ? 0 : 6)
                .padding(.vertical, compact ? 0 : 1)
                .background(
                    compact ? Color.clear : theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .help("\(points) points")
        } else if compact {
            Text("–")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
                .help("Not estimated")
        }
    }
}

/// Criteria done/total pill with an optional progress bar (green when complete).
struct TicketProgressPill: View {
    @Environment(\.vesperTheme) private var theme
    let done: Int
    let total: Int
    var showBar: Bool = true

    var body: some View {
        if total == 0 {
            Text("–")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
                .accessibilityLabel("No criteria")
        } else {
            let fraction = min(1, max(0, Double(done) / Double(total)))
            let complete = done >= total
            HStack(spacing: 6) {
                Text("\(done)/\(total)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(complete ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.secondaryText)
                if showBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(theme.swiftUIColor("track", fallback: theme.palette.border))
                            Capsule()
                                .fill(complete ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.accent)
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(width: 36, height: 4)
                }
            }
            .help("\(done) of \(total) criteria done")
            .accessibilityLabel("\(done) of \(total) criteria met")
        }
    }
}

/// Label chip in a ticket row or property inspector.
struct TicketLabelChip: View {
    @Environment(\.vesperTheme) private var theme
    let label: API.Label

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(cssHex: label.color) ?? theme.palette.secondaryText)
                .frame(width: 6, height: 6)
            Text(label.name)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: Capsule())
        .overlay(Capsule().stroke(theme.palette.border.opacity(0.6)))
    }
}

/// Quiet epic chip matching the web's `EpicChip`.
struct TicketEpicChip: View {
    @Environment(\.vesperTheme) private var theme
    let epic: API.EpicRef

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: SidebarIcons.symbolName("epics"))
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.tertiaryText)
            Text(epic.name)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: Capsule())
        .help("Epic: \(epic.name)")
    }
}

/// Current ticket state text: amber for Needs you, red for blocked, tertiary otherwise.
struct TicketStateTextView: View {
    @Environment(\.vesperTheme) private var theme
    let ticket: API.TicketSummary
    let needs: TicketsLogic.NeedsYou?

    var body: some View {
        let state = TicketsLogic.stateText(for: ticket, needs: needs)
        let color: Color = switch state.tone {
        case .human: theme.swiftUIColor("pill-human-fg", fallback: .orange)
        case .blocked: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .quiet: theme.palette.tertiaryText
        }
        Text(state.text)
            .font(.system(size: theme.pointSize(.small)))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(state.text)
    }
}

/// Placeholder dashed circle for unassigned tickets.
struct UnassignedAvatarCircle: View {
    @Environment(\.vesperTheme) private var theme
    var size: CGFloat = 20

    var body: some View {
        Circle()
            .strokeBorder(theme.palette.border, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
            .frame(width: size, height: size)
            .help("Unassigned")
    }
}

/// Reusable Acceptance Criteria checklist card with toggle, remove, attribution, and inline add.
struct TicketCriteriaListView: View {
    @Environment(\.vesperTheme) private var theme
    var title: String = "Acceptance criteria"
    let criteria: [API.Criterion]
    var checkedBy: [String: TicketDetailLogic.CriterionCheckInfo] = [:]
    var readOnly: Bool = false
    var errorMessage: String?
    var onToggle: (API.Criterion, Bool) -> Void
    var onDelete: ((String) -> Void)?
    var onAdd: ((String) -> Void)?

    @State private var draft = ""
    @State private var hoveredId: String?

    var body: some View {
        let doneCount = criteria.filter(\.done).count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(theme.palette.tertiaryText)
                Spacer()
                if !criteria.isEmpty {
                    Text("\(doneCount)/\(criteria.count)")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(doneCount == criteria.count ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.tertiaryText)
                }
            }

            if !criteria.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(criteria, id: \.id) { criterion in
                        criterionRow(criterion)
                    }
                }
            }

            if !readOnly, let onAdd {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(theme.palette.border, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                        .frame(width: 14, height: 14)
                    TextField("Add a criterion and press Enter", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: theme.pointSize(.body)))
                        .onSubmit {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            draft = ""
                            onAdd(text)
                        }
                }
                .padding(.vertical, 3)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(theme.palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border.opacity(0.7)))
    }

    private func criterionRow(_ criterion: API.Criterion) -> some View {
        let info = criterion.done ? checkedBy[criterion.id] : nil
        let isHovered = hoveredId == criterion.id
        return HStack(alignment: .center, spacing: 10) {
            Button {
                guard !readOnly else { return }
                onToggle(criterion, !criterion.done)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(criterion.done ? theme.swiftUIColor("state-done", fallback: .green) : Color.clear)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            criterion.done ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.border,
                            lineWidth: 1.3
                        )
                    if criterion.done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.swiftUIColor("text-on-accent", fallback: .white))
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(readOnly)
            .accessibilityLabel(criterion.done ? "Mark criterion incomplete" : "Mark criterion complete")

            Text(criterion.text)
                .font(.system(size: theme.pointSize(.body)))
                .foregroundStyle(criterion.done ? theme.palette.tertiaryText : theme.palette.text)
                .strikethrough(criterion.done)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let info {
                Text("\(info.actorName) · \(APIDate.shortAgo(info.createdAt))")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }

            if !readOnly, let onDelete {
                Button {
                    onDelete(criterion.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0.001)
                .accessibilityLabel("Remove criterion: \(criterion.text)")
            }
        }
        .padding(.vertical, 4)
        .onHover { hoveredId = $0 ? criterion.id : (hoveredId == criterion.id ? nil : hoveredId) }
    }
}

/// Reusable selectable/focusable row for Tickets list (used by `TicketsScreen` and available for LAZYAGENTS-281).
struct TicketRowView: View {
    @Environment(\.vesperTheme) private var theme
    let ticket: API.TicketSummary
    let needs: TicketsLogic.NeedsYou?
    let selected: Bool
    let focused: Bool
    let compact: Bool
    var showEpic: Bool = true
    var highlighted: Bool = false
    var onToggleSelect: () -> Void
    var onOpen: (_ newTab: Bool) -> Void
    var onOpenNeeds: ((String) -> Void)?
    var onStart: (() -> Void)?
    var onChangeStatus: ((API.TicketStatus) -> Void)?
    var onCopyKey: (() -> Void)?
    var onCopyLink: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        let canStart = !compact && needs == nil && ticket.status == .todo && ticket.unmetDependencies == 0 && ticket.assignee != nil && onStart != nil
        HStack(spacing: 10) {
            Button(action: onToggleSelect) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? theme.palette.accent : Color.clear)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? theme.palette.accent : theme.palette.border, lineWidth: 1.2)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.swiftUIColor("text-on-accent", fallback: .white))
                    }
                }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(selected || focused || hovered ? 1 : 0.25)
            .accessibilityLabel("Select \(ticket.key)")

            TicketStatusBadge(status: ticket.status, size: 13)

            Text(ticket.key)
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
                .frame(width: 78, alignment: .leading)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(ticket.title)
                    .font(.system(size: theme.pointSize(.body), weight: .medium))
                    .foregroundStyle(theme.palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if ticket.priority != .none {
                    TicketPriorityBadge(priority: ticket.priority)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !compact && !ticket.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(ticket.labels.prefix(2), id: \.id) { label in
                        TicketLabelChip(label: label)
                    }
                }
            }

            TicketStateTextView(ticket: ticket, needs: needs)
                .frame(width: 170, alignment: .leading)

            if !compact {
                TicketProgressPill(done: ticket.criteriaDone, total: ticket.criteriaTotal, showBar: false)
                    .frame(width: 44, alignment: .trailing)
            }

            TicketEstimateBadge(points: ticket.estimatePoints, compact: true)
                .frame(width: 28, alignment: .center)

            if showEpic {
                Group {
                    if let epic = ticket.epic {
                        TicketEpicChip(epic: epic)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 130, alignment: .leading)
            }

            if let assignee = ticket.assignee {
                WorkPersonaAvatarView(agent: assignee, size: 20)
            } else {
                UnassignedAvatarCircle(size: 20)
            }

            trailingAction(canStart: canStart)
                .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: compact ? 32 : 44)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.palette.accent.opacity(0.5), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            onOpen(false)
        }
        .contextMenu {
            contextMenuContent(canStart: canStart)
        }
    }

    private var rowBackground: Color {
        if highlighted { return theme.palette.accent.opacity(0.24) }
        if selected { return theme.palette.accent.opacity(0.10) }
        if hovered { return theme.palette.hover }
        return .clear
    }

    @ViewBuilder
    private func trailingAction(canStart: Bool) -> some View {
        if let needs {
            Button("Open") {
                if let onOpenNeeds {
                    onOpenNeeds(needs.href)
                } else {
                    onOpen(false)
                }
            }
            .buttonStyle(.vesper(.approveOutline))
            .controlSize(.small)
        } else if canStart, let onStart {
            Button {
                onStart()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
            }
            .buttonStyle(.vesper())
            .controlSize(.small)
        } else {
            Text(APIDate.shortAgo(ticket.updatedAt))
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.palette.tertiaryText)
        }
    }

    @ViewBuilder
    private func contextMenuContent(canStart: Bool) -> some View {
        Button(needs != nil ? "Open what it needs" : "Open ticket") {
            if let needs, let onOpenNeeds {
                onOpenNeeds(needs.href)
            } else {
                onOpen(false)
            }
        }
        Button("Open in new tab") { onOpen(true) }
        if canStart, let onStart {
            Button("Start run") { onStart() }
        }
        if let onChangeStatus {
            Menu("Set status") {
                ForEach(TicketsLogic.statusOrder, id: \.rawValue) { status in
                    Button {
                        onChangeStatus(status)
                    } label: {
                        if status == ticket.status {
                            Label(TicketsLogic.statusLabel(status), systemImage: "checkmark")
                        } else {
                            Text(TicketsLogic.statusLabel(status))
                        }
                    }
                    .disabled(status == ticket.status)
                }
            }
        }
        Divider()
        if let onCopyKey {
            Button("Copy \(ticket.key)", action: onCopyKey)
        }
        if let onCopyLink {
            Button("Copy link", action: onCopyLink)
        }
    }
}
