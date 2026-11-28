import SwiftUI
import VesperCore

// MARK: - Live Micro-Indicators & Lightweight Thinking Markdown

/// Calm breathing sonar dot for active steps, running subagents, and live reasoning tails.
/// Respects Reduce Motion and window occlusion via `AnimationPolicy`.
struct ChatPulsingStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowVisible) private var windowVisible

    let color: Color
    var size: CGFloat = 7
    var active: Bool = true

    @State private var pulsing = false

    var body: some View {
        let shouldPulse = active && AnimationPolicy.shouldAnimate(
            working: true,
            context: AppPowerState.shared.animationContext(
                reduceMotion: reduceMotion,
                windowVisible: windowVisible
            )
        )

        ZStack {
            if shouldPulse {
                Circle()
                    .fill(color.opacity(pulsing ? 0 : 0.42))
                    .frame(width: size, height: size)
                    .scaleEffect(pulsing ? 2.2 : 0.9)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulsing)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size + 6, height: size + 6)
        .onAppear {
            if shouldPulse { pulsing = true }
        }
        .onChange(of: shouldPulse) { _, live in
            pulsing = live
        }
        .accessibilityHidden(true)
    }
}

/// Fast, selectable lightweight Markdown renderer for live and finished reasoning blocks.
/// Formats headings, bullets, bold/italic spans, and inline code without spawning full WebViews or TextKit layouts.
struct ChatLightweightMarkdownView: View {
    @Environment(\.vesperTheme) private var theme

    let text: String

    var body: some View {
        let p = theme.palette
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    Spacer(minLength: 2).frame(height: 2)
                } else if let heading = headingText(trimmed) {
                    Text(inlineAttributed(heading))
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let bullet = bulletText(trimmed) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.tertiaryText)
                        Text(inlineAttributed(bullet))
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(inlineAttributed(trimmed))
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingText(_ line: String) -> String? {
        if line.hasPrefix("### ") { return String(line.dropFirst(4)) }
        if line.hasPrefix("## ") { return String(line.dropFirst(3)) }
        if line.hasPrefix("# ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            let inner = String(line.dropFirst(2).dropLast(2))
            if !inner.contains("**") { return inner }
        }
        return nil
    }

    private func bulletText(_ line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private func inlineAttributed(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var parsed = try? AttributedString(markdown: raw, options: options) else {
            return AttributedString(raw)
        }
        let monoFont = Font.system(size: max(10, theme.pointSize(.small) - 0.5), design: .monospaced)
        let codeBg = theme.swiftUIColor("surface-raised", fallback: theme.palette.surface)
        for run in parsed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                parsed[run.range].font = monoFont
                parsed[run.range].backgroundColor = codeBg
            }
        }
        return parsed
    }
}

// MARK: - Live Target Ticker, Narration Banner & Subagent Swimlanes

/// Cross-sliding monospaced pill displaying the concrete file, pattern, command, or URL currently in flight.
private struct ChatTargetTickerView: View {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let kind: ActivitySceneKind
    let target: String
    let tint: Color

    var body: some View {
        let p = theme.palette
        HStack(spacing: 5) {
            Image(systemName: iconForKind(kind))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint.opacity(0.9))
            Text(target)
                .font(.system(size: theme.pointSize(.micro), weight: .medium, design: .monospaced))
                .foregroundStyle(p.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            theme.swiftUIColor("surface-sunken", fallback: p.surface),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(theme.swiftUIColor("border-subtle", fallback: p.border), lineWidth: 1)
        )
        .id(target)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                )
        )
    }

    private func iconForKind(_ kind: ActivitySceneKind) -> String {
        switch kind {
        case .readingCode, .writingCode, .writingReply: "doc.text"
        case .searchingCode: "magnifyingglass"
        case .tests: "checkmark.seal"
        case .build, .install: "hammer"
        case .terminal: "terminal"
        case .web, .webPage: "globe"
        case .wiki: "book"
        case .subagent: "person.2"
        case .commit, .push, .pullRequest, .repoHistory, .github: "arrow.triangle.branch"
        case .image, .imageView: "photo"
        default: "sparkle"
        }
    }
}

