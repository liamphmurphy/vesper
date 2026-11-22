import Foundation

/// Pure logic for the Kanban Board view: column bucketing, cross-column moves, intra-column card
/// ordering, optimistic `QueryStore` updates with rollback, and epic criteria / completion gates
/// per the Kanban board ADR (Foundation only; zero AppKit).
public enum TicketsBoardLogic {
    public static let defaultStatuses: [API.TicketStatus] = [
        .backlog, .todo, .inProgress, .inReview, .done,
    ]

    public static func visibleStatuses(includeCanceled: Bool) -> [API.TicketStatus] {
        includeCanceled ? defaultStatuses + [.canceled] : defaultStatuses
    }

    public struct PendingMove: Sendable, Equatable {
        public var card: API.TicketSummary
        public var targetStatus: API.TicketStatus
        public var targetIndex: Int?

        public init(card: API.TicketSummary, targetStatus: API.TicketStatus, targetIndex: Int? = nil) {
            self.card = card
            self.targetStatus = targetStatus
            self.targetIndex = targetIndex
        }
    }

    public struct ColumnDisplay: Sendable, Equatable, Identifiable {
        public var id: String { status.rawValue }
        public var status: API.TicketStatus
        public var title: String
        public var cards: [API.TicketSummary]
        public var count: Int
        public var points: Int
        public var truncated: Bool

        public init(
            status: API.TicketStatus,
            title: String,
            cards: [API.TicketSummary],
            count: Int,
            points: Int,
            truncated: Bool
        ) {
            self.status = status
            self.title = title
            self.cards = cards
            self.count = count
            self.points = points
            self.truncated = truncated
        }
    }

    public enum BoardMoveError: Error, Sendable, Equatable, LocalizedError {
        case staleTicket

        public var errorDescription: String? {
            switch self {
            case .staleTicket:
                "Ticket changed elsewhere. The board has been refreshed; review it and retry."
            }
        }
    }

    /// Applies pending cross-column moves and optional intra-column insertion indexes onto `board`.
    /// Prevents double counting if a background refetch has already placed the card in `targetStatus`.
    public static func withBoardMoves(_ board: API.Board, moves: [PendingMove]) -> API.Board {
        var columns = board.columns
        for move in moves {
            let sourceIndex = columns.firstIndex { col in col.cards.contains { $0.key == move.card.key } }
            let sourceCard = sourceIndex.flatMap { idx in
                columns[idx].cards.first { $0.key == move.card.key }
            } ?? move.card

            guard let targetIndex = columns.firstIndex(where: { $0.status == move.targetStatus }) else {
                continue
            }

            if let sourceIndex, columns[sourceIndex].status == columns[targetIndex].status {
                // Intra-column reorder only.
                if let insertion = move.targetIndex {
                    var updated = columns[targetIndex].cards
                    updated.removeAll { $0.key == sourceCard.key }
                    let clamped = min(max(insertion, 0), updated.count)
                    updated.insert(sourceCard, at: clamped)
                    columns[targetIndex].cards = updated
                }
                continue
            }

            if let sourceIndex {
                columns[sourceIndex].cards.removeAll { $0.key == sourceCard.key }
                columns[sourceIndex].count = max(0, columns[sourceIndex].count - 1)
                columns[sourceIndex].points = max(0, columns[sourceIndex].points - (sourceCard.estimatePoints ?? 0))
            }

            var movedCard = sourceCard
            movedCard.status = move.targetStatus
            let insertion = min(max(move.targetIndex ?? 0, 0), columns[targetIndex].cards.count)
            columns[targetIndex].cards.insert(movedCard, at: insertion)
            columns[targetIndex].count += 1
            columns[targetIndex].points += movedCard.estimatePoints ?? 0
        }
        return API.Board(columns: columns, epic: board.epic, project: board.project)
    }

    /// Filters columns to blocked cards (`unmetDependencies > 0`) and recalculates visible counts and points.
    public static func onlyBlocked(_ board: API.Board) -> API.Board {
        let filteredColumns = board.columns.map { col in
            let blockedCards = col.cards.filter { $0.unmetDependencies > 0 }
            let pts = blockedCards.reduce(0) { $0 + ($1.estimatePoints ?? 0) }
            return API.BoardColumn(
                cards: blockedCards,
                count: blockedCards.count,
                points: pts,
                status: col.status,
                truncated: false
            )
        }
        return API.Board(columns: filteredColumns, epic: board.epic, project: board.project)
    }

