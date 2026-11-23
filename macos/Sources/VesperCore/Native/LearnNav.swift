import Foundation

/// The Learn study view's left sidebar navigator model: the course progress,
/// optional next-part status/actions, and lessons grouped by unit.
/// Swift port of `web/lib/native-shell/models/study.ts`.
public enum LearnNav {
    public static let id = "study"
    public static let backAction = "back"
    public static let deleteAction = "delete"
    public static let planNextItem = "plan-next"
    public static let stopBuildItem = "stop-build"
    public static let reviewItem = "review"
    public static let scopingItem = "scoping"
    public static let buildingItem = "building"
    public static let nextErrorItem = "next-error"

    public struct StudyLesson: Sendable, Equatable, Hashable {
        public var key: String
        public var title: String
        public var unit: String
        /// Started or finished, or already known.
        public var done: Bool
        public var status: String

        public init(key: String, title: String, unit: String, done: Bool, status: String) {
            self.key = key
            self.title = title
            self.unit = unit
            self.done = done
            self.status = status
        }
    }

    public struct StudyNextPart: Sendable, Equatable, Hashable {
        /// 1-based part in question and the total.
        public var part: Int
        public var parts: Int
        public var title: String?
        /// The course's state: ready, scoping, outline_ready or a building state.
        public var state: String
        public var building: Bool
        public var error: String?
        public var buildNote: String?
        public var planPending: Bool
        public var stopPending: Bool
        public var actionError: String?
        public var courseId: String

        public init(
            part: Int,
            parts: Int,
            title: String? = nil,
            state: String,
            building: Bool,
            error: String? = nil,
            buildNote: String? = nil,
            planPending: Bool,
            stopPending: Bool,
            actionError: String? = nil,
            courseId: String
        ) {
            self.part = part
            self.parts = parts
            self.title = title
            self.state = state
            self.building = building
            self.error = error
            self.buildNote = buildNote
            self.planPending = planPending
            self.stopPending = stopPending
            self.actionError = actionError
            self.courseId = courseId
        }
    }

    public struct StudyInput: Sendable, Equatable {
        public var topic: String
        public var complete: Int
        public var total: Int
        public var solid: Int
        public var nextPart: StudyNextPart?
        public var lessons: [StudyLesson]
        public var currentKey: String?
        public var courseId: String

        public init(
            topic: String,
            complete: Int,
            total: Int,
            solid: Int,
            nextPart: StudyNextPart? = nil,
            lessons: [StudyLesson],
            currentKey: String? = nil,
            courseId: String
        ) {
            self.topic = topic
            self.complete = complete
            self.total = total
            self.solid = solid
            self.nextPart = nextPart
            self.lessons = lessons
            self.currentKey = currentKey
            self.courseId = courseId
        }
    }

    public static func nextPart(
        for course: API.Course,
        planPending: Bool = false,
        stopPending: Bool = false,
        actionError: String? = nil
    ) -> StudyNextPart? {
        let summary = course.summary
        let building = summary.state != .ready
        let partZeroBased = building ? summary.part : summary.part + 1
        guard summary.parts >= 2, !(!building && partZeroBased >= summary.parts) else { return nil }
        let parts = course.outline?.parts ?? []
        let title = partZeroBased >= 0 && partZeroBased < parts.count ? parts[partZeroBased].title : nil
        return StudyNextPart(
            part: partZeroBased + 1,
            parts: summary.parts,
            title: title,
            state: summary.state.rawValue,
            building: LearnLogic.courseBuilding(summary.state),
            error: summary.state == .ready && !summary.error.isEmpty ? summary.error : nil,
            buildNote: summary.buildNote.isEmpty ? nil : summary.buildNote,
            planPending: planPending,
            stopPending: stopPending,
            actionError: actionError,
            courseId: summary.id
        )
    }

    public static func buildStudyModel(
        course: API.Course,
        currentKey: String?,
        planPending: Bool = false,
        stopPending: Bool = false,
        actionError: String? = nil
    ) -> NavModel {
        let lessons = course.lessons.map { lesson in
            StudyLesson(
                key: lesson.key,
                title: lesson.title,
                unit: lesson.unitTitle,
                done: lesson.progress != .new || lesson.status == .known,
                status: lesson.status.rawValue
            )
        }
        return buildStudyModel(StudyInput(
            topic: course.summary.topic,
            complete: course.summary.complete,
            total: course.summary.lessons,
            solid: course.summary.solid,
            nextPart: nextPart(for: course, planPending: planPending, stopPending: stopPending, actionError: actionError),
            lessons: lessons,
            currentKey: currentKey,
            courseId: course.summary.id
        ))
    }

