import SwiftUI
import VesperCore

// MARK: - Native Fork Conversation Sheet

struct ChatForkSheetView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let defaultTitle: String
    let hasRepo: Bool
    let message: API.ChatMessage
    let onClose: () -> Void

    @State private var title: String
    @State private var branchRepo: Bool
    @State private var branchName = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(chatId: String, defaultTitle: String, hasRepo: Bool, message: API.ChatMessage, onClose: @escaping () -> Void) {
        self.chatId = chatId
        self.defaultTitle = defaultTitle
        self.hasRepo = hasRepo
        self.message = message
        self.onClose = onClose
        _title = State(initialValue: defaultTitle.isEmpty ? "Forked chat" : "Fork of \(defaultTitle)")
        _branchRepo = State(initialValue: hasRepo && (message.gitCommitSha != nil || message.gitBranch != nil))
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(p.accent)
                Text("Fork conversation from here")
                    .font(.headline)
            }

            Text("Starts a new independent conversation seeded with every message up to this point.")
                .font(.system(size: theme.pointSize(.small)))
                .foregroundStyle(p.secondaryText)

            VStack(alignment: .leading, spacing: 4) {
                Text("Title")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                TextField("Forked chat", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            if hasRepo {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Branch repository from this turn", isOn: $branchRepo)
                    if branchRepo {
                        TextField("Branch name (optional, e.g. feat/fork-alt)", text: $branchName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(10)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.vesper())
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Forking…" : "Fork chat") { submit() }
                    .buttonStyle(.vesper(.primary))
                    .disabled(isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let created = try await context.store.mutate(
                    API.forkChat(id: chatId, body: API.ForkChatRequest(
                        branchName: hasRepo && branchRepo && !trimmedBranch.isEmpty ? trimmedBranch : nil,
                        branchRepo: hasRepo ? branchRepo : nil,
                        messageId: message.id,
                        title: trimmedTitle.isEmpty ? nil : trimmedTitle
                    )),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                onClose()
                context.navigate("/chat/\(created.id)")
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

// MARK: - Save Reply to Knowledge Sheet

struct ChatSaveWikiSheetView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let chatTitle: String
    let projectKey: String?
    let bodyMd: String
    let onClose: () -> Void

    @State private var path: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(chatId: String, chatTitle: String, projectKey: String?, bodyMd: String, onClose: @escaping () -> Void) {
        self.chatId = chatId
        self.chatTitle = chatTitle
        self.projectKey = projectKey
        self.bodyMd = bodyMd
        self.onClose = onClose
        let slug = chatTitle
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        _path = State(initialValue: "notes/\(slug.isEmpty ? "chat-note" : slug)")
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "book")
                    .foregroundStyle(p.accent)
                Text("Save to Knowledge")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Page path")
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                TextField("notes/my-page", text: $path)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .buttonStyle(.vesper())
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Saving…" : "Save page") { submit() }
                    .buttonStyle(.vesper(.primary))
                    .disabled(isSubmitting || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSubmitting, !trimmed.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        let label = chatTitle.isEmpty ? "chat" : chatTitle
        let fullMd = "\(bodyMd)\n\n---\nFrom [\(label)](/chat/\(chatId))"
        Task {
            do {
                let saved = try await context.store.mutate(
                    API.createWikiPage(body: API.NewWikiPage(
                        bodyMd: fullMd,
                        path: trimmed,
                        projectKey: projectKey
                    )),
                    invalidating: QueryInvalidation(resources: ["wiki"])
                )
                onClose()
                context.showToast(ToastItemModel(id: "chat.save.wiki", title: "Saved to Knowledge", tone: .success))
                if let savedPath = saved.path, !savedPath.isEmpty {
                    context.navigate("/wiki/\(savedPath)")
                }
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
