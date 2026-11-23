import XCTest
@testable import VesperCore

final class LearnLogicTests: XCTestCase {
    private let units = [
        LearnLogic.OutlineUnitOrder(title: "A", lessons: ["a", "b"]),
        LearnLogic.OutlineUnitOrder(title: "B", lessons: ["c"]),
    ]

    // MARK: learning.test.mjs ports

    func testMoveLessonSwapsWithinUnit() {
        let moved = LearnLogic.moveLesson(units, key: "b", dir: -1)
        XCTAssertEqual(moved[0].lessons, ["b", "a"])
    }

    func testMoveLessonCrossesUnitEdgesAndLeavesInputAlone() {
        let down = LearnLogic.moveLesson(units, key: "b", dir: 1)
        XCTAssertEqual(down[0].lessons, ["a"])
        XCTAssertEqual(down[1].lessons, ["b", "c"])

        let up = LearnLogic.moveLesson(units, key: "c", dir: -1)
        XCTAssertEqual(up[0].lessons, ["a", "b", "c"])
        XCTAssertEqual(units[0].lessons, ["a", "b"])
    }

    func testMoveLessonCannotLeaveModule() {
        XCTAssertEqual(LearnLogic.moveLesson(units, key: "a", dir: -1), units)
        XCTAssertEqual(LearnLogic.moveLesson(units, key: "c", dir: 1), units)
        XCTAssertEqual(LearnLogic.moveLesson(units, key: "nope", dir: 1), units)
    }

    func testEstimatedRunsSkipsAllKnownUnits() {
        XCTAssertEqual(LearnLogic.estimatedRuns(knownFlagsByUnit: [[true], [false, true]]), 3)
        let outlineUnits = [
            API.CourseOutlineUnit(
                lessons: [API.CourseOutlineLesson(key: "l1", known: true, minutes: 10, objectives: [], prereqs: [], title: "L1")],
                question: "Q1",
                title: "U1"
            ),
            API.CourseOutlineUnit(
                lessons: [
                    API.CourseOutlineLesson(key: "l2", known: nil, minutes: 10, objectives: [], prereqs: [], title: "L2"),
                    API.CourseOutlineLesson(key: "l3", known: true, minutes: 10, objectives: [], prereqs: [], title: "L3"),
                ],
                question: "Q2",
                title: "U2"
            ),
        ]
        XCTAssertEqual(LearnLogic.estimatedRuns(outlineUnits), 3)
    }

    func testPickLessonHonorsRequestThenFirstUnfinished() {
        func lesson(
            _ key: String,
            status: API.CourseLesson.Status,
            progress: API.CourseLesson.Progress = .new,
            hasCheck: Bool = true
        ) -> API.CourseLesson {
            let checks = hasCheck ? [
                API.CourseCheck(
                    attempts: 0,
                    id: "chk-\(key)",
                    kind: .mcq,
                    objective: "obj",
                    options: ["a", "b"],
                    prompt: "Q?",
                    solved: false
                ),
            ] : []
            return API.CourseLesson(
                body: [],
                checks: checks,
                issues: [],
                key: key,
                minutes: 10,
                objectives: [],
                prereqs: [],
                progress: progress,
                shakyPrereqs: [],
                status: status,
                title: key.capitalized,
                unitTitle: "U1"
            )
        }

        let list = [
            lesson("k", status: .known, progress: .new, hasCheck: false),
            lesson("done", status: .verified, progress: .solid),
            lesson("next", status: .verified, progress: .new),
            lesson("gone", status: .flagged, progress: .new, hasCheck: false),
        ]
        XCTAssertEqual(LearnLogic.pickLesson(list, requested: "done")?.key, "done")
        XCTAssertEqual(LearnLogic.pickLesson(list, requested: nil)?.key, "next")
        XCTAssertEqual(LearnLogic.pickLesson(list, requested: "k")?.key, "next")
        XCTAssertEqual(LearnLogic.pickLesson([lesson("a", status: .verified, progress: .solid)], requested: nil)?.key, "a")
        XCTAssertNil(LearnLogic.pickLesson([], requested: nil))
    }

