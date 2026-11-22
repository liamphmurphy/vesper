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
            activeTicketRuns: activeTicketRuns,
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
            onCompare: onCompare
        )
    }
}
