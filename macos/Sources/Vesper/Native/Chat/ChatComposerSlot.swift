import SwiftUI
import VesperCore

/// Functional SwiftUI composer seam for `/chat` and `/chat/:id`.
/// Replaced by the full native composer (attachments, slash commands, @mentions, effort/voice) in LAZYAGENTS-286.
struct ChatComposerSlot: View {
    @Environment(\.vesperTheme) private var theme

    let chatId: String?
    let isRunning: Bool
    let personaId: String?
    let personaName: String
    let modelLabel: String?
    let onSend: @MainActor (String) async -> String?
    let onCancel: @MainActor () async -> Void

    @State private var draft = ""
    @State private var isSending = false
    @State private var isCancelling = false
    @State private var errorMessage: String?

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && !isSending && !isRunning
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                    Text(errorMessage)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Dismiss") { self.errorMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(p.secondaryText)
                }
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Message \(personaName)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .vesperText(.chat, theme)
                    .lineLimit(1...6)
                    .disabled(isSending)
                    .onSubmit {
                        if canSend { submit() }
                    }

                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        WorkPersonaAvatarView(id: personaId, handle: nil, name: personaName, size: 18)
                        Text(personaName)
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .foregroundStyle(p.secondaryText)
                        if let modelLabel, !modelLabel.isEmpty {
                            Text("·")
                                .foregroundStyle(p.tertiaryText)
                            Text(modelLabel)
                                .font(.system(size: theme.pointSize(.small)))
                                .foregroundStyle(p.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if isRunning {
                        Button {
                            cancelTurn()
                        } label: {
                            Label(isCancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.vesper(.danger))
                        .disabled(isCancelling)
                    } else {
                        Button {
                            submit()
                        } label: {
                            Label(isSending ? "Sending…" : "Send", systemImage: "arrow.up")
                        }
                        .buttonStyle(.vesper(.primary))
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: [.command])
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(p.background)
        .overlay(alignment: .top) {
            Rectangle().fill(p.rowBorder).frame(height: 1)
        }
    }

    private func submit() {
        let body = trimmedDraft
        guard !body.isEmpty, !isSending else { return }
        errorMessage = nil
        isSending = true
        let previous = draft
        draft = ""
        Task {
            let err = await onSend(body)
            isSending = false
            if let err {
                draft = previous
                errorMessage = err
            }
        }
    }

    private func cancelTurn() {
        guard !isCancelling else { return }
        isCancelling = true
        Task {
            await onCancel()
            isCancelling = false
        }
    }
}
