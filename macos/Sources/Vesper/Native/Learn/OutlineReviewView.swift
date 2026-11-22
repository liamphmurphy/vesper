import SwiftUI
import VesperCore

/// 6-step horizontal build progress indicator (`Scoping` -> `Ready`).
struct BuildStepper: View {
    @Environment(\.vesperTheme) private var theme
    let state: API.CourseState

    var body: some View {
        let p = theme.palette
        let activeIndex = LearnLogic.buildStepIndex(state)

        HStack(spacing: 16) {
            ForEach(Array(LearnLogic.buildSteps.enumerated()), id: \.offset) { idx, step in
                let done = activeIndex >= 0 && idx < activeIndex
                let current = idx == activeIndex
                let isHuman = current && state == .outlineReady

                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(done ? theme.swiftUIColor("text-2", fallback: p.secondaryText) : .clear)
                        Circle()
                            .stroke(
                                done
                                    ? theme.swiftUIColor("text-2", fallback: p.secondaryText)
                                    : current
                                        ? (isHuman ? theme.swiftUIColor("state-human", fallback: .orange) : p.accent)
                                        : theme.swiftUIColor("border-strong", fallback: p.border),
                                lineWidth: current ? 1.5 : 1
                            )
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(p.background)
                        }
                    }
                    .frame(width: 18, height: 18)

                    Text(step.label)
                        .font(.system(size: theme.pointSize(.small), weight: current ? .semibold : .regular))
                        .foregroundStyle(
                            current
                                ? (isHuman ? theme.swiftUIColor("pill-human-fg", fallback: .orange) : p.text)
                                : done ? p.secondaryText : p.tertiaryText
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Build progress: \(LearnLogic.stateLabel(state))")
    }
}

/// Multi-part plan list rendered alongside the outline review when `outline.parts` is present.
struct PartsPlanView: View {
    @Environment(\.vesperTheme) private var theme
    let parts: [API.CourseOutlinePart]
    let currentPart: Int

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 8) {
            Text("The plan")
                .vesperText(.heading, theme)

            VStack(spacing: 8) {
                ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                    let isCurrent = idx == currentPart
                    let isPast = idx < currentPart
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Part \(idx + 1) · \(part.title)")
                                .font(.system(size: theme.pointSize(.body), weight: .medium))
                                .foregroundStyle(isPast ? p.tertiaryText : p.text)
                            Spacer()
                            Text(isPast ? "built" : LearnLogic.hoursTenthsLabel(part.minutes))
                                .font(.system(size: theme.pointSize(.micro) + 1, design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                        }
                        if !isPast {
                            Text(part.summary)
                                .vesperText(.small, theme)
                                .foregroundStyle(p.secondaryText)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isCurrent ? p.selected : p.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isCurrent ? p.accent : theme.swiftUIColor("border-subtle", fallback: p.border))
                    )
                }
            }

            Text("Each later part is outlined when you near the end of the one before, from how you\u{2019}re doing.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
        }
    }
}

