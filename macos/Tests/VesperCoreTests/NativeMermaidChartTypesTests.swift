import CoreGraphics
import XCTest
@testable import VesperCore

/// Pie and gantt charts: the mermaid types drawn by deterministic chart layouts rather than a graph
/// engine.
final class NativeMermaidChartTypesTests: XCTestCase {
    static let pieSample = """
    pie showData title Pets adopted by volunteers
        "Dogs" : 386
        "Cats" : 85.5
        "Rats" : 15
        "Fish" : 0
    """

    static let ganttSample = """
    gantt
        title Vesper 2.0 launch
        dateFormat YYYY-MM-DD
        axisFormat %b %e
        excludes weekends
        todayMarker off
        section Design
        Research users          :done, des1, 2024-01-08, 2024-01-12
        Wireframes              :active, des2, after des1, 5d
        Visual design review    :crit, after des2, 3d
        section Build
        API                     :api, 2024-01-15, 2w
        Native app              :app, after api, 15d
        Docs                    :10d
        section Launch
        Code freeze             :milestone, freeze, after app, 0d
        Release candidate QA    :crit, active, after freeze, 4d
        Ship it                 :milestone, after freeze, 6d
    """

    static let ganttHours = """
    gantt
        title Deploy day
        dateFormat HH:mm
        axisFormat %H:%M
        Prepare      :p, 09:00, 45m
        Migrate DB   :crit, m, after p, 1h
        Roll out     :after m, 2h
        Smoke tests  :done, 12:30, 30m
        Done         :milestone, 15:00, 0m
    """

    static let ganttYear = """
    gantt
        dateFormat YYYY-MM-DD
        section Q1
        A long-running research effort with a long name :2025-01-06, 70d
        section Q2-Q4
        Pilot     :pilot, 2025-04-01, 3M
        Rollout   :after pilot, 2025-12-15
        Tiny      :2025-12-20, 1d
    """

    static let samples: [(String, String)] = [
        ("gantt", ganttSample),
        ("gantt-hours", ganttHours),
        ("gantt-year", ganttYear),
        ("pie", pieSample),
        ("pie-single", "pie\n\"Everything\" : 1"),
        ("pie-many", "---\ntitle: Browser share\n---\npie\n" + ["Chrome": 64.2, "Safari": 18.6, "Edge": 5.2, "Firefox": 2.8, "Opera": 2.3,
                                                                    "Samsung Internet": 2.1, "UC Browser": 0.9, "Other": 3.9]
            .sorted { $0.key < $1.key }.map { "  \"\($0.key)\" : \($0.value)" }.joined(separator: "\n")),
    ]

    /// As `NativeMermaidTests.assertRenders`: profile-clean in both palettes, every label drawn,
    /// byte-identical on a re-run.
    @discardableResult
    func assertRenders(_ source: String, labels: [String], file: StaticString = #filePath, line: UInt = #line) throws -> MermaidDrawing {
        var light: MermaidDrawing?
        for p in [VizPalette.light, VizPalette.dark] {
            let d = try NativeMermaid.render(source, palette: p)
            XCTAssertEqual(MockupSVGProfile.violations(d.svg), [], file: file, line: line)
            XCTAssertNoThrow(try MockupSVGDocument(source: d.svg), file: file, line: line)
            XCTAssertEqual(d.svg, try NativeMermaid.svg(source, palette: p), "not deterministic", file: file, line: line)
            if light == nil { light = d }
        }
        let d = try XCTUnwrap(light)
        for l in labels {
            XCTAssertTrue(d.texts.contains(l), "missing label \(l) in \(d.texts)", file: file, line: line)
        }
        return d
    }

