import SwiftUI
import VesperCore

/// Pure-SwiftUI Scheduled tasks screen (`/scheduled`). Zero AppKit imports.
struct ScheduledScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var filter: ScheduledLogic.Filter = .all
    @State private var selectedId: String? = nil
    @State private var draft = ScheduledLogic.TaskDraft.blank()
    @State private var isCreating = false
    @State private var validationErrors: [String] = []
    @State private var saveError: String? = nil
    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var watched: [QueryKey] = []

    private static let tasksRequest = API.listScheduledTasks()
    private static let personasRequest = API.listPersonas()
    private static let bootstrapRequest = API.getBootstrap()
    private static let workflowsRequest = API.listWorkflows()

    var body: some View {
        let store = context.store
        let tasksEntry = store.entry(Self.tasksRequest)
        let tasks = tasksEntry.data?.tasks ?? []
        let personas = store.entry(Self.personasRequest).data?.personas ?? []
        let projects = (store.entry(Self.bootstrapRequest).data?.projects ?? []).filter { !$0.archived }
        let workflows = (store.entry(Self.workflowsRequest).data?.workflows ?? []).filter { $0.publishedVersion > 0 }
        let selectedTask = isCreating ? nil : tasks.first(where: { $0.id == selectedId }) ?? tasks.first

        Group {
            if tasksEntry.data == nil && tasksEntry.error == nil {
                VStack(spacing: 12) {
                    SkeletonBar(height: 32)
                    SkeletonBar(height: 120)
                }
                .padding(24)
            } else if let error = tasksEntry.error, tasksEntry.data == nil {
                QueryErrorView(message: error.userMessage) {
                    Task { _ = await store.refetch(Self.tasksRequest) }
                }
            } else if !isCreating && selectedTask == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerRow(task: selectedTask)
                        if !validationErrors.isEmpty {
                            errorBanner(validationErrors.joined(separator: " "))
                        }
                        if let saveError {
                            errorBanner(saveError)
                        }
                        formBody(personas: personas, projects: projects, workflows: workflows)
                        if let task = selectedTask {
                            upcomingAndRuns(task: task)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 780, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: chrome(tasks: tasks, activeId: isCreating ? "new" : selectedTask?.id), initial: true) { _, next in
            context.chrome = next
        }
        .onChange(of: selectedTask?.id) { _, _ in
            if !isCreating, let task = selectedTask {
                draft = ScheduledLogic.TaskDraft.from(task)
                validationErrors = []
                saveError = nil
            }
        }
        .task(id: context.match) {
            if let qId = context.match.query["id"], !qId.isEmpty {
                isCreating = false
                selectedId = qId
            }
            watch()
        }
        .onAppear {
            context.onCommand = { command in handle(command, tasks: tasks) }
            if !isCreating, let task = selectedTask {
                draft = ScheduledLogic.TaskDraft.from(task)
            }
        }
        .onDisappear {
            for key in watched { context.store.stopObserving(key) }
            watched = []
        }
        .alert("Delete scheduled task?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let task = selectedTask { Task { await deleteTask(task) } }
            }
        } message: {
            Text("This removes the task and stops future scheduled runs.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 28))
                .foregroundStyle(theme.palette.secondaryText)
            Text("No scheduled tasks yet")
                .font(.headline)
            Text("Create a recurring prompt, workflow, or Custom App task.")
                .font(.callout)
                .foregroundStyle(theme.palette.secondaryText)
            Button("Create scheduled task") { beginNewTask() }
                .buttonStyle(.vesper(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headerRow(task: API.ScheduledTask?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isCreating ? "New scheduled task" : (task?.name ?? "Scheduled task"))
                    .font(.title2.weight(.semibold))
                if let task {
                    Text(ScheduledLogic.describeSchedule(task))
                        .font(.callout)
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }
            Spacer()
            if let task {
                Button("Run now") { Task { await runNow(task) } }
                    .buttonStyle(.vesper())
                    .disabled(isSaving)
                Button("Delete") { showDeleteConfirm = true }
                    .buttonStyle(.vesper(.danger))
                    .disabled(isSaving)
            }
            Button(isCreating ? "Create" : "Save") { Task { await save(existing: task) } }
                .buttonStyle(.vesper(.primary))
                .disabled(isSaving)
        }
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.swiftUIColor("pill-blocked-bg", fallback: Color.red.opacity(0.1)), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func formBody(personas: [API.Persona], projects: [API.Project], workflows: [API.Workflow]) -> some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(p.secondaryText)
                    TextField("Morning brief", text: $draft.name).textFieldStyle(.roundedBorder)
                }
                Toggle("Enabled", isOn: $draft.enabled).toggleStyle(.switch).padding(.top, 16)
            }

            HStack(spacing: 12) {
                Picker("Kind", selection: $draft.kind) {
                    Text("Prompt").tag(API.ScheduledTaskInput.Kind.prompt)
                    Text("Workflow").tag(API.ScheduledTaskInput.Kind.workflow)
                    Text("Custom App").tag(API.ScheduledTaskInput.Kind.customApp)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            if draft.kind == .workflow {
                Picker("Workflow", selection: Binding(get: { draft.workflowId ?? "" }, set: { draft.workflowId = $0.isEmpty ? nil : $0 })) {
                    Text("Choose workflow…").tag("")
                    ForEach(workflows, id: \.id) { wf in
                        Text(wf.name).tag(wf.id)
                    }
                }
            }

            if draft.kind == .customApp {
                HStack(spacing: 12) {
                    TextField("App slug", text: Binding(get: { draft.customAppSlug ?? "" }, set: { draft.customAppSlug = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                    TextField("Tool name", text: Binding(get: { draft.customAppTool ?? "" }, set: { draft.customAppTool = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments (JSON object)").font(.caption).foregroundStyle(p.secondaryText)
                    TextEditor(text: $draft.customAppArgsText)
                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                        .frame(minHeight: 64)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            } else {
                HStack(spacing: 12) {
                    Picker("Persona", selection: Binding(get: { draft.personaId ?? "" }, set: { draft.personaId = $0.isEmpty ? nil : $0 })) {
                        Text("Default").tag("")
                        ForEach(personas, id: \.id) { person in
                            Text(person.name).tag(person.id)
                        }
                    }
                    Picker("Space", selection: Binding(get: { draft.project ?? "" }, set: { draft.project = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(projects, id: \.key) { proj in
                            Text(proj.name).tag(proj.key)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions").font(.caption).foregroundStyle(p.secondaryText)
                    TextEditor(text: $draft.instructions)
                        .frame(minHeight: 96)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                }
            }

            Divider()

            HStack(spacing: 12) {
                Picker("Frequency", selection: $draft.frequency) {
                    Text("Hourly").tag(API.ScheduledTaskInput.Frequency.hourly)
                    Text("Daily").tag(API.ScheduledTaskInput.Frequency.daily)
                    Text("Weekly").tag(API.ScheduledTaskInput.Frequency.weekly)
                    Text("Monthly").tag(API.ScheduledTaskInput.Frequency.monthly)
                    Text("Cron").tag(API.ScheduledTaskInput.Frequency.cron)
                }
                .frame(maxWidth: 220)

                if draft.frequency != .hourly && draft.frequency != .cron {
                    TextField("HH:MM", text: $draft.atTime).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                TextField("Time zone", text: $draft.timezone).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            }

            if draft.frequency == .weekly {
                HStack(spacing: 6) {
                    ForEach(ScheduledLogic.weekdayButtons, id: \.day) { item in
                        let selected = draft.weekdays.contains(item.day)
                        Button(item.letter) {
                            if selected {
                                draft.weekdays.removeAll { $0 == item.day }
                            } else {
                                draft.weekdays.append(item.day)
                                draft.weekdays.sort()
                            }
                        }
                        .buttonStyle(.vesper(selected ? .primary : .outline))
                        .help(item.full)
                    }
                }
            } else if draft.frequency == .monthly {
                Stepper("Day of month: \(draft.monthDay)", value: $draft.monthDay, in: 1...31)
            } else if draft.frequency == .cron {
                let check = ScheduledLogic.validateCron(draft.cron)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("0 8 * * 1-5", text: $draft.cron)
                        .font(.system(size: theme.pointSize(.mono), design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Text(check.summary)
                        .font(.caption)
                        .foregroundStyle(check.isValid ? p.secondaryText : theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                }
            }

            HStack(spacing: 16) {
                Stepper("Time limit: \(draft.maxMinutes)m", value: $draft.maxMinutes, in: 1...240)
                if draft.kind != .customApp {
                    let dollars = Double(draft.maxCostMicros) / 1_000_000.0
                    Stepper("Budget: \(ScheduledLogic.moneyLabel(micros: draft.maxCostMicros))", value: Binding(
                        get: { dollars },
                        set: { draft.maxCostMicros = max(10_000, Int(($0 * 1_000_000.0).rounded())) }
                    ), in: 0.25...50.0, step: 0.25)
                }
            }
        }
        .padding(16)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    @ViewBuilder
    private func upcomingAndRuns(task: API.ScheduledTask) -> some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 10) {
            if !task.upcoming.isEmpty {
                Text("Upcoming").font(.headline)
                HStack(spacing: 12) {
                    ForEach(task.upcoming, id: \.self) { iso in
                        Text(APIDate.short(iso))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(p.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(p.border))
                    }
                }
            }
            Text("Recent runs").font(.headline)
            if task.runs.isEmpty {
                Text("No runs yet.").font(.callout).foregroundStyle(p.secondaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(task.runs, id: \.id) { run in
                        HStack(spacing: 10) {
                            TonePill(label: ScheduledLogic.runStateLabel(run.state), tone: ScheduledLogic.runStateTone(run.state))
                            Text(run.summary.isEmpty ? APIDate.short(run.startedAt) : run.summary)
                                .lineLimit(1)
                            Spacer()
                            if run.costMicros > 0 {
                                Text(ScheduledLogic.moneyLabel(micros: run.costMicros))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(p.secondaryText)
                            }
                            if let href = run.href, !href.isEmpty {
                                Button("Open") { context.navigate(href) }
                                    .buttonStyle(.vesper())
                            }
                        }
                        .padding(10)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                    }
                }
            }
        }
    }

    private func chrome(tasks: [API.ScheduledTask], activeId: String?) -> NativeChrome {
        NativeChrome(
            title: "Scheduled",
            toolbarItems: [
                ShellToolbarItem(id: "scheduled.new", label: "New task", icon: "plus", kind: .button, accent: true, showsLabel: true),
            ],
            navigator: ScheduledLogic.navModel(tasks: tasks, filter: filter, selectedId: activeId)
        )
    }

    private func watch() {
        let store = context.store
        for key in watched { store.stopObserving(key) }
        func start<V: Sendable>(_ req: APIRequest<V>) -> QueryKey {
            store.observe(req)
            store.load(req)
            return req.key
        }
        watched = [start(Self.tasksRequest), start(Self.personasRequest), start(Self.bootstrapRequest), start(Self.workflowsRequest)]
    }

    private func beginNewTask() {
        isCreating = true
        selectedId = nil
        draft = ScheduledLogic.TaskDraft.blank()
        validationErrors = []
        saveError = nil
    }

    private func handle(_ command: NativeCommand, tasks: [API.ScheduledTask]) {
        if case .toolbarAction(itemId: "scheduled.new", _) = command {
            beginNewTask()
            return
        }
        guard let action = ScheduledLogic.navAction(for: command) else { return }
        switch action {
        case .newTask:
            beginNewTask()
        case .selectTask(let id):
            isCreating = false
            selectedId = id
            if let task = tasks.first(where: { $0.id == id }) {
                draft = ScheduledLogic.TaskDraft.from(task)
            }
        case .filter(let next):
            filter = next
        }
    }

    private func save(existing: API.ScheduledTask?) async {
        let result = ScheduledLogic.validate(draft)
        validationErrors = result.errors
        guard result.isValid else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let input = draft.toInput(parsedArgs: result.parsedArgs)
        do {
            let saved: API.ScheduledTask
            if let existing, !isCreating {
                saved = try await context.store.mutate(
                    API.updateScheduledTask(id: existing.id, body: input),
                    invalidating: QueryInvalidation(resources: ["scheduled-tasks"])
                )
            } else {
                saved = try await context.store.mutate(
                    API.createScheduledTask(body: input),
                    invalidating: QueryInvalidation(resources: ["scheduled-tasks"])
                )
            }
            isCreating = false
            selectedId = saved.id
            draft = ScheduledLogic.TaskDraft.from(saved)
            context.showToast(ToastItemModel(id: "scheduled.saved", title: "Scheduled task saved", tone: .success))
        } catch {
            saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func runNow(_ task: API.ScheduledTask) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await context.store.mutate(
                API.runScheduledTask(id: task.id),
                invalidating: QueryInvalidation(resources: ["scheduled-tasks", "runs"])
            )
            context.showToast(ToastItemModel(id: "scheduled.run", title: "Triggered \(task.name)", tone: .info))
        } catch {
            saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func deleteTask(_ task: API.ScheduledTask) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await context.store.mutate(
                API.deleteScheduledTask(id: task.id),
                invalidating: QueryInvalidation(resources: ["scheduled-tasks"])
            )
            selectedId = nil
            context.showToast(ToastItemModel(id: "scheduled.deleted", title: "Deleted \(task.name)", tone: .info))
        } catch {
            saveError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}
