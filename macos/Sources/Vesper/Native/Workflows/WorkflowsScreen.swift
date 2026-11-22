import SwiftUI
import VesperCore

/// `/workflows`: lists all workflows with create/delete actions and recent workflow runs.
struct WorkflowsScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var newName = ""
    @State private var creating = false
    @State private var deletingId: String?
    @State private var pendingDelete: API.Workflow?
    @State private var actionError: String?

    private static let workflowsRequest = API.listWorkflows()
    private static let runsRequest = API.listWorkflowRuns()

    private var workflowsEntry: QueryEntry<API.Workflows> {
        context.store.entry(Self.workflowsRequest)
    }

    private var runsEntry: QueryEntry<API.WorkflowRuns> {
        context.store.entry(Self.runsRequest)
    }

    var body: some View {
        let workflows = workflowsEntry.data?.workflows ?? []
        let runs = Array((runsEntry.data?.runs ?? []).prefix(20))

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let message = actionError ?? workflowsEntry.error?.userMessage {
                    errorBanner(message)
                }

                if !workflows.isEmpty {
                    createForm
                }

                if workflowsEntry.data == nil && workflowsEntry.error == nil {
                    SkeletonBar(height: 96)
                } else if workflows.isEmpty {
                    emptyState
                } else {
                    workflowList(workflows)
                }

                if !runs.isEmpty {
                    recentRunsSection(runs)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            context.store.load(Self.workflowsRequest)
            context.store.load(Self.runsRequest)
        }
        .onAppear {
            context.store.observe(Self.workflowsRequest)
            context.store.observe(Self.runsRequest)
            publishChrome(workflows: workflows, runs: runs)
            context.onCommand = { handleCommand($0) }
        }
        .onChange(of: workflows.map(\.id)) { _, _ in
            publishChrome(workflows: workflows, runs: runs)
        }
        .onChange(of: runs.map(\.id)) { _, _ in
            publishChrome(workflows: workflows, runs: runs)
        }
        .onDisappear {
            context.store.stopObserving(Self.workflowsRequest.key)
            context.store.stopObserving(Self.runsRequest.key)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "workflow")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete workflow", role: .destructive) {
                if let target = pendingDelete {
                    Task { await deleteWorkflow(target) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Runs already started keep going.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Workflows")
                .vesperText(.display, theme)
            Text("Fixed sequences of steps Vesper runs for you. Start one from a chat with /workflow, or ask a persona and confirm its suggestion.")
                .vesperText(.reading, theme)
                .foregroundStyle(theme.palette.secondaryText)
        }
    }

    private var createForm: some View {
        HStack(spacing: 8) {
            TextField("New workflow name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
                .onSubmit {
                    if !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { await createWorkflow() }
                    }
                }
            Button(creating ? "Creating…" : "Create") {
                Task { await createWorkflow() }
            }
            .buttonStyle(.vesper(.primary))
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No workflows yet")
                .vesperText(.heading, theme)
            Text("Name your first one below, or ask a persona in a chat to build one with you.")
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
            createForm
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border))
    }

    private func workflowList(_ workflows: [API.Workflow]) -> some View {
        VStack(spacing: 8) {
            ForEach(workflows, id: \.id) { workflow in
                HStack(spacing: 12) {
                    Button {
                        context.navigate("/workflows/\(workflow.id)")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(workflow.name)
                                .vesperText(.body, theme)
                                .fontWeight(.semibold)
                            if !workflow.description.isEmpty {
                                Text(workflow.description)
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(versionBadge(workflow))
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(theme.palette.tertiaryText)

                    Button("Delete") {
                        pendingDelete = workflow
                    }
                    .buttonStyle(.vesper(.outline))
                    .disabled(deletingId == workflow.id)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
            }
        }
    }

    private func recentRunsSection(_ runs: [API.WorkflowRun]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent runs")
                .vesperText(.heading, theme)
            VStack(spacing: 4) {
                ForEach(runs, id: \.id) { run in
                    Button {
                        context.navigate("/workflows/runs/\(run.id)")
                    } label: {
                        HStack(spacing: 12) {
                            Text(run.name)
                                .vesperText(.body, theme)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(run.input)
                                .vesperText(.small, theme)
                                .foregroundStyle(theme.palette.tertiaryText)
                                .lineLimit(1)
                                .frame(maxWidth: 280, alignment: .trailing)
                            TonePill(
                                label: WorkflowsLogic.runStateLabel(run.state),
                                tone: WorkflowsLogic.runStateTone(run.state)
                            )
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(theme.palette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .vesperText(.body, theme)
                .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            Spacer()
        }
        .padding(12)
        .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)), in: RoundedRectangle(cornerRadius: 8))
    }

    private func versionBadge(_ w: API.Workflow) -> String {
        if w.publishedVersion > 0 {
            return "v\(w.publishedVersion)\(w.unpublishedChanges ? " · edited" : "")"
        }
        return "Draft"
    }

    private func createWorkflow() async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creating = true
        actionError = nil
        defer { creating = false }
        do {
            let created = try await context.store.mutate(API.createWorkflow(body: API.NewWorkflow(description: nil, name: trimmed)))
            newName = ""
            context.store.setData(created, for: API.getWorkflow(id: created.id))
            _ = await context.store.refetch(Self.workflowsRequest)
            context.navigate("/workflows/\(created.id)")
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteWorkflow(_ workflow: API.Workflow) async {
        deletingId = workflow.id
        actionError = nil
        defer { deletingId = nil; pendingDelete = nil }
        do {
            _ = try await context.store.mutate(API.deleteWorkflow(id: workflow.id))
            _ = await context.store.refetch(Self.workflowsRequest)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func publishChrome(workflows: [API.Workflow], runs: [API.WorkflowRun]) {
        context.chrome = NativeChrome(
            title: "Workflows",
            navigator: WorkflowsLogic.buildWorkflowsNavModel(workflows: workflows, runs: runs)
        )
    }

    private func handleCommand(_ command: NativeCommand) {
        if case .navActivate(let navId, let itemId, let newTab) = command, navId == WorkflowsLogic.workflowsNavId {
            let path = itemId.hasPrefix("run:")
                ? "/workflows/runs/\(itemId.dropFirst(4))"
                : "/workflows/\(itemId)"
            if newTab { context.openInNewTab(path) } else { context.navigate(path) }
        }
    }
}