    public static func buildStudyModel(_ input: StudyInput) -> NavModel {
        var sections: [NavSection] = [
            NavSection(
                id: "progress",
                items: [NavItem(id: "progress", title: "\(input.complete) of \(input.total) complete · \(input.solid) solid", disabled: true)]
            )
        ]

        if let np = input.nextPart {
            var items: [NavItem] = []
            if np.state == "ready" {
                let prefix = np.error.map { "\($0) · " } ?? ""
                items.append(NavItem(
                    id: planNextItem,
                    title: np.planPending ? "Starting…" : "Plan part \(np.part) now",
                    subtitle: "\(prefix)Its outline starts on its own when you reach the last unit.",
                    icon: "play",
                    disabled: np.planPending
                ))
            } else if np.state == "scoping" {
                items.append(NavItem(
                    id: scopingItem,
                    title: "Drafting its outline from how you\u{2019}re doing…",
                    disabled: true
                ))
            } else if np.state == "outline_ready" {
                items.append(NavItem(
                    id: reviewItem,
                    title: "Review its outline",
                    icon: "edit",
                    href: "/learn/\(np.courseId)?review=1"
                ))
            }
            if np.building && np.state != "scoping" {
                let note = np.buildNote.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
                items.append(NavItem(
                    id: buildingItem,
                    title: "Building\(note). Keep studying meanwhile.",
                    disabled: true
                ))
            }
            if np.building {
                items.append(NavItem(
                    id: stopBuildItem,
                    title: "Stop building it",
                    icon: "pause",
                    disabled: np.stopPending
                ))
            }
            if let actionError = np.actionError, !actionError.isEmpty {
                items.append(NavItem(
                    id: nextErrorItem,
                    title: actionError,
                    status: .blocked,
                    disabled: true
                ))
            }
            let partTitle = np.title.flatMap { $0.isEmpty ? nil : " · \($0)" } ?? ""
            sections.append(NavSection(
                id: "next-part",
                title: "Part \(np.part) of \(np.parts)\(partTitle)",
                items: items
            ))
        }

        var units: [String] = []
        var seenUnits = Set<String>()
        for lesson in input.lessons where seenUnits.insert(lesson.unit).inserted {
            units.append(lesson.unit)
        }

        for unit in units {
            let items = input.lessons
                .filter { $0.unit == unit }
                .map { lesson -> NavItem in
                    var item = NavItem(id: lesson.key, title: lesson.title)
                    if lesson.done { item.icon = "check" }
                    if lesson.status == "flagged" {
                        item.status = .human
                        item.subtitle = "Flagged: see reviewer note"
                    }
                    if lesson.status == "known" {
                        item.subtitle = "You know this"
                        item.disabled = true
                    }
                    return item
                }
            sections.append(NavSection(id: "unit:\(unit)", title: unit, items: items))
        }

        return NavModel(
            id: id,
            title: input.topic,
            actions: [
                NavAction(id: backAction, label: "Back to Learn", icon: "chev"),
                NavAction(id: deleteAction, label: "Delete course", icon: "trash"),
            ],
            sections: sections,
            selectedId: input.currentKey
        )
    }

    public enum Action: Sendable, Equatable {
        case back
        case delete
        case planNext
        case stopBuild
        case reviewOutline(newTab: Bool)
        case selectLesson(String, newTab: Bool)
    }