/// Inline callout pill for persona decision narrations (`New approach:` / `Surprise:`).
private struct ChatNarrationCalloutView: View {
    @Environment(\.vesperTheme) private var theme

    let narration: ChatDecisionNarration

    var body: some View {
        let p = theme.palette
        let warmColor = theme.swiftUIColor("state-progress", fallback: .orange)
        let tagColor: Color = switch narration.tag {
        case .approach: p.accent
        case .surprise: warmColor
        case nil: p.secondaryText
        }
        let tagLabel: String? = switch narration.tag {
        case .approach: "New approach"
        case .surprise: "Surprise"
        case nil: nil
        }
        let tagIcon: String = switch narration.tag {
        case .approach: "arrow.triangle.branch"
        case .surprise: "sparkles"
        case nil: "quote.opening"
        }

        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let tagLabel {
                HStack(spacing: 3) {
                    Image(systemName: tagIcon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(tagLabel)
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                }
                .foregroundStyle(tagColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tagColor.opacity(0.14), in: Capsule())
            }
            Text(narration.text)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tagColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(tagColor.opacity(0.22), lineWidth: 1)
        )
    }
}

/// Live or finished parallel subagent swimlanes rendered directly inside the working card.
private struct ChatSubagentLanesView: View {
    @Environment(\.vesperTheme) private var theme

    let lanes: [ChatSubagentLane]
    let now: Date?
    let live: Bool

