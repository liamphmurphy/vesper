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
}