    /// Reorders `key` inside a column's key list (`targetKey == nil` moves to the end).
    public static func reorderCard(key: String, before targetKey: String?, in keys: [String]) -> [String] {
        var next = keys.filter { $0 != key }
        if let targetKey, let idx = next.firstIndex(of: targetKey) {
            next.insert(key, at: idx)
        } else {
            next.append(key)
        }
        return next
    }

    /// Applies local intra-column ordering per status key (`status.rawValue -> [ticketKey]`).
    public static func applyClientOrder(_ board: API.Board, orderByStatus: [String: [String]]) -> API.Board {
        guard !orderByStatus.isEmpty else { return board }
        let updated = board.columns.map { col -> API.BoardColumn in
            guard let preferred = orderByStatus[col.status.rawValue], !preferred.isEmpty else { return col }
            var byKey = Dictionary(uniqueKeysWithValues: col.cards.map { ($0.key, $0) })
            var sorted: [API.TicketSummary] = []
            for key in preferred {
                if let card = byKey.removeValue(forKey: key) {
                    sorted.append(card)
                }
            }
            for card in col.cards where byKey[card.key] != nil {
                sorted.append(card)
            }
            return API.BoardColumn(
                cards: sorted, count: col.count, points: col.points, status: col.status, truncated: col.truncated
            )
        }
        return API.Board(columns: updated, epic: board.epic, project: board.project)
    }

    /// Produces ordered `ColumnDisplay` structs for all visible statuses.
    public static func columns(
        from board: API.Board,
        includeCanceled: Bool,
        blockedOnly: Bool = false,
        pendingMoves: [PendingMove] = [],
        clientOrder: [String: [String]] = [:]
    ) -> [ColumnDisplay] {
        var effective = withBoardMoves(board, moves: pendingMoves)
        effective = applyClientOrder(effective, orderByStatus: clientOrder)
        if blockedOnly {
            effective = onlyBlocked(effective)
        }
        let byStatus = Dictionary(uniqueKeysWithValues: effective.columns.map { ($0.status, $0) })
        return visibleStatuses(includeCanceled: includeCanceled).map { status in
            let col = byStatus[status]
            return ColumnDisplay(
                status: status,
                title: TicketsLogic.statusLabel(status),
                cards: col?.cards ?? [],
                count: col?.count ?? 0,
                points: col?.points ?? 0,
                truncated: col?.truncated ?? false
            )
        }
    }

    /// Verifies a freshly fetched `API.Ticket` still matches the board card before mutating its status.
    public static func moveRevision(card: API.TicketSummary, detail: API.Ticket) throws -> Int {
        guard detail.key == card.key, detail.status == card.status, detail.updatedAt == card.updatedAt else {
            throw BoardMoveError.staleTicket
        }
        return detail.revision
    }

    public static func boardTotals(_ columns: [ColumnDisplay]) -> (tickets: Int, points: Int) {
        var tickets = 0
        var points = 0
        for col in columns {
            tickets += col.count
            if col.status != .canceled {
                points += col.points
            }
        }
        return (tickets, points)
    }

    // MARK: Optimistic QueryStore Helpers

    @MainActor
    public static func moveOptimisticUpdate(
        boardRequest: APIRequest<API.Board>,
        card: API.TicketSummary,
        to targetStatus: API.TicketStatus,
        at index: Int? = nil
    ) -> OptimisticUpdate {
        OptimisticUpdate.update(boardRequest) { board in
            board = withBoardMoves(board, moves: [PendingMove(card: card, targetStatus: targetStatus, targetIndex: index)])
        }
    }

    @MainActor
    public static func listStatusOptimisticUpdate(
        listRequest: APIRequest<API.TicketList>,
        key: String,
        to targetStatus: API.TicketStatus
    ) -> OptimisticUpdate {
        OptimisticUpdate.update(listRequest) { list in
            guard let idx = list.tickets.firstIndex(where: { $0.key == key }) else { return }
            list.tickets[idx].status = targetStatus
        }
    }

