import SwiftUI
import VesperCore

/// Compact header pill showing live context window usage and a popover for 1-click compaction
/// and per-chat auto-rollover threshold controls.
struct ChatContextMeterView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let session: API.ChatSession
    var messages: [API.ChatMessage] = []
    let pinnedCount: Int
    let onCompact: @MainActor (String?) async -> String?

    @State private var open = false
    @State private var focus = ""
    @State private var compacting = false
    @State private var updatingThreshold = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let state = ChatContextMeterLogic.state(
            contextTokens: session.contextTokens,
            effectiveLimit: session.effectiveAutoRolloverTokens
        )
        let isRunning = session.state == .running
        let barColor: Color = switch state.tone {
        case .danger: theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        case .warning: theme.swiftUIColor("state-human", fallback: .orange)
        case .neutral: p.accent
        }

        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                if state.limit > 0 {
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.border)
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(state.tokens > 0 ? 3 : 0, 32 * state.ratio))
                    }
                    .frame(width: 32, height: 5)
                }
                Text(session.compactPending == true ? "Compacted" : state.label)
                    .font(.system(size: theme.pointSize(.micro), weight: .medium, design: .monospaced))
                    .foregroundStyle(state.tone == .neutral ? p.secondaryText : barColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().stroke(state.tone == .neutral ? p.border : barColor.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("Context window: \(state.label)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Context window")
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    Spacer()
                    Text(state.label)
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(p.secondaryText)
                }

                if state.limit > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.swiftUIColor("surface-sunken", fallback: p.border))
                            Capsule()
                                .fill(barColor)
                                .frame(width: max(state.tokens > 0 ? 4 : 0, geo.size.width * state.ratio))
                        }
                    }
                    .frame(height: 6)
                }

                let slices = ChatContextMeterLogic.breakdown(
                    contextTokens: session.contextTokens,
                    messages: messages,
                    hasSpace: session.space != nil,
                    hasPersona: session.persona != nil,
                    isTemporary: session.temporary == true
                )
                if !slices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ESTIMATED BREAKDOWN")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(p.tertiaryText)

                        GeometryReader { geo in
                            HStack(spacing: 1.5) {
                                ForEach(slices) { slice in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(sliceColor(slice.category))
                                        .frame(width: max(3, geo.size.width * slice.share - 1.5))
                                }
                            }
                        }
                        .frame(height: 6)

                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(slices) { slice in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(sliceColor(slice.category))
                                        .frame(width: 6, height: 6)
                                    Text(slice.category.label)
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(p.secondaryText)
                                    Spacer()
                                    Text(ChatContextMeterLogic.formatTokens(slice.tokens))
                                        .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                                        .foregroundStyle(p.tertiaryText)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 7))
                }

                Text(pinnedCount > 0
                     ? "\(pinnedCount) pinned \(pinnedCount == 1 ? "message" : "messages") will be preserved verbatim when compacting."
                     : "Bookmark key messages to preserve them verbatim across compaction.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("AUTO-COMPACT THRESHOLD")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                        ForEach(ChatContextMeterLogic.presets) { preset in
                            let active = session.autoRolloverTokens?.value == preset.value
                            Button {
                                setThreshold(preset.value)
                            } label: {
                                Text(preset.label)
                                    .font(.system(size: theme.pointSize(.micro), weight: active ? .semibold : .medium))
                                    .foregroundStyle(active ? p.accent : p.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(active ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? p.accent : p.border))
                            }
                            .buttonStyle(.plain)
                            .disabled(isRunning || session.archived || updatingThreshold)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Optional compaction focus…", text: $focus)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRunning || session.archived || compacting)

                    Button {
                        runCompact()
                    } label: {
                        Label(
                            session.compactPending == true ? "Compacted for next turn" : compacting ? "Compacting…" : "Compact now",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(isRunning || session.archived || compacting || session.compactPending == true)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }

    private func sliceColor(_ category: ChatContextBreakdownCategory) -> Color {
        let viz = ChatVizPalette(theme: theme)
        switch category {
        case .systemPersona: return viz.seriesColor(at: 0)
        case .memory: return viz.seriesColor(at: 1)
        case .spaceKnowledge: return viz.seriesColor(at: 2)
        case .attachmentsTools: return viz.seriesColor(at: 3)
        case .conversation: return viz.seriesColor(at: 4)
        }
    }

    private func setThreshold(_ value: Int?) {
        guard !updatingThreshold else { return }
        updatingThreshold = true
        errorMessage = nil
        Task {
            defer { updatingThreshold = false }
            do {
                let patchValue: APINullable<Int> = value.map { .value($0) } ?? .null
                _ = try await context.store.mutate(
                    API.updateChat(id: session.id, body: API.ChatPatch(
                        autoRolloverTokens: patchValue,
                        revision: session.revision
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func runCompact() {
        guard !compacting else { return }
        compacting = true
        errorMessage = nil
        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { compacting = false }
            if let err = await onCompact(trimmed.isEmpty ? nil : trimmed) {
                errorMessage = err
            } else {
                focus = ""
                open = false
            }
        }
    }
}
