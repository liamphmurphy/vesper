import SwiftUI
import VesperCore

/// Native Kanban board view for Tickets (`/tickets?layout=board` and `/board`).
/// Pure SwiftUI (zero AppKit); delegates all domain math and optimistic updates to `TicketsBoardLogic`.
struct TicketsBoardView: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(NativeScreenContext.self) private var context

    let boardRequest: APIRequest<API.Board>
    let selectedProject: String?
    let selectedEpicId: String?
    let includeCanceled: Bool
    let blockedOnly: Bool
    let needsByKey: [String: TicketsLogic.NeedsYou]
    let onOpenTicket: (_ key: String, _ newTab: Bool) -> Void
    let onNewTicket: (_ status: API.TicketStatus) -> Void
    let onStartTicket: (_ key: String) -> Void
    let onOpenListWithStatus: (_ status: API.TicketStatus) -> Void

    @State private var pendingMoves: [TicketsBoardLogic.PendingMove] = []
    @State private var clientOrder: [String: [String]] = [:]
    @State private var movingKey: String?
    @State private var dropTargetColumn: API.TicketStatus?
    @State private var dropTargetCardKey: String?

    private var orderStorageKey: String {
        "vesper.boardOrder.\(selectedProject ?? "all")"
    }

    var body: some View {
        let entry = context.store.entry(boardRequest)
        Group {
            if let board = entry.data {
                let columns = TicketsBoardLogic.columns(
                    from: board,
                    includeCanceled: includeCanceled,
                    blockedOnly: blockedOnly,
                    pendingMoves: pendingMoves,
                    clientOrder: clientOrder
                )
                VStack(alignment: .leading, spacing: 14) {
                    if let epic = board.epic {
                        BoardEpicHeaderView(
                            summary: epic,
                            projectKey: board.project.key,
                            boardRequest: boardRequest,
                            onNavigate: { context.navigate($0) }
                        )
                        .padding(.horizontal, 20)
                    }

                    if blockedOnly, columns.allSatisfy({ $0.cards.isEmpty }) {
                        emptyBoardState(
                            title: "No blocked tickets",
                            subtitle: "Every ticket on this board has its dependencies met."
                        )
                    } else if columns.allSatisfy({ $0.cards.isEmpty }) {
                        emptyBoardState(
                            title: "Nothing on the board yet",
                            subtitle: "Create a ticket or adjust your epic/assignee filters."
                        )
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(columns) { column in
                                    boardColumn(column, in: board)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                        }
                    }
                }
            } else if let error = entry.error {
                QueryErrorView(message: "Couldn\u{2019}t load board: \(error.userMessage)") {
                    Task { await context.store.refetch(boardRequest) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                boardSkeleton
            }
        }
        .onAppear { loadSavedOrder() }
        .onChange(of: orderStorageKey) { _, _ in loadSavedOrder() }
    }

    private func boardColumn(_ column: TicketsBoardLogic.ColumnDisplay, in board: API.Board) -> some View {
        let isDropTarget = dropTargetColumn == column.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                TicketStatusBadge(status: column.status, size: 13)
                Text(column.title)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(theme.palette.text)
                Text("\(column.count)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: Capsule())
                Spacer(minLength: 4)
                if column.points > 0 {
                    Text("\(column.points) pt\(column.points == 1 ? "" : "s")")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.secondaryText)
                        .help("Total estimate points in column")
                }
                Button {
                    onNewTicket(column.status)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.palette.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New ticket in \(column.title)")
                .accessibilityLabel("New ticket in \(column.title)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(column.cards.enumerated()), id: \.element.key) { index, card in
                        VStack(spacing: 4) {
                            if dropTargetCardKey == card.key {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(theme.palette.accent)
                                    .frame(height: 2)
                                    .padding(.horizontal, 4)
                            }
                            BoardCardView(
                                card: card,
                                needs: needsByKey[card.key],
                                showEpic: board.epic == nil,
                                isMoving: movingKey == card.key,
                                findQuery: context.find.query,
                                findActive: context.find.matches("\(card.key) \(card.title)"),
                                onOpen: { newTab in onOpenTicket(card.key, newTab) },
                                onOpenNeeds: { href in context.navigate(href) },
                                onMoveToStatus: { target in
                                    Task { await performMove(card: card, to: target, at: nil, beforeKey: nil, in: board) }
                                },
                                onStart: { onStartTicket(card.key) },
                                onCopyKey: { copyAndToast(card.key, label: "\(card.key) copied") },
                                onCopyLink: { copyTicketLink(card.key) }
                            )
                            .draggable(card.key)
                            .dropDestination(for: String.self) { items, _ in
                                guard let draggedKey = items.first, draggedKey != card.key else { return false }
                                Task {
                                    await handleDrop(
                                        draggedKey: draggedKey,
                                        into: column.status,
                                        beforeKey: card.key,
                                        at: index,
                                        columnKeys: column.cards.map(\.key),
                                        in: board
                                    )
                                }
                                return true
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTargetCardKey = card.key
                                    dropTargetColumn = column.status
                                } else if dropTargetCardKey == card.key {
                                    dropTargetCardKey = nil
                                }
                            }
                        }
                    }

                    if column.cards.isEmpty {
                        Text("Drop tickets here")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }

                    if column.truncated {
                        Button {
                            onOpenListWithStatus(column.status)
                        } label: {
                            Text("Showing \(column.cards.count) of \(column.count) \u{2014} view all in List")
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(theme.palette.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 288)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            isDropTarget
                ? theme.palette.accent.opacity(0.06)
                : theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTarget ? theme.palette.accent.opacity(0.75) : theme.palette.border.opacity(0.7),
                    lineWidth: isDropTarget ? 1.5 : 1
                )
        )
        .dropDestination(for: String.self) { items, _ in
            guard let draggedKey = items.first else { return false }
            Task {
                await handleDrop(
                    draggedKey: draggedKey,
                    into: column.status,
                    beforeKey: nil,
                    at: column.cards.count,
                    columnKeys: column.cards.map(\.key),
                    in: board
                )
            }
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetColumn = column.status
            } else if dropTargetColumn == column.status {
                dropTargetColumn = nil
            }
        }
    }

    @MainActor
    private func handleDrop(
        draggedKey: String,
        into targetStatus: API.TicketStatus,
        beforeKey: String?,
        at index: Int,
        columnKeys: [String],
        in board: API.Board
    ) async {
        dropTargetCardKey = nil
        dropTargetColumn = nil
        guard let card = board.columns.flatMap(\.cards).first(where: { $0.key == draggedKey }) else { return }

        if card.status == targetStatus {
            let reordered = TicketsBoardLogic.reorderCard(key: draggedKey, before: beforeKey, in: columnKeys)
            clientOrder[targetStatus.rawValue] = reordered
            saveOrder()
            return
        }

        await performMove(card: card, to: targetStatus, at: index, beforeKey: beforeKey, in: board)
    }

    @MainActor
    private func performMove(
        card: API.TicketSummary,
        to targetStatus: API.TicketStatus,
        at targetIndex: Int?,
        beforeKey: String?,
        in board: API.Board
    ) async {
        guard card.status != targetStatus else { return }
        guard let client = context.store.client else {
            context.showToast(ToastItemModel(id: "board.move.no-client", title: "Vesper isn\u{2019}t signed in.", tone: .error))
            return
        }

        let previousOrder = clientOrder
        if let targetCol = board.columns.first(where: { $0.status == targetStatus }) {
            let existingKeys = clientOrder[targetStatus.rawValue] ?? targetCol.cards.map(\.key)
            clientOrder[targetStatus.rawValue] = TicketsBoardLogic.reorderCard(
                key: card.key,
                before: beforeKey,
                in: existingKeys
            )
            saveOrder()
        }

        let pending = TicketsBoardLogic.PendingMove(card: card, targetStatus: targetStatus, targetIndex: targetIndex)
        pendingMoves.append(pending)
        movingKey = card.key
        defer {
            pendingMoves.removeAll { $0.card.key == card.key && $0.targetStatus == targetStatus }
            if movingKey == card.key { movingKey = nil }
        }

        do {
            let detail = try await client.send(API.getTicket(key: card.key))
            let revision = try TicketsBoardLogic.moveRevision(card: card, detail: detail)
            let optimistic = TicketsBoardLogic.moveOptimisticUpdate(
                boardRequest: boardRequest,
                card: card,
                to: targetStatus,
                at: targetIndex
            )
            _ = try await context.store.mutate(
                API.updateTicket(key: card.key, body: API.TicketPatch(revision: revision, status: targetStatus)),
                optimistic: [optimistic],
                invalidating: QueryInvalidation(resources: ["board", "boards", "tickets", "planning", "inbox", "epics"])
            )
        } catch {
            clientOrder = previousOrder
            saveOrder()
            Task { _ = await context.store.refetch(boardRequest) }
            let message = (error as? APIError)?.userMessage ?? error.localizedDescription
            context.showToast(ToastItemModel(
                id: "board.move.failed.\(card.key)",
                title: "Couldn\u{2019}t move \(card.key) to \(TicketsLogic.statusLabel(targetStatus))",
                description: message,
                tone: .error
            ))
        }
    }

    private func loadSavedOrder() {
        guard let raw = UserDefaults.standard.dictionary(forKey: orderStorageKey) as? [String: [String]] else {
            clientOrder = [:]
            return
        }
        clientOrder = raw
    }

    private func saveOrder() {
        UserDefaults.standard.set(clientOrder, forKey: orderStorageKey)
    }

    private func copyAndToast(_ text: String, label: String) {
        context.copyToClipboard(text)
        context.showToast(ToastItemModel(id: "board.copy.\(text)", title: label, tone: .success))
    }

    private func copyTicketLink(_ key: String) {
        let path = TicketsLogic.ticketHref(key)
        let copied = context.resolvedURL(path)?.absoluteString ?? path
        context.copyToClipboard(copied)
        context.showToast(ToastItemModel(id: "board.link.\(key)", title: "Link copied", tone: .success))
    }

    private func emptyBoardState(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: theme.pointSize(.title), weight: .semibold))
                .foregroundStyle(theme.palette.text)
            Text(subtitle)
                .font(.system(size: theme.pointSize(.body)))
                .foregroundStyle(theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var boardSkeleton: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBar(height: 14).frame(width: 110)
                    SkeletonBar(height: 74).frame(width: 248)
                    SkeletonBar(height: 74).frame(width: 248)
                    Spacer()
                }
                .padding(12)
                .frame(width: 288)
                .background(theme.palette.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

// MARK: - Board Card

private struct BoardCardView: View {
    @Environment(\.vesperTheme) private var theme
    let card: API.TicketSummary
    let needs: TicketsLogic.NeedsYou?
    let showEpic: Bool
    let isMoving: Bool
    let findQuery: String
    let findActive: Bool
    let onOpen: (_ newTab: Bool) -> Void
    let onOpenNeeds: (String) -> Void
    let onMoveToStatus: (API.TicketStatus) -> Void
    let onStart: () -> Void
    let onCopyKey: () -> Void
    let onCopyLink: () -> Void

    @State private var hovered = false

    var body: some View {
        let canStart = needs == nil && card.status == .todo && card.unmetDependencies == 0 && card.assignee != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(card.key)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
                if let pr = card.pr {
                    prBadge(pr)
                }
                Spacer(minLength: 4)
                if card.priority != .none {
                    TicketPriorityBadge(priority: card.priority)
                }
                TicketEstimateBadge(points: card.estimatePoints, compact: false)
            }

            Text(card.title)
                .font(.system(size: theme.pointSize(.body), weight: .medium))
                .foregroundStyle(theme.palette.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if needs != nil || card.unmetDependencies > 0 || (showEpic && card.epic != nil) || !card.labels.isEmpty {
                HStack(spacing: 5) {
                    if let needs {
                        Button {
                            onOpenNeeds(needs.href)
                        } label: {
                            TonePill(
                                label: needs.label,
                                tone: needs.pillTone
                            )
                        }
                        .buttonStyle(.plain)
                    } else if card.unmetDependencies > 0 {
                        TonePill(
                            label: "\(card.unmetDependencies) blocked",
                            tone: "blocked"
                        )
                    }
                    if showEpic, let epic = card.epic {
                        TicketEpicChip(epic: epic)
                    }
                    ForEach(card.labels.prefix(2), id: \.id) { label in
                        TicketLabelChip(label: label)
                    }
                }
            }

            HStack(spacing: 8) {
                if card.criteriaTotal > 0 {
                    TicketProgressPill(done: card.criteriaDone, total: card.criteriaTotal, showBar: false)
                }
                if canStart {
                    Button {
                        onStart()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                    }
                    .buttonStyle(.vesper())
                    .controlSize(.small)
                }
                Spacer()
                if let assignee = card.assignee {
                    WorkPersonaAvatarView(agent: assignee, size: 18)
                } else {
                    UnassignedAvatarCircle(size: 18)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            findActive && !findQuery.isEmpty
                ? theme.palette.accent.opacity(0.18)
                : (hovered ? theme.palette.surface : theme.palette.background),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    hovered ? theme.palette.accent.opacity(0.45) : theme.palette.border.opacity(0.75),
                    lineWidth: 1
                )
        )
        .opacity(isMoving ? 0.65 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
        .onTapGesture { onOpen(false) }
        .contextMenu {
            Button("Open ticket") { onOpen(false) }
            Button("Open in new tab") { onOpen(true) }
            if canStart {
                Button("Start run", action: onStart)
            }
            Menu("Move to") {
                ForEach(TicketsLogic.statusOrder, id: \.rawValue) { status in
                    Button {
                        onMoveToStatus(status)
                    } label: {
                        if status == card.status {
                            Label(TicketsLogic.statusLabel(status), systemImage: "checkmark")
                        } else {
                            Text(TicketsLogic.statusLabel(status))
                        }
                    }
                    .disabled(status == card.status)
                }
            }
            Divider()
            Button("Copy \(card.key)", action: onCopyKey)
            Button("Copy link", action: onCopyLink)
        }
    }

    private func prBadge(_ pr: API.PullRequest) -> some View {
        let tone: String = switch pr.state {
        case .merged: "done"
        case .closed: pr.closedUnmerged == true ? "blocked" : "neutral"
        case .open: "review"
        default: "neutral"
        }
        return TonePill(label: "#\(pr.number)", tone: tone)
    }
}

// MARK: - Epic Criteria & Gate Header

private struct BoardEpicHeaderView: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(NativeScreenContext.self) private var context

    let summary: API.BoardEpic
    let projectKey: String
    let boardRequest: APIRequest<API.Board>
    let onNavigate: (String) -> Void

    @State private var criteriaExpanded = true
    @State private var newCriterionText = ""
    @State private var editingId: String?
    @State private var editingText = ""
    @State private var busy = false
    @State private var inlineError: String?

    var body: some View {
        let readiness = TicketsBoardLogic.epicReadiness(summary)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(summary.epic.name)
                    .font(.system(size: theme.pointSize(.title), weight: .semibold))
                    .foregroundStyle(theme.palette.text)

                TonePill(label: readiness.healthLabel, tone: readiness.healthTone.rawValue)
                TonePill(
                    label: readiness.isClosed ? "Done" : "Open",
                    tone: readiness.isClosed ? "done" : "neutral"
                )

                Button {
                    onNavigate("/epics/\(summary.epic.id)")
                } label: {
                    Text("Epic page \u{2192}")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.accent)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task { await toggleRequiresMockup() }
                } label: {
                    Label(
                        summary.epic.requiresMockup ? "Mockup required" : "No mockup gate",
                        systemImage: summary.epic.requiresMockup ? "checkmark.square" : "square"
                    )
                    .font(.system(size: theme.pointSize(.small)))
                }
                .buttonStyle(.vesper(.outline))
                .controlSize(.small)
                .disabled(busy)
                .help("Require an approved UI mockup on every ticket in this epic before closing")

                if let review = summary.review {
                    Button("Review: \(review.key)") {
                        onNavigate(TicketsLogic.ticketHref(review.key))
                    }
                    .buttonStyle(.vesper(.outline))
                    .controlSize(.small)
                } else {
                    Button("Final review") {
                        Task { await createFinalReview() }
                    }
                    .buttonStyle(.vesper(.outline))
                    .controlSize(.small)
                    .disabled(busy)
                }

                if readiness.isClosed {
                    Button("Reopen epic") {
                        Task { await setEpicStatus(.open) }
                    }
                    .buttonStyle(.vesper(.outline))
                    .controlSize(.small)
                    .disabled(busy)
                } else {
                    Button("Mark epic done") {
                        Task { await setEpicStatus(.done) }
                    }
                    .buttonStyle(.vesper(readiness.canMarkDone ? .approve : .outline))
                    .controlSize(.small)
                    .disabled(busy || !readiness.canMarkDone)
                    .help(doneButtonHelp(readiness))
                }
            }

            if let objective = summary.objective, !objective.isEmpty {
                Text(objective)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 18) {
                progressMeter(
                    label: "Points",
                    detail: "\(readiness.pointsDone) / \(readiness.pointsTotal) pts",
                    ratio: readiness.pointsRatio,
                    complete: readiness.pointsTotal > 0 && readiness.pointsDone >= readiness.pointsTotal
                )
                progressMeter(
                    label: "Criteria",
                    detail: "\(readiness.criteriaDone) / \(readiness.criteriaTotal)",
                    ratio: readiness.criteriaRatio,
                    complete: readiness.criteriaTotal > 0 && readiness.criteriaDone >= readiness.criteriaTotal
                )

                Spacer()

                Button {
                    criteriaExpanded.toggle()
                } label: {
                    Label(
                        criteriaExpanded ? "Hide epic criteria" : "Epic criteria (\(readiness.criteriaDone)/\(readiness.criteriaTotal))",
                        systemImage: criteriaExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.palette.secondaryText)
                }
                .buttonStyle(.plain)
            }

            if !readiness.isClosed && (readiness.missingCriteria || readiness.isGated) {
                blockersBar(readiness)
            }

            if let inlineError, !inlineError.isEmpty {
                Text(inlineError)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            if criteriaExpanded {
                Divider()
                epicCriteriaList
            }
        }
        .padding(14)
        .background(theme.palette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border.opacity(0.75)))
    }

    private func progressMeter(label: String, detail: String, ratio: Double, complete: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.secondaryText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.swiftUIColor("track", fallback: theme.palette.border))
                    Capsule()
                        .fill(complete ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.accent)
                        .frame(width: geo.size.width * min(1, max(0, ratio)))
                }
            }
            .frame(width: 96, height: 5)
            Text(detail)
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.secondaryText)
        }
    }

    private func blockersBar(_ readiness: TicketsBoardLogic.EpicReadiness) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
            if readiness.missingCriteria {
                Text("Add at least one epic criterion before closing.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.secondaryText)
            } else {
                if !readiness.openTickets.isEmpty {
                    Text("Open tickets:")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                    ForEach(readiness.openTickets.prefix(6), id: \.self) { key in
                        Button(key) {
                            onNavigate(TicketsLogic.ticketHref(key))
                        }
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.accent)
                        .buttonStyle(.plain)
                    }
                    if readiness.openTickets.count > 6 {
                        Text("+\(readiness.openTickets.count - 6) more")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                }
                if !readiness.uncheckedCriteria.isEmpty {
                    Text("\(readiness.uncheckedCriteria.count) unchecked epic criteria")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
        }
    }

    private var epicCriteriaList: some View {
        let sorted = summary.criteria.sorted { $0.position < $1.position }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, criterion in
                HStack(spacing: 8) {
                    Button {
                        Task { await toggleCriterion(criterion) }
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(criterion.done ? theme.swiftUIColor("state-done", fallback: .green) : Color.clear)
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    criterion.done ? theme.swiftUIColor("state-done", fallback: .green) : theme.palette.border,
                                    lineWidth: 1.2
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

                    Text("#\(criterion.position)")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)

                    if editingId == criterion.id {
                        TextField("Criterion text", text: $editingText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: theme.pointSize(.body)))
                            .onSubmit {
                                let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
                                editingId = nil
                                guard !trimmed.isEmpty, trimmed != criterion.text else { return }
                                Task { await renameCriterion(criterion.id, text: trimmed) }
                            }
                        Button("Cancel") { editingId = nil }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.secondaryText)
                    } else {
                        Text(criterion.text)
                            .font(.system(size: theme.pointSize(.body)))
                            .foregroundStyle(criterion.done ? theme.palette.tertiaryText : theme.palette.text)
                            .strikethrough(criterion.done)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture(count: 2) {
                                editingId = criterion.id
                                editingText = criterion.text
                            }
                    }

                    if let checkedBy = criterion.checkedBy, let checkedAt = criterion.checkedAt {
                        Text("\(checkedBy.name) · \(APIDate.shortAgo(checkedAt))")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }

                    Button {
                        Task { await moveCriterion(criterion, to: max(1, criterion.position - 1)) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(idx == 0)

                    Button {
                        Task { await moveCriterion(criterion, to: min(sorted.count, criterion.position + 1)) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(idx == sorted.count - 1)

                    Button {
                        editingId = criterion.id
                        editingText = criterion.text
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await deleteCriterion(criterion.id) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.tertiaryText)
                TextField("Add an epic criterion and press Enter", text: $newCriterionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.pointSize(.body)))
                    .onSubmit {
                        let text = newCriterionText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        newCriterionText = ""
                        Task { await addCriterion(text) }
                    }
            }
            .padding(.top, 2)
        }
    }

    private func doneButtonHelp(_ readiness: TicketsBoardLogic.EpicReadiness) -> String {
        if readiness.missingCriteria { return "Add at least one epic criterion first" }
        if readiness.isGated { return "Finish open tickets and check off all epic criteria first" }
        return "Mark epic done"
    }

    private var boardInvalidation: QueryInvalidation {
        QueryInvalidation(resources: ["board", "boards", "epics", "tickets", "planning"])
    }

    @MainActor
    private func toggleCriterion(_ criterion: API.EpicCriterion) async {
        inlineError = nil
        let targetDone = !criterion.done
        let optimistic = TicketsBoardLogic.epicCriterionToggleOptimisticUpdate(
            boardRequest: boardRequest,
            criterionId: criterion.id,
            done: targetDone
        )
        do {
            _ = try await context.store.mutate(
                API.updateEpicCriterion(id: criterion.id, body: API.UpdateEpicCriterionBody(done: targetDone)),
                optimistic: [optimistic],
                invalidating: boardInvalidation
            )
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            inlineError = msg
            context.showToast(ToastItemModel(id: "epic.criterion.\(criterion.id)", title: "Couldn\u{2019}t update criterion", description: msg, tone: .error))
        }
    }

    @MainActor
    private func addCriterion(_ text: String) async {
        inlineError = nil
        do {
            _ = try await context.store.mutate(
                API.createEpicCriterion(id: summary.epic.id, body: API.CreateEpicCriterionBody(text: text)),
                invalidating: boardInvalidation
            )
        } catch {
            inlineError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private func renameCriterion(_ id: String, text: String) async {
        inlineError = nil
        do {
            _ = try await context.store.mutate(
                API.updateEpicCriterion(id: id, body: API.UpdateEpicCriterionBody(text: text)),
                invalidating: boardInvalidation
            )
        } catch {
            inlineError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private func moveCriterion(_ criterion: API.EpicCriterion, to position: Int) async {
        guard position != criterion.position else { return }
        inlineError = nil
        do {
            _ = try await context.store.mutate(
                API.updateEpicCriterion(id: criterion.id, body: API.UpdateEpicCriterionBody(position: position)),
                invalidating: boardInvalidation
            )
        } catch {
            inlineError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private func deleteCriterion(_ id: String) async {
        inlineError = nil
        do {
            _ = try await context.store.mutate(
                API.deleteEpicCriterion(id: id),
                invalidating: boardInvalidation
            )
        } catch {
            inlineError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private func setEpicStatus(_ status: API.EpicStatus) async {
        busy = true
        inlineError = nil
        defer { busy = false }
        do {
            _ = try await context.store.mutate(
                API.updateEpic(id: summary.epic.id, body: API.UpdateEpicBody(status: status)),
                invalidating: boardInvalidation
            )
            context.showToast(ToastItemModel(
                id: "epic.status.\(summary.epic.id)",
                title: status == .done ? "Epic marked done" : "Epic reopened",
                tone: .success
            ))
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            inlineError = msg
            context.showToast(ToastItemModel(id: "epic.status.err", title: "Couldn\u{2019}t update epic", description: msg, tone: .error))
        }
    }

    @MainActor
    private func toggleRequiresMockup() async {
        busy = true
        inlineError = nil
        defer { busy = false }
        do {
            _ = try await context.store.mutate(
                API.updateEpic(id: summary.epic.id, body: API.UpdateEpicBody(requiresMockup: !summary.epic.requiresMockup)),
                invalidating: boardInvalidation
            )
        } catch {
            inlineError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    @MainActor
    private func createFinalReview() async {
        busy = true
        inlineError = nil
        defer { busy = false }
        do {
            let ticket = try await context.store.mutate(
                API.createEpicReview(id: summary.epic.id),
                invalidating: QueryInvalidation(resources: ["board", "boards", "epics", "tickets", "planning"])
            )
            context.showToast(ToastItemModel(id: "epic.review.\(ticket.key)", title: "Review ticket \(ticket.key) created", tone: .success))
            onNavigate(TicketsLogic.ticketHref(ticket.key))
        } catch {
            inlineError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
