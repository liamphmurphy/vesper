import SwiftUI
import VesperCore

/// Conversational run transcript (`Thread` tab): live `ActivitySceneView` + plan progress bar,
/// ended outcome card, collapsible inline turn tool calls, thinking blocks, markdown replies,
/// grouped subagent cards, approval/question action box, and pinned reply/follow-up composer.
struct RunThreadView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let detail: API.RunDetail
    let events: [API.RunEvent]
    let thread: RunThreadLogic.ThreadModel
    let needsItems: [API.InboxItem]
    let now: Date
    let onOpenTurn: (Int) -> Void
    let onOpenTrace: () -> Void
    let onRefresh: () -> Void

    @State private var expandedTurns: Set<Int> = []
    @State private var expandedTools: Set<String> = []
    @State private var expandedThinking: Set<String> = []
    @State private var composerBody = ""
    @State private var composerSending = false
    @State private var composerError: String?
    @State private var sentAtSeq: Int?
    @FocusState private var composerFocused: Bool

    private var run: API.Run { detail.run }
    private var isLive: Bool { RunsLogic.isLive(run) }
    private var asking: Bool { RunsLogic.waitsForReply(run) }
    private var canWrite: Bool { RunsLogic.canWriteFollowUp(run) }
    private var nextNeeds: API.InboxItem? {
        guard !needsItems.contains(where: { $0.runId == run.id }) else { return nil }
        return RunsLogic.nextNeedsItem(in: needsItems, afterRunId: run.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            nowLineBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !isLive {
                            outcomeCard
                        }
                        traceSummaryStrip
                        feedBody
                        if asking {
                            questionCallout
                        }
                        RunActionBoxView(
                            detail: detail,
                            lastEventSeq: thread.lastEventSeq,
                            inThread: true,
                            onRefresh: onRefresh
                        )
                        if let next = nextNeeds {
                            nextLineButton(next)
                        }
                        Color.clear.frame(height: 1).id("thread-bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: thread.items.count) { _, _ in
                    if isLive {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("thread-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            if canWrite {
                composerBar
            } else if isLive && (run.purpose == .planning || run.purpose == .chat),
                      let href = RunsLogic.workHref(for: run) {
                HStack(spacing: 4) {
                    Text("Write to \(run.agent.name) in the")
                        .foregroundStyle(theme.palette.tertiaryText)
                    Button(run.purpose == .planning ? "plan" : "chat") {
                        context.navigate(href)
                    }
                    .buttonStyle(.link)
                }
                .vesperText(.small, theme)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .padding(.top, 6)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: asking, initial: true) { _, isAsking in
            if isAsking { composerFocused = true }
        }
        .onChange(of: run.id) { _, _ in
            expandedTurns.removeAll()
            expandedTools.removeAll()
            expandedThinking.removeAll()
            composerBody = ""
            composerError = nil
            sentAtSeq = nil
        }
    }

    // MARK: - Now Line

    @ViewBuilder
    private var nowLineBar: some View {
        let progress = thread.stepProgress
        let headline = progress.current?.text ?? thread.nowLine
        let showLiveRow = isLive && (headline != nil || progress.total > 0)
        let showBar = progress.total > 0

        if showLiveRow || showBar {
            VStack(spacing: isLive ? 8 : 0) {
                if showLiveRow {
                    HStack(spacing: 12) {
                        ActivitySceneView(
                            kind: thread.activity.kind,
                            stopping: false,
                            width: 88,
                            height: 42,
                            showStageChrome: true
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(headline ?? thread.activity.phrase)
                                .vesperText(.body, theme)
                                .foregroundStyle(theme.palette.text)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(run.harness)
                                if let detailText = thread.activity.detail, !detailText.isEmpty {
                                    Text("·")
                                    Text(detailText).lineLimit(1)
                                }
                                if progress.total > 0 {
                                    Text("·")
                                    Text("Step \(progress.current?.position ?? progress.done) of \(progress.total)")
                                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                }
                            }
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.palette.tertiaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }

                if showBar {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(
                            run.state == .waiting
                                ? theme.swiftUIColor("state-human", fallback: .orange)
                                : theme.swiftUIColor("state-done", fallback: .green)
                        )
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Plan progress")
                        .accessibilityValue("\(progress.done) of \(progress.total) steps done")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, isLive ? 10 : 6)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }

    // MARK: - Outcome & Summary

    private var outcomeCard: some View {
        let workHref = RunsLogic.workHref(for: run)
        let isFailed = run.state == .failed
        let borderColor = isFailed
            ? theme.swiftUIColor("pill-blocked-bg", fallback: .red)
            : theme.palette.border

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    if run.state == .completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                    }
                    Text("OUTCOME")
                        .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                Spacer()
                if let prURL = run.prUrl, let prNumber = run.prNumber {
                    Button("PR #\(prNumber) \u{2197}") { context.openExternal(prURL) }
                        .buttonStyle(.vesper(.outline))
                }
                if let workHref {
                    let label = run.purpose == .ticket ? run.ticketKey
                        : run.purpose == .planning ? "Review proposals" : "Open chat"
                    Button(label) { context.navigate(workHref) }
                        .buttonStyle(.vesper(.outline))
                }
            }
            if let outcome = run.outcome, !outcome.isEmpty {
                MarkdownView(markdown: outcome, textStyle: .reading, textColor: "text-2", chat: true)
            } else {
                Text("The run ended without an outcome.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }
            if (run.outcome ?? "").isEmpty, let finalMsg = thread.finalMessage {
                MarkdownView(markdown: finalMsg, textStyle: .body, textColor: "text-secondary", chat: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
    }

    @ViewBuilder
    private var traceSummaryStrip: some View {
        let progress = thread.stepProgress
        if run.toolCalls > 0 || progress.total > 0 {
            let parts = [
                "Worked for \(APIDate.duration(since: run.startedAt, until: run.endedAt, now: now))",
                run.toolCalls > 0 ? "\(run.toolCalls) tool call\(run.toolCalls == 1 ? "" : "s")" : nil,
                progress.total > 0 ? "\(progress.done)/\(progress.total) plan steps" : nil,
            ].compactMap { $0 }

            Button(action: onOpenTrace) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                    Text(parts.joined(separator: " · "))
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    Text("Inspect trace \u{2192}")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(theme.palette.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedBody: some View {
        if thread.items.isEmpty {
            if isLive {
                Text(run.state == .queued
                     ? "The run starts when a runner slot is free."
                     : "Messages appear as \(run.agent.name) works.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(thread.items) { item in
                    feedRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func feedRow(_ item: RunThreadLogic.ThreadItem) -> some View {
        switch item {
        case .turnHeader(_, let turn, _, let label, _, let tools):
            turnHeaderView(turn: turn, summary: label, tools: tools)

        case .thinking(let id, _, let at, let heading, let text):
            let open = expandedThinking.contains(id)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if open { expandedThinking.remove(id) } else { expandedThinking.insert(id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                        Text(heading ?? "Thinking")
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.palette.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(RunsLogic.clockTime(at))
                            .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    Text(text)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                        .textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(theme.palette.border).frame(width: 2)
                        }
                }
            }
            .padding(.vertical, 2)

        case .message(_, _, let at, let text):
            HStack(alignment: .top, spacing: 12) {
                WorkPersonaAvatarView(agent: run.agent, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(run.agent.name)
                            .font(.system(size: theme.pointSize(.body), weight: .semibold))
                            .foregroundStyle(theme.palette.text)
                        Text(RunsLogic.clockTime(at))
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    MarkdownView(markdown: text, textStyle: .chat, textColor: "text-2", chat: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)

        case .step(_, _, let at, let position, let state, let text):
            let mark = state == "done" ? "\u{2713}" : state == "failed" ? "\u{2715}" : "!"
            let stateLabel = state == "done" ? "done" : state == "failed" ? "failed" : "needs a person"
            let tone = state == "done" ? "done" : state == "failed" ? "blocked" : "human"
            timelineNoteRow(mark: mark, tone: tone, at: at) {
                (Text("Step \(position) \(stateLabel)") + Text(text.map { " · \($0)" } ?? "").foregroundStyle(theme.palette.text))
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }

        case .subagentGroup(_, _, _, let items):
            VStack(alignment: .leading, spacing: 8) {
                if items.count > 1 {
                    Text("Delegated to \(items.count) sub-agents")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                ForEach(items) { sub in
                    subagentCard(sub)
                }
            }
            .padding(.vertical, 4)

        case .gate(_, _, let at, let gate, let text):
            timelineNoteRow(mark: "\u{25C6}", tone: "human", at: at) {
                (Text(gate.label) + Text(text.isEmpty ? "" : " · \(text)").foregroundStyle(theme.palette.text))
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }

        case .error(_, let turn, let at, let text, _):
            Button {
                onOpenTurn(turn)
            } label: {
                timelineNoteRow(mark: "!", tone: "blocked", at: at) {
                    Text(text)
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func turnHeaderView(turn: Int, summary: String, tools: [RunThreadLogic.PairedToolCall]) -> some View {
        let open = expandedTurns.contains(turn)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if tools.isEmpty {
                        onOpenTurn(turn)
                    } else if open {
                        expandedTurns.remove(turn)
                    } else {
                        expandedTurns.insert(turn)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Turn \(turn)")
                            .fontWeight(.medium)
                        if !tools.isEmpty {
                            Text("· \(tools.count) tool call\(tools.count == 1 ? "" : "s")")
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                        } else if summary != "Turn \(turn)" {
                            Text("· \(summary)")
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.palette.surface.opacity(0.75), in: Capsule())
                    .overlay(Capsule().stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border)))
                }
                .buttonStyle(.plain)

                if !tools.isEmpty {
                    Button("Trace \u{2197}") {
                        onOpenTurn(turn)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: theme.pointSize(.micro) + 1))
                }
                Spacer()
            }
            if open && !tools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools) { pair in
                        RunToolCallCard(
                            pair: pair,
                            isOpen: expandedTools.contains(pair.id),
                            onToggle: {
                                if expandedTools.contains(pair.id) {
                                    expandedTools.remove(pair.id)
                                } else {
                                    expandedTools.insert(pair.id)
                                }
                            }
                        )
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(.top, 6)
    }

    private func timelineNoteRow<Content: View>(
        mark: String,
        tone: String,
        at: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let fg: Color = switch tone {
        case "blocked": theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case "human": theme.swiftUIColor("pill-human-fg", fallback: .orange)
        case "done": theme.swiftUIColor("state-done", fallback: .green)
        default: theme.palette.secondaryText
        }
        let bg: Color = switch tone {
        case "blocked": theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.15))
        case "human": theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.15))
        case "done": Color.clear
        default: theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)
        }
        return HStack(alignment: .top, spacing: 10) {
            Text(mark)
                .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold, design: .monospaced))
                .foregroundStyle(fg)
                .frame(minWidth: 20, minHeight: 20)
                .background(bg, in: RoundedRectangle(cornerRadius: 4))
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(RunsLogic.clockTime(at))
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
        }
        .padding(.vertical, 3)
    }

    private func subagentCard(_ sub: RunThreadLogic.SubagentInvocation) -> some View {
        let child = sub.child
        return HStack(alignment: .top, spacing: 12) {
            if let child {
                WorkPersonaAvatarView(agent: child.agent, size: 28, state: RunsLogic.characterState(for: child), active: RunsLogic.isLive(child))
            } else {
                Circle()
                    .fill(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(child?.agent.name ?? sub.agentHandle)
                        .font(.system(size: theme.pointSize(.body), weight: .medium))
                        .foregroundStyle(theme.palette.text)
                    Text("sub-run")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                    if let child {
                        let badge = RunsLogic.statusBadge(for: child)
                        TonePill(label: badge.label, tone: badge.tone)
                    }
                }
                if !sub.task.isEmpty {
                    Text(sub.task)
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(RunsLogic.clockTime(sub.at))
                    if let child {
                        Text("· \(child.model)")
                        Text("· \(APIDate.duration(since: child.startedAt, until: child.endedAt, now: now))")
                        Text("· \(WorkLogic.runCost(child.costUsd, source: child.costSource))")
                    }
                }
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(theme.palette.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let child {
                Button("Open run \u{2197}") {
                    context.navigate("/runs/\(child.id)")
                }
                .buttonStyle(.link)
                .font(.system(size: theme.pointSize(.small)))
            }
        }
        .padding(12)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    // MARK: - Question & Next Line

    private var questionCallout: some View {
        let fallbackSummary = needsItems.first(where: { $0.runId == run.id && $0.kind == .question })?.summary
        let question = thread.latestQuestion ?? (fallbackSummary?.isEmpty == false ? fallbackSummary : nil)
        let humanFG = theme.swiftUIColor("pill-human-fg", fallback: .orange)
        let humanBG = theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.12))
        let border = theme.swiftUIColor("state-human", fallback: .orange).opacity(0.5)

        return VStack(alignment: .leading, spacing: 6) {
            Text("\(run.agent.name) is waiting for your reply")
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(humanFG)
            if let question {
                MarkdownView(markdown: question, textStyle: .reading, textColor: "text-2", chat: true)
            }
            Text("Answer in the box below.")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.tertiaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(humanBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(border))
    }

    private func nextLineButton(_ next: API.InboxItem) -> some View {
        let kind = InboxLogic.kind(next.kind.rawValue)
        let href = RunsLogic.itemHref(next)
        return HStack(spacing: 8) {
            Text("NEXT")
                .font(.system(size: theme.pointSize(.micro) + 1, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.palette.tertiaryText)
            Button {
                if InboxLogic.isExternalHref(href) {
                    context.openExternal(href)
                } else {
                    context.navigate(href)
                }
            } label: {
                Text("\(kind.label) · \(next.title)\(next.agent.map { " · \($0.name)" } ?? "")")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Composer Bar

    private var composerBar: some View {
        let trimmed = composerBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let didSend = sentAtSeq == thread.lastEventSeq
        return VStack(alignment: .leading, spacing: 6) {
            if let composerError {
                Text(composerError)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
            if didSend {
                HStack {
                    Text(asking ? "Sent. Resuming \(run.agent.name)…" : "Sent to \(run.agent.name) as a comment on \(run.ticketKey).")
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                    Spacer()
                    Button("Write another") { sentAtSeq = nil }
                        .buttonStyle(.vesper(.outline))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
            } else {
                HStack(spacing: 6) {
                    Text("To")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                    HStack(spacing: 6) {
                        WorkPersonaAvatarView(agent: run.agent, size: 18)
                        Text(run.ticketKey.isEmpty ? run.agent.name : "\(run.agent.name) · \(run.ticketKey)")
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .foregroundStyle(theme.palette.text)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if composerBody.isEmpty {
                            Text(asking ? "Reply to \(run.agent.name)…" : "Follow up with \(run.agent.name)…")
                                .vesperText(.body, theme)
                                .foregroundStyle(theme.palette.tertiaryText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $composerBody)
                            .scrollContentBackground(.hidden)
                            .focused($composerFocused)
                            .vesperText(.body, theme)
                            .frame(minHeight: 38, maxHeight: 110)
                            .padding(3)
                            .onKeyPress(.return, phases: .down) { press in
                                if press.modifiers.contains(.command) || !press.modifiers.contains(.shift) {
                                    submitReply()
                                    return .handled
                                }
                                return .ignored
                            }
                    }
                    Button(composerSending ? "Sending…" : "Send") {
                        submitReply()
                    }
                    .buttonStyle(.vesper(asking ? .approve : .primary))
                    .disabled(trimmed.isEmpty || composerSending)
                }
                .padding(8)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(asking ? theme.swiftUIColor("state-human", fallback: .orange).opacity(0.6) : theme.palette.border)
                )
            }
            Text(asking
                 ? "Your reply resumes the run."
                 : "Goes to \(run.agent.name) as a comment on \(run.ticketKey); it reads it on its next look at the ticket.")
                .font(.system(size: theme.pointSize(.micro) + 1))
                .foregroundStyle(theme.palette.tertiaryText)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider() }
    }

    private func submitReply() {
        guard !composerSending,
              let request = RunsLogic.replyCommentRequest(
                  ticketKey: run.ticketKey,
                  agentHandle: run.agent.handle,
                  body: composerBody
              ) else { return }
        composerSending = true
        composerError = nil
        let targetSeq = thread.lastEventSeq
        Task {
            do {
                _ = try await context.store.mutate(request, invalidating: RunsLogic.runMutationInvalidation)
                composerBody = ""
                sentAtSeq = targetSeq
                composerSending = false
                onRefresh()
            } catch {
                composerSending = false
                composerError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Shared Tool Call Card & Action Box

struct RunToolCallCard: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let pair: RunThreadLogic.PairedToolCall
    let isOpen: Bool
    let onToggle: () -> Void
    var rawJSON: String? = nil

    @State private var showJSON = false

    var body: some View {
        let sunken = theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface)
        let border: Color = pair.isFailed
            ? theme.swiftUIColor("pill-blocked-bg", fallback: .red)
            : isOpen ? theme.palette.border : theme.swiftUIColor("border-subtle", fallback: theme.palette.border)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.palette.tertiaryText)
                            .frame(width: 12)
                        Text(pair.toolName)
                            .font(.system(size: theme.pointSize(.micro) + 1, weight: .medium, design: .monospaced))
                            .foregroundStyle(
                                pair.isFailed ? theme.swiftUIColor("pill-blocked-fg", fallback: .red)
                                : isOpen ? theme.palette.accent : theme.palette.text
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                pair.isFailed ? theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.15))
                                : isOpen ? theme.palette.accent.opacity(0.12) : sunken,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        if !pair.argSummary.isEmpty {
                            Text(pair.argSummary)
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(theme.palette.secondaryText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let link = pair.link {
                    Button("Open \(link.label) \u{2197}") { context.navigate(link.href) }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.small)))
                }
                if let child = pair.delegatedChild {
                    Button("\(child.agent.name) run \u{2197}") { context.navigate("/runs/\(child.id)") }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.small)))
                }
                if pair.isDenied {
                    TonePill(label: "denied by harness", tone: "blocked")
                } else if pair.isError {
                    TonePill(label: pair.exitCode.map { "error · exit \($0)" } ?? "error", tone: "blocked")
                } else if pair.result != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                        if let ms = pair.durationMs, ms >= 1000 {
                            Text("\(Int((Double(ms) / 1000.0).rounded()))s")
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                .foregroundStyle(theme.palette.tertiaryText)
                        }
                    }
                } else {
                    Text("running…")
                        .font(.system(size: theme.pointSize(.micro) + 1))
                        .foregroundStyle(theme.palette.tertiaryText)
                }

                Text(RunsLogic.clockTime(pair.call.at))
                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                    .foregroundStyle(theme.palette.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if isOpen {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if !pair.output.isEmpty {
                        ScrollView {
                            Text(pair.output)
                                .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                                .foregroundStyle(theme.palette.secondaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 240)
                    } else {
                        Text(pair.result != nil ? "No output." : "No result yet.")
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.palette.tertiaryText)
                    }
                    if let rawJSON {
                        HStack(spacing: 10) {
                            Button(showJSON ? "Hide payload JSON" : "Show payload JSON") {
                                showJSON.toggle()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: theme.pointSize(.micro) + 1))
                            Button("Copy JSON") {
                                context.copyToClipboard(rawJSON)
                                context.showToast(ToastItemModel(id: "trace.copy.\(pair.id)", title: "Copied event JSON", tone: .success))
                            }
                            .buttonStyle(.link)
                            .font(.system(size: theme.pointSize(.micro) + 1))
                        }
                        if showJSON {
                            ScrollView {
                                Text(rawJSON)
                                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                            .padding(8)
                            .background(theme.palette.background, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sunken)
            }
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(border))
    }
}

struct RunActionBoxView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let detail: API.RunDetail
    let lastEventSeq: Int
    var inThread: Bool = false
    let onRefresh: () -> Void

    @State private var controlBusy = false
    @State private var controlError: String?
    @State private var confirmCancel = false
    @State private var decidedIDs: Set<String> = []
    @State private var approvalBusy = false
    @State private var approvalError: String?
    @State private var denyOpen = false
    @State private var denyNote = ""
    @State private var previewExpanded = false
    @State private var confirmApproveAll = false

    private var run: API.Run { detail.run }
    private var pendingApprovals: [API.Approval] {
        detail.approvals.filter { $0.state == .pending && !decidedIDs.contains($0.id) }
    }
    private var liveChildren: [API.Run] {
        detail.childRuns.filter { RunsLogic.isLive($0) }
    }

    private var showsBox: Bool {
        switch run.state.rawValue {
        case "queued", "paused", "waiting_for_quota":
            return true
        case "waiting":
            if run.waitReason == .humanReply && inThread && run.purpose != .planning && run.purpose != .chat {
                return false
            }
            return true
        default:
            return false
        }
    }

    var body: some View {
        if showsBox {
            let humanBG = theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.12))
            let border = theme.swiftUIColor("state-human", fallback: .orange).opacity(0.5)
            VStack(alignment: .leading, spacing: 10) {
                boxBody
                if let controlError {
                    Text(controlError)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(humanBG.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border))
            .alert("Cancel \(run.agent.name)\u{2019}s run?", isPresented: $confirmCancel) {
                Button("Keep running", role: .cancel) {}
                Button("Cancel run", role: .destructive) { sendControl(.cancel) }
            } message: {
                Text("It stops now and can\u{2019}t be resumed.")
            }
            .alert("Approve all \(pendingApprovals.count) requests from \(run.agent.name)?", isPresented: $confirmApproveAll) {
                Button("Cancel", role: .cancel) {}
                Button("Approve all") { approveAllPending() }
            } message: {
                Text("Each one is approved for this run only.")
            }
        }
    }

    @ViewBuilder
    private var boxBody: some View {
        switch run.state.rawValue {
        case "queued":
            HStack(spacing: 12) {
                Text("Waiting for a runner slot. It starts when one is free.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.text)
                Spacer()
                cancelButton
            }

        case "paused":
            HStack(spacing: 12) {
                (Text("Paused. ").fontWeight(.medium).foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                    + Text("Nothing runs until it is resumed."))
                    .vesperText(.body, theme)
                Spacer()
                Button("Resume") { sendControl(.resume) }
                    .buttonStyle(.vesper(.approve))
                    .disabled(controlBusy)
                cancelButton
            }

        case "waiting_for_quota":
            let at = run.holdUntil.map { RunsLogic.absoluteTime($0) } ?? "soon"
            HStack(spacing: 12) {
                Text(
                    run.holdResetKnown == true
                        ? "Out of provider usage. It resumes after the limit resets at \(at)."
                        : "Out of provider usage. The reset time is unknown, so it tries again at \(at)."
                )
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.text)
                Spacer()
                Button("Try now") { sendControl(.resume) }
                    .buttonStyle(.vesper(.approve))
                    .disabled(controlBusy)
                cancelButton
            }

        case "waiting":
            waitingBody

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var waitingBody: some View {
        switch run.waitReason?.rawValue {
        case "approval":
            if let approval = pendingApprovals.first {
                approvalBody(approval, remainingCount: pendingApprovals.count)
            } else {
                Text("Waiting for an approval decision.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }

        case "human_reply":
            if run.purpose == .planning {
                HStack(spacing: 8) {
                    Text("\(run.agent.name) is waiting for your reply.")
                        .vesperText(.body, theme)
                    Button("Open the plan") { context.navigate(RunsLogic.workHref(for: run) ?? "/plans") }
                        .buttonStyle(.link)
                }
            } else if run.purpose == .chat {
                HStack(spacing: 8) {
                    Text("\(run.agent.name) is waiting for your reply.")
                        .vesperText(.body, theme)
                    Button("Open chat") { context.navigate(RunsLogic.workHref(for: run) ?? "/chat") }
                        .buttonStyle(.link)
                }
            } else {
                Text("\(run.agent.name) is waiting for your reply in the Thread tab.")
                    .vesperText(.body, theme)
            }

        case "mockup_review":
            HStack(spacing: 12) {
                Text("Waiting for a mockup review. The next turn starts when a person reviews it.")
                    .vesperText(.body, theme)
                Spacer()
                if !run.ticketKey.isEmpty {
                    Button("Review mockup") {
                        context.navigate("/tickets/\(MarkdownSource.encodeURIComponent(run.ticketKey))")
                    }
                    .buttonStyle(.vesper(.primary))
                }
                cancelButton
            }

        case "delegation":
            VStack(alignment: .leading, spacing: 8) {
                Text("Waiting for \(liveChildren.count) sub agent\(liveChildren.count == 1 ? "" : "s")")
                    .font(.system(size: theme.pointSize(.body), weight: .medium))
                ForEach(liveChildren, id: \.id) { child in
                    HStack(spacing: 8) {
                        WorkPersonaAvatarView(agent: child.agent, size: 18, state: RunsLogic.characterState(for: child), active: true)
                        Button("\(child.agent.name) \u{2197}") {
                            context.navigate("/runs/\(child.id)")
                        }
                        .buttonStyle(.link)
                        let badge = RunsLogic.statusBadge(for: child)
                        TonePill(label: badge.label, tone: badge.tone)
                    }
                }
                cancelButton
            }

        default:
            HStack(spacing: 12) {
                Text("Waiting for \(run.agent.name).")
                    .vesperText(.body, theme)
                Spacer()
                cancelButton
            }
        }
    }

    @ViewBuilder
    private func approvalBody(_ approval: API.Approval, remainingCount: Int) -> some View {
        let preview = approval.actionPreview ?? ""
        let lines = preview.components(separatedBy: "\n")
        let isLong = preview.count > 400 || lines.count > 6
        let shownPreview = previewExpanded || !isLong
            ? preview
            : String(lines.prefix(6).joined(separator: "\n").prefix(400))

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(run.agent.name) needs a decision")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                Text(approval.scope)
                    .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 4))
                if remainingCount > 1 {
                    Text("1 of \(remainingCount)")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
            }
            Text(approval.actionSummary)
                .font(.system(size: theme.pointSize(.heading), weight: .medium))
                .foregroundStyle(theme.palette.text)
            if !approval.riskSummary.isEmpty {
                Text(approval.riskSummary)
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }
            if !preview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal) {
                        Text(shownPreview + (isLong && !previewExpanded ? "…" : ""))
                            .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                            .foregroundStyle(theme.palette.text)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.swiftUIColor("border-subtle", fallback: theme.palette.border)))
                    if isLong {
                        Button(previewExpanded ? "less" : "more") {
                            previewExpanded.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: theme.pointSize(.small)))
                    }
                }
            }
            if let approvalError {
                Text(approvalError)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
            if denyOpen {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Why not? (optional, sent to \(run.agent.name))", text: $denyNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    HStack {
                        Spacer()
                        Button("Cancel") { denyOpen = false }
                            .buttonStyle(.vesper(.outline))
                        Button("Deny") { decide(approval, decision: .deny) }
                            .buttonStyle(.vesper(.danger))
                            .disabled(approvalBusy)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Deny…") { denyOpen = true }
                        .buttonStyle(.vesper(.outline))
                        .disabled(approvalBusy)
                    if remainingCount > 1 {
                        Button("Approve all \(remainingCount) for this run") {
                            confirmApproveAll = true
                        }
                        .buttonStyle(.vesper(.approveOutline))
                        .disabled(approvalBusy)
                    }
                    Button(approvalBusy ? "Saving…" : "Approve") {
                        decide(approval, decision: .approve)
                    }
                    .buttonStyle(.vesper(.approve))
                    .disabled(approvalBusy)
                }
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel run") { confirmCancel = true }
            .buttonStyle(.vesper(.danger))
            .disabled(controlBusy)
    }

    private func sendControl(_ action: API.ControlRunAction) {
        guard !controlBusy else { return }
        controlBusy = true
        controlError = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    RunsLogic.controlActionRequest(runId: run.id, action: action),
                    invalidating: RunsLogic.runMutationInvalidation
                )
                controlBusy = false
                onRefresh()
            } catch {
                controlBusy = false
                controlError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func decide(_ approval: API.Approval, decision: API.DecideApprovalDecision) {
        guard !approvalBusy else { return }
        approvalBusy = true
        approvalError = nil
        let request = RunsLogic.approvalDecisionRequest(approvalId: approval.id, decision: decision, note: denyNote)
        Task {
            do {
                _ = try await context.store.mutate(request, invalidating: RunsLogic.runMutationInvalidation)
                decidedIDs.insert(approval.id)
                denyNote = ""
                denyOpen = false
                approvalBusy = false
                onRefresh()
            } catch {
                approvalBusy = false
                approvalError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func approveAllPending() {
        let targets = pendingApprovals
        guard !approvalBusy, targets.count > 1 else { return }
        approvalBusy = true
        approvalError = nil
        Task {
            for item in targets {
                do {
                    let req = RunsLogic.approvalDecisionRequest(approvalId: item.id, decision: .approve, note: nil)
                    _ = try await context.store.mutate(req, invalidating: RunsLogic.runMutationInvalidation)
                    decidedIDs.insert(item.id)
                } catch {
                    approvalError = (error as? APIError)?.userMessage ?? error.localizedDescription
                }
            }
            approvalBusy = false
            onRefresh()
        }
    }
}
