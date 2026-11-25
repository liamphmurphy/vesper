import AppKit
import SwiftUI
import VesperCore

/// The selected item's details and actions (web app/(app)/inbox/detail-pane.tsx).
struct InboxDetailPane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.InboxItem
    let model: InboxModel
    let actions: InboxActions

    var body: some View {
        let kind = InboxLogic.kind(item.kind.rawValue)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Text([kind.label, item.project.isEmpty ? "Workspace" : item.project].filter { !$0.isEmpty }.joined(separator: " · ").uppercased())
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.palette.tertiaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open \u{2197}") { follow(item.href) }
                        .buttonStyle(.link).font(.system(size: theme.pointSize(.small)))
                }
                HStack(spacing: 12) {
                    if let agent = item.agent { WorkPersonaAvatarView(agent: agent, size: 24) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(InboxLogic.headline(kind: item.kind.rawValue, agent: item.agent?.name ?? "An agent") ?? item.title)
                            .vesperText(.heading, theme)
                            .foregroundStyle(kind.tone == .blocked ? theme.swiftUIColor("pill-blocked-fg", fallback: .red)
                                : kind.tone == .human ? theme.swiftUIColor("pill-human-fg", fallback: .orange) : theme.palette.text)
                        Text("\(item.kind.rawValue == "stalled" ? "No activity for " : item.resolved || item.read ? "Changed " : "Waiting ")\(APIDate.waited(item.createdAt)) · \(item.title)")
                            .font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.tertiaryText).lineLimit(2)
                    }
                }
                switch item.kind.rawValue {
                case "approval": InboxApprovalPane(item: item, actions: actions)
                case "blocked", "stalled": InboxRunPane(item: item, actions: actions)
                case "pr_ci_failed", "pr_review_comments": InboxPRFeedbackPane(item: item, actions: actions)
                case "mockup": InboxMockupPane(item: item, actions: actions)
                default: InboxInfoPane(item: item, actions: actions)
                }
            }
            .padding(24)
        }
        .background(theme.swiftUIColor("bg-panel", fallback: theme.palette.background))
        .accessibilityLabel("\(kind.label) details")
    }

    private func follow(_ href: String) {
        if InboxLogic.isExternalHref(href) { context.openExternal(href) } else { context.navigate(href) }
    }
}

// MARK: Shared pieces

private struct PaneSection<Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: theme.pointSize(.small), weight: .medium)).foregroundStyle(theme.palette.secondaryText)
            content
        }
    }
}

private struct PaneQuote: View {
    @Environment(\.vesperTheme) private var theme
    let text: String
    var blocked = false

    var body: some View {
        Text(text)
            .vesperText(.reading, theme)
            .foregroundStyle(theme.swiftUIColor("text-2", fallback: theme.palette.text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                    .fill(theme.swiftUIColor(blocked ? "state-blocked" : "state-human", fallback: .orange)).frame(width: 3)
            }
    }
}

private struct PaneHint: View {
    @Environment(\.vesperTheme) private var theme
    let text: String
    var body: some View { Text(text).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.palette.tertiaryText) }
}

private struct PaneFailure: View {
    @Environment(\.vesperTheme) private var theme
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.system(size: theme.pointSize(.small))).foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
        }
    }
}

/// A note or reply box: ⌘↵ submits, Esc returns to the list.
private struct PaneNote: View {
    @Environment(\.vesperTheme) private var theme
    let label: String
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding
    let submit: (() -> Void)?
    let leave: () -> Void

    var body: some View {
        PaneSection(label: label) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(theme.palette.tertiaryText).padding(.horizontal, 9).padding(.vertical, 8)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .focused(focused)
                    .padding(4)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command), let submit else { return .ignored }
                        submit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        focused.wrappedValue = false
                        leave()
                        return .handled
                    }
            }
            .vesperText(.body, theme)
            .frame(minHeight: 66, maxHeight: 140)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused.wrappedValue ? theme.palette.accent : theme.palette.border))
        }
    }
}

