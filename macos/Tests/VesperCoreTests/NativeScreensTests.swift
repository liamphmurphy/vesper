import XCTest
@testable import VesperCore

final class NativeRoutesTests: XCTestCase {
    private let registry = NativeRouteRegistry(
        routes: [
            NativeRoute("/tickets/:key", .debugPlaceholder),
            NativeRoute("/knowledge/*", .debugPlaceholder),
            NativeRoute("/native-debug", .debugPlaceholder),
        ],
        enabled: [.debugPlaceholder]
    )

    func testResolvesParamsQueryAndIgnoresFragment() {
        let match = registry.resolve("/tickets/PAY-1?tab=runs&tab=ignored#activity")
        XCTAssertEqual(match, NativeRouteMatch(screen: .debugPlaceholder, path: "/tickets/PAY-1", params: ["key": "PAY-1"], query: ["tab": "runs"]))
    }

    func testSegmentsAreDecodedAndMustMatchExactly() {
        XCTAssertEqual(registry.resolve("/tickets/a%20b")?.params["key"], "a b")
        XCTAssertNil(registry.resolve("/tickets"))
        XCTAssertNil(registry.resolve("/tickets/PAY-1/runs"))
        XCTAssertNil(registry.resolve("/ticketsX/PAY-1"))
    }

    func testWildcardTakesTheRest() {
        XCTAssertEqual(registry.resolve("/knowledge/Projects/Plan%201")?.params["*"], "Projects/Plan 1")
        XCTAssertEqual(registry.resolve("/knowledge")?.params["*"], "")
    }

    func testDisabledScreensStayOnTheWebView() {
        let off = NativeRouteRegistry(routes: registry.routes, enabled: [])
        XCTAssertNil(off.resolve("/native-debug"))
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug"))
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/7")?.params["id"], "7")
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/markdown")?.screen, .markdownDebug)
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug/markdown"))
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/scenes")?.screen, .scenesDebug)
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug/scenes"))
        XCTAssertEqual(NativeRouteRegistry.standard(debug: true).resolve("/native-debug/embeds")?.screen, .embedsDebug)
        XCTAssertNil(NativeRouteRegistry.standard(debug: false).resolve("/native-debug/embeds"))
    }

    func testWorkBareRunsAndRunDetailAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/work?project=VES")?.screen, .work)
        XCTAssertEqual(standard.resolve("/work?project=VES")?.query, ["project": "VES"])
        XCTAssertEqual(standard.resolve("/runs")?.screen, .work)
        let run = standard.resolve("/runs/r1?view=details")
        XCTAssertEqual(run?.screen, .runDetail)
        XCTAssertEqual(run?.params["id"], "r1")
        XCTAssertEqual(run?.query["view"], "details")
        XCTAssertNil(standard.resolve("/runs/r1/extra"))
        XCTAssertNil(standard.resolve("/workflows"))
    }

    func testLibraryAndPDFViewerAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        let library = standard.resolve("/library?tab=videos&item=v1")
        XCTAssertEqual(library?.screen, .library)
        XCTAssertEqual(library?.query, ["tab": "videos", "item": "v1"])
        XCTAssertEqual(standard.resolve("/library?source=projects&type=report")?.query["source"], "projects")
        let pdf = standard.resolve("/pdf?src=%2Fapi%2Fv1%2Fknowledge%2Fassets%2Fa1&title=Spec")
        XCTAssertEqual(pdf?.screen, .pdf)
        XCTAssertEqual(pdf?.query["src"], "/api/v1/knowledge/assets/a1")
        // Only the Library's own path: other screens under it stay on the web view until they move.
        XCTAssertNil(standard.resolve("/library/anything"))
    }

    func testDevTerminalIsNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/dev")?.screen, .dev)
        XCTAssertNil(standard.resolve("/dev/anything"))
    }

    func testHttpClientIsNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/http")?.screen, .http)
        let withWorkspace = standard.resolve("/http?workspace=ws-1")
        XCTAssertEqual(withWorkspace?.screen, .http)
        XCTAssertEqual(withWorkspace?.query, ["workspace": "ws-1"])
        XCTAssertNil(standard.resolve("/http/anything"))
    }

    func testLearnRoutesAreNative() {
        let standard = NativeRouteRegistry.standard(debug: false)
        XCTAssertEqual(standard.resolve("/learn")?.screen, .learn)
        let lesson = standard.resolve("/learn/c1?lesson=snapshots")
        XCTAssertEqual(lesson?.screen, .learnCourse)
        XCTAssertEqual(lesson?.params["id"], "c1")
        XCTAssertEqual(lesson?.query["lesson"], "snapshots")
        let review = standard.resolve("/learn/c1?review=1")
        XCTAssertEqual(review?.screen, .learnCourse)
        XCTAssertEqual(review?.query["review"], "1")
        XCTAssertNil(standard.resolve("/learn/c1/extra"))
    }

    func testOnlyInAppPathsResolve() {
        XCTAssertNil(registry.resolve("https://example.com/native-debug"))
        XCTAssertNil(registry.resolve("//evil.example/native-debug"))
        XCTAssertNil(registry.resolve("native-debug"))
    }

    func testDeepLinksReachNativeScreensThroughTheirPath() {
        guard case .ok(.navigate(let path)) = DeepLinks.parse("vesper://ticket/PAY-214") else { return XCTFail("parse") }
        XCTAssertEqual(registry.resolve(path)?.params["key"], "PAY-214")
        guard case .ok(.navigate(let inbox)) = DeepLinks.parse("vesper://inbox") else { return XCTFail("parse") }
        XCTAssertEqual(NativeRouteRegistry.standard(debug: false).resolve(inbox)?.screen, .inbox)
    }
}

