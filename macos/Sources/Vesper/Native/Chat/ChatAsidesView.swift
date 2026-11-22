import SwiftUI
import VesperCore

/// The asides asked during the running reply, under its status card and joined to it by a rail.
/// Each is answered by a side instance that saw the reply so far (`LiveAsides` in web).
struct ChatLiveAsidesView: View {
    let parentChatId: String
    let asides: [API.ChatSession]

    @State private var hidden: Set<String> = []

    var body: some View {
        let shown = asides.filter { !hidden.contains($0.id) }
        if !shown.isEmpty {
            ChatAsideRail {
                ForEach(shown, id: \.id) { aside in
                    ChatAsideCardView(parentChatId: parentChatId, aside: aside, live: true) {
                        hidden.insert(aside.id)
                    }
                }
            }
        }
    }
}

/// A finished reply's asides, folded into one chip: they never became part of the conversation
/// (`ReplyAsides` in web).
struct ChatReplyAsidesView: View {
    @Environment(\.vesperTheme) private var theme

    let parentChatId: String
    let asides: [API.ChatSession]
    let speakerName: String

    @State private var open = false

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 8) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .imageScale(.small)
                    Text("\(ChatAsideLogic.countLabel(asides.count)) \u{00B7} not in \(speakerName)\u{2019}s context")
                        .font(.system(size: theme.pointSize(.small)))
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundStyle(p.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .overlay(Capsule().stroke(p.border))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                ChatAsideRail {
                    ForEach(asides, id: \.id) { aside in
                        ChatAsideCardView(parentChatId: parentChatId, aside: aside, live: false, onHide: nil)
                    }
                }
            }
        }
    }
}

private struct ChatAsideRail<Content: View>: View {
    @Environment(\.vesperTheme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.leading, 16)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.swiftUIColor("state-review", fallback: .purple).opacity(0.35))
                .frame(width: 1.5)
        }
        .padding(.leading, 22)
        .frame(maxWidth: 720, alignment: .leading)
    }
}

private struct ChatAsideCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let parentChatId: String
    let aside: API.ChatSession
    let live: Bool
    let onHide: (() -> Void)?

    @State private var watchedKey: QueryKey?
    @State private var busy = false
    @State private var actionError: String?

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: aside.id, limit: 50)
    }

    private var answering: Bool { aside.state == .running }

    var body: some View {
        let p = theme.palette
        let reviewFg = theme.swiftUIColor("pill-review-fg", fallback: .purple)
        let reviewBg = theme.swiftUIColor("pill-review-bg", fallback: Color.purple.opacity(0.15))
        let messages = context.store.entry(messagesRequest).data?.messages ?? []
        let content = ChatAsideLogic.content(
            messages: messages,
            title: aside.title,
            running: answering,
            failed: aside.state == .failed,
            error: aside.error
        )

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WorkPersonaAvatarView(
                    id: aside.persona?.id,
                    handle: nil,
                    name: aside.persona?.name ?? "Assistant",
                    size: 20,
                    active: answering
                )
                Text(aside.persona?.name ?? "Assistant")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(reviewFg)
                Text("ASIDE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(reviewFg)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(reviewBg, in: RoundedRectangle(cornerRadius: 3))
                Text(live ? "sees the live reply \u{00B7} read-only" : "asked during this reply")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if live && answering {
                    Button("Stop") { Task { await stop() } }
                        .buttonStyle(.plain)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.tertiaryText)
                        .disabled(busy)
                } else if live, let onHide {
                    Button(action: onHide) {
                        Image(systemName: "xmark").imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(p.tertiaryText)
                    .accessibilityLabel("Hide aside")
                }
            }

            HStack {
                Spacer(minLength: 40)
                Text(content.question)
                    .font(.system(size: theme.pointSize(.body)))
                    .foregroundStyle(p.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(p.selected, in: RoundedRectangle(cornerRadius: 12))
            }

            switch content.status {
            case .answered(let answer):
                MarkdownView(markdown: answer, textStyle: .chat, chat: true)
            case .failed(let reason):
                Text(reason)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            case .answering:
                Text("Reading the live reply: its steps, tool output and what it has written\u{2026}")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
            case .stopped:
                Text("Stopped before answering.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.tertiaryText)
            }

            if live, case .answered = content.status {
                HStack(spacing: 6) {
                    actionButton("Queue as follow-up", systemImage: "clock") {
                        API.queueChatFollowup(id: parentChatId, body: API.ChatMessageEdit(body: content.question))
                    }
                    actionButton("Steer with this", systemImage: "bolt") {
                        API.steerChat(id: parentChatId, body: API.ChatMessageEdit(body: content.question))
                    }
                }
            }
            if let actionError {
                Text(actionError)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.swiftUIColor("state-review", fallback: .purple).opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aside: \(content.question)")
        .task(id: aside.id) { watchMessages() }
        // Refetch as the aside moves on, also without the live event stream.
        .onChange(of: "\(aside.state.rawValue):\(aside.messageCount)") { _, _ in
            Task { _ = await context.store.refetch(messagesRequest) }
        }
        .onDisappear {
            if let watchedKey { context.store.stopObserving(watchedKey) }
            watchedKey = nil
        }
    }

    private func actionButton<V: Sendable>(
        _ title: String,
        systemImage: String,
        request: @escaping () -> APIRequest<V>
    ) -> some View {
        let p = theme.palette
        return Button {
            Task { await run(request()) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func watchMessages() {
        if let watchedKey { context.store.stopObserving(watchedKey) }
        context.store.observe(messagesRequest)
        context.store.load(messagesRequest)
        watchedKey = messagesRequest.key
    }

    private func stop() async {
        await run(API.cancelChatTurn(id: aside.id))
    }

    private func run<V: Sendable>(_ request: APIRequest<V>) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await context.store.mutate(request, invalidating: QueryInvalidation(resources: ["chats"]))
            actionError = nil
        } catch {
            actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