private struct DoneButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) { HStack(spacing: 6) { Text("Mark done"); KeyCap(key: "E") } }.buttonStyle(.vesper())
    }
}

/// Runs one API action for an item: busy while in flight, the error's message on failure.
@MainActor
@Observable
private final class PaneAction {
    var busy = false
    var error: String?

    func run(_ work: @escaping () async throws -> Void, onSuccess: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await work()
                busy = false
                onSuccess()
            } catch {
                busy = false
                self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private func mutateItem<V: Sendable>(_ store: QueryStore, _ request: APIRequest<V>, resources: Set<String>) async throws {
    try await store.mutate(request, invalidating: QueryInvalidation(resources: resources.union(["inbox"])))
}

// MARK: Kinds

private struct InboxApprovalPane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.InboxItem
    let actions: InboxActions
    @State private var note = ""
    @State private var decide = PaneAction()
    @FocusState private var noteFocused: Bool

    var body: some View {
        let run = item.runId.map { context.store.entry(API.getRun(id: $0)) }
        let approvals = run?.data?.approvals
        let ap = approvals?.first { "approval:\($0.id)" == item.id }
        let live = InboxLogic.isOpen(item) && ap?.state == .pending
        let loading = run.map { $0.data == nil && $0.error == nil } ?? false
        let failed = run?.error

        Group {
            if loading {
                SkeletonBar(height: 160)
            } else if let failed, approvals == nil {
                PaneFailure(message: failed.userMessage)
            } else {
                PaneSection(label: "Exact action") {
                    VStack(alignment: .leading, spacing: 6) {
                        (Text(ap?.scope ?? "").font(.system(size: theme.pointSize(.small), design: .monospaced)).foregroundStyle(theme.palette.tertiaryText)
                            + Text(" \(ap?.actionSummary ?? item.summary)"))
                        if let preview = ap?.actionPreview, !preview.isEmpty {
                            ScrollView { Text(preview).font(.system(size: theme.pointSize(.mono), design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                                .frame(maxHeight: 224)
                                .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .vesperText(.body, theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
                }
                if let ap, !ap.riskSummary.isEmpty {
                    PaneSection(label: "Risk summary from \(ap.agent.name)") { Text(ap.riskSummary).vesperText(.body, theme) }
                }
                if live, let ap {
                    PaneNote(label: "Note to \(ap.agent.name) (optional)", text: $note,
                             placeholder: "Added to the resumed turn, e.g. \u{201C}run it after 18:00\u{201D}.",
                             focused: $noteFocused, submit: { send(.approve, ap) }, leave: actions.leave)
                    HStack(spacing: 8) {
                        DoneButton { actions.markDone([item.id]) }
                        Spacer()
                        Button { send(.deny, ap) } label: { HStack(spacing: 6) { Text("Deny"); KeyCap(key: "D") } }
                            .buttonStyle(.vesper(.approveOutline)).disabled(decide.busy)
                        Button { send(.approve, ap) } label: { HStack(spacing: 6) { Text("Approve & continue"); KeyCap(key: "A") } }
                            .buttonStyle(.vesper(.approve)).disabled(decide.busy)
                    }
                    PaneHint(text: ap.chatId != nil ? "Approving lets \(ap.agent.name) run this tool right away." : "Approving resumes \(ap.agent.name) with your note.")
                } else {
                    PaneHint(text: ap.map { $0.state != .pending ? "This request was \($0.state.rawValue)." : "This item is done." } ?? "This item is done.")
                }
                PaneFailure(message: decide.error)
            }
        }
        .task {
            if let runId = item.runId { context.store.load(API.getRun(id: runId)) }
        }
        .onChange(of: ap?.id, initial: true) { _, _ in
            actions.register(InboxPaneActions(
                approve: live ? { if let ap { send(.approve, ap) } } : nil,
                deny: live ? { if let ap { send(.deny, ap) } } : nil,
                focus: { noteFocused = true },
                done: { actions.markDone([item.id]) }))
        }
    }

    private func send(_ decision: API.DecideApprovalDecision, _ ap: API.Approval) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = API.decideApproval(id: ap.id, decision: decision, body: .init(note: trimmed.isEmpty ? nil : trimmed))
        decide.run({ try await mutateItem(context.store, request, resources: ["runs", "chats"]) }) { actions.sent(item.id) }
    }
}

private struct InboxRunPane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.InboxItem
    let actions: InboxActions
    @State private var control = PaneAction()
    @State private var confirming = false

    var body: some View {
        let stalled = item.kind.rawValue == "stalled"
        Group {
            if stalled {
                PaneSection(label: "Last activity") {
                    PaneQuote(text: "No events for \(APIDate.waited(item.createdAt)).", blocked: true)
                    PaneHint(text: "A running run counts as stalled after 30 minutes without an event; one long, quiet command can look the same, so check the run log first. Cancel stops the harness and keeps the branch, so Retry can pick up from there.")
                }
            } else {
                PaneSection(label: "Error") {
                    PaneQuote(text: item.summary, blocked: true)
                    PaneHint(text: "Retry starts a new run for the same agent and branch.")
                }
            }
            if confirming {
                HStack(spacing: 8) {
                    Text("Stop \(item.agent?.name ?? "this")\u{2019}s run?").frame(maxWidth: .infinity, alignment: .leading)
                    Button("Keep running") { confirming = false }.buttonStyle(.vesper())
                    Button("Stop run") { act(.cancel) }.buttonStyle(.vesper(.danger)).disabled(control.busy)
                }
                .vesperText(.body, theme)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            } else {
                HStack(spacing: 8) {
                    DoneButton { actions.markDone([item.id]) }
                    Spacer()
                    if item.runId != nil {
                        if stalled {
                            Button("Cancel run") { confirming = true }.buttonStyle(.vesper(.danger))
                        } else {
                            Button("Retry run") { act(.retry) }.buttonStyle(.vesper(.primary)).disabled(control.busy)
                        }
                    }
                }
            }
            PaneHint(text: stalled ? "The item leaves Inbox after the run stops." : "The item leaves Inbox once the new run starts.")
            PaneFailure(message: control.error)
        }
        .onAppear { actions.register(InboxPaneActions(done: { actions.markDone([item.id]) })) }
    }

    private func act(_ action: API.ControlRunAction) {
        guard let runId = item.runId else { return }
        control.run({ try await mutateItem(context.store, API.controlRun(id: runId, action: action), resources: ["runs"]) }) {
            confirming = false
            actions.sent(item.id)
        }
    }
}

private struct InboxPRFeedbackPane: View {
    @Environment(NativeScreenContext.self) private var context
    let item: API.InboxItem
    let actions: InboxActions
    @State private var address = PaneAction()

    var body: some View {
        let isCI = item.kind.rawValue == "pr_ci_failed"
        let pushId = InboxLogic.pushRequestId(item.id)
        let open = InboxLogic.isOpen(item)
        PaneSection(label: isCI ? "Failing checks" : "Unresolved review threads") {
            PaneQuote(text: item.summary, blocked: isCI)
            PaneHint(text: "Starts a follow-up turn in the originating chat on the pull request\u{2019}s branch.")
        }
        HStack(spacing: 8) {
            if open { DoneButton { actions.markDone([item.id]) } }
            Spacer()
            Button("Open chat \u{2197}") { follow(item.href) }.buttonStyle(.vesper())
            if let pushId {
                Button(address.busy ? "Sending\u{2026}" : isCI ? "Fix CI" : "Address review comments") { fix(isCI: isCI, pushId: pushId) }
                    .buttonStyle(.vesper(.primary)).disabled(address.busy || !open)
            }
        }
        PaneFailure(message: address.error)
            .onAppear { actions.register(InboxPaneActions(done: { actions.markDone([item.id]) })) }
    }

    private func follow(_ href: String) {
        if InboxLogic.isExternalHref(href) { context.openExternal(href) } else { context.navigate(href) }
    }

    private func fix(isCI: Bool, pushId: String) {
        let body = API.AddressPRFeedbackRequest(mode: isCI ? .ci : .review)
        let request = API.addressPushRequestPRFeedback(id: pushId, body: body)
        address.run({ try await mutateItem(context.store, request, resources: ["push-requests", "chats", "bootstrap"]) }) { actions.sent(item.id) }
    }
}

private struct InboxMockupPane: View {
    @Environment(NativeScreenContext.self) private var context
    let item: API.InboxItem
    let actions: InboxActions
    @State private var note = ""
    @State private var review = PaneAction()
    @FocusState private var noteFocused: Bool

    var body: some View {
        let open = InboxLogic.isOpen(item)
        PaneQuote(text: item.summary)
        if open {
            PaneNote(label: "Note (required for Request changes)", text: $note, placeholder: "What should change?", focused: $noteFocused,
                     submit: { decide(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .approved : .changesRequested) },
                     leave: actions.leave)
            HStack(spacing: 8) {
                DoneButton { actions.markDone([item.id]) }
                Spacer()
                Button("Request changes") { decide(.changesRequested) }.buttonStyle(.vesper()).disabled(review.busy)
                Button("Open review \u{2197}") { context.navigate(item.href) }.buttonStyle(.vesper())
                Button { decide(.approved) } label: { HStack(spacing: 6) { Text("Approve"); KeyCap(key: "A") } }
                    .buttonStyle(.vesper(.approve)).disabled(review.busy)
            }
            PaneHint(text: "Pinned comments and version compare live in the review.")
        } else {
            Button("Open review \u{2197}") { context.navigate(item.href) }.buttonStyle(.vesper())
        }
        PaneFailure(message: review.error)
            .onAppear {
                actions.register(InboxPaneActions(approve: { decide(.approved) }, focus: { noteFocused = true }, done: { actions.markDone([item.id]) }))
            }
    }

    private func decide(_ decision: API.ReviewArtifactVersionBody.Decision) {
        guard InboxLogic.isOpen(item), let artifactId = item.artifactId, !review.busy else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if decision == .changesRequested && trimmed.isEmpty {
            noteFocused = true
            return
        }
        let versionId = String(item.id.dropFirst("mockup:".count))
        let request = API.reviewArtifactVersion(id: artifactId, versionId: versionId, body: .init(decision: decision, note: trimmed.isEmpty ? nil : trimmed))
        review.run({ try await mutateItem(context.store, request, resources: ["artifacts"]) }) { actions.sent(item.id) }
    }
}

/// Proposals, reviews, dispatch, mentions and wiki edits: summary, Mark done and a deep link.
private struct InboxInfoPane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    let item: API.InboxItem
    let actions: InboxActions

    var body: some View {
        let planning = item.kind.rawValue == "planning"
        PaneSection(label: planning ? "Goal" : "Summary") {
            Text(planning ? item.title : item.summary).vesperText(.body, theme).textSelection(.enabled)
                .foregroundStyle(theme.swiftUIColor("text-2", fallback: theme.palette.text))
        }
        if planning { PaneHint(text: "\(item.summary). Edit, link and accept drafts on the plan screen.") }
        HStack(spacing: 8) {
            if InboxLogic.isOpen(item) { DoneButton { actions.markDone([item.id]) } }
            Spacer()
            Button(InboxLogic.openLabel(kind: item.kind.rawValue)) {
                if InboxLogic.isExternalHref(item.href) { context.openExternal(item.href) } else { context.navigate(item.href) }
            }
            .buttonStyle(.vesper(.primary))
        }
        .onAppear { actions.register(InboxPaneActions(done: { actions.markDone([item.id]) })) }
    }
}