final class NativeFindAndCommandTests: XCTestCase {
    private let rows = ["Alpha", "beta", "Gamma", "alphabet", "Delta"]

    func testNextMatchWrapsBothWays() {
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: nil, backwards: false), 0)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: 0, backwards: false), 3)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: 3, backwards: false), 0)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: 0, backwards: true), 3)
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "alpha", caseSensitive: false, after: nil, backwards: true), 3)
    }

    func testCaseSensitivityAndNoMatch() {
        XCTAssertEqual(FindLogic.nextMatch(in: rows, query: "Alpha", caseSensitive: true, after: 0, backwards: false), 0)
        XCTAssertNil(FindLogic.nextMatch(in: rows, query: "zeta", caseSensitive: false, after: nil, backwards: false))
        XCTAssertNil(FindLogic.nextMatch(in: rows, query: "", caseSensitive: false, after: nil, backwards: false))
    }

    func testScreenCommandsGoToTheNativeScreen() {
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.toolbarAction(itemId: "refresh")))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.titleAction(menuItemId: "rename")))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.inspectorAction(tabId: "t", actionId: "a")))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.inspectorVisibility(open: false)))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navigate(path: "/inbox")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navActivate(navigatorId: "n", itemId: "i")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.railAction(itemId: "r")))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.command(.find)))
    }

    func testAScreensOwnNavigatorCommandsGoToTheScreen() {
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.navActivate(navigatorId: "work-activity", itemId: "i"), navigatorId: "work-activity"))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.navSearch(navigatorId: "work-activity", searchId: "s", value: ""), navigatorId: "work-activity"))
        XCTAssertTrue(NativeCommandRouting.isScreenCommand(.navToggle(navigatorId: "work-activity", itemId: "s", expanded: false), navigatorId: "work-activity"))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navActivate(navigatorId: "runs", itemId: "i"), navigatorId: "work-activity"))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navFilter(navigatorId: "work-activity", filterId: "f", value: "", checked: true)))
        XCTAssertFalse(NativeCommandRouting.isScreenCommand(.navigate(path: "/work"), navigatorId: "work-activity"))
    }

    func testNavigatorCommandsGoToTheScreenThatPublishesTheNavigator() {
        let commands: [NativeCommand] = [
            .navActivate(navigatorId: "library", itemId: "videos"),
            .navAction(navigatorId: "library", actionId: "project", menuItemId: "space:PAY"),
            .navPicker(navigatorId: "library", pickerId: "source", value: "projects"),
            .navFilter(navigatorId: "library", filterId: "f", value: "v", checked: true),
            .navSearch(navigatorId: "library", searchId: "library-search", value: "spec"),
            .navToggle(navigatorId: "library", itemId: "i", expanded: true),
        ]
        for command in commands {
            XCTAssertTrue(NativeCommandRouting.isScreenCommand(command, navigatorId: "library"), "\(command)")
            // Another navigator's commands (the page's, still running underneath) stay with the page.
            XCTAssertFalse(NativeCommandRouting.isScreenCommand(command, navigatorId: "inbox"), "\(command)")
            XCTAssertFalse(NativeCommandRouting.isScreenCommand(command), "\(command)")
        }
    }
}