    var body: some View {
        let p = theme.palette
        let runningCount = lanes.filter { $0.state == .running }.count
        let queuedCount = lanes.filter { $0.state == .queued }.count
        let doneCount = lanes.filter { $0.state == .done }.count
        let failedCount = lanes.filter { $0.state == .failed }.count

        let summaryParts: [String] = {
            var parts: [String] = []
            if runningCount > 0 { parts.append("\(runningCount) running") }
            if queuedCount > 0 { parts.append("\(queuedCount) queued") }
            if doneCount > 0 { parts.append("\(doneCount) done") }
            if failedCount > 0 { parts.append("\(failedCount) failed") }
            return parts
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(runningCount > 0 ? p.accent : p.tertiaryText)
                Text("Subagents")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.secondaryText)
                if !summaryParts.isEmpty {
                    Text("· \(summaryParts.joined(separator: " · "))")
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                }
                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(lanes) { lane in
                    subagentLaneRow(lane, palette: p)
                }
            }
        }
    }

    private func subagentLaneRow(_ lane: ChatSubagentLane, palette p: NativePalette) -> some View {
        let doneColor = theme.swiftUIColor("state-done", fallback: .green)
        let failedColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let elapsedMs: Int? = {
            if let dur = lane.durationMs { return dur }
            if lane.state == .running, let start = lane.startedAt, let now {
                return max(0, Int(((now.timeIntervalSince1970 - start) * 1000).rounded()))
            }
            return nil
        }()
        let activityLine: String? = {
            switch lane.state {
            case .queued:
                return "Waiting for worker slot…"
            case .running:
                if let target = lane.currentTarget, !target.isEmpty {
                    if let phrase = lane.currentStatus?.phrase {
                        return "\(phrase) · \(target)"
                    }
                    return target
                }
                return lane.currentStatus?.phrase ?? "Working…"
            case .done:
                if lane.toolCallCount > 0 {
                    return "\(lane.toolCallCount) tool \(lane.toolCallCount == 1 ? "call" : "calls")"
                }
                return "Completed"
            case .failed:
                return lane.error ?? "Failed"
            }
        }()

        return HStack(spacing: 7) {
            Group {
                switch lane.state {
                case .running:
                    ChatPulsingStatusDot(color: p.accent, size: 6, active: live)
                case .queued:
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(p.tertiaryText)
                        .frame(width: 12)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(doneColor)
                        .frame(width: 12)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(failedColor)
                        .frame(width: 12)
                }
            }

            Text(lane.displayName)
                .font(.system(size: theme.pointSize(.small), weight: lane.state == .running ? .medium : .regular))
                .foregroundStyle(lane.state == .failed ? failedColor : (lane.state == .running ? p.text : p.secondaryText))
                .lineLimit(1)

            if let tier = lane.tier, !tier.isEmpty {
                let tierColor = tierTint(tier, palette: p)
                Text(tier)
                    .font(.system(size: max(9, theme.pointSize(.micro) - 0.5), weight: .semibold, design: .monospaced))
                    .foregroundStyle(tierColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tierColor.opacity(0.13), in: Capsule())
            }

            if let activityLine {
                Text(activityLine)
                    .font(.system(size: theme.pointSize(.micro), design: lane.state == .running && lane.currentTarget != nil ? .monospaced : .default))
                    .foregroundStyle(lane.state == .failed ? failedColor.opacity(0.85) : p.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if let elapsedMs, elapsedMs >= 1000 {
                Text(ChatTurnActivity.formatSpan(ms: elapsedMs))
                    .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(p.tertiaryText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            lane.state == .running
                ? p.accent.opacity(0.06)
                : theme.swiftUIColor("surface-sunken", fallback: p.surface).opacity(0.6),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func tierTint(_ tier: String, palette p: NativePalette) -> Color {
        switch tier.lowercased() {
        case "fast": theme.swiftUIColor("state-done", fallback: p.secondaryText)
        case "deep": theme.swiftUIColor("state-progress", fallback: .orange)
        default: p.accent
        }
    }
}

// MARK: - Finished Working Card in History

/// What the live working card leaves behind in chat history once a turn finishes (or stops/fails):
/// a compact one-line strip ("Worked for 2m 14s · Thought for 32s · 7 steps") that expands in place to show the
/// turn's steps and any subagent lanes, plus an inline collapsible thinking disclosure block when `showLiveThinking` is on.
struct ChatTurnStepsCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let runId: String
    let outcome: ChatTurnOutcome
    let since: String?
    let until: String?
    let end: TimeInterval?
    var morphId: String? = nil
    var morphNamespace: Namespace.ID? = nil

    var body: some View {
        let events = context.store.entry(API.listRunEvents(id: runId)).data?.events ?? []
        let turn = ChatTurnActivity.finishedTurn(
            events: events.map(ChatRunEvent.init),
            outcome: outcome,
            since: since,
            until: until,
            end: end
        )
        let showThinking = showLiveThinking && !turn.thinkingBlocks.isEmpty
        if showThinking || !turn.steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if showThinking {
                    ChatFinishedThinkingDisclosureView(
                        blocks: turn.thinkingBlocks,
                        thinkingDurationMs: turn.thinkingDurationMs
                    )
                }
                if !turn.steps.isEmpty {
                    let card = ChatFinishedTurnCardView(turn: turn, outcome: outcome)
                    if let morphId, let morphNamespace {
                        card.matchedGeometryEffect(id: morphId, in: morphNamespace, isSource: false)
                    } else {
                        card
                    }
                }
            }
        }
    }
}

/// Renders a finished working card with persona identity for turns that ended without a reply
/// (failed or stopped/interrupted). Renders nothing if the turn did no tool work and has no visible thinking.
struct ChatEndedTurnSectionView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let runId: String
    let ended: ChatEndedTurn
    let personaId: String?
    let speakerName: String

    var body: some View {
        let events = context.store.entry(API.listRunEvents(id: runId)).data?.events ?? []
        let turn = ChatTurnActivity.finishedTurn(
            events: events.map(ChatRunEvent.init),
            outcome: ended.outcome,
            since: ended.since,
            until: ended.until,
            end: ended.end
        )
        let showThinking = showLiveThinking && !turn.thinkingBlocks.isEmpty

        if showThinking || !turn.steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    WorkPersonaAvatarView(
                        id: personaId,
                        handle: nil,
                        name: speakerName,
                        size: 24,
                        preferCharacter: true
                    )
                    Text(speakerName)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(theme.palette.text)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if showThinking {
                        ChatFinishedThinkingDisclosureView(
                            blocks: turn.thinkingBlocks,
                            thinkingDurationMs: turn.thinkingDurationMs
                        )
                    }
                    if !turn.steps.isEmpty {
                        ChatFinishedTurnCardView(turn: turn, outcome: ended.outcome)
                    }
                }
                .padding(.leading, 32)
            }
        }
    }
}

