import SwiftUI
import VesperCore

// MARK: - Aggregated Proposals & Canvases Section

struct ChatProposalsSectionView: View {
    let chatId: String
    let approvals: [API.Approval]
    let secretProposals: [API.ApiSecretProposal]
    let personaProposals: [API.PersonaProposal]
    let characterProposals: [API.PersonaCharacterProposal]
    let ticketChanges: [API.TicketChangeRequest]
    let canvases: [API.ChatCanvasSummary]

    private var hasAny: Bool {
        !approvals.isEmpty || !secretProposals.isEmpty
            || !personaProposals.isEmpty || !characterProposals.isEmpty
            || !ticketChanges.isEmpty || !canvases.isEmpty
    }

    var body: some View {
        if hasAny {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(approvals, id: \.id) { approval in
                    ChatToolApprovalCardView(approval: approval)
                }
                ForEach(secretProposals, id: \.id) { proposal in
                    ChatSecretProposalCardView(proposal: proposal)
                }
                ForEach(personaProposals, id: \.id) { proposal in
                    ChatPersonaProposalCardView(chatId: chatId, proposal: proposal)
                }
                ForEach(characterProposals, id: \.id) { proposal in
                    ChatPersonaCharacterProposalCardView(chatId: chatId, proposal: proposal)
                }
                ForEach(ticketChanges, id: \.id) { change in
                    ChatTicketChangeCardView(request: change)
                }
                if !canvases.isEmpty {
                    ChatCanvasesStripView(chatId: chatId, canvases: canvases)
                }
            }
        }
    }
}

// MARK: - Tool Approval Card