    func assertSyntax(_ source: String, line expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try NativeMermaid.svg(source, palette: .light), file: file, line: line) { e in
            guard case let .syntax(l, _)? = e as? NativeMermaidError else { return XCTFail("\(e)", file: file, line: line) }
            XCTAssertEqual(l, expected, file: file, line: line)
        }
    }

    // MARK: Pie

    func testPieWithShowDataAndTitle() throws {
        let d = try assertRenders(Self.pieSample, labels: ["Pets adopted by volunteers", "Dogs [386]", "Cats [85.5]", "Rats [15]", "79%", "18%"])
        XCTAssertFalse(d.texts.contains { $0.hasPrefix("Fish") }, "zero slices are left out")
        XCTAssertEqual(d.svg.components(separatedBy: "<path d=\"M").count - 1, 3, "one path per slice")
        // Largest first, so Dogs takes the first series colour.
        let dogs = try XCTUnwrap(d.svg.range(of: "Dogs [386]"))
        XCTAssertTrue(d.svg[..<dogs.lowerBound].contains(VizPalette.light.series[0]))
    }

    func testPieTitleOnItsOwnLineAndNoShowData() throws {
        let d = try assertRenders("pie\n  title Votes\n  \"Yes\" : 3\n  'No' : 1", labels: ["Votes", "Yes", "No", "75%", "25%"])
        XCTAssertFalse(d.texts.contains("Yes [3]"))
    }

    func testPieSingleSliceIsAFullCircle() throws {
        let d = try assertRenders("pie\n\"Everything\" : 1", labels: ["Everything", "100%"])
        XCTAssertTrue(d.svg.contains("<circle"))
        XCTAssertFalse(d.svg.contains(" A"), "no arc for a single slice")
    }

    func testPieSyntaxErrors() {
        assertSyntax("pie\n\"A\" : 1\n\"B\" : -2", line: 3)
        assertSyntax("pie\n\"A\" : 1\nB : 2", line: 3)
        assertSyntax("---\ntitle: T\n---\npie\n\"A\" : x", line: 5)
        assertSyntax("pie\n\"A\" : 0", line: 1)
    }

    func testPieTooManySlicesIsTooLarge() {
        let src = "pie\n" + (0...NativeMermaid.maxRows).map { "\"s\($0)\" : 1" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    // MARK: Gantt

    func testGanttProjectPlan() throws {
        let d = try assertRenders(Self.ganttSample, labels: [
            "Vesper 2.0 launch", "Design", "Build", "Launch", "Research users", "Wireframes", "Visual design review", "API",
            "Native app", "Docs", "Code freeze", "Release candidate QA", "Ship it", "Jan 14",
        ])
        XCTAssertEqual(d.nodeFrames.count, 9)
        for i in d.nodeFrames.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(d.nodeFrames[i].minY, d.nodeFrames[i - 1].maxY, "one task per row")
        }
        XCTAssertTrue(d.svg.contains("<polygon"), "milestones are diamonds")
    }

    func testGanttTimeOfDayAndYearLongCharts() throws {
        try assertRenders(Self.ganttHours, labels: ["Deploy day", "Prepare", "Migrate DB", "Roll out", "Smoke tests", "Done", "10:00"])
        try assertRenders(Self.ganttYear,
                          labels: ["Q1", "Q2-Q4", "A long-running research effort with a long name", "Pilot", "Rollout", "Tiny"])
    }

    func gantt(_ src: String) throws -> MermaidGantt {
        try MermaidGantt.parse(try MermaidSource(src))
    }

    func at(_ s: String) -> Int64 {
        GanttDateFormat("YYYY-MM-DD HH:mm").parse(s)!
    }

    func testGanttDateArithmetic() throws {
        let g = try gantt("""
        gantt
          A : a1, 2024-01-01, 3d
          B : after a1, 1w
          C : 12h
          D : d1, after a1 f1, 2024-03-01
          E : 2024-01-31, 1M
          F : f1, 2024-02-01, 1d
          G : 2024-01-01, until a1
          H : 2024-01-01T06:30, 90m
        """)
        let spans = g.tasks.map { [$0.start, $0.end] }
        XCTAssertEqual(spans, [
            [at("2024-01-01 00:00"), at("2024-01-04 00:00")],
            [at("2024-01-04 00:00"), at("2024-01-11 00:00")],
            [at("2024-01-11 00:00"), at("2024-01-11 12:00")],
            [at("2024-02-02 00:00"), at("2024-03-01 00:00")],
            [at("2024-01-31 00:00"), at("2024-02-29 00:00")],
            [at("2024-02-01 00:00"), at("2024-02-02 00:00")],
            [at("2024-01-01 00:00"), at("2024-01-01 00:00")],
            [at("2024-01-01 06:30"), at("2024-01-01 08:00")],
        ])
    }

    func testGanttExcludesInclusiveEndsAndTimeFormats() throws {
        // Thu 4 Jan 2024 + 3 working days ends on Tue 9 Jan; a Friday 1d task runs over the weekend to Monday.
        var g = try gantt("gantt\nexcludes weekends\nA : 2024-01-04, 3d\nB : 2024-01-05, 1d\nC : 2024-01-05, 2024-01-08")
        XCTAssertEqual(g.tasks.map(\.end), [at("2024-01-09 00:00"), at("2024-01-08 00:00"), at("2024-01-08 00:00")])
        g = try gantt("gantt\nexcludes 2024-01-02, wednesday\nincludes 2024-01-03\nA : 2024-01-01, 3d")
        XCTAssertEqual(g.tasks[0].end, at("2024-01-05 00:00"), "only the excluded Tuesday pushes the end")
        g = try gantt("gantt\ninclusiveEndDates\nA : 2024-01-01, 2024-01-03")
        XCTAssertEqual(g.tasks[0].end, at("2024-01-04 00:00"))
        g = try gantt("gantt\ndateFormat HH:mm\nA : 09:00, 90m")
        XCTAssertEqual(g.tasks.map { [$0.start, $0.end] }, [[9 * GanttTime.hour, 10 * GanttTime.hour + 30 * GanttTime.minute]])
        g = try gantt("gantt\ndateFormat DD/MM/YYYY HH:mm\nA : 29/02/2024 13:05, 1h")
        XCTAssertEqual(g.tasks[0].start, at("2024-02-29 13:05"))
        XCTAssertEqual(GanttTime.format(at("2024-03-05 07:08"), "%b %e %Y %H:%M %-m/%d %a %q"), "Mar 5 2024 07:08 3/05 Tue %q")
    }

    func testGanttTicksAreAlignedAndReadable() {
        let ticks = GanttTime.ticks(from: at("2024-01-03 00:00"), to: at("2024-03-20 00:00"), width: 800, fixed: nil, format: nil)
        XCTAssertGreaterThanOrEqual(ticks.times.count, 4)
        XCTAssertLessThanOrEqual(ticks.times.count, 24)
        XCTAssertTrue(ticks.times.allSatisfy { GanttTime.weekday(GanttTime.dayNumber($0)) == 0 }, "weekly ticks fall on Sundays")
        let monthly = GanttTime.ticks(from: at("2024-01-03 00:00"), to: at("2024-12-20 00:00"), width: 800, fixed: .months(1), format: "%b")
        XCTAssertEqual(monthly.times.map { GanttTime.format($0, monthly.format) }, ["Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])
    }

    func testGanttSyntaxErrors() {
        assertSyntax("gantt\nA : a, after b, 1d\nB : b, after a, 1d", line: 2)
        assertSyntax("gantt\nA : 2024-01-01, 1d\nB : after nope, 1d", line: 3)
        assertSyntax("gantt\nsection S\nA : 3d", line: 3)
        assertSyntax("---\ntitle: T\n---\ngantt\nA : 2024-13-01, 1d", line: 5)
        assertSyntax("gantt\nA : 2024-01-01, 3 days", line: 2)
        assertSyntax("gantt\nA 2024-01-01", line: 2)
        assertSyntax("gantt\ntickInterval often\nA : 2024-01-01, 1d", line: 2)
        assertSyntax("gantt\ntitle Empty", line: 1)
    }

    func testGanttTooManyTasksIsTooLarge() {
        let src = "gantt\nA : 2024-01-01, 1d\n" + (0..<NativeMermaid.maxRows).map { "T\($0) : 1d" }.joined(separator: "\n")
        XCTAssertThrowsError(try NativeMermaid.svg(src, palette: .light)) { e in
            XCTAssertEqual(e as? NativeMermaidError, .tooLarge)
        }
    }

    // MARK: Visual check

    /// Writes every sample as SVG and PNG into `macos/.build/mermaid-chart-png` when
    /// `MERMAID_CHART_PNG` is set, for eyeballing; `.build` is ignored, so nothing is left in the tree.
    func testWritePNGsWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["MERMAID_CHART_PNG"] != nil else { throw XCTSkip("MERMAID_CHART_PNG isn't set") }
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mermaid-chart-png")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, src) in Self.samples {
            for (mode, p) in [("light", VizPalette.light), ("dark", VizPalette.dark)] {
                let svg = try NativeMermaid.svg(src, palette: p)
                try svg.write(to: out.appendingPathComponent("\(name)-\(mode).svg"), atomically: true, encoding: .utf8)
                let png = try XCTUnwrap(MockupSVGRenderer.pngData(try MockupSVGDocument(source: svg), scale: 2, background: nil))
                try png.write(to: out.appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }
}