/// Clean collapsible disclosure block for a finished turn's reasoning blocks when `showLiveThinking` is on.
struct ChatFinishedThinkingDisclosureView: View {
    @Environment(\.vesperTheme) private var theme

    let blocks: [ChatThinkingBlock]
    let thinkingDurationMs: Int?

    @State private var isExpanded = false

    var body: some View {
        let p = theme.palette
        let title: String = {
            if let ms = thinkingDurationMs, ms >= 1000 {
                return "Thought for \(ChatTurnActivity.formatSpan(ms: ms))"
            }
            return "Thinking"
        }()

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .imageScale(.small)
                        .foregroundStyle(p.tertiaryText)
                    Text(title)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(p.secondaryText)
                        .lineLimit(1)
                    if blocks.count > 1 {
                        Text("· \(blocks.count) blocks")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Hide" : "Show")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                            if idx > 0 {
                                Divider()
                            }
                            ChatLightweightMarkdownView(text: block.text)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
    }
}

/// Live inline reasoning teleprompter shown under the running turn when `showLiveThinking` is enabled.
struct ChatLiveThinkingStreamView: View {
    @Environment(\.vesperTheme) private var theme

    let blocks: [ChatThinkingBlock]
    let activeDetail: String?
    let isActivelyThinking: Bool
    let thinkingDurationMs: Int

    @State private var isExpanded = true

    var body: some View {
        let p = theme.palette
        let headerTitle = isActivelyThinking ? "Thinking…" : "Thought"

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .imageScale(.small)
                        .foregroundStyle(isActivelyThinking ? p.accent : p.tertiaryText)
                    Text(headerTitle)
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(isActivelyThinking ? p.text : p.secondaryText)
                    if thinkingDurationMs >= 1000 {
                        Text(ChatTurnActivity.formatSpan(ms: thinkingDurationMs))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(p.tertiaryText)
                    }
                    if !isExpanded, let activeDetail, !activeDetail.isEmpty {
                        Text("· \(activeDetail)")
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
                                if idx > 0 {
                                    Divider()
                                }
                                ChatLightweightMarkdownView(text: block.text)
                            }
                            if isActivelyThinking {
                                HStack(spacing: 6) {
                                    ChatPulsingStatusDot(color: p.accent, size: 5, active: true)
                                    Text(activeDetail?.isEmpty == false ? activeDetail! : "Reasoning…")
                                        .font(.system(size: theme.pointSize(.small)))
                                        .italic()
                                        .foregroundStyle(p.tertiaryText)
                                        .lineLimit(2)
                                }
                                .id("live-thinking-tail")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, blocks.count > 1 ? 14 : 8)
                        .padding(.bottom, 10)
                    }
                    .frame(maxHeight: 196)
                    // Soft top-edge teleprompter fade when reasoning history scrolls upward.
                    .mask {
                        if blocks.isEmpty {
                            Color.black
                        } else {
                            VStack(spacing: 0) {
                                LinearGradient(
                                    colors: [.clear, .black],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 18)
                                Color.black
                            }
                        }
                    }
                    .onChange(of: blocks.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            if isActivelyThinking {
                                proxy.scrollTo("live-thinking-tail", anchor: .bottom)
                            } else if let last = blocks.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface).opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActivelyThinking ? p.accent.opacity(0.35) : p.border)
        )
    }
}

struct ChatFinishedTurnCardView: View {
    @Environment(\.vesperTheme) private var theme

