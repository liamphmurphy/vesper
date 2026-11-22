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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .background(p.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        .shadow(color: Color.black.opacity(0.14), radius: 10, y: 4)
    }
}

// MARK: - Running-Run Status Strip

struct ChatRunningStatusStrip: View {
    @Environment(\.vesperTheme) private var theme

    let isChatRunning: Bool
    let speakerName: String
    let activeHarness: String?
    let activeTicketRuns: [API.ChatTicketRun]
    let isCancelling: Bool
    let onStopChat: () -> Void
    let onOpenRun: (String) -> Void

    private var hasActivity: Bool {
        isChatRunning || !activeTicketRuns.isEmpty
    }

    var body: some View {
        if hasActivity {
            let p = theme.palette
            HStack(spacing: 8) {
                if let harness = activeHarness, let kind = HarnessCharacterView.kind(for: harness) {
                    HarnessCharacterView(kind: kind, working: true, size: 20)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if isChatRunning {
                    Text("\(speakerName) is replying…")
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                }

                if !activeTicketRuns.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(activeTicketRuns, id: \.runId) { run in
                                Button {
                                    onOpenRun(run.runId)
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(p.accent)
                                            .frame(width: 6, height: 6)
                                        Text(run.ticket)
                                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                                        if let step = run.currentStep, !step.isEmpty {
                                            Text("· \(step)")
                                                .font(.system(size: theme.pointSize(.micro)))
                                                .foregroundStyle(p.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(p.surface, in: Capsule())
                                    .overlay(Capsule().stroke(p.border))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer(minLength: 6)

                if isChatRunning {
                    Button(action: onStopChat) {
                        Label(isCancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.vesper(.danger))
                    .controlSize(.small)
                    .disabled(isCancelling)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .background(p.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
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
            .background(p.surface.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .buttonStyle(.plain)
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
