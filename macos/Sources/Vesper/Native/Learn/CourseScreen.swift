import SwiftUI
import VesperCore

/// /learn/:id: routes between `StudyView` (when studyable and not reviewing a later part's outline)
/// and `CourseBuildView` (progress stepper, failed/stopped banners, or `OutlineReviewView`).
struct CourseScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var watchedKey: QueryKey?
    @State private var confirmDelete = false
    @State private var confirmStop = false
    @State private var stopPending = false
    @State private var deletePending = false
    @State private var actionError: String?

    private var courseId: String {
        context.match.params["id"] ?? ""
    }

    private var reviewMode: Bool {
        context.match.query["review"] == "1"
    }

    private var courseRequest: APIRequest<API.Course> {
        API.getCourse(id: courseId)
    }

    var body: some View {
        let entry = context.store.entry(courseRequest)
        let course = entry.data
        let isBuilding = course.map { LearnLogic.courseBuilding($0.summary.state) } ?? false
        let showStudy = course.map {
            $0.summary.studyable && !(reviewMode && $0.summary.state == .outlineReady)
        } ?? false
        let laterPart = (course?.summary.part ?? 0) > 0

        Group {
            if let course, showStudy {
                StudyView(course: course) {
                    confirmDelete = true
                }
                .id(course.summary.id)
            } else {
                CourseBuildView(
                    courseId: courseId,
                    entry: entry,
                    actionError: actionError,
                    stopPending: stopPending,
                    deletePending: deletePending,
                    onRequestStop: { confirmStop = true },
                    onRequestDelete: { confirmDelete = true },
                    onRefresh: {
                        Task { _ = await context.store.refetch(courseRequest) }
                    }
                )
            }
        }
        .task(id: courseId) {
            actionError = nil
            let request = courseRequest
            if let old = watchedKey, old != request.key {
                context.store.stopObserving(old)
            }
            if watchedKey != request.key {
                context.store.observe(request)
                watchedKey = request.key
            }
            context.store.load(request)
        }
        .task(id: "\(courseId):\(isBuilding)") {
            guard isBuilding, !courseId.isEmpty else { return }
            let request = courseRequest
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                _ = await context.store.refetch(request)
            }
        }
        .onDisappear {
            if let old = watchedKey {
                context.store.stopObserving(old)
                watchedKey = nil
            }
        }
        .alert("Delete this module?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete module", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("Its progress and its tutor conversation are deleted too.")
        }
        .alert(laterPart ? "Discard this part?" : "Stop building this module?", isPresented: $confirmStop) {
            Button("Cancel", role: .cancel) {}
            Button(laterPart ? "Discard this part" : "Stop build", role: .destructive) {
                performStop(laterPart: laterPart)
            }
        } message: {
            Text(
                laterPart
                    ? "Your built lessons stay available, and you can plan this part again later."
                    : "The current build run will be stopped."
            )
        }
    }

    private func performStop(laterPart: Bool) {
        guard !stopPending, !courseId.isEmpty else { return }
        stopPending = true
        actionError = nil
        let id = courseId
        let request = API.getCourse(id: id)
        Task {
            do {
                let updated = try await context.store.mutate(
                    API.stopCourse(id: id),
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                context.store.setData(updated, for: request)
                stopPending = false
                if laterPart {
                    context.navigate("/learn/\(id)")
                }
            } catch {
                stopPending = false
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func performDelete() {
        guard !deletePending, !courseId.isEmpty else { return }
        deletePending = true
        actionError = nil
        let id = courseId
        let listRequest = API.listCourses()
        Task {
            do {
                _ = try await context.store.mutate(
                    API.deleteCourse(id: id),
                    optimistic: [.update(listRequest) { items in
                        items.removeAll { $0.id == id }
                    }],
                    invalidating: QueryInvalidation(resources: ["courses", "learn"])
                )
                deletePending = false
                context.navigate("/learn")
            } catch {
                deletePending = false
                actionError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }
}

/// Non-study view for `/learn/:id`: scoping, outline review, researching/authoring/verifying, stopped, or failed.
private struct CourseBuildView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let courseId: String
    let entry: QueryEntry<API.Course>
    let actionError: String?
    let stopPending: Bool
    let deletePending: Bool
    let onRequestStop: () -> Void
    let onRequestDelete: () -> Void
    let onRefresh: () -> Void

    private var course: API.Course? { entry.data }
    private var laterPart: Bool { (course?.summary.part ?? 0) > 0 }

    private var chromeKey: String {
        let topic = course?.summary.topic ?? "Module"
        let state = course?.summary.state.rawValue ?? "loading"
        return "\(topic)|\(state)|\(laterPart)|\(stopPending)|\(deletePending)"
    }

    var body: some View {
        let p = theme.palette

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Button {
                        context.navigate("/learn")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Learn")
                        }
                        .foregroundStyle(p.secondaryText)
                    }
                    .buttonStyle(.plain)

                    Text("/")
                        .foregroundStyle(p.tertiaryText)

                    Text(course?.summary.topic ?? "Module")
                        .fontWeight(.medium)
                        .foregroundStyle(p.text)
                        .lineLimit(1)
                }
                .vesperText(.small, theme)

                if let actionError {
                    LearnBanner(tone: "blocked", title: actionError)
                }

                if entry.data == nil, let error = entry.error {
                    QueryErrorView(message: error.userMessage, retry: onRefresh)
                } else if entry.data == nil {
                    VStack(spacing: 12) {
                        SkeletonBar(height: 24)
                        SkeletonBar(height: 180)
                    }
                    .accessibilityLabel("Loading module")
                } else if let course {
                    if let error = entry.error {
                        LearnBanner(tone: "blocked", title: error.userMessage, retry: onRefresh)
                    }

                    BuildStepper(state: course.summary.state)

                    if course.summary.state == .failed {
                        LearnBanner(
                            tone: "blocked",
                            title: "This module couldn\u{2019}t be built",
                            bodyText: course.summary.error
                        )
                    } else if course.summary.state == .stopped {
                        LearnBanner(
                            tone: "blocked",
                            title: "This module was stopped",
                            bodyText: "Delete it, or start a new one from Learn."
                        )
                    }

                    if course.summary.state == .outlineReady, let outline = course.outline {
                        OutlineReviewView(course: course, outline: outline)
                            .id("\(course.summary.id)-\(course.summary.part)")
                    } else if course.summary.state != .outlineReady {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(course.summary.topic)
                                .vesperText(.title, theme)
                            if LearnLogic.courseBuilding(course.summary.state) {
                                let label = LearnLogic.stateLabel(course.summary.state)
                                let note = course.summary.buildNote.isEmpty ? "" : " · \(course.summary.buildNote)"
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("\(label)\(note). This takes a while; you can leave and come back.")
                                        .vesperText(.body, theme)
                                        .foregroundStyle(p.secondaryText)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: chromeKey, initial: true) { _, _ in
            publishChrome()
        }
        .onAppear {
            publishChrome()
            context.onCommand = { command in
                handleCommand(command)
            }
        }
    }

    private func publishChrome() {
        var items: [ShellToolbarItem] = [
            ShellToolbarItem(id: "course.refresh", label: "Refresh", icon: "refresh", kind: .button, showsLabel: false),
        ]
        if let course {
            if laterPart {
                items.append(
                    ShellToolbarItem(id: "course.back", label: "Back to studying", icon: "chev", kind: .button, showsLabel: true)
                )
                items.append(
                    ShellToolbarItem(
                        id: "course.discard",
                        label: "Discard this part",
                        icon: "trash",
                        kind: .button,
                        disabled: stopPending,
                        showsLabel: true
                    )
                )
            } else {
                if LearnLogic.courseBuilding(course.summary.state) {
                    items.append(
                        ShellToolbarItem(
                            id: "course.stop",
                            label: "Stop",
                            icon: "pause",
                            kind: .button,
                            disabled: stopPending,
                            showsLabel: true
                        )
                    )
                }
                items.append(
                    ShellToolbarItem(
                        id: "course.delete",
                        label: "Delete",
                        icon: "trash",
                        kind: .button,
                        disabled: deletePending,
                        showsLabel: true
                    )
                )
            }
        }
        context.chrome = NativeChrome(
            title: course?.summary.topic ?? "Module",
            toolbarItems: items,
            navigator: nil
        )
    }

    private func handleCommand(_ command: NativeCommand) {
        switch command {
        case .toolbarAction(itemId: "course.refresh", _):
            onRefresh()
        case .toolbarAction(itemId: "course.back", _):
            context.navigate("/learn/\(courseId)")
        case .toolbarAction(itemId: "course.discard", _), .toolbarAction(itemId: "course.stop", _):
            onRequestStop()
        case .toolbarAction(itemId: "course.delete", _):
            onRequestDelete()
        default:
            break
        }
    }
}
