import SwiftUI
import VesperCore

// MARK: - Tone Mapping Helper

extension Tone {
    var pillTone: String {
        switch self {
        case .human: "human"
        case .blocked, .danger: "blocked"
        case .done: "done"
        case .accent, .warning: "review"
        case .neutral: "neutral"
        }
    }
}

// MARK: - Choices Card

struct ChatChoicesCardView: View {
    @Environment(\.vesperTheme) private var theme

    let card: ChatChoicesCard
    let chosenOption: String?
    let disabled: Bool
    let onSelect: @MainActor (String) -> Void

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 8) {
            if !card.question.isEmpty {
                Text(card.question)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(card.options.enumerated()), id: \.offset) { _, option in
                    let isChosen = chosenOption == option.label
                    Button {
                        onSelect(ChatChoicesCard.choicePrompt(option.label))
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                .imageScale(.small)
                                .foregroundStyle(isChosen ? p.accent : p.tertiaryText)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label)
                                    .font(.system(size: theme.pointSize(.body), weight: .medium))
                                    .foregroundStyle(p.text)
                                if !option.detail.isEmpty {
                                    Text(option.detail)
                                        .font(.system(size: theme.pointSize(.small)))
                                        .foregroundStyle(p.secondaryText)
                                }
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(isChosen ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isChosen ? p.accent : p.border)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled || chosenOption != nil)
                }
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

// MARK: - Dispatch Card

