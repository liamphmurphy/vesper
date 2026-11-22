import SwiftUI
import VesperCore

/// Reference-type state for `StudyView` so `context.onCommand` always reads the latest course/lessons
/// without capturing a stale SwiftUI view value.
@MainActor
@Observable
final class StudyController {
    var courseId = ""
    var lessonKeys: Set<String> = []
    var currentLessonKey: String?
    var planPending = false
    var stopPending = false
    var navActionError: String?
    var confirmStopBuild = false
    var wideTutorOpen = true
    var compactTutorSheetOpen = false
    var isCompactWidth = false
}

/// Interactive lesson study view: publishes `LearnNav` to the window sidebar, renders lesson body
/// blocks (`MarkdownView`, Swift Charts, diagrams), knowledge checks, sources, and trailing tutor panel.
struct StudyView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let course: API.Course
    let onRequestDelete: () -> Void

    @State private var controller = StudyController()
    @State private var highlightedSourceAnchor: String?

    private var requestedKey: String? {
        context.match.query["lesson"]
    }

    private var currentLesson: API.CourseLesson? {
        LearnLogic.pickLesson(course.lessons, requested: requestedKey)
    }

    private var openLessons: [API.CourseLesson] {
        course.lessons.filter { $0.status != .known }
    }

    private var navSyncKey: String {
        [
            course.summary.id,
            course.summary.topic,
            course.summary.state.rawValue,
            course.summary.buildNote,
            course.summary.error,
            "\(course.summary.complete)-\(course.summary.lessons)-\(course.summary.solid)-\(course.summary.part)-\(course.summary.parts)",
            currentLesson?.key ?? "",
            "\(controller.planPending)-\(controller.stopPending)-\(controller.navActionError ?? "")",
            "\(controller.wideTutorOpen)-\(controller.compactTutorSheetOpen)-\(controller.isCompactWidth)",
            course.lessons.map { "\($0.key):\($0.status.rawValue):\($0.progress.rawValue)" }.joined(separator: ","),
        ].joined(separator: "|")
    }

    var body: some View {
        let lesson = currentLesson
        let open = openLessons
        let currentIndex = lesson.flatMap { l in open.firstIndex(where: { $0.key == l.key }) }
        let nextLesson = currentIndex.flatMap { $0 + 1 < open.count ? open[$0 + 1] : nil }

        GeometryReader { geo in
            let compact = geo.size.width < 860
            HStack(spacing: 0) {
                readerPane(lesson: lesson, openCount: open.count, lessonIndex: currentIndex, nextLesson: nextLesson, compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !compact && controller.wideTutorOpen, let lesson {
                    Divider().overlay(theme.swiftUIColor("border-subtle", fallback: theme.palette.border))
                    TutorPanelView(courseId: course.summary.id, chatId: course.chatId, lessonKey: lesson.key)
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                }
            }
            .onChange(of: compact, initial: true) { _, isCompact in
                controller.isCompactWidth = isCompact
            }
        }
        .onChange(of: navSyncKey, initial: true) { _, _ in
            syncControllerAndChrome()
        }
        .onAppear {
            syncControllerAndChrome()
            context.onCommand = { command in
                handleNavCommand(command)
            }
        }
        .sheet(isPresented: $controller.compactTutorSheetOpen) {
            if let lesson {
                VStack(spacing: 0) {
                    HStack {
                        Text("Your tutor")
                            .vesperText(.heading, theme)
                        Spacer()
                        Button("Done") { controller.compactTutorSheetOpen = false }
                            .buttonStyle(.vesper())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.swiftUIColor("surface-sunken", fallback: theme.palette.surface))
                    Divider().overlay(theme.palette.border)
                    TutorPanelView(courseId: course.summary.id, chatId: course.chatId, lessonKey: lesson.key)
                }
                .frame(minWidth: 380, idealWidth: 460, minHeight: 520, idealHeight: 620)
                .environment(context)
                .environment(\.vesperTheme, theme)
            }
        }
        .alert("Stop building the next part?", isPresented: $controller.confirmStopBuild) {
            Button("Cancel", role: .cancel) {}
            Button("Stop build", role: .destructive) {
                stopBuild()
            }
        } message: {
            Text("The lessons you already have stay available.")
        }
    }

    @ViewBuilder
    private func readerPane(
        lesson: API.CourseLesson?,
        openCount: Int,
        lessonIndex: Int?,
        nextLesson: API.CourseLesson?,
        compact: Bool
    ) -> some View {
        let p = theme.palette
        let cited = Set(lesson?.body.flatMap { $0.sources ?? [] } ?? [])

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let lesson {
                        (Text(lesson.unitTitle).foregroundStyle(p.tertiaryText)
                            + Text(" / \(lesson.title)").foregroundStyle(p.text).fontWeight(.medium))
                            .vesperText(.body, theme)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer()
                    }

                    if compact, lesson != nil {
                        Button {
                            controller.compactTutorSheetOpen = true
                        } label: {
                            Label("Tutor", systemImage: "bubble.left")
                        }
                        .buttonStyle(.vesper())
                    }

                    if let nextLesson {
                        Button("Next \u{2192}") {
                            context.navigate("/learn/\(course.summary.id)?lesson=\(nextLesson.key)")
                        }
                        .buttonStyle(.vesper())
                    }
                }
                .padding(.horizontal, 24)
                .frame(height: 52)

                Divider().overlay(theme.swiftUIColor("border-subtle", fallback: p.border))

                if let lesson {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Color.clear.frame(height: 0).id("lesson-top")

                            lessonHeader(lesson: lesson, index: lessonIndex ?? 0, openCount: openCount, citedCount: cited.count)

                            if !lesson.shakyPrereqs.isEmpty {
                                LearnBanner(
                                    tone: "human",
                                    title: "Prerequisite shaky",
                                    bodyText: "This builds on \(lesson.shakyPrereqs.joined(separator: ", ")), which you haven\u{2019}t completed. You can carry on anyway."
                                )
                            }

                            if lesson.status == .flagged {
                                LearnBanner(
                                    tone: "human",
                                    title: "The reviewer flagged this lesson",
                                    bodyText: "Check what it says before relying on it.",
                                    bullets: lesson.issues
                                )
                            }

                            lessonBody(lesson: lesson) { target in
                                handleMarkdownLink(target, proxy: proxy)
                            }

                            ForEach(Array(lesson.checks.enumerated()), id: \.element.id) { idx, check in
                                CheckCardView(
                                    courseId: course.summary.id,
                                    check: check,
                                    index: idx,
                                    total: lesson.checks.count
                                )
                                .id(check.id)
                            }

                            if !cited.isEmpty {
                                sourcesSection(cited: cited)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .onChange(of: lesson.key) { _, _ in
                        highlightedSourceAnchor = nil
                        proxy.scrollTo("lesson-top", anchor: .top)
                    }
                } else {
                    VStack(spacing: 10) {
                        Text("No lessons ready yet")
                            .vesperText(.heading, theme)
                        Text("This module has no open lessons right now.")
                            .vesperText(.body, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func lessonHeader(lesson: API.CourseLesson, index: Int, openCount: Int, citedCount: Int) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 8) {
            Text("LESSON \(index + 1) OF \(max(openCount, 1))")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(p.tertiaryText)

            Text(lesson.title)
                .vesperText(.display, theme)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(lesson.minutes) min · \(citedCount) sources")
                        .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        .foregroundStyle(p.tertiaryText)
                        .fixedSize()

                    if lesson.status == .verified {
                        Text("Reviewed")
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                            .fixedSize()
                    }

                    if !lesson.objectives.isEmpty {
                        Text("Goal: \(lesson.objectives.joined(separator: "; "))")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text("\(lesson.minutes) min · \(citedCount) sources")
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                            .foregroundStyle(p.tertiaryText)

                        if lesson.status == .verified {
                            Text("Reviewed")
                                .vesperText(.small, theme)
                                .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
                        }
                    }

                    if !lesson.objectives.isEmpty {
                        Text("Goal: \(lesson.objectives.joined(separator: "; "))")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func lessonBody(lesson: API.CourseLesson, onLink: @escaping (MarkdownLinkTarget) -> Bool) -> some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(lesson.body.enumerated()), id: \.offset) { _, block in
                let isModelKnowledge = block.provenance == .modelKnowledge
                let content = blockContent(block, isModelKnowledge: isModelKnowledge, onLink: onLink)

                if isModelKnowledge && block.kind != .heading && block.kind != .code {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MODEL KNOWLEDGE · NOT SOURCED")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(p.tertiaryText)
                        content
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        DashedVerticalRule()
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .foregroundStyle(p.tertiaryText)
                            .frame(width: 1.5)
                    }
                } else {
                    content
                }
            }
        }
        .onChange(of: lesson.body.map(\.text), initial: true) { _, texts in
            context.find.texts = texts + lesson.checks.map(\.prompt)
        }
    }

    @ViewBuilder
    private func blockContent(
        _ block: API.CourseBlock,
        isModelKnowledge: Bool,
        onLink: @escaping (MarkdownLinkTarget) -> Bool
    ) -> some View {
        let captionMarkdown: String? = {
            let cap = block.caption ?? ""
            let cites = LearnLogic.citationsMarkdown(block.sources)
            let combined = cap + cites
            return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : combined
        }()

        switch block.kind {
        case .heading:
            Text(block.text)
                .vesperText(.heading, theme)
                .padding(.top, 6)

        case .code:
            MarkdownView(
                markdown: LearnLogic.codeFenceMarkdown(code: block.text, lang: block.lang),
                textStyle: .reading,
                textColor: "text-2",
                chat: true,
                onLink: onLink
            )

        case .chart:
            LessonChartView(
                json: block.text,
                alt: block.alt,
                captionMarkdown: captionMarkdown,
                showCodeOnError: false,
                onLink: onLink
            )

        case .diagram:
            LessonDiagramView(
                svgSource: block.text,
                alt: block.alt,
                steps: block.steps,
                captionMarkdown: captionMarkdown,
                onLink: onLink
            )

        default:
            let md = isModelKnowledge ? block.text : (block.text + LearnLogic.citationsMarkdown(block.sources))
            MarkdownView(
                markdown: md,
                textStyle: .reading,
                textColor: "text-2",
                onLink: onLink
            )
        }
    }

    private func sourcesSection(cited: Set<Int>) -> some View {
        let p = theme.palette
        let matching = course.sources.filter { cited.contains($0.n) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.system(size: theme.pointSize(.small), weight: .semibold))
                .foregroundStyle(p.secondaryText)

            ForEach(matching, id: \.n) { source in
                let anchor = "source-\(source.n)"
                let highlighted = highlightedSourceAnchor == anchor
                Button {
                    context.openExternal(source.url)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("[\(source.n)]")
                            .foregroundStyle(p.accent)
                            .font(.system(size: theme.pointSize(.small), design: .monospaced))
                        Text(source.title)
                            .vesperText(.small, theme)
                            .foregroundStyle(p.tertiaryText)
                            .underline(highlighted)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(highlighted ? p.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .id(anchor)
            }
        }
        .padding(.top, 8)
    }

    private func handleMarkdownLink(_ target: MarkdownLinkTarget, proxy: ScrollViewProxy) -> Bool {
        if case .anchor(let anchor) = target, anchor.hasPrefix("source-") {
            highlightedSourceAnchor = anchor
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(anchor, anchor: .center)
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                if highlightedSourceAnchor == anchor {
                    highlightedSourceAnchor = nil
                }
            }
            return true
        }
        return false
    }

    private func syncControllerAndChrome() {
        controller.courseId = course.summary.id
        controller.lessonKeys = Set(course.lessons.map(\.key))
        controller.currentLessonKey = currentLesson?.key

        let navModel = LearnNav.buildStudyModel(
            course: course,
            currentKey: currentLesson?.key,
            planPending: controller.planPending,
            stopPending: controller.stopPending,
            actionError: controller.navActionError
        )
        let tutorOpen = controller.isCompactWidth ? controller.compactTutorSheetOpen : controller.wideTutorOpen
        context.chrome = NativeChrome(
            title: course.summary.topic,
            toolbarItems: [
                ShellToolbarItem(id: "study.refresh", label: "Refresh", icon: "refresh", kind: .button, showsLabel: false),
                ShellToolbarItem(
                    id: "study.tutor",
                    label: "Tutor",
                    icon: "msg",
                    kind: .toggle,
                    on: tutorOpen,
                    showsLabel: true
                ),
            ],
            navigator: navModel
        )
    }

    private func handleNavCommand(_ command: NativeCommand) {
        switch command {
        case .toolbarAction(itemId: "study.refresh", _):
            let id = controller.courseId
            if !id.isEmpty {
                Task { _ = await context.store.refetch(API.getCourse(id: id)) }
            }
            return
        case .toolbarAction(itemId: "study.tutor", _):
            if controller.isCompactWidth {
                controller.compactTutorSheetOpen.toggle()
            } else {
                controller.wideTutorOpen.toggle()
            }
            syncControllerAndChrome()
            return
        default:
            break
        }

        guard let action = LearnNav.action(for: command, lessonKeys: controller.lessonKeys) else { return }
        let id = controller.courseId
        switch action {
        case .back:
            context.navigate("/learn")
        case .delete:
            onRequestDelete()
        case .planNext:
            planNextPart(courseId: id)
        case .stopBuild:
            controller.confirmStopBuild = true
        case .reviewOutline(let newTab):
            let href = "/learn/\(id)?review=1"
            newTab ? context.openInNewTab(href) : context.navigate(href)
        case .selectLesson(let key, let newTab):
            let href = "/learn/\(id)?lesson=\(key)"
            newTab ? context.openInNewTab(href) : context.navigate(href)
        }
    }

    private func planNextPart(courseId id: String) {
        guard !controller.planPending, !id.isEmpty else { return }
        controller.planPending = true
        controller.navActionError = nil
        syncControllerAndChrome()
        let request = API.getCourse(id: id)
        Task {
            do {
                let updated = try await context.store.mutate(
                    API.startCourseNextPart(id: id),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                context.store.setData(updated, for: request)
                controller.planPending = false
                syncControllerAndChrome()
            } catch {
                controller.planPending = false
                controller.navActionError = (error as? APIError)?.userMessage ?? error.localizedDescription
                syncControllerAndChrome()
            }
        }
    }

    private func stopBuild() {
        let id = controller.courseId
        guard !controller.stopPending, !id.isEmpty else { return }
        controller.stopPending = true
        controller.navActionError = nil
        syncControllerAndChrome()
        let request = API.getCourse(id: id)
        Task {
            do {
                let updated = try await context.store.mutate(
                    API.stopCourse(id: id),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                context.store.setData(updated, for: request)
                controller.stopPending = false
                syncControllerAndChrome()
            } catch {
                controller.stopPending = false
                controller.navActionError = (error as? APIError)?.userMessage ?? error.localizedDescription
                syncControllerAndChrome()
            }
        }
    }
}

/// Interactive knowledge check card (`mcq`, `order`, `short` + self-grading + confidence + reveal).
private struct CheckCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let courseId: String
    let check: API.CourseCheck
    let index: Int
    let total: Int

    @State private var choice = ""
    @State private var shortText = ""
    @State private var order: [String]
    @State private var confidence = 2
    @State private var attemptPending = false
    @State private var gradePending = false
    @State private var actionError: String?

    init(courseId: String, check: API.CourseCheck, index: Int, total: Int) {
        self.courseId = courseId
        self.check = check
        self.index = index
        self.total = total
        _order = State(initialValue: check.options)
    }

    private var ready: Bool {
        switch check.kind {
        case .mcq: return !choice.isEmpty
        case .order: return !order.isEmpty
        case .short: return !shortText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return !shortText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var response: [String] {
        switch check.kind {
        case .mcq: return [choice]
        case .order: return order
        default: return [shortText]
        }
    }

    var body: some View {
        let p = theme.palette
        let waitingMark = !(check.ungradedAttemptId ?? "").isEmpty

        VStack(alignment: .leading, spacing: 12) {
            Text("CHECK \(index + 1) OF \(total)")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(p.tertiaryText)

            Text(check.prompt)
                .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                .foregroundStyle(p.text)

            if check.kind == .mcq {
                VStack(spacing: 8) {
                    ForEach(check.options, id: \.self) { option in
                        let selected = choice == option
                        Button {
                            choice = option
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? p.accent : p.tertiaryText)
                                Text(option)
                                    .vesperText(.body, theme)
                                    .foregroundStyle(selected ? p.text : theme.swiftUIColor("text-2", fallback: p.secondaryText))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                selected
                                    ? theme.swiftUIColor("accent-soft", fallback: p.selected)
                                    : theme.swiftUIColor("surface-sunken", fallback: p.background),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected ? p.accent : theme.swiftUIColor("border-strong", fallback: p.border))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if check.kind == .order {
                VStack(spacing: 8) {
                    ForEach(Array(order.enumerated()), id: \.element) { idx, item in
                        HStack(spacing: 8) {
                            Text(item)
                                .vesperText(.body, theme)
                                .foregroundStyle(theme.swiftUIColor("text-2", fallback: p.secondaryText))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("\u{2191}") { moveOrder(idx, by: -1) }
                                .buttonStyle(.vesper())
                                .disabled(idx == 0)
                                .accessibilityLabel("Move \(item) up")
                            Button("\u{2193}") { moveOrder(idx, by: 1) }
                                .buttonStyle(.vesper())
                                .disabled(idx >= order.count - 1)
                                .accessibilityLabel("Move \(item) down")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.swiftUIColor("border-strong", fallback: p.border)))
                    }
                }
            } else {
                TextEditor(text: $shortText)
                    .scrollContentBackground(.hidden)
                    .vesperText(.body, theme)
                    .padding(6)
                    .frame(minHeight: 76, maxHeight: 140)
                    .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.swiftUIColor("border-strong", fallback: p.border)))
                    .accessibilityLabel("Your answer")
            }

            if waitingMark, let attemptId = check.ungradedAttemptId {
                HStack(spacing: 8) {
                    Text("Compare with the answer below. Did you get it?")
                        .vesperText(.body, theme)
                        .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                    Spacer()
                    Button("Yes") {
                        gradeAttempt(attemptId: attemptId, correct: true)
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(gradePending)
                    Button("Not quite") {
                        gradeAttempt(attemptId: attemptId, correct: false)
                    }
                    .buttonStyle(.vesper())
                    .disabled(gradePending)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("How sure are you?")
                            .vesperText(.small, theme)
                            .foregroundStyle(p.secondaryText)
                        confidencePicker
                        Spacer()
                        checkButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("How sure are you?")
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                            confidencePicker
                        }
                        checkButton
                    }
                }
            }

            if check.lastCorrect == true {
                Text("Correct.")
                    .vesperText(.body, theme)
                    .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
            } else if check.lastCorrect == false && !check.solved {
                Text(check.reveal != nil ? "Not this time." : "Not quite. Try again, or ask your tutor for a hint.")
                    .vesperText(.body, theme)
                    .foregroundStyle(p.secondaryText)
            }

            if let reveal = check.reveal {
                revealBox(reveal)
            }

            if let actionError {
                LearnBanner(tone: "blocked", title: actionError)
            }
        }
        .padding(20)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.swiftUIColor("border-strong", fallback: p.border)))
        .onChange(of: check.options) { _, latest in
            if Set(latest) != Set(order) {
                order = latest
            }
        }
    }

    private var confidencePicker: some View {
        Picker("How sure are you?", selection: $confidence) {
            ForEach(LearnLogic.confidenceOptions) { option in
                Text(option.label).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var checkButton: some View {
        Button(attemptPending ? "Checking\u{2026}" : "Check answer") {
            submitAttempt()
        }
        .buttonStyle(.vesper(.primary))
        .disabled(!ready || attemptPending)
    }

    private func revealBox(_ reveal: API.CourseReveal) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 6) {
            if check.kind == .short {
                if let first = reveal.answer.first {
                    (Text("A good answer: ").fontWeight(.semibold) + Text(first))
                }
                if !reveal.rubric.isEmpty {
                    (Text("It should cover: ").fontWeight(.semibold) + Text(reveal.rubric))
                }
            } else if check.kind == .mcq {
                if let first = reveal.answer.first {
                    (Text("Answer: ").fontWeight(.semibold) + Text(first))
                }
            } else if check.kind == .order {
                ForEach(Array(reveal.answer.enumerated()), id: \.offset) { idx, item in
                    Text("\(idx + 1). \(item)")
                }
            }
            if !reveal.explanation.isEmpty {
                Text(reveal.explanation)
            }
        }
        .vesperText(.body, theme)
        .foregroundStyle(theme.swiftUIColor("text-2", fallback: p.secondaryText))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.background), in: RoundedRectangle(cornerRadius: 6))
    }

    private func moveOrder(_ index: Int, by delta: Int) {
        let next = index + delta
        guard next >= 0, next < order.count else { return }
        order.swapAt(index, next)
    }

    private func submitAttempt() {
        guard ready, !attemptPending else { return }
        attemptPending = true
        actionError = nil
        let body = API.CourseAttemptCreate(confidence: confidence, response: response)
        let id = courseId
        let cid = check.id
        Task {
            do {
                _ = try await context.store.mutate(
                    API.attemptCourseCheck(id: id, checkId: cid, body: body),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                _ = await context.store.refetch(API.getCourse(id: id))
                attemptPending = false
            } catch {
                attemptPending = false
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func gradeAttempt(attemptId: String, correct: Bool) {
        guard !gradePending else { return }
        gradePending = true
        actionError = nil
        let id = courseId
        Task {
            do {
                _ = try await context.store.mutate(
                    API.gradeCourseAttempt(id: id, attemptId: attemptId, body: API.GradeCourseAttemptBody(correct: correct)),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                _ = await context.store.refetch(API.getCourse(id: id))
                gradePending = false
            } catch {
                gradePending = false
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

/// Trailing tutor conversation drawer: quick prompts, markdown/chart transcript, 2s run polling, Enter-to-send composer.
struct TutorPanelView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let courseId: String
    let chatId: String
    let lessonKey: String

    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var watchedKeys: [QueryKey] = []
    @FocusState private var composerFocused: Bool

    private var chatRequest: APIRequest<API.ChatSession> {
        API.getChat(id: chatId)
    }

    private var messagesRequest: APIRequest<API.ListChatMessagesResponse> {
        API.listChatMessages(id: chatId, limit: 200)
    }

    var body: some View {
        let p = theme.palette
        let chatEntry = context.store.entry(chatRequest)
        let messagesEntry = context.store.entry(messagesRequest)
        let running = chatEntry.data?.state == .running
        let messages = (messagesEntry.data?.messages ?? []).filter { $0.role != .system }

        VStack(spacing: 0) {
            HStack {
                Text("Your tutor")
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                Spacer()
                Text("Replies aren\u{2019}t reviewed")
                    .font(.system(size: theme.pointSize(.micro) + 1))
                    .foregroundStyle(p.tertiaryText)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Divider().overlay(theme.swiftUIColor("border-subtle", fallback: p.border))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = messagesEntry.error, messages.isEmpty {
                            LearnBanner(tone: "blocked", title: error.userMessage) {
                                Task { _ = await context.store.refetch(messagesRequest) }
                            }
                        } else if messages.isEmpty {
                            Text("Stuck on something? Ask about this lesson and your tutor will work through it with you.")
                                .vesperText(.body, theme)
                                .foregroundStyle(p.tertiaryText)
                        }

                        ForEach(messages, id: \.id) { message in
                            if message.role == .user {
                                HStack {
                                    Spacer(minLength: 36)
                                    Text(message.bodyMd)
                                        .vesperText(.body, theme)
                                        .foregroundStyle(p.text)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            theme.swiftUIColor("surface-raised", fallback: p.surface),
                                            in: RoundedRectangle(cornerRadius: 10)
                                        )
                                }
                            } else {
                                tutorMessageBody(message.bodyMd)
                            }
                        }

                        if running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("Thinking\u{2026}")
                                    .vesperText(.small, theme)
                                    .foregroundStyle(p.tertiaryText)
                            }
                        }

                        Color.clear.frame(height: 1).id("tutor-bottom")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: "\(messages.count):\(running)") { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("tutor-bottom", anchor: .bottom)
                    }
                }
            }

            Divider().overlay(theme.swiftUIColor("border-subtle", fallback: p.border))

            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LearnLogic.quickTutorPrompts, id: \.self) { prompt in
                            Button(prompt) {
                                send(text: prompt, clearDraft: false)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(p.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(p.surface, in: Capsule())
                            .overlay(Capsule().stroke(theme.swiftUIColor("border-strong", fallback: p.border)))
                            .disabled(running || sending)
                        }
                    }
                }

                if let sendError {
                    LearnBanner(tone: "blocked", title: sendError)
                }

                HStack(alignment: .bottom, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ask about this lesson\u{2026}")
                                .vesperText(.body, theme)
                                .foregroundStyle(p.tertiaryText)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draft)
                            .scrollContentBackground(.hidden)
                            .vesperText(.body, theme)
                            .focused($composerFocused)
                            .padding(4)
                            .onKeyPress(.return, phases: .down) { press in
                                guard !press.modifiers.contains(.shift) else { return .ignored }
                                send(text: draft, clearDraft: true)
                                return .handled
                            }
                    }
                    .frame(minHeight: 54, maxHeight: 110)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(composerFocused ? p.accent : p.border))

                    Button("Send") {
                        send(text: draft, clearDraft: true)
                    }
                    .buttonStyle(.vesper(.primary))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running || sending)
                }
            }
            .padding(14)
        }
        .background(theme.swiftUIColor("panel", fallback: p.surface))
        .task(id: chatId) {
            for key in watchedKeys {
                context.store.stopObserving(key)
            }
            let chatReq = chatRequest
            let msgReq = messagesRequest
            context.store.observe(chatReq)
            context.store.observe(msgReq)
            watchedKeys = [chatReq.key, msgReq.key]
            context.store.load(chatReq)
            context.store.load(msgReq)
        }
        .task(id: "\(chatId):\(running)") {
            guard running else { return }
            let chatReq = chatRequest
            let msgReq = messagesRequest
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                _ = await context.store.refetch(chatReq)
                _ = await context.store.refetch(msgReq)
            }
        }
        .onChange(of: running) { wasRunning, isRunning in
            if wasRunning && !isRunning {
                Task { _ = await context.store.refetch(messagesRequest) }
            }
        }
        .onDisappear {
            for key in watchedKeys {
                context.store.stopObserving(key)
            }
            watchedKeys = []
        }
    }

    private func tutorMessageBody(_ markdown: String) -> some View {
        let blocks = LearnLogic.splitTutorMarkdown(markdown)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let md):
                    MarkdownView(markdown: md, textStyle: .body, textColor: "text-2", chat: true)
                case .chart(let json):
                    LessonChartView(json: json, showCodeOnError: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func send(text: String, clearDraft: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRunning = context.store.entry(chatRequest).data?.state == .running
        guard !trimmed.isEmpty, !sending, !isRunning else { return }
        sending = true
        sendError = nil
        let body = API.PostCourseTutorMessageBody(body: trimmed, lesson: lessonKey)
        let id = courseId
        let cId = chatId
        Task {
            do {
                _ = try await context.store.mutate(
                    API.postCourseTutorMessage(id: id, body: body),
                    invalidating: QueryInvalidation(prefixes: [["chats", cId]])
                )
                if clearDraft {
                    draft = ""
                }
                _ = await context.store.refetch(chatRequest)
                _ = await context.store.refetch(messagesRequest)
                sending = false
            } catch {
                sending = false
                sendError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

private struct DashedVerticalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
