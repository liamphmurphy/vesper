import XCTest
@testable import VesperCore

final class TabLayoutSettingTests: XCTestCase {
    func testDefaultIsSeparate() {
        XCTAssertEqual(NativeSettings.defaults().tabs.layout, .separate)
        XCTAssertEqual(NativeSettings.normalize(nil).tabs.layout, .separate)
    }

    func testNormaliseKeepsCompactAndRepairsUnknownValues() {
        XCTAssertEqual(NativeSettings.normalize(["tabs": ["layout": "compact"]]).tabs.layout, .compact)
        XCTAssertEqual(NativeSettings.normalize(["tabs": ["layout": "grid"]]).tabs.layout, .separate)
        XCTAssertEqual(NativeSettings.normalize(["tabs": ["layout": 3]]).tabs.layout, .separate)
        XCTAssertEqual(NativeSettings.normalize(["tabs": "compact"]).tabs.layout, .separate)
    }

    func testPatchKeepsCurrentValueWhenInvalid() {
        var s = NativeSettings.defaults()
        s = s.applying(patch: ["tabs": ["layout": "compact"]])
        XCTAssertEqual(s.tabs.layout, .compact)
        XCTAssertEqual(s.applying(patch: ["tabs": ["layout": "bogus"]]).tabs.layout, .compact)
        XCTAssertEqual(s.applying(patch: ["tray": ["enabled": false]]).tabs.layout, .compact)
        XCTAssertEqual(s.applying(patch: ["tabs": ["layout": "separate"]]).tabs.layout, .separate)
    }

    func testPersistsUnderNativeTabs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tablayout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = ConfigFile.url(dataDirectory: dir)
        var s = NativeSettings.defaults()
        s.tabs.layout = .compact
        try ConfigFile.save(native: s, to: url)
        let native = ConfigFile.readDictionary(at: url)["native"] as? [String: Any]
        XCTAssertEqual((native?["tabs"] as? [String: Any])?["layout"] as? String, "compact")
        XCTAssertEqual(ConfigFile.loadNative(from: url).tabs.layout, .compact)
    }
}

final class TabListTests: XCTestCase {
    private func list(_ n: Int, active: Int = 0) -> TabList<String> {
        TabList(items: (0..<n).map { "t\($0)" }, activeIndex: active)
    }

    func testInsertAfterActiveSelectsNewTab() {
        var l = list(3, active: 1)
        XCTAssertEqual(l.insertAfterActive("x"), 2)
        XCTAssertEqual(l.items, ["t0", "t1", "x", "t2"])
        XCTAssertEqual(l.active, "x")
    }

    func testInsertInBackgroundKeepsActiveTab() {
        var l = list(3, active: 1)
        l.insert("x", at: 0, select: false)
        XCTAssertEqual(l.active, "t1")
        l.insert("y", at: 4, select: false)
        XCTAssertEqual(l.active, "t1")
    }

    func testCloseActiveSelectsRightNeighbourThenLast() {
        var l = list(4, active: 1)
        l.remove(at: 1)
        XCTAssertEqual(l.active, "t2")
        l.select(2)
        XCTAssertEqual(l.items, ["t0", "t2", "t3"])
        l.remove(at: 2)
        XCTAssertEqual(l.active, "t2")
        XCTAssertEqual(l.items, ["t0", "t2"])
        XCTAssertEqual(l.activeIndex, 1)
    }

    func testCloseOtherTabsKeepsActive() {
        var l = list(4, active: 2)
        l.remove(at: 0)
        XCTAssertEqual(l.active, "t2")
        l.remove(at: 2)
        XCTAssertEqual(l.active, "t2")
    }

    func testCloseLastTabEmptiesList() {
        var l = list(1)
        XCTAssertEqual(l.remove(at: 0), "t0")
        XCTAssertTrue(l.isEmpty)
        XCTAssertNil(l.active)
        XCTAssertNil(l.remove(at: 0))
    }

    func testMoveKeepsActiveTabSelected() {
        var l = list(4, active: 1)
        l.move(from: 0, to: 2)
        XCTAssertEqual(l.items, ["t1", "t2", "t0", "t3"])
        XCTAssertEqual(l.active, "t1")
        l.move(from: 0, to: 3)
        XCTAssertEqual(l.items, ["t2", "t0", "t3", "t1"])
        XCTAssertEqual(l.active, "t1")
        l.move(from: 3, to: 0)
        XCTAssertEqual(l.items, ["t1", "t2", "t0", "t3"])
        XCTAssertEqual(l.active, "t1")
        l.move(from: 3, to: 99)
        XCTAssertEqual(l.items, ["t1", "t2", "t0", "t3"])
    }

    func testIndexSetsForCloseOthersAndRight() {
        let l = list(4)
        XCTAssertEqual(l.indicesOfOthers(than: 1), [0, 2, 3])
        XCTAssertEqual(l.indicesToTheRight(of: 1), [2, 3])
        XCTAssertEqual(l.indicesToTheRight(of: 3), [])
    }

    func testNextPreviousWrapAndNumbered() {
        var l = list(3, active: 2)
        l.selectNext()
        XCTAssertEqual(l.activeIndex, 0)
        l.selectPrevious()
        XCTAssertEqual(l.activeIndex, 2)
        XCTAssertTrue(l.selectNumbered(2))
        XCTAssertEqual(l.activeIndex, 1)
        XCTAssertTrue(l.selectNumbered(9))
        XCTAssertEqual(l.activeIndex, 2)
        XCTAssertFalse(l.selectNumbered(5))
        XCTAssertEqual(l.activeIndex, 2)
    }

    func testSessionMappingSkipsUnsavableTabsAndKeepsActive() {
        let b = WindowBounds(x: 1, y: 2, width: 800, height: 600)
        let s = sessionState(urls: ["a", nil, "c", "d"], activeIndex: 2, bounds: b)
        XCTAssertEqual(s, SessionState(tabs: ["a", "c", "d"], activeIndex: 1, bounds: b))
        // The active tab can't be saved: the next saved tab stands in.
        XCTAssertEqual(sessionState(urls: ["a", nil, "c"], activeIndex: 1, bounds: nil)?.activeIndex, 1)
        XCTAssertEqual(sessionState(urls: ["a", nil], activeIndex: 1, bounds: nil)?.activeIndex, 0)
        XCTAssertNil(sessionState(urls: [nil, nil], activeIndex: 0, bounds: nil))
    }

    func testClosingTheAppsOnlyTabOpensANewChatInsteadOfClosingTheWindow() {
        XCTAssertEqual(TabCloseOutcome.decide(tabsInWindow: 1, otherWindows: 0), .openNewChat)
    }

    func testClosingAWindowsLastTabClosesItWhileAnotherWindowIsOpen() {
        // Separate layout: a sibling tab is another window.
        XCTAssertEqual(TabCloseOutcome.decide(tabsInWindow: 1, otherWindows: 1), .closeWindow)
    }

    func testClosingOneOfSeveralTabsRemovesOnlyThatTab() {
        XCTAssertEqual(TabCloseOutcome.decide(tabsInWindow: 2, otherWindows: 0), .removeTab)
        XCTAssertEqual(TabCloseOutcome.decide(tabsInWindow: 3, otherWindows: 2), .removeTab)
    }
}