    func testBuildHelpers() {
        XCTAssertEqual(LearnLogic.buildStepIndex("researching"), 2)
        XCTAssertEqual(LearnLogic.buildStepIndex(API.CourseState.researching), 2)
        XCTAssertEqual(LearnLogic.buildStepIndex("failed"), -1)
        XCTAssertTrue(LearnLogic.courseBuilding("authoring"))
        XCTAssertTrue(LearnLogic.courseBuilding(API.CourseState.authoring))
        XCTAssertFalse(LearnLogic.courseBuilding("outline_ready"))
        XCTAssertEqual(LearnLogic.stateLabel(.verifying), "Reviewing")
        XCTAssertEqual(LearnLogic.statePillTone(.outlineReady), "human")
        XCTAssertEqual(LearnLogic.statePillTone(.failed), "blocked")
        XCTAssertEqual(LearnLogic.statePillTone(.ready), "neutral")
    }

    func testTimeSliderAndPartEstimates() {
        XCTAssertEqual(LearnLogic.timeSteps.first, 30)
        XCTAssertEqual(LearnLogic.timeSteps.last, 1200)
        XCTAssertTrue(LearnLogic.timeSteps.contains(180))
        XCTAssertTrue(LearnLogic.timeSteps.contains(480))
        XCTAssertEqual(
            [30, 60, 90, 1200].map(LearnLogic.timeLabel),
            ["30 min", "1 hour", "1.5 hours", "20 hours"]
        )
        XCTAssertEqual(
            [480, 540, 720, 1200].map(LearnLogic.partsEstimate),
            [1, 2, 3, 5]
        )
        XCTAssertTrue(LearnLogic.timeDetail(1200).contains("about 5 parts"))
        XCTAssertFalse(LearnLogic.timeDetail(480).contains("parts"))
    }

    // MARK: Outline limits, markdown & tutor helpers