struct ChatDispatchCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let messageId: String
    let card: ChatDispatchCard
    let runs: [API.ChatTicketRun]

    @State private var selectedKeys: Set<String> = []
    @State private var initialized = false
    @State private var isStarting = false
    @State private var errorMessage: String?

    private var runsByTicket: [String: API.ChatTicketRun] {
        var map: [String: API.ChatTicketRun] = [:]
        for run in runs where card.ticketKeys.contains(run.ticket) {
            if map[run.ticket] == nil || run.messageId == messageId {
                map[run.ticket] = run
            }
        }
        return map
    }

    private var startableKeys: [String] {
        card.ticketKeys.filter { key in
            guard let run = runsByTicket[key] else { return true }
            return ChatDispatchCard.runEnded(run.state)
        }
    }

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "play.square.stack")
                    .foregroundStyle(p.accent)
                Text(card.ticketKeys.count == 1 ? "Start ticket run" : "Start ticket runs (\(card.ticketKeys.count))")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                Spacer(minLength: 8)
                if !startableKeys.isEmpty {
                    Button {
                        startSelected()
                    } label: {
                        Text(isStarting ? "Starting…" : "Start (\(selectedKeys.intersection(startableKeys).count))")
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(isStarting || selectedKeys.intersection(startableKeys).isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(card.ticketKeys, id: \.self) { key in
                    ticketRow(key: key, run: runsByTicket[key])
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
        .onAppear {
            if !initialized {
                selectedKeys = Set(startableKeys)
                initialized = true
            }
        }
    }

    private func ticketRow(key: String, run: API.ChatTicketRun?) -> some View {
        let p = theme.palette
        let isStartable = run == nil || ChatDispatchCard.runEnded(run!.state)
        let isSelected = selectedKeys.contains(key)
        return HStack(spacing: 8) {
            if isStartable {
                Button {
                    if isSelected { selectedKeys.remove(key) } else { selectedKeys.insert(key) }
                } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? p.accent : p.tertiaryText)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "bolt.circle.fill")
                    .foregroundStyle(p.accent)
            }

            Button {
                context.navigate("/tickets/\(key)")
            } label: {
                Text(key)
                    .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)

            if let run {
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.ticketTitle)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                    let plan = ChatDispatchCard.planLine(
                        stepsTotal: run.stepsTotal,
                        stepsDone: run.stepsDone,
                        currentStep: run.currentStep
                    )
                    if !plan.isEmpty {
                        Text(plan)
                            .font(.system(size: theme.pointSize(.micro)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                let badge = ChatCardDisplay.stateBadge(for: run.state)
                TonePill(label: badge.label, tone: badge.tone.pillTone)
                Button("Run") {
                    context.navigate("/runs/\(run.runId)")
                }
                .buttonStyle(.vesper())
            } else {
                Spacer(minLength: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.rowBorder))
    }

    private func startSelected() {
        let keys = card.ticketKeys.filter { selectedKeys.contains($0) && startableKeys.contains($0) }
        guard !keys.isEmpty, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        Task {
            do {
                for key in keys {
                    _ = try await context.store.mutate(
                        API.startChatTicketRun(id: chatId, body: API.ChatTicketRunStart(messageId: messageId, ticket: key)),
                        invalidating: QueryInvalidation(resources: ["chats", "runs", "tickets"])
                    )
                }
                context.showToast(ToastItemModel(id: "chat.dispatch", title: "Started \(keys.count) run\(keys.count == 1 ? "" : "s")", tone: .success))
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            isStarting = false
        }
    }
}

// MARK: - Recommend Link / YouTube Cards

struct ChatRecommendCardsView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let messageId: String
    let cards: [ChatRecommendCard]
    let onSend: @MainActor (String) -> Void

    private var previewRequest: APIRequest<API.LinkPreviews> {
        API.listLinkPreviews(messageId: messageId)
    }

    var body: some View {
        let previews = context.store.entry(previewRequest).data?.previews ?? []
        let byURL = Dictionary(uniqueKeysWithValues: previews.map { ($0.url, $0) })

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                recommendCardRow(card: card, preview: byURL[card.url])
            }
        }
        .task(id: messageId) {
            context.store.load(previewRequest)
        }
    }

    private func recommendCardRow(card: ChatRecommendCard, preview: API.LinkPreview?) -> some View {
        let p = theme.palette
        let isVideo = card.youtubeVideoID != nil || preview?.kind == .video
        let title = (preview?.title.isEmpty == false ? preview?.title : nil) ?? hostLabel(card.url)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isVideo ? "play.rectangle.fill" : "safari")
                    .foregroundStyle(isVideo ? Color.red : p.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(preview?.site.isEmpty == false ? preview!.site : hostLabel(card.url))
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.tertiaryText)
                        if let secs = card.youtubeMomentSeconds {
                            TonePill(label: "@ \(ChatCardDisplay.mediaClock(ms: secs * 1000))", tone: "neutral")
                        }
                    }
                    if !card.note.isEmpty {
                        Text(card.note)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                    } else if let desc = preview?.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Button {
                    context.openExternal(card.url)
                } label: {
                    Label(isVideo ? "Watch" : "Open link", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.vesper())

                Button {
                    onSend(ChatRecommendCard.summarizePrompt(url: card.url, title: preview?.title, isVideo: isVideo))
                } label: {
                    Label("Summarize", systemImage: "text.alignleft")
                }
                .buttonStyle(.vesper())
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func hostLabel(_ raw: String) -> String {
        URL(string: raw)?.host ?? raw
    }
}

// MARK: - Workflow Run Card

struct ChatWorkflowRunCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let messageId: String
    let card: ChatWorkflowRunCard
    let runs: [API.WorkflowRun]

    @State private var isStarting = false
    @State private var errorMessage: String?

    private static let workflowsRequest = API.listWorkflows()

    private var matchingRun: API.WorkflowRun? {
        runs.first { $0.workflowId == card.workflowID && $0.messageId == messageId }
            ?? runs.first { $0.workflowId == card.workflowID }
    }

    var body: some View {
        let p = theme.palette
        let workflows = context.store.entry(Self.workflowsRequest).data?.workflows ?? []
        let workflowName = workflows.first(where: { $0.id == card.workflowID })?.name ?? "Workflow"

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "flowchart")
                    .foregroundStyle(p.accent)
                Text(workflowName)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                Spacer(minLength: 8)
                if let run = matchingRun {
                    let badge = ChatCardDisplay.stateBadge(for: run.state.rawValue)
                    TonePill(label: badge.label, tone: badge.tone.pillTone)
                }
            }

            if !card.input.isEmpty {
                Text(card.input)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(4)
            }

            HStack(spacing: 8) {
                if let run = matchingRun {
                    Button("Open workflow run") {
                        context.navigate("/workflows/runs/\(run.id)")
                    }
                    .buttonStyle(.vesper())
                } else {
                    Button {
                        startWorkflow()
                    } label: {
                        Label(isStarting ? "Starting…" : "Start workflow", systemImage: "play.fill")
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(isStarting)
                }
                Button("Edit workflow") {
                    context.navigate("/workflows/\(card.workflowID)")
                }
                .buttonStyle(.vesper())
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
        .task { context.store.load(Self.workflowsRequest) }
    }

    private func startWorkflow() {
        guard !isStarting else { return }
        isStarting = true
        errorMessage = nil
        Task {
            do {
                let run = try await context.store.mutate(
                    API.startChatWorkflow(
                        id: chatId,
                        body: API.WorkflowRunStart(input: card.input, messageId: messageId, workflowId: card.workflowID)
                    ),
                    invalidating: QueryInvalidation(resources: ["chats", "workflows"])
                )
                context.showToast(ToastItemModel(id: "chat.workflow", title: "Started \(run.name)", tone: .success))
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            isStarting = false
        }
    }
}

// MARK: - Research Plan Card

struct ChatResearchPlanCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let chatId: String
    let messageId: String
    let plan: ChatResearchPlanCard

    @State private var isStarting = false
    @State private var started = false
    @State private var errorMessage: String?

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(p.accent)
                Text(plan.title)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                Spacer(minLength: 8)
                if let length = plan.length {
                    TonePill(label: length.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, tone: "neutral")
                }
                if let tone = plan.tone {
                    TonePill(label: tone.rawValue.capitalized, tone: "neutral")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.questions.enumerated()), id: \.offset) { idx, q in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)
                        Text(q.question)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    startResearch()
                } label: {
                    Label(started ? "Research started" : isStarting ? "Starting…" : "Start research", systemImage: "play.fill")
                }
                .buttonStyle(.vesper(.primary))
                .disabled(isStarting || started)
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

    private func startResearch() {
        guard !isStarting, !started else { return }
        isStarting = true
        errorMessage = nil
        Task {
            do {
                let items = plan.questions.map {
                    API.ResearchStart.QuestionsItem(label: $0.label, question: $0.question)
                }
                let body = API.ResearchStart(
                    maxMinutes: 15,
                    maxSources: 30,
                    messageId: messageId,
                    questions: items,
                    reportLength: plan.length.flatMap { API.ResearchReportLength(rawValue: $0.rawValue) },
                    reportTone: plan.tone.flatMap { API.ResearchReportTone(rawValue: $0.rawValue) },
                    title: plan.title
                )
                _ = try await context.store.mutate(
                    API.startChatResearch(id: chatId, body: body),
                    invalidating: QueryInvalidation(resources: ["chats"])
                )
                started = true
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
            isStarting = false
        }
    }
}

