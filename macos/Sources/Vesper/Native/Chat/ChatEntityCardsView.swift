import SwiftUI
import VesperCore

// MARK: - Live Entity Cards Strip (LAZYAGENTS-317)

struct ChatEntityCardsStripView: View {
    let refs: [ChatEntityRef]

    var body: some View {
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(refs) { ref in
                    switch ref {
                    case .ticket(let key):
                        ChatLiveTicketCardView(key: key)
                    case .run(let id):
                        ChatLiveRunCardView(runId: id)
                    case .epic(let epicRef):
                        ChatLiveEpicCardView(epicRef: epicRef)
                    case .page(let pageRef):
                        ChatLivePageCardView(pageRef: pageRef)
                    }
                }
            }
        }
    }
}

// MARK: - Ticket Entity Card

private struct ChatLiveTicketCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let key: String

    var body: some View {
        let req = API.getTicket(key: key)
        let entry = context.store.entry(req)

        Group {
            if let ticket = entry.data {
                ticketCard(ticket)
            } else if entry.error != nil {
                notFoundChip(icon: "ticket", label: key)
            } else {
                loadingChip(icon: "ticket", label: key)
            }
        }
        .task(id: key) {
            context.store.load(req)
        }
    }

    private func ticketCard(_ ticket: API.Ticket) -> some View {
        let p = theme.palette
        let statusTone = ticketStatusTone(ticket.status.rawValue)
        return Button {
            context.navigate("/tickets/\(ticket.key)")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "ticket.fill")
                    .imageScale(.small)
                    .foregroundStyle(p.accent)
                Text(ticket.key)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.text)
                Text(ticket.title)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let assignee = ticket.assignee {
                    Text("@\(assignee.handle)")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                if let pr = ticket.pr {
                    TonePill(label: "PR #\(pr.number) · \(pr.state.rawValue)", tone: prTone(pr.state.rawValue))
                }
                TonePill(label: ticket.status.rawValue.replacingOccurrences(of: "_", with: " "), tone: statusTone)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
        .buttonStyle(.plain)
    }

    private func ticketStatusTone(_ raw: String) -> String {
        switch raw {
        case "done": "done"
        case "in_progress": "human"
        case "in_review": "review"
        case "canceled": "blocked"
        default: "neutral"
        }
    }

    private func prTone(_ raw: String) -> String {
        switch raw.lowercased() {
        case "merged": "done"
        case "open": "review"
        case "closed": "blocked"
        default: "neutral"
        }
    }
}

// MARK: - Run Entity Card