    let turn: ChatFinishedTurn
    let outcome: ChatTurnOutcome

    @State private var isExpanded: Bool
    @State private var showAllEarlier = false

    init(turn: ChatFinishedTurn, outcome: ChatTurnOutcome) {
        self.turn = turn
        self.outcome = outcome
        self._isExpanded = State(initialValue: outcome == .failed)
    }

    var body: some View {
        let p = theme.palette
        let failureFold = outcome == .failed && !showAllEarlier
            ? ChatTurnActivity.foldStepsFromFailure(turn.steps)
            : (earlier: 0, shown: turn.steps)
        let summary = ChatTurnActivity.finishedSummary(
            outcome: outcome,
            stepCount: turn.steps.count,
            durationMs: turn.durationMs,
            thinkingDurationMs: turn.thinkingDurationMs
        )

        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: outcomeIcon)
                            .imageScale(.small)
                            .foregroundStyle(outcomeColor(palette: p))
                        Text(summary)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                        if !turn.subagents.isEmpty {
                            Text("· \(turn.subagents.count) \(turn.subagents.count == 1 ? "worker" : "workers")")
                                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Hide steps" : "Show steps")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            if failureFold.earlier > 0 {
                                Button("Show \(failureFold.earlier) earlier step\(failureFold.earlier == 1 ? "" : "s")") {
                                    showAllEarlier = true
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.accent)
                            }
                            ForEach(failureFold.shown, id: \.key) { step in
                                ChatTurnStepRowView(step: step, live: false)
                            }
                        }

                        if !turn.subagents.isEmpty {
                            Divider()
                            ChatSubagentLanesView(lanes: turn.subagents, now: nil, live: false)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(outcome == .failed ? theme.swiftUIColor("pill-blocked-fg", fallback: .red).opacity(0.4) : p.border)
            )

            if outcome == .stopped {
                Text("Stopped before it replied.")
                    .font(.system(size: theme.pointSize(.micro)))
                    .italic()
                    .foregroundStyle(p.tertiaryText)
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

    private func outcomeColor(palette p: NativePalette) -> Color {
        switch outcome {
        case .done: theme.swiftUIColor("state-done", fallback: .green)
        case .failed: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .stopped: p.tertiaryText
        }
    }
}

struct ChatTurnStepRowView: View {
    @Environment(\.vesperTheme) private var theme

    let step: ChatTurnStep
    var live: Bool = true

    var body: some View {
        let p = theme.palette
        let doneColor = theme.swiftUIColor("state-done", fallback: .green)
        let failedColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let warmColor = theme.swiftUIColor("state-progress", fallback: .orange)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Group {
                    if step.state == .active && live {
                        ChatPulsingStatusDot(color: p.accent, size: 6, active: true)
                            .frame(width: 14)
                    } else {
                        Image(systemName: stepIcon(step.state))
                            .imageScale(.small)
                            .foregroundStyle(stepColor(step.state, palette: p, doneColor: doneColor, failedColor: failedColor))
                            .frame(width: 14)
                    }
                }
                Text(step.title)
                    .font(.system(size: theme.pointSize(.small), weight: step.state == .active ? .medium : .regular))
                    .foregroundStyle(step.state == .planned ? p.tertiaryText : (step.state == .active ? p.text : p.secondaryText))
                    .lineLimit(1)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if step.state != .active, let started = step.startedAt, let ended = step.endedAt {
                    let ms = Int((ended - started) * 1000)
                    if ms >= 1000 {
                        Spacer(minLength: 6)
                        Text(ChatTurnActivity.formatSpan(ms: ms))
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(p.tertiaryText)
                    }
                }
            }