    @MainActor
    public static func epicCriterionToggleOptimisticUpdate(
        boardRequest: APIRequest<API.Board>,
        criterionId: String,
        done: Bool
    ) -> OptimisticUpdate {
        OptimisticUpdate.update(boardRequest) { board in
            guard var boardEpic = board.epic else { return }
            guard let idx = boardEpic.criteria.firstIndex(where: { $0.id == criterionId }) else { return }
            let wasDone = boardEpic.criteria[idx].done
            boardEpic.criteria[idx].done = done
            if wasDone != done {
                boardEpic.epic.criteriaDone = max(0, boardEpic.epic.criteriaDone + (done ? 1 : -1))
                let pos = boardEpic.criteria[idx].position
                if done {
                    boardEpic.doneBlockers.uncheckedCriteria.removeAll { $0 == pos }
                } else if !boardEpic.doneBlockers.uncheckedCriteria.contains(pos) {
                    boardEpic.doneBlockers.uncheckedCriteria.append(pos)
                    boardEpic.doneBlockers.uncheckedCriteria.sort()
                }
            }
            board.epic = boardEpic
        }
    }

    // MARK: Epic Readiness & Criteria Rollup (ADR)

    public struct EpicReadiness: Sendable, Equatable {
        public var isClosed: Bool
        public var pointsDone: Int
        public var pointsTotal: Int
        public var pointsRatio: Double
        public var criteriaDone: Int
        public var criteriaTotal: Int
        public var criteriaRatio: Double
        public var openTickets: [String]
        public var uncheckedCriteria: [API.EpicCriterion]
        public var missingCriteria: Bool
        public var isGated: Bool
        public var canMarkDone: Bool
        public var healthLabel: String
        public var healthTone: Tone

        public init(
            isClosed: Bool,
            pointsDone: Int,
            pointsTotal: Int,
            pointsRatio: Double,
            criteriaDone: Int,
            criteriaTotal: Int,
            criteriaRatio: Double,
            openTickets: [String],
            uncheckedCriteria: [API.EpicCriterion],
            missingCriteria: Bool,
            isGated: Bool,
            canMarkDone: Bool,
            healthLabel: String,
            healthTone: Tone
        ) {
            self.isClosed = isClosed
            self.pointsDone = pointsDone
            self.pointsTotal = pointsTotal
            self.pointsRatio = pointsRatio
            self.criteriaDone = criteriaDone
            self.criteriaTotal = criteriaTotal
            self.criteriaRatio = criteriaRatio
            self.openTickets = openTickets
            self.uncheckedCriteria = uncheckedCriteria
            self.missingCriteria = missingCriteria
            self.isGated = isGated
            self.canMarkDone = canMarkDone
            self.healthLabel = healthLabel
            self.healthTone = healthTone
        }
    }

    public static func epicHealthLabel(_ health: API.Epic.HealthValue) -> String {
        switch health {
        case .onTrack: "On track"
        case .atRisk: "At risk"
        case .offTrack: "Off track"
        default: health.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func epicHealthTone(_ health: API.Epic.HealthValue) -> Tone {
        switch health {
        case .onTrack: .done
        case .atRisk: .human
        case .offTrack: .blocked
        default: .neutral
        }
    }

    public static func epicReadiness(_ summary: API.BoardEpic) -> EpicReadiness {
        let epic = summary.epic
        let isClosed = epic.status == .done
        let pointsRatio = epic.pointsTotal > 0 ? min(1, Double(epic.pointsDone) / Double(epic.pointsTotal)) : 0
        let criteriaRatio = epic.criteriaTotal > 0 ? min(1, Double(epic.criteriaDone) / Double(epic.criteriaTotal)) : 0
        let uncheckedPositions = Set(summary.doneBlockers.uncheckedCriteria)
        let uncheckedCriteria = summary.criteria.filter { uncheckedPositions.contains($0.position) }
        let missingCriteria = summary.criteria.isEmpty
        let isGated = !summary.doneBlockers.openTickets.isEmpty || !summary.doneBlockers.uncheckedCriteria.isEmpty
        let canMarkDone = !isClosed && !missingCriteria && !isGated

        return EpicReadiness(
            isClosed: isClosed,
            pointsDone: epic.pointsDone,
            pointsTotal: epic.pointsTotal,
            pointsRatio: pointsRatio,
            criteriaDone: epic.criteriaDone,
            criteriaTotal: epic.criteriaTotal,
            criteriaRatio: criteriaRatio,
            openTickets: summary.doneBlockers.openTickets,
            uncheckedCriteria: uncheckedCriteria,
            missingCriteria: missingCriteria,
            isGated: isGated,
            canMarkDone: canMarkDone,
            healthLabel: epicHealthLabel(epic.health),
            healthTone: epicHealthTone(epic.health)
        )
    }
}
