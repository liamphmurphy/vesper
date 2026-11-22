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
}