private struct ChatLiveRunCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let runId: String

    var body: some View {
        let req = API.getRun(id: runId)
        let entry = context.store.entry(req)

        Group {
            if let detail = entry.data {
                runCard(detail.run)
            } else if entry.error != nil {
                notFoundChip(icon: "play.circle", label: "run \(String(runId.prefix(8)))")
            } else {
                loadingChip(icon: "play.circle", label: "run \(String(runId.prefix(8)))")
            }
        }
        .task(id: runId) {
            context.store.load(req)
        }
    }

    private func runCard(_ run: API.Run) -> some View {
        let p = theme.palette
        let elapsed = APIDate.duration(since: run.startedAt, until: run.endedAt)
        let tokens = ChatEntityRefExtractor.compactTokens(run.inputTokens + run.outputTokens)
        let cost = ChatEntityRefExtractor.compactCost(run.costUsd)
        let title = run.workTitle ?? (run.ticketKey.isEmpty ? "Run \(String(run.id.prefix(8)))" : run.ticketKey)

        return Button {
            context.navigate("/runs/\(run.id)")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(p.accent)
                Text(run.agent.name)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                Text(title)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(elapsed)
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                Text("· \(tokens)")
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                if let cost {
                    Text("· \(cost)")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                TonePill(label: run.state.rawValue.replacingOccurrences(of: "_", with: " "), tone: runStateTone(run.state.rawValue))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
        .buttonStyle(.plain)
    }

    private func runStateTone(_ raw: String) -> String {
        switch raw {
        case "completed": "done"
        case "running", "queued": "human"
        case "failed", "cancelled": "blocked"
        case "waiting_for_approval", "waiting_for_user": "review"
        default: "neutral"
        }
    }
}

// MARK: - Epic Entity Card

private struct ChatLiveEpicCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let epicRef: String

    var body: some View {
        let req = API.listEpicOverviews()
        let entry = context.store.entry(req)
        let match = entry.data?.epics.first { ov in
            ov.epic.id.caseInsensitiveCompare(epicRef) == .orderedSame
                || ov.epic.name.caseInsensitiveCompare(epicRef) == .orderedSame
        }

        Group {
            if let overview = match {
                epicCard(overview)
            } else if entry.data != nil || entry.error != nil {
                notFoundChip(icon: "flag", label: "epic \(epicRef)")
            } else {
                loadingChip(icon: "flag", label: epicRef)
            }
        }
        .task(id: epicRef) {
            context.store.load(req)
        }
    }

    private func epicCard(_ overview: API.EpicOverview) -> some View {
        let p = theme.palette
        let done = overview.counts.done
        let total = overview.counts.total
        let ratio = total > 0 ? Double(done) / Double(total) : 0

        return Button {
            context.navigate("/epics/\(overview.epic.id)")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flag.fill")
                    .imageScale(.small)
                    .foregroundStyle(p.accent)
                Text(overview.epic.name)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.border)
                        Capsule()
                            .fill(theme.swiftUIColor("state-done", fallback: p.accent))
                            .frame(width: max(0, geo.size.width * ratio))
                    }
                }
                .frame(width: 64, height: 5)
                Text("\(done)/\(total) done")
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .foregroundStyle(p.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Wiki Page Entity Card

private struct ChatLivePageCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let pageRef: String

    var body: some View {
        let resolveReq = API.resolveLinks(ref: [pageRef])
        let entry = context.store.entry(resolveReq)
        let target = entry.data?.links.first?.target

        Group {
            if let target, target.kind != .unresolved, let href = target.href, !href.isEmpty {
                ChatLiveResolvedPageCardView(target: target, href: href)
            } else if entry.data != nil || entry.error != nil {
                notFoundChip(icon: "doc.text", label: pageRef)
            } else {
                loadingChip(icon: "doc.text", label: pageRef)
            }
        }
        .task(id: pageRef) {
            context.store.load(resolveReq)
        }
    }
}

private struct ChatLiveResolvedPageCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let target: API.LinkTarget
    let href: String

    var body: some View {
        let p = theme.palette
        let pageReq = target.path.flatMap { !$0.isEmpty ? API.getWikiPage(path: $0) : nil }
        let artifact = pageReq.flatMap { context.store.entry($0).data }
        let folder = ChatEntityRefExtractor.folderPath(from: artifact?.path ?? target.path)
        let edited = artifact.map { APIDate.shortAgo($0.updatedAt) }

        Button {
            context.navigate(href)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .imageScale(.small)
                    .foregroundStyle(p.accent)
                Text(artifact?.title ?? target.title)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                if let folder {
                    Text(folder)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let edited {
                    Text("edited \(edited)")
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
        }
        .buttonStyle(.plain)
        .task(id: target.path ?? "") {
            if let pageReq { context.store.load(pageReq) }
        }
    }
}

// MARK: - Shared Missing / Loading Chips

@MainActor
private func notFoundChip(icon: String, label: String) -> some View {
    ChatEntityFallbackChip(icon: icon, label: label, suffix: "not found", loading: false)
}

@MainActor
private func loadingChip(icon: String, label: String) -> some View {
    ChatEntityFallbackChip(icon: icon, label: label, suffix: nil, loading: true)
}

private struct ChatEntityFallbackChip: View {
    @Environment(\.vesperTheme) private var theme
    let icon: String
    let label: String
    let suffix: String?
    let loading: Bool

    var body: some View {
        let p = theme.palette
        HStack(spacing: 6) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(p.tertiaryText)
            Text(label)
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(p.secondaryText)
                .lineLimit(1)
            if let suffix {
                Text("· \(suffix)")
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
            }
            Spacer(minLength: 4)
            if loading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }
}