struct ChatToolApprovalCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let approval: API.Approval
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let badge = ChatCardDisplay.stateBadge(for: approval.state.rawValue)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
                Text(approval.actionSummary)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            if !approval.riskSummary.isEmpty {
                Text(approval.riskSummary)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            }

            if let preview = approval.actionPreview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                    .foregroundStyle(p.text)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(p.background, in: RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }

            if approval.state == .pending {
                HStack(spacing: 8) {
                    Button("Approve") { decide(.approve) }
                        .buttonStyle(.vesper(.approve))
                        .disabled(busy)
                    Button("Deny") { decide(.deny) }
                        .buttonStyle(.vesper(.danger))
                        .disabled(busy)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func decide(_ decision: API.DecideApprovalDecision) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    API.decideApproval(id: approval.id, decision: decision, body: nil),
                    invalidating: QueryInvalidation(resources: ["chats", "approvals", "inbox"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Push Request Card

/// Push request cards placed in the transcript (`ChatPushPlacement`), indented under the reply
/// that asked for them.
struct ChatPushRequestStackView: View {
    let requests: [API.PushRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(requests, id: \.id) { request in
                ChatPushRequestCardView(request: request)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.leading, 32)
    }
}

struct ChatPushRequestCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let request: API.PushRequest
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let badge = ChatCardDisplay.stateBadge(for: request.state.rawValue)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title.isEmpty ? "Push request" : request.title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    Text(ChatCardDisplay.pushSummary(
                        branch: request.branch,
                        commitCount: request.commits.count,
                        fileCount: request.files.count
                    ))
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.secondaryText)
                }
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            if !request.repository.isEmpty {
                Text(request.repository)
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
            }

            if let err = request.error, !err.isEmpty {
                Text(err)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack(spacing: 8) {
                if request.state == .pending {
                    Button("Push & open PR") { decide(.push) }
                        .buttonStyle(.vesper(.approve))
                        .disabled(busy)
                    Button("Always allow repo") { decide(.always) }
                        .buttonStyle(.vesper(.approveOutline))
                        .disabled(busy)
                    Button("Decline") { decide(.deny) }
                        .buttonStyle(.vesper(.danger))
                        .disabled(busy)
                }
                if let prUrl = request.prUrl, !prUrl.isEmpty {
                    Button {
                        context.openExternal(prUrl)
                    } label: {
                        Label(
                            request.prNumber.map { "PR #\($0)" } ?? "Open pull request",
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .buttonStyle(.vesper())
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func decide(_ decision: API.PushRequestDecision.Decision) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    API.decidePushRequest(id: request.id, body: API.PushRequestDecision(decision: decision)),
                    invalidating: QueryInvalidation(resources: ["chats", "inbox"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - API Secret Proposal Card

struct ChatSecretProposalCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let proposal: API.ApiSecretProposal
    @State private var secretValue = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(theme.swiftUIColor("state-human", fallback: .orange))
                Text("Secret proposal: \(proposal.name)")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                Spacer(minLength: 8)
                TonePill(label: "Pending", tone: "human")
            }

            Text("\(proposal.host) · \(ChatCardDisplay.secretPlacementLabel(placement: proposal.placement.rawValue, key: proposal.placementKey))")
                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                .foregroundStyle(p.secondaryText)

            if !proposal.reason.isEmpty {
                Text(proposal.reason)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            }

            Text(ChatCardDisplay.secretSentAs(placement: proposal.placement.rawValue, key: proposal.placementKey, handle: proposal.name))
                .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                .foregroundStyle(p.tertiaryText)

            HStack(spacing: 8) {
                SecureField("Paste secret value…", text: $secretValue)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                Button("Save secret") { saveSecret() }
                    .buttonStyle(.vesper(.approve))
                    .disabled(busy || secretValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Decline") { decline() }
                    .buttonStyle(.vesper(.danger))
                    .disabled(busy)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func saveSecret() {
        let value = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                let body = API.NewApiSecret(
                    allowedHosts: [proposal.host],
                    name: proposal.name,
                    placement: proposal.placement,
                    placementKey: proposal.placementKey.isEmpty ? nil : proposal.placementKey,
                    proposalId: proposal.id,
                    value: value
                )
                _ = try await context.store.mutate(
                    API.createApiSecret(body: body),
                    invalidating: QueryInvalidation(resources: ["chats", "secrets"])
                )
                secretValue = ""
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }

    private func decline() {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    API.declineApiSecretProposal(id: proposal.id),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Persona & Character Proposal Cards

struct ChatPersonaProposalCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let proposal: API.PersonaProposal
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let badge = ChatCardDisplay.stateBadge(for: proposal.state.rawValue)
        let canApprove = ChatCardDisplay.canApprovePersonaProposal(
            state: proposal.state.rawValue,
            avatarState: proposal.avatarState?.rawValue
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let svg = proposal.characterSvg, !svg.isEmpty {
                    PersonaCharacterView(svg: svg, color: proposal.color, state: .idle, size: 40, active: false, framed: true)
                } else {
                    WorkPersonaAvatarView(id: nil, handle: nil, name: proposal.name, size: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("New persona: \(proposal.name)")
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    Text("Tone: \(proposal.tone.rawValue)")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.secondaryText)
                }
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            if !proposal.reason.isEmpty {
                Text(proposal.reason)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            }

            if proposal.state == .pending {
                HStack(spacing: 8) {
                    Button(proposal.avatarState == .pending ? "Generating avatar…" : "Create persona") {
                        decide(.approve)
                    }
                    .buttonStyle(.vesper(.approve))
                    .disabled(busy || !canApprove)
                    Button("Decline") { decide(.decline) }
                        .buttonStyle(.vesper(.danger))
                        .disabled(busy)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func decide(_ decision: API.DecidePersonaProposalBody.Decision) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    API.decidePersonaProposal(
                        id: chatId,
                        proposalId: proposal.id,
                        body: API.DecidePersonaProposalBody(decision: decision)
                    ),
                    invalidating: QueryInvalidation(resources: ["chats", "personas"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }
}

struct ChatPersonaCharacterProposalCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let proposal: API.PersonaCharacterProposal
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let badge = ChatCardDisplay.stateBadge(for: proposal.state.rawValue)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PersonaCharacterView(
                    svg: proposal.characterSvg,
                    color: proposal.targetPersona.color,
                    state: .idle,
                    size: 48,
                    active: proposal.state == .pending,
                    framed: true
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Character for \(proposal.targetPersona.name)")
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    if !proposal.summary.isEmpty {
                        Text(proposal.summary)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            if proposal.state == .pending {
                HStack(spacing: 8) {
                    Button("Apply character") { decide(.approve) }
                        .buttonStyle(.vesper(.approve))
                        .disabled(busy)
                    Button("Decline") { decide(.decline) }
                        .buttonStyle(.vesper(.danger))
                        .disabled(busy)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func decide(_ decision: API.DecidePersonaCharacterProposalBody.Decision) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    API.decidePersonaCharacterProposal(
                        id: chatId,
                        proposalId: proposal.id,
                        body: API.DecidePersonaCharacterProposalBody(decision: decision)
                    ),
                    invalidating: QueryInvalidation(resources: ["chats", "personas"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Ticket / Epic Change Proposal Card

struct ChatTicketChangeCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let request: API.TicketChangeRequest
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        let badge = ChatCardDisplay.stateBadge(for: request.state.rawValue)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundStyle(p.accent)
                Button {
                    context.navigate("/tickets/\(request.ticketKey)")
                } label: {
                    Text(ChatCardDisplay.ticketChangeLabel(tool: request.tool.rawValue, ticketKey: request.ticketKey))
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.accent)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
            }

            if !request.ticketTitle.isEmpty {
                Text(request.ticketTitle)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(request.changes.enumerated()), id: \.offset) { _, change in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(change.label)
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .foregroundStyle(p.secondaryText)
                        if let before = change.before, !before.isEmpty {
                            Text(before)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.tertiaryText)
                                .strikethrough()
                                .lineLimit(1)
                            Text("→")
                                .foregroundStyle(p.tertiaryText)
                        }
                        Text(change.after)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.text)
                            .lineLimit(2)
                    }
                }
            }

            if request.state == .pending {
                HStack(spacing: 8) {
                    Button("Apply") { decide(.allow) }
                        .buttonStyle(.vesper(.approve))
                        .disabled(busy)
                    Button("Always allow") { decide(.always) }
                        .buttonStyle(.vesper(.approveOutline))
                        .disabled(busy)
                    Button("Decline") { decide(.deny) }
                        .buttonStyle(.vesper(.danger))
                        .disabled(busy)
                }
            }

            if let err = request.error ?? errorMessage, !err.isEmpty {
                Text(err)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func decide(_ decision: API.TicketChangeDecision.Decision) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            do {
                _ = try await context.store.mutate(
                    API.decideTicketChangeRequest(id: request.id, body: API.TicketChangeDecision(decision: decision)),
                    invalidating: QueryInvalidation(resources: ["chats", "tickets"])
                )
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Canvases Strip

struct ChatCanvasesStripView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let canvases: [API.ChatCanvasSummary]

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            Text("Canvases")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.tertiaryText)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(canvases, id: \.id) { canvas in
                        Button {
                            context.openInNewTab("/chat/\(chatId)?canvas=\(canvas.id)")
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: icon(for: canvas.kind))
                                    .foregroundStyle(p.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(canvas.title.isEmpty ? "Untitled" : canvas.title)
                                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                                        .foregroundStyle(p.text)
                                        .lineLimit(1)
                                    Text(ChatCardDisplay.canvasKindLabel(canvas.kind.rawValue))
                                        .font(.system(size: theme.pointSize(.micro)))
                                        .foregroundStyle(p.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func icon(for kind: API.ChatCanvasSummary.Kind) -> String {
        switch kind {
        case .design: "square.on.square"
        case .svg: "scribble.variable"
        case .deck: "rectangle.stack"
        default: "doc.richtext"
        }
    }
}
