import SwiftUI
import VesperCore

// MARK: - Activity Scene Icon Mapping

extension ActivitySceneKind {
    var sfSymbol: String {
        switch self {
        case .thinking: "brain.head.profile"
        case .nextStep: "arrow.triangle.turn.up.right.diamond"
        case .writingReply: "pencil.line"
        case .connector: "cable.connector"
        case .secret: "key.fill"
        case .wiki: "book.pages"
        case .tickets, .ticketLookup: "checklist"
        case .readingCode: "doc.text.magnifyingglass"
        case .searchingCode: "magnifyingglass"
        case .writingCode: "chevron.left.forwardslash.chevron.right"
        case .tests: "checkmark.seal"
        case .build: "hammer"
        case .install: "shippingbox"
        case .terminal: "terminal"
        case .github: "network"
        case .commit: "arrow.triangle.branch"
        case .push: "arrow.up.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .repoHistory: "clock.arrow.circlepath"
        case .web, .webPage: "globe"
        case .video: "film"
        case .image, .imageView: "photo"
        case .canvas, .canvasComment: "rectangle.and.pencil.and.ellipsis"
        case .design, .designView: "paintbrush"
        case .playground: "play.rectangle"
        case .runs: "bolt.circle"
        case .workflow: "flowchart"
        case .memory, .memorySave: "memorychip"
        case .chatHistory: "bubble.left.and.bubble.right"
        case .repoSearch, .repoAttach: "folder.badge.gearshape"
        case .videoRender: "film.stack"
        case .audioRender: "waveform"
        case .finance, .financeSort: "chart.line.uptrend.xyaxis"
        case .persona: "person.crop.circle"
        case .schedule: "calendar.badge.clock"
        case .learning: "graduationcap"
        case .research: "doc.text.magnifyingglass"
        case .space: "square.stack.3d.up"
        case .savedLinks: "bookmark"
        case .projects: "folder"
        case .library: "photo.on.rectangle"
        case .inbox: "tray"
        case .chart: "chart.bar"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .app, .customApp: "app.badge"
        case .database: "cylinder.split.1x2"
        case .http: "network"
        case .pdf: "doc.richtext"
        case .subagent: "person.2.wave.2"
        case .choices: "list.bullet.circle"
        }
    }

    var tintColor: Color {
        switch self {
        case .thinking, .nextStep: .purple
        case .writingReply: .blue
        case .readingCode, .searchingCode, .writingCode: .indigo
        case .tests: .green
        case .build, .install, .terminal: .orange
        case .commit, .push, .pullRequest, .github, .repoHistory: .teal
        case .web, .webPage: .cyan
        case .wiki, .memory, .memorySave: .mint
        case .image, .imageView, .video, .design, .designView: .pink
        default: .accentColor
        }
    }
}

// MARK: - Live Working / Thinking Card (Matches Desktop ChatLiveActivityCardView)

struct ChatLiveActivityCardView: View {
    let speakerName: String
    let events: [API.RunEvent]
    let since: String?
    let awaitingApproval: Bool
    let onStop: (() -> Void)?

