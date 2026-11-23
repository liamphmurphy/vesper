import XCTest
@testable import VesperCore

final class ChatTimelineTreeImageTests: XCTestCase {
    func testTimelineWaterfallAndDateAxisGranularity() throws {
        // Run waterfall in ms with tokens annotation
        let waterfallJSON = """
        {
          "title": "Run Tool Waterfall",
          "unit": "ms",
          "items": [
            {"label": "read_file", "lane": "Explorer", "start": 0, "end": 420, "tokens": 1200},
            {"label": "run_tests", "lane": "Build", "start": 450, "end": 1850, "annotation": "3.4k tok"},
            {"label": "commit", "lane": "Build", "at": 1900}
          ]
        }
        """
        let wf = try ChatTimelineSpec.parse(waterfallJSON).get()
        XCTAssertEqual(wf.mode, .numeric)
        XCTAssertEqual(wf.lanes, ["Explorer", "Build"])
        XCTAssertEqual(wf.items[0].annotation, "1.2K tok")
        XCTAssertTrue(wf.items[2].isPoint)
        let wfTicks = wf.axisTicks(count: 4)
        XCTAssertEqual(wfTicks.count, 4)
        XCTAssertTrue(wfTicks.last?.label.hasSuffix("ms") == true)

        // Multi-year roadmap adapts to years
        let roadmapJSON = """
        {
          "title": "Roadmap",
          "items": [
            {"label": "v1", "start": "2024-01-01", "end": "2025-06-01"},
            {"label": "v2", "start": "2026-01-01", "end": "2028-01-01"}
          ]
        }
        """
        let rm = try ChatTimelineSpec.parse(roadmapJSON).get()
        XCTAssertEqual(rm.mode, .date)
        XCTAssertEqual(rm.axisTicks(count: 3).first?.label, "2024")

        // Invalid specs
        XCTAssertThrowsError(try ChatTimelineSpec.parse("{\"items\":[]}").get())
        XCTAssertThrowsError(try ChatTimelineSpec.parse("{\"items\":[{\"label\":\"bad\",\"at\":\"nope\"}]}").get())
    }

    func testTreeParserBuildsHierarchyIconsAndAnnotations() throws {
        let outline = """
        macos/ — Native Swift app
          Sources/
            VesperCore/ # shared logic
              ChatChartSpec.swift — chart parser
          README.md
        """
        let spec = try ChatTreeSpec.parse(outline, info: "tree Repo layout").get()
        XCTAssertEqual(spec.title, "Repo layout")
        XCTAssertEqual(spec.roots.count, 1)
        let root = spec.roots[0]
        XCTAssertEqual(root.label, "macos")
        XCTAssertEqual(root.annotation, "Native Swift app")
        XCTAssertTrue(root.isFolder)
        XCTAssertEqual(root.children.count, 2)
        XCTAssertTrue(root.children[0].isFolder)
        XCTAssertFalse(root.children[1].isFolder)
        XCTAssertEqual(root.children[0].children[0].children[0].annotation, "chart parser")

        XCTAssertThrowsError(try ChatTreeSpec.parse("   \n  ").get())
    }

    func testCompareImagesResolvesRefsAndRejectsInvalid() throws {
        let json = """
        {
          "title": "Redesign v1 vs v2",
          "before": "01a20488-bd7d-7ce0-836c-fdcdea552bb3",
          "after": "attachment:01a20488-bd7d-7ce0-836c-fdcdea552bb4",
          "beforeLabel": "Old",
          "afterLabel": "New"
        }
        """
        let spec = try ChatCompareImagesSpec.parse(json).get()
        XCTAssertEqual(spec.before.primaryPath, "/api/v1/library/01a20488-bd7d-7ce0-836c-fdcdea552bb3/content")
        XCTAssertEqual(spec.before.fallbackPath, "/api/v1/chat-attachments/01a20488-bd7d-7ce0-836c-fdcdea552bb3/content")
        XCTAssertEqual(spec.after.primaryPath, "/api/v1/chat-attachments/01a20488-bd7d-7ce0-836c-fdcdea552bb4/content")
        XCTAssertEqual(spec.beforeLabel, "Old")
        XCTAssertEqual(spec.afterLabel, "New")

        XCTAssertThrowsError(try ChatCompareImagesSpec.parse("{\"before\":\"bad\",\"after\":\"also-bad\"}").get())
        XCTAssertThrowsError(try ChatCompareImagesSpec.parse("not json").get())
    }
}
