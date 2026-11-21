import AppKit
import SwiftUI
import VesperCore

/// What the Overview draws, read from the screen's queries.
struct WorkOverviewData {
    var runs: [API.Run]
    var needs: [API.InboxItem]
    var runner: API.RunnerStatus?
    var costs: API.CostReport?
    /// Nil while the ticket list loads.
    var tickets: [API.TicketSummary]?
    var project: String?
    var filter: WorkLogic.ActivityFilter
    var now: Date
}

/// Work's calm single-column Overview (web work/activity-overview.tsx): one hairline telemetry strip,
/// items needing the person's decision, active runs, ready tickets to dispatch, and today's finished
/// runs. Failed today hides all but Finished today, as on the web.
struct WorkOverview: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let data: WorkOverviewData
    let model: WorkModel

    private struct FindRow: Equatable {
        let id: String
        let text: String
    }

    var body: some View {
        let stats = WorkLogic.activityStats(runs: data.runs, inbox: data.needs, runner: data.runner, now: data.now)
        let running = WorkLogic.runningNow(data.runs)
        let finished = WorkLogic.finishedToday(data.runs, now: data.now)
        let tickets = data.tickets ?? []
        let ready = WorkLogic.readyTickets(tickets, running: running)
        let assigned = WorkLogic.assignedReadyKeys(tickets, running: running)
        let showsWork = data.filter != .failed
        let rows = findRows(showsWork: showsWork, running: running, ready: ready, finished: finished)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    telemetry(stats)
                    if showsWork {
                        needsSection
                        if !running.isEmpty { runningSection(running) }
                        readySection(ready, assigned: assigned)
                    }
                    if !finished.isEmpty { finishedSection(finished) }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: context.find.current) { _, index in
                guard let index, index < rows.count else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(rows[index].id, anchor: .center) }
            }
        }
        .onChange(of: rows.map(\.text), initial: true) { _, texts in context.find.texts = texts }
        .accessibilityLabel("Activity overview")
    }

    private func findRows(showsWork: Bool, running: [API.Run], ready: [API.TicketSummary], finished: [API.Run]) -> [FindRow] {
        var rows: [FindRow] = []
        if showsWork {
            rows += data.needs.map { FindRow(id: "needs:\($0.id)", text: [$0.title, $0.ticketKey, $0.summary, $0.agent?.name ?? ""].joined(separator: " ")) }
            rows += running.map { FindRow(id: "run:\($0.id)", text: runText($0)) }
            rows += ready.map { FindRow(id: "ticket:\($0.key)", text: "\($0.key) \($0.title) \($0.assignee?.name ?? "")") }
        }
        rows += finished.map { FindRow(id: "done:\($0.id)", text: runText($0)) }
        return rows
    }

    private func runText(_ run: API.Run) -> String {
        [run.ticketKey, WorkLogic.runTitle(run), run.agent.name].joined(separator: " ")
    }

    // MARK: Telemetry strip

    private func telemetry(_ stats: WorkLogic.ActivityStats) -> some View {
        let costs = data.costs
        return HStack(spacing: 0) {
            cell {
                caption("Runner") {
                    Text(stats.runnerState)
                        .font(mono(10))
                        .foregroundStyle(stats.online ? color("state-done", .green)
                            : stats.starting ? theme.palette.tertiaryText : color("pill-blocked-fg", .red))
                }
                (Text("\(stats.slotsBusy)") + Text(" / \(stats.slotsMax)").font(mono(12)).foregroundStyle(theme.palette.tertiaryText))
                    .font(mono(16, weight: .semibold))
                footnote("\(stats.queued) queued")
            }
            divider
            cell {
                caption("Needs you") {
                    if stats.needsYouCount > 0 { Circle().fill(color("state-human", .orange)).frame(width: 6, height: 6) }
                }
                Text("\(stats.needsYouCount)")
                    .font(mono(16, weight: .semibold))
                    .foregroundStyle(stats.needsYouCount > 0 ? color("pill-human-fg", .orange) : theme.palette.text)
                footnote(stats.needsBreakdown)
            }
            divider
            cell {
                caption("Today") { EmptyView() }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(stats.completedToday)").font(mono(16, weight: .semibold))
                    Text("done").font(.system(size: px(11))).foregroundStyle(theme.palette.tertiaryText)
                }
                footnote(stats.todayDetail)
            }
            divider
            cell {
                caption("7d spend") {
                    link("Reports \u{2192}", size: 11) { context.navigate(WorkLogic.reportsHref(project: data.project)) }
                }
                Text(costs.map { WorkLogic.spendLabel(micros: $0.total.costMicros, unpricedRuns: $0.unpricedRuns) } ?? "\u{2013}")
                    .font(mono(16, weight: .semibold))
                if let costs {
                    footnote("\(costs.total.runs) run\(costs.total.runs == 1 ? "" : "s")")
                } else {
                    SkeletonBar(height: 12).frame(width: 64)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .card(theme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity telemetry")
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2, content: content)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 4)
            trailing()
        }
        .font(.system(size: px(11)))
        .foregroundStyle(theme.palette.tertiaryText)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.system(size: px(11))).foregroundStyle(theme.palette.tertiaryText).lineLimit(1)
    }

    private var divider: some View {
        Rectangle().fill(subtleBorder).frame(width: 1)
    }

    // MARK: Needs you

    private var needsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Needs you", count: data.needs.count, human: !data.needs.isEmpty)
            if data.needs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: px(12), weight: .semibold)).foregroundStyle(color("state-done", .green))
                    Text("All caught up \u{2014} no approvals or questions waiting on you.")
                }
                .font(.system(size: px(13)))
                .foregroundStyle(theme.palette.tertiaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(theme)
            } else {
                ForEach(data.needs, id: \.id) { item in needsCard(item).id("needs:\(item.id)") }
            }
        }
    }

    private func needsCard(_ item: API.InboxItem) -> some View {
        let kind = InboxLogic.kind(item.kind.rawValue)
        let run = item.runId.flatMap { $0.isEmpty ? nil : $0 }
        let human = color("state-human", .orange)
        return HStack(spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if let agent = item.agent {
                    WorkPersonaAvatarView(agent: agent, size: 20)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: px(10)))
                        .foregroundStyle(color("pill-human-fg", .orange))
                        .frame(width: 20, height: 20)
                        .background(color("pill-human-bg", human.opacity(0.2)), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TonePill(label: kind.label, tone: kind.tone == .blocked ? "blocked" : "human")
                        if !item.ticketKey.isEmpty {
                            Text(item.ticketKey).font(mono(11)).foregroundStyle(theme.palette.tertiaryText)
                        }
                        Text(item.title).font(.system(size: px(13), weight: .medium)).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let agent = item.agent { Text(agent.name) }
                        Text("waiting \(APIDate.waited(item.createdAt, now: data.now))")
                        if !item.summary.isEmpty {
                            Text("· \(item.summary)").foregroundStyle(theme.palette.secondaryText).lineLimit(1)
                        }
                    }
                    .font(.system(size: px(11)))
                    .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let run {
                Button("Review \u{2192}") { openRun(run) }.buttonStyle(.vesper(.approveOutline))
            } else {
                Button("Open \u{2192}") { open(item.href) }.buttonStyle(.vesper(.outline))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hoverFill(color("pill-human-bg", human.opacity(0.2)).opacity(0.15), hover: color("pill-human-bg", human.opacity(0.2)).opacity(0.25))
        .findHighlight(context.find.matches(findText(item)), theme)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(human.opacity(0.4)))
        .contextMenu {
            if let run { Button("Open Run") { openRun(run) } }
            Button("Open") { open(item.href) }
            if !InboxLogic.isExternalHref(item.href) { Button("Open in New Tab") { context.openInNewTab(item.href) } }
            if !item.ticketKey.isEmpty { Button("Open \(item.ticketKey)") { context.navigate(ticketHref(item.ticketKey)) } }
            Divider()
            Button("Copy Link") { copyLink(item.href) }
        }
    }

    private func findText(_ item: API.InboxItem) -> String {
        [item.title, item.ticketKey, item.summary, item.agent?.name ?? ""].joined(separator: " ")
    }

    // MARK: Running now

    private func runningSection(_ runs: [API.Run]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Running now", count: runs.count)
            ForEach(runs, id: \.id) { run in runningRow(run).id("run:\(run.id)") }
        }
    }

    private func runningRow(_ run: API.Run) -> some View {
        let done = color("state-done", .green)
        return Button { openRun(run.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    WorkPersonaAvatarView(agent: run.agent, size: 20)
                    dot(WorkLogic.runDot(run))
                    if !run.ticketKey.isEmpty {
                        Text(run.ticketKey).font(mono(11)).foregroundStyle(theme.palette.tertiaryText).fixedSize()
                    }
                    Text(WorkLogic.runTitle(run)).font(.system(size: px(13), weight: .medium)).lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 8) {
                        Text(APIDate.duration(since: run.startedAt, until: run.endedAt, now: data.now))
                        if run.costUsd > 0 { Text(WorkLogic.runCost(run.costUsd, source: run.costSource)) }
                    }
                    .font(mono(11))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .fixedSize()
                }
                HStack(spacing: 12) {
                    Text("\(run.agent.name) · \(run.harness)/\(run.model)").foregroundStyle(theme.palette.tertiaryText)
                    if let step = WorkLogic.currentStep(run) {
                        Text(step).foregroundStyle(done).lineLimit(1)
                    }
                }
                .font(.system(size: px(11)))
                if let pct = WorkLogic.planProgress(run) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(sunken)
                            Capsule().fill(done).frame(width: geo.size.width * CGFloat(pct) / 100)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(theme.palette.surface, hover: theme.palette.hover)
        .findHighlight(context.find.matches(runText(run)), theme)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
        .contextMenu { runMenu(run) }
    }

    // MARK: Ready to start

    private func readySection(_ ready: [API.TicketSummary], assigned: [String]) -> some View {
        let tasks = WorkLogic.tasksHref(project: data.project)
        return VStack(alignment: .leading, spacing: 8) {
            heading("Ready to start", count: ready.count) {
                HStack(spacing: 8) {
                    if !assigned.isEmpty {
                        Button { model.dispatchKeys = assigned } label: {
                            Label("Start ready (\(assigned.count))", systemImage: "play.fill")
                        }
                        .buttonStyle(.vesper(.approveOutline))
                    }
                    link("All tasks \u{2192}", size: 12) { context.navigate(tasks) }
                }
            }
            if data.tickets == nil {
                SkeletonBar(height: 64)
            } else if ready.isEmpty {
                HStack(spacing: 12) {
                    Text("No unblocked tasks queued for dispatch.").foregroundStyle(theme.palette.tertiaryText)
                    Spacer()
                    link("Open Tasks \u{2192}", size: 12, weight: .medium) { context.navigate(tasks) }
                }
                .font(.system(size: px(13)))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .card(theme)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(ready.enumerated()), id: \.element.id) { index, ticket in
                        if index > 0 { Rectangle().fill(subtleBorder).frame(height: 1) }
                        readyRow(ticket).id("ticket:\(ticket.key)")
                    }
                }
                .card(theme)
            }
        }
    }

    private func readyRow(_ ticket: API.TicketSummary) -> some View {
        let href = ticketHref(ticket.key)
        return Button { open(href) } label: {
            HStack(spacing: 12) {
                Text(ticket.key).font(mono(11)).foregroundStyle(theme.palette.tertiaryText)
                    .frame(width: 64, alignment: .leading).lineLimit(1)
                Text(ticket.title).font(.system(size: px(13), weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let points = ticket.estimatePoints {
                    Text("\(points) pt").font(mono(11)).foregroundStyle(theme.palette.tertiaryText)
                }
                if let assignee = ticket.assignee {
                    HStack(spacing: 6) {
                        WorkPersonaAvatarView(agent: assignee, size: 20)
                        Text(assignee.name)
                    }
                    .font(.system(size: px(12)))
                    .foregroundStyle(theme.palette.secondaryText)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(color("unassigned", theme.palette.tertiaryText), style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                        .frame(width: 18, height: 18)
                        .accessibilityLabel("Unassigned")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(.clear, hover: theme.palette.hover)
        .findHighlight(context.find.matches("\(ticket.key) \(ticket.title) \(ticket.assignee?.name ?? "")"), theme)
        .contextMenu {
            Button("Open \(ticket.key)") { context.navigate(href) }
            Button("Open in New Tab") { context.openInNewTab(href) }
            Divider()
            Button("Copy Link") { copyLink(href) }
        }
    }

    // MARK: Finished today

    private func finishedSection(_ runs: [API.Run]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Finished today", count: runs.count)
            VStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                    if index > 0 { Rectangle().fill(subtleBorder).frame(height: 1) }
                    finishedRow(run).id("done:\(run.id)")
                }
            }
            .card(theme)
        }
    }

    private func finishedRow(_ run: API.Run) -> some View {
        let state = WorkLogic.runDot(run)
        return Button { openRun(run.id) } label: {
            HStack(spacing: 10) {
                dot(state).help(state.label)
                if !run.ticketKey.isEmpty {
                    Text(run.ticketKey).font(mono(11)).foregroundStyle(theme.palette.tertiaryText)
                        .frame(width: 64, alignment: .leading).lineLimit(1)
                }
                Text(WorkLogic.runTitle(run)).font(.system(size: px(12), weight: .medium)).lineLimit(1)
                    .foregroundStyle(theme.palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    WorkPersonaAvatarView(agent: run.agent, size: 20)
                    Text(run.agent.name)
                }
                .font(.system(size: px(11)))
                .foregroundStyle(theme.palette.tertiaryText)
                if let pr = run.prNumber {
                    Text("PR #\(pr)")
                        .font(mono(10))
                        .foregroundStyle(theme.palette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(sunken, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(APIDate.duration(since: run.startedAt, until: run.endedAt, now: data.now))
                    .frame(width: 48, alignment: .trailing)
                Text(WorkLogic.shortAgo(run.endedAt ?? run.startedAt, now: data.now))
                    .frame(width: 40, alignment: .trailing)
            }
            .font(mono(11))
            .foregroundStyle(theme.palette.tertiaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(.clear, hover: theme.palette.hover)
        .findHighlight(context.find.matches(runText(run)), theme)
        .contextMenu { runMenu(run) }
    }

    // MARK: Shared pieces

    @ViewBuilder
    private func runMenu(_ run: API.Run) -> some View {
        let href = "/runs/\(run.id)"
        Button("Open Run") { openRun(run.id) }
        Button("Open in New Tab") { context.openInNewTab(href) }
        if !run.ticketKey.isEmpty { Button("Open \(run.ticketKey)") { context.navigate(ticketHref(run.ticketKey)) } }
        Divider()
        Button("Copy Run ID") { copy(run.id) }
        Button("Copy Link") { copyLink(href) }
    }

    private func heading(_ label: String, count: Int, human: Bool = false) -> some View {
        heading(label, count: count, human: human) { EmptyView() }
    }

    private func heading<Trailing: View>(_ label: String, count: Int, human: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(label.uppercased()).font(.system(size: px(11), weight: .semibold)).tracking(0.66)
                if count > 0 { Text("\(count)").font(mono(11)) }
            }
            .foregroundStyle(human ? color("pill-human-fg", .orange) : theme.palette.tertiaryText)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 2)
    }

    private func dot(_ dot: WorkLogic.Dot) -> some View {
        Group {
            switch dot {
            case .queued: Circle().stroke(theme.palette.tertiaryText, lineWidth: 1)
            case .idle: Circle().fill(theme.palette.tertiaryText.opacity(0.4))
            case .human: Circle().fill(color("state-human", .orange))
            case .failed: Circle().fill(color("state-blocked", .red))
            case .running, .done: Circle().fill(color("state-done", .green))
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    private func link(_ label: String, size: Double, weight: Font.Weight = .regular, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.link)
            .font(.system(size: px(size), weight: weight))
    }

    private func openRun(_ id: String) {
        open("/runs/\(id)")
    }

    /// ⌘-click opens in a new tab, as links do.
    private func open(_ href: String) {
        if InboxLogic.isExternalHref(href) {
            context.openExternal(href)
        } else if NSEvent.modifierFlags.contains(.command) {
            context.openInNewTab(href)
        } else {
            context.navigate(href)
        }
    }

    private func ticketHref(_ key: String) -> String {
        "/tickets/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)"
    }

    private func copyLink(_ href: String) {
        copy(InboxLogic.isExternalHref(href) ? href : (DeepLinks.hrefToVesperLink(href) ?? href))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func px(_ size: Double) -> CGFloat { size * theme.typeScale }

    private func mono(_ size: Double, weight: Font.Weight = .regular) -> Font {
        .system(size: px(size), weight: weight, design: .monospaced)
    }

    private func color(_ token: String, _ fallback: Color) -> Color { theme.swiftUIColor(token, fallback: fallback) }

    private var subtleBorder: Color { theme.swiftUIColor("border-subtle", fallback: theme.palette.rowBorder) }

    private var sunken: Color { theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface) }
}

private extension View {
    /// The web's `rounded-xl border border-border bg-surface`.
    func card(_ theme: ThemeTokens) -> some View {
        background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    func hoverFill(_ fill: Color, hover: Color) -> some View {
        modifier(HoverFill(fill: fill, hover: hover))
    }

    /// Tints a row the find bar matches.
    func findHighlight(_ isMatch: Bool, _ theme: ThemeTokens) -> some View {
        overlay { if isMatch { theme.palette.selected.allowsHitTesting(false) } }
    }
}

private struct HoverFill: ViewModifier {
    let fill: Color
    let hover: Color
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(hovered ? hover : fill)
            .onHover { hovered = $0 }
    }
}