    @State private var now = Date()
    @State private var showAllSteps = false
    @State private var showThinking = false

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let activity = ChatTurnActivity.fold(
            events: events.map(ChatRunEvent.init),
            since: since,
            now: now
        )
        let folded = ChatTurnActivity.foldSteps(activity.steps)
        let displaySteps = showAllSteps ? activity.steps : folded.shown
        let planProgress = ChatTurnActivity.planProgress(steps: activity.steps, planned: activity.planned)
        let liveTimerMs = activity.phaseElapsedMs ?? activity.elapsedMs
        let secondaryTimingLine: String? = {
            var parts: [String] = []
            if let total = activity.elapsedMs, let phase = activity.phaseElapsedMs, total - phase >= 1000 {
                parts.append("Total \(ChatTurnActivity.formatSpan(ms: total))")
            }
            if activity.thinkingDurationMs >= 1000 {
                let same = activity.timingPhase == .thinking
                    && activity.phaseElapsedMs.map { abs(activity.thinkingDurationMs - $0) < 1000 } == true
                if !same {
                    parts.append("Thought for \(ChatTurnActivity.formatSpan(ms: activity.thinkingDurationMs))")
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        let activeThinkingDetail: String? = {
            if case .thinking(let detail) = activity.activePhase { return detail }
            return nil
        }()

        VStack(alignment: .leading, spacing: 10) {
            // Header row: animated activity badge + status phrase + live timer + stop
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(activity.status.kind.tintColor.opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: awaitingApproval ? "hand.raised.fill" : activity.status.kind.sfSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(awaitingApproval ? .orange : activity.status.kind.tintColor)
                        .symbolEffect(.pulse, isActive: true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(awaitingApproval
                             ? "\(speakerName) is waiting for your approval"
                             : "\(speakerName) is \(activity.status.phrase)…")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        if let liveTimerMs {
                            Text(ChatTurnActivity.formatSpan(ms: liveTimerMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let secondaryTimingLine {
                        Text(secondaryTimingLine)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let onStop {
                    Button(role: .destructive, action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop turn")
                }
            }

            // Opening line
            if let opening = activity.openingLine, !opening.isEmpty {
                Text(opening)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Plan checklist progress bar (when set_plan / TodoWrite was used)
            if let plan = planProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Plan", systemImage: "list.bullet.clipboard")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(plan.progressLabel)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(plan.completed), total: Double(max(1, plan.total)))
                        .tint(plan.failed > 0 ? .orange : .accentColor)
                }
                .padding(.vertical, 2)
            }

            // Steps list
            if !displaySteps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !showAllSteps && folded.earlier > 0 {
                        Button("Show \(folded.earlier) earlier step\(folded.earlier == 1 ? "" : "s")") {
                            withAnimation(.easeInOut(duration: 0.2)) { showAllSteps = true }
                        }
                        .font(.caption.weight(.medium))
                    }
                    ForEach(displaySteps, id: \.key) { step in
                        ChatTurnStepRowView(step: step)
                    }
                    if !showAllSteps && folded.later > 0 {
                        Text("+\(folded.later) planned")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
                .padding(.top, 2)
            }

            // Collapsible live thinking blocks
            if !activity.thinkingBlocks.isEmpty || activeThinkingDetail != nil {
                DisclosureGroup(isExpanded: $showThinking) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(activity.thinkingBlocks) { block in
                            VStack(alignment: .leading, spacing: 2) {
                                if let heading = block.heading, !heading.isEmpty {
                                    Text(heading)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(block.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        if let detail = activeThinkingDetail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.purple)
                        Text(activity.thinkingBlocks.isEmpty
                             ? "Thinking…"
                             : "Thinking (\(activity.thinkingBlocks.count))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .onReceive(timer) { tick in
            now = tick
        }
    }
}

// MARK: - Finished Turn Steps Card in History (Matches Desktop ChatTurnStepsCardView)

struct ChatTurnStepsCardView: View {
    let events: [API.RunEvent]
    let outcome: ChatTurnOutcome
    let since: String?
    let until: String?
    let end: TimeInterval?

    @State private var expanded = false
    @State private var showAllEarlier = false
    @State private var showThinking = false

    var body: some View {
        let turn = ChatTurnActivity.finishedTurn(
            events: events.map(ChatRunEvent.init),
            outcome: outcome,
            since: since,
            until: until,
            end: end
        )
        if !turn.steps.isEmpty || !turn.thinkingBlocks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !turn.steps.isEmpty {
                    let failureFold = outcome == .failed && !showAllEarlier
                        ? ChatTurnActivity.foldStepsFromFailure(turn.steps)
                        : (earlier: 0, shown: turn.steps)
                    let summary = ChatTurnActivity.finishedSummary(
                        outcome: outcome,
                        stepCount: turn.steps.count,
                        durationMs: turn.durationMs,
                        thinkingDurationMs: turn.thinkingDurationMs
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: outcomeIcon)
                                    .font(.caption)
                                    .foregroundStyle(outcomeColor)
                                Text(summary.isEmpty ? "\(turn.steps.count) steps" : summary)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)

                        if expanded {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                if failureFold.earlier > 0 {
                                    Button("Show \(failureFold.earlier) earlier step\(failureFold.earlier == 1 ? "" : "s")") {
                                        showAllEarlier = true
                                    }
                                    .font(.caption)
                                }
                                ForEach(failureFold.shown, id: \.key) { step in
                                    ChatTurnStepRowView(step: step)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(outcome == .failed ? Color.red.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                }

                if !turn.thinkingBlocks.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(turn.thinkingBlocks) { block in
                                VStack(alignment: .leading, spacing: 2) {
                                    if let heading = block.heading, !heading.isEmpty {
                                        Text(heading)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(block.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                            if let ms = turn.thinkingDurationMs, ms >= 1000 {
                                Text("Thought for \(ChatTurnActivity.formatSpan(ms: ms))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Thinking (\(turn.thinkingBlocks.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                if outcome == .stopped {
                    Text("Stopped before it replied.")
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var outcomeIcon: String {
        switch outcome {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .stopped: "pause.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch outcome {
        case .done: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

// MARK: - Single Step Row

struct ChatTurnStepRowView: View {
    let step: ChatTurnStep

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: stepIcon(step.state))
                    .font(.caption)
                    .foregroundStyle(stepColor(step.state))

                Text(step.title)
                    .font(.caption)
                    .foregroundStyle(step.state == .planned ? .tertiary : .primary)
                    .lineLimit(2)

                if let detail = step.detail, !detail.isEmpty {
                    Text("· \(detail)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if step.state != .active, let started = step.startedAt, let ended = step.endedAt {
                    let ms = Int((ended - started) * 1000)
                    if ms >= 1000 {
                        Text(ChatTurnActivity.formatSpan(ms: ms))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let intent = step.intent, !intent.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    if let tag = step.tag {
                        Text(tag == .surprise ? "Surprise" : "New approach")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                (tag == .surprise ? Color.orange : Color.purple).opacity(0.18),
                                in: Capsule()
                            )
                            .foregroundStyle(tag == .surprise ? .orange : .purple)
                    }
                    Text(intent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
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

    private func stepColor(_ state: ChatStepState) -> Color {
        switch state {
        case .done: .green
        case .active: .accentColor
        case .failed: .red
        case .planned: .secondary
        }
    }
}

// MARK: - Code Changes Card (Files Changed During Turn)

struct ChatCodeChangesCardView: View {
    let changes: [API.ChatCodeChange]
    let branch: String?

    @State private var expanded = false
    @State private var selectedFile: API.ChatCodeChange?

    var body: some View {
        let totalAdd = changes.reduce(0) { $0 + $1.additions }
        let totalDel = changes.reduce(0) { $0 + $1.deletions }

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.indigo)
                    Text("\(changes.count) file\(changes.count == 1 ? "" : "s") changed")
                        .font(.caption.weight(.semibold))
                    if let branch, !branch.isEmpty {
                        Text(branch)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if totalAdd > 0 {
                        Text("+\(totalAdd)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if totalDel > 0 {
                        Text("-\(totalDel)")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes, id: \.path) { change in
                        Button {
                            if change.patch != nil { selectedFile = change }
                        } label: {
                            HStack(spacing: 6) {
                                Text(change.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if change.additions > 0 {
                                    Text("+\(change.additions)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.green)
                                }
                                if change.deletions > 0 {
                                    Text("-\(change.deletions)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.red)
                                }
                                if change.patch != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .sheet(item: Binding(
            get: { selectedFile.map { IdentifiableCodeChange(change: $0) } },
            set: { selectedFile = $0?.change }
        )) { item in
            NavigationStack {
                ScrollView {
                    if let patch = item.change.patch,
                       case .success(let diffSpec) = ChatDiffSpec.parse(patch) {
                        ChatDiffCardView(spec: diffSpec)
                            .padding()
                    } else {
                        Text(item.change.patch ?? "No diff available.")
                            .font(.caption.monospaced())
                            .padding()
                    }
                }
                .navigationTitle((item.change.path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selectedFile = nil }
                    }
                }
            }
        }
    }
}

private struct IdentifiableCodeChange: Identifiable {
    var id: String { change.path }
    let change: API.ChatCodeChange
}

// MARK: - Inline Push Request Card

struct ChatPushRequestCardView: View {
    let request: API.PushRequest
    let client: APIClient?
    let onUpdated: () -> Void

    @State private var busy = false
    @State private var errorMessage: String?

    private var isPending: Bool { request.state.rawValue == "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.teal)
                Text(request.title.isEmpty ? "Push & Pull Request" : request.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                statusPill
            }

            Text(ChatCardDisplay.pushSummary(
                branch: request.branch,
                commitCount: request.commits.count,
                fileCount: request.files.count
            ))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            if let prUrl = request.prUrl, let url = URL(string: prUrl) {
                Link(destination: url) {
                    Label(
                        request.prNumber.map { "Pull Request #\($0)" } ?? "Open Pull Request",
                        systemImage: "arrow.up.right.square"
                    )
                    .font(.caption.weight(.semibold))
                }
            }

            if let err = request.error, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isPending {
                HStack(spacing: 8) {
                    Button {
                        Task { await decide(.push) }
                    } label: {
                        Label("Push & Open PR", systemImage: "arrow.up.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy || client == nil)

                    Button(role: .destructive) {
                        Task { await decide(.deny) }
                    } label: {
                        Text("Decline")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busy || client == nil)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isPending ? Color.teal.opacity(0.4) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private var statusPill: some View {
        let state = request.state.rawValue
        let color: Color = switch state {
        case "pushed", "merged": .green
        case "denied", "failed": .red
        case "pending": .orange
        default: .secondary
        }
        return Text(state.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func decide(_ decision: API.PushRequestDecision.Decision) async {
        guard let client else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            _ = try await client.send(API.decidePushRequest(
                id: request.id,
                body: API.PushRequestDecision(decision: decision)
            ))
            onUpdated()
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

// MARK: - Inline Tool Approval Cards

struct ChatToolApprovalCardView: View {
    let approval: API.Approval
    let client: APIClient?
    let onDecided: () -> Void

    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Approval Needed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(approval.scope)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Text(approval.actionSummary)
                .font(.callout)

            if !approval.riskSummary.isEmpty {
                Text(approval.riskSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let preview = approval.actionPreview, !preview.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(preview)
                        .font(.caption.monospaced())
                        .padding(8)
                }
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await decide("approved") }
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(busy || client == nil)

                Button(role: .destructive) {
                    Task { await decide("denied") }
                } label: {
                    Label("Deny", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy || client == nil)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func decide(_ decision: String) async {
        guard let client else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["decision": decision])
            _ = try await client.request("POST", "/api/v1/approvals/\(approval.id)/decision", body: payload)
            onDecided()
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