            if let intent = step.intent, !intent.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let tag = step.tag {
                        let color = tag == .approach ? p.accent : warmColor
                        Text(tag == .approach ? "New approach" : "Surprise")
                            .font(.system(size: max(9, theme.pointSize(.micro) - 0.5), weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(color.opacity(0.14), in: Capsule())
                    }
                    Text(intent)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(2)
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

    private func stepColor(_ state: ChatStepState, palette p: NativePalette, doneColor: Color, failedColor: Color) -> Color {
        switch state {
        case .done: doneColor
        case .active: p.accent
        case .failed: failedColor
        case .planned: p.tertiaryText
        }
    }
}

// MARK: - Isolated Live Work / Thinking Cockpit Card

/// Redesigned live working visualization card:
/// - Message-row-aligned persona header (24pt animated character in the reply avatar lane + phase pill + 1s timer)
/// - Single unified glass-cockpit container with a flush 60fps lit mini-diorama stage on the left
/// - Concrete monospaced target ticker, decision narration banners (`New approach:` / `Surprise:`),
///   live parallel subagent swimlanes, smart plan deduplication, and lightweight Markdown thinking teleprompter
/// - Driven by SSE `run.events` invalidation with a 1s local clock tick and 8s fallback safety refetch
struct ChatLiveActivityCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let chatId: String
    let runId: String?
    let since: String?
    let waitingForMessages: Bool
    let speaker: API.PersonaSummary?
    var personas: [API.Persona] = []
    let fallbackSpeakerName: String
    var isStopping: Bool = false
    var hasPinnedPlanBar: Bool = false
    var morphId: String? = nil
    var morphNamespace: Namespace.ID? = nil

    @State private var watchedKey: QueryKey?
    @State private var now = Date()
    @State private var showAllSteps = false

    /// Fallback refetch interval when SSE `run.events` has been quiet; normal updates arrive immediately via SSE.
    private static let sseFallbackStaleSeconds: TimeInterval = 8.0

    private var runEventsRequest: APIRequest<API.RunEventList>? {
        guard let runId, !runId.isEmpty else { return nil }
        return ChatTurnActivity.liveEventsRequest(runId: runId, since: since)
    }

    var body: some View {
        let p = theme.palette
        let entry = runEventsRequest.map { context.store.entry($0) }
        let events = waitingForMessages ? [] : (entry?.data?.events ?? [])
        let activity = ChatTurnActivity.fold(events: events.map(ChatRunEvent.init), since: since, now: now)
        let speakerName = speaker?.name ?? fallbackSpeakerName
        let folded = ChatTurnActivity.foldSteps(activity.steps)
        let displaySteps = showAllSteps ? activity.steps : folded.shown
        // Observed by `ChatTranscriptProposalsSlot`; the API lists only pending approvals.
        let awaiting = !(context.store.entry(API.listChatToolApprovals(id: chatId)).data?.approvals.isEmpty ?? true)
        let characterState = CharacterState.forActivity(activity.status.kind, awaiting: awaiting)
        let liveTimerMs = activity.phaseElapsedMs ?? activity.elapsedMs
        let stageTint = resolvedStageTint(
            activity: activity,
            awaiting: awaiting,
            palette: p
        )
        let phaseBadge = resolvedPhaseBadge(activity: activity, awaiting: awaiting)
        let secondaryTimingLine: String? = {
            var parts: [String] = []
            if let total = activity.elapsedMs, let phase = activity.phaseElapsedMs, total - phase >= 1000 {
                parts.append("Total \(ChatTurnActivity.formatSpan(ms: total))")
            }
            if activity.thinkingDurationMs >= 1000 {
                let isSameAsLiveTimer = activity.timingPhase == .thinking
                    && activity.phaseElapsedMs.map { abs(activity.thinkingDurationMs - $0) < 1000 } == true
                if !isSameAsLiveTimer {
                    parts.append("Thought \(ChatTurnActivity.formatSpan(ms: activity.thinkingDurationMs))")
                }
            }
            if activity.toolCallCount > 0 {
                parts.append("\(activity.toolCallCount) \(activity.toolCallCount == 1 ? "tool" : "tools")")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        let activeThinkingDetail: String? = {
            if case .thinking(let detail) = activity.activePhase { return detail }
            return nil
        }()
        let shouldShowLiveThinking = showLiveThinking && (!activity.thinkingBlocks.isEmpty || activity.timingPhase == .thinking)
        let deduplicatePlanSteps = activity.planned && hasPinnedPlanBar
        let activePlanStep = deduplicatePlanSteps ? activity.steps.first(where: { $0.state == .active }) : nil

        VStack(alignment: .leading, spacing: 8) {
            // Message-row aligned persona identity header (24pt avatar matches ChatMessageRowView)
            HStack(spacing: 8) {
                WorkPersonaAvatarView(
                    id: speaker?.id,
                    handle: nil,
                    name: speakerName,
                    size: 24,
                    state: characterState,
                    active: !isStopping,
                    preferCharacter: true
                )
                Text(speakerName)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    ChatPulsingStatusDot(color: stageTint, size: 5, active: !isStopping)
                    Text(phaseBadge)
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(stageTint)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(stageTint.opacity(0.12), in: Capsule())

                if let liveTimerMs {
                    Text(ChatTurnActivity.formatSpan(ms: liveTimerMs))
                        .font(.system(size: theme.pointSize(.small), weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(p.secondaryText)
                }

                Spacer(minLength: 8)

                if let secondaryTimingLine {
                    Text(secondaryTimingLine)
                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(p.tertiaryText)
                        .lineLimit(1)
                }
            }

            // Indented to align cleanly with assistant reply content & finished turn strip
            VStack(alignment: .leading, spacing: 8) {
                let cockpitCard = VStack(alignment: .leading, spacing: 0) {
                    // Main Diorama + Telemetry Split (adapts cleanly to narrow Docked Chat widths)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 0) {
                            ActivitySceneView(
                                kind: activity.status.kind,
                                stopping: isStopping,
                                width: 136,
                                height: 76,
                                stageStyle: .diorama(tint: stageTint, ambientPulse: !isStopping)
                            )
                            Rectangle()
                                .fill(theme.swiftUIColor("border-subtle", fallback: p.border))
                                .frame(width: 1)
                            telemetryPane(activity: activity, stageTint: stageTint, palette: p)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 0) {
                            ActivitySceneView(
                                kind: activity.status.kind,
                                stopping: isStopping,
                                width: 180,
                                height: 60,
                                stageStyle: .diorama(tint: stageTint, ambientPulse: !isStopping)
                            )
                            .frame(maxWidth: .infinity)
                            Divider()
                            telemetryPane(activity: activity, stageTint: stageTint, palette: p)
                        }
                    }

                    // Inline parallel subagent swimlanes
                    if !activity.subagents.isEmpty {
                        Divider()
                        ChatSubagentLanesView(lanes: activity.subagents, now: now, live: !isStopping)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }

                    // Smart plan deduplication vs. planless step rail
                    if deduplicatePlanSteps {
                        if let activePlanStep {
                            Divider()
                            HStack(spacing: 6) {
                                ChatPulsingStatusDot(color: stageTint, size: 5, active: !isStopping)
                                Text("Current plan step:")
                                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                                    .foregroundStyle(p.tertiaryText)
                                Text(activePlanStep.title)
                                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                                    .foregroundStyle(p.secondaryText)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                    } else if !displaySteps.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            if !showAllSteps && folded.earlier > 0 {
                                Button("Show \(folded.earlier) earlier step\(folded.earlier == 1 ? "" : "s")") {
                                    showAllSteps = true
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.accent)
                            }
                            ForEach(displaySteps, id: \.key) { step in
                                ChatTurnStepRowView(step: step, live: !isStopping)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                }
                .background(
                    theme.swiftUIColor("surface-raised", fallback: p.surface),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isStopping
                                ? p.border
                                : stageTint.opacity(theme.mode == .dark ? 0.32 : 0.24),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: (isStopping ? Color.clear : stageTint.opacity(theme.mode == .dark ? 0.10 : 0.06)),
                    radius: 10,
                    y: 2
                )

                if let morphId, let morphNamespace {
                    cockpitCard.matchedGeometryEffect(id: morphId, in: morphNamespace, isSource: true)
                } else {
                    cockpitCard
                }

                if shouldShowLiveThinking {
                    ChatLiveThinkingStreamView(
                        blocks: activity.thinkingBlocks,
                        activeDetail: activeThinkingDetail,
                        isActivelyThinking: activity.timingPhase == .thinking && !isStopping,
                        thinkingDurationMs: activity.thinkingDurationMs
                    )
                }
            }
            .padding(.leading, 32)
        }
        // The chat's persona companion acts out what this card shows, and idles once it's gone.
        .onChange(of: characterState, initial: true) { _, next in
            ChatCompanions.companion(for: chatId).work = next
        }
        .onDisappear { ChatCompanions.companion(for: chatId).work = nil }
        .onChange(of: since) { _, _ in
            showAllSteps = false
            now = Date()
        }
        .task(id: "\(runId ?? "")|\(since ?? "")") {
            watchRunEvents()
            await tickClockAndFallbackRefresh()
        }
        .onDisappear {
            if let watchedKey {
                context.store.stopObserving(watchedKey)
                self.watchedKey = nil
            }
        }
    }

    private func telemetryPane(
        activity: ChatTurnActivity,
        stageTint: Color,
        palette p: NativePalette
    ) -> some View {
        let headline: String = {
            if isStopping { return "Stopping turn…" }
            let raw = activity.status.phrase
            guard !raw.isEmpty else { return "Working on it…" }
            return raw.prefix(1).uppercased() + raw.dropFirst() + "…"
        }()

        return VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                .foregroundStyle(isStopping ? p.secondaryText : p.text)
                .lineLimit(1)

            if !isStopping, let target = activity.activeTarget, !target.isEmpty {
                ChatTargetTickerView(kind: activity.status.kind, target: target, tint: stageTint)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: target)
            }

            if let opening = activity.openingLine, !opening.isEmpty {
                Text(opening)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let narration = activity.latestNarration {
                ChatNarrationCalloutView(narration: narration)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if activity.quiet && !isStopping {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Still working — no new events for a bit.")
                        .font(.system(size: theme.pointSize(.micro), weight: .medium))
                }
                .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resolvedStageTint(
        activity: ChatTurnActivity,
        awaiting: Bool,
        palette p: NativePalette
    ) -> Color {
        if isStopping { return p.tertiaryText }
        if awaiting || activity.quiet {
            return theme.swiftUIColor("state-human", fallback: theme.swiftUIColor("state-progress", fallback: .orange))
        }
        switch activity.status.kind {
        case .tests, .build:
            return theme.swiftUIColor("state-done", fallback: p.accent)
        default:
            break
        }
        if let speakerId = speaker?.id,
           let matched = personas.first(where: { $0.id == speakerId }),
           let hex = Color(cssHex: matched.color) {
            return hex
        }
        return p.accent
    }

    private func resolvedPhaseBadge(activity: ChatTurnActivity, awaiting: Bool) -> String {
        if isStopping { return "Stopping" }
        if awaiting { return "Needs you" }
        switch activity.timingPhase {
        case .thinking: return "Thinking"
        case .tool: return "Working"
        case .writingReply: return "Drafting"
        }
    }

    private func watchRunEvents() {
        if let watchedKey {
            context.store.stopObserving(watchedKey)
            self.watchedKey = nil
        }
        guard let req = runEventsRequest else { return }
        context.store.observe(req)
        context.store.load(req)
        watchedKey = req.key
    }

    /// Ticks the local 1s timer smoothly while relying on SSE `run.events` invalidation for live data;
    /// only triggers a safety refetch if no SSE-driven update landed in the last 8 seconds.
    private func tickClockAndFallbackRefresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let current = Date()
            now = current
            if let req = runEventsRequest {
                let updatedAt = context.store.entry(req).updatedAt
                let isStale = updatedAt.map { current.timeIntervalSince($0) >= Self.sseFallbackStaleSeconds } ?? true
                if isStale {
                    _ = await context.store.refetch(req)
                }
            }
        }
    }
}
