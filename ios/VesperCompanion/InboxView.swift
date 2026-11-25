import SwiftUI
import VesperCore

struct InboxView: View {
    let connection: CompanionConnectionManager
    let sseTick: Int
    @Binding var badgeCount: Int

    @State private var items: [InboxItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var replyTarget: InboxItem?
    @State private var replyText = ""

    private struct InboxListResponse: Decodable {
        var items: [InboxItem]
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                let needsYou = items.filter { $0.needsYou && !$0.resolved }
                let other = items.filter { !($0.needsYou && !$0.resolved) }

                if items.isEmpty && !loading {
                    ContentUnavailableView(
                        "Inbox Clear",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing is waiting on you right now.")
                    )
                } else {
                    if !needsYou.isEmpty {
                        Section("Needs You (\(needsYou.count))") {
                            ForEach(needsYou, id: \.id) { item in
                                InboxItemRow(
                                    item: item,
                                    onDecision: { decision in
                                        Task { await decide(item, decision: decision) }
                                    },
                                    onReply: {
                                        replyText = ""
                                        replyTarget = item
                                    }
                                )
                            }
                        }
                    }
                    if !other.isEmpty {
                        Section("Recent") {
                            ForEach(other, id: \.id) { item in
                                InboxItemRow(item: item, onDecision: nil, onReply: nil)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
            .refreshable { await load() }
            .task(id: connection.state) { await load() }
            .onChange(of: sseTick) { _, _ in
                Task { await load(silent: true) }
            }
            .sheet(item: $replyTarget) { item in
                NavigationStack {
                    Form {
                        Section(item.title) {
                            TextEditor(text: $replyText)
                                .frame(minHeight: 120)
                        }
                    }
                    .navigationTitle("Reply")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { replyTarget = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") {
                                let target = item
                                let text = replyText
                                replyTarget = nil
                                Task { await sendReply(target, text: text) }
                            }
                            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func alert(for item: InboxItem) -> DesktopAlert {
        DesktopAlert(
            title: item.title,
            body: item.summary ?? "",
            href: item.href,
            signature: NotificationLogic.itemSignature(item),
            kind: item.kind,
            itemId: item.id,
            runId: item.runId,
            ticketKey: item.ticketKey,
            agentHandle: item.agent?.handle
        )
    }

    private func load(silent: Bool = false) async {
        guard let client = connection.apiClient else { return }
        if !silent { loading = true }
        defer { loading = false }
        do {
            let resp = try await client.get("/api/v1/inbox", as: InboxListResponse.self)
            items = resp.items
            badgeCount = resp.items.filter { $0.needsYou && !$0.resolved }.count
            errorMessage = nil
        } catch {
            if !silent {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func decide(_ item: InboxItem, decision: NotificationLogic.Decision) async {
        guard let client = connection.apiClient,
              let call = NotificationLogic.decisionRequest(alert(for: item), decision)
        else { return }
        do {
            try await client.send(call)
            await load(silent: true)
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func sendReply(_ item: InboxItem, text: String) async {
        guard let client = connection.apiClient,
              let call = NotificationLogic.replyRequest(alert(for: item), text)
        else { return }
        do {
            try await client.send(call)
            await load(silent: true)
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

extension InboxItem: @retroactive Identifiable {}

private struct InboxItemRow: View {
    let item: InboxItem
    let onDecision: ((NotificationLogic.Decision) -> Void)?
    let onReply: (() -> Void)?

    private var action: NotificationLogic.AlertAction {
        let alert = DesktopAlert(
            title: item.title,
            body: item.summary ?? "",
            href: item.href,
            signature: NotificationLogic.itemSignature(item),
            kind: item.kind,
            itemId: item.id,
            runId: item.runId,
            ticketKey: item.ticketKey,
            agentHandle: item.agent?.handle
        )
        return NotificationLogic.alertActionFor(alert, actionsEnabled: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let key = item.ticketKey, !key.isEmpty {
                    Text(key)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item.kind.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                Spacer()
            }
            Text(item.title)
                .font(.body.weight(.medium))
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            switch action {
            case .decide(let approve, let decline):
                if let onDecision {
                    HStack(spacing: 10) {
                        Button(approve) { onDecision(.approve) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button(decline, role: .destructive) { onDecision(.deny) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            case .reply(let placeholder):
                if let onReply {
                    Button(placeholder) { onReply() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            case .none:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}
