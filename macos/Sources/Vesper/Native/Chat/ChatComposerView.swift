import SwiftUI
import UniformTypeIdentifiers
import VesperCore

struct ChatComposerSubmission: Sendable {
    let body: String
    let mode: ChatSendMode
    let attachmentIds: [String]
    let contextRefs: [API.ChatContextRef]?
    let research: Bool
}

/// Full native glass chat composer for `/chat` and `/chat/:id` (LAZYAGENTS-286).
struct ChatComposerView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String?
    let session: API.ChatSession?
    let personas: [API.Persona]
    let activePersona: API.Persona?
    let harnessModels: [API.ChatHarnessModels]
    let harnesses: [API.HarnessActivity]
    let workflows: [API.Workflow]
    let repositories: [API.RepositoryEntry]
    let activeTicketRuns: [API.ChatTicketRun]

    @Binding var selectedHarness: API.Harness?
    @Binding var selectedModel: String?
    @Binding var selectedEffort: API.ChatEffort?
    @Binding var selectedRepoUrl: String?

    let onSelectNewChatPersona: @MainActor (String) -> Void
    let onSend: @MainActor (ChatComposerSubmission) async -> String?
    let onCancel: @MainActor () async -> Void
    let onSetRepository: @MainActor (String) async -> String?
    let onCompact: @MainActor (String?) async -> String?
    let onStartWorkflow: @MainActor (String, String) async -> String?
    let onStartMusic: @MainActor (String) async -> String?
    let onCompare: @MainActor (ChatCompareOption, String) async -> String?

    private let draftStore = ChatDraftStore()

    @State private var draft = ""
    @State private var cursorUTF16 = 0
    @State private var editorHeight: CGFloat = 34
    @State private var contextChips: [ChatContextChip] = []
    @State private var attachments: [ChatComposerAttachment] = []
    @State private var sendModeWhileRunning: ChatSendMode = .queue
    @State private var researchMode = false
    @State private var isSending = false
    @State private var isCancelling = false
    @State private var errorMessage: String?
    @State private var showFileImporter = false
    @State private var completionIndex = 0
    @State private var completionDismissedText: String?
    @State private var draftSaveTask: Task<Void, Never>?

    private var isRunning: Bool { session?.state == .running }
    private var personaName: String { activePersona?.name ?? session?.agent.name ?? "Vesper" }
    private var activeHarnessId: String {
        selectedHarness?.rawValue ?? session?.harness.rawValue ?? activePersona?.defaultHarness?.rawValue ?? "claude-code"
    }
    private var canCode: Bool { activePersona?.capabilities.code == true }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUploading: Bool {
        attachments.contains { if case .uploading = $0.uploadState { return true }; return false }
    }
    private var canSubmit: Bool {
        (!trimmedDraft.isEmpty || !attachments.isEmpty) && !isSending && !isUploading
    }

    var body: some View {
        let p = theme.palette
        let activeCompletion = resolvedCompletion()

        VStack(alignment: .leading, spacing: 8) {
            if !activeTicketRuns.isEmpty {
                ChatRunningStatusStrip(
                    activeTicketRuns: activeTicketRuns,
                    onOpenRun: { runId in context.navigate("/runs/\(runId)") }
                )
            }

            if let errorMessage {
                errorBanner(errorMessage)
            }

            if let completion = activeCompletion, !completion.items.isEmpty {
                ChatComposerCompletionPopover(
                    heading: completion.heading,
                    items: completion.items,
                    selectedIndex: min(completionIndex, max(0, completion.items.count - 1)),
                    onSelect: { applyCompletion($0, mode: completion.mode) },
                    onDismiss: { completionDismissedText = draft }
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty || !contextChips.isEmpty {
                    chipsStrip
                }

                ChatComposerTextView(
                    text: $draft,
                    cursorUTF16: $cursorUTF16,
                    measuredHeight: $editorHeight,
                    placeholder: isRunning ? "Queue, steer, or ask an aside…" : "Message \(personaName)… (/ for commands, @ for personas)",
                    fontSize: theme.pointSize(.chat),
                    textColor: p.text,
                    placeholderColor: p.tertiaryText,
                    isDisabled: isSending,
                    isCompletionOpen: activeCompletion != nil && !(activeCompletion?.items.isEmpty ?? true),
                    minHeight: 34,
                    maxHeight: 200,
                    onSubmit: { submit() },
                    onCompletionNavigate: { delta in
                        guard let count = activeCompletion?.items.count, count > 0 else { return }
                        completionIndex = (completionIndex + delta + count) % count
                    },
                    onCompletionAccept: {
                        guard let completion = activeCompletion, !completion.items.isEmpty else { return }
                        let idx = min(completionIndex, completion.items.count - 1)
                        applyCompletion(completion.items[idx], mode: completion.mode)
                    },
                    onCompletionDismiss: { completionDismissedText = draft },
                    onAttachFiles: { incoming in handleIncomingFiles(incoming) }
                )
                .frame(height: editorHeight)

                controlsBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .background(p.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.border))
            .shadow(color: Color.black.opacity(0.10), radius: 10, y: 3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(p.background)
        .overlay(alignment: .top) {
            Rectangle().fill(p.rowBorder).frame(height: 1)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.importerTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onAppear { loadDraft(for: chatId) }
        .onDisappear { saveDraftImmediately(for: chatId) }
        .onChange(of: chatId) { oldId, newId in
            saveDraftImmediately(for: oldId)
            loadDraft(for: newId)
            attachments = []
            errorMessage = nil
            completionDismissedText = nil
        }
        .onChange(of: draft) { _, newValue in
            if completionIndex != 0 { completionIndex = 0 }
            if completionDismissedText != nil && completionDismissedText != newValue {
                completionDismissedText = nil
            }
            scheduleDraftSave(for: chatId)
        }
        .onChange(of: contextChips) { _, _ in
            saveDraftImmediately(for: chatId)
        }
    }

    // MARK: - Subviews

    private func errorBanner(_ message: String) -> some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .imageScale(.small)
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Dismiss") { errorMessage = nil }
                .buttonStyle(.plain)
                .foregroundStyle(p.secondaryText)
        }
        .font(.system(size: theme.pointSize(.small)))
        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var chipsStrip: some View {
        let p = theme.palette
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { item in
                    HStack(spacing: 5) {
                        Button {
                            previewAttachment(item)
                        } label: {
                            HStack(spacing: 4) {
                                Text(item.badge)
                                    .font(.system(size: theme.pointSize(.micro), weight: .bold))
                                    .foregroundStyle(p.accent)
                                Text(item.filename)
                                    .font(.system(size: theme.pointSize(.micro)))
                                    .foregroundStyle(p.text)
                                    .lineLimit(1)
                                if case .uploading = item.uploadState {
                                    ProgressView().controlSize(.mini)
                                } else if case .failed = item.uploadState {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                        .imageScale(.small)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Preview \(item.filename)")

                        Button {
                            attachments.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(p.surface, in: Capsule())
                    .overlay(Capsule().stroke(p.border))
                }

                ForEach(contextChips) { chip in
                    HStack(spacing: 4) {
                        Image(systemName: chip.pinned ? "pin.fill" : "doc.text")
                            .font(.system(size: 9))
                            .foregroundStyle(p.secondaryText)
                        Text(chip.label)
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Button {
                            contextChips = ChatComposerContextLogic.removeChip(key: chip.key, from: contextChips)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(p.selected.opacity(0.6), in: Capsule())
                    .overlay(Capsule().stroke(p.border))
                }
            }
        }
    }

    private var controlsBar: some View {
        let p = theme.palette
        return HStack(spacing: 6) {
            Button {
                showFileImporter = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(p.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Attach files")

            personaPickerMenu

            if canCode {
                repositoryPickerMenu
            }

            Button {
                researchMode.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(researchMode ? p.accent : p.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background((researchMode ? p.selected : p.surface.opacity(0.8)), in: Capsule())
                    .overlay(Capsule().stroke(researchMode ? p.accent : p.border))
            }
            .buttonStyle(.plain)
            .help("Research mode (plan before answering)")

            Spacer(minLength: 4)

            modelAndEffortMenu

            ChatHarnessUsageButton(
                activeHarnessId: activeHarnessId,
                harnesses: harnesses,
                isWorking: isRunning
            )

            if isRunning {
                Picker("Send mode", selection: $sendModeWhileRunning) {
                    ForEach(ChatSendMode.runningModes) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 82)
                .help(sendModeWhileRunning.hint)
            }

            if isRunning && trimmedDraft.isEmpty && attachments.isEmpty {
                Button(action: cancelTurn) {
                    Label(isCancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.vesper(.danger))
                .disabled(isCancelling)
            } else {
                let resolvedMode = ChatComposerSendLogic.resolveSendMode(
                    isRunning: isRunning,
                    preferredWhileRunning: sendModeWhileRunning,
                    parsedCommand: ChatSlashCommandLogic.parseCommand(draft)
                )
                Button(action: submit) {
                    Label(isSending ? "Sending…" : resolvedMode.label, systemImage: "arrow.up")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    private var personaPickerMenu: some View {
        let p = theme.palette
        let participants = session?.participants ?? []
        let selectable = personas.filter(\.inChatList)
        return Menu {
            if chatId == nil {
                Section("Chat persona") {
                    ForEach(selectable, id: \.id) { persona in
                        Button {
                            onSelectNewChatPersona(persona.id)
                        } label: {
                            if persona.id == activePersona?.id {
                                Label(persona.name, systemImage: "checkmark")
                            } else {
                                Text(persona.name)
                            }
                        }
                    }
                }
            } else {
                if !participants.isEmpty {
                    Section("In this conversation") {
                        ForEach(participants, id: \.id) { participant in
                            Button("@\(participant.name)") {
                                insertAtMention(name: participant.name)
                            }
                        }
                    }
                }
                Section("Bring in another persona") {
                    ForEach(selectable, id: \.id) { persona in
                        Button("@\(persona.name)") {
                            insertAtMention(name: persona.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                WorkPersonaAvatarView(id: activePersona?.id, handle: activePersona?.handle, name: personaName, size: 17)
                Text(personaName)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(1)
                if participants.count > 1 {
                    Text("+\(participants.count - 1)")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(p.tertiaryText)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(p.surface.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(chatId == nil ? "Choose persona" : "Mention or add personas")
    }

    private var modelAndEffortMenu: some View {
        let p = theme.palette
        let available = harnessModels.filter { $0.available && !$0.models.isEmpty }
        let currentModelId = selectedModel ?? session?.model
        let currentModel = available.flatMap(\.models).first { $0.id == currentModelId }
        let currentEffort = selectedEffort ?? session?.effort
        let labelText = [currentModel?.label ?? currentModelId ?? "Auto", currentEffort?.rawValue.capitalized]
            .compactMap { $0 }
            .joined(separator: " · ")

        return Menu {
            Button("Auto (default)") {
                selectedHarness = nil
                selectedModel = nil
                selectedEffort = nil
            }
            Divider()
            ForEach(available, id: \.harness.rawValue) { group in
                Section(group.label) {
                    ForEach(group.models, id: \.id) { item in
                        Button {
                            selectedHarness = group.harness
                            selectedModel = item.id
                            if let eff = selectedEffort, !item.efforts.contains(eff) {
                                selectedEffort = nil
                            }
                        } label: {
                            if item.id == currentModelId {
                                Label(item.label, systemImage: "checkmark")
                            } else {
                                Text(item.label)
                            }
                        }
                    }
                }
            }
            let efforts = currentModel?.efforts ?? API.ChatEffort.allKnown
            if !efforts.isEmpty {
                Divider()
                Menu("Reasoning effort") {
                    Button("Default") { selectedEffort = nil }
                    ForEach(efforts, id: \.rawValue) { eff in
                        Button {
                            selectedEffort = eff
                        } label: {
                            if eff == currentEffort {
                                Label(eff.rawValue.capitalized, systemImage: "checkmark")
                            } else {
                                Text(eff.rawValue.capitalized)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .imageScale(.small)
                Text(labelText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
            }
            .font(.system(size: theme.pointSize(.micro), weight: .medium))
            .foregroundStyle(p.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(p.surface.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model & reasoning effort")
    }

    private var repositoryPickerMenu: some View {
        let p = theme.palette
        let activeRepo = selectedRepoUrl ?? session?.pendingRepoUrl ?? session?.repoUrl
        let shortName = activeRepo.map { Self.repoShortName($0) } ?? "Repo"
        let allRepos = mergedRepositoryNames()

        return Menu {
            if chatId == nil {
                Button("No repository") { selectedRepoUrl = nil }
                Divider()
            }
            if allRepos.isEmpty {
                Text("No saved repositories")
            } else {
                ForEach(allRepos, id: \.url) { repo in
                    Button {
                        if chatId != nil {
                            Task {
                                if let err = await onSetRepository(repo.url) {
                                    errorMessage = err
                                }
                            }
                        } else {
                            selectedRepoUrl = repo.url
                        }
                    } label: {
                        if activeRepo == repo.url || activeRepo == repo.name {
                            Label(repo.name, systemImage: "checkmark")
                        } else {
                            Text(repo.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                Text(shortName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
            }
            .font(.system(size: theme.pointSize(.micro), weight: .medium))
            .foregroundStyle(p.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(p.surface.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Active repository")
    }

    // MARK: - Completions (@mention & /slash)

    private enum CompletionMode {
        case mention(ChatMentionTrigger)
        case slashCommand
        case slashArg(commandName: String)
    }

    private struct ResolvedCompletion {
        let heading: String
        let mode: CompletionMode
        let items: [ChatCompletionItem]
    }

    private func resolvedCompletion() -> ResolvedCompletion? {
        if completionDismissedText == draft { return nil }

        if let menu = ChatSlashCommandLogic.commandMenu(for: draft) {
            switch menu {
            case .command(let query):
                let matches = ChatSlashCommandLogic.matchingCommands(query: query, isRunning: isRunning)
                let items = matches.map { cmd in
                    ChatCompletionItem(
                        id: "cmd:\(cmd.name)",
                        title: "/\(cmd.name)",
                        subtitle: cmd.hint,
                        badge: cmd.args,
                        personaId: nil,
                        applyValue: ChatSlashCommandLogic.applyCommandCompletion(cmd)
                    )
                }
                return ResolvedCompletion(heading: "Commands", mode: .slashCommand, items: items)

            case .arg(let name, let query):
                let items = argumentCompletions(commandName: name, query: query)
                guard !items.isEmpty else { return nil }
                return ResolvedCompletion(heading: "/\(name) options", mode: .slashArg(commandName: name), items: items)
            }
        }

        if let trigger = ChatMentionLogic.detectTrigger(in: draft, cursorUTF16: cursorUTF16) {
            let participantIds = Set((session?.participants ?? []).map(\.id))
            let candidates = personas.map(ChatMentionCandidate.init)
            let ranked = ChatMentionLogic.rankCandidates(candidates, query: trigger.query, participantIds: participantIds)
            let items = ranked.map { c in
                ChatCompletionItem(
                    id: "mention:\(c.id)",
                    title: c.name,
                    subtitle: c.handle.map { "@\($0)" },
                    badge: participantIds.contains(c.id) ? "in chat" : nil,
                    personaId: c.id,
                    applyValue: c.name
                )
            }
            return ResolvedCompletion(heading: "Personas", mode: .mention(trigger), items: items)
        }

        return nil
    }

    private func argumentCompletions(commandName: String, query: String) -> [ChatCompletionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        switch commandName {
        case "model", "compare":
            return compareOptions()
                .filter { q.isEmpty || $0.model.lowercased().contains(q) || $0.modelLabel.lowercased().contains(q) || $0.harnessLabel.lowercased().contains(q) }
                .map {
                    ChatCompletionItem(
                        id: "model:\($0.id)",
                        title: $0.modelLabel,
                        subtitle: $0.harnessLabel,
                        badge: $0.isDefault ? "default" : nil,
                        personaId: nil,
                        applyValue: $0.model
                    )
                }
        case "effort":
            return API.ChatEffort.allKnown
                .filter { q.isEmpty || $0.rawValue.lowercased().contains(q) }
                .map {
                    ChatCompletionItem(
                        id: "effort:\($0.rawValue)",
                        title: $0.rawValue.capitalized,
                        subtitle: nil,
                        badge: nil,
                        personaId: nil,
                        applyValue: $0.rawValue
                    )
                }
        case "persona":
            return personas.filter(\.inChatList)
                .filter { q.isEmpty || $0.name.lowercased().contains(q) }
                .map {
                    ChatCompletionItem(
                        id: "persona:\($0.id)",
                        title: $0.name,
                        subtitle: $0.handle.map { "@\($0)" },
                        badge: nil,
                        personaId: $0.id,
                        applyValue: $0.name
                    )
                }
        case "workflow":
            return workflows
                .filter { q.isEmpty || $0.name.lowercased().contains(q) }
                .map {
                    ChatCompletionItem(
                        id: "wf:\($0.id)",
                        title: $0.name,
                        subtitle: $0.description,
                        badge: nil,
                        personaId: nil,
                        applyValue: $0.name
                    )
                }
        case "repo":
            return mergedRepositoryNames()
                .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.url.lowercased().contains(q) }
                .map {
                    ChatCompletionItem(
                        id: "repo:\($0.url)",
                        title: $0.name,
                        subtitle: $0.url,
                        badge: nil,
                        personaId: nil,
                        applyValue: $0.name
                    )
                }
        default:
            return []
        }
    }

    private func applyCompletion(_ item: ChatCompletionItem, mode: CompletionMode) {
        switch mode {
        case .mention(let trigger):
            let candidate = ChatMentionCandidate(id: item.personaId ?? item.id, name: item.applyValue)
            let updated = ChatMentionLogic.insertMention(candidate, into: draft, trigger: trigger)
            draft = updated.text
            cursorUTF16 = updated.cursorUTF16
        case .slashCommand:
            draft = item.applyValue
            cursorUTF16 = (draft as NSString).length
        case .slashArg(let commandName):
            draft = ChatSlashCommandLogic.applyArgumentCompletion(commandName: commandName, argument: item.applyValue)
            cursorUTF16 = (draft as NSString).length
        }
    }

    private func insertAtMention(name: String) {
        let prefix = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
        draft += "\(prefix)@\(name) "
        cursorUTF16 = (draft as NSString).length
    }

    // MARK: - Submission & Slash Commands

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil

        if let cmd = ChatSlashCommandLogic.parseCommand(draft) {
            handleSlashCommand(cmd)
            return
        }

        let literal = ChatSlashCommandLogic.literalBody(trimmedDraft)
        let body = ChatComposerContextLogic.serializeBody(literal, chips: contextChips)
        let mode = ChatComposerSendLogic.resolveSendMode(
            isRunning: isRunning,
            preferredWhileRunning: sendModeWhileRunning,
            parsedCommand: nil
        )
        sendPayload(body: body, mode: mode)
    }

    private func handleSlashCommand(_ cmd: ChatParsedCommand) {
        switch cmd.name {
        case "new":
            clearComposer()
            context.navigate("/chat")
        case "stop":
            clearComposer()
            cancelTurn()
        case "memory":
            clearComposer()
            context.navigate("/memory")
        case "compact":
            let focus = cmd.arg.isEmpty ? nil : cmd.arg
            clearComposer()
            Task {
                if let err = await onCompact(focus) { errorMessage = err }
            }
        case "steer":
            guard !cmd.arg.isEmpty else { errorMessage = "Usage: /steer <guidance>"; return }
            sendPayload(body: cmd.arg, mode: isRunning ? .steer : .send)
        case "queue":
            guard !cmd.arg.isEmpty else { errorMessage = "Usage: /queue <message>"; return }
            sendPayload(body: cmd.arg, mode: isRunning ? .queue : .send)
        case "aside":
            guard !cmd.arg.isEmpty else { errorMessage = "Usage: /aside <question>"; return }
            sendPayload(body: cmd.arg, mode: .aside)
        case "design":
            guard !cmd.arg.isEmpty else { errorMessage = "Usage: /design <what to design>"; return }
            sendPayload(body: ChatSlashCommandLogic.designRequest(cmd.arg), mode: .send)
        case "music":
            let prompt = cmd.arg.isEmpty ? "Create a short ambient track" : cmd.arg
            clearComposer()
            Task {
                if let err = await onStartMusic(prompt) { errorMessage = err }
            }
        case "model":
            let q = cmd.arg.lowercased()
            if q == "auto" || q == "default" {
                selectedHarness = nil; selectedModel = nil; clearComposer(); return
            }
            if let match = compareOptions().first(where: { $0.model.lowercased() == q || $0.modelLabel.lowercased() == q || $0.model.lowercased().hasPrefix(q) }) {
                selectedHarness = API.Harness(rawValue: match.harness)
                selectedModel = match.model
                clearComposer()
            } else {
                errorMessage = "Unknown model “\(cmd.arg)”."
            }
        case "effort":
            let q = cmd.arg.lowercased()
            if q == "default" { selectedEffort = nil; clearComposer(); return }
            if let eff = API.ChatEffort.allKnown.first(where: { $0.rawValue == q }) {
                selectedEffort = eff; clearComposer()
            } else {
                errorMessage = "Unknown effort “\(cmd.arg)”."
            }
        case "persona":
            if let match = personas.first(where: { $0.name.lowercased() == cmd.arg.lowercased() || $0.handle?.lowercased() == cmd.arg.lowercased() }) {
                clearComposer()
                onSelectNewChatPersona(match.id)
                context.navigate("/chat")
            } else {
                errorMessage = "Unknown persona “\(cmd.arg)”."
            }
        case "repo":
            guard !cmd.arg.isEmpty else { errorMessage = "Usage: /repo <repository>"; return }
            let target = mergedRepositoryNames().first(where: { $0.name.lowercased() == cmd.arg.lowercased() })?.url ?? cmd.arg
            clearComposer()
            if chatId != nil {
                Task { if let err = await onSetRepository(target) { errorMessage = err } }
            } else {
                selectedRepoUrl = target
            }
        case "workflow":
            let parts = cmd.arg.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard let first = parts.first else { errorMessage = "Usage: /workflow <name> [input]"; return }
            let query = String(first).lowercased()
            guard let wf = workflows.first(where: { $0.name.lowercased() == query || $0.name.lowercased().hasPrefix(query) }) else {
                errorMessage = "Unknown workflow “\(first)”."
                return
            }
            let input = parts.count > 1 ? String(parts[1]) : ""
            clearComposer()
            Task { if let err = await onStartWorkflow(wf.id, input) { errorMessage = err } }
        case "compare":
            switch ChatSlashCommandLogic.resolveCompareTarget(options: compareOptions(), raw: cmd.arg) {
            case .matched(let option, let question):
                clearComposer()
                Task { if let err = await onCompare(option, question) { errorMessage = err } }
            case .error(let msg):
                errorMessage = msg
            }
        default:
            sendPayload(body: ChatComposerContextLogic.serializeBody(trimmedDraft, chips: contextChips), mode: .send)
        }
    }

    private func sendPayload(body: String, mode: ChatSendMode) {
        let uploadedIds = attachments.compactMap(\.uploadedId)
        let refs = ChatComposerContextLogic.toAPIContextRefs(contextChips)
        let prevDraft = draft
        let prevAttachments = attachments
        let prevChips = contextChips
        let research = researchMode

        isSending = true
        clearComposer()

        Task {
            let err = await onSend(ChatComposerSubmission(
                body: body,
                mode: mode,
                attachmentIds: uploadedIds,
                contextRefs: refs,
                research: research
            ))
            isSending = false
            if let err {
                draft = prevDraft
                attachments = prevAttachments
                contextChips = prevChips
                errorMessage = err
            } else {
                researchMode = false
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

    private func clearComposer() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        draft = ""
        cursorUTF16 = 0
        attachments = []
        contextChips = []
        draftStore.clear(chatId: chatId)
    }

    // MARK: - Attachments & Quick Look

    private static let importerTypes: [UTType] = [
        .pdf, .png, .jpeg, .gif, .webP, .plainText, .commaSeparatedText, .json, .zip, .data,
    ]

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            var incoming: [ChatComposerIncomingFile] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let name = url.lastPathComponent
                incoming.append(ChatComposerIncomingFile(
                    filename: name,
                    contentType: ChatAttachmentRules.mimeType(for: name),
                    data: data,
                    localURL: url
                ))
            }
            handleIncomingFiles(incoming)
        }
    }

    private func handleIncomingFiles(_ incoming: [ChatComposerIncomingFile]) {
        for file in incoming {
            if let problem = ChatAttachmentRules.canAdd(
                currentCount: attachments.count,
                filename: file.filename,
                sizeBytes: file.data.count
            ) {
                errorMessage = "\(file.filename): \(problem)"
                continue
            }
            let item = ChatComposerAttachment(
                filename: file.filename,
                contentType: file.contentType,
                sizeBytes: file.data.count,
                localURL: file.localURL,
                uploadState: .uploading
            )
            attachments.append(item)
            uploadAttachment(item, data: file.data)
        }
    }

    private func uploadAttachment(_ item: ChatComposerAttachment, data: Data) {
        Task {
            var form = APIMultipartForm()
            form.addFile("file", filename: item.filename, contentType: item.contentType, data: data)
            do {
                let uploaded = try await context.store.mutate(API.uploadChatAttachment(body: form))
                if let idx = attachments.firstIndex(where: { $0.id == item.id }) {
                    attachments[idx].uploadState = .uploaded(id: uploaded.id)
                }
            } catch {
                let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
                if let idx = attachments.firstIndex(where: { $0.id == item.id }) {
                    attachments[idx].uploadState = .failed(msg)
                }
                errorMessage = "Upload failed for \(item.filename): \(msg)"
            }
        }
    }

    private func previewAttachment(_ item: ChatComposerAttachment) {
        let previewURL: String?
        if let uploadedId = item.uploadedId {
            previewURL = "/api/v1/chat-attachments/\(uploadedId)/content"
        } else if let local = item.localURL {
            previewURL = local.absoluteString
        } else {
            previewURL = nil
        }
        guard let url = previewURL else { return }
        context.showQuickLook(
            [QuickLookItem(url: url, title: item.filename, filename: item.filename, contentType: item.contentType)],
            index: 0
        )
    }

    // MARK: - Drafts & Helpers

    private func loadDraft(for id: String?) {
        if let saved = draftStore.load(chatId: id) {
            draft = saved.text
            contextChips = saved.chips
            cursorUTF16 = (saved.text as NSString).length
        } else {
            draft = ""
            contextChips = []
            cursorUTF16 = 0
        }
    }

    private func scheduleDraftSave(for id: String?) {
        draftSaveTask?.cancel()
        let snapshot = ChatComposerDraft(text: draft, chips: contextChips)
        let store = draftStore
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            store.save(snapshot, chatId: id)
        }
    }

    private func saveDraftImmediately(for id: String?) {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        draftStore.save(ChatComposerDraft(text: draft, chips: contextChips), chatId: id)
    }

    private func compareOptions() -> [ChatCompareOption] {
        harnessModels.filter(\.available).flatMap { group in
            group.models.map { m in
                ChatCompareOption(
                    name: "\(group.label) \(m.label)",
                    harness: group.harness.rawValue,
                    harnessLabel: group.label,
                    model: m.id,
                    modelLabel: m.label,
                    isDefault: m.default
                )
            }
        }
    }

    private func mergedRepositoryNames() -> [API.RepositoryEntry] {
        var seen = Set<String>()
        var list: [API.RepositoryEntry] = []
        for repo in repositories {
            if seen.insert(repo.url).inserted { list.append(repo) }
        }
        for repo in activePersona?.repos ?? [] {
            if seen.insert(repo).inserted {
                list.append(API.RepositoryEntry(name: Self.repoShortName(repo), url: repo))
            }
        }
        return list
    }

    private static func repoShortName(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: ".git", with: "")
        let parts = trimmed.split(separator: "/")
        if parts.count >= 2 { return "\(parts[parts.count - 2])/\(parts[parts.count - 1])" }
        return trimmed
    }
}