/// Outline review & approval editor for `outline_ready` courses (`LearnLogic.moveLesson`, `Known`, research limits).
struct OutlineReviewView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let course: API.Course
    let outline: API.CourseOutline

    @State private var sourcesText: String
    @State private var minutesText: String
    @State private var spendText = ""
    @State private var editPending = false
    @State private var editError: String?
    @State private var approvePending = false
    @State private var approveError: String?

    init(course: API.Course, outline: API.CourseOutline) {
        self.course = course
        self.outline = outline
        _sourcesText = State(initialValue: String(course.maxSources))
        _minutesText = State(initialValue: String(course.maxMinutes))
    }

    private var part: Int { course.summary.part }
    private var parts: [API.CourseOutlinePart] { outline.parts ?? [] }
    private var units: [API.CourseOutlineUnit] { outline.units.filter { ($0.part ?? 0) == part } }
    private var offset: Int { outline.units.count - units.count }
    private var lessonNumbers: [String: String] { LearnLogic.lessonNumbers(in: outline) }
    private var order: [LearnLogic.OutlineUnitOrder] {
        units.map { LearnLogic.OutlineUnitOrder(title: $0.title, lessons: $0.lessons.map(\.key)) }
    }
    private var knownKeys: [String] {
        units.flatMap { $0.lessons.filter { $0.known == true }.map(\.key) }
    }
    private var estRuns: Int { LearnLogic.estimatedRuns(units) }

    private var parsedSources: Int {
        Int(sourcesText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private var parsedMinutes: Int {
        Int(minutesText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    private var limitsValid: Bool {
        LearnLogic.approveLimitsValid(sources: parsedSources, minutes: parsedMinutes, spendText: spendText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LearnBanner(
                tone: "neutral",
                title: part > 0
                    ? "Review part \(part + 1)\u{2019}s outline. Research starts when you approve it; you can keep studying meanwhile."
                    : "Review this outline. Research starts when you approve it."
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    unitsColumn
                        .frame(minWidth: 480, maxWidth: .infinity, alignment: .leading)
                    asideColumn
                        .frame(width: 320, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 24) {
                    unitsColumn
                    asideColumn
                }
            }
        }
    }

    private var unitsColumn: some View {
        let p = theme.palette
        let currentOrder = order
        let currentKnown = knownKeys

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.summary.topic)
                    .vesperText(.title, theme)
                if part >= 0, part < parts.count {
                    Text("Part \(part + 1) of \(parts.count): \(parts[part].title)")
                        .font(.system(size: theme.pointSize(.heading), weight: .medium))
                        .foregroundStyle(p.text)
                }
                Text(part > 0 && part < parts.count ? parts[part].summary : outline.summary)
                    .vesperText(.reading, theme)
                    .foregroundStyle(p.secondaryText)
                Text("\(course.summary.units) units · \(course.summary.lessons) lessons · about \(LearnLogic.hoursTenthsLabel(course.summary.minutes ?? 0))")
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
            }

            if let editError {
                LearnBanner(tone: "blocked", title: editError)
            }

            ForEach(Array(units.enumerated()), id: \.offset) { unitIdx, unit in
                VStack(alignment: .leading, spacing: 0) {
                    Text("Unit \(offset + unitIdx + 1) · \(unit.title)")
                        .font(.system(size: theme.pointSize(.small), weight: .semibold))
                        .foregroundStyle(theme.swiftUIColor("text-2", fallback: p.secondaryText))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface))

                    Divider().overlay(theme.swiftUIColor("border-subtle", fallback: p.border))

                    ForEach(Array(unit.lessons.enumerated()), id: \.element.key) { lessonIdx, lesson in
                        let canMoveUp = LearnLogic.moveLesson(currentOrder, key: lesson.key, dir: -1) != currentOrder
                        let canMoveDown = LearnLogic.moveLesson(currentOrder, key: lesson.key, dir: 1) != currentOrder
                        let isKnown = lesson.known == true

                        HStack(spacing: 10) {
                            VStack(spacing: 2) {
                                Button {
                                    editOutline(order: LearnLogic.moveLesson(currentOrder, key: lesson.key, dir: -1), known: currentKnown)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 10, weight: .semibold))
                                        .frame(width: 20, height: 14)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(p.tertiaryText)
                                .disabled(editPending || !canMoveUp)
                                .opacity(canMoveUp ? 1 : 0.3)
                                .accessibilityLabel("Move \(lesson.title) up")

                                Button {
                                    editOutline(order: LearnLogic.moveLesson(currentOrder, key: lesson.key, dir: 1), known: currentKnown)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .frame(width: 20, height: 14)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(p.tertiaryText)
                                .disabled(editPending || !canMoveDown)
                                .opacity(canMoveDown ? 1 : 0.3)
                                .accessibilityLabel("Move \(lesson.title) down")
                            }

                            Text(lessonNumbers[lesson.key] ?? "")
                                .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                .foregroundStyle(p.tertiaryText)
                                .frame(width: 30, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.title)
                                    .font(.system(size: theme.pointSize(.body), weight: .medium))
                                    .foregroundStyle(isKnown ? p.tertiaryText : p.text)
                                    .lineLimit(1)
                                if let firstObjective = lesson.objectives.first, !firstObjective.isEmpty {
                                    Text(firstObjective)
                                        .vesperText(.small, theme)
                                        .foregroundStyle(p.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if !lesson.prereqs.isEmpty {
                                let reqs = lesson.prereqs.map { lessonNumbers[$0] ?? $0 }.joined(separator: ", ")
                                Text("needs \(reqs)")
                                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                                    .foregroundStyle(p.secondaryText)
                            }

                            Button(isKnown ? "\u{2713} Known" : "Known") {
                                let nextKnown = isKnown
                                    ? currentKnown.filter { $0 != lesson.key }
                                    : currentKnown + [lesson.key]
                                editOutline(order: currentOrder, known: nextKnown)
                            }
                            .buttonStyle(.vesper(isKnown ? .primary : .outline))
                            .disabled(editPending)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        if lessonIdx < unit.lessons.count - 1 {
                            Divider().overlay(p.rowBorder)
                        }
                    }
                }
                .background(p.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
            }

            Text("Use the arrows to reorder. Every change is checked against the prerequisites.")
                .vesperText(.small, theme)
                .foregroundStyle(p.tertiaryText)
        }
    }

    private var asideColumn: some View {
        let p = theme.palette
        let researchQuestions = units
            .filter { $0.lessons.contains { $0.known != true } }
            .map(\.question)

        return VStack(alignment: .leading, spacing: 16) {
            if !parts.isEmpty {
                PartsPlanView(parts: parts, currentPart: part)
                Divider().overlay(theme.swiftUIColor("border-subtle", fallback: p.border))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What will be researched")
                    .vesperText(.heading, theme)
                if researchQuestions.isEmpty {
                    Text("All lessons are marked known.")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.tertiaryText)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(researchQuestions.enumerated()), id: \.offset) { _, question in
                            Text(question)
                                .vesperText(.body, theme)
                                .foregroundStyle(theme.swiftUIColor("text-2", fallback: p.secondaryText))
                        }
                    }
                }
            }

            Divider().overlay(theme.swiftUIColor("border-subtle", fallback: p.border))

            VStack(alignment: .leading, spacing: 12) {
                Text("Limits")
                    .vesperText(.heading, theme)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                    HStack(spacing: 8) {
                        TextField("40", text: $sourcesText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: theme.pointSize(.body), design: .monospaced))
                        Stepper("", value: Binding(
                            get: { min(max(parsedSources, LearnLogic.sourceRange.lowerBound), LearnLogic.sourceRange.upperBound) },
                            set: { sourcesText = String($0) }
                        ), in: LearnLogic.sourceRange)
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Minutes per run")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                    HStack(spacing: 8) {
                        TextField("30", text: $minutesText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: theme.pointSize(.body), design: .monospaced))
                        Stepper("", value: Binding(
                            get: { min(max(parsedMinutes, LearnLogic.minuteRange.lowerBound), LearnLogic.minuteRange.upperBound) },
                            set: { minutesText = String($0) }
                        ), in: LearnLogic.minuteRange)
                        .labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Spend limit, USD")
                        .vesperText(.small, theme)
                        .foregroundStyle(p.secondaryText)
                    TextField("no limit", text: $spendText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: theme.pointSize(.body), design: .monospaced))
                    Text("Leave empty for no limit")
                        .font(.system(size: theme.pointSize(.micro) + 1))
                        .foregroundStyle(p.tertiaryText)
                }

                Text("About \(estRuns) runs, more if a lesson needs its one rewrite. They queue behind other work.")
                    .vesperText(.small, theme)
                    .foregroundStyle(p.tertiaryText)

                if let approveError {
                    LearnBanner(tone: "blocked", title: approveError)
                }

                Button(approvePending ? "Starting\u{2026}" : "Approve and start research") {
                    approveOutline()
                }
                .buttonStyle(.vesper(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!limitsValid || estRuns == 0 || approvePending)
            }
        }
    }

    private func editOutline(order: [LearnLogic.OutlineUnitOrder], known: [String]) {
        guard !editPending else { return }
        editPending = true
        editError = nil
        let knownSet = Set(known)
        let body = API.CourseOutlineEdit(
            known: known,
            units: order.map { API.CourseOutlineEdit.UnitsItem(lessons: $0.lessons, title: $0.title) }
        )
        let request = API.getCourse(id: course.summary.id)

        Task {
            do {
                let updated = try await context.store.mutate(
                    API.editCourseOutline(id: course.summary.id, body: body),
                    optimistic: [.update(request) { cached in
                        guard var cachedOutline = cached.outline else { return }
                        var lookup: [String: API.CourseOutlineLesson] = [:]
                        for u in cachedOutline.units where (u.part ?? 0) == cached.summary.part {
                            for l in u.lessons { lookup[l.key] = l }
                        }
                        var orderIndex = 0
                        for idx in cachedOutline.units.indices where (cachedOutline.units[idx].part ?? 0) == cached.summary.part {
                            guard orderIndex < order.count else { break }
                            let targetOrder = order[orderIndex]
                            orderIndex += 1
                            cachedOutline.units[idx].lessons = targetOrder.lessons.compactMap { key in
                                guard var lesson = lookup[key] else { return nil }
                                lesson.known = knownSet.contains(key)
                                return lesson
                            }
                        }
                        cached.outline = cachedOutline
                    }],
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                context.store.setData(updated, for: request)
                editPending = false
            } catch {
                editPending = false
                editError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func approveOutline() {
        guard limitsValid, estRuns > 0, !approvePending else { return }
        approvePending = true
        approveError = nil
        let body = API.CourseApprove(
            maxCostUsd: LearnLogic.parsedSpendLimit(spendText),
            maxMinutes: parsedMinutes,
            maxSources: parsedSources
        )
        let id = course.summary.id
        let request = API.getCourse(id: id)

        Task {
            do {
                let updated = try await context.store.mutate(
                    API.approveCourse(id: id, body: body),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                context.store.setData(updated, for: request)
                approvePending = false
                if part > 0 {
                    context.navigate("/learn/\(id)")
                }
            } catch {
                approvePending = false
                approveError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}
