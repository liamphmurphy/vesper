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

    @State private var navSearch = ""
    @State private var guideOpen = false

    private static let coursesRequest = API.listCourses()

    private var course: API.Course? { entry.data }
    private var laterPart: Bool { (course?.summary.part ?? 0) > 0 }

    var body: some View {
        let p = theme.palette
        let coursesEntry = context.store.entry(Self.coursesRequest)
        let courses = coursesEntry.data ?? []
        let currentChrome = buildChrome(coursesEntry: coursesEntry, courses: courses)

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
        .onChange(of: currentChrome, initial: true) { _, next in
            context.chrome = next
        }
        .task {
            context.store.load(Self.coursesRequest)
        }
        .onAppear {
            context.store.observe(Self.coursesRequest)
            context.chrome = currentChrome
            context.onCommand = { command in
                handleCommand(command)
            }
        }
        .onDisappear {
            context.onCommand = nil
            context.store.stopObserving(Self.coursesRequest.key)
        }
        .sheet(isPresented: $guideOpen) {
            NewModuleSheet()
                .environment(context)
                .environment(\.vesperTheme, theme)
        }
    }

    private func buildChrome(
        coursesEntry: QueryEntry<[API.CourseSummary]>,
        courses: [API.CourseSummary]
    ) -> NativeChrome {
        var items: [ShellToolbarItem] = [
            ShellToolbarItem(id: "course.refresh", label: "Refresh", icon: "refresh", kind: .button, showsLabel: false),
        ]
        if let course {
            if laterPart {
                items.append(
                    ShellToolbarItem(id: "course.back", label: "Back to studying", icon: "chevl", kind: .button, showsLabel: true)
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
        return NativeChrome(
            title: course?.summary.topic ?? "Module",
            toolbarItems: items,
            navigator: LearnNav.buildCoursesModel(
                courses: courses,
                search: navSearch,
                selectedId: courseId,
                loading: coursesEntry.data == nil && coursesEntry.error == nil,
                error: coursesEntry.data == nil ? coursesEntry.error?.userMessage : nil
            )
        )
    }

    private func handleCommand(_ command: NativeCommand) {
        switch command {
        case .toolbarAction(itemId: "course.refresh", _):
            onRefresh()
            return
        case .toolbarAction(itemId: "course.back", _):
            context.navigate("/learn/\(courseId)")
            return
        case .toolbarAction(itemId: "course.discard", _), .toolbarAction(itemId: "course.stop", _):
            onRequestStop()
            return
        case .toolbarAction(itemId: "course.delete", _):
            onRequestDelete()
            return
        default:
            break
        }
        guard let action = LearnNav.coursesAction(for: command) else { return }
        switch action {
        case .newCourse:
            guideOpen = true
        case .search(let value):
            navSearch = value
        case .retry:
            Task { _ = await context.store.refetch(Self.coursesRequest) }
        case .openCourse(let id, let newTab):
            if newTab {
                context.openInNewTab("/learn/\(id)")
            } else {
                context.navigate("/learn/\(id)")
            }
        case .copyLink(let id):
            let href = "/learn/\(id)"
            let copied = context.resolvedURL(href)?.absoluteString ?? href
            context.copyToClipboard(copied)
            context.showToast(ToastItemModel(id: "learn.copy.\(id)", title: "Link copied", tone: .success))
        }
    }
}