    func testApproveLimitsValidation() {
        XCTAssertTrue(LearnLogic.approveLimitsValid(sources: 5, minutes: 5, spendText: ""))
        XCTAssertTrue(LearnLogic.approveLimitsValid(sources: 200, minutes: 120, spendText: "3.5"))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 4, minutes: 30, spendText: ""))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 201, minutes: 30, spendText: ""))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 40, minutes: 4, spendText: ""))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 40, minutes: 121, spendText: ""))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 40, minutes: 30, spendText: "0"))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 40, minutes: 30, spendText: "-2"))
        XCTAssertFalse(LearnLogic.approveLimitsValid(sources: 40, minutes: 30, spendText: "abc"))
        XCTAssertNil(LearnLogic.parsedSpendLimit(" "))
        XCTAssertEqual(LearnLogic.parsedSpendLimit(" 4.25 "), 4.25)
    }

    func testHoursCitationsFencesAndSvgTitle() {
        XCTAssertEqual(LearnLogic.hoursTenthsLabel(30), "0.5h")
        XCTAssertEqual(LearnLogic.hoursTenthsLabel(600), "10h")
        XCTAssertEqual(LearnLogic.citationsMarkdown([1, 2]), " [\\[1\\]](#source-1) [\\[2\\]](#source-2)")
        XCTAssertEqual(LearnLogic.citationsMarkdown(nil), "")

        let nested = "let s = \"```\""
        XCTAssertEqual(LearnLogic.codeFenceMarkdown(code: nested, lang: "swift"), "````swift\nlet s = \"```\"\n````")

        let svg = "<svg><title>Two row versions</title><rect/></svg>"
        XCTAssertEqual(LearnLogic.svgTitle(svg), "Two row versions")
        XCTAssertNil(LearnLogic.svgTitle("<svg><rect/></svg>"))
    }

    func testTutorMarkdownSplitsChartFences() {
        let md = """
        Picture it:

        ```chart
        {"type":"line","categories":["Mon","Tue"],"series":[{"name":"Tuples","values":[10,40]}]}
        ```

        And in Swift:

        ```swift
        print("hi")
        ```
        """
        let blocks = LearnLogic.splitTutorMarkdown(md)
        XCTAssertEqual(blocks.count, 3)
        if case .markdown(let first) = blocks[0] {
            XCTAssertTrue(first.contains("Picture it:"))
        } else {
            XCTFail("expected leading markdown block")
        }
        if case .chart(let json) = blocks[1] {
            if case .spec(let spec) = LearnLogic.parseChart(json) {
                XCTAssertEqual(spec.type, .line)
            } else {
                XCTFail("expected valid chart spec")
            }
        } else {
            XCTFail("expected chart block")
        }
        if case .markdown(let trailing) = blocks[2] {
            XCTAssertTrue(trailing.contains("```swift"))
        } else {
            XCTFail("expected trailing markdown block")
        }
    }

    // MARK: Chart parsing & formatting

    func testParseChartValidBarLineAndScatter() {
        let line = #"{"type":"line","title":"Dead tuples","x":{"label":"Day"},"y":{"label":"Count","unit":"%"},"categories":["Mon","Tue","Wed"],"series":[{"name":"Tuples","values":[10,null,25]}]}"#
        guard case .spec(let lineSpec) = LearnLogic.parseChart(line) else {
            return XCTFail("expected line chart spec")
        }
        XCTAssertEqual(lineSpec.type, .line)
        XCTAssertEqual(lineSpec.title, "Dead tuples")
        XCTAssertEqual(lineSpec.xLabel, "Day")
        XCTAssertEqual(lineSpec.yLabel, "Count")
        XCTAssertEqual(lineSpec.yUnit, "%")
        XCTAssertEqual(lineSpec.categories, ["Mon", "Tue", "Wed"])
        XCTAssertEqual(lineSpec.series[0].values, [10, nil, 25])

        let scatter = #"{"type":"scatter","series":[{"name":"Samples","points":[[1,2.5],[3,4]]}]}"#
        guard case .spec(let scatterSpec) = LearnLogic.parseChart(scatter) else {
            return XCTFail("expected scatter chart spec")
        }
        XCTAssertEqual(scatterSpec.type, .scatter)
        XCTAssertEqual(scatterSpec.series[0].points, [LearnLogic.ChartPoint(x: 1, y: 2.5), LearnLogic.ChartPoint(x: 3, y: 4)])
    }

    func testParseChartRejectsInvalidInputsAndBooleans() {
        XCTAssertEqual(LearnLogic.parseChart("{"), .error("This chart isn't valid JSON."))
        XCTAssertEqual(LearnLogic.parseChart(#"{"type":"pie"}"#), .error("A chart's type must be bar, line or scatter."))
        XCTAssertEqual(LearnLogic.parseChart(#"{"type":"bar","categories":["A"],"series":[]}"#), .error("A bar chart needs 1 to 8 series."))
        XCTAssertEqual(LearnLogic.parseChart(#"{"type":"bar","categories":[],"series":[{"name":"S","values":[]}]}"#), .error("A bar chart needs 1 to 60 categories."))
        XCTAssertEqual(
            LearnLogic.parseChart(#"{"type":"bar","categories":["A"],"series":[{"name":"","values":[1]},{"name":"B","values":[2]}]}"#),
            .error("Each series needs a name.")
        )
        // Ensure JSON booleans are not coerced to 1/0 numbers.
        XCTAssertEqual(
            LearnLogic.parseChart(#"{"type":"bar","categories":["A"],"series":[{"name":"S","values":[true]}]}"#),
            .error("Series \"S\" needs one value per category.")
        )
        XCTAssertEqual(
            LearnLogic.parseChart(#"{"type":"scatter","series":[{"name":"S","points":[[true,1]]}]}"#),
            .error("Each series needs 1 to 500 points.")
        )
    }

    func testChartNumberAndUnitFormatting() {
        XCTAssertEqual(LearnLogic.compactNumber(950), "950")
        XCTAssertEqual(LearnLogic.compactNumber(1_000), "1K")
        XCTAssertEqual(LearnLogic.compactNumber(2_500_000), "2.5M")
        XCTAssertEqual(LearnLogic.withUnit("42", unit: "$"), "$42")
        XCTAssertEqual(LearnLogic.withUnit("-42", unit: "€"), "-€42")
        XCTAssertEqual(LearnLogic.withUnit("42", unit: "%"), "42%")
        XCTAssertEqual(LearnLogic.withUnit("42", unit: "ms"), "42 ms")
        XCTAssertEqual(LearnLogic.formatChartValue(1234.5, unit: "$"), "$1,234.5")
    }

    // MARK: Study Nav (screens.test.mjs port)

    func testStudyNavProgressNextPartAndLessonsByUnit() {
        let lessons = [
            LearnNav.StudyLesson(key: "a", title: "Intro", unit: "U1", done: true, status: "verified"),
            LearnNav.StudyLesson(key: "b", title: "Deep", unit: "U1", done: false, status: "flagged"),
            LearnNav.StudyLesson(key: "c", title: "Known", unit: "U2", done: true, status: "known"),
        ]
        let model = LearnNav.buildStudyModel(LearnNav.StudyInput(
            topic: "Rust",
            complete: 1,
            total: 3,
            solid: 1,
            nextPart: LearnNav.StudyNextPart(
                part: 2,
                parts: 3,
                title: "Async",
                state: "ready",
                building: false,
                planPending: false,
                stopPending: false,
                courseId: "c1"
            ),
            lessons: lessons,
            currentKey: "b",
            courseId: "c1"
        ))
        XCTAssertEqual(model.title, "Rust")
        XCTAssertEqual(model.actions?.map(\.id), ["back", "delete"])
        XCTAssertEqual(model.sections[0].items[0].title, "1 of 3 complete · 1 solid")
        XCTAssertEqual(model.sections[1].title, "Part 2 of 3 · Async")
        XCTAssertEqual(model.sections[1].items[0].id, "plan-next")
        XCTAssertEqual(model.sections.dropFirst(2).map(\.title), ["U1", "U2"])
        XCTAssertEqual(model.sections[2].items[0], NavItem(id: "a", title: "Intro", icon: "check"))
        XCTAssertEqual(model.sections[2].items[1], NavItem(id: "b", title: "Deep", subtitle: "Flagged: see reviewer note", status: .human))
        XCTAssertEqual(model.sections[3].items[0].disabled, true)
        XCTAssertEqual(model.selectedId, "b")

        let review = LearnNav.buildStudyModel(LearnNav.StudyInput(
            topic: "T",
            complete: 0,
            total: 0,
            solid: 0,
            nextPart: LearnNav.StudyNextPart(
                part: 1,
                parts: 2,
                state: "outline_ready",
                building: false,
                planPending: false,
                stopPending: false,
                courseId: "c1"
            ),
            lessons: [],
            courseId: "c1"
        ))
        XCTAssertEqual(review.sections[1].items[0].href, "/learn/c1?review=1")

        let building = LearnNav.buildStudyModel(LearnNav.StudyInput(
            topic: "T",
            complete: 0,
            total: 0,
            solid: 0,
            nextPart: LearnNav.StudyNextPart(
                part: 1,
                parts: 2,
                state: "authoring",
                building: true,
                buildNote: "Unit 2",
                planPending: false,
                stopPending: true,
                actionError: "nope",
                courseId: "c1"
            ),
            lessons: [],
            courseId: "c1"
        ))
        XCTAssertEqual(building.sections[1].items.map(\.id), ["building", "stop-build", "next-error"])
        XCTAssertEqual(building.sections[1].items[1].disabled, true)
    }

    func testStudyNavCommandsDecode() {
        let keys: Set<String> = ["snapshots", "vacuum"]
        XCTAssertEqual(LearnNav.action(for: .navAction(navigatorId: LearnNav.id, actionId: "back"), lessonKeys: keys), .back)
        XCTAssertEqual(LearnNav.action(for: .navAction(navigatorId: LearnNav.id, actionId: "delete"), lessonKeys: keys), .delete)
        XCTAssertEqual(LearnNav.action(for: .navActivate(navigatorId: LearnNav.id, itemId: "plan-next"), lessonKeys: keys), .planNext)
        XCTAssertEqual(LearnNav.action(for: .navActivate(navigatorId: LearnNav.id, itemId: "stop-build"), lessonKeys: keys), .stopBuild)
        XCTAssertEqual(LearnNav.action(for: .navActivate(navigatorId: LearnNav.id, itemId: "review", newTab: true), lessonKeys: keys), .reviewOutline(newTab: true))
        XCTAssertEqual(LearnNav.action(for: .navActivate(navigatorId: LearnNav.id, itemId: "vacuum", newTab: true), lessonKeys: keys), .selectLesson("vacuum", newTab: true))
        XCTAssertNil(LearnNav.action(for: .navActivate(navigatorId: LearnNav.id, itemId: "unknown"), lessonKeys: keys))
        XCTAssertNil(LearnNav.action(for: .navActivate(navigatorId: "other", itemId: "vacuum"), lessonKeys: keys))
    }

    func testCoursesNavModelGroupsFiltersAndDecodesCommands() {
        func summary(
            id: String,
            topic: String,
            state: API.CourseState,
            studyable: Bool,
            complete: Int = 0,
            lessons: Int = 6,
            nextLesson: String? = nil,
            buildNote: String = ""
        ) -> API.CourseSummary {
            API.CourseSummary(
                buildNote: buildNote,
                complete: complete,
                createdAt: "2026-11-20T00:00:00Z",
                error: "",
                flagged: 0,
                id: id,
                lessons: lessons,
                minutes: 90,
                nextLesson: nextLesson,
                part: 0,
                parts: 1,
                readyAt: nil,
                solid: complete,
                state: state,
                studyable: studyable,
                topic: topic,
                units: 2
            )
        }

        let courses = [
            summary(id: "c-build", topic: "Rust Lifetimes", state: .outlineReady, studyable: false),
            summary(id: "c-ready", topic: "Postgres MVCC", state: .ready, studyable: true, complete: 2, lessons: 5, nextLesson: "Vacuum"),
        ]
        let model = LearnNav.buildCoursesModel(courses: courses, selectedId: "c-build")
        XCTAssertEqual(model.id, LearnNav.coursesNavId)
        XCTAssertEqual(model.title, "Learn")
        XCTAssertEqual(model.selectedId, "c-build")
        XCTAssertEqual(model.sections.map(\.id), ["in-progress", "modules"])
        XCTAssertEqual(model.sections[0].items.first?.status, .human)
        XCTAssertEqual(model.sections[1].items.first?.trailing, "2/5")
        XCTAssertEqual(model.sections[1].items.first?.subtitle, "Vacuum")

        let filtered = LearnNav.buildCoursesModel(courses: courses, search: "mvcc")
        XCTAssertEqual(filtered.sections.map(\.id), ["modules"])
        XCTAssertEqual(filtered.sections[0].items.map(\.id), ["c-ready"])

        let empty = LearnNav.buildCoursesModel(courses: [], loading: false)
        XCTAssertEqual(empty.sections.first?.emptyText, "No modules yet.")

        let loading = LearnNav.buildCoursesModel(courses: [], loading: true)
        XCTAssertEqual(loading.sections.first?.id, "loading")

        let errored = LearnNav.buildCoursesModel(courses: [], error: "offline")
        XCTAssertEqual(errored.sections.first?.items.first?.id, LearnNav.retryCoursesItem)

        XCTAssertEqual(
            LearnNav.coursesAction(for: .navAction(navigatorId: LearnNav.coursesNavId, actionId: LearnNav.newCourseAction)),
            .newCourse
        )
        XCTAssertEqual(
            LearnNav.coursesAction(for: .navSearch(navigatorId: LearnNav.coursesNavId, searchId: LearnNav.coursesSearchId, value: "go")),
            .search("go")
        )
        XCTAssertEqual(
            LearnNav.coursesAction(for: .navActivate(navigatorId: LearnNav.coursesNavId, itemId: "c-ready", newTab: true)),
            .openCourse("c-ready", newTab: true)
        )
        XCTAssertEqual(
            LearnNav.coursesAction(for: .navActivate(navigatorId: LearnNav.coursesNavId, itemId: LearnNav.retryCoursesItem)),
            .retry
        )
        XCTAssertEqual(
            LearnNav.coursesAction(for: .navAction(navigatorId: LearnNav.coursesNavId, actionId: LearnNav.copyLinkMenu, itemId: "c-ready")),
            .copyLink("c-ready")
        )
        XCTAssertNil(LearnNav.coursesAction(for: .navActivate(navigatorId: "other", itemId: "c-ready")))
    }
}