    public static func action(for command: NativeCommand, lessonKeys: Set<String>) -> Action? {
        switch command {
        case .navAction(id, backAction, _, _):
            return .back
        case .navAction(id, deleteAction, _, _):
            return .delete
        case .navActivate(id, let itemId, let newTab):
            if itemId == planNextItem { return .planNext }
            if itemId == stopBuildItem { return .stopBuild }
            if itemId == reviewItem { return .reviewOutline(newTab: newTab) }
            if lessonKeys.contains(itemId) { return .selectLesson(itemId, newTab: newTab) }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Courses index navigator (/learn and /learn/:id build/outline)

    public static let coursesNavId = "learn-courses"
    public static let newCourseAction = "new-course"
    public static let coursesSearchId = "learn-search"
    public static let retryCoursesItem = "retry"
    public static let openNewTabMenu = "open-new-tab"
    public static let copyLinkMenu = "copy-link"

    public static func buildCoursesModel(
        courses: [API.CourseSummary],
        search: String = "",
        selectedId: String? = nil,
        loading: Bool = false,
        error: String? = nil
    ) -> NavModel {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = trimmed.lowercased()
        let filtered: [API.CourseSummary] = needle.isEmpty ? courses : courses.filter { c in
            c.topic.lowercased().contains(needle)
                || (c.nextLesson?.lowercased().contains(needle) ?? false)
                || c.buildNote.lowercased().contains(needle)
        }

        let sections: [NavSection]
        if loading && courses.isEmpty {
            sections = [NavSection(id: "loading", items: [], emptyText: "Loading modules\u{2026}")]
        } else if let error, !error.isEmpty, courses.isEmpty {
            sections = [NavSection(id: "error", items: [
                NavItem(id: retryCoursesItem, title: "Couldn\u{2019}t load modules", subtitle: error, icon: "refresh"),
            ])]
        } else {
            let inProgress = filtered.filter { !$0.studyable }
            let ready = filtered.filter { $0.studyable }
            var built: [NavSection] = []

            if !inProgress.isEmpty {
                built.append(NavSection(
                    id: "in-progress",
                    title: "In progress",
                    items: inProgress.map { course in
                        let sub: String = {
                            if course.state == .failed && !course.error.isEmpty { return course.error }
                            if !course.buildNote.isEmpty { return course.buildNote }
                            return LearnLogic.stateLabel(course.state)
                        }()
                        let tone: Tone? = {
                            if course.state == .outlineReady { return .human }
                            if course.state == .failed || course.state == .stopped { return .blocked }
                            if LearnLogic.courseBuilding(course.state) { return .done }
                            return .neutral
                        }()
                        return NavItem(
                            id: course.id,
                            title: course.topic,
                            subtitle: sub,
                            status: tone,
                            href: "/learn/\(course.id)",
                            contextMenu: courseContextMenu
                        )
                    },
                    badge: NavBadge(text: "\(inProgress.count)")
                ))
            }

            if !ready.isEmpty {
                built.append(NavSection(
                    id: "modules",
                    title: "Modules",
                    items: ready.map { course in
                        let sub: String? = {
                            if let next = course.nextLesson, !next.isEmpty { return next }
                            if course.parts > course.part + 1 || course.state != .ready { return "Built parts done" }
                            if course.lessons > 0 && course.complete >= course.lessons { return "Finished" }
                            return nil
                        }()
                        let trailing = course.lessons > 0 ? "\(course.complete)/\(course.lessons)" : nil
                        let tone: Tone? = {
                            if course.flagged > 0 { return .human }
                            if course.state != .ready { return .accent }
                            return nil
                        }()
                        return NavItem(
                            id: course.id,
                            title: course.topic,
                            subtitle: sub,
                            icon: "learn",
                            status: tone,
                            trailing: trailing,
                            href: "/learn/\(course.id)",
                            contextMenu: courseContextMenu
                        )
                    },
                    badge: NavBadge(text: "\(ready.count)")
                ))
            }

            if built.isEmpty {
                built = [NavSection(
                    id: "empty",
                    items: [],
                    emptyText: trimmed.isEmpty ? "No modules yet." : "No modules match."
                )]
            }
            sections = built
        }

        return NavModel(
            id: coursesNavId,
            title: "Learn",
            actions: [NavAction(id: newCourseAction, label: "New Learning Module", icon: "plus", accent: true)],
            search: NavSearch(id: coursesSearchId, placeholder: "Filter modules\u{2026}", value: search),
            sections: sections,
            selectedId: selectedId
        )
    }

    private static let courseContextMenu: [MenuItem] = [
        MenuItem(id: openNewTabMenu, label: "Open in New Tab", icon: "external"),
        MenuItem(id: copyLinkMenu, label: "Copy Link", icon: "copy"),
    ]

    public enum CoursesAction: Sendable, Equatable {
        case newCourse
        case search(String)
        case retry
        case openCourse(String, newTab: Bool)
        case copyLink(String)
    }

    public static func coursesAction(for command: NativeCommand) -> CoursesAction? {
        switch command {
        case .navAction(coursesNavId, newCourseAction, _, _):
            return .newCourse
        case .navAction(coursesNavId, openNewTabMenu, let itemId?, _):
            return .openCourse(itemId, newTab: true)
        case .navAction(coursesNavId, copyLinkMenu, let itemId?, _):
            return .copyLink(itemId)
        case .navSearch(coursesNavId, coursesSearchId, let value):
            return .search(value)
        case .navActivate(coursesNavId, let itemId, let newTab):
            if itemId == retryCoursesItem { return .retry }
            return .openCourse(itemId, newTab: newTab)
        default:
            return nil
        }
    }
}
