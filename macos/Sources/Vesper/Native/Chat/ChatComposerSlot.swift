import SwiftUI
import VesperCore

/// Native composer slot for `/chat` and `/chat/:id` (LAZYAGENTS-286).
/// Wraps `ChatComposerView` so `ChatScreen` keeps a clean seam boundary.
struct ChatComposerSlot: View {
    let chatId: String?
    let session: API.ChatSession?
    let personas: [API.Persona]
    let activePersona: API.Persona?
    let harnessModels: [API.ChatHarnessModels]
    let harnesses: [API.HarnessActivity]
    let workflows: [API.Workflow]
    let repositories: [API.RepositoryEntry]
    var promptTemplates: [API.PromptTemplate] = []
    var spaces: [API.ChatSpace] = []

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
    var onEditLastUserMessage: (@MainActor () -> Bool)? = nil
    var prefill: ChatComposerPrefill? = nil
    var onPrefillApplied: (@MainActor (Int) -> Void)? = nil
    var livePlanProgress: ChatPlanProgress? = nil
    var livePlanTurnKey: String = ""
    var inline: Bool = false
    var autoFocusOnSwitch: Bool = true
    var placeholderOverride: String? = nil

    var body: some View {
        ChatComposerView(
            chatId: chatId,
            session: session,
            personas: personas,
            activePersona: activePersona,
            harnessModels: harnessModels,
            harnesses: harnesses,
            workflows: workflows,
            repositories: repositories,
            promptTemplates: promptTemplates,
            spaces: spaces,
            selectedHarness: $selectedHarness,
            selectedModel: $selectedModel,
            selectedEffort: $selectedEffort,
            selectedRepoUrl: $selectedRepoUrl,
            onSelectNewChatPersona: onSelectNewChatPersona,
            onSend: onSend,
            onCancel: onCancel,
            onSetRepository: onSetRepository,
            onCompact: onCompact,
            onStartWorkflow: onStartWorkflow,
            onStartMusic: onStartMusic,
            onCompare: onCompare,
            onStartLiveVoice: onStartLiveVoice,
            onOpenOutline: onOpenOutline,
            onStartTemporaryChat: onStartTemporaryChat,
            onEditLastUserMessage: onEditLastUserMessage,
            prefill: prefill,
            onPrefillApplied: onPrefillApplied,
            livePlanProgress: livePlanProgress,
            livePlanTurnKey: livePlanTurnKey,
            inline: inline,
            autoFocusOnSwitch: autoFocusOnSwitch,
            placeholderOverride: placeholderOverride
        )
    }
}