// MARK: - Sources & Context Chips

struct ChatSourcesChipsView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let sources: [ChatListedSource]
    let citations: [API.ChatCitation]
    var messageId: String? = nil

    @State private var inspectedSourceIndex: Int?

    private var previewRequest: APIRequest<API.LinkPreviews>? {
        guard let messageId, !messageId.isEmpty, sources.contains(where: { !$0.url.isEmpty }) else { return nil }
        return API.listLinkPreviews(messageId: messageId)
    }

    var body: some View {
        let p = theme.palette
        let previews = previewRequest.flatMap { context.store.entry($0).data?.previews } ?? []
        let byURL = Dictionary(uniqueKeysWithValues: previews.map { ($0.url, $0) })

        if !sources.isEmpty || !citations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sources")
                    .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                    .textCase(.uppercase)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { idx, source in
                            sourceChip(source, index: idx, preview: byURL[source.url])
                        }
                        ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                            citationChip(citation)
                        }
                    }
                }
            }
            .padding(.top, 4)
            .task(id: messageId) {
                if let req = previewRequest {
                    context.store.load(req)
                }
            }
        }
    }

    private func sourceChip(_ source: ChatListedSource, index: Int, preview: API.LinkPreview?) -> some View {
        let p = theme.palette
        let label = (preview?.title.isEmpty == false ? preview?.title : nil)
            ?? (!source.title.isEmpty ? source.title : (source.ref ?? URL(string: source.url)?.host ?? source.url))
        return Button {
            inspectedSourceIndex = index
        } label: {
            HStack(spacing: 4) {
                if let n = source.number {
                    Text("\(n)")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold, design: .monospaced))
                        .foregroundStyle(p.accent)
                }
                Image(systemName: source.url.isEmpty ? "doc.text" : "globe")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
                Text(label)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { inspectedSourceIndex == index },
                set: { if !$0 && inspectedSourceIndex == index { inspectedSourceIndex = nil } }
            ),
            arrowEdge: .top
        ) {
            ChatCitationPopoverCardView(source: source, preview: preview) {
                inspectedSourceIndex = nil
            }
        }
    }

    private func citationChip(_ citation: API.ChatCitation) -> some View {
        let p = theme.palette
        let label = citation.title ?? citation.target.title
        return Button {
            if let href = citation.target.href, !href.isEmpty {
                context.navigate(href)
            } else if let path = citation.path, !path.isEmpty {
                context.navigate("/wiki/\(path)")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "book.closed")
                    .imageScale(.small)
                    .foregroundStyle(p.tertiaryText)
                Text(label)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().stroke(p.border))
        }
        .buttonStyle(.plain)
    }
}

struct ChatContextChipsView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let stripped: ChatStrippedContext
    let refs: [API.ChatContextRef]

    private var hasContext: Bool {
        !stripped.workContextLines.isEmpty
            || !stripped.knowledgeContextLines.isEmpty
            || !stripped.customAppContextLines.isEmpty
            || !refs.isEmpty
    }

    var body: some View {
        let p = theme.palette
        if hasContext {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(stripped.workContextLines, id: \.self) { line in
                        chip(icon: "hammer", text: line, palette: p)
                    }
                    ForEach(stripped.knowledgeContextLines, id: \.self) { line in
                        chip(icon: "book", text: line, palette: p)
                    }
                    ForEach(stripped.customAppContextLines, id: \.self) { line in
                        chip(icon: "app.dashed", text: line, palette: p)
                    }
                    ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                        let label = ref.key ?? ref.id ?? ref.kind.rawValue
                        chip(icon: "link", text: "\(ref.kind.rawValue): \(label)", palette: p)
                    }
                }
            }
        }
    }

    private func chip(icon: String, text: String, palette p: NativePalette) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(p.tertiaryText)
            Text(text)
                .font(.system(size: theme.pointSize(.micro)))
                .foregroundStyle(p.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(p.surface, in: Capsule())
        .overlay(Capsule().stroke(p.rowBorder))
    }
}
