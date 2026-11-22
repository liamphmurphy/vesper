import SwiftUI
import VesperCore

/// Pure SwiftUI composer for `/tickets/new` (optional `?project=`, `?status=`, `?epic=`, `?title=`).
/// Zero AppKit imports; persists drafts via `TicketsLogic` and creates tickets via `API.createTicket`.
struct NewTicketScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var draft = TicketsLogic.NewTicketDraft()
    @State private var estimateRationale = ""
    @State private var newCriterion = ""
    @State private var restoredDraft = false
    @State private var loadedInitial = false
    @State private var submitting = false
    @State private var errorMessage: String?

    private static let bootstrapRequest = API.getBootstrap()

    private var boot: API.Bootstrap? {
        context.store.entry(Self.bootstrapRequest).data
    }

    private var activeProjects: [API.Project] {
        (boot?.projects ?? []).filter { !$0.archived }
    }

    private var selectedProject: API.Project? {
        if !draft.projectKey.isEmpty, let found = activeProjects.first(where: { $0.key == draft.projectKey }) {
            return found
        }
        return activeProjects.first
    }

    private var resolvedProjectKey: String {
        selectedProject?.key ?? draft.projectKey
    }

    private var projectEpics: [API.Epic] {
        guard let projectId = selectedProject?.id else { return [] }
        return (boot?.epics ?? []).filter { $0.projectId == projectId }
    }

    private var assignableAgents: [API.Agent] {
        (boot?.agents ?? []).filter { $0.kind == .main }
    }

    private var canSubmit: Bool {
        !submitting
            && !resolvedProjectKey.isEmpty
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerBar
                if boot != nil && selectedProject == nil {
                    Text("No active project is available. Create or unarchive a project before creating a ticket.")
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.secondaryText)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                titleAndDescriptionSection
                propertiesSection
                estimateSection
                labelsSection
                criteriaSection
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
                footerBar
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(theme.palette.background)
        .onAppear {
            context.store.observe(Self.bootstrapRequest)
            context.chrome = NativeChrome(title: "New Ticket", subtitle: resolvedProjectKey.isEmpty ? nil : resolvedProjectKey)
            initializeFromRouteIfNeeded()
        }
        .onDisappear {
            context.store.stopObserving(Self.bootstrapRequest.key)
        }
        .onChange(of: context.match) { _, _ in
            loadedInitial = false
            initializeFromRouteIfNeeded()
        }
        .onChange(of: draft) { _, updated in
            guard loadedInitial else { return }
            let key = resolvedProjectKey.isEmpty ? nil : resolvedProjectKey
            TicketsLogic.saveDraft(updated, to: .standard, projectKey: key)
        }
    }

    // MARK: - Sections

    private var headerBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(activeProjects, id: \.id) { project in
                    Button {
                        switchProject(to: project.key)
                    } label: {
                        HStack {
                            Text("\(project.name) (\(project.key))")
                            if project.key == resolvedProjectKey {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let project = selectedProject {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(cssHex: project.color) ?? theme.palette.accent)
                            .frame(width: 9, height: 9)
                        Text(project.name)
                    } else {
                        Text("Select project")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.palette.tertiaryText)
                }
                .font(.system(size: theme.pointSize(.small), weight: .medium))
                .foregroundStyle(theme.palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.palette.border))
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.tertiaryText)

            Text("New ticket")
                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                .foregroundStyle(theme.palette.text)

            Spacer()

            if restoredDraft {
                HStack(spacing: 6) {
                    Text("Draft restored")
                        .font(.system(size: theme.pointSize(.small)))
                        .foregroundStyle(theme.palette.secondaryText)
                    Button("Discard") {
                        discardDraft()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: theme.pointSize(.small), weight: .medium))
                }
            }
        }
    }

    private var titleAndDescriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ticket title", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.palette.text)
                .padding(.vertical, 4)

            ZStack(alignment: .topLeading) {
                if draft.descriptionMd.isEmpty {
                    Text("Add a markdown description. Say what done looks like and what\u{2019}s out of scope.")
                        .font(.system(size: theme.pointSize(.body)))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.descriptionMd)
                    .font(.system(size: theme.pointSize(.body)))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
            }
            .padding(8)
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
        }
    }

    private var propertiesSection: some View {
        HStack(spacing: 12) {
            Picker("Status", selection: $draft.statusRaw) {
                ForEach(TicketsLogic.statusOrder, id: \.rawValue) { status in
                    Text(TicketsLogic.statusLabel(status)).tag(status.rawValue)
                }
            }
            .pickerStyle(.menu)

            Picker("Priority", selection: $draft.priorityRaw) {
                ForEach(TicketsLogic.priorityOrder, id: \.rawValue) { priority in
                    Text(TicketsLogic.priorityLabel(priority)).tag(priority.rawValue)
                }
            }
            .pickerStyle(.menu)

            Picker("Epic", selection: $draft.epicId) {
                Text("No epic").tag(Optional<String>.none)
                ForEach(projectEpics, id: \.id) { epic in
                    Text(epic.name).tag(Optional(epic.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Agent", selection: $draft.assigneeAgentId) {
                Text("Unassigned").tag(Optional<String>.none)
                ForEach(assignableAgents, id: \.id) { agent in
                    Text(agent.name).tag(Optional(agent.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Estimate")
                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                .foregroundStyle(theme.palette.secondaryText)
            HStack(spacing: 8) {
                Picker("Points", selection: $draft.estimatePoints) {
                    Text("None").tag(Optional<Int>.none)
                    ForEach(TicketsLogic.estimateScale, id: \.self) { pts in
                        Text("\(pts) pt\(pts == 1 ? "" : "s")").tag(Optional(pts))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                TextField("Estimate rationale (optional)", text: $estimateRationale)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var labelsSection: some View {
        let allLabels = boot?.labels ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text("Labels")
                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                .foregroundStyle(theme.palette.secondaryText)
            if allLabels.isEmpty {
                Text("No labels configured.")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(allLabels, id: \.id) { label in
                        let selected = draft.labelIds.contains(label.id)
                        Button {
                            toggleLabel(label.id)
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(cssHex: label.color) ?? theme.palette.secondaryText)
                                    .frame(width: 6, height: 6)
                                Text(label.name)
                                    .font(.system(size: theme.pointSize(.small)))
                                    .lineLimit(1)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                selected ? theme.palette.accent.opacity(0.16) : theme.palette.surface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(selected ? theme.palette.accent : theme.palette.border)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var criteriaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance criteria")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(theme.palette.secondaryText)
                Spacer()
                Text("Agents verify these before finishing")
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(theme.palette.tertiaryText)
            }

            ForEach(Array(draft.criteria.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    Image(systemName: "square")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.tertiaryText)
                    TextField("Criterion \(index + 1)", text: criterionBinding(at: index))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        draft.criteria.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Remove criterion")
                }
            }

            HStack(spacing: 8) {
                TextField("Add acceptance criterion\u{2026}", text: $newCriterion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { appendNewCriterion() }
                Button("Add") {
                    appendNewCriterion()
                }
                .disabled(newCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") {
                let target = resolvedProjectKey.isEmpty
                    ? "/tickets"
                    : TicketsLogic.ticketsHref(query: ["project": resolvedProjectKey])
                context.navigate(target)
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button(submitting ? "Creating\u{2026}" : "Create ticket") {
                Task { await submit() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func initializeFromRouteIfNeeded() {
        guard !loadedInitial else { return }
        let queryProject = context.match.query["project"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageProject = (queryProject?.isEmpty == false) ? queryProject : nil

        if let saved = TicketsLogic.loadDraft(from: .standard, projectKey: storageProject), saved.isMeaningful {
            draft = saved
            if let storageProject, draft.projectKey.isEmpty {
                draft.projectKey = storageProject
            }
            restoredDraft = true
        } else {
            var fresh = TicketsLogic.NewTicketDraft()
            if let storageProject { fresh.projectKey = storageProject }
            if let statusRaw = context.match.query["status"],
               TicketsLogic.statusOrder.contains(where: { $0.rawValue == statusRaw }) {
                fresh.statusRaw = statusRaw
            }
            if let epic = context.match.query["epic"], !epic.isEmpty {
                fresh.epicId = epic
            }
            if let title = context.match.query["title"], !title.isEmpty {
                fresh.title = title
            }
            draft = fresh
            restoredDraft = false
        }
        loadedInitial = true
    }

    private func switchProject(to key: String) {
        draft.projectKey = key
        draft.epicId = nil
        context.chrome = NativeChrome(title: "New Ticket", subtitle: key)
    }

    private func discardDraft() {
        let key = resolvedProjectKey.isEmpty ? nil : resolvedProjectKey
        TicketsLogic.clearDraft(from: .standard, projectKey: key)
        draft = TicketsLogic.NewTicketDraft(projectKey: resolvedProjectKey)
        estimateRationale = ""
        newCriterion = ""
        restoredDraft = false
    }

    private func toggleLabel(_ id: String) {
        if let idx = draft.labelIds.firstIndex(of: id) {
            draft.labelIds.remove(at: idx)
        } else {
            draft.labelIds.append(id)
        }
    }

    private func criterionBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { draft.criteria.indices.contains(index) ? draft.criteria[index] : "" },
            set: { newValue in
                if draft.criteria.indices.contains(index) {
                    draft.criteria[index] = newValue
                }
            }
        )
    }

    private func appendNewCriterion() {
        let trimmed = newCriterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft.criteria.append(trimmed)
        newCriterion = ""
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }

        if !newCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendNewCriterion()
        }

        var payload = draft.toNewTicket(resolvedProjectKey: resolvedProjectKey)
        let trimmedRationale = estimateRationale.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.estimate = trimmedRationale.isEmpty ? nil : trimmedRationale

        do {
            let created = try await context.store.mutate(
                API.createTicket(body: payload),
                invalidating: QueryInvalidation(resources: ["tickets", "board", "boards", "epics", "inbox", "planning"])
            )
            TicketsLogic.clearDraft(from: .standard, projectKey: resolvedProjectKey)
            TicketsLogic.clearDraft(from: .standard, projectKey: nil)
            context.showToast(ToastItemModel(id: "ticket.created.\(created.key)", title: "Created \(created.key)", tone: .success))
            context.navigate(TicketsLogic.ticketHref(created.key))
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            errorMessage = msg
            context.showToast(ToastItemModel(id: "ticket.create.err", title: "Couldn\u{2019}t create ticket", description: msg, tone: .error))
        }
    }
}
