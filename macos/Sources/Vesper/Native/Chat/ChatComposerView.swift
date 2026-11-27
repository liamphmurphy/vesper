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
    @AppStorage(ChatLiveThinkingPreference.defaultsKey) private var showLiveThinking = false

    let chatId: String?
    let session: API.ChatSession?
    let personas: [API.Persona]
    let activePersona: API.Persona?
    let harnessModels: [API.ChatHarnessModels]
    let harnesses: [API.HarnessActivity]
    let workflows: [API.Workflow]
    let repositories: [API.RepositoryEntry]

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
    /// Opens Live Voice, talking with the persona out loud.
    let onStartLiveVoice: @MainActor () -> Void
    var onOpenOutline: (@MainActor () -> Void)? = nil
    var onStartTemporaryChat: (@MainActor () -> Void)? = nil
    /// Text to draft without sending; `onPrefillApplied` gets its token once it is in the composer.
    var prefill: ChatComposerPrefill? = nil
    var onPrefillApplied: (@MainActor (Int) -> Void)? = nil
    /// Active TodoWrite/TaskCreate plan progress pinned above the composer while a turn runs.
    var livePlanProgress: ChatPlanProgress? = nil
    var livePlanTurnKey: String = ""
    /// When true, omits the bottom-docked bar chrome (outer padding, background, and top divider)
    /// so the composer can sit inline inside a scrollable screen such as a Space hub.
    var inline: Bool = false
    /// Optional placeholder override for inline contexts (e.g. "New chat in Vesper").
    var placeholderOverride: String? = nil

    private let draftStore = ChatDraftStore()

    @State private var editor = ChatComposerController()
    @State private var hasDraftText = false
    @State private var parsedSlashCommand: ChatParsedCommand?
    @State private var activeCompletion: ResolvedCompletion?
    @State private var editorHeight: CGFloat = 34
    @State private var contextChips: [ChatContextChip] = []
    @State private var attachments: [ChatComposerAttachment] = []
    @State private var sendModeWhileRunning: ChatSendMode = .queue
    @State private var researchMode = false
    @State private var isSending = false
    @State private var isCancelling = false
    @State private var errorMessage: String?
    @State private var dictationSettingsURL: URL?
    @State private var showFileImporter = false
    @State private var completionIndex = 0
    @State private var completionDismissedText: String?
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var speech = LiveSpeechRecognizer()
    @State private var isPreparingDictation = false
    @State private var isApplyingDictation = false
    @State private var dictationAnchor: ChatDictationAnchor?
    @State private var lastDictatedText: String?
    @State private var dictationStartTask: Task<Void, Never>?
    @State private var dictationFinishTask: Task<Void, Never>?
    @State private var micPressStart: Date?
    @State private var micWasListeningBeforePress = false
    @State private var pendingReleaseStop = false
    @State private var watchedFollowupsKey: QueryKey?

    private var isRunning: Bool { session?.state == .running }
    private var personaName: String { activePersona?.name ?? session?.agent.name ?? "Vesper" }
    private var speakerName: String {
        session?.speaker?.name ?? session?.persona?.name ?? activePersona?.name ?? session?.agent.name ?? "Vesper"
    }
    private var followupsRequest: APIRequest<API.ChatFollowupList>? {
        chatId.map { API.listChatFollowups(id: $0) }
    }
    private var activeHarnessId: String {
        selectedHarness?.rawValue ?? session?.harness.rawValue ?? activePersona?.defaultHarness?.rawValue ?? "claude-code"
    }
    private var canCode: Bool { activePersona?.capabilities.code == true }
    private var trimmedDraft: String { editor.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isUploading: Bool {
        attachments.contains { if case .uploading = $0.uploadState { return true }; return false }
    }
    private var canSubmit: Bool {
        (hasDraftText || !attachments.isEmpty) && !isSending && !isUploading
    }

    private var activeRepoLabel: String? {
        let raw = (selectedRepoUrl ?? session?.repoUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return Self.repoShortName(raw)
    }

    private var hasAnyChips: Bool {
        !attachments.isEmpty || !contextChips.isEmpty || researchMode || (canCode && activeRepoLabel != nil) || speech.listening
    }

    var body: some View {
        let p = theme.palette
        let followups = followupsRequest.flatMap { context.store.entry($0).data?.followups } ?? []
        let messages = chatId.flatMap { context.store.entry(API.listChatMessages(id: $0, limit: 200)).data?.messages } ?? []

        VStack(alignment: .leading, spacing: 8) {
            if isRunning, let livePlanProgress {
                ChatPinnedPlanChecklistBar(
                    progress: livePlanProgress,
                    turnKey: livePlanTurnKey
                )
            }

            if let chatId, session?.archived != true, !followups.isEmpty {
                ChatFollowupTrayView(
                    chatId: chatId,
                    items: followups,
                    speakerName: speakerName,
                    isRunning: isRunning,
                    isHeld: ChatFollowupLogic.isHeld(state: session?.state, lastMessageRole: messages.last?.role),
                    disabled: isSending,
                    onSendNow: { body in
                        await sendFollowupNow(body)
                    },
                    onEdit: { body in
                        editFollowupInComposer(body)
                    }
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
                    onDismiss: { dismissCompletion() }
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                if hasAnyChips {
                    chipsStrip
                }

                ChatComposerTextView(
                    controller: editor,
                    measuredHeight: $editorHeight,
                    placeholder: placeholderOverride ?? (isRunning ? sendModeWhileRunning : .send).placeholder(personaName: personaName),
                    fontSize: theme.pointSize(.chat),
                    textColor: p.text,
                    placeholderColor: p.tertiaryText,
                    isDisabled: isSending,
                    isCompletionOpen: activeCompletion != nil && !(activeCompletion?.items.isEmpty ?? true),
                    canCycleSendMode: isRunning,
                    minHeight: 34,
                    maxHeight: 200,
                    onTextChange: { text, cursorUTF16 in
                        handleDraftChange(text: text, cursorUTF16: cursorUTF16, save: true)
                    },
                    onSelectionChange: { text, cursorUTF16 in
                        handleSelectionChange(text: text, cursorUTF16: cursorUTF16)
                    },
                    onSubmit: { submit() },
                    onCycleSendMode: { backward in
                        sendModeWhileRunning = sendModeWhileRunning.cycled(backward: backward)
                    },
                    onCompletionNavigate: { delta in
                        guard let count = activeCompletion?.items.count, count > 0 else { return }
                        completionIndex = (completionIndex + delta + count) % count
                    },
                    onCompletionAccept: {
                        guard let completion = activeCompletion, !completion.items.isEmpty else { return }
                        let idx = min(completionIndex, completion.items.count - 1)
                        applyCompletion(completion.items[idx], mode: completion.mode)
                    },
                    onCompletionDismiss: { dismissCompletion() },
                    onAttachFiles: { incoming in handleIncomingFiles(incoming) }
                )
                .frame(height: editorHeight)

                controlsBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                // Shadow belongs on the backdrop shape, not the VStack: shadowing the container
                // forces Core Animation to re-rasterize the text view and animated harness canvas.
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(p.surface.opacity(0.6)))
                    .shadow(color: Color.black.opacity(0.10), radius: 10, y: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.border))
        }
        .padding(.horizontal, inline ? 0 : 20)
        .padding(.vertical, inline ? 0 : 12)
        .background(inline ? Color.clear : p.background)
        .overlay(alignment: .top) {
            if !inline {
                Rectangle().fill(p.rowBorder).frame(height: 1)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: Self.importerTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .onAppear {
            loadDraft(for: chatId)
            applyPrefill()
        }
        .task(id: chatId) { syncFollowupsWatch() }
        .onChange(of: session?.state) { oldState, newState in
            if oldState == .running && newState != .running, let req = followupsRequest {
                Task { _ = await context.store.refetch(req) }
            }
        }
        .onChange(of: prefill?.token) { _, _ in applyPrefill() }
        .onDisappear {
            cancelDictation()
            saveDraftImmediately(for: chatId)
            stopWatchingFollowups()
        }
        .onChange(of: chatId) { oldId, newId in
            cancelDictation()
            saveDraftImmediately(for: oldId)
            loadDraft(for: newId)
            attachments = []
            errorMessage = nil
            dictationSettingsURL = nil
            completionDismissedText = nil
            sendModeWhileRunning = .queue
        }
        .onChange(of: contextChips) { _, _ in
            saveDraftImmediately(for: chatId)
        }
        .onChange(of: speech.transcript) { _, next in
            guard speech.listening else { return }
            applyDictatedTranscript(next, save: false)
        }
        .onChange(of: speech.problem) { _, problem in
            guard let problem else { return }
            dictationAnchor = nil
            lastDictatedText = nil
            isPreparingDictation = false
            errorMessage = problem.message
            dictationSettingsURL = problem.settingsURL
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
            if let settingsURL = dictationSettingsURL {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(settingsURL)
                }
                .buttonStyle(.plain)
                .foregroundStyle(p.accent)
            }
            Button("Dismiss") {
                errorMessage = nil
                dictationSettingsURL = nil
                speech.clearProblem()
            }
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
                if speech.listening {
                    let activeColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
                    let activeBg = theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.14))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(activeColor)
                            .frame(width: 6, height: 6)
                            .scaleEffect(1 + CGFloat(speech.level) * 0.4)
                            .animation(.easeOut(duration: 0.08), value: speech.level)
                        Text(micPressStart != nil ? "Listening… release to finish" : "Listening… tap mic to finish")
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(activeColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(activeBg, in: Capsule())
                    .overlay(Capsule().stroke(activeColor.opacity(0.35)))
                }

                if canCode, let repoLabel = activeRepoLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                            .foregroundStyle(p.secondaryText)
                        Text(repoLabel)
                            .font(.system(size: theme.pointSize(.micro), design: .monospaced))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(p.surface, in: Capsule())
                    .overlay(Capsule().stroke(p.border))
                }

                if researchMode {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9))
                            .foregroundStyle(p.accent)
                        Text("Research plan")
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(p.accent)
                        Button {
                            researchMode = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(p.accent.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(p.selected, in: Capsule())
                    .overlay(Capsule().stroke(p.accent.opacity(0.5)))
                }

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
                sendModeSwitcher
            }

            dictateButton

            Button {
                cancelDictation()
                onStartLiveVoice()
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.secondaryText)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .help("Live Voice: talk with \(personaName) out loud")
            .accessibilityLabel("Start Live Voice")

            if isRunning && !hasDraftText && attachments.isEmpty {
                Button(action: cancelTurn) {
                    Label(isCancelling ? "Stopping…" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.vesper(.danger))
                .disabled(isCancelling)
            } else {
                let resolvedMode = ChatComposerSendLogic.resolveSendMode(
                    isRunning: isRunning,
                    preferredWhileRunning: sendModeWhileRunning,
                    parsedCommand: parsedSlashCommand
                )
                Button(action: submit) {
                    Label(isSending ? "Sending…" : resolvedMode.actionLabel, systemImage: resolvedMode.sendButtonSystemImage)
                }
                .buttonStyle(ChatSendButtonStyle(mode: resolvedMode))
                .disabled(!canSubmit)
                .help(resolvedMode.hint)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private var dictateButton: some View {
        let p = theme.palette
        let isListening = speech.listening
        let activeColor = theme.swiftUIColor("pill-blocked-fg", fallback: .red)
        let activeBg = theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.14))

        Group {
            if isPreparingDictation {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: isListening ? "mic.fill" : "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isListening ? activeColor : p.secondaryText)
                    .scaleEffect(isListening ? 1 + CGFloat(speech.level) * 0.16 : 1)
                    .animation(.easeOut(duration: 0.08), value: speech.level)
            }
        }
        .frame(width: 26, height: 22)
        .background(isListening ? activeBg : .clear, in: Capsule())
        .overlay(Capsule().stroke(isListening ? activeColor.opacity(0.35) : .clear))
        .contentShape(Capsule())
        .opacity(isSending ? 0.45 : 1)
        .allowsHitTesting(!isSending)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isSending, micPressStart == nil else { return }
                    micPressStart = Date()
                    micWasListeningBeforePress = speech.listening || isPreparingDictation
                    pendingReleaseStop = false
                    if !micWasListeningBeforePress {
                        startDictation()
                    }
                }
                .onEnded { _ in
                    guard let start = micPressStart else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    let wasListening = micWasListeningBeforePress
                    micPressStart = nil
                    micWasListeningBeforePress = false
                    let action = ChatComposerDictationLogic.releaseAction(
                        elapsedSeconds: elapsed,
                        wasListeningBeforePress: wasListening
                    )
                    if action == .stopAndCommit {
                        if speech.listening {
                            stopAndCommitDictation()
                        } else if isPreparingDictation {
                            pendingReleaseStop = true
                        }
                    }
                }
        )
        .help(dictationHelpText)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isListening ? "Stop dictation" : "Dictate (tap to toggle, hold for push-to-talk)")
    }

    private var dictationHelpText: String {
        if speech.listening { return "Stop dictation (release or tap)" }
        if isPreparingDictation {
            return speech.downloadingModel ? "Downloading on-device speech model…" : "Starting dictation…"
        }
        return "Dictate into message (tap to toggle, hold for push-to-talk)"
    }

    private var sendModeSwitcher: some View {
        let p = theme.palette
        return HStack(spacing: 2) {
            ForEach(ChatSendMode.runningModes) { mode in
                let isSelected = sendModeWhileRunning == mode
                let colors = sendModeColors(for: mode)
                Button {
                    sendModeWhileRunning = mode
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isSelected ? colors.fg : p.secondaryText)
                        .frame(width: 24, height: 22)
                        .background(isSelected ? colors.bg : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .help("\(mode.label): \(mode.hint)")
                .accessibilityLabel(mode.label)
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .frame(height: 28)
        .background(p.surface.opacity(0.8), in: Capsule())
        .overlay(Capsule().stroke(p.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send as")
    }

    private func sendModeColors(for mode: ChatSendMode) -> (fg: Color, bg: Color) {
        let p = theme.palette
        switch mode {
        case .send, .queue:
            return (p.accent, theme.swiftUIColor("accent-soft", fallback: p.selected))
        case .steer:
            return (
                theme.swiftUIColor("pill-done-fg", fallback: .green),
                theme.swiftUIColor("pill-done-bg", fallback: Color.green.opacity(0.15))
            )
        case .aside:
            return (
                theme.swiftUIColor("pill-review-fg", fallback: .blue),
                theme.swiftUIColor("pill-review-bg", fallback: Color.blue.opacity(0.15))
            )
        case .interrupt:
            return (
                theme.swiftUIColor("pill-human-fg", fallback: .orange),
                theme.swiftUIColor("pill-human-bg", fallback: Color.orange.opacity(0.15))
            )
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

    private enum CompletionMode: Equatable {
        case mention(ChatMentionTrigger)
        case slashCommand
        case slashArg(commandName: String)
    }

    private struct ResolvedCompletion: Equatable {
        let heading: String
        let mode: CompletionMode
        let items: [ChatCompletionItem]
    }

    private func handleDraftChange(text: String, cursorUTF16: Int, save: Bool) {
        if !isApplyingDictation, speech.listening, text != lastDictatedText {
            cancelDictation()
        }

        let nextHasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if nextHasText != hasDraftText {
            hasDraftText = nextHasText
        }

        let nextSlash: ChatParsedCommand? = text.hasPrefix("/") ? ChatSlashCommandLogic.parseCommand(text) : nil
        if nextSlash != parsedSlashCommand {
            parsedSlashCommand = nextSlash
        }

        if completionDismissedText != nil && completionDismissedText != text {
            completionDismissedText = nil
        }

        updateCompletion(text: text, cursorUTF16: cursorUTF16, resetIndex: true)

        if save {
            scheduleDraftSave(for: chatId)
        }
    }

    private func handleSelectionChange(text: String, cursorUTF16: Int) {
        // Only @mentions depend on cursor position; skip all work for normal prose without '@'.
        guard activeCompletion != nil || text.contains("@") else { return }
        updateCompletion(text: text, cursorUTF16: cursorUTF16, resetIndex: false)
    }

    private func updateCompletion(text: String, cursorUTF16: Int, resetIndex: Bool) {
        let next = resolvedCompletion(for: text, cursorUTF16: cursorUTF16)
        if next != activeCompletion {
            activeCompletion = next
            if completionIndex != 0 { completionIndex = 0 }
        } else if resetIndex && activeCompletion != nil && completionIndex != 0 {
            completionIndex = 0
        }
    }

    private func dismissCompletion() {
        completionDismissedText = editor.text
        if activeCompletion != nil {
            activeCompletion = nil
        }
    }

    private func setDraftProgrammatically(_ text: String, cursorUTF16: Int? = nil, save: Bool = true) {
        editor.setText(text, cursorUTF16: cursorUTF16)
        handleDraftChange(text: editor.text, cursorUTF16: editor.cursorUTF16, save: save)
    }

    private func resolvedCompletion(for text: String, cursorUTF16: Int) -> ResolvedCompletion? {
        if completionDismissedText == text { return nil }
        guard text.hasPrefix("/") || text.contains("@") else { return nil }

        if let menu = ChatSlashCommandLogic.commandMenu(for: text) {
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

        if let trigger = ChatMentionLogic.detectTrigger(in: text, cursorUTF16: cursorUTF16) {
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
        case "thinking":
            let options: [(value: String, subtitle: String)] = [
                ("on", "Stream thinking blocks live in the transcript"),
                ("off", "Keep full reasoning in the Activity tab"),
            ]
            return options
                .filter { q.isEmpty || $0.value.contains(q) }
                .map { opt in
                    ChatCompletionItem(
                        id: "thinking:\(opt.value)",
                        title: opt.value,
                        subtitle: opt.subtitle,
                        badge: (opt.value == "on") == showLiveThinking ? "current" : nil,
                        personaId: nil,
                        applyValue: opt.value
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
            let updated = ChatMentionLogic.insertMention(candidate, into: editor.text, trigger: trigger)
            setDraftProgrammatically(updated.text, cursorUTF16: updated.cursorUTF16)
        case .slashCommand:
            setDraftProgrammatically(item.applyValue)
        case .slashArg(let commandName):
            setDraftProgrammatically(ChatSlashCommandLogic.applyArgumentCompletion(commandName: commandName, argument: item.applyValue))
        }
    }

    private func insertAtMention(name: String) {
        let current = editor.text
        let prefix = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : " "
        setDraftProgrammatically(current + "\(prefix)@\(name) ")
    }

    // MARK: - Submission & Slash Commands

    private func submit() {
        cancelDictation()
        guard canSubmit else { return }
        errorMessage = nil
        dictationSettingsURL = nil

        if let cmd = ChatSlashCommandLogic.parseCommand(editor.text) {
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
        case "temp":
            clearComposer()
            if let onStartTemporaryChat {
                onStartTemporaryChat()
            } else {
                context.navigate("/chat?temporary=1")
            }
        case "stop":
            clearComposer()
            cancelTurn()
        case "memory":
            clearComposer()
            context.navigate("/memory")
        case "outline":
            clearComposer()
            onOpenOutline?()
        case "thinking":
            switch ChatSlashCommandLogic.resolveThinkingToggle(raw: cmd.arg, current: showLiveThinking) {
            case .set(let next):
                showLiveThinking = next
                clearComposer()
                context.showToast(ToastItemModel(
                    id: "chat.live-thinking",
                    title: next ? "Live thinking enabled" : "Live thinking hidden"
                ))
            case .error(let msg):
                errorMessage = msg
            }
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
        if let problem = ChatComposerSendLogic.textOnlyValidationError(
            mode: mode,
            hasAttachments: !attachments.isEmpty,
            hasContextChips: !contextChips.isEmpty,
            researchMode: researchMode
        ) {
            errorMessage = problem
            return
        }

        let uploadedIds = attachments.compactMap(\.uploadedId)
        let refs = ChatComposerContextLogic.toAPIContextRefs(contextChips)
        let prevDraft = editor.text
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
                setDraftProgrammatically(prevDraft)
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
        setDraftProgrammatically("", cursorUTF16: 0, save: false)
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
            contextChips = saved.chips
            setDraftProgrammatically(saved.text, save: false)
        } else {
            contextChips = []
            setDraftProgrammatically("", cursorUTF16: 0, save: false)
        }
    }

    /// Runs after `loadDraft` on appear, so a saved draft can't overwrite the prefill.
    private func applyPrefill() {
        guard let prefill else { return }
        setDraftProgrammatically(ChatComposerPrefill.merge(prefill.text, into: editor.text), save: false)
        saveDraftImmediately(for: chatId)
        onPrefillApplied?(prefill.token)
        // The text view may not be in a window yet on first appear.
        DispatchQueue.main.async { editor.focus() }
    }

    private func syncFollowupsWatch() {
        stopWatchingFollowups()
        guard let req = followupsRequest else { return }
        context.store.observe(req)
        context.store.load(req)
        watchedFollowupsKey = req.key
    }

    private func stopWatchingFollowups() {
        if let key = watchedFollowupsKey {
            context.store.stopObserving(key)
            watchedFollowupsKey = nil
        }
    }

    private func sendFollowupNow(_ body: String) async -> String? {
        await onSend(ChatComposerSubmission(
            body: body,
            mode: isRunning ? .interrupt : .send,
            attachmentIds: [],
            contextRefs: nil,
            research: false
        ))
    }

    private func editFollowupInComposer(_ body: String) {
        let merged = ChatFollowupLogic.mergeIntoDraft(body, existingDraft: editor.text)
        setDraftProgrammatically(merged, save: false)
        saveDraftImmediately(for: chatId)
        sendModeWhileRunning = .queue
        DispatchQueue.main.async { editor.focus() }
    }

    private func scheduleDraftSave(for id: String?) {
        draftSaveTask?.cancel()
        let snapshot = ChatComposerDraft(text: editor.text, chips: contextChips)
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
        draftStore.save(ChatComposerDraft(text: editor.text, chips: contextChips), chatId: id)
    }

    // MARK: - Dictation

    private func startDictation() {
        dictationFinishTask?.cancel()
        dictationFinishTask = nil
        dictationStartTask?.cancel()
        speech.clearProblem()
        errorMessage = nil
        dictationSettingsURL = nil
        isPreparingDictation = true

        dictationStartTask = Task {
            let ok = await speech.prepare()
            isPreparingDictation = false
            dictationStartTask = nil
            guard !Task.isCancelled, ok else { return }

            dictationAnchor = ChatComposerDictationLogic.anchor(in: editor.text, cursorUTF16: editor.cursorUTF16)
            lastDictatedText = editor.text
            speech.start()
            if !speech.listening {
                dictationAnchor = nil
                lastDictatedText = nil
                pendingReleaseStop = false
            } else if pendingReleaseStop {
                pendingReleaseStop = false
                stopAndCommitDictation()
            } else {
                editor.focus()
            }
        }
    }

    private func stopAndCommitDictation() {
        let anchor = dictationAnchor
        let settle = speech.finish()
        dictationFinishTask?.cancel()
        dictationFinishTask = Task {
            let finalText = await settle.value
            guard !Task.isCancelled else { return }
            if let anchor, !finalText.isEmpty {
                let composed = ChatComposerDictationLogic.compose(anchor: anchor, spoken: finalText)
                isApplyingDictation = true
                setDraftProgrammatically(composed.text, cursorUTF16: composed.cursorUTF16, save: true)
                isApplyingDictation = false
            } else {
                saveDraftImmediately(for: chatId)
            }
            dictationAnchor = nil
            lastDictatedText = nil
            dictationFinishTask = nil
            editor.focus()
        }
    }

    private func cancelDictation() {
        dictationStartTask?.cancel()
        dictationStartTask = nil
        dictationFinishTask?.cancel()
        dictationFinishTask = nil
        isPreparingDictation = false
        micPressStart = nil
        micWasListeningBeforePress = false
        pendingReleaseStop = false
        dictationAnchor = nil
        lastDictatedText = nil
        speech.stop()
    }

    private func applyDictatedTranscript(_ spoken: String, save: Bool) {
        guard let anchor = dictationAnchor else { return }
        let composed = ChatComposerDictationLogic.compose(anchor: anchor, spoken: spoken)
        isApplyingDictation = true
        lastDictatedText = composed.text
        setDraftProgrammatically(composed.text, cursorUTF16: composed.cursorUTF16, save: save)
        isApplyingDictation = false
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

/// Primary composer submit button tinted to match the active send mode (matches web `SendButton` tones).
private struct ChatSendButtonStyle: ButtonStyle {
    @Environment(\.vesperTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let mode: ChatSendMode

    func makeBody(configuration: Configuration) -> some View {
        let p = theme.palette
        let (fg, bg): (Color, Color) = switch mode {
        case .send, .queue:
            (theme.swiftUIColor("text-on-accent", fallback: .white), p.accent)
        case .steer:
            (theme.swiftUIColor("text-on-accent", fallback: .white), theme.swiftUIColor("state-done", fallback: .green))
        case .aside:
            (theme.swiftUIColor("text-on-accent", fallback: .white), theme.swiftUIColor("state-review", fallback: .blue))
        case .interrupt:
            (theme.swiftUIColor("approve-fg", fallback: .white), theme.swiftUIColor("state-human", fallback: .orange))
        }
        return configuration.label
            .font(.system(size: theme.pointSize(.body), weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(bg.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}
