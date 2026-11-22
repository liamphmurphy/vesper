import SwiftUI
import VesperCore

/// 5-step guided wizard for creating a new Learning Module (Topic -> Purpose -> Level -> Time -> Review).
struct NewModuleSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var topic = ""
    @State private var goal = ""
    @State private var level: API.CourseCreate.Level = .some
    @State private var timeIndex: Double = Double(LearnLogic.timeSteps.firstIndex(of: 180) ?? 5)
    @State private var tutorId = ""
    @State private var pickedModel: LearnLogic.ModelSelection?
    @State private var submitting = false
    @State private var submitError: String?

    @FocusState private var topicFocused: Bool
    @FocusState private var goalFocused: Bool

    private static let steps = ["Topic", "Purpose", "Level", "Time", "Review"]
    private static let lastStep = steps.count - 1

    private static let bootstrapRequest = API.getBootstrap()
    private static let personasRequest = API.listPersonas()
    private static let modelsRequest = API.listChatModels()

    private var minutesBudget: Int {
        let idx = min(max(Int(timeIndex.rounded()), 0), LearnLogic.timeSteps.count - 1)
        return LearnLogic.timeSteps[idx]
    }

    private var projects: [API.Project] {
        context.store.entry(Self.bootstrapRequest).data?.projects ?? []
    }

    private var projectKey: String? {
        LearnLogic.defaultProjectKey(projects: projects, preferred: context.match.query["project"])
    }

    private var modelGroups: [API.ChatHarnessModels] {
        context.store.entry(Self.modelsRequest).data ?? []
    }

    private var effectiveSelection: LearnLogic.ModelSelection? {
        pickedModel ?? LearnLogic.defaultModelSelection(from: modelGroups)
    }

    private var personas: [API.Persona] {
        context.store.entry(Self.personasRequest).data?.personas ?? []
    }

    private var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var blocked: Bool {
        trimmedTopic.isEmpty || (step == Self.lastStep && (projectKey == nil || submitting))
    }

    var body: some View {
        let p = theme.palette

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("New Learning Module")
                    .vesperText(.heading, theme)
                Text("\(step + 1) of \(Self.steps.count)")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            HStack(spacing: 4) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { idx, _ in
                    Capsule()
                        .fill(idx <= step ? p.accent : theme.swiftUIColor("track", fallback: p.hover))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .accessibilityHidden(true)

            ScrollView {
                stepBody
                    .padding(.horizontal, 18)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 340)

            Divider().overlay(theme.swiftUIColor("track", fallback: p.border))

            HStack(spacing: 12) {
                if step == Self.lastStep {
                    Text("Drafting takes one short run. You approve the outline before any research starts.")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }
                if step > 0 {
                    Button("Back") {
                        go(to: step - 1)
                    }
                    .buttonStyle(.vesper())
                    .disabled(submitting)
                }
                Button(primaryButtonLabel) {
                    advance()
                }
                .buttonStyle(.vesper(.primary))
                .disabled(blocked)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))
        }
        .frame(width: 600)
        .background(theme.swiftUIColor("surface-raised", fallback: p.background))
        .task {
            context.store.load(Self.bootstrapRequest)
            context.store.load(Self.personasRequest)
            context.store.load(Self.modelsRequest)
        }
        .onChange(of: step, initial: true) { _, newStep in
            topicFocused = (newStep == 0)
            goalFocused = (newStep == 1)
        }
    }

    private var primaryButtonLabel: String {
        if step == Self.lastStep {
            return submitting ? "Starting\u{2026}" : "Draft outline"
        }
        if step == 1 && goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Skip"
        }
        return "Continue"
    }

    @ViewBuilder
    private var stepBody: some View {
        let p = theme.palette
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                Text("What do you want to learn?")
                    .vesperText(.title, theme)
                TextField("How Postgres MVCC and vacuum actually work", text: $topic)
                    .textFieldStyle(.roundedBorder)
                    .focused($topicFocused)
                    .onChange(of: topic) { _, next in
                        if next.count > 200 { topic = String(next.prefix(200)) }
                    }
                    .onSubmit {
                        if !trimmedTopic.isEmpty { advance() }
                    }
                Text("Be as specific as you like. A narrow topic makes a better module.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
            }

        case 1:
            VStack(alignment: .leading, spacing: 12) {
                Text("What\u{2019}s it for?")
                    .vesperText(.title, theme)
                ZStack(alignment: .topLeading) {
                    if goal.isEmpty {
                        Text("I debug slow queries at work and want to understand table bloat")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.tertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $goal)
                        .scrollContentBackground(.hidden)
                        .vesperText(.body, theme)
                        .focused($goalFocused)
                        .padding(5)
                        .onChange(of: goal) { _, next in
                            if next.count > 1000 { goal = String(next.prefix(1000)) }
                        }
                        .onKeyPress(.return, phases: .down) { press in
                            guard !press.modifiers.contains(.shift) else { return .ignored }
                            advance()
                            return .handled
                        }
                }
                .frame(height: 110)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(goalFocused ? p.accent : p.border))
                Text("This shapes what gets taught. Skip it if you\u{2019}re just curious.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
            }

        case 2:
            VStack(alignment: .leading, spacing: 12) {
                Text("How much do you already know?")
                    .vesperText(.title, theme)
                VStack(spacing: 8) {
                    ForEach(LearnLogic.levelOptions) { option in
                        let selected = level == option.value
                        Button {
                            level = option.value
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.system(size: theme.pointSize(.heading), weight: .medium))
                                        .foregroundStyle(p.text)
                                    Text(option.detail)
                                        .vesperText(.small, theme)
                                        .foregroundStyle(p.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                ZStack {
                                    Circle()
                                        .fill(selected ? p.accent : .clear)
                                    Circle()
                                        .stroke(selected ? p.accent : theme.swiftUIColor("border-strong", fallback: p.border))
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(theme.swiftUIColor("text-on-accent", fallback: .white))
                                    }
                                }
                                .frame(width: 18, height: 18)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(selected ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selected ? p.accent : theme.swiftUIColor("border-strong", fallback: p.border))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        case 3:
            let minutes = minutesBudget
            let partFraction = Double(LearnLogic.timeSteps.firstIndex(of: LearnLogic.partMinutes) ?? 8) / Double(max(1, LearnLogic.timeSteps.count - 1))
            VStack(alignment: .leading, spacing: 14) {
                Text("How much time do you have?")
                    .vesperText(.title, theme)
                HStack(alignment: .firstTextBaseline) {
                    Text(LearnLogic.timeLabel(minutes))
                        .font(.system(size: 22 * theme.typeScale, weight: .semibold))
                        .foregroundStyle(p.text)
                    Spacer()
                    if minutes > LearnLogic.partMinutes {
                        Text("In \(LearnLogic.partsEstimate(minutes)) parts")
                            .font(.system(size: theme.pointSize(.small), weight: .semibold))
                            .foregroundStyle(p.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.swiftUIColor("accent-soft", fallback: p.selected), in: Capsule())
                    }
                }
                Slider(value: $timeIndex, in: 0...Double(LearnLogic.timeSteps.count - 1), step: 1)
                    .accessibilityLabel("Time")
                    .accessibilityValue(LearnLogic.timeLabel(minutes))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Text("30 min")
                        Text("8h · parts beyond")
                            .position(x: geo.size.width * partFraction, y: 8)
                        HStack {
                            Spacer()
                            Text("20h")
                        }
                    }
                    .font(.system(size: theme.pointSize(.micro) + 1))
                    .foregroundStyle(p.tertiaryText)
                }
                .frame(height: 16)

                Text(LearnLogic.timeDetail(minutes))
                    .vesperText(.small, theme)
                    .foregroundStyle(p.secondaryText)
            }

        default:
            VStack(alignment: .leading, spacing: 14) {
                Text("Here\u{2019}s your module")
                    .vesperText(.title, theme)

                VStack(spacing: 2) {
                    reviewRow(label: "Topic", value: trimmedTopic, stepIndex: 0)
                    reviewRow(
                        label: "Purpose",
                        value: goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Not set"
                            : goal.trimmingCharacters(in: .whitespacesAndNewlines),
                        muted: goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        stepIndex: 1
                    )
                    reviewRow(
                        label: "Level",
                        value: LearnLogic.levelOptions.first(where: { $0.value == level })?.label ?? level.rawValue,
                        stepIndex: 2
                    )
                    let partNote = minutesBudget > LearnLogic.partMinutes ? ", in about \(LearnLogic.partsEstimate(minutesBudget)) parts" : ""
                    reviewRow(
                        label: "Time",
                        value: "\(LearnLogic.timeLabel(minutesBudget))\(partNote)",
                        stepIndex: 3
                    )
                }

                HStack(alignment: .bottom, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tutor")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                        Picker("Tutor", selection: $tutorId) {
                            Text("Default persona").tag("")
                            ForEach(personas, id: \.id) { persona in
                                Text(persona.name).tag(persona.id)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 160)
                    }

                    if let selection = effectiveSelection {
                        let label = LearnLogic.modelDisplayLabel(groups: modelGroups, selection: selection)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model")
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                            Menu {
                                ForEach(modelGroups, id: \.harness.rawValue) { group in
                                    Section(group.label) {
                                        if !group.available {
                                            let msg = group.checking == true
                                                ? "Checking available models\u{2026}"
                                                : (group.unavailableReason ?? "Model discovery unavailable")
                                            Text(msg)
                                        }
                                        ForEach(group.models, id: \.id) { model in
                                            Button {
                                                pickedModel = LearnLogic.ModelSelection(harness: group.harness.rawValue, model: model.id)
                                            } label: {
                                                let active = selection.harness == group.harness.rawValue && selection.model == model.id
                                                if active {
                                                    Label(model.label, systemImage: "checkmark")
                                                } else {
                                                    Text(model.label)
                                                }
                                            }
                                            .disabled(!group.available)
                                        }
                                    }
                                }
                            } label: {
                                Text("\(label.harness) · \(label.model)")
                            }
                            .menuStyle(.borderedButton)
                            .fixedSize()
                        }
                    }
                }

                if projectKey == nil {
                    LearnBanner(tone: "blocked", title: "No active project found to run this module.")
                }
                if let submitError {
                    LearnBanner(tone: "blocked", title: submitError)
                }
            }
        }
    }

    private func reviewRow(label: String, value: String, muted: Bool = false, stepIndex: Int) -> some View {
        let p = theme.palette
        return Button {
            go(to: stepIndex)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)
                    .frame(width: 64, alignment: .leading)
                Text(value)
                    .vesperText(.body, theme)
                    .foregroundStyle(muted ? p.tertiaryText : p.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Edit")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.accent)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func go(to next: Int) {
        submitError = nil
        step = min(max(next, 0), Self.lastStep)
    }

    private func advance() {
        guard !blocked else { return }
        if step < Self.lastStep {
            go(to: step + 1)
            return
        }
        guard let projectKey else { return }
        submitting = true
        submitError = nil
        let selection = effectiveSelection
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = API.CourseCreate(
            goal: trimmedGoal.isEmpty ? nil : trimmedGoal,
            harness: selection?.harness,
            level: level,
            minutesBudget: minutesBudget,
            model: selection?.model,
            personaId: tutorId.isEmpty ? nil : tutorId,
            project: projectKey,
            topic: trimmedTopic
        )
        Task {
            do {
                let created = try await context.store.mutate(
                    API.createCourse(body: body),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                context.store.setData(created, for: API.getCourse(id: created.summary.id))
                submitting = false
                dismiss()
                context.navigate("/learn/\(created.summary.id)")
            } catch {
                submitting = false
                submitError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
