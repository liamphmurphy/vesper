import SwiftUI
import VesperCore

/// /learn: lists active module builds and studyable learning modules, plus the New Learning Module wizard.
struct LearnScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var guideOpen = false

    private static let coursesRequest = API.listCourses()

    private var coursesEntry: QueryEntry<[API.CourseSummary]> {
        context.store.entry(Self.coursesRequest)
    }

    var body: some View {
        let entry = coursesEntry
        let all = entry.data ?? []
        let building = all.filter { !$0.studyable }
        let ready = all.filter { $0.studyable }
        let ordered = building + ready
        let hasBuilding = all.contains { LearnLogic.courseBuilding($0.state) }

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    content(entry: entry, all: all, building: building, ready: ready)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: context.find.current) { _, index in
                guard let index, index < ordered.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(ordered[index].id, anchor: .center)
                }
            }
        }
        .onChange(of: ordered.map(\.topic), initial: true) { _, topics in
            context.find.texts = topics
        }
        .task {
            context.store.load(Self.coursesRequest)
        }
        .task(id: hasBuilding) {
            guard hasBuilding else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                _ = await context.store.refetch(Self.coursesRequest)
            }
        }
        .onAppear {
            context.store.observe(Self.coursesRequest)
            publishChrome()
            context.onCommand = { command in
                handleCommand(command)
            }
        }
        .onDisappear {
            context.store.stopObserving(Self.coursesRequest.key)
        }
        .sheet(isPresented: $guideOpen) {
            NewModuleSheet()
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Learn")
                .vesperText(.display, theme)
            Text("Turn a topic into a sourced, properly ordered module, then work through it with a tutor.")
                .vesperText(.reading, theme)
                .foregroundStyle(theme.palette.secondaryText)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    @ViewBuilder
    private func content(
        entry: QueryEntry<[API.CourseSummary]>,
        all: [API.CourseSummary],
        building: [API.CourseSummary],
        ready: [API.CourseSummary]
    ) -> some View {
        let columns = [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)]

        if entry.data == nil, entry.error != nil {
            QueryErrorView(message: entry.error?.userMessage ?? "Couldn\u{2019}t load your modules.") {
                Task { _ = await context.store.refetch(Self.coursesRequest) }
            }
        } else if entry.data == nil {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBar(height: 112)
                }
            }
            .accessibilityLabel("Loading modules")
        } else {
            if let error = entry.error {
                LearnBanner(tone: "blocked", title: error.userMessage) {
                    Task { _ = await context.store.refetch(Self.coursesRequest) }
                }
            }
            if all.isEmpty {
                emptyState
            } else {
                if !building.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("In progress").vesperText(.heading, theme)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(building, id: \.id) { course in
                                buildCard(course).id(course.id)
                            }
                        }
                    }
                }
                if !ready.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your modules").vesperText(.heading, theme)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(ready, id: \.id) { course in
                                moduleCard(course).id(course.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "graduationcap")
                .font(.system(size: 24))
                .foregroundStyle(theme.palette.tertiaryText)
            Text("No modules yet")
                .vesperText(.heading, theme)
            Text("Start a New Learning Module and you\u{2019}ll get an outline to review.")
                .vesperText(.body, theme)
                .foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("New Learning Module") { guideOpen = true }
                .buttonStyle(.vesper(.primary))
        }
        .padding(.vertical, 52)
        .frame(maxWidth: .infinity)
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.palette.border))
    }

    private func buildCard(_ course: API.CourseSummary) -> some View {
        let p = theme.palette
        let step = LearnLogic.buildStepIndex(course.state)
        let findHit = context.find.matches(course.topic)
        let subtitle: String = {
            if course.state == .failed { return course.error }
            if !course.buildNote.isEmpty { return course.buildNote }
            if course.state == .outlineReady { return "\(course.units) units · \(course.lessons) lessons" }
            return " "
        }()

        return Button {
            context.navigate("/learn/\(course.id)")
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(course.topic)
                    .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                LearnStatePill(state: course.state)
                Text(subtitle)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                if step >= 0 {
                    HStack(spacing: 4) {
                        ForEach(Array(LearnLogic.buildSteps.enumerated()), id: \.offset) { idx, _ in
                            Capsule()
                                .fill(idx < step
                                    ? theme.swiftUIColor("text-2", fallback: p.secondaryText)
                                    : theme.swiftUIColor("track", fallback: p.hover))
                                .frame(height: 4)
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(findHit ? p.hover : p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(findHit ? p.accent : p.border))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu { cardContextMenu(course) }
    }

    private func moduleCard(_ course: API.CourseSummary) -> some View {
        let p = theme.palette
        let findHit = context.find.matches(course.topic)
        let partPrefix = course.parts > 1 ? "Part \(course.state == .ready ? course.part + 1 : course.part) of \(course.parts) · " : ""
        let progressLine = "\(partPrefix)\(course.complete) of \(course.lessons) complete · \(course.solid) solid"
        let hasNext = !(course.nextLesson ?? "").isEmpty
        let statusText: String = {
            if let next = course.nextLesson, !next.isEmpty { return "Continue: \(next)" }
            if course.parts > course.part + 1 || course.state != .ready { return "Built parts done" }
            return "Finished"
        }()

        return Button {
            context.navigate("/learn/\(course.id)")
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(course.topic)
                    .font(.system(size: theme.pointSize(.heading), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Text(progressLine)
                    .font(.system(size: theme.pointSize(.small), design: .monospaced))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
                LearnProgressBar(value: course.complete, total: course.lessons)
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.system(size: theme.pointSize(.body), weight: .medium))
                        .foregroundStyle(hasNext ? p.accent : p.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if course.state != .ready {
                        LearnStatePill(state: course.state)
                    }
                    if course.flagged > 0 {
                        Text("\(course.flagged) flagged")
                            .font(.system(size: theme.pointSize(.small)))
                            .foregroundStyle(theme.swiftUIColor("pill-human-fg", fallback: .orange))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(findHit ? p.hover : p.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(findHit ? p.accent : p.border))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu { cardContextMenu(course) }
    }

    @ViewBuilder
    private func cardContextMenu(_ course: API.CourseSummary) -> some View {
        Button("Open") { context.navigate("/learn/\(course.id)") }
        Button("Open in New Tab") { context.openInNewTab("/learn/\(course.id)") }
        Button("Copy Link") {
            let href = "/learn/\(course.id)"
            let copied = context.resolvedURL(href)?.absoluteString ?? href
            context.copyToClipboard(copied)
            context.showToast(ToastItemModel(id: "learn.copy.\(course.id)", title: "Link copied", tone: .success))
        }
    }

    private func publishChrome() {
        context.chrome = NativeChrome(
            title: "Learn",
            toolbarItems: [
                ShellToolbarItem(id: "learn.refresh", label: "Refresh", icon: "refresh", kind: .button, showsLabel: false),
                ShellToolbarItem(id: "learn.new", label: "New Learning Module", icon: "plus", kind: .button, accent: true, showsLabel: true),
            ],
            navigator: nil
        )
    }

    private func handleCommand(_ command: NativeCommand) {
        switch command {
        case .toolbarAction(itemId: "learn.new", _):
            guideOpen = true
        case .toolbarAction(itemId: "learn.refresh", _):
            Task { _ = await context.store.refetch(Self.coursesRequest) }
        default:
            break
        }
    }
}
